# --- [新增] Docker 容器安全隔离 ---
install_docker_guard_assets() {
    cat > "$DOCKER_GUARD_APPLY_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/vps-init-suite/docker_guard.conf"
[ -r "$CONFIG_FILE" ] || { echo "Docker Guard 配置不存在: $CONFIG_FILE" >&2; exit 1; }
. "$CONFIG_FILE"

: "${DOCKER_GUARD_IFACE:?}"
: "${DOCKER_GUARD_PROTOCOL:=tcp}"
: "${DOCKER_GUARD_PORTS:=}"
: "${DOCKER_GUARD_CHAIN:=VPS_DOCKER_GUARD}"
: "${DOCKER_GUARD_CHAIN6:=VPS_DOCKER_GUARD6}"

add_allow_rules() {
    local cmd="$1" chain="$2" proto="$3" port="$4"
    "$cmd" -A "$chain" -i "$DOCKER_GUARD_IFACE" -o docker+ -p "$proto" -m conntrack --ctorigdstport "$port" -m comment --comment "vps-docker-guard allow" -j RETURN
    "$cmd" -A "$chain" -i "$DOCKER_GUARD_IFACE" -o br+ -p "$proto" -m conntrack --ctorigdstport "$port" -m comment --comment "vps-docker-guard allow" -j RETURN
}

apply_chain() {
    local cmd="$1" user_chain="$2" guard_chain="$3"
    "$cmd" -S "$user_chain" >/dev/null 2>&1 || return 1
    "$cmd" -N "$guard_chain" >/dev/null 2>&1 || true
    "$cmd" -F "$guard_chain"
    while "$cmd" -D "$user_chain" -j "$guard_chain" >/dev/null 2>&1; do :; done
    "$cmd" -I "$user_chain" 1 -j "$guard_chain"
    "$cmd" -A "$guard_chain" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "vps-docker-guard established" -j RETURN
    "$cmd" -A "$guard_chain" ! -i "$DOCKER_GUARD_IFACE" -m comment --comment "vps-docker-guard bypass non-wan" -j RETURN

    for port in $DOCKER_GUARD_PORTS; do
        case "$DOCKER_GUARD_PROTOCOL" in
            tcp)
                add_allow_rules "$cmd" "$guard_chain" tcp "$port"
                ;;
            udp)
                add_allow_rules "$cmd" "$guard_chain" udp "$port"
                ;;
            all)
                add_allow_rules "$cmd" "$guard_chain" tcp "$port"
                add_allow_rules "$cmd" "$guard_chain" udp "$port"
                ;;
        esac
    done

    "$cmd" -A "$guard_chain" -i "$DOCKER_GUARD_IFACE" -o docker+ -m comment --comment "vps-docker-guard drop docker+" -j DROP
    "$cmd" -A "$guard_chain" -i "$DOCKER_GUARD_IFACE" -o br+ -m comment --comment "vps-docker-guard drop br+" -j DROP
    "$cmd" -A "$guard_chain" -j RETURN
}

command -v iptables >/dev/null 2>&1 || { echo "未找到 iptables" >&2; exit 1; }
apply_chain iptables DOCKER-USER "$DOCKER_GUARD_CHAIN"

if command -v ip6tables >/dev/null 2>&1 && ip6tables -S DOCKER-USER >/dev/null 2>&1; then
    apply_chain ip6tables DOCKER-USER "$DOCKER_GUARD_CHAIN6"
fi
EOF
    chmod 755 "$DOCKER_GUARD_APPLY_SCRIPT"

    cat > "$DOCKER_GUARD_SERVICE_PATH" <<EOF
[Unit]
Description=VPS Docker published port guard
After=docker.service
Requires=docker.service
PartOf=docker.service
ConditionPathExists=${DOCKER_GUARD_APPLY_SCRIPT}

[Service]
Type=oneshot
ExecStart=${DOCKER_GUARD_APPLY_SCRIPT}
ExecReload=${DOCKER_GUARD_APPLY_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

write_docker_guard_config() {
    local iface="$1"
    local protocol="$2"
    local ports="$3"
    ensure_suite_state_dir
    cat > "$DOCKER_GUARD_CONFIG_FILE" <<EOF
DOCKER_GUARD_IFACE="${iface}"
DOCKER_GUARD_PROTOCOL="${protocol}"
DOCKER_GUARD_PORTS="${ports}"
DOCKER_GUARD_CHAIN="${DOCKER_GUARD_CHAIN}"
DOCKER_GUARD_CHAIN6="${DOCKER_GUARD_CHAIN6}"
EOF
}

normalize_port_list() {
    local raw="$1"
    local port result=""
    raw=$(echo "$raw" | tr ',' ' ' | xargs 2>/dev/null || true)
    [ -n "$raw" ] || { echo ""; return 0; }
    for port in $raw; do
        validate_port "$port" || return 1
        case " $result " in
            *" $port "*) ;;
            *) result="${result:+$result }$port" ;;
        esac
    done
    echo "$result"
}

docker_guard_prereq_check() {
    local backend
    backend=$(detect_firewall_backend)
    if [ "$backend" != "iptables" ]; then
        msg_warn "当前防火墙模式为: $backend"
        msg_warn "Docker 隔离功能依赖原生 iptables 规则管理，请在 iptables 模式下使用。"
        return 1
    fi
    if ! command -v docker >/dev/null 2>&1; then
        msg_err "未检测到 Docker 命令，请先安装 Docker。"
        return 1
    fi
    if ! iptables -L DOCKER-USER -n >/dev/null 2>&1; then
        msg_err "未检测到 iptables 的 DOCKER-USER 链！"
        msg_info "请确保 Docker 服务已启动 (systemctl start docker)。"
        msg_info "请检查 /etc/docker/daemon.json 中是否禁用了 iptables (应为 true 或默认)。"
        return 1
    fi
}

apply_docker_guard_rules() {
    install_docker_guard_assets || return 1
    if ! "$DOCKER_GUARD_APPLY_SCRIPT"; then
        msg_err "Docker 隔离规则应用失败。"
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1 && has_systemd_service "docker.service"; then
        systemctl daemon-reload || {
            msg_err "systemctl daemon-reload 执行失败。"
            return 1
        }
        systemctl enable "$DOCKER_GUARD_SERVICE_NAME" >/dev/null 2>&1 || {
            msg_err "Docker 隔离服务启用失败。"
            return 1
        }
        systemctl restart "$DOCKER_GUARD_SERVICE_NAME" >/dev/null 2>&1 || true
    else
        msg_warn "当前系统未检测到可用的 systemd Docker 服务，规则已即时生效，但未配置开机自动重建。"
    fi
}

