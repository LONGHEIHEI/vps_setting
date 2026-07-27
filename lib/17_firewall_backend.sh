save_iptables() {
    local backend
    backend=$(detect_firewall_backend)
    if [ "$backend" = "nft" ]; then
        mkdir -p /etc
        nft list ruleset > /etc/nftables.conf 2>/dev/null || true
        [ -x "$(command -v netfilter-persistent)" ] && netfilter-persistent save >/dev/null 2>&1 || true
    else
        mkdir -p "$IPTABLES_RULE_DIR"
        iptables-save > "$IPTABLES_RULES_V4" 2>/dev/null || true
        if command -v ip6tables >/dev/null 2>&1; then
            ip6tables-save > "$IPTABLES_RULES_V6" 2>/dev/null || true
        fi
    fi
}

# 检测防火墙后端
detect_firewall_backend() {
    local remembered_backend=""
    if [ "${FORCE_IPTABLES:-0}" != "0" ]; then echo "iptables"; return; fi
    remembered_backend=$(get_firewall_backend_state 2>/dev/null || true)
    if [ -f "/.dockerenv" ] || grep -qE '/docker/|/kubepods/|/lxc/' /proc/1/cgroup 2>/dev/null; then
        if [ "$remembered_backend" = "nft" ]; then
            echo "nft"
        else
            echo "iptables"
        fi
        return
    fi
    if is_systemd_service_active "firewalld.service"; then echo "firewalld"; return; fi
    if is_systemd_service_active "$IPTABLES_RESTORE_SERVICE_NAME" || is_systemd_service_enabled "$IPTABLES_RESTORE_SERVICE_NAME"; then
        echo "iptables"
        return
    fi
    if is_systemd_service_active "nftables.service" || is_systemd_service_enabled "nftables.service"; then
        echo "nft"
        return
    fi
    case "$remembered_backend" in
        iptables|nft|firewalld)
            echo "$remembered_backend"
            return
            ;;
    esac
    if command -v nft >/dev/null 2>&1; then
        if nft list table inet filter >/dev/null 2>&1; then echo "nft"; return; fi
    fi
    echo "iptables"
}

# 停用 firewalld
disable_firewalld() {
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        msg_warn "检测到 firewalld 正在运行，准备停止并禁用它（会备份 firewalld 配置）。"
        confirm "停止并禁用 firewalld?" || return 1
        mkdir -p /var/backups/firewalld
        cp -a /etc/firewalld /var/backups/firewalld/ 2>/dev/null || true
        systemctl stop firewalld 2>/dev/null || true
        systemctl disable firewalld 2>/dev/null || true
        systemctl mask firewalld 2>/dev/null || true
        msg_ok "firewalld 已停止并禁用（备份：/var/backups/firewalld）"
    else
        msg_warn "firewalld 未运行，跳过。"
    fi
}

# 清空并禁用 nftables 规则集
disable_nftables() {
    if command -v nft >/dev/null 2>&1; then
        if nft list ruleset 2>/dev/null | grep -q .; then
            msg_warn "检测到 nftables 规则，准备备份并清空规则集。"
            confirm "清空 nftables 规则并写入空规则集以保留 iptables 优先?" || return 1
            mkdir -p /var/backups/nftables
            nft list ruleset > /var/backups/nftables/ruleset.bak 2>/dev/null || true
            nft flush ruleset 2>/dev/null || true
            echo -e "# empty nftables ruleset" > /etc/nftables.conf 2>/dev/null || true
            if command -v systemctl >/dev/null 2>&1; then
                systemctl stop nftables 2>/dev/null || true
                systemctl disable nftables 2>/dev/null || true
                systemctl mask nftables 2>/dev/null || true
            fi
            msg_ok "nftables 规则已清空并禁用（备份：/var/backups/nftables）"
        else
            msg_warn "未发现 nftables 规则，跳过。"
        fi
    else
        msg_warn "系统未安装 nft 命令，跳过 nftables 操作。"
    fi
}

