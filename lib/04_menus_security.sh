# --- [4. 子菜单模块] ---
# 1. 基础环境
menu_base_config() {
    local sub menu_action

    while true; do
        clear
        menu_header "1. 基础环境"
        status_pair "HOST" "$(hostname)"
        status_pair "TZ" "$(timedatectl show --property=Timezone --value)"
        draw_line
        menu_section "系统身份"
        menu_pair "[1] 修改系统主机名" "[2] 修改系统时区"

        menu_section "Shell 与软件源"
        menu_pair "[3] 终端环境美化" "[4] 更新软件索引"
        menu_footer_back
        menu_read_submenu_action sub menu_action
        case "$menu_action" in
            continue) ;;
            return) return ;;
            retry) continue ;;
            back) break ;;
        esac
        case $sub in
            1)
                read -p "新主机名: " hn
                if [ -n "$hn" ]; then
                    if ! validate_hostname_value "$hn"; then
                        msg_err "主机名格式无效：仅允许字母、数字、短横线和点，且每段需以字母或数字开头/结尾。"
                        pause
                        continue
                    fi
                    if hostnamectl set-hostname "$hn"; then
                        if grep -qE '^127\.0\.1\.1([[:space:]]|$)' /etc/hosts; then
                            sed -i -E "s/^127\.0\.1\.1([[:space:]].*)?$/127.0.1.1 ${hn}/" /etc/hosts
                        else
                            printf '127.0.1.1 %s\n' "$hn" >> /etc/hosts
                        fi
                        msg_ok "主机名已设置为 ${hn}"
                    else
                        msg_err "主机名设置失败"
                    fi
                fi ;;
            2)
                read -p "输入时区 [默认: ${DEFAULT_TIMEZONE}]: " input_tz
                input_tz=${input_tz:-$DEFAULT_TIMEZONE}
                if timedatectl list-timezones 2>/dev/null | grep -Fxq "$input_tz"; then
                    timedatectl set-timezone "$input_tz" && msg_ok "时区已设置为 ${input_tz}"
                else
                    msg_err "无效时区：${input_tz}"
                fi ;;
            3)
                MARKER="# SERVER_MASTER_PS1"
                append_shell_beautify_block ~/.bashrc "$MARKER"
                msg_info "配置已写入 ~/.bashrc，重新登录 Shell 后生效。"
                ;;
            4)
                pkg_update && msg_ok "软件索引更新完成" || msg_err "软件索引更新失败" ;;
        esac
        pause
    done
}

