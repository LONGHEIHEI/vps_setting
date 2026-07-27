download_reinstall_script_if_missing() {
    local url="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"

    if [ -f "reinstall.sh" ]; then
        return 0
    fi

    msg_info "正在下载reinstall.sh脚本..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 5 --max-time 300 -o reinstall.sh "$url" || {
            msg_err "reinstall.sh 下载失败。"
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -O reinstall.sh "$url" || {
            msg_err "reinstall.sh 下载失败。"
            return 1
        }
    else
        msg_err "错误：未找到curl或wget，无法下载脚本。"
        return 1
    fi

    chmod +x reinstall.sh
}

get_ssh_service_name() {
    if [ -n "$SSH_SERVICE_NAME_CACHE" ]; then
        printf '%s\n' "$SSH_SERVICE_NAME_CACHE"
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
        SSH_SERVICE_NAME_CACHE="ssh"
    elif command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
        SSH_SERVICE_NAME_CACHE="sshd"
    elif command -v systemctl >/dev/null 2>&1 && systemctl status ssh >/dev/null 2>&1; then
        SSH_SERVICE_NAME_CACHE="ssh"
    else
        SSH_SERVICE_NAME_CACHE="sshd"
    fi

    printf '%s\n' "$SSH_SERVICE_NAME_CACHE"
}

restart_ssh_service() {
    local ssh_service="${1:-$(get_ssh_service_name)}"
    systemctl restart "$ssh_service" >/dev/null 2>&1 || \
    service "$ssh_service" restart >/dev/null 2>&1
}

enable_ssh_service() {
    local ssh_service="${1:-$(get_ssh_service_name)}"
    systemctl enable "$ssh_service" >/dev/null 2>&1 || true
    systemctl start "$ssh_service" >/dev/null 2>&1 || service "$ssh_service" start >/dev/null 2>&1 || true
}

cleanup_ssh_socket_activation() {
    local socket_conf="/etc/systemd/system/ssh.socket.d/override.conf"
    if systemctl is-active --quiet ssh.socket 2>/dev/null || \
       systemctl is-enabled --quiet ssh.socket 2>/dev/null || \
       [ -f "$socket_conf" ]; then
        systemctl stop ssh.socket >/dev/null 2>&1 || true
        systemctl disable ssh.socket >/dev/null 2>&1 || true
        rm -f "$socket_conf"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

backup_file_with_timestamp() {
    local target_file="$1"
    local backup_root="${SUITE_BACKUP_DIR:-/var/backups/vps-init-suite}"
    local safe_name backup_path

    [ -e "$target_file" ] || return 1
    safe_name=$(printf '%s\n' "$target_file" | sed 's#^/##; s#[^A-Za-z0-9._-]#_#g')
    backup_path="${backup_root}/${safe_name}.bak.$(date +%F_%H%M%S).$$"
    mkdir -p "$backup_root" || return 1
    cp -af "$target_file" "$backup_path"
    if [ "$target_file" = "/etc/ssh/sshd_config" ]; then
        if [ -f "$SSHD_MANAGED_OVERRIDE_FILE" ]; then
            safe_name=$(printf '%s\n' "$SSHD_MANAGED_OVERRIDE_FILE" | sed 's#^/##; s#[^A-Za-z0-9._-]#_#g')
            LAST_SSHD_OVERRIDE_BACKUP="${backup_root}/${safe_name}.bak.$(date +%F_%H%M%S).$$"
            cp -af "$SSHD_MANAGED_OVERRIDE_FILE" "$LAST_SSHD_OVERRIDE_BACKUP"
        else
            LAST_SSHD_OVERRIDE_BACKUP="__ABSENT__"
        fi
    fi
    echo "$backup_path"
}

ensure_sshd_managed_override_include() {
    local tmp_file
    mkdir -p /etc/ssh
    touch /etc/ssh/sshd_config
    touch "$SSHD_MANAGED_OVERRIDE_FILE"
    tmp_file=$(mktemp) || {
        msg_err "创建临时文件失败，无法调整 sshd Include 顺序。"
        return 1
    }

    {
        printf 'Include %s\n' "$SSHD_MANAGED_OVERRIDE_FILE"
        awk -v line="Include ${SSHD_MANAGED_OVERRIDE_FILE}" '
            $0 == line { next }
            { print }
        ' /etc/ssh/sshd_config
    } > "$tmp_file" || {
        rm -f "$tmp_file"
        msg_err "重写 /etc/ssh/sshd_config 失败。"
        return 1
    }

    cat "$tmp_file" > /etc/ssh/sshd_config || {
        rm -f "$tmp_file"
        msg_err "写回 /etc/ssh/sshd_config 失败。"
        return 1
    }

    rm -f "$tmp_file"
}

restore_sshd_backup_state() {
    local ssh_backup="$1"
    [ -n "$ssh_backup" ] && [ -f "$ssh_backup" ] && cp -af "$ssh_backup" /etc/ssh/sshd_config

    case "$LAST_SSHD_OVERRIDE_BACKUP" in
        "__ABSENT__")
            rm -f "$SSHD_MANAGED_OVERRIDE_FILE"
            ;;
        "")
            ;;
        *)
            [ -f "$LAST_SSHD_OVERRIDE_BACKUP" ] && cp -af "$LAST_SSHD_OVERRIDE_BACKUP" "$SSHD_MANAGED_OVERRIDE_FILE"
            ;;
    esac
}

backup_ssh_banner_file() {
    local target="$SSH_LOGIN_BANNER_PROFILE_FILE"

    if [ -f "$target" ]; then
        LAST_SSH_BANNER_BACKUP=$(backup_file_with_timestamp "$target") || return 1
    else
        LAST_SSH_BANNER_BACKUP="__ABSENT__"
    fi
}