# 启用nftables
enable_nft() {
    local pkg_mgr
    msg_info "正在准备启用 nftables..."

    # 1. 安装 nftables (根据包管理器判断)
    if ! command -v nft >/dev/null 2>&1; then
        msg_info "正在安装 nftables..."
        pkg_mgr=$(get_pkg_manager)
        case "$pkg_mgr" in
            apt|dnf|yum)
                pkg_update || true
                pkg_install nftables || {
                    msg_err "nftables 安装失败，请检查软件源。"
                    return 1
                }
                ;;
            *)
                msg_err "未检测到受支持的包管理器，无法自动安装 nftables。"
                return 1
                ;;
        esac
    fi

    # 2. 清理冲突服务 (防止多重防火墙打架)
    # 这一步非常重要，防止 firewalld 或 ufw 抢占接管
    local conflict_services=("firewalld" "ufw" "iptables" "iptables-persistent" "netfilter-persistent")
    for svc in "${conflict_services[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            msg_warn "检测到冲突服务正在运行: $svc"
            systemctl stop "$svc"
            systemctl disable "$svc"
            msg_ok "已停止并禁用冲突服务: $svc"
        fi
    done

    # 3. 确保存在基础配置 (防止启动失败或SSH被锁)
    init_nft_rule

    # 4. 启用并启动 nftables 服务
    msg_info "正在解除 nftables 锁定状态..."
    systemctl unmask nftables 2>/dev/null

    # 5. 启用并启动
    # 先 reload daemon 确保 systemd 意识到 mask 已被移除
    systemctl daemon-reload
    
    if systemctl enable --now nftables; then
        set_firewall_backend_state nft
        msg_ok "nftables 服务已解除锁定并成功启动"
        # 尝试加载兼容模块
        modprobe nft_compat 2>/dev/null || true 
    else
        msg_err "nftables 服务启动失败，请检查 'systemctl status nftables'"
        # 输出更多调试信息帮助排查
        journalctl -xeu nftables --no-pager | tail -n 10
        return 1
    fi
}

init_nft_rule() {
    local extra_ports=("$@")
    # 1. 更加精准地获取 SSH 端口
    # 忽略以 # 开头的注释行，忽略缩进
    local current_ssh_port
    local backup_ts
    local extra_rules=""
    local merge_input_specs=()
    local merged_port_specs=()
    local spec normalized proto port
    current_ssh_port=$(get_current_ssh_port)
    current_ssh_port=${current_ssh_port:-22}
    backup_ts=$(date +%F_%H%M%S)

    merge_input_specs=("${extra_ports[@]}")
    while IFS= read -r spec; do
        [ -n "$spec" ] && merge_input_specs+=("$spec")
    done < <(collect_preserved_open_port_specs)

    while IFS= read -r spec; do
        [ -n "$spec" ] && merged_port_specs+=("$spec")
    done < <(merge_unique_port_specs "${merge_input_specs[@]}")

    for spec in "${merged_port_specs[@]}"; do
        normalized=$(normalize_port_spec "$spec") || continue
        proto="${normalized%%:*}"
        port="${normalized#*:}"
        [ "$proto" = "tcp" ] && [ "$port" = "$current_ssh_port" ] && continue
        extra_rules+="
        ${proto} dport ${port} accept"
    done
    
    msg_info "检测到 SSH 端口为: $current_ssh_port"
    msg_info "正在初始化 nftables 基础配置..."

    # 2. 备份现有配置 (如果有)
    if [ -f /etc/nftables.conf ]; then
        mv /etc/nftables.conf "/etc/nftables.conf.bak.${backup_ts}"
        msg_warn "已备份原配置文件为 /etc/nftables.conf.bak.${backup_ts}"
    fi

    # 3. 写入增强版配置
    # 注意：这里增加了 ipv6-icmp 支持，防止 IPv6 网络下无法 Ping 通
    cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # 允许本地回环接口 (Localhost)
        iif "lo" accept

        # 允许已建立的连接和相关连接 (防止断连)
        ct state established,related accept

        # 允许 SSH 端口
        tcp dport $current_ssh_port accept
${extra_rules}

        # 允许 ICMP (IPv4 Ping, Traceroute 等)
        ip protocol icmp accept

        # 允许 ICMPv6 (IPv6 Ping)
        meta l4proto ipv6-icmp accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF
    if nft -f /etc/nftables.conf; then
        set_firewall_backend_state nft
        msg_ok "nftables基础规则已生效。"
    else
        msg_err "nftables 规则加载失败，请检查 /etc/nftables.conf。"
        return 1
    fi
}
# 禁止 PING
disable_ping() {
    local backend
    backend=$(detect_firewall_backend)
    
    if [ "$backend" = "nft" ]; then
        # === NFTABLES 处理 ===
        # 1. 处理 IPv4 PING
        if nft list chain inet filter input | grep -q "ip protocol icmp drop"; then
            msg_warn "nftables: PING (IPv4) 规则已存在，跳过。"
        else
            nft insert rule inet filter input ip protocol icmp drop
        fi
        # 2. 处理 IPv6 PING
        if nft list chain inet filter input | grep -q "meta l4proto ipv6-icmp drop"; then
            msg_warn "nftables: PING (IPv6) 规则已存在，跳过。"
        else
            nft insert rule inet filter input meta l4proto ipv6-icmp drop
        fi
        msg_ok "nftables: PING 禁止规则已确认"

    else
        # === IPTABLES 处理 ===
        local chain6 chain4
        chain4=$(get_effective_filter_chain iptables)
        if iptables -C "$chain4" -p icmp --icmp-type echo-request -j DROP 2>/dev/null; then
            msg_warn "iptables: PING (IPv4) 规则已存在，跳过。"
        else
            while iptables -D "$chain4" -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null; do :; done
            iptables -I "$chain4" 1 -p icmp --icmp-type echo-request -j DROP
            msg_ok "iptables: PING (IPv4) 已禁止"
        fi

        if command -v ip6tables &>/dev/null; then
            chain6=$(get_effective_filter_chain ip6tables)
            if ip6tables -C "$chain6" -p ipv6-icmp --icmpv6-type echo-request -j DROP 2>/dev/null; then
                msg_warn "ip6tables: PING (IPv6) 规则已存在，跳过。"
            else
                while ip6tables -D "$chain6" -p ipv6-icmp --icmpv6-type echo-request -j ACCEPT 2>/dev/null; do :; done
                ip6tables -I "$chain6" 1 -p ipv6-icmp --icmpv6-type echo-request -j DROP
                msg_ok "ip6tables: PING (IPv6) 已禁止"
            fi
        fi
    fi
    # 保存规则 (调用之前定义的保存函数)
    save_iptables
}