show_docker_guard_runtime() {
    msg_info "当前 DOCKER-USER 链状态："
    iptables -L DOCKER-USER -n --line-numbers | head -n 20
    if iptables -L "$DOCKER_GUARD_CHAIN" -n --line-numbers >/dev/null 2>&1; then
        draw_line
        msg_info "当前 ${DOCKER_GUARD_CHAIN} 链状态："
        iptables -L "$DOCKER_GUARD_CHAIN" -n --line-numbers | head -n 30
    fi
    if command -v ip6tables >/dev/null 2>&1 && ip6tables -L "$DOCKER_GUARD_CHAIN6" -n --line-numbers >/dev/null 2>&1; then
        draw_line
        msg_info "当前 ${DOCKER_GUARD_CHAIN6} 链状态："
        ip6tables -L "$DOCKER_GUARD_CHAIN6" -n --line-numbers | head -n 30
    fi
}

show_docker_guard_config() {
    local svc_enabled="否" svc_active="否"
    docker_guard_prereq_check || return 1
    if [ ! -r "$DOCKER_GUARD_CONFIG_FILE" ]; then
        msg_warn "当前未配置 Docker 容器隔离。"
        return 1
    fi
    . "$DOCKER_GUARD_CONFIG_FILE"
    menu_header "Docker 隔离配置"
    status_pair "公网网卡" "${DOCKER_GUARD_IFACE:-N/A}"
    status_pair "协议" "${DOCKER_GUARD_PROTOCOL:-N/A}"
    status_pair "放行端口" "${DOCKER_GUARD_PORTS:-全部封锁}"
    status_pair "配置文件" "${DOCKER_GUARD_CONFIG_FILE}"
    status_pair "应用脚本" "${DOCKER_GUARD_APPLY_SCRIPT}"
    if command -v systemctl >/dev/null 2>&1 && has_systemd_service "$DOCKER_GUARD_SERVICE_NAME"; then
        is_systemd_service_enabled "$DOCKER_GUARD_SERVICE_NAME" && svc_enabled="是"
        is_systemd_service_active "$DOCKER_GUARD_SERVICE_NAME" && svc_active="是"
    fi
    status_pair "服务启用" "${svc_enabled}"
    status_pair "服务状态" "${svc_active}"
    draw_line
    show_docker_guard_runtime
}

append_docker_guard_ports() {
    local current_iface current_protocol current_ports new_ports merged_ports
    docker_guard_prereq_check || return 1
    if [ ! -r "$DOCKER_GUARD_CONFIG_FILE" ]; then
        msg_warn "请先执行一次 Docker 容器隔离，生成初始配置。"
        return 1
    fi
    . "$DOCKER_GUARD_CONFIG_FILE"
    current_iface="${DOCKER_GUARD_IFACE:-}"
    current_protocol="${DOCKER_GUARD_PROTOCOL:-tcp}"
    current_ports="${DOCKER_GUARD_PORTS:-}"
    menu_header "追加 Docker 放行端口"
    status_pair "当前网卡" "${current_iface:-N/A}"
    status_pair "当前协议" "${current_protocol}"
    status_pair "当前端口" "${current_ports:-全部封锁}"
    draw_line
    read -p "请输入要追加的宿主机发布端口 (空格或逗号分隔): " new_ports
    new_ports=$(normalize_port_list "$new_ports") || {
        msg_err "端口列表包含无效端口。"
        return 1
    }
    [ -n "$new_ports" ] || {
        msg_warn "未输入任何端口。"
        return 1
    }
    merged_ports=$(normalize_port_list "${current_ports} ${new_ports}") || {
        msg_err "端口合并失败。"
        return 1
    }
    status_pair "追加后端口" "${merged_ports}"
    confirm "将这些端口追加到 Docker 隔离白名单?" || return 0
    write_docker_guard_config "$current_iface" "$current_protocol" "$merged_ports" || return 1
    apply_docker_guard_rules || return 1
    msg_ok "Docker 放行端口已追加。"
    show_docker_guard_runtime
}

secure_docker_isolation() {
    local protocol IFACE PORTS CLEAN_PORTS default_iface
    docker_guard_prereq_check || return 1
    menu_header "Docker 容器安全隔离"
    msg_warn "原理：利用 iptables 的 DOCKER-USER 链，拦截指定网卡进入容器的流量。"
    msg_warn "效果：默认拒绝公网进入容器，仅放行你指定的发布端口。"
    msg_warn "注意：此策略使用 DOCKER-USER 独立托管链，不会覆盖 Docker 自己的动态链。"

    default_iface=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+')
    if [ -z "$default_iface" ]; then
        default_iface=$(ip -br link | grep -vE "lo|docker|veth|br-" | awk '{print $1}' | head -n 1)
    fi

    draw_line
    msg_text "检测到系统网卡："
    ip -br link | grep -vE "lo|docker|veth" | awk '{print $1}'
    draw_line

    read -p "请输入面向公网的网卡名称 [默认: $default_iface]: " IFACE
    IFACE=${IFACE:-$default_iface}
    if ! ip link show "$IFACE" > /dev/null 2>&1; then
        msg_err "错误：网卡 $IFACE 不存在！"
        return 1
    fi

    msg_info "请输入允许【公网访问】的容器端口 (例如 Nginx:80, qBit:8080)"
    msg_info "提示：这里填写宿主机发布端口，不需要输入 SSH 端口。"
    read -p "协议 (tcp/udp/all) [tcp]: " protocol
    protocol=${protocol:-tcp}
    validate_protocol "$protocol" || {
        msg_err "协议无效：$protocol（仅支持 tcp / udp / all）"
        return 1
    }
    read -p "开放端口列表 (空格分隔，直接回车则全部封锁): " PORTS
    CLEAN_PORTS=$(normalize_port_list "$PORTS") || {
        msg_err "端口列表包含无效端口。"
        return 1
    }

    msg_warn "即将对网卡 [$IFACE] 应用 Docker 隔离策略。"
    status_pair "协议" "${protocol}"
    status_pair "放行端口" "${CLEAN_PORTS:-全部封锁}"
    confirm "确定继续吗?" || {
        msg_warn "操作已取消。"
        return 0
    }

    msg_info "正在写入 Docker 隔离配置..."
    write_docker_guard_config "$IFACE" "$protocol" "$CLEAN_PORTS" || return 1
    apply_docker_guard_rules || return 1
    msg_ok "Docker 隔离规则已成功应用！"
    show_docker_guard_runtime
}

# 获取 DNS 状态
get_dns_status() {
    local dns_list=""
    if [ -f /etc/systemd/resolved.conf.d/99-vps-init-suite.conf ]; then
        dns_list=$(awk -F= '/^DNS=/ {print $2; exit}' /etc/systemd/resolved.conf.d/99-vps-init-suite.conf 2>/dev/null)
    fi
    [ -n "$dns_list" ] || dns_list=$(awk '/^[[:space:]]*nameserver[[:space:]]+/ { out = out ? out " " $2 : $2 } END { print out }' /etc/resolv.conf 2>/dev/null)
    if [[ "$dns_list" == *"8.8.8.8"* || "$dns_list" == *"1.1.1.1"* ]]; then
        echo "已优化 (${dns_list:-N/A})"
    else
        echo "默认 (${dns_list:-N/A})"
    fi
}