restore_ssh_banner_backup_state() {
    local target="$SSH_LOGIN_BANNER_PROFILE_FILE"

    case "$LAST_SSH_BANNER_BACKUP" in
        "__ABSENT__")
            rm -f "$target"
            ;;
        "")
            ;;
        *)
            [ -f "$LAST_SSH_BANNER_BACKUP" ] && cp -af "$LAST_SSH_BANNER_BACKUP" "$target"
            ;;
    esac
}

restore_ssh_pam_backup_state() {
    case "$LAST_SSH_PAM_BACKUP" in
        "__ABSENT__")
            rm -f /etc/pam.d/sshd
            ;;
        "")
            ;;
        *)
            [ -f "$LAST_SSH_PAM_BACKUP" ] && cp -af "$LAST_SSH_PAM_BACKUP" /etc/pam.d/sshd
            ;;
    esac
}

restore_ssh_login_message_backup_state() {
    local ssh_backup="${1:-}"
    local ssh_service

    restore_sshd_backup_state "$ssh_backup"
    restore_ssh_pam_backup_state
    restore_ssh_banner_backup_state

    ssh_service=$(get_ssh_service_name)
    restart_ssh_service "$ssh_service" >/dev/null 2>&1 || true
}

set_sshd_directive() {
    local key="$1"
    local value="$2"
    local config_file="${3:-$SSHD_MANAGED_OVERRIDE_FILE}"
    if [ "$config_file" = "$SSHD_MANAGED_OVERRIDE_FILE" ]; then
        ensure_sshd_managed_override_include || return 1
    fi
    sed -i "/^[[:space:]#]*${key}[[:space:]]\\+/Id" "$config_file" || return 1
    printf '%s %s\n' "$key" "$value" >> "$config_file" || return 1
}

delete_sshd_directive() {
    local key="$1"
    local config_file="${2:-$SSHD_MANAGED_OVERRIDE_FILE}"
    if [ "$config_file" = "$SSHD_MANAGED_OVERRIDE_FILE" ]; then
        ensure_sshd_managed_override_include || return 1
    fi
    sed -i "/^[[:space:]#]*${key}[[:space:]]\\+/Id" "$config_file" || return 1
}

disable_ssh_pam_motd() {
    local pam_file="/etc/pam.d/sshd"
    local tmp_file backup_path

    [ -f "$pam_file" ] || return 0
    grep -Eq '^[[:space:]]*session[[:space:]].*pam_motd\.so' "$pam_file" || return 0

    backup_path=$(backup_file_with_timestamp "$pam_file") || {
        msg_err "备份 sshd PAM 配置失败：${pam_file}"
        return 1
    }
    LAST_SSH_PAM_BACKUP="$backup_path"

    tmp_file=$(mktemp) || {
        msg_err "创建临时文件失败，无法调整 sshd PAM MOTD。"
        return 1
    }

    awk '
        /^[[:space:]]*session[[:space:]].*pam_motd\.so/ {
            print "# Disabled by VPS init suite: " $0
            next
        }
        { print }
    ' "$pam_file" > "$tmp_file" || {
        rm -f "$tmp_file"
        msg_err "重写 sshd PAM 配置失败：${pam_file}"
        return 1
    }

    cp -af "$tmp_file" "$pam_file" || {
        rm -f "$tmp_file"
        msg_err "写回 sshd PAM 配置失败：${pam_file}"
        return 1
    }
    rm -f "$tmp_file"

    msg_info "已禁用 sshd PAM MOTD：${pam_file}"
    msg_info "旧 PAM 配置已备份：${backup_path}"
}