# 2. SSH 与账号安全
menu_security_hardening() {
    local sub menu_action root_s

    while true; do
        clear
        menu_header "2. SSH 与账号安全"
        root_s=$(get_current_root_login_status)
        status_pair "Fail2Ban" "$(check_fail2ban)"
        status_pair "SSH_PORT" "$(get_current_ssh_ports_csv)"
        status_pair "ROOT_LOGIN" "${root_s:-"yes"}"
        status_pair "SSH_BANNER" "$(get_ssh_login_banner_status)"
        draw_line

        menu_section "账号"
        menu_pair "[1] 创建/修复管理用户"

        menu_section "SSH 登录"
        menu_pair "[2] 修改SSH登录端口" "[C] 添加SSH登录Banner"
        menu_pair "[3] 允许Root登录" "[4] 禁用Root登录"
        menu_pair "[5] 允许密码登录" "[6] 禁用密码登录"
        menu_pair "[B] 仅允许SSH密钥登录"

        menu_section "入侵防护"
        menu_pair "[7] 安装/配置Fail2Ban" "[9] 查看状态/封禁详情"
        menu_pair "[A] 卸载Fail2Ban"

        menu_section "整合初始化"
        menu_pair "[8] 一键整合SSH / 用户 / 防火墙"
        menu_footer_back
        menu_read_submenu_action sub menu_action
        case "$menu_action" in
            continue) ;;
            return) return ;;
            retry) continue ;;
            back) break ;;
        esac
        case $sub in
            1)
                while true; do
                    read -p "管理用户名: " input_user
                    if [ -n "$input_user" ]; then break; else msg_warn "用户名不能为空。"; fi
                done
                need_password=1  # 默认标记为需要设置密码
                if id "$input_user" &>/dev/null; then
                    msg_warn "用户 '$input_user' 已存在。"
                    
                    # 1. 检查 sudo 权限是否已存在 (避免重复添加)
                    if groups "$input_user" | grep -Eq "\b(sudo|wheel)\b"; then
                        echo " -> 检测到该用户已拥有 sudo 权限。"
                    else
                        ensure_user_in_admin_group "$input_user"
                        msg_ok " -> 已补全 sudo 权限。"
                    fi
                    # 2. 询问是否覆盖密码 (防止意外修改现有密码)
                    read -p "是否需要重置该用户的密码？(y/n) [默认n]: " reset_confirm
                    if [[ ! "$reset_confirm" =~ ^[Yy]$ ]]; then
                        echo " -> 跳过密码修改，保持现状。"
                        need_password=0
                    fi
                fi
                if [ "$need_password" -eq 1 ]; then
                    while true; do
                        read -s -p "请输入密码: " input_pass; echo
                        read -s -p "请再次输入密码以确认: " input_pass2; echo
                        if [ -z "$input_pass" ]; then msg_warn "密码不能为空。"; continue; fi
                        if [ "$input_pass" != "$input_pass2" ]; then msg_warn "密码不一致。"; continue; fi
                        break
                    done

                    if id "$input_user" &>/dev/null; then
                        # 用户存在，仅更新密码
                        echo "$input_user:$input_pass" | chpasswd
                        msg_ok "用户密码已更新"
                    else
                        # 用户不存在，创建新用户
                        useradd -m -s /bin/bash "$input_user" && \
                        echo "$input_user:$input_pass" | chpasswd && \
                        ensure_user_in_admin_group "$input_user"
                        msg_ok "管理用户 $input_user 创建成功"
                    fi
                fi 
                ;;
            2)
                current_ssh_port=$(get_current_ssh_port)
                read -p "输入端口: " p; p=${p:-$DEFAULT_SSH_PORT}; confirm "将SSH端口从 $current_ssh_port 改为 $p（将自动联动防火墙 / SELinux / Fail2Ban）" && {
                    if ! validate_port "$p"; then
                        msg_err "端口格式无效。"
                    elif [ "$current_ssh_port" != "$p" ]; then
                        change_ssh_port_safely "$p" "SSH端口修改成功" 1
                    else
                        msg_warn "SSH端口已配置为 $p，跳过配置文件修改。"
                    fi
                } ;;
            3)
                if confirm "允许root登录?"; then
                    if ! ssh_backup=$(backup_file_with_timestamp /etc/ssh/sshd_config); then
                        msg_err "备份 sshd 配置失败。"
                        continue
                    fi
                    set_sshd_directive "PermitRootLogin" "yes"
                    apply_sshd_changes "已允许root登录" "$ssh_backup"
                else
                    msg_warn "操作已取消"
                fi ;;
            4)
                read -p "允许登录的用户名: " allow_user
                if [ -z "$allow_user" ]; then
                    confirm "禁用root登录" && {
                        if ! ssh_backup=$(backup_file_with_timestamp /etc/ssh/sshd_config); then
                            msg_err "备份 sshd 配置失败。"
                            continue
                        fi
                        set_sshd_directive "PermitRootLogin" "no"
                        set_sshd_directive "PasswordAuthentication" "yes"
                        delete_sshd_directive "AllowUsers"
                        apply_sshd_changes "SSH安全配置完成" "$ssh_backup"
                    }
                else
                    confirm "禁用root登录, 仅允许用户 $allow_user" && {
                        if ! ssh_backup=$(backup_file_with_timestamp /etc/ssh/sshd_config); then
                            msg_err "备份 sshd 配置失败。"
                            continue
                        fi
                        set_sshd_directive "PermitRootLogin" "no"
                        set_sshd_directive "PasswordAuthentication" "yes"
                        set_sshd_directive "AllowUsers" "$allow_user"
                        apply_sshd_changes "SSH安全配置完成" "$ssh_backup"
                    }
                fi ;;
            5)
                if confirm "允许密码登录 (PasswordAuthentication yes)?"; then
                    if ! ssh_backup=$(backup_file_with_timestamp /etc/ssh/sshd_config); then
                        msg_err "备份 sshd 配置失败。"
                        continue
                    fi
                    set_sshd_directive "PasswordAuthentication" "yes"
                    apply_sshd_changes "已启用密码登录" "$ssh_backup"
                else
                    msg_warn "操作已取消"
                fi ;;
            6)
                if confirm "禁用密码登录 (PasswordAuthentication no)?"; then
                    if ! ssh_backup=$(backup_file_with_timestamp /etc/ssh/sshd_config); then
                        msg_err "备份 sshd 配置失败。"
                        continue
                    fi
                    set_sshd_directive "PasswordAuthentication" "no"
                    apply_sshd_changes "已禁用密码登录" "$ssh_backup"
                else
                    msg_warn "操作已取消"
                fi ;;
            B|b)
                read -r -p "允许密钥登录的用户名（可多个空格分隔；留空不写 AllowUsers，将自动检查当前登录用户公钥）: " allow_users
                if [ -n "$allow_users" ]; then
                    invalid_user=""
                    for input_user in $allow_users; do
                        if ! is_valid_system_username "$input_user"; then
                            invalid_user="$input_user"
                            break
                        fi
                    done
                    if [ -n "$invalid_user" ]; then
                        msg_err "用户名格式无效：${invalid_user}"
                        continue
                    fi
                fi
                if confirm "启用仅 SSH 密钥登录（将禁用密码登录、键盘交互认证和空密码）?"; then
                    apply_ssh_key_only_login_config "$allow_users"
                else
                    msg_warn "操作已取消"
                fi ;;
            C|c)
                if confirm "添加/更新 SSH 动态登录 Banner（同时静默系统 MOTD / Last login）?"; then
                    install_ssh_login_banner
                else
                    msg_warn "操作已取消"
                fi ;;
            7)
                confirm "安装并配置Fail2Ban防暴力破解" && {
                    install_and_configure_fail2ban && \
                    msg_ok "Fail2Ban安装/配置完成"
                } ;;
            8)
                run_integrated_ssh_user_firewall_init ;;
            9)
                show_fail2ban_status_detail ;;
            A|a)
                run_confirmed_action "卸载Fail2Ban（删除配置需二次确认）" uninstall_fail2ban ;;
        esac
        pause
    done
}