# 获取协议优先级
get_proto_priority() {
    if grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        echo "IPv4 优先"
    else
        echo "IPv6 优先 (默认)"
    fi
}

get_primary_network_iface() {
    local iface

    iface=$(ip route show default 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }
    ')

    if [ -z "$iface" ]; then
        iface=$(ip -o link show 2>/dev/null | awk -F': ' '
            $2 !~ /^(lo|docker[0-9]*|veth.*|br-.*|virbr.*|tun.*|tap.*|wg.*|tailscale.*|zt.*|dummy.*)$/ {
                print $2
                exit
            }
        ')
    fi

    echo "$iface"
}

get_current_ipv6_address() {
    local iface="${1:-$(get_primary_network_iface)}"
    local addr

    if [ -n "$iface" ]; then
        addr=$(ip -6 addr show dev "$iface" scope global 2>/dev/null | awk '/inet6/ {print $2; exit}')
    else
        addr=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2; exit}')
    fi

    echo "$addr"
}

get_ipv6_status() {
    local addr
    addr=$(get_current_ipv6_address)
    if [ -n "$addr" ]; then
        echo "$addr"
    else
        echo "未获取"
    fi
}

# 获取 BBR 状态
get_bbr_status() {
    local algo=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}' 2>/dev/null)
    local qdisc=$(sysctl net.core.default_qdisc | awk '{print $3}' 2>/dev/null)
    if [ -f "$BBR_SYSCTL_FILE" ]; then
        echo "已配置 (${algo:-unknown} ${qdisc:-unknown})"
    else
        echo "未配置 (${algo:-unknown})"
    fi
}

