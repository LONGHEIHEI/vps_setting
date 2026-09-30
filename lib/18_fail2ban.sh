# Fail2Ban installation, configuration, and diagnostics.
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

backup_fail2ban_file_with_timestamp() {
    local target_file="$1"
    local backup_root="${SUITE_BACKUP_DIR:-/var/backups/vps-init-suite}/fail2ban"
    local safe_name backup_path

    [ -f "$target_file" ] || return 1
    mkdir -p "$backup_root" || return 1
    safe_name=$(printf '%s\n' "$target_file" | sed 's#^/##; s#[^A-Za-z0-9._-]#_#g')
    backup_path="${backup_root}/${safe_name}.bak.$(date +%F_%H%M%S).$$"
    cp -af "$target_file" "$backup_path" || return 1
    printf '%s\n' "$backup_path"
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
        backup_file=$(backup_fail2ban_file_with_timestamp "$jail_local") || {
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
        mkdir -p "${SUITE_BACKUP_DIR:-/var/backups/vps-init-suite}/fail2ban" 2>/dev/null || true
        legacy_backup="${SUITE_BACKUP_DIR:-/var/backups/vps-init-suite}/fail2ban/$(basename "$legacy_candidate").disabled.$(date +%F_%H%M%S).$$"
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

    backup_file=$(backup_fail2ban_file_with_timestamp "$jail_local") || return 1
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
