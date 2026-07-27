# 3. 防火墙策略
menu_firewall_advanced() {
    local sub menu_action backend

    while true; do
        clear
        backend=$(detect_firewall_backend)
        menu_header "3. 防火墙策略"
        show_firewall_status "$backend"
        draw_line
        menu_section "规则管理"
        menu_pair "[1] 服务与初始化" "[2] 端口与连通性"
        menu_pair "[3] 访问控制与策略" "[5] 查看详细规则"

        menu_section "容器边界"
        menu_pair "[4] Docker隔离"
        menu_footer_back
        menu_read_submenu_action sub menu_action
        case "$menu_action" in
            continue) ;;
            return) return ;;
            retry) continue ;;
            back) break ;;
        esac
        case $sub in
            1) menu_firewall_service_init ;;
            2) menu_firewall_ports_ping ;;
            3) menu_firewall_access_policy ;;
            4) menu_firewall_docker ;;
            5)
                require_native_firewall_backend "$backend" || continue
                firewall_show_rule_details "$backend"
                pause
                ;;
        esac
    done
}