disable_ssh_builtin_login_messages() {
    local ssh_service

    set_sshd_directive "PrintMotd" "no" || return 1
    set_sshd_directive "PrintLastLog" "no" || return 1

    if command -v sshd >/dev/null 2>&1 && sshd -T 2>/dev/null | grep -qi '^debianbanner '; then
        set_sshd_directive "DebianBanner" "no" || return 1
    fi

    disable_ssh_pam_motd || return 1

    if command -v sshd >/dev/null 2>&1 && ! sshd -t; then
        msg_err "sshd 配置校验失败，未能静默系统自带登录信息。"
        return 1
    fi

    ssh_service=$(get_ssh_service_name)
    restart_ssh_service "$ssh_service" || {
        msg_err "SSH 服务重启失败，系统自带登录信息可能仍会显示。"
        return 1
    }

    msg_info "已静默系统自带 SSH 登录信息：MOTD / Last login / DebianBanner"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

prompt_password_twice() {
    local prompt_label="$1"
    local __resultvar="$2"
    local p1 p2
    while true; do
        read -s -p "请输入${prompt_label}密码: " p1; echo
        read -s -p "请再次输入${prompt_label}密码以确认: " p2; echo
        if [ -z "$p1" ]; then
            msg_warn "密码不能为空。"
            continue
        fi
        if [ "$p1" != "$p2" ]; then
            msg_warn "两次输入的密码不一致。"
            continue
        fi
        printf -v "$__resultvar" '%s' "$p1"
        return 0
    done
}

ensure_ssh_server_installed() {
    if command -v sshd >/dev/null 2>&1; then
        return 0
    fi
    msg_warn "未检测到 openssh-server，正在尝试自动安装..."
    pkg_update || true
    pkg_install openssh-server || {
        msg_err "openssh-server 安装失败，请手动检查。"
        return 1
    }
    command -v sshd >/dev/null 2>&1
}

ensure_user_in_admin_group() {
    local username="$1"
    if getent group sudo >/dev/null 2>&1; then
        usermod -aG sudo "$username"
    elif getent group wheel >/dev/null 2>&1; then
        usermod -aG wheel "$username"
    else
        msg_warn "未检测到 sudo/wheel 组，跳过管理员组设置。"
    fi
}

get_user_home_dir() {
    local username="$1"
    getent passwd "$username" | awk -F: '{print $6; exit}'
}

get_user_primary_group() {
    local username="$1"
    getent passwd "$username" | awk -F: '{print $4; exit}'
}

is_valid_system_username() {
    local username="$1"
    [[ "$username" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]]
}

append_unique_word() {
    local list="$1"
    local word="$2"

    [ -n "$word" ] || {
        printf '%s\n' "$list"
        return 0
    }

    if [[ " ${list} " == *" ${word} "* ]]; then
        printf '%s\n' "$list"
    elif [ -n "$list" ]; then
        printf '%s %s\n' "$list" "$word"
    else
        printf '%s\n' "$word"
    fi
}

get_default_ssh_key_check_users() {
    local users="" candidate

    for candidate in "${SUDO_USER:-}" "${USER:-}" "${LOGNAME:-}" root; do
        [ -n "$candidate" ] || continue
        [ "$candidate" = "root" ] || id "$candidate" >/dev/null 2>&1 || continue
        users=$(append_unique_word "$users" "$candidate")
    done

    printf '%s\n' "${users:-root}"
}

get_ssh_key_check_users() {
    local allow_users="$1"

    if [ -n "$allow_users" ]; then
        printf '%s\n' "$allow_users"
    else
        get_default_ssh_key_check_users
    fi
}

is_valid_ssh_public_key() {
    local public_key="$1"
    [[ "$public_key" =~ ^(sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com|ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]
}

authorized_keys_has_public_key() {
    local auth_file="$1"
    [ -f "$auth_file" ] || return 1

    awk '
        /^[[:space:]]*($|#)/ { next }
        /(^|[[:space:],])(sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com|ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]]+[A-Za-z0-9+\/=]+/ {
            found=1
            exit
        }
        END { exit(found ? 0 : 1) }
    ' "$auth_file"
}

fix_user_ssh_key_permissions() {
    local username="$1"
    local home_dir="$2"
    local ssh_dir="${home_dir}/.ssh"
    local auth_file="${ssh_dir}/authorized_keys"
    local primary_group

    primary_group=$(get_user_primary_group "$username")
    [ -n "$primary_group" ] || primary_group="$username"

    mkdir -p "$ssh_dir" || return 1
    touch "$auth_file" || return 1
    chown "$username:$primary_group" "$ssh_dir" "$auth_file" 2>/dev/null || chown "$username" "$ssh_dir" "$auth_file"
    chmod go-w "$home_dir" 2>/dev/null || true
    chmod 700 "$ssh_dir"
    chmod 600 "$auth_file"
}

ensure_user_has_ssh_public_key() {
    local username="$1"
    local home_dir ssh_dir auth_file public_key

    if ! id "$username" >/dev/null 2>&1; then
        msg_err "用户不存在：${username}"
        return 1
    fi

    home_dir=$(get_user_home_dir "$username")
    if [ -z "$home_dir" ] || [ ! -d "$home_dir" ]; then
        msg_err "用户 ${username} 的 Home 目录不存在：${home_dir:-未知}"
        return 1
    fi

    ssh_dir="${home_dir}/.ssh"
    auth_file="${ssh_dir}/authorized_keys"

    if authorized_keys_has_public_key "$auth_file"; then
        fix_user_ssh_key_permissions "$username" "$home_dir" || {
            msg_err "修复 ${auth_file} 权限失败。"
            return 1
        }
        msg_ok "已检测到 ${username} 的 authorized_keys，并修复权限。"
        return 0
    fi

    msg_warn "未检测到 ${username} 的可用 SSH 公钥：${auth_file}"
    if ! confirm "现在为 ${username} 粘贴一条 SSH 公钥，否则启用仅密钥登录可能导致无法登录"; then
        msg_err "已取消：没有可用公钥，未应用仅密钥登录配置。"
        return 1
    fi

    while true; do
        read -r -p "请粘贴 SSH 公钥: " public_key
        if is_valid_ssh_public_key "$public_key"; then
            break
        fi
        msg_warn "公钥格式无效，请粘贴 ssh-ed25519 / ssh-rsa / ecdsa / FIDO sk-* 开头的单行公钥。"
    done

    fix_user_ssh_key_permissions "$username" "$home_dir" || {
        msg_err "创建或修复 ${auth_file} 权限失败。"
        return 1
    }
    printf '%s\n' "$public_key" >> "$auth_file"
    fix_user_ssh_key_permissions "$username" "$home_dir" || return 1
    msg_ok "已写入 ${auth_file}"
}

apply_ssh_key_only_login_config() {
    local allow_users="$1"
    local ssh_backup username key_check_users

    ensure_ssh_server_installed || return 1

    key_check_users=$(get_ssh_key_check_users "$allow_users")
    for username in $key_check_users; do
        ensure_user_has_ssh_public_key "$username" || return 1
    done

    if [ -z "$allow_users" ]; then
        msg_warn "未指定 AllowUsers，将仅限制认证方式，不额外限制可登录用户。"
        msg_info "已确认密钥登录用户: ${key_check_users}"
    fi

    ssh_backup=$(backup_file_with_timestamp /etc/ssh/sshd_config) || {
        msg_err "备份 sshd 配置失败。"
        return 1
    }

    set_sshd_directive "PubkeyAuthentication" "yes"
    set_sshd_directive "PasswordAuthentication" "no"
    set_sshd_directive "KbdInteractiveAuthentication" "no"
    set_sshd_directive "ChallengeResponseAuthentication" "no"
    set_sshd_directive "PermitEmptyPasswords" "no"
    set_sshd_directive "AuthenticationMethods" "publickey"
    set_sshd_directive "PermitRootLogin" "prohibit-password"

    if [ -n "$allow_users" ]; then
        set_sshd_directive "AllowUsers" "$allow_users"
    else
        delete_sshd_directive "AllowUsers"
    fi

    apply_sshd_changes "已启用仅 SSH 密钥登录" "$ssh_backup" || return 1

    if [ -n "$allow_users" ]; then
        msg_info "允许的密钥登录用户: ${allow_users}"
    fi
    msg_warn "请立即新开终端测试密钥登录，确认成功后再关闭当前会话。"
}

get_ssh_login_banner_status() {
    if [ -f "$SSH_LOGIN_BANNER_PROFILE_FILE" ]; then
        echo "已启用"
    else
        echo "未启用"
    fi
}

install_ssh_login_banner() {
    local target="$SSH_LOGIN_BANNER_PROFILE_FILE"
    local ssh_backup=""

    ssh_backup=$(backup_file_with_timestamp /etc/ssh/sshd_config) || {
        msg_err "备份 sshd 配置失败。"
        return 1
    }
    LAST_SSH_PAM_BACKUP=""
    LAST_SSH_BANNER_BACKUP=""
    backup_ssh_banner_file || {
        msg_err "备份旧 Banner 脚本失败：${target}"
        return 1
    }

    disable_ssh_builtin_login_messages || {
        msg_err "系统自带 SSH 登录信息静默失败，正在回滚。"
        restore_ssh_login_message_backup_state "$ssh_backup"
        return 1
    }

    mkdir -p /etc/profile.d || {
        msg_err "创建 /etc/profile.d 失败。"
        restore_ssh_login_message_backup_state "$ssh_backup"
        return 1
    }

    cat > "$target" <<'EOF' || {
# Managed by VPS init suite.
# SSH-only dynamic login banner. System MOTD and LastLog are silenced
# separately by the installer so this banner remains the only login notice.

_vps_ssh_login_banner_main() {
local up days hours mins total available used percent primary_ip
local c_reset c_dim c_bold c_cyan c_green c_yellow c_blue
local banner_host banner_os banner_kernel banner_time banner_uptime banner_load
local banner_memory banner_disk banner_ipv4 banner_ipv6 banner_source_ip

if [ -n "${VPS_SSH_LOGIN_BANNER_SHOWN:-}" ]; then
    return 0 2>/dev/null || exit 0
fi

case "$-" in
    *i*) ;;
    *) return 0 2>/dev/null || exit 0 ;;
esac

[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] || return 0 2>/dev/null || exit 0
export VPS_SSH_LOGIN_BANNER_SHOWN=1

vps_banner_os() {
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        printf '%s\n' "${PRETTY_NAME:-unknown}"
    else
        printf 'unknown\n'
    fi
}

vps_banner_uptime() {
    if [ -r /proc/uptime ]; then
        read -r up _ < /proc/uptime
        up=${up%.*}
        days=$((up / 86400))
        hours=$(((up % 86400) / 3600))
        mins=$(((up % 3600) / 60))
        if [ "$days" -gt 0 ]; then
            printf '%sd %sh %sm\n' "$days" "$hours" "$mins"
        else
            printf '%sh %sm\n' "$hours" "$mins"
        fi
    else
        printf 'N/A\n'
    fi
}

vps_banner_memory() {
    total=0
    available=0
    if [ -r /proc/meminfo ]; then
        while read -r key value unit; do
            case "$key" in
                MemTotal:) total=$value ;;
                MemAvailable:) available=$value ;;
            esac
        done < /proc/meminfo
    fi

    if [ "$total" -gt 0 ]; then
        used=$((total - available))
        percent=$((used * 100 / total))
        printf '%s/%s MiB (%s%%)\n' "$((used / 1024))" "$((total / 1024))" "$percent"
    else
        printf 'N/A\n'
    fi
}

vps_banner_disk() {
    if command -v df >/dev/null 2>&1; then
        df -hP / 2>/dev/null | awk 'NR == 2 { print $3 "/" $2 " (" $5 ")" }'
    else
        printf 'N/A\n'
    fi
}

vps_banner_load() {
    if [ -r /proc/loadavg ]; then
        read -r load_1 load_5 load_15 _ < /proc/loadavg
        printf '%s %s %s\n' "$load_1" "$load_5" "$load_15"
    else
        printf 'N/A\n'
    fi
}

vps_banner_ipv4() {
    if command -v ip >/dev/null 2>&1; then
        primary_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i == "src") {
                        print $(i + 1)
                        exit
                    }
                }
            }
        ')
        if [ -n "$primary_ip" ]; then
            printf '%s\n' "$primary_ip"
            return
        fi

        ip -o -4 addr show scope global 2>/dev/null | awk '
            $2 ~ /^(lo|docker|br-|veth|virbr|wg|tun|tap)/ { next }
            {
                split($4, addr, "/")
                out = out ? out ", " addr[1] : addr[1]
            }
            END { print out ? out : "N/A" }
        '
    elif command -v hostname >/dev/null 2>&1; then
        hostname -I 2>/dev/null | awk '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^[0-9]+\./) {
                        out = out ? out ", " $i : $i
                    }
                }
            }
            END { print out ? out : "N/A" }
        '
    else
        printf 'N/A\n'
    fi
}