# 4. 网络与性能
menu_network_performance() {
    local sub menu_action

    while true; do
        clear
        menu_header "4. 网络与性能"
        status_pair "DNS" "$(get_dns_status)"
        status_pair "优先级" "$(get_proto_priority)"
        status_pair "IPv6" "$(get_ipv6_status)"
        status_pair "TCP" "$(get_bbr_status)"
        status_pair "Swap" "$(free -m | awk '/Swap:/{printf "%d/%dM", $3, $2}')"
        draw_line
        menu_section "网络栈"
        menu_pair "[1] TCP网络调优" "[2] DNS解析优化"
        menu_pair "[3] 切换为IPv4优先" "[4] 切换为IPv6优先"
        menu_pair "[7] 修复IPv6自动获取"

        menu_section "资源维护"
        menu_pair "[5] 修改Swap分区" "[6] 深度清理系统垃圾"
        menu_footer_back
        menu_read_submenu_action sub menu_action
        case "$menu_action" in
            continue) ;;
            return) return ;;
            retry) continue ;;
            back) break ;;
        esac
        case $sub in
            1)
                confirm "应用TCP网络调优" && {
                    apply_bbr_optimization
                } ;;
            2)
                confirm "优化DNS解析配置" && {
                    apply_dns_optimization
                } ;;
            3)
                confirm "切换为IPv4优先协议" && {
                    sed -i '/precedence ::ffff:0:0\/96/d' /etc/gai.conf; echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
                    msg_ok "IPv4优先已设置"
                } ;;
            4)
                confirm "切换为IPv6优先协议(默认)" && {
                    sed -i '/precedence ::ffff:0:0\/96/d' /etc/gai.conf
                    msg_ok "IPv6优先已设置"
                } ;;
            5)
                read -p "大小(MB): " sz
                validate_non_negative_int "$sz" || {
                    msg_err "请输入非负整数，例如 0 / 512 / 1024"
                    pause
                    continue
                }
                confirm "创建或修改Swap文件为 ${sz}MB" && {
                    configure_swap_file "$sz"
                } ;;
            6)
                confirm "深度清理系统垃圾" && {
                    if pkg_cleanup && journalctl --vacuum-time=1s; then
                        msg_ok "系统清理完成"
                    else
                        msg_err "系统清理过程中出现错误"
                    fi
                } ;;
            7)
                confirm "修复 IPv6 自动获取" && {
                    repair_ipv6_autoconf
                } ;;
        esac
        pause
    done
}

menu_oracle_cloud_services() {
    local sub menu_action oci_meta_ipv6 oci_service_status

    while true; do
        clear
        oci_meta_ipv6=$(get_oci_ipv6_metadata_address 2>/dev/null || echo "未分配")
        oci_service_status=$(get_oci_ipv6_service_status)

        menu_header "9. 云厂商/OCI"
        status_pair "元数据 IPv6" "$oci_meta_ipv6"
        status_pair "IPv6 服务" "$oci_service_status"
        draw_line
        menu_pair "[1] 添加 OCI IPv6 开机服务"
        menu_pair "[2] 修复当前 OCI IPv6"
        menu_footer_back
        menu_read_submenu_action sub menu_action
        case "$menu_action" in
            continue) ;;
            return) return ;;
            retry) continue ;;
            back) break ;;
        esac
        case $sub in
            1)
                confirm "安装并启动甲骨文 IPv6 开机服务" && {
                    install_oci_ipv6_service
                } ;;
            2)
                confirm "立即修复当前甲骨文 IPv6" && {
                    repair_ipv6_autoconf
                } ;;
        esac
        pause
    done
}

