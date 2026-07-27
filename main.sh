#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/01_core_ui.sh"
source "${SCRIPT_DIR}/lib/13_auto_deploy_entry.sh"
source "${SCRIPT_DIR}/lib/14_system_base.sh"
source "${SCRIPT_DIR}/lib/15_ssh_hardening.sh"
source "${SCRIPT_DIR}/lib/16_perf_tuning.sh"
source "${SCRIPT_DIR}/lib/17_firewall_backend.sh"
source "${SCRIPT_DIR}/lib/03_network_report.sh"
source "${SCRIPT_DIR}/lib/04_menus_security.sh"
source "${SCRIPT_DIR}/lib/05_firewall_advanced.sh"
source "${SCRIPT_DIR}/lib/06_lucky_docker_compose.sh"
source "${SCRIPT_DIR}/lib/07_machine_tests.sh"
source "${SCRIPT_DIR}/lib/08_nginx.sh"
source "${SCRIPT_DIR}/lib/09_3xui.sh"
source "${SCRIPT_DIR}/lib/10_komari.sh"
source "${SCRIPT_DIR}/lib/11_service_uninstall.sh"
source "${SCRIPT_DIR}/lib/12_ops_menu_dd.sh"

# --- [5. 主程序循环入口] ---
while true; do
    local_menu_status=0
    [ "$EXIT_ALL" -eq 1 ] && exit 0
    if [ -z "$(get_pkg_manager)" ]; then
        msg_err "脚本当前仅支持apt / dnf / yum系列发行版。"
        exit 1
    fi
    clear
    DASH_LOAD=$(uptime | awk -F'load average:' '{print $2}' | cut -d',' -f1 | tr -d ' ')
    DASH_MEM=$(free | awk '/Mem:/{printf "%.1f%%", $3/$2*100}')
    DASH_IP=$(hostname -I | awk '{print $1}')
    menu_header "SERVER MASTER ULTIMATE SUITE"
    menu_section "初始化与安全"
    menu_pair "[1] 基础环境 >>" "[2] SSH与账号安全 >>"
    menu_pair "[3] 防火墙策略 >>" "[A] 全自动一键部署"

    menu_section "网络与服务"
    menu_pair "[4] 网络与性能 >>" "[5] 软件与面板 >>"
    menu_pair "[6] 系统重装/DD >>" "[9] 云厂商/OCI >>"

    menu_section "诊断与信息"
    menu_pair "[7] 系统信息 >>" "[8] 机器测试 >>"

    menu_section "快捷入口"
    menu_pair "[0] 退出管理系统"

    draw_line
    status_pair "HOST" "$(hostname)"
    status_pair "LOAD" "${DASH_LOAD:-"0.0"}"
    status_pair "MEM" "${DASH_MEM:-"0.0"}"
    status_pair "IP" "${DASH_IP:-"N/A"}"
    draw_line
    local_menu_status=$MENU_RESULT_CONTINUE
    menu_read_standard_choice choice || local_menu_status=$?
    case "$local_menu_status" in
        "$MENU_RESULT_CONTINUE") ;;
        "$MENU_RESULT_EXIT_ALL"|"$MENU_RESULT_BACK") exit 0 ;;
        "$MENU_RESULT_RETRY") continue ;;
    esac

    case $choice in
        1) menu_base_config ;;
        2) menu_security_hardening ;;
        3) menu_firewall_advanced ;;
        4) menu_network_performance ;;
        5) menu_ops_tools ;;
        6) install_system_tools ;;
        7) show_system_report ;;
        8) menu_machine_tests ;;
        9) menu_oracle_cloud_services ;;
        A|a)
            confirm "执行全自动一键部署(已内置SSH/用户/iptables/ping初始化逻辑)" && \
                run_inlined_auto_deploy
            pause ;;
    esac
done