vps_banner_ipv6() {
    if command -v ip >/dev/null 2>&1; then
        primary_ip=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i == "src") {
                        print $(i + 1)
                        exit
                    }
                }
            }
        ')
        if [ -n "$primary_ip" ]; then
            printf '%s\n' "$primary_ip"
            return
        fi

        ip -o -6 addr show scope global 2>/dev/null | awk '
            $2 ~ /^(lo|docker|br-|veth|virbr|wg|tun|tap)/ { next }
            {
                split($4, addr, "/")
                out = out ? out ", " addr[1] : addr[1]
            }
            END { print out ? out : "N/A" }
        '
    elif command -v hostname >/dev/null 2>&1; then
        hostname -I 2>/dev/null | awk '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /:/) {
                        out = out ? out ", " $i : $i
                    }
                }
            }
            END { print out ? out : "N/A" }
        '
    else
        printf 'N/A\n'
    fi
}

vps_banner_source_ip() {
    if [ -n "${SSH_CONNECTION:-}" ]; then
        set -- $SSH_CONNECTION
        printf '%s\n' "${1:-N/A}"
    else
        printf 'N/A\n'
    fi
}

vps_banner_color_init() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
        c_reset="$(printf '\033[0m')"
        c_dim="$(printf '\033[2m')"
        c_bold="$(printf '\033[1m')"
        c_cyan="$(printf '\033[36m')"
        c_green="$(printf '\033[32m')"
        c_yellow="$(printf '\033[33m')"
        c_blue="$(printf '\033[34m')"
    else
        c_reset=''
        c_dim=''
        c_bold=''
        c_cyan=''
        c_green=''
        c_yellow=''
        c_blue=''
    fi
}