firewall_open_port() {
    local backend="${1:-$(detect_firewall_backend)}"
    local proto="$2"
    local port="$3"
    local normalized chain iptables_port

    require_native_firewall_backend "$backend" || return 1
    validate_protocol "$proto" || { msg_err "协议无效：$proto"; return 1; }

    if [ "$backend" = "nft" ]; then
        if [ "$proto" = "all" ]; then
            firewall_open_port "$backend" tcp "$port" || return 1
            firewall_open_port "$backend" udp "$port" || return 1
        elif normalized=$(normalize_port_spec "${proto}:${port}"); then
            port="${normalized#*:}"
            if nft list chain inet filter input 2>/dev/null | grep -Eq "(^|[[:space:]])${proto}[[:space:]]+dport[[:space:]]+${port}([[:space:]]|$).*accept"; then
                msg_warn "nftables: ${proto} 端口 ${port} 规则已存在，跳过。"
            else
                nft insert rule inet filter input "$proto" dport "$port" accept
                msg_ok "nftables: ${proto} 端口 ${port} 已开放"
            fi
        else
            msg_err "端口无效：$port"
            return 1
        fi
    else
        chain=$(get_effective_filter_chain iptables)
        if [ "$proto" = "all" ]; then
            firewall_open_port "$backend" tcp "$port" || return 1
            firewall_open_port "$backend" udp "$port" || return 1
        else
            normalized=$(normalize_port_spec "${proto}:${port}") || { msg_err "端口无效：$port"; return 1; }
            port="${normalized#*:}"
            iptables_port=$(port_spec_to_iptables_dport "$port")
            if iptables -C "$chain" -p "$proto" --dport "$iptables_port" -j ACCEPT 2>/dev/null; then
                msg_warn "iptables: ${proto} 端口 ${port} 规则已存在，跳过。"
            else
                iptables -I "$chain" 1 -p "$proto" --dport "$iptables_port" -j ACCEPT
                msg_ok "iptables: ${proto} 端口 ${port} 已开放"
            fi
            if command -v ip6tables >/dev/null 2>&1; then
                chain=$(get_effective_filter_chain ip6tables)
                if ip6tables -C "$chain" -p "$proto" --dport "$iptables_port" -j ACCEPT 2>/dev/null; then
                    msg_warn "ip6tables: ${proto} 端口 ${port} 规则已存在，跳过。"
                else
                    ip6tables -I "$chain" 1 -p "$proto" --dport "$iptables_port" -j ACCEPT
                    msg_ok "ip6tables: ${proto} 端口 ${port} 已开放"
                fi
            fi
        fi
    fi
}

remove_iptables_port_rules() {
    local cmd="${1:-iptables}"
    local chain="$2"
    local proto="$3"
    local port="$4"
    local iptables_port
    local removed=1

    iptables_port=$(port_spec_to_iptables_dport "$port")
    while "$cmd" -D "$chain" -p "$proto" --dport "$iptables_port" -j ACCEPT 2>/dev/null; do removed=0; done
    while "$cmd" -D "$chain" -p "$proto" -m "$proto" --dport "$iptables_port" -j ACCEPT 2>/dev/null; do removed=0; done
    return "$removed"
}

firewall_close_port() {
    local backend="${1:-$(detect_firewall_backend)}"
    local port="$2"
    local chain handles current_ssh_port normalized

    require_native_firewall_backend "$backend" || return 1
    normalized=$(normalize_port_spec "tcp:${port}") || { msg_err "端口无效：$port"; return 1; }
    port="${normalized#*:}"

    current_ssh_port=$(get_current_ssh_port)
    if port_spec_contains_port "$port" "$current_ssh_port"; then
        msg_warn "你正在操作当前 SSH 端口 ${port}，请务必确认有其他登录通道。"
        confirm "仍要继续关闭 SSH 端口 ${port} 的放行规则?" || return 1
    fi

    if [ "$backend" = "nft" ]; then
        handles=$(nft -a list chain inet filter input 2>/dev/null | grep -E "dport ${port}([[:space:]]|$).*accept" | awk -F 'handle ' '{print $2}')
        if [ -z "$handles" ]; then
            msg_warn "nftables: 未找到端口 ${port} 的放行规则。"
            return 0
        fi
        for handle in $handles; do
            nft delete rule inet filter input handle "$handle"
        done
        msg_ok "nftables: 端口 ${port} 放行规则已清理"
        return 0
    fi

    local removed=1
    chain=$(get_effective_filter_chain iptables)
    remove_iptables_port_rules iptables "$chain" tcp "$port" && removed=0 || true
    remove_iptables_port_rules iptables "$chain" udp "$port" && removed=0 || true

    if command -v ip6tables >/dev/null 2>&1; then
        chain=$(get_effective_filter_chain ip6tables)
        remove_iptables_port_rules ip6tables "$chain" tcp "$port" && removed=0 || true
        remove_iptables_port_rules ip6tables "$chain" udp "$port" && removed=0 || true
    fi

    if [ "$removed" -ne 0 ]; then
        msg_warn "iptables/ip6tables: 未找到端口 ${port} 的放行规则。"
    else
        msg_ok "iptables/ip6tables: 端口 ${port} 放行规则已清理"
    fi
}

