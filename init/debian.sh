#!/bin/bash
set -euo pipefail

default_ssh_port=2221
ssh_port=
non_interactive=0
scratch=
pending_file=

fail() {
    printf 'init-host: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n $pending_file ]]; then rm -f -- "$pending_file"; fi
    if [[ -n $scratch ]]; then rm -rf -- "$scratch"; fi
}

write_config() {
    local file=$1 mode=$2

    pending_file=$(mktemp --tmpdir="$(dirname -- "$file")" .init-host.XXXXXXXX)
    cat > "$pending_file"
    if [[ -f $file && ! -L $file ]] &&
        cmp -s -- "$pending_file" "$file" &&
        [[ $(stat -c '%u:%g:%a' -- "$file") == "0:0:$mode" ]]; then
        rm -- "$pending_file"
    else
        chown root:root -- "$pending_file"
        chmod "$mode" -- "$pending_file"
        mv -fT -- "$pending_file" "$file"
    fi
    pending_file=
}

validate_ssh_port() {
    local port=$1
    if [[ ! $port =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
        fail "Invalid SSH port: $port"
    fi
}

parse_args() {
    local usage="Usage: ${0##*/} [--ssh-port PORT] [--non-interactive]"
    if [[ $# -eq 1 && $1 == --help ]]; then
        printf '%s\n' "$usage"
        exit 0
    fi

    while (( $# )); do
        case $1 in
            --ssh-port)
                [[ $# -ge 2 && -z $ssh_port ]] || fail "$usage"
                validate_ssh_port "$2"
                ssh_port=$2
                shift 2
                ;;
            --non-interactive)
                non_interactive=1
                shift
                ;;
            *)
                fail "$usage"
                ;;
        esac
    done
    if (( non_interactive )); then
        ssh_port=${ssh_port:-$default_ssh_port}
    fi
}

preflight() {
    local ID VERSION_ID VERSION_CODENAME ssh_peer
    (( EUID == 0 )) || fail 'Run as root.'
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ $ID == debian && $VERSION_ID == 13 && $(dpkg --print-architecture) == amd64 ]] ||
        fail 'This script requires Debian 13 amd64.'
    [[ ${VERSION_CODENAME-} =~ ^[a-z][a-z0-9-]*$ ]] ||
        fail 'Debian release codename is missing or invalid in /etc/os-release.'
    debian_codename=$VERSION_CODENAME
    [[ -d /run/systemd/system ]] || fail 'This script requires a running systemd.'
    if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
        fail 'This script requires ssh.service in standalone mode. ssh.socket is active or enabled.'
    fi
    ssh_peer=${SSH_CONNECTION-}
    ssh_peer=${ssh_peer%% *}
    [[ $ssh_peer != *:* ]] || fail 'Reconnect over IPv4 before disabling IPv6.'
}

configure_apt_sources() {
    local codename=$1 components='main non-free contrib non-free-firmware'
    local source_list='' source_parts='' apt_paths entry file staged
    local assignments="^(source_list|source_parts)='([^'[:cntrl:]]+)'$"
    local network=0 debian=0 seen_network seen_debian changed
    local -a targets=() candidates=()

    apt_paths=$(apt-config shell source_list Dir::Etc::sourcelist/f source_parts Dir::Etc::sourceparts/d)
    while IFS= read -r entry; do
        [[ $entry =~ $assignments ]] || fail 'Could not read the active APT source paths.'
        printf -v "${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
    done <<< "$apt_paths"
    [[ $source_list == /* && $source_parts == /* ]] ||
        fail 'APT source paths must be absolute.'

    cat > "$scratch/apt-sources.awk" <<'APT_SOURCES'
function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
}

function network_uri(uri) {
    return uri ~ /^([a-z]+\+)*(https?|ftps?):\/\// || uri ~ /^mirror([+:])/
}

function debian_uri(uri, keyring) {
    if (!network_uri(uri)) return 0
    return keyring ~ /^\/usr\/share\/keyrings\/debian-archive-keyring\.(gpg|pgp)$/ ||
        uri ~ /^[a-z+]+:\/\/([a-z0-9-]+\.)*debian\.org\/debian(-security)?\/?$/ ||
        uri ~ /^[a-z+]+:\/\/security\.debian\.org\/?$/
}

function current_suite(suite) {
    return suite == codename || index(suite, codename "-") == 1
}

function legacy(line, body, comment, prefix, options, keyring, fields, i, end, count) {
    if (!match(line, /^[ \t]*deb(-src)?[ \t]+/)) return line
    prefix = substr(line, 1, RLENGTH)
    body = substr(line, RLENGTH + 1)
    end = index(body, "#")
    if (end) {
        comment = substr(body, end)
        body = substr(body, 1, end - 1)
        match(body, /[ \t]*$/)
        comment = substr(body, RSTART) comment
    }
    body = trim(body)
    if (substr(body, 1, 1) == "[") {
        end = index(body, "]")
        if (!end) return line
        options = substr(body, 2, end - 2)
        count = split(options, fields, /[ \t]+/)
        for (i = 1; i <= count; i++) {
            if (fields[i] ~ /^signed-by=/) keyring = substr(fields[i], 11)
        }
        match(body, /^\[[^]]*\][ \t]*/)
        prefix = prefix substr(body, 1, RLENGTH)
        body = substr(body, RLENGTH + 1)
    }
    split(body, fields, /[ \t]+/)
    if (network_uri(fields[1])) network = 1
    if (!current_suite(fields[2]) || !debian_uri(fields[1], keyring)) return line
    debian = 1
    match(body, /^[^ \t]+[ \t]+[^ \t]+/)
    return prefix substr(body, 1, RLENGTH) " " components comment
}

function flush_stanza(uris, suites, uri_count, suite_count, official, current, i, selected, written) {
    if (tolower(trim(values["enabled"])) !~ /^(no|false|off|disable|without|[+-]?0+)$/ &&
        trim(values["types"]) ~ /(^|[ \t])deb(-src)?($|[ \t])/) {
        uri_count = split(trim(values["uris"]), uris, /[ \t]+/)
        suite_count = split(trim(values["suites"]), suites, /[ \t]+/)
        for (i = 1; i <= uri_count; i++) {
            if (network_uri(uris[i])) network = 1
            if (debian_uri(uris[i], trim(values["signed-by"]))) official++
        }
        for (i = 1; i <= suite_count; i++) {
            if (current_suite(suites[i])) current++
        }
        if (official && current) {
            if (official != uri_count || current != suite_count) {
                print "init-host: Split the mixed Debian source stanza in " FILENAME > "/dev/stderr"
                invalid = 1
            } else {
                debian = selected = 1
            }
        }
    }
    for (i = 1; i <= line_count; i++) {
        if (!selected || line_fields[i] != "components") {
            print lines[i]
        } else if (!written++) {
            print "Components: " components
            if (lines[i] != "Components: " components) changed = 1
        } else {
            changed = 1
        }
        delete lines[i]
        delete line_fields[i]
    }
    if (selected && !written) {
        print "Components: " components
        changed = 1
    }
    for (i in values) delete values[i]
    line_count = 0
    field = ""
}

format != "deb822" {
    updated = legacy($0)
    if (updated != $0) changed = 1
    print updated
    next
}

/^[[:space:]]*$/ {
    flush_stanza()
    print
    next
}

{
    lines[++line_count] = $0
    if (match($0, /^[[:alnum:]-]+:/)) {
        field = tolower(substr($0, 1, RLENGTH - 1))
        values[field] = trim(substr($0, RLENGTH + 1))
        line_fields[line_count] = field
    } else if (field != "" && /^[ \t]/) {
        values[field] = values[field] " " trim($0)
        line_fields[line_count] = field
    }
}

END {
    if (format == "deb822") flush_stanza()
    if (invalid) exit 1
    print network + 0, debian + 0, changed + 0 > metadata
}
APT_SOURCES

    local format
    for file in "$source_list" "$source_parts"/*.list "$source_parts"/*.sources; do
        [[ -f $file ]] || continue
        if [[ $file != "$source_list" && ! ${file##*/} =~ ^[a-zA-Z0-9_.-]+$ ]]; then
            continue
        fi
        format=legacy
        if [[ $file == *.sources ]]; then format=deb822; fi
        staged="$scratch/apt-source.${#candidates[@]}"
        awk -v codename="$codename" -v components="$components" -v format="$format" \
            -v metadata="$scratch/apt-source.meta" -f "$scratch/apt-sources.awk" "$file" > "$staged"
        read -r seen_network seen_debian changed < "$scratch/apt-source.meta"
        network=$(( network || seen_network ))
        debian=$(( debian || seen_debian ))
        if (( changed )); then
            targets+=("$(readlink -f -- "$file")")
            candidates+=("$staged")
        fi
    done

    if (( ! debian )); then
        (( ! network )) ||
            fail "No active Debian sources for $codename were identified. Check the configured suites and mirrors."
        [[ ! -e $source_list || -f $source_list ]] ||
            fail "Invalid APT sources file: $source_list"
        local keyring=/usr/share/keyrings/debian-archive-keyring.pgp
        if [[ ! -r $keyring ]]; then keyring=/usr/share/keyrings/debian-archive-keyring.gpg; fi
        [[ -r $keyring ]] || fail 'The Debian archive keyring is missing.'
        staged="$scratch/apt-source.default"
        {
            if [[ -s $source_list ]]; then cat -- "$source_list"; printf '\n\n'; fi
            if [[ $source_list == *.sources ]]; then
                printf 'Types: deb\nURIs: http://deb.debian.org/debian\nSuites: %s %s-updates\nComponents: %s\nSigned-By: %s\n\n' \
                    "$codename" "$codename" "$components" "$keyring"
                printf 'Types: deb\nURIs: http://security.debian.org/debian-security\nSuites: %s-security\nComponents: %s\nSigned-By: %s\n' \
                    "$codename" "$components" "$keyring"
            else
                printf 'deb [signed-by=%s] http://deb.debian.org/debian %s %s\n' "$keyring" "$codename" "$components"
                printf 'deb [signed-by=%s] http://deb.debian.org/debian %s-updates %s\n' "$keyring" "$codename" "$components"
                printf 'deb [signed-by=%s] http://security.debian.org/debian-security %s-security %s\n' "$keyring" "$codename" "$components"
            fi
        } > "$staged"
        targets+=("$(readlink -f -- "$source_list")")
        candidates+=("$staged")
    fi

    local i mode
    for i in "${!targets[@]}"; do
        file=${targets[i]}
        mode=644
        if [[ -f $file ]]; then mode=$(stat -c '%a' -- "$file"); fi
        write_config "$file" "$mode" < "${candidates[i]}"
    done
}