vps_banner_row() {
    printf '%b|%b %b%s%b %s\n' "$c_blue" "$c_reset" "$c_dim" "$1" "$c_reset" "$2"
}

vps_banner_color_init
banner_host="$(hostname 2>/dev/null || printf 'unknown')"
banner_os="$(vps_banner_os)"
banner_kernel="$(uname -r 2>/dev/null || printf 'unknown')"
banner_time="$(date '+%F %T %Z' 2>/dev/null || printf 'unknown')"
banner_uptime="$(vps_banner_uptime)"
banner_load="$(vps_banner_load)"
banner_memory="$(vps_banner_memory)"
banner_disk="$(vps_banner_disk)"
banner_ipv4="$(vps_banner_ipv4)"
banner_ipv6="$(vps_banner_ipv6)"
banner_source_ip="$(vps_banner_source_ip)"

printf '\n'
printf '%b+------------------------------------------------------------+%b\n' "$c_blue" "$c_reset"
printf '%b|%b %bVPS SSH 登录%b\n' "$c_blue" "$c_reset" "$c_bold$c_cyan" "$c_reset"
printf '%b|%b %b%s@%s%b\n' "$c_blue" "$c_reset" "$c_green" "${USER:-unknown}" "$banner_host" "$c_reset"
printf '%b+------------------------------------------------------------+%b\n' "$c_blue" "$c_reset"
vps_banner_row "系统      " "$banner_os"
vps_banner_row "内核      " "$banner_kernel"
vps_banner_row "时间      " "$banner_time"
printf '%b+-------------------------- 运行状态 --------------------------+%b\n' "$c_blue" "$c_reset"
vps_banner_row "运行时间  " "$banner_uptime"
vps_banner_row "负载      " "$banner_load"
vps_banner_row "内存      " "$banner_memory"
vps_banner_row "根分区    " "$banner_disk"
printf '%b+-------------------------- 网络信息 --------------------------+%b\n' "$c_blue" "$c_reset"
vps_banner_row "IPv4      " "$banner_ipv4"
vps_banner_row "IPv6      " "$banner_ipv6"
vps_banner_row "来源 IP   " "$banner_source_ip"
printf '%b+------------------------------------------------------------+%b\n' "$c_blue" "$c_reset"
printf '\n'
}

_vps_ssh_login_banner_main
unset -f _vps_ssh_login_banner_main
unset -f vps_banner_os vps_banner_uptime vps_banner_memory vps_banner_disk vps_banner_load vps_banner_ipv4 vps_banner_ipv6 vps_banner_source_ip vps_banner_color_init vps_banner_row
EOF
        msg_err "写入 Banner 脚本失败：${target}"
        restore_ssh_login_message_backup_state "$ssh_backup"
        return 1
    }

    chmod 644 "$target" || {
        msg_err "设置 Banner 脚本权限失败：${target}"
        restore_ssh_login_message_backup_state "$ssh_backup"
        return 1
    }

    msg_ok "SSH 动态登录 Banner 已启用：${target}"
    msg_info "实现方式：仅 SSH 交互登录时由 /etc/profile.d 脚本动态输出。"
    msg_info "已静默 Debian/OpenSSH 自带 MOTD、Last login 与 DebianBanner。"
    [ -n "$ssh_backup" ] && msg_info "sshd 配置备份：${ssh_backup}"
    case "$LAST_SSH_PAM_BACKUP" in
        ""|"__ABSENT__") ;;
        *) msg_info "PAM 配置备份：${LAST_SSH_PAM_BACKUP}" ;;
    esac
    case "$LAST_SSH_BANNER_BACKUP" in
        ""|"__ABSENT__") ;;
        *) msg_warn "旧 Banner 已备份：${LAST_SSH_BANNER_BACKUP}" ;;
    esac
    return 0
}

handle_selinux_ssh_port() {
    local port="$1"
    local pkg_mgr

    if ! command -v getenforce >/dev/null 2>&1; then
        return 0
    fi
    if [ "$(getenforce 2>/dev/null || true)" != "Enforcing" ]; then
        return 0
    fi

    if ! command -v semanage >/dev/null 2>&1; then
        pkg_mgr=$(get_pkg_manager)
        msg_info "检测到 SELinux=Enforcing，正在补装 semanage..."
        case "$pkg_mgr" in
            dnf) pkg_install policycoreutils-python-utils || true ;;
            yum) pkg_install policycoreutils-python policycoreutils-python-utils || true ;;
            apt) pkg_install policycoreutils python3-semanage || true ;;
        esac
    fi

    if ! command -v semanage >/dev/null 2>&1; then
        msg_err "SELinux 正在 Enforcing，但 semanage 不可用，无法安全放行 SSH 端口 ${port}。"
        return 1
    fi

    if ! semanage port -l | awk '/^ssh_port_t[[:space:]]+tcp/ {print}' | grep -qw "$port"; then
        semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null || \
        semanage port -m -t ssh_port_t -p tcp "$port"
    fi
    return 0
}