firewall_allow_all_ports() {
    local backend="${1:-$(detect_firewall_backend)}"

    require_native_firewall_backend "$backend" || return 1

    if [ "$backend" = "nft" ]; then
        nft delete table inet filter >/dev/null 2>&1 || true
        nft add table inet filter
        nft add chain inet filter input '{ type filter hook input priority 0; policy accept; }'
        nft add chain inet filter forward '{ type filter hook forward priority 0; policy accept; }'
        nft add chain inet filter output '{ type filter hook output priority 0; policy accept; }'
        set_firewall_backend_state nft
        msg_ok "nftables: 已将 inet/filter 重建为全放行策略"
    else
        ensure_managed_filter_chain iptables >/dev/null 2>&1 || true
        iptables -F "$IPTABLES_MANAGED_CHAIN" >/dev/null 2>&1 || true
        iptables -A "$IPTABLES_MANAGED_CHAIN" -j ACCEPT
        if command -v ip6tables >/dev/null 2>&1; then
            ensure_managed_filter_chain ip6tables >/dev/null 2>&1 || true
            ip6tables -F "$IP6TABLES_MANAGED_CHAIN" >/dev/null 2>&1 || true
            ip6tables -A "$IP6TABLES_MANAGED_CHAIN" -j ACCEPT
        fi
        set_firewall_backend_state iptables
        msg_ok "iptables/ip6tables: 托管链已改为全放行"
    fi
}

firewall_reset_whitelist() {
    local backend="${1:-$(detect_firewall_backend)}"
    shift
    require_native_firewall_backend "$backend" || return 1

    if [ "$backend" = "nft" ]; then
        init_nft_rule "$@"
    else
        init_iptable_rule "$@"
    fi
}

set_iptables_terminal_policy() {
    local cmd="${1:-iptables}"
    local desired="$2"
    local chain

    command -v "$cmd" >/dev/null 2>&1 || return 0
    chain=$(get_effective_filter_chain "$cmd")

    if [ "$chain" = "$(get_managed_chain_name "$cmd")" ]; then
        ensure_managed_filter_chain "$cmd" || return 1
        while "$cmd" -C "$chain" -j ACCEPT >/dev/null 2>&1; do
            "$cmd" -D "$chain" -j ACCEPT >/dev/null 2>&1 || break
        done
        while "$cmd" -C "$chain" -j DROP >/dev/null 2>&1; do
            "$cmd" -D "$chain" -j DROP >/dev/null 2>&1 || break
        done
        while "$cmd" -C "$chain" -j REJECT >/dev/null 2>&1; do
            "$cmd" -D "$chain" -j REJECT >/dev/null 2>&1 || break
        done
        "$cmd" -A "$chain" -j "$desired" || return 1
    else
        "$cmd" -P INPUT "$desired" || return 1
    fi
}

set_nft_input_policy() {
    local desired="$1"

    command -v nft >/dev/null 2>&1 || {
        msg_err "系统未安装 nft 命令，无法切换 nftables 策略。"
        return 1
    }

    if [ ! -s /etc/nftables.conf ]; then
        nft list ruleset > /etc/nftables.conf 2>/dev/null || {
            msg_err "无法生成 /etc/nftables.conf。"
            return 1
        }
    fi

    python3 - "$desired" /etc/nftables.conf <<'PY' || return 1
import re
import sys
from pathlib import Path

desired = sys.argv[1]
path = Path(sys.argv[2])
text = path.read_text()
pattern = re.compile(r'(chain\s+input\s*\{.*?type\s+filter\s+hook\s+input\s+priority\s+0;\s*policy\s+)(accept|drop)(\s*;)', re.S)
new_text, count = pattern.subn(r'\1' + desired + r'\3', text, count=1)
if count != 1:
    sys.exit(1)
path.write_text(new_text)
PY

    nft -f /etc/nftables.conf || {
        msg_err "nftables 策略应用失败。"
        return 1
    }
}

firewall_switch_policy() {
    local backend="${1:-$(detect_firewall_backend)}"
    local mode="$2"
    shift 2

    require_native_firewall_backend "$backend" || return 1

    case "$mode" in
        allow)
            if [ "$backend" = "nft" ]; then
                set_nft_input_policy accept || return 1
            else
                set_iptables_terminal_policy iptables ACCEPT || return 1
                if command -v ip6tables >/dev/null 2>&1; then
                    set_iptables_terminal_policy ip6tables ACCEPT || return 1
                fi
            fi
            save_iptables
            msg_ok "已切换为允许策略（未改动现有放行端口规则）"
            ;;
        block)
            if [ "$backend" = "nft" ]; then
                set_nft_input_policy drop || return 1
            else
                set_iptables_terminal_policy iptables DROP || return 1
                if command -v ip6tables >/dev/null 2>&1; then
                    set_iptables_terminal_policy ip6tables DROP || return 1
                fi
            fi
            save_iptables
            msg_ok "已切换为阻止策略（未改动现有放行端口规则）"
            ;;
        *)
            msg_err "未知策略模式：$mode"
            return 1
            ;;
    esac
}