# 允许 PING
enable_ping() {
    local backend
    backend=$(detect_firewall_backend)
    
    if [ "$backend" = "nft" ]; then
        # === NFTABLES 处理 ===
        # 1. 删除所有相关的 DROP 规则
        # 使用 grep 查找 icmp 且 action 为 drop 的规则句柄
        handles=$(nft -a list chain inet filter input | grep -E "(icmp|ipv6-icmp).*drop" | awk -F 'handle ' '{print $2}')
        for h in $handles; do 
            nft delete rule inet filter input handle "$h"
        done
        # 2. 添加 ACCEPT 规则 (防止重复添加)
        # 检查 IPv4 ICMP
        if ! nft list chain inet filter input | grep -q "ip protocol icmp accept"; then
            nft add rule inet filter input ip protocol icmp accept
        fi
        
        # 检查 IPv6 ICMP
        if ! nft list chain inet filter input | grep -q "meta l4proto ipv6-icmp accept"; then
            nft add rule inet filter input meta l4proto ipv6-icmp accept
        fi
        
        msg_ok "nftables: PING 已允许"
        
    else
        # === IPTABLES 处理 ===
        local chain6 chain4
        chain4=$(get_effective_filter_chain iptables)
        while iptables -D "$chain4" -p icmp --icmp-type echo-request -j DROP 2>/dev/null; do :; done
        while iptables -D "$chain4" -p icmp -j DROP 2>/dev/null; do :; done

        if iptables -C "$chain4" -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null; then
            msg_warn "iptables: PING (IPv4) 已允许，跳过重复添加。"
        else
            iptables -I "$chain4" 1 -p icmp --icmp-type echo-request -j ACCEPT
            msg_ok "iptables: PING (IPv4) 已允许"
        fi

        if command -v ip6tables &>/dev/null; then
            chain6=$(get_effective_filter_chain ip6tables)
            while ip6tables -D "$chain6" -p ipv6-icmp --icmpv6-type echo-request -j DROP 2>/dev/null; do :; done
            if ip6tables -C "$chain6" -p ipv6-icmp --icmpv6-type echo-request -j ACCEPT 2>/dev/null; then
                msg_warn "ip6tables: PING (IPv6) 已允许，跳过重复添加。"
            else
                ip6tables -I "$chain6" 1 -p ipv6-icmp --icmpv6-type echo-request -j ACCEPT
                msg_ok "ip6tables: PING (IPv6) 已允许"
            fi
        fi
    fi
     save_iptables
}

reload_iptable_rule() {
    iptables-restore < "$IPTABLES_RULES_V4"
}