disable_other_firewalls_quiet() {
    if systemctl list-unit-files 2>/dev/null | grep -q '^firewalld\.service'; then
        systemctl stop firewalld >/dev/null 2>&1 || true
        systemctl disable firewalld >/dev/null 2>&1 || true
        systemctl mask firewalld >/dev/null 2>&1 || true
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw disable >/dev/null 2>&1 || true
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^ufw\.service'; then
        systemctl stop ufw >/dev/null 2>&1 || true
        systemctl disable ufw >/dev/null 2>&1 || true
        systemctl mask ufw >/dev/null 2>&1 || true
    fi

    if command -v nft >/dev/null 2>&1; then
        nft flush ruleset >/dev/null 2>&1 || true
        printf '#!/usr/sbin/nft -f\nflush ruleset\n' > /etc/nftables.conf 2>/dev/null || true
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^nftables\.service'; then
        systemctl stop nftables >/dev/null 2>&1 || true
        systemctl disable nftables >/dev/null 2>&1 || true
        systemctl mask nftables >/dev/null 2>&1 || true
    fi
}

# 检查是否安装 fail2ban
check_fail2ban() {
    if command -v fail2ban-client &>/dev/null; then
        echo "已安装"
    else
        echo "未安装"
    fi
}

ensure_fail2ban_installed() {
    if command -v fail2ban-client >/dev/null 2>&1; then
        return 0
    fi
    msg_info "未检测到 Fail2Ban，正在尝试自动安装..."
    pkg_update || true
    pkg_install fail2ban || {
        msg_err "Fail2Ban 安装失败，请检查软件源或系统兼容性。"
        return 1
    }
    command -v fail2ban-client >/dev/null 2>&1
}

get_fail2ban_sshd_backend() {
    if command -v journalctl >/dev/null 2>&1 && \
       command -v python3 >/dev/null 2>&1 && \
       python3 - <<'PY' >/dev/null 2>&1
import systemd.journal
PY
    then
        echo "systemd"
    else
        echo "auto"
    fi
}

get_fail2ban_banaction() {
    local backend
    backend=$(detect_firewall_backend 2>/dev/null || true)

    if [ "$backend" = "nft" ]; then
        if [ -f /etc/fail2ban/action.d/nftables-multiport.conf ]; then
            echo "nftables-multiport"
        elif [ -f /etc/fail2ban/action.d/nftables.conf ]; then
            echo "nftables"
        else
            echo "iptables-multiport"
        fi
    elif [ -f /etc/fail2ban/action.d/iptables-multiport.conf ]; then
        echo "iptables-multiport"
    elif [ -f /etc/fail2ban/action.d/iptables-allports.conf ]; then
        echo "iptables-allports"
    else
        echo "iptables-multiport"
    fi
}

write_fail2ban_jail_local() {
    local ports="$1"
    local f2b_backend="$2"
    local f2b_banaction="$3"
    local jail_local="${FAIL2BAN_SSH_JAIL_FILE:-/etc/fail2ban/jail.local}"
    local legacy_jaild="${FAIL2BAN_LEGACY_JAILD_FILE:-/etc/fail2ban/jail.d/vps-init-suite-sshd.local}"
    local backup_file tmp_file legacy_backup

    mkdir -p /etc/fail2ban
    command -v python3 >/dev/null 2>&1 || {
        msg_err "未检测到 python3，无法安全更新 ${jail_local}。"
        return 1
    }

    if [ -f "$jail_local" ]; then
        backup_file="${jail_local}.bak.$(date +%F_%H%M%S)"
        cp -af "$jail_local" "$backup_file" || {
            msg_err "备份 ${jail_local} 失败。"
            return 1
        }
    else
        backup_file="新建文件"
        : > "$jail_local" || {
            msg_err "创建 ${jail_local} 失败。"
            return 1
        }
    fi

    tmp_file=$(mktemp) || {
        msg_err "创建临时文件失败，无法更新 ${jail_local}。"
        return 1
    }

    python3 - "$jail_local" "$tmp_file" <<'PY' || {
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
lines = src.read_text(errors="ignore").splitlines(True)

out = []
in_managed = False
in_default_block = False

for line in lines:
    stripped = line.strip()
    if stripped == "# VPS init suite migrated legacy [sshd] block to jail.d/vps-init-suite-sshd.local":
        continue
    if stripped == "# VPS-INIT-SUITE-FAIL2BAN-START":
        in_managed = True
        continue
    if in_managed:
        if stripped == "# VPS-INIT-SUITE-FAIL2BAN-END":
            in_managed = False
        continue
    if stripped == "#DEFAULT-START":
        in_default_block = True
        continue
    if in_default_block:
        if stripped == "#DEFAULT-END":
            in_default_block = False
        continue
    out.append(line)

sections = []
prelude = []
current_header = None
current_body = []

def push_section():
    if current_header is not None:
        sections.append((current_header, current_body.copy()))

for line in out:
    if re.match(r"^\s*\[[^]]+\]\s*$", line):
        push_section()
        current_header = line
        current_body = []
    else:
        if current_header is None:
            prelude.append(line)
        else:
            current_body.append(line)
push_section()

result = []
result.extend(prelude)
for header, body in sections:
    name = header.strip().strip("[]").strip().lower()
    if name == "sshd":
        result.append("# VPS init suite disabled previous [sshd] block; managed block is appended below.\n")
        for legacy_line in [header, *body]:
            if legacy_line.strip():
                result.append("# " + legacy_line)
            else:
                result.append(legacy_line)
        if result and not result[-1].endswith("\n"):
            result[-1] += "\n"
        continue
    result.append(header)
    result.extend(body)

text = "".join(result).rstrip() + "\n\n"
dst.write_text(text)
PY
        rm -f "$tmp_file"
        return 1
    }

    cat >> "$tmp_file" <<EOF
# VPS-INIT-SUITE-FAIL2BAN-START
[sshd]
enabled = true
filter = sshd
port = ${ports}
protocol = tcp
logpath = %(sshd_log)s
backend = ${f2b_backend}
banaction = ${f2b_banaction}
action = %(action_)s
maxretry = 5
findtime = 10m
bantime = 1h
EOF
    if [ "$f2b_backend" = "systemd" ]; then
        cat >> "$tmp_file" <<'EOF'
journalmatch = _COMM=sshd
EOF
    fi
    cat >> "$tmp_file" <<'EOF'
# VPS-INIT-SUITE-FAIL2BAN-END
EOF

    cat "$tmp_file" > "$jail_local" || {
        rm -f "$tmp_file"
        msg_err "写回 ${jail_local} 失败。"
        return 1
    }
    rm -f "$tmp_file"

    local legacy_candidate
    for legacy_candidate in "$legacy_jaild" "${legacy_jaild}".*; do
        [ -f "$legacy_candidate" ] || continue
        mkdir -p /var/backups/fail2ban 2>/dev/null || true
        legacy_backup="/var/backups/fail2ban/$(basename "$legacy_candidate").disabled.$(date +%F_%H%M%S)"
        mv "$legacy_candidate" "$legacy_backup" 2>/dev/null || rm -f "$legacy_candidate"
        msg_ok "已停用旧独立配置文件：${legacy_backup}"
    done

    msg_ok "Fail2Ban SSH 配置已写入 ${jail_local}（备份：${backup_file}）"
}