firewall_add_ip_rule() {
    local backend="${1:-$(detect_firewall_backend)}"
    local mode="$2"
    local value="$3"
    local action label family chain expr cmd

    require_native_firewall_backend "$backend" || return 1
    validate_ip_or_cidr "$value" || { msg_err "IP/CIDR 格式无效：$value"; return 1; }

    case "$mode" in
        whitelist) action="accept"; label="白名单" ;;
        blacklist) action="drop"; label="黑名单" ;;
        *) msg_err "未知 IP 规则模式：$mode"; return 1 ;;
    esac

    family=$(get_ip_family "$value") || { msg_err "无法识别 IP 类型：$value"; return 1; }

    if [ "$backend" = "nft" ]; then
        if [ "$family" = "ipv6" ]; then
            expr="ip6 saddr ${value} ${action}"
            if nft list chain inet filter input 2>/dev/null | grep -Fq "$expr"; then
                msg_warn "nftables: ${value} 已在${label}中。"
            else
                nft insert rule inet filter input ip6 saddr "$value" "$action"
                msg_ok "nftables: ${value} 已加入${label}"
            fi
        else
            expr="ip saddr ${value} ${action}"
            if nft list chain inet filter input 2>/dev/null | grep -Fq "$expr"; then
                msg_warn "nftables: ${value} 已在${label}中。"
            else
                nft insert rule inet filter input ip saddr "$value" "$action"
                msg_ok "nftables: ${value} 已加入${label}"
            fi
        fi
        return 0
    fi

    if [ "$family" = "ipv6" ]; then
        cmd="ip6tables"
        command -v ip6tables >/dev/null 2>&1 || { msg_err "系统未安装 ip6tables，无法处理 IPv6 规则。"; return 1; }
    else
        cmd="iptables"
    fi
    chain=$(get_effective_filter_chain "$cmd")
    if "$cmd" -C "$chain" -s "$value" -j "${action^^}" 2>/dev/null; then
        msg_warn "${cmd}: ${value} 已在${label}中。"
    else
        "$cmd" -I "$chain" 1 -s "$value" -j "${action^^}"
        msg_ok "${cmd}: ${value} 已加入${label}"
    fi
}

firewall_show_rule_details() {
    local backend="${1:-$(detect_firewall_backend)}"
    require_native_firewall_backend "$backend" || return 1

    draw_line
    msg_info "当前防火墙规则 (${backend})"
    draw_line
    if [ "$backend" = "nft" ]; then
        nft -a list table inet filter
    else
        echo "[iptables: INPUT]"
        iptables -L INPUT -n --line-numbers
        if iptables_chain_exists iptables "$IPTABLES_MANAGED_CHAIN"; then
            echo
            echo "[iptables: ${IPTABLES_MANAGED_CHAIN}]"
            iptables -L "$IPTABLES_MANAGED_CHAIN" -n --line-numbers
        fi
        if command -v ip6tables >/dev/null 2>&1; then
            echo
            echo "[ip6tables: INPUT]"
            ip6tables -L INPUT -n --line-numbers
            if iptables_chain_exists ip6tables "$IP6TABLES_MANAGED_CHAIN"; then
                echo
                echo "[ip6tables: ${IP6TABLES_MANAGED_CHAIN}]"
                ip6tables -L "$IP6TABLES_MANAGED_CHAIN" -n --line-numbers
            fi
        fi
    fi
    draw_line
}