reload_ip6table_rule() {
    if command -v ip6tables-restore >/dev/null 2>&1 && [ -s "$IPTABLES_RULES_V6" ]; then
        ip6tables-restore < "$IPTABLES_RULES_V6"
    fi
    return 0
}

install_iptables_restore_service() {
    mkdir -p "$IPTABLES_RULE_DIR"
    cat > "$IPTABLES_RESTORE_SERVICE_PATH" <<EOF
[Unit]
Description=Restore unified iptables rules from ${IPTABLES_RULE_DIR}
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target
After=local-fs.target
ConditionPathExists=${IPTABLES_RULES_V4}

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash -lc 'iptables-restore < "${IPTABLES_RULES_V4}"; if command -v ip6tables-restore >/dev/null 2>&1 && [ -s "${IPTABLES_RULES_V6}" ]; then ip6tables-restore < "${IPTABLES_RULES_V6}"; fi'
ExecReload=/usr/bin/env bash -lc 'iptables-restore < "${IPTABLES_RULES_V4}"; if command -v ip6tables-restore >/dev/null 2>&1 && [ -s "${IPTABLES_RULES_V6}" ]; then ip6tables-restore < "${IPTABLES_RULES_V6}"; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$IPTABLES_RESTORE_SERVICE_NAME" >/dev/null 2>&1
}

get_legacy_iptables_restore_units() {
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit
    while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        [ "$unit" = "$IPTABLES_RESTORE_SERVICE_NAME" ] && continue
        if systemctl cat "$unit" 2>/dev/null | grep -Eq '/etc/iptables\.rules|/etc/ip6tables\.rules'; then
            printf '%s\n' "$unit"
        fi
    done < <(systemctl list-unit-files --type=service --all 2>/dev/null | awk '{print $1}' | grep '\.service$')
}

disable_legacy_iptables_restore_sources() {
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit found=0
    while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        found=1
        msg_warn "检测到旧规则恢复服务：${unit}（引用 /etc/iptables.rules 或 /etc/ip6tables.rules）"
        systemctl stop "$unit" >/dev/null 2>&1 || true
        systemctl disable "$unit" >/dev/null 2>&1 || true
        systemctl mask "$unit" >/dev/null 2>&1 || true
        msg_ok "已停用并屏蔽旧恢复服务：${unit}"
    done < <(get_legacy_iptables_restore_units | sort -u)

    if [ "$found" -eq 0 ]; then
        msg_info "未发现引用 /etc/iptables.rules 的旧恢复服务。"
    fi
}

quarantine_legacy_iptables_rule_files() {
    local target ts moved=0
    ts=$(date +%F_%H%M%S)
    for target in "$LEGACY_IPTABLES_RULES_V4" "$LEGACY_IPTABLES_RULES_V6"; do
        [ -f "$target" ] || continue
        if mv -f "$target" "${target}.disabled-by-vps-suite.${ts}" 2>/dev/null; then
            moved=1
            msg_warn "已隔离旧规则文件：${target} -> ${target}.disabled-by-vps-suite.${ts}"
        fi
    done
    [ "$moved" -eq 0 ] || return 0
    msg_info "未发现需要隔离的旧规则文件。"
}