remove_fail2ban_managed_jail_local() {
    local jail_local="${FAIL2BAN_SSH_JAIL_FILE:-/etc/fail2ban/jail.local}"
    local legacy_jaild="${FAIL2BAN_LEGACY_JAILD_FILE:-/etc/fail2ban/jail.d/vps-init-suite-sshd.local}"
    local backup_file tmp_file

    [ -f "$jail_local" ] || { rm -f "$legacy_jaild"; return 0; }
    command -v python3 >/dev/null 2>&1 || return 0

    backup_file="${jail_local}.bak.$(date +%F_%H%M%S)"
    cp -af "$jail_local" "$backup_file" || return 1
    tmp_file=$(mktemp) || return 1

    python3 - "$jail_local" "$tmp_file" <<'PY' || { rm -f "$tmp_file"; return 1; }
import sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
lines = src.read_text(errors="ignore").splitlines(True)
out = []
in_managed = False
for line in lines:
    stripped = line.strip()
    if stripped == "# VPS-INIT-SUITE-FAIL2BAN-START":
        in_managed = True
        continue
    if in_managed:
        if stripped == "# VPS-INIT-SUITE-FAIL2BAN-END":
            in_managed = False
        continue
    out.append(line)
dst.write_text("".join(out).rstrip() + "\n")
PY
    cat "$tmp_file" > "$jail_local" || { rm -f "$tmp_file"; return 1; }
    rm -f "$tmp_file"
    rm -f "$legacy_jaild" "${legacy_jaild}".*
    msg_ok "已移除 Fail2Ban 托管配置（备份：${backup_file}）"
}

# 更新 fail2ban 中 sshd jail 的端口配置并重启/重载 fail2ban
update_fail2ban_ssh_port() {
    local ports="$1"
    local f2b_backend f2b_banaction
    [ -z "$ports" ] && ports=$(get_current_ssh_ports_csv)

    if ! command -v fail2ban-client &>/dev/null; then
        msg_warn "未检测到 Fail2Ban，跳过 SSH 端口同步。"
        return 1
    fi

    f2b_backend=$(get_fail2ban_sshd_backend)
    f2b_banaction=$(get_fail2ban_banaction)

    write_fail2ban_jail_local "$ports" "$f2b_backend" "$f2b_banaction" || return 1

    local f2b_check_log
    f2b_check_log=$(mktemp) || f2b_check_log="/tmp/fail2ban-check.log"
    if ! fail2ban-client -d >"$f2b_check_log" 2>&1; then
        msg_err "Fail2Ban 配置校验失败，请检查 ${FAIL2BAN_SSH_JAIL_FILE}"
        tail -n 40 "$f2b_check_log" 2>/dev/null || true
        rm -f "$f2b_check_log"
        return 1
    fi
    rm -f "$f2b_check_log"

    systemctl enable fail2ban >/dev/null 2>&1 || true
    if systemctl restart fail2ban >/dev/null 2>&1 || \
       service fail2ban restart >/dev/null 2>&1 || \
       fail2ban-client reload >/dev/null 2>&1; then
        msg_ok "Fail2Ban 已按当前 SSH 端口同步: ${ports}"
        return 0
    fi

    msg_err "Fail2Ban 重启/重载失败，请检查服务状态。"
    return 1
}

install_and_configure_fail2ban() {
    ensure_fail2ban_installed || return 1
    update_fail2ban_ssh_port "$(get_current_ssh_ports_csv)"
}