show_firewall_status() {
    local backend="${1:-$(detect_firewall_backend)}"
    local FW_POLICY="未知"
    local PING_STATUS="未知"

    if [ "$backend" = "firewalld" ]; then
        status_pair "当前防火墙" "firewalld"
        status_pair "当前策略" "由 firewalld 接管"
        status_pair "PING 状态" "请使用 firewall-cmd 单独查看"
        return 0
    elif [ "$backend" = "nft" ]; then
        local nft_input_chain first_icmp_rule
        nft_input_chain=$(nft list chain inet filter input 2>/dev/null)

        # --- NFTABLES 检测逻辑 ---
        # 1. 获取 INPUT 链默认策略
        FW_POLICY=$(printf '%s\n' "$nft_input_chain" | sed -n -E 's/.*policy ([a-z]+).*/\1/p' | head -n1 | tr '[:lower:]' '[:upper:]')
        FW_POLICY=${FW_POLICY:-"ACCEPT"} # 默认为 ACCEPT

        # 2. 查找第一条关于 icmp 的规则 (First Match Wins)
        # nftables 的 list 输出是按顺序的，我们取第一条匹配 icmp 的行
        # 匹配 "ip protocol icmp" 或 "meta l4proto ipv6-icmp"
        first_icmp_rule=$(printf '%s\n' "$nft_input_chain" | grep -E "(ip protocol icmp|meta l4proto ipv6-icmp)" | head -n 1)

        if [ -n "$first_icmp_rule" ]; then
            # 如果找到了针对 ICMP 的规则，检查它的动作
            if echo "$first_icmp_rule" | grep -q "accept"; then
                PING_STATUS="允许 (规则优先)"
            elif echo "$first_icmp_rule" | grep -q "drop"; then
                PING_STATUS="禁止 (规则优先)"
            else
                PING_STATUS="复杂规则 (视为禁止)"
            fi
        else
            # 没有显式规则 -> 跟随默认策略
            if [ "$FW_POLICY" = "DROP" ]; then
                PING_STATUS="禁止 (默认策略)"
            else
                PING_STATUS="允许 (默认策略)"
            fi
        fi

    else
        # --- IPTABLES 检测逻辑 ---
        local inspect_chain first_icmp_rule chain_rules input_rules
        inspect_chain=$(get_effective_filter_chain iptables)
        chain_rules=$(iptables -S "$inspect_chain" 2>/dev/null)

        if [ "$inspect_chain" = "$IPTABLES_MANAGED_CHAIN" ]; then
            if printf '%s\n' "$chain_rules" | tail -n 1 | grep -q -- '-j DROP$'; then
                FW_POLICY="DROP (托管链)"
            else
                FW_POLICY="ACCEPT (托管链)"
            fi
        else
            input_rules=$(iptables -S INPUT 2>/dev/null)
            FW_POLICY=$(printf '%s\n' "$input_rules" | awk '/^-P INPUT / {print toupper($3); exit}')
            FW_POLICY=${FW_POLICY:-"ACCEPT"}
        fi

        first_icmp_rule=$(printf '%s\n' "$chain_rules" | awk -v chain="$inspect_chain" '
            $1=="-A" && $2==chain && $0 ~ / -p icmp / {
                for (i=1; i<=NF; i++) {
                    if ($i == "-j") {
                        print toupper($(i+1))
                        exit
                    }
                }
            }
        ')

        if [ -n "$first_icmp_rule" ]; then
            if [ "$first_icmp_rule" = "ACCEPT" ]; then
                PING_STATUS="允许 (规则优先)"
            elif [ "$first_icmp_rule" = "DROP" ] || [ "$first_icmp_rule" = "REJECT" ]; then
                PING_STATUS="禁止 (规则优先)"
            else
                PING_STATUS="未知 ($first_icmp_rule)"
            fi
        else
            if echo "$FW_POLICY" | grep -q "DROP"; then
                PING_STATUS="禁止 (默认策略)"
            else
                PING_STATUS="允许 (默认策略)"
            fi
        fi
    fi

    # ==========================================
    # 输出结果
    # ==========================================
    status_pair "当前防火墙" "${backend}"
    status_pair "当前策略" "${FW_POLICY}"
    status_pair "PING 状态" "${PING_STATUS}"
}

persist_netfilter_rules_quiet() {
    # main.sh 启用了 set -e；未安装 netfilter-persistent 时不能让菜单退出。
    command -v netfilter-persistent >/dev/null 2>&1 || return 0
    netfilter-persistent save >/dev/null 2>&1 || true
    return 0
}

menu_firewall_service_init() {
    local sub menu_action backend

    while true; do
        clear
        backend=$(detect_firewall_backend)
        menu_header "3.1 服务与初始化"
        show_firewall_status "$backend"
        draw_line
        menu_pair "[1] 启用Iptables" "[2] 初始化Iptables规则"
        menu_pair "[3] 启用Nftables" "[4] 初始化Nftables规则"
        menu_footer_back
        menu_read_submenu_action sub menu_action
        case "$menu_action" in
            continue) ;;
            return) return ;;
            retry) continue ;;
            back) break ;;
        esac
        case $sub in
            1) run_confirmed_action "开启Iptables服务" enable_iptables ;;
            2) run_confirmed_action "初始化Iptables默认规则" init_iptable_rule ;;
            3) run_confirmed_action "开启Nftables服务" enable_nft ;;
            4) run_confirmed_action "初始化Nftables默认规则" init_nft_rule ;;
        esac
        persist_netfilter_rules_quiet
        pause
    done
}