upgrade_system() {
    local -a fetch_options=(-o Acquire::Retries=2 -o Acquire::http::Timeout=10)

    timeout 120s apt-get "${fetch_options[@]}" update --error-on=any </dev/null
    DEBIAN_FRONTEND=noninteractive timeout 600s apt-get "${fetch_options[@]}" \
        upgrade -y --with-new-pkgs --download-only </dev/null
    DEBIAN_FRONTEND=noninteractive apt-get \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        upgrade -y --with-new-pkgs --no-download </dev/null
}

install_packages() {
    local package
    local -a missing=()

    for package in "$@"; do
        if [[ $(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null) != installed ]]; then
            missing+=("$package")
        fi
    done
    if (( ${#missing[@]} )); then
        DEBIAN_FRONTEND=noninteractive timeout 180s \
            apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=10 \
            install -y --no-install-recommends --download-only "${missing[@]}" </dev/null
        DEBIAN_FRONTEND=noninteractive apt-get \
            install -y --no-install-recommends --no-download "${missing[@]}" </dev/null
    fi
}

read_host_settings() {
    local current_hostname label
    local -a labels
    if [[ -z $ssh_port ]]; then
        printf 'SSH port [%s]: ' "$default_ssh_port"
        IFS= read -r ssh_port || fail 'Could not read the SSH port.'
        ssh_port=${ssh_port:-$default_ssh_port}
        validate_ssh_port "$ssh_port"
    fi
    current_hostname=$(hostname)
    printf 'Hostname [%s]: ' "$current_hostname"
    IFS= read -r host_name || fail 'Could not read the hostname.'
    if [[ -z $host_name ]]; then return; fi
    [[ ${#host_name} -le 64 && $host_name != .* && $host_name != *. ]] ||
        fail 'Enter a valid hostname of at most 64 characters.'
    IFS=. read -r -a labels <<< "$host_name"
    for label in "${labels[@]}"; do
        [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] ||
            fail 'Enter a hostname made of valid DNS labels.'
    done
}

install_root_key() {
    local public_key=$1 key_type key_data fingerprint
    local directory=/root/.ssh file=/root/.ssh/authorized_keys
    local installed_fingerprints='' candidate="$scratch/root-authorized-keys"

    read -r key_type key_data _ <<< "$public_key"
    [[ $key_type =~ ^(ssh-|ecdsa-|sk-)[a-zA-Z0-9@._+-]+$ &&
        $key_type != *-cert-* && $key_data =~ ^[A-Za-z0-9+/]+={0,2}$ ]] ||
        fail 'Paste one valid OpenSSH public key line.'
    fingerprint=$(ssh-keygen -E sha256 -lf /dev/stdin <<< "$public_key") ||
        fail 'The public key could not be decoded.'
    read -r _ fingerprint _ <<< "$fingerprint"
    [[ ! -L $directory && ! -L $file && ( ! -e $file || -f $file ) ]] ||
        fail "Unexpected path at $directory or $file."

    install -d -o root -g root -m 0700 -- "$directory"
    if [[ -f $file ]]; then
        cp -- "$file" "$candidate"
        installed_fingerprints=$(ssh-keygen -E sha256 -lf "$file" 2>/dev/null) || :
    else
        : > "$candidate"
    fi
    if ! awk -v wanted="$fingerprint" '$2 == wanted { found = 1 } END { exit !found }' <<< "$installed_fingerprints"; then
        if [[ -s $candidate && -n $(tail -c 1 -- "$candidate") ]]; then
            printf '\n' >> "$candidate"
        fi
        printf '%s\n' "$public_key" >> "$candidate"
    fi
    write_config "$file" 600 < "$candidate"
}

configure_root_keys() {
    local public_keys public_key
    install_packages openssh-client
    public_keys=$(timeout 10s ssh-add -L 2>/dev/null) || public_keys=
    if [[ -z $public_keys ]]; then
        if (( non_interactive )); then return; fi
        printf 'Root SSH public key: '
        IFS= read -r public_keys || fail 'Could not read the public key.'
    fi
    while IFS= read -r public_key; do
        install_root_key "$public_key"
    done <<< "$public_keys"

    if (( non_interactive )); then return; fi
    printf 'Additional root SSH public key [Enter to skip]: '
    IFS= read -r public_key || fail 'Could not read the additional public key.'
    if [[ -n $public_key ]]; then
        install_root_key "$public_key"
    fi
}

configure_time_sync() {
    local end

    if [[ $(timedatectl show --property=CanNTP --value) != yes ]]; then
        install_packages systemd-timesyncd
    fi
    if [[ $(timedatectl show --property=NTP --value) != yes ]]; then
        timedatectl set-ntp true
    fi

    end=$(( SECONDS + 60 ))
    while [[ $(timedatectl show --property=NTPSynchronized --value) != yes ]]; do
        if (( SECONDS >= end )); then
            printf 'Clock synchronized: no (after 60 seconds).\n' >&2
            return
        fi
        sleep 1
    done
    printf 'Clock synchronized: yes.\n'
}

configure_security_updates() {
    write_config /etc/apt/apt.conf.d/99-devhost-security-upgrades 644 <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
APT
    install_packages unattended-upgrades
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
}

execution_rules_active() {
    local rules
    rules=$(auditctl -l) || return 1
    grep -Fqx -- '-a always,exit -F arch=b64 -S execve,execveat -F key=process_exec' <<< "$rules" &&
        grep -Fqx -- '-a always,exit -F arch=b32 -S execve,execveat -F key=process_exec' <<< "$rules"
}

configure_auditd() {
    write_config /etc/audit/rules.d/50-devhost-exec.rules 640 <<'AUDIT'
-a always,exit -F arch=b64 -S execve,execveat -k process_exec
-a always,exit -F arch=b32 -S execve,execveat -k process_exec
AUDIT
    systemctl enable --now auditd.service
    systemctl enable audit-rules.service
    if execution_rules_active; then
        augenrules
    else
        augenrules --load
        execution_rules_active || fail 'Execution audit rules did not take effect.'
    fi
    local status
    status=$(auditctl -s)
    if grep -qx 'enabled 0' <<< "$status"; then
        auditctl -e 1
    fi
}

configure_audit_retention() {
    local file=/etc/audit/auditd.conf
    local candidate="$scratch/auditd.conf"
    local settings="$scratch/audit-retention"

    cat > "$settings" <<'AUDIT_RETENTION'
max_log_file = 32
num_logs = 8
max_log_file_action = ROTATE
space_left = 15%
space_left_action = SYSLOG
admin_space_left = 10%
admin_space_left_action = ROTATE
disk_full_action = ROTATE
AUDIT_RETENTION

    awk -F '[[:blank:]]*=[[:blank:]]*' '
        NR == FNR {
            values[$1] = $0
            order[++count] = $1
            next
        }
        {
            name = $1
            sub(/^[[:blank:]]+/, "", name)
            name = tolower(name)
            if (name in values) {
                if (!seen[name]++) print values[name]
            } else {
                print
            }
        }
        END {
            for (i = 1; i <= count; i++) {
                name = order[i]
                if (!seen[name]) print values[name]
            }
        }
    ' "$settings" "$file" > "$candidate"
    if ! cmp -s -- "$candidate" "$file"; then
        write_config "$file" 640 < "$candidate"
        auditctl --signal reload
    fi
}

configure_tty_audit() {
    local service file updated
    local rule='session    required     pam_tty_audit.so disable=* enable=*'

    for service in sshd login; do
        file=/etc/pam.d/$service
        updated=$(awk -v rule="$rule" '
            $0 == rule { next }
            /^[[:blank:]]*session[[:blank:]].*[[:blank:]]pam_tty_audit[.]so([[:blank:]]|$)/ {
                conflict = 1
            }
            { print }
            /^[[:blank:]]*session[[:blank:]].*[[:blank:]]pam_loginuid[.]so([[:blank:]]|$)/ {
                print rule
                loginuid++
            }
            END { if (conflict || loginuid != 1) exit 1 }
        ' "$file") || fail "Unexpected PAM session stack in $file."
        write_config "$file" 644 <<< "$updated"
    done
}

configure_journald() {
    mkdir -p /etc/systemd/journald.conf.d
    write_config /etc/systemd/journald.conf.d/60-devhost.conf 644 <<'JOURNAL'
[Journal]
Storage=persistent
MaxRetentionSec=3month
SystemMaxUse=4G
SystemKeepFree=1G
JOURNAL
    systemctl restart systemd-journald.service
    journalctl --flush
}

configure_login_banner() {
    local motd_dir=/etc/update-motd.d
    local pam_file=/etc/pam.d/sshd
    local login_rule='session    optional     pam_exec.so stdout type=open_session /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /etc/update-motd.d/10-sysinfo --last-login'
    local motd=/etc/motd template=/usr/share/base-files/motd

    [[ ! -L $motd_dir ]] || fail "Unexpected symlink at $motd_dir."
    mkdir -p -- "$motd_dir"
    find "$motd_dir" -xdev -mindepth 1 -delete
    write_config "$motd_dir/10-sysinfo" 755 <<'MOTD'
#!/bin/bash

export LC_ALL=C

if [[ ${1-} == --last-login ]]; then
    login=—
    peer=—
    login_time=—
    separator=$'\037'

    # OpenSSH records the new terminal login only after the PAM session opens.
    if [[ -r /var/log/wtmp.db ]] &&
        record=$(timeout 2s sqlite3 -readonly -batch -init /dev/null -noheader \
            -cmd '.timeout 1500' -list -separator "$separator" /var/log/wtmp.db "
                SELECT User, COALESCE(RemoteHost, ''),
                       strftime('%Y-%m-%d %H:%M:%S UTC', Login / 1000000, 'unixepoch')
                FROM wtmp
                WHERE Type = 3 AND TTY GLOB 'pts/[0-9]*'
                  AND (Service = 'sshd' OR (Service IS NULL AND RemoteHost <> ''))
                ORDER BY Login DESC, ID DESC
                LIMIT 1;
            " 2>/dev/null) && [[ -n $record ]]; then
        IFS=$separator read -r login peer login_time <<< "$record"
        if [[ ! $login_time || $login =~ [[:cntrl:]] ]]; then
            login=—
            peer=—
            login_time=—
        elif [[ ! $peer =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ &&
                ! $peer =~ ^[[:xdigit:].]*:[[:xdigit:].:]+(%[[:alnum:]_.-]+)?$ ]]; then
            peer=—
        fi
    fi

    printf '\n  Last........: %s\n  Last IP.....: %s\n  Last Time...: %s\n\n' \
        "$login" "$peer" "$login_time"
    exit
fi

# get load averages
IFS=" " read LOAD1 LOAD5 LOAD15 <<<$(cat /proc/loadavg | awk '{ print $1,$2,$3 }')
# get free memory
IFS=" " read USED AVAIL TOTAL <<<$(free -htm | grep "Mem" | awk {'print $3,$7,$2'})
# get processes
PROCESS=`ps -eo user=|sort|uniq -c | awk '{ print $2 " " $1 }'`
PROCESS_ALL=`echo "$PROCESS"| awk {'print $2'} | awk '{ SUM += $1} END { print SUM }'`
PROCESS_ROOT=`echo "$PROCESS"| grep root | awk {'print $2'}`
PROCESS_USER=`echo "$PROCESS"| grep -v root | awk {'print $2'} | awk '{ SUM += $1} END { print SUM }'`
# get processors
PROCESSOR_NAME=`grep "model name" /proc/cpuinfo | cut -d ' ' -f3- | awk {'print $0'} | head -1`
PROCESSOR_COUNT=`grep -ioP 'processor\t:' /proc/cpuinfo | wc -l`

W="\e[0;39m"
G="\e[0;34m"

echo -e "
$W  Distro......: $W`cat /etc/*release | grep "PRETTY_NAME" | cut -d "=" -f 2- | sed 's/"//g'`
$W  Kernel......: $W`uname -sr`

$W  Uptime......: $W`uptime -p`
$W  Load........: $G$LOAD1$W (1m), $G$LOAD5$W (5m), $G$LOAD15$W (15m)
$W  Processes...:$W $G$PROCESS_ROOT$W (root), $G$PROCESS_USER$W (user), $G$PROCESS_ALL$W (total)

$W  CPU.........: $W$PROCESSOR_NAME ($G$PROCESSOR_COUNT$W vCPU)
$W  Memory......: $G$USED$W used, $G$AVAIL$W avail, $G$TOTAL$W total$W"

printf '\n  Hostname....: %s\n' "$(hostname)"
for interface in /sys/class/net/*; do
    [[ -e "$interface/device" ]] || continue
    name=${interface##*/}
    ip -o -4 address show dev "$name" |
        awk -v name="$name" '{ printf "  IPv4........: %s %s\n", name, $4 }'
done

resolv_conf=/etc/resolv.conf
if [[ $(readlink -f "$resolv_conf") == /run/systemd/resolve/stub-resolv.conf &&
      -r /run/systemd/resolve/resolv.conf ]]; then
    resolv_conf=/run/systemd/resolve/resolv.conf
fi
if [[ -r $resolv_conf ]]; then
    awk '$1 == "nameserver" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && !seen[$2]++ {
        printf "  DNS.........: %s\n", $2
    }' "$resolv_conf"
fi
MOTD

    if [[ -f $motd ]]; then
        perl -0777 -pe '
            BEGIN {
                my $template = shift @ARGV;
                open my $file, "<", $template or die "$template: $!\n";
                $default = <$file>;
                $default =~ s/\A\n+|\n+\z//g;
                length $default or die "$template is empty\n";
            }
            if (s/^\Q$default\E(?:\n|\z)//mg && !/\S/) { $_ = ""; }
        ' "$template" "$motd" > "$scratch/motd"
        if ! cmp -s -- "$motd" "$scratch/motd"; then
            write_config "$motd" "$(stat -Lc '%a' -- "$motd")" < "$scratch/motd"
        fi
    fi

    # Send the last-login block through this connection's PAM conversation.
    awk -v rule="$login_rule" '
        $0 == rule { next }
        !added && (/^# SELinux needs to intervene at login time/ ||
            (/^session[[:blank:]]/ && /[[:blank:]]pam_selinux[.]so[[:blank:]]+open([[:blank:]]|$)/)) {
            print rule
            added = 1
        }
        { print }
        END { if (!added) print rule }
    ' "$pam_file" > "$scratch/pam-sshd"
    write_config "$pam_file" 644 < "$scratch/pam-sshd"
}

configure_ssh_client() {
    mkdir -p /etc/ssh/ssh_config.d
    write_config /etc/ssh/ssh_config.d/10-devhost.conf 644 <<'SSH_CLIENT'
Host *
    Compression yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
SSH_CLIENT
    local effective
    effective=$(ssh -G -T -F /etc/ssh/ssh_config localhost)
    if ! { grep -qx 'compression yes' <<< "$effective" &&
        grep -qx 'serveraliveinterval 30' <<< "$effective" &&
        grep -qx 'serveralivecountmax 3' <<< "$effective"; }; then
        fail 'System SSH client configuration did not take effect.'
    fi
}

verify_ssh_server_config() {
    local effective
    effective=$(sshd -T) || return 1
    [[ $(awk '$1 == "port" { print $2 }' <<< "$effective") == "$ssh_port" ]] &&
        grep -qx 'usepam yes' <<< "$effective" &&
        grep -qx 'printmotd no' <<< "$effective" &&
        grep -qx 'printlastlog no' <<< "$effective" &&
        grep -qx 'allowagentforwarding yes' <<< "$effective" &&
        grep -qx 'disableforwarding no' <<< "$effective" &&
        grep -qx 'compression yes' <<< "$effective" &&
        grep -qx 'clientaliveinterval 30' <<< "$effective" &&
        grep -qx 'clientalivecountmax 3' <<< "$effective"
}

wait_for_ssh_listener() {
    local end=$(( SECONDS + 10 )) listeners
    while (( SECONDS < end )); do
        listeners=$(ss -H -ltnp "sport = :$ssh_port") || return 1
        if [[ $listeners == *'"sshd"'* ]]; then return 0; fi
        sleep 0.2
    done
    return 1
}

configure_ssh_server() {
    local file=/etc/ssh/sshd_config.d/10-devhost.conf

    mkdir -p /etc/ssh/sshd_config.d
    if [[ -e $file ]]; then
        cp -a -- "$file" "$scratch/sshd.conf"
    fi
    write_config "$file" 644 <<SSH_SERVER
Port $ssh_port
UsePAM yes
PrintMotd no
PrintLastLog no
AllowAgentForwarding yes
Compression yes
ClientAliveInterval 30
ClientAliveCountMax 3
SSH_SERVER

    if sshd -t && verify_ssh_server_config &&
        systemctl enable --now ssh.service &&
        systemctl reload ssh.service && wait_for_ssh_listener; then
        return
    fi

    if [[ -f $scratch/sshd.conf ]]; then
        cp -a -- "$scratch/sshd.conf" "$file"
    else
        rm -- "$file"
    fi
    systemctl reload-or-restart ssh.service ||
        fail 'Could not restore the previous SSH service configuration.'
    fail "Could not activate SSH on port $ssh_port. Previous settings restored."
}

verified_root_key_session() {
    local peer peer_port local_address local_port pid=$BASHPID
    read -r peer peer_port local_address local_port <<< "${SSH_CONNECTION-}"
    [[ -n $peer && $peer_port =~ ^[0-9]+$ &&
        -n $local_address && $local_port =~ ^[0-9]+$ ]] || return 1

    while (( pid > 1 )); do
        if [[ $(< "/proc/$pid/comm") == sshd-session ]] &&
            journalctl -b -u ssh.service "_PID=$pid" --no-pager -o cat | awk \
                -v peer="$peer" -v port="$peer_port" '
                    $1 == "Accepted" && $2 == "publickey" && $4 == "root" &&
                        $6 == peer && $8 == port { found = 1 }
                    END { exit !found }
                '; then
            return 0
        fi
        pid=$(awk '$1 == "PPid:" { print $2 }' "/proc/$pid/status") || return 1
    done
    return 1
}

key_only_policy_active() {
    local effective
    effective=$(sshd -T "$@") || return 1
    grep -qx 'authenticationmethods publickey' <<< "$effective" &&
        grep -qx 'pubkeyauthentication yes' <<< "$effective" &&
        grep -qx 'passwordauthentication no' <<< "$effective" &&
        grep -qx 'kbdinteractiveauthentication no' <<< "$effective" &&
        grep -Eqx 'permitrootlogin (prohibit|without)-password' <<< "$effective"
}

configure_ssh_authentication() {
    local file=/etc/ssh/sshd_config.d/05-devhost-auth.conf
    if ! verified_root_key_session; then
        if key_only_policy_active; then
            printf 'SSH key-only policy: already active.\n'
        else
            printf 'SSH key-only policy deferred. Rerun from a root SSH session authenticated by key.\n'
        fi
        return
    fi

    local peer local_address
    read -r peer _ local_address _ <<< "$SSH_CONNECTION"
    local connection="user=root,host=$peer,addr=$peer,laddr=$local_address,lport=$ssh_port"
    if [[ -e $file ]]; then
        cp -a -- "$file" "$scratch/ssh-auth.conf"
    fi
    write_config "$file" 644 <<'SSH_AUTH'
AuthenticationMethods publickey
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
SSH_AUTH
    if sshd -t && key_only_policy_active && key_only_policy_active -C "$connection" &&
        systemctl reload ssh.service && wait_for_ssh_listener; then
        printf 'SSH key-only policy: active.\n'
        return
    fi

    if [[ -f $scratch/ssh-auth.conf ]]; then
        cp -a -- "$scratch/ssh-auth.conf" "$file"
    else
        rm -- "$file"
    fi
    systemctl reload-or-restart ssh.service ||
        fail 'Could not restore the previous SSH authentication configuration.'
    fail 'Could not activate the SSH key-only policy. Previous settings restored.'
}

configure_security() {
    configure_auditd
    configure_audit_retention
    configure_tty_audit
    configure_journald
    configure_login_banner
    configure_ssh_client
    configure_ssh_server
    configure_ssh_authentication
}

configure_tmux() {
    write_config /etc/tmux.conf 644 <<'TMUX'
set -g mouse on

bind / split-window -h
bind - split-window -v

set-option -g status-style bg=colour235,fg=gray,dim
set-window-option -g window-status-style fg=gray,bg=colour236,dim

set -g pane-active-border-style bg=default,fg=blue
set -g pane-border-style fg=black
set -g status-right '#H'

set -g pane-border-status top
set -g pane-border-format " [ ###P  #T ] "

set-hook -g after-split-window 'selectp -T ""'
set-hook -g after-new-window 'selectp -T ""'
set-hook -g after-new-session 'selectp -T ""'

bind-key . command-prompt -I "#{pane_title}" -p "Pane title:" 'select-pane -T "%%"'

set -g automatic-rename on
set -g automatic-rename-format '#{pane_current_command}'
set -g allow-rename off
TMUX
}

configure_bash() {
    local file=/etc/bash.bashrc
    local begin='# BEGIN devhost managed interactive Bash'
    local end='# END devhost managed interactive Bash'

    awk -v begin="$begin" -v end="$end" '
        $0 == begin { managed = 1; next }
        $0 == end { managed = 0; next }
        !managed { print }
        END { if (managed) exit 1 }
    ' "$file" > "$scratch/bash.bashrc"
    cat >> "$scratch/bash.bashrc" <<'BASHRC'
# BEGIN devhost managed interactive Bash
if [[ $- == *i* ]]; then
    if ! shopt -oq posix && ! declare -F _init_completion >/dev/null; then
        . /usr/share/bash-completion/bash_completion
    fi
    shopt -s histappend checkwinsize
    bind 'set show-all-if-ambiguous on'
    bind 'set completion-ignore-case on'
    bind 'set menu-complete-display-prefix on'
    bind '"\t": menu-complete'
    bind '"\e[A": history-search-backward'
    bind '"\e[B": history-search-forward'

    if ! declare -F __devhost_first_prompt >/dev/null; then
        # Debian reads the user's Bash startup file after the system file.
        __devhost_first_prompt() {
            local status=$? index colors
            colors=$(tput colors 2>/dev/null) || colors=0
            if [[ $colors == 256 ]]; then
                PS1='\[\e[38;5;237m\]\t \[\e[38;5;33m\]\u@\h \[\e[38;5;240m\]\w\[\e[0m\] '
            else
                PS1='\t \u@\h \w '
            fi
            for index in "${!PROMPT_COMMAND[@]}"; do
                if [[ ${PROMPT_COMMAND[index]} == __devhost_first_prompt ]]; then
                    unset 'PROMPT_COMMAND[index]'
                fi
            done
            unset -f __devhost_first_prompt
            return "$status"
        }
        PROMPT_COMMAND+=(__devhost_first_prompt)
    fi
fi
# END devhost managed interactive Bash
BASHRC
    bash -n "$scratch/bash.bashrc"
    write_config "$file" 644 < "$scratch/bash.bashrc"
}

configure_base_software() {
    install_packages auditd openssh-server openssh-client libpam-modules \
        tmux bind9-dnsutils net-tools iperf3 ethtool bash-completion sqlite3 \
        curl mtr-tiny mc htop bwm-ng iptraf-ng zstd
    configure_tmux
    configure_bash
}

verify_network_settings() {
    local key value actual
    local -a expected_fields actual_fields
    while IFS='=' read -r key value; do
        key=${key% }
        read -r -a expected_fields <<< "$value"
        actual=$(sysctl -n "$key") || return 1
        read -r -a actual_fields <<< "$actual"
        if [[ ${actual_fields[*]} != "${expected_fields[*]}" ]]; then
            printf '%s returned %s, expected %s\n' "$key" "${actual_fields[*]}" "${expected_fields[*]}" >&2
            return 1
        fi
    done < "$scratch/10-network.conf"

    local flag
    for flag in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        [[ $(< "$flag") == 1 ]] || return 1
    done
}

configure_network() {
    local config=/etc/sysctl.d/10-network.conf
    local boot_override=/etc/sysctl.d/99-devhost-network.conf
    local key previous

    # Load the same settings after Debian's 50-default.conf at boot.
    if [[ -e $boot_override || -L $boot_override ]]; then
        [[ -L $boot_override && $(readlink -- "$boot_override") == 10-network.conf ]] ||
            fail "Unexpected file at $boot_override."
    fi

    cat > "$scratch/10-network.conf" <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
SYSCTL
    while IFS='=' read -r key _; do
        key=${key% }
        previous=$(sysctl -n "$key")
        printf '%s = %s\n' "$key" "$previous"
    done < "$scratch/10-network.conf" > "$scratch/network.previous"
    if sysctl --load "$scratch/10-network.conf" && verify_network_settings; then
        write_config "$config" 644 < "$scratch/10-network.conf"
        if [[ ! -L $boot_override ]]; then
            ln -s -- 10-network.conf "$boot_override"
        fi
    else
        sysctl --load "$scratch/network.previous" ||
            fail 'Could not restore previous sysctl values.'
        fail 'Could not apply network settings. Previous sysctl values restored.'
    fi
}

initialize_host() (
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    export LC_ALL=C
    local debian_codename lock_fd host_name=
    preflight
    exec {lock_fd}</etc/sysctl.d
    flock -n "$lock_fd" || fail 'Another host initialization is running.'
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    scratch=$(mktemp -d)

    configure_apt_sources "$debian_codename"
    upgrade_system
    if (( ! non_interactive )); then
        read_host_settings
    fi
    configure_root_keys
    if [[ -n $host_name ]]; then
        hostnamectl --static --transient hostname "$host_name"
    fi
    configure_time_sync
    configure_base_software
    configure_network
    configure_security
    configure_security_updates
    printf 'Initialization complete. SSH port: %s\n' "$ssh_port"
    /etc/update-motd.d/10-sysinfo
)

main() {
    parse_args "$@"
    if (( non_interactive )); then
        initialize_host </dev/null
        return
    fi
    if ! ( : </dev/tty ) 2>/dev/null; then
        fail 'Run in a terminal or use --non-interactive.'
    fi
    initialize_host </dev/tty >/dev/tty 2>&1
    exec /bin/bash -i </dev/tty >/dev/tty 2>&1
}

main "$@"