# 获取当前 SSH 端口（支持多端口，优先读取真实监听状态）
get_current_ssh_ports() {
    local ports=()
    local port cfg

    if command -v ss >/dev/null 2>&1; then
        while IFS= read -r port; do
            validate_port "$port" || continue
            ports+=("$port")
        done < <(
            ss -H -tlnp 2>/dev/null | awk '
                /sshd/ {
                    split($4, arr, ":")
                    print arr[length(arr)]
                }
            ' | awk '!seen[$1]++'
        )
    fi

    if command -v sshd >/dev/null 2>&1; then
        while IFS= read -r port; do
            validate_port "$port" || continue
            ports+=("$port")
        done < <(sshd -T 2>/dev/null | awk '/^port / {print $2}')
    fi

    if [ "${#ports[@]}" -eq 0 ]; then
        for cfg in /etc/ssh/sshd_config "$SSHD_MANAGED_OVERRIDE_FILE" /etc/ssh/sshd_config.d/*.conf; do
            [ -f "$cfg" ] || continue
            while IFS= read -r port; do
                validate_port "$port" || continue
                ports+=("$port")
            done < <(awk '
                /^[[:space:]]*#/ {next}
                /^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2}
            ' "$cfg" 2>/dev/null)
        done
    fi

    if [ "${#ports[@]}" -eq 0 ]; then
        echo "22"
    else
        printf '%s\n' "${ports[@]}" | awk '!seen[$1]++'
    fi
}

get_current_ssh_ports_csv() {
    local csv=""
    local port
    while IFS= read -r port; do
        [ -n "$port" ] || continue
        if [ -n "$csv" ]; then
            csv="${csv},${port}"
        else
            csv="$port"
        fi
    done < <(get_current_ssh_ports)
    echo "${csv:-22}"
}

get_current_ssh_port() {
    get_current_ssh_ports | head -n 1
}

get_current_root_login_status() {
    local status
    if command -v sshd >/dev/null 2>&1; then
        status=$(sshd -T 2>/dev/null | awk '/^permitrootlogin / {print $2; exit}')
    fi
    [ -n "$status" ] || status=$(awk '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*PermitRootLogin[[:space:]]+/ {print $2; exit}
    ' /etc/ssh/sshd_config 2>/dev/null)
    echo "${status:-yes}"
}

# ==============================================================================
# 终端环境美化：为 root 和管理用户的 .bashrc 添加彩色提示符和实用别名
# 使用标记 "# SERVER_MASTER_PS1" 防止重复添加
# ==============================================================================
append_shell_beautify_block() {
    local rc_file="$1"
    local marker="${2:-# SERVER_MASTER_PS1}"

    if ! grep -qF "$marker" "$rc_file" 2>/dev/null; then
        cat >> "$rc_file" <<'EOF'
# SERVER_MASTER_PS1
export PS1='\[\033[1;32m\]\u\[\033[0m\]@\[\033[1;34m\]\h\[\033[0m\] \[\033[1;31m\]\w\[\033[0m\] # '
alias ls='ls --color=auto'
alias ll='ls -l'
alias l='ls -lA'
EOF
        msg_ok "终端美化已添加到 ${rc_file}"
    else
        msg_info "终端美化已存在于 ${rc_file}，跳过"
    fi
}

apply_terminal_beautification() {
    local marker="# SERVER_MASTER_PS1"
    local bashrc_files=("/root/.bashrc")

    if [ -n "$AUTO_DEPLOY_USER" ] && id "$AUTO_DEPLOY_USER" >/dev/null 2>&1; then
        local user_home
        user_home=$(eval echo "~${AUTO_DEPLOY_USER}")
        [ -f "${user_home}/.bashrc" ] && bashrc_files+=("${user_home}/.bashrc")
    fi

    for rc_file in "${bashrc_files[@]}"; do
        append_shell_beautify_block "$rc_file" "$marker"
    done
}

# ==============================================================================
# DNS 解析优化：配置 8.8.8.8 + 1.1.1.1 作为 DNS 服务器
# 自动检测 systemd-resolved，适配两种 DNS 管理方式
# ==============================================================================
apply_dns_optimization() {
    if is_systemd_service_active "systemd-resolved.service"; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/99-vps-init-suite.conf <<EOF
[Resolve]
DNS=8.8.8.8 1.1.1.1
FallbackDNS=
EOF
        systemctl restart systemd-resolved >/dev/null 2>&1 || {
            msg_err "systemd-resolved 重启失败，DNS 优化未完成。"
            return 1
        }
    else
        [ -e /etc/resolv.conf ] && backup_file_with_timestamp /etc/resolv.conf >/dev/null 2>&1 || true
        printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
    fi
    msg_ok "DNS 优化完成"
}

apply_ipv6_runtime_sysctl() {
    local iface="$1"

    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.accept_ra=2 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.accept_ra=2 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.autoconf=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.autoconf=1 >/dev/null 2>&1 || true

    if [ -n "$iface" ]; then
        sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=0" >/dev/null 2>&1 || true
        sysctl -w "net.ipv6.conf.${iface}.accept_ra=2" >/dev/null 2>&1 || true
        sysctl -w "net.ipv6.conf.${iface}.autoconf=1" >/dev/null 2>&1 || true
    fi
}

write_ipv6_sysctl_config() {
    mkdir -p /etc/sysctl.d
    cat > "$IPV6_SYSCTL_FILE" <<EOF
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.ipv6.conf.all.autoconf = 1
net.ipv6.conf.default.autoconf = 1
EOF

    sysctl -p "$IPV6_SYSCTL_FILE" >/dev/null 2>&1
}

get_iface_mac_address() {
    local iface="$1"
    [ -n "$iface" ] || return 1
    [ -r "/sys/class/net/${iface}/address" ] || return 1
    tr '[:lower:]' '[:upper:]' < "/sys/class/net/${iface}/address" 2>/dev/null
}

get_oci_vnic_ipv6_info() {
    local iface="$1"
    local mac

    [ -n "$iface" ] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    command -v python3 >/dev/null 2>&1 || return 1

    mac=$(get_iface_mac_address "$iface") || return 1
    [ -n "$mac" ] || return 1

    curl -fsS --connect-timeout 3 --max-time 8 \
        -H 'Authorization: Bearer Oracle' \
        http://169.254.169.254/opc/v2/vnics/ 2>/dev/null | \
        python3 - "$mac" <<'PY'
import json
import sys

target_mac = sys.argv[1].strip().upper()
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

for item in data if isinstance(data, list) else []:
    mac = str(item.get("macAddr", "")).strip().upper()
    if mac != target_mac:
        continue
    ipv6_list = item.get("ipv6Addresses") or []
    ipv6 = ipv6_list[0].strip() if ipv6_list else ""
    gateway = str(item.get("ipv6VirtualRouterIp", "")).strip()
    subnet = str(item.get("ipv6SubnetCidrBlock", "")).strip()
    if ipv6:
        print(f"{ipv6}|{gateway}|{subnet}")
        sys.exit(0)

sys.exit(1)
PY
}

apply_oci_ipv6_runtime_fix() {
    local iface="$1"
    local ipv6_info ipv6_addr ipv6_gw ipv6_subnet

    [ -n "$iface" ] || return 1
    ipv6_info=$(get_oci_vnic_ipv6_info "$iface") || return 1
    IFS='|' read -r ipv6_addr ipv6_gw ipv6_subnet <<EOF
$ipv6_info
EOF

    [ -n "$ipv6_addr" ] || return 1

    if ! ip -6 addr show dev "$iface" 2>/dev/null | grep -Fq "${ipv6_addr}/128"; then
        ip -6 addr add "${ipv6_addr}/128" dev "$iface" >/dev/null 2>&1 || return 1
    fi

    [ -n "$ipv6_subnet" ] && ip -6 route replace "$ipv6_subnet" dev "$iface" metric 256 >/dev/null 2>&1 || true
    [ -n "$ipv6_gw" ] && ip -6 route replace default via "$ipv6_gw" dev "$iface" metric 512 >/dev/null 2>&1 || true

    ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -Fq "${ipv6_addr}/128"
}

apply_ifupdown_oci_ipv6_fix() {
    local iface="$1"
    local ipv6_info ipv6_addr ipv6_gw ipv6_subnet target_file backup_file

    [ -n "$iface" ] || return 1
    [ -f /etc/network/interfaces ] || return 1

    ipv6_info=$(get_oci_vnic_ipv6_info "$iface") || return 1
    IFS='|' read -r ipv6_addr ipv6_gw ipv6_subnet <<EOF
$ipv6_info
EOF

    [ -n "$ipv6_addr" ] || return 1
    [ -n "$ipv6_gw" ] || return 1

    target_file=$(grep -R -l -E "^[[:space:]]*iface[[:space:]]+${iface}[[:space:]]+inet6[[:space:]]+" /etc/network/interfaces /etc/network/interfaces.d 2>/dev/null | head -n 1)

    if [ -n "$target_file" ] && [ -f "$target_file" ]; then
        backup_file_with_timestamp "$target_file" >/dev/null 2>&1 || true
        python3 - "$target_file" "$iface" "$ipv6_addr" "$ipv6_gw" "$ipv6_subnet" <<'PY' || return 1
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
iface = sys.argv[2]
ipv6 = sys.argv[3]
gateway = sys.argv[4]
subnet = sys.argv[5]

lines = path.read_text().splitlines()
out = []
i = 0
re_iface = re.compile(rf'^\s*iface\s+{re.escape(iface)}\s+inet6\s+\S+\s*$')
re_new_block = re.compile(r'^\s*(iface|auto|allow-\S+|mapping|source|source-directory)\b')
managed = False

while i < len(lines):
    line = lines[i]
    if re_iface.match(line):
        managed = True
        out.append(f"iface {iface} inet6 static")
        out.append(f"    address {ipv6}/128")
        out.append(f"    gateway {gateway}")
        out.append("    accept_ra 2")
        if subnet:
            out.append(f"    up ip -6 route replace {subnet} dev {iface} metric 256 || true")
        out.append(f"    up ip -6 route replace default via {gateway} dev {iface} metric 512 || true")
        i += 1
        while i < len(lines) and not re_new_block.match(lines[i]):
            i += 1
        continue
    out.append(line)
    i += 1

if not managed:
    if out and out[-1].strip():
        out.append("")
    out.append(f"iface {iface} inet6 static")
    out.append(f"    address {ipv6}/128")
    out.append(f"    gateway {gateway}")
    out.append("    accept_ra 2")
    if subnet:
        out.append(f"    up ip -6 route replace {subnet} dev {iface} metric 256 || true")
    out.append(f"    up ip -6 route replace default via {gateway} dev {iface} metric 512 || true")

path.write_text("\n".join(out) + "\n")
PY
        return 0
    fi

    backup_file="${IFUPDOWN_OCI_IPV6_FIX_FILE}"
    mkdir -p "$(dirname "$backup_file")"
    cat > "$backup_file" <<EOF
iface ${iface} inet6 static
    address ${ipv6_addr}/128
    gateway ${ipv6_gw}
    accept_ra 2
EOF
    if [ -n "$ipv6_subnet" ]; then
        cat >> "$backup_file" <<EOF
    up ip -6 route replace ${ipv6_subnet} dev ${iface} metric 256 || true
EOF
    fi
    cat >> "$backup_file" <<EOF
    up ip -6 route replace default via ${ipv6_gw} dev ${iface} metric 512 || true
EOF
    return 0
}

apply_netplan_ipv6_fix() {
    local iface="$1"

    [ -n "$iface" ] || return 1
    command -v netplan >/dev/null 2>&1 || return 1
    [ -d /etc/netplan ] || return 1

    cat > "$NETPLAN_IPV6_FIX_FILE" <<EOF
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp6: true
      accept-ra: true
EOF

    netplan generate >/dev/null 2>&1 || return 1
    netplan apply >/dev/null 2>&1 || return 1
    return 0
}

apply_nmcli_ipv6_fix() {
    local iface="$1"
    local conn_uuid

    [ -n "$iface" ] || return 1
    command -v nmcli >/dev/null 2>&1 || return 1
    is_systemd_service_active "NetworkManager.service" || is_systemd_service_enabled "NetworkManager.service" || return 1

    conn_uuid=$(nmcli -t -f UUID,DEVICE connection show --active 2>/dev/null | awk -F: -v iface="$iface" '$2 == iface {print $1; exit}')
    [ -n "$conn_uuid" ] || conn_uuid=$(nmcli -t -f UUID,DEVICE connection show 2>/dev/null | awk -F: -v iface="$iface" '$2 == iface {print $1; exit}')
    [ -n "$conn_uuid" ] || return 1

    nmcli connection modify "$conn_uuid" \
        connection.autoconnect yes \
        ipv6.method auto \
        ipv6.addr-gen-mode stable-privacy >/dev/null 2>&1 || return 1

    nmcli connection up uuid "$conn_uuid" >/dev/null 2>&1 || nmcli device reapply "$iface" >/dev/null 2>&1 || true
    return 0
}

refresh_ipv6_address() {
    local iface="$1"

    [ -n "$iface" ] || return 1

    if command -v networkctl >/dev/null 2>&1 && \
       (is_systemd_service_active "systemd-networkd.service" || is_systemd_service_enabled "systemd-networkd.service"); then
        networkctl reconfigure "$iface" >/dev/null 2>&1 || true
    fi

    if command -v dhclient >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 20 dhclient -6 -1 "$iface" >/dev/null 2>&1 || true
        else
            dhclient -6 -1 "$iface" >/dev/null 2>&1 || true
        fi
    fi

    if command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd -n "$iface" >/dev/null 2>&1 || true
    fi
}

get_oci_ipv6_metadata_address() {
    local iface ipv6_info ipv6_addr ipv6_gw ipv6_subnet

    iface="${1:-$(get_primary_network_iface)}"
    [ -n "$iface" ] || return 1

    ipv6_info=$(get_oci_vnic_ipv6_info "$iface") || return 1
    IFS='|' read -r ipv6_addr ipv6_gw ipv6_subnet <<EOF
$ipv6_info
EOF

    [ -n "$ipv6_addr" ] || return 1
    printf '%s\n' "$ipv6_addr"
}

get_oci_ipv6_service_status() {
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "不支持"
        return 0
    fi

    if is_systemd_service_active "$OCI_IPV6_SERVICE_NAME"; then
        echo "运行中"
    elif is_systemd_service_enabled "$OCI_IPV6_SERVICE_NAME"; then
        echo "已启用"
    elif has_systemd_service "$OCI_IPV6_SERVICE_NAME"; then
        echo "未启动"
    else
        echo "未安装"
    fi
}

write_oci_ipv6_apply_script() {
    cat > "$OCI_IPV6_APPLY_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

iface=$(ip route show default 2>/dev/null | awk '
    {
        for (i = 1; i <= NF; i++) {
            if ($i == "dev") {
                print $(i + 1)
                exit
            }
        }
    }
')

if [ -z "$iface" ]; then
    iface=$(ip -o link show 2>/dev/null | awk -F': ' '
        $2 !~ /^(lo|docker[0-9]*|veth.*|br-.*|virbr.*|tun.*|tap.*|wg.*|tailscale.*|zt.*|dummy.*)$/ {
            print $2
            exit
        }
    ')
fi

[ -n "$iface" ] || exit 1
[ -r "/sys/class/net/${iface}/address" ] || exit 1

mac=$(tr '[:lower:]' '[:upper:]' < "/sys/class/net/${iface}/address")

ipv6_info=$(
    curl -fsS --connect-timeout 3 --max-time 8 \
        -H 'Authorization: Bearer Oracle' \
        http://169.254.169.254/opc/v2/vnics/ 2>/dev/null | \
        python3 - "$mac" <<'PY'
import json
import sys

target_mac = sys.argv[1].strip().upper()
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

for item in data if isinstance(data, list) else []:
    mac = str(item.get("macAddr", "")).strip().upper()
    if mac != target_mac:
        continue
    ipv6_list = item.get("ipv6Addresses") or []
    ipv6 = ipv6_list[0].strip() if ipv6_list else ""
    gateway = str(item.get("ipv6VirtualRouterIp", "")).strip()
    subnet = str(item.get("ipv6SubnetCidrBlock", "")).strip()
    if ipv6:
        print(f"{ipv6}|{gateway}|{subnet}")
        sys.exit(0)

sys.exit(1)
PY
)

IFS='|' read -r ipv6_addr ipv6_gw ipv6_subnet <<EOF2
$ipv6_info
EOF2

[ -n "${ipv6_addr:-}" ] || exit 1

sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.accept_ra=2 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.accept_ra=2 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.autoconf=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.autoconf=1 >/dev/null 2>&1 || true
sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=0" >/dev/null 2>&1 || true
sysctl -w "net.ipv6.conf.${iface}.accept_ra=2" >/dev/null 2>&1 || true
sysctl -w "net.ipv6.conf.${iface}.autoconf=1" >/dev/null 2>&1 || true

if ! ip -6 addr show dev "$iface" 2>/dev/null | grep -Fq "${ipv6_addr}/128"; then
    ip -6 addr add "${ipv6_addr}/128" dev "$iface"
fi

[ -n "${ipv6_subnet:-}" ] && ip -6 route replace "$ipv6_subnet" dev "$iface" metric 256 >/dev/null 2>&1 || true
[ -n "${ipv6_gw:-}" ] && ip -6 route replace default via "$ipv6_gw" dev "$iface" metric 512 >/dev/null 2>&1 || true
EOF

    chmod 755 "$OCI_IPV6_APPLY_SCRIPT"
}

write_oci_ipv6_service_unit() {
    cat > "$OCI_IPV6_SERVICE_PATH" <<EOF
[Unit]
Description=VPS Suite OCI IPv6 Bootstrap
After=network-online.target
Wants=network-online.target
ConditionPathExists=${OCI_IPV6_APPLY_SCRIPT}

[Service]
Type=oneshot
ExecStart=${OCI_IPV6_APPLY_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

install_oci_ipv6_service() {
    local iface ipv6_info ipv6_addr ipv6_gw ipv6_subnet current_ipv6

    command -v systemctl >/dev/null 2>&1 || {
        msg_err "当前系统未提供 systemd，无法安装甲骨文 IPv6 服务。"
        return 1
    }

    iface=$(get_primary_network_iface)
    [ -n "$iface" ] || {
        msg_err "未检测到主网卡。"
        return 1
    }

    ipv6_info=$(get_oci_vnic_ipv6_info "$iface") || {
        msg_err "未从甲骨文元数据拿到 IPv6。请先在 OCI 控制台为主网卡分配 IPv6。"
        return 1
    }
    IFS='|' read -r ipv6_addr ipv6_gw ipv6_subnet <<EOF
$ipv6_info
EOF

    [ -n "$ipv6_addr" ] || {
        msg_err "甲骨文元数据中没有可用的 IPv6 地址。"
        return 1
    }

    write_ipv6_sysctl_config || {
        msg_err "IPv6 内核参数写入失败。"
        return 1
    }

    apply_ipv6_runtime_sysctl "$iface"
    write_oci_ipv6_apply_script || return 1
    write_oci_ipv6_service_unit || return 1

    systemctl daemon-reload || return 1
    systemctl enable --now "$OCI_IPV6_SERVICE_NAME" >/dev/null 2>&1 || {
        msg_err "甲骨文 IPv6 服务启动失败。"
        return 1
    }

    apply_oci_ipv6_runtime_fix "$iface" || true
    sleep 1
    current_ipv6=$(get_current_ipv6_address "$iface")

    msg_ok "甲骨文 IPv6 服务已启用。"
    msg_info "网卡: ${iface}"
    msg_info "元数据 IPv6: ${ipv6_addr}"
    [ -n "$ipv6_gw" ] && msg_info "IPv6 网关: ${ipv6_gw}"
    [ -n "$current_ipv6" ] && msg_info "当前 IPv6: ${current_ipv6}"
    return 0
}

repair_ipv6_autoconf() {
    local iface before_ipv6 after_ipv6
    local netplan_fixed=0 nmcli_fixed=0 ifupdown_fixed=0 oci_runtime_fixed=0

    iface=$(get_primary_network_iface)
    [ -n "$iface" ] || {
        msg_err "未检测到主网卡，无法修复 IPv6。"
        return 1
    }

    before_ipv6=$(get_current_ipv6_address "$iface")

    write_ipv6_sysctl_config || {
        msg_err "IPv6 内核参数加载失败。"
        return 1
    }

    apply_ipv6_runtime_sysctl "$iface"
    apply_netplan_ipv6_fix "$iface" && netplan_fixed=1
    apply_nmcli_ipv6_fix "$iface" && nmcli_fixed=1
    apply_ifupdown_oci_ipv6_fix "$iface" && ifupdown_fixed=1
    refresh_ipv6_address "$iface"
    apply_oci_ipv6_runtime_fix "$iface" && oci_runtime_fixed=1
    sleep 2

    after_ipv6=$(get_current_ipv6_address "$iface")

    if [ -n "$after_ipv6" ]; then
        msg_ok "IPv6 修复完成：${after_ipv6}"
        return 0
    fi

    if [ -n "$before_ipv6" ]; then
        msg_ok "IPv6 已存在：${before_ipv6}"
        return 0
    fi

    if [ "$ifupdown_fixed" -eq 1 ] || [ "$oci_runtime_fixed" -eq 1 ]; then
        msg_warn "检测到 Oracle Cloud 元数据已分配 IPv6，已写入静态配置，但当前仍未拿到 IPv6。"
    elif [ "$netplan_fixed" -eq 1 ] || [ "$nmcli_fixed" -eq 1 ]; then
        msg_warn "已写入 IPv6 自动获取配置，但当前仍未拿到 IPv6。"
    else
        msg_warn "已启用 IPv6 自动获取参数，但当前仍未拿到 IPv6。"
    fi
    return 1
}

# 获取系统基本信息
get_system_info() {
    status_pair "主机名" "$(hostname)"
    status_pair "系统版本" "$(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    status_pair "Linux 版本" "$(uname -r)"
}

# 获取 CPU 信息
get_cpu_info() {
    local cpu_arch=$(uname -m)
    local cpu_model
    cpu_model=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^[ \t]*//')
    if [ -z "$cpu_model" ]; then
        cpu_model=$(lscpu | awk -F: '/Model name/ {print $2; exit}' | sed 's/^[ \t]*//')
    fi
    # 将任何换行、制表与多重空格归一为单个空格，避免输出断行
    cpu_model=$(echo "$cpu_model" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^ //;s/ $//')
    local cpu_cores=$(nproc)

    # 尝试从 lscpu 或 /proc/cpuinfo 获取频率（优先 MHz 数值）
    local cpu_freq_raw
    cpu_freq_raw=$(lscpu | awk -F: '/CPU MHz/ {gsub(/^[ \t]*/,"",$2); print $2; exit}' 2>/dev/null)
    if [ -z "$cpu_freq_raw" ]; then
        cpu_freq_raw=$(awk -F: '/cpu MHz/ {gsub(/^[ \t]*/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
    fi

    local cpu_freq_display=""
    if [ -n "$cpu_freq_raw" ]; then
        # 如果是纯数字，视为 MHz
        if echo "$cpu_freq_raw" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
            cpu_freq_display=$(awk "BEGIN{printf \"%.2f MHz\", $cpu_freq_raw}")
        else
            cpu_freq_display="$cpu_freq_raw"
        fi
    else
        # 从型号字符串中提取带单位的频率（例如: "@ 2.0GHz" 或 "2.0 GHz"）
        if echo "$cpu_model" | grep -Ei -q '([0-9]+(\.[0-9]+)?)\s*(ghz|mhz)'; then
            local freq_num
            local freq_unit
            freq_num=$(echo "$cpu_model" | sed -n -E 's/.*([0-9]+(\.[0-9]+)?)\s*(GHz|MHz).*/\1/ip')
            freq_unit=$(echo "$cpu_model" | sed -n -E 's/.*([0-9]+(\.[0-9]+)?)\s*(GHz|MHz).*/\3/ip' | tr '[:upper:]' '[:lower:]')
            if [ -n "$freq_num" ] && [ -n "$freq_unit" ]; then
                if [ "$freq_unit" = "ghz" ]; then
                    cpu_freq_display="${freq_num} GHz"
                else
                    cpu_freq_display="${freq_num} MHz"
                fi
            fi
        fi
    fi

    [ -z "$cpu_freq_display" ] && cpu_freq_display="N/A"

    status_pair "CPU 架构" "${cpu_arch}"
    status_pair "CPU 型号" "${cpu_model}"
    status_pair "CPU 核心数" "${cpu_cores}"
    status_pair "CPU 频率" "${cpu_freq_display}"
}

# 获取内存与磁盘信息
get_memory_and_disk_info() {
    local mem_total=$(free -m | awk '/Mem:/{print $2}')
    local mem_used=$(free -m | awk '/Mem:/{print $3}')
    local mem_pct=$(awk "BEGIN {printf \"%.2f\", $mem_used/$mem_total*100}")
    local swap_total=$(free -m | awk '/Swap:/{print $2}')
    local swap_used=$(free -m | awk '/Swap:/{print $3}')
    local swap_pct=0
    [ "$swap_total" -gt 0 ] && swap_pct=$(awk "BEGIN {printf \"%.2f\", $swap_used/$swap_total*100}")

    local disk_total=$(df -h / | awk 'NR==2{print $2}')
    local disk_used=$(df -h / | awk 'NR==2{print $3}')
    local disk_pct=$(df -h / | awk 'NR==2{print $5}')

    status_pair "物理内存" "${mem_used}/${mem_total}M (${mem_pct}%)"
    status_pair "虚拟内存" "${swap_used}/${swap_total}M (${swap_pct}%)"
    status_pair "硬盘占用" "${disk_used}/${disk_total} (${disk_pct})"
}

# 获取网络流量信息
get_network_traffic_info() {
    local rx_bytes=$(awk '{if($1~"eth0|enp|ens|eno") sum+=$2} END {print sum}' /proc/net/dev)
    local tx_bytes=$(awk '{if($1~"eth0|enp|ens|eno") sum+=$10} END {print sum}' /proc/net/dev)
    local rx_gb=$(awk "BEGIN {printf \"%.2f\", $rx_bytes/1024/1024/1024}")
    local tx_gb=$(awk "BEGIN {printf \"%.2f\", $tx_bytes/1024/1024/1024}")
    status_pair "总接收" "${rx_gb} GB"
    status_pair "总发送" "${tx_gb} GB"
    status_pair "网络算法" "$(get_bbr_status)"
}

# 获取地理位置与 IP 信息
get_geo_and_ip_info() {
    local ip_info=$(curl -s --connect-timeout 3 --max-time 8 https://ipapi.co/json/)
    local isp=$(echo "$ip_info" | jq -r '.org // "N/A"' 2>/dev/null || echo "N/A")
    local geo=$(echo "$ip_info" | jq -r '(.city // "N/A") + " " + (.country_name // "N/A")' 2>/dev/null || echo "N/A")
    local ipv4=$(curl -s4 --connect-timeout 3 --max-time 8 ip.sb || echo "N/A")
    local ipv6=$(curl -s6 --connect-timeout 3 --max-time 8 ip.sb || echo "N/A")

    status_pair "运营商" "${isp}"
    status_pair "IPv4 地址" "${ipv4}"
    status_pair "IPv6 地址" "${ipv6}"
    status_pair "DNS 地址" "$(if [ -f /etc/systemd/resolved.conf.d/99-vps-init-suite.conf ]; then awk -F= '/^DNS=/ {print $2; exit}' /etc/systemd/resolved.conf.d/99-vps-init-suite.conf; else grep nameserver /etc/resolv.conf | awk '{print $2}' | tr '\n' ' '; fi)"
    status_pair "地理位置" "${geo}"
    status_pair "系统时间" "$(date "+%Z %Y-%m-%d %I:%M %p")"
}

# --- [8. 系统深度体检报告] ---
show_system_report() {
    clear
    menu_header "8. 系统深度体检报告"

    get_system_info
    draw_line
    get_cpu_info
    draw_line
    get_memory_and_disk_info
    draw_line
    get_network_traffic_info
    draw_line
    get_geo_and_ip_info
    draw_line
    pause
}

apply_sshd_changes() {
    local success_msg="${1:-}"
    local ssh_backup="${2:-}"
    local ssh_service
    local current_ports

    ssh_service=$(get_ssh_service_name)
    if [ -z "$ssh_backup" ]; then
        ssh_backup=$(backup_file_with_timestamp /etc/ssh/sshd_config) || {
            msg_err "备份 sshd 配置失败。"
            return 1
        }
    fi

    cleanup_ssh_socket_activation
    enable_ssh_service "$ssh_service"

    if ! sshd -t; then
        msg_err "sshd 配置校验失败，正在回滚。"
        restore_sshd_backup_state "$ssh_backup"
        return 1
    fi

    if ! restart_ssh_service "$ssh_service"; then
        msg_err "SSH 服务重启失败，正在回滚。"
        restore_sshd_backup_state "$ssh_backup"
        restart_ssh_service "$ssh_service" || true
        return 1
    fi

    current_ports=$(get_current_ssh_ports_csv)
    update_fail2ban_ssh_port "$current_ports" || msg_warn "Fail2Ban 端口同步失败，请稍后手动检查。"
    [ -n "$success_msg" ] && msg_ok "$success_msg"
    return 0
}

is_ssh_port_listening() {
    local port="$1"
    validate_port "$port" || return 1
    ss -H -tln 2>/dev/null | awk -v p="$port" '
        {
            local_addr=$4
            sub(/.*:/, "", local_addr)
            if (local_addr == p) {
                found=1
                exit
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

firewalld_open_tcp_port() {
    local port="$1"
    command -v firewall-cmd >/dev/null 2>&1 || {
        msg_err "当前防火墙由 firewalld 接管，但系统未找到 firewall-cmd。"
        return 1
    }

    firewall-cmd --quiet --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || return 1
    firewall-cmd --quiet --add-port="${port}/tcp" >/dev/null 2>&1 || \
        firewall-cmd --reload >/dev/null 2>&1 || return 1
    return 0
}

firewalld_close_tcp_port() {
    local port="$1"
    command -v firewall-cmd >/dev/null 2>&1 || return 1

    firewall-cmd --quiet --query-port="${port}/tcp" >/dev/null 2>&1 && \
        firewall-cmd --quiet --remove-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --quiet --permanent --query-port="${port}/tcp" >/dev/null 2>&1 && \
        firewall-cmd --quiet --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    return 0
}

prepare_firewall_for_ssh_port_change() {
    local backend="$1"
    local new_port="$2"

    case "$backend" in
        firewalld)
            firewalld_open_tcp_port "$new_port" || {
                msg_err "firewalld 预放行新 SSH 端口 ${new_port} 失败。"
                return 1
            }
            msg_ok "firewalld: 已预放行新 SSH 端口 ${new_port}/tcp"
            ;;
        nft|iptables)
            firewall_open_port "$backend" tcp "$new_port" || {
                msg_err "${backend}: 预放行新 SSH 端口 ${new_port} 失败。"
                return 1
            }
            save_iptables
            ;;
        *)
            msg_warn "未识别的防火墙后端 ${backend}，跳过新端口预放行。"
            ;;
    esac
    return 0
}

rollback_firewall_for_ssh_port_change() {
    local backend="$1"
    local new_port="$2"

    case "$backend" in
        firewalld)
            firewalld_close_tcp_port "$new_port" >/dev/null 2>&1 || true
            ;;
        nft|iptables)
            firewall_close_port "$backend" "$new_port" >/dev/null 2>&1 || true
            save_iptables
            ;;
    esac
}

finalize_firewall_after_ssh_port_change() {
    local backend="$1"
    local old_port="$2"
    local new_port="$3"
    local close_old_on_success="${4:-1}"

    [ "$close_old_on_success" -eq 1 ] || return 0
    [ -n "$old_port" ] || return 0
    [ "$old_port" = "$new_port" ] && return 0

    case "$backend" in
        firewalld)
            if command -v firewall-cmd >/dev/null 2>&1 && \
               firewall-cmd --permanent --query-port="${old_port}/tcp" >/dev/null 2>&1; then
                firewalld_close_tcp_port "$old_port" || true
                msg_ok "firewalld: 已移除旧 SSH 端口 ${old_port}/tcp 的显式放行规则"
            else
                msg_warn "firewalld 模式下旧 SSH 端口 ${old_port} 可能仍由 service/zone 规则放行，请按需手动检查。"
            fi
            ;;
        nft|iptables)
            firewall_close_port "$backend" "$old_port" >/dev/null 2>&1 || true
            save_iptables
            ;;
    esac
}