menu_firewall_ports_ping() {
    local sub menu_action backend

    while true; do
        clear
        backend=$(detect_firewall_backend)
        menu_header "3.2 端口与连通性"
        show_firewall_status "$backend"
        draw_line
        menu_pair "[1] 开放指定端口" "[2] 关闭指定端口"
        menu_pair "[3] 开放所有端口" "[4] 仅保留SSH"
        menu_pair "[5] 禁止PING" "[6] 允许PING"
        menu_footer_back
        menu_read_submenu_action sub menu_action
        case "$menu_action" in
            continue) ;;
            return) return ;;
            retry) continue ;;
            back) break ;;
        esac
        case $sub in
            1) 
                require_native_firewall_backend "$backend" || continue
                read -p "端口或范围(示例: 443 / 10000-20000): " p
                read -p "协议(tcp/udp/all)[tcp]: " proto
                proto=${proto:-tcp}
                if ! validate_port_or_range "${p/:/-}"; then
                    msg_err "端口无效：$p"
                    continue
                fi
                if ! validate_protocol "$proto"; then
                    msg_err "协议无效：$proto（仅支持 tcp / udp / all）"
                    continue
                fi
                # 确认提示
                confirm "开放 $proto 端口 $p" || continue
                firewall_open_port "$backend" "$proto" "$p"
                save_iptables
                ;;

            2)
                require_native_firewall_backend "$backend" || continue
                read -p "端口或范围(示例: 443 / 10000-20000): " p
                if ! validate_port_or_range "${p/:/-}"; then
                    msg_err "端口无效：$p"
                    continue
                fi
                confirm "关闭端口 $p(将删除相关放行规则)" || continue
                firewall_close_port "$backend" "$p"
                save_iptables
                ;;
            3)
                require_native_firewall_backend "$backend" || continue
                confirm "开放所有端口(警告：将清空防火墙规则!)" || continue
                firewall_allow_all_ports "$backend"
                save_iptables
                ;;
            4)
                require_native_firewall_backend "$backend" || continue
                confirm "重置规则并仅保留SSH(白名单模式)" || continue
                read -p "额外保留端口或范围（逗号分隔，示例: 80,443,10000-20000）: " keep
                IFS=',' read -ra keep_arr <<< "$keep"
                firewall_reset_whitelist "$backend" "${keep_arr[@]}"
                ;;
            5) require_native_firewall_backend "$backend" || continue; if confirm "禁止PING?"; then disable_ping || true; fi ;;
            6) require_native_firewall_backend "$backend" || continue; if confirm "允许PING?"; then enable_ping || true; fi ;;
        esac
        persist_netfilter_rules_quiet
        pause
    done
}

menu_firewall_access_policy() {
    local sub menu_action backend

    while true; do
        clear
        backend=$(detect_firewall_backend)
        menu_header "3.3 访问控制与策略"
        show_firewall_status "$backend"
        draw_line
        menu_pair "[1] 加入IP白名单" "[2] 加入IP黑名单"
        menu_pair "[3] 切换为允许策略" "[4] 切换为阻止策略"
        menu_footer_back
        menu_read_submenu_action sub menu_action
        case "$menu_action" in
            continue) ;;
            return) return ;;
            retry) continue ;;
            back) break ;;
        esac
        case $sub in
            1)
                require_native_firewall_backend "$backend" || continue
                read -p "IP: " ip
                confirm "将IP $ip加入白名单" || continue
                firewall_add_ip_rule "$backend" whitelist "$ip"
                save_iptables
                ;;
            2)
                require_native_firewall_backend "$backend" || continue
                read -p "IP: " ip
                confirm "将IP $ip加入黑名单" || continue
                firewall_add_ip_rule "$backend" blacklist "$ip"
                save_iptables
                ;;
            3)
                require_native_firewall_backend "$backend" || continue
                confirm "切换为允许策略（仅切换策略，不修改已开放端口）" || continue
                firewall_switch_policy "$backend" allow
                ;;
            4)
                require_native_firewall_backend "$backend" || continue
                confirm "切换为阻止策略（仅切换策略，不修改已开放端口）" || continue
                firewall_switch_policy "$backend" block
                ;;
        esac
        persist_netfilter_rules_quiet
        pause
    done
}

menu_firewall_docker() {
    local sub menu_action

    while true; do
        clear
        menu_header "3.4 Docker隔离"
        draw_line
        menu_pair "[1] Docker容器隔离" "[2] 查看Docker配置"
        menu_pair "[3] 追加Docker端口"
        menu_footer_back
        menu_read_submenu_action sub menu_action
        case "$menu_action" in
            continue) ;;
            return) return ;;
            retry) continue ;;
            back) break ;;
        esac
        case $sub in
            1) secure_docker_isolation ;;
            2) show_docker_guard_config ;;
            3) append_docker_guard_ports ;;
        esac
        pause
    done
}