## 启动用Iptables持久化服务
enable_iptables() {
    msg_info "正在准备启用 iptables 持久化服务..."
    local preserved_specs=()
    local spec backup_dir backup_ts

    # 1. 识别系统并安装相应的持久化包
    if ! command -v iptables-restore >/dev/null 2>&1; then
        msg_info "正在安装 iptables..."
        case "$(get_pkg_manager)" in
            apt)
                pkg_update || true
                pkg_install iptables || {
                    msg_err "iptables 安装失败。"
                    return 1
                }
                ;;
            dnf|yum)
                pkg_update || true
                pkg_install iptables iptables-services || {
                    msg_err "iptables / iptables-services 安装失败。"
                    return 1
                }
                ;;
            *)
                msg_err "不支持的包管理器，无法自动配置 iptables 服务。"
                return 1
                ;;
        esac
    fi

    while IFS= read -r spec; do
        [ -n "$spec" ] && preserved_specs+=("$spec")
    done < <(collect_preserved_open_port_specs)

    # 2. 清理冲突服务
    # 必须停止 nftables 服务本身以及 firewalld/ufw
    local conflict_services=("firewalld" "ufw" "nftables" "netfilter-persistent" "iptables")
    for svc in "${conflict_services[@]}"; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\\.service"; then
            msg_warn "停止冲突服务: $svc"
            systemctl stop "$svc" >/dev/null 2>&1 || true
            systemctl disable "$svc" >/dev/null 2>&1 || true
        fi
    done
    if command -v nft >/dev/null 2>&1; then
        backup_ts=$(date +%F_%H%M%S)
        backup_dir="${SUITE_BACKUP_DIR:-/var/backups/vps-init-suite}/firewall"
        mkdir -p "$backup_dir" 2>/dev/null || true
        nft list ruleset > "${backup_dir}/nft-ruleset.bak.${backup_ts}.$$" 2>/dev/null || true
        [ -f /etc/nftables.conf ] && cp -af /etc/nftables.conf "${backup_dir}/nftables.conf.bak.${backup_ts}.$$" 2>/dev/null || true
        msg_info "nftables 规则已备份到：${backup_dir}"
        nft flush ruleset >/dev/null 2>&1 || true
        printf '#!/usr/sbin/nft -f\nflush ruleset\n' > /etc/nftables.conf 2>/dev/null || true
    fi

    # 3. 确保有基本的规则文件 (防止服务启动报错)
    FORCE_IPTABLES=1 init_iptable_rule "${preserved_specs[@]}"

    # 4. 统一安装并启用我们自己的恢复服务
    install_iptables_restore_service
    if systemctl restart "$IPTABLES_RESTORE_SERVICE_NAME" >/dev/null 2>&1; then
        set_firewall_backend_state iptables
        disable_legacy_iptables_restore_sources
        quarantine_legacy_iptables_rule_files
        msg_ok "iptables 持久化服务已启用，统一配置目录：${IPTABLES_RULE_DIR}"
    else
        msg_err "iptables 持久化服务启动失败，请检查 systemctl status ${IPTABLES_RESTORE_SERVICE_NAME}"
        return 1
    fi
}

# 初始化 iptables 规则 (白名单模式)
init_iptable_rule() {
    local extra_ports=()
    local backend sshport
    local merge_input_specs=()
    local merged_port_specs=()
    local spec
    while [ "$#" -gt 0 ]; do
        extra_ports+=("$1")
        shift
    done

    backend=$(detect_firewall_backend)
    if [ "$backend" = "firewalld" ]; then
        msg_warn "检测到 firewalld 正在运行。"
        msg_warn "本脚本仅支持原生 iptables 或 nftables 管理，继续操作可能会导致规则冲突。"
        confirm "是否强制继续 (建议先停止 firewalld)?" || return 1
    fi

    sshport=$(get_current_ssh_port)
    sshport=${sshport:-22}

    merge_input_specs=("${extra_ports[@]}")
    while IFS= read -r spec; do
        [ -n "$spec" ] && merge_input_specs+=("$spec")
    done < <(collect_preserved_open_port_specs)

    while IFS= read -r spec; do
        [ -n "$spec" ] && merged_port_specs+=("$spec")
    done < <(merge_unique_port_specs "${merge_input_specs[@]}")

    mkdir -p "$IPTABLES_RULE_DIR"
    [ -f "$IPTABLES_RULES_V4" ] && cp "$IPTABLES_RULES_V4" "${IPTABLES_RULES_V4}.bak.$(date +%F_%T)"
    [ -f "$IPTABLES_RULES_V6" ] && cp "$IPTABLES_RULES_V6" "${IPTABLES_RULES_V6}.bak.$(date +%F_%T)" 2>/dev/null || true

    msg_info "正在重建 iptables 托管白名单规则（链：${IPTABLES_MANAGED_CHAIN}，会保留已识别的放行端口）..."
    reset_managed_filter_chain_rules iptables "$sshport" "${merged_port_specs[@]}" || {
        msg_err "iptables IPv4 规则初始化失败。"
        return 1
    }

    if command -v ip6tables >/dev/null 2>&1; then
        msg_info "检测到 ip6tables，正在同步重建 IPv6 白名单规则（链：${IP6TABLES_MANAGED_CHAIN}）..."
        reset_managed_filter_chain_rules ip6tables "$sshport" "${merged_port_specs[@]}" || {
            msg_err "ip6tables IPv6 规则初始化失败。"
            return 1
        }
    fi

    save_iptables
    set_firewall_backend_state iptables
    msg_ok "iptables 初始化完成（托管白名单模式，已开放 SSH:${sshport}，并保留已识别的放行端口）"
}