show_fail2ban_status_detail() {
    local cfg_file="${FAIL2BAN_SSH_JAIL_FILE:-/etc/fail2ban/jail.local}"
    local service_active="未知" service_enabled="未知" server_ping="失败"
    local config_check="未执行" jails="" sshd_loaded="否" effective="否"
    local cfg_port="未配置" cfg_backend="未配置" cfg_banaction="未配置"
    local current_failed="-" total_failed="-" current_banned="-" total_banned="-"
    local banned_ips="无" backend="unknown" firewall_rules="" recent_events=""
    local sshd_status=""

    clear
    menu_header "Fail2Ban 状态与封禁详情"

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        status_pair "安装状态" "未安装"
        status_pair "脚本配置" "$([ -f "$cfg_file" ] && echo "存在：$cfg_file" || echo "不存在")"
        draw_line
        msg_warn "Fail2Ban 未安装，当前未生效。"
        return 1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        service_active=$(systemctl is-active fail2ban 2>/dev/null || echo "inactive")
        service_enabled=$(systemctl is-enabled fail2ban 2>/dev/null || echo "disabled")
    fi

    fail2ban-client ping >/dev/null 2>&1 && server_ping="正常"
    fail2ban-client -d >/dev/null 2>&1 && config_check="通过" || config_check="失败"

    if [ -f "$cfg_file" ]; then
        cfg_port=$(awk -F= '/^[[:space:]]*#/ {next} /^[[:space:]]*port[[:space:]]*=/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$cfg_file" | tail -n 1)
        cfg_backend=$(awk -F= '/^[[:space:]]*#/ {next} /^[[:space:]]*backend[[:space:]]*=/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$cfg_file" | tail -n 1)
        cfg_banaction=$(awk -F= '/^[[:space:]]*#/ {next} /^[[:space:]]*banaction[[:space:]]*=/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$cfg_file" | tail -n 1)
        cfg_port=${cfg_port:-未配置}
        cfg_backend=${cfg_backend:-未配置}
        cfg_banaction=${cfg_banaction:-未配置}
    fi

    jails=$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' ' | xargs 2>/dev/null || true)
    if printf ' %s ' "$jails" | grep -q ' sshd '; then
        sshd_loaded="是"
        sshd_status=$(fail2ban-client status sshd 2>/dev/null || true)
        current_failed=$(printf '%s\n' "$sshd_status" | awk -F: '/Currently failed:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
        total_failed=$(printf '%s\n' "$sshd_status" | awk -F: '/Total failed:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
        current_banned=$(printf '%s\n' "$sshd_status" | awk -F: '/Currently banned:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
        total_banned=$(printf '%s\n' "$sshd_status" | awk -F: '/Total banned:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
        banned_ips=$(printf '%s\n' "$sshd_status" | awk -F: '/Banned IP list:/ {sub(/^[^:]*:[ \t]*/, ""); print; exit}')
        current_failed=${current_failed:-0}
        total_failed=${total_failed:-0}
        current_banned=${current_banned:-0}
        total_banned=${total_banned:-0}
        banned_ips=${banned_ips:-无}
    fi

    if [ "$server_ping" = "正常" ] && [ "$sshd_loaded" = "是" ] && [ "$config_check" = "通过" ]; then
        effective="是"
    fi

    backend=$(detect_firewall_backend 2>/dev/null || echo "unknown")
    if [ "$backend" = "nft" ] && command -v nft >/dev/null 2>&1; then
        firewall_rules=$(nft list ruleset 2>/dev/null | grep -i 'f2b' | head -n 20 || true)
    elif command -v iptables >/dev/null 2>&1; then
        firewall_rules=$(iptables -S 2>/dev/null | grep -i 'f2b' | head -n 20 || true)
        if command -v ip6tables >/dev/null 2>&1; then
            firewall_rules="${firewall_rules}"$'\n'"$(ip6tables -S 2>/dev/null | grep -i 'f2b' | head -n 20 || true)"
        fi
    fi
    firewall_rules=$(printf '%s\n' "$firewall_rules" | awk 'NF')

    recent_events=$(
        {
            journalctl -u fail2ban --no-pager -n 120 2>/dev/null || true
            [ -f /var/log/fail2ban.log ] && tail -n 120 /var/log/fail2ban.log 2>/dev/null || true
        } | grep -Ei "\\[sshd\\].*(Ban|Unban)|Jail 'sshd'|Jail \"sshd\"" | tail -n 20 || true
    )

    status_pair "安装状态" "已安装"
    status_pair "服务状态" "${service_active}"
    status_pair "开机启动" "${service_enabled}"
    status_pair "客户端连接" "${server_ping}"
    status_pair "配置校验" "${config_check}"
    status_pair "sshd jail" "${sshd_loaded}"
    status_pair "当前生效" "${effective}"
    draw_line

    menu_section "脚本配置"
    status_pair "配置文件" "$([ -f "$cfg_file" ] && echo "$cfg_file" || echo "不存在")"
    status_pair "SSH端口" "${cfg_port}"
    status_pair "日志后端" "${cfg_backend}"
    status_pair "封禁动作" "${cfg_banaction}"
    status_pair "防火墙模式" "${backend}"
    draw_line

    menu_section "封禁详情"
    status_pair "当前失败" "${current_failed}"
    status_pair "累计失败" "${total_failed}"
    status_pair "当前封禁" "${current_banned}"
    status_pair "累计封禁" "${total_banned}"
    status_pair "封禁IP" "${banned_ips}"
    draw_line

    menu_section "防火墙规则"
    if [ -n "$firewall_rules" ]; then
        printf '%s\n' "$firewall_rules"
    else
        msg_info "未发现 f2b 规则。未触发封禁或 action 尚未创建规则时可能出现该状态。"
    fi
    draw_line

    menu_section "近期事件"
    if [ -n "$recent_events" ]; then
        printf '%s\n' "$recent_events"
    else
        msg_info "未发现近期 Ban / Unban / sshd jail 事件。"
    fi
}
