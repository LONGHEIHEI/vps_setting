run_ecs_fusion_test() {
    run_remote_script "https://gitlab.com/spiritysdx/za/-/raw/main/ecs.sh" "/tmp/ecs-test.XXXXXX.sh" "融合测试脚本"
}

run_net_quality_test() {
    run_remote_script "https://Net.Check.Place" "/tmp/net-quality.XXXXXX.sh" "网络质量测试脚本" -4
}

run_ip_quality_test() {
    run_remote_script "https://IP.Check.Place" "/tmp/ip-quality.XXXXXX.sh" "IP质量测试脚本"
}

run_hardware_test() {
    run_remote_script "https://Check.Place" "/tmp/hardware-test.XXXXXX.sh" "机器硬件测试脚本" -H
}

run_speedtest_script() {
    run_remote_script "https://raw.githubusercontent.com/i-abc/Speedtest/main/speedtest.sh" "/tmp/speedtest.XXXXXX.sh" "网络测速脚本"
}

menu_machine_tests() {
    local sub menu_action

    while true; do
        clear
        menu_header "9. 机器测试"
        menu_pair "[1] 融合测试" "[2] 网络质量测试"
        menu_pair "[3] IP质量测试" "[4] 机器硬件测试"
        menu_pair "[5] 网络测速"
        menu_footer_back
        menu_read_submenu_action sub menu_action
        case "$menu_action" in
            continue) ;;
            return) return ;;
            retry) continue ;;
            back) break ;;
        esac
        case $sub in
            1) run_confirmed_action "执行融合测试" run_ecs_fusion_test ;;
            2) run_confirmed_action "执行网络质量测试" run_net_quality_test ;;
            3) run_confirmed_action "执行IP质量测试" run_ip_quality_test ;;
            4) run_confirmed_action "执行机器硬件测试" run_hardware_test ;;
            5) run_confirmed_action "执行网络测速" run_speedtest_script ;;
        esac
        pause
    done
}