change_ssh_port_safely() {
    local new_port="${1:-}"
    local success_msg="${2:-}"
    local close_old_on_success="${3:-1}"
    local ssh_backup="${4:-}"
    local old_port backend ssh_service current_ports

    validate_port "$new_port" || {
        msg_err "端口无效：${new_port}"
        return 1
    }

    old_port=$(get_current_ssh_port)
    if [ -z "$ssh_backup" ]; then
        ssh_backup=$(backup_file_with_timestamp /etc/ssh/sshd_config) || {
            msg_err "备份 sshd 配置失败。"
            return 1
        }
    fi

    if [ "$old_port" = "$new_port" ]; then
        return apply_sshd_changes "${success_msg:-SSH 配置已更新}" "$ssh_backup"
    fi

    backend=$(detect_firewall_backend)
    ssh_service=$(get_ssh_service_name)

    set_sshd_directive "Port" "$new_port"
    handle_selinux_ssh_port "$new_port" || {
        restore_sshd_backup_state "$ssh_backup"
        return 1
    }

    prepare_firewall_for_ssh_port_change "$backend" "$new_port" || {
        restore_sshd_backup_state "$ssh_backup"
        return 1
    }

    cleanup_ssh_socket_activation
    enable_ssh_service "$ssh_service"

    if ! sshd -t; then
        msg_err "新的 sshd 配置校验失败，正在回滚 SSH 配置与预放行规则。"
        restore_sshd_backup_state "$ssh_backup"
        rollback_firewall_for_ssh_port_change "$backend" "$new_port"
        return 1
    fi

    if ! restart_ssh_service "$ssh_service"; then
        msg_err "SSH 服务重启失败，正在回滚 SSH 配置与预放行规则。"
        restore_sshd_backup_state "$ssh_backup"
        restart_ssh_service "$ssh_service" || true
        rollback_firewall_for_ssh_port_change "$backend" "$new_port"
        return 1
    fi

    sleep 1
    if ! is_ssh_port_listening "$new_port"; then
        msg_err "未检测到 SSH 正在监听新端口 ${new_port}，正在回滚。"
        restore_sshd_backup_state "$ssh_backup"
        restart_ssh_service "$ssh_service" || true
        rollback_firewall_for_ssh_port_change "$backend" "$new_port"
        return 1
    fi

    finalize_firewall_after_ssh_port_change "$backend" "$old_port" "$new_port" "$close_old_on_success"

    current_ports=$(get_current_ssh_ports_csv)
    update_fail2ban_ssh_port "$current_ports" || msg_warn "Fail2Ban 端口同步失败，请稍后手动检查。"
    [ -n "$success_msg" ] && msg_ok "$success_msg"
    msg_info "SSH 端口切换完成：${old_port} -> ${new_port}"
    return 0
}

run_integrated_ssh_user_firewall_init() {
    local ssh_port new_user new_user_pass root_pass allow_ping ssh_service ssh_backup
    local old_port current_root_status user_exists=0

    clear
    menu_header "一键整合初始化"
    status_pair "功能说明" "创建管理用户 / 修改SSH端口 / 禁用Root / 启用密码 / 配置防火墙 / 可选PING"
    draw_line

    while true; do
        read -p "管理用户名 [默认: ${DEFAULT_AUTO_INIT_USER}]: " new_user
        new_user=${new_user:-$DEFAULT_AUTO_INIT_USER}
        if [[ "$new_user" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]]; then
            break
        fi
        msg_warn "用户名格式无效，请重新输入。"
    done

    while true; do
        read -p "SSH端口[默认: ${DEFAULT_SSH_PORT}]: " ssh_port
        ssh_port=${ssh_port:-$DEFAULT_SSH_PORT}
        if validate_port "$ssh_port"; then
            break
        fi
        msg_warn "端口必须是 1-65535 的数字。"
    done

    if id "$new_user" >/dev/null 2>&1; then
        user_exists=1
        msg_warn "用户 ${new_user} 已存在，将保留用户并更新密码/权限。"
    fi

    prompt_password_twice "用户 ${new_user}" new_user_pass
    prompt_password_twice "root" root_pass

    read -p "是否允许PING?(Y/n): " allow_ping
    allow_ping=${allow_ping:-Y}

    draw_line
    status_pair "管理用户" "${new_user}"
    status_pair "SSH端口" "${ssh_port}"
    status_pair "Root远程登录" "禁用"
    status_pair "密码登录" "启用"
    status_pair "PING" "$([[ "$allow_ping" =~ ^[Nn]$ ]] && echo "禁止" || echo "允许")"
    draw_line
    confirm "确认执行整合初始化?" || return 0

    ensure_ssh_server_installed || return 1
    ssh_service=$(get_ssh_service_name)
    enable_ssh_service "$ssh_service"
    cleanup_ssh_socket_activation

    old_port=$(get_current_ssh_port)
    current_root_status=$(get_current_root_login_status)

    if [ "$user_exists" -eq 0 ]; then
        useradd -m -s /bin/bash "$new_user" || {
            msg_err "创建用户 ${new_user} 失败。"
            return 1
        }
    fi
    echo "${new_user}:${new_user_pass}" | chpasswd || {
        msg_err "设置用户 ${new_user} 密码失败。"
        return 1
    }
    echo "root:${root_pass}" | chpasswd || {
        msg_err "设置 root 密码失败。"
        return 1
    }
    ensure_user_in_admin_group "$new_user"

    ssh_backup=$(backup_file_with_timestamp /etc/ssh/sshd_config) || {
        msg_err "备份 sshd 配置失败。"
        return 1
    }

    set_sshd_directive "PasswordAuthentication" "yes"
    set_sshd_directive "PermitRootLogin" "no"

    change_ssh_port_safely "$ssh_port" "SSH 配置已应用" 0 "$ssh_backup" || return 1

    enable_iptables || return 1

    if [[ "$allow_ping" =~ ^[Nn]$ ]]; then
        FORCE_IPTABLES=1 disable_ping || return 1
    else
        FORCE_IPTABLES=1 enable_ping || return 1
    fi

    save_iptables

    draw_line
    msg_ok "整合初始化已完成。"
    status_pair "sshd备份" "${ssh_backup}"
    status_pair "旧SSH端口" "${old_port}"
    status_pair "新SSH端口" "${ssh_port}"
    status_pair "管理用户" "${new_user}"
    status_pair "Root远程登录" "${current_root_status} -> no"
    status_pair "防火墙后端" "iptables"
    status_pair "PING状态" "$([[ "$allow_ping" =~ ^[Nn]$ ]] && echo "禁止" || echo "允许")"
    draw_line
    msg_warn "请立即新开终端测试登录：ssh -p ${ssh_port} ${new_user}@你的服务器IP"
}
