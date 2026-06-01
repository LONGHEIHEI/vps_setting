# 4.5 运维与工具
menu_ops_tools() {
    local sub menu_action
    local docker_status nginx_status xui_status komari_status panel_status lucky_status

    while true; do
        clear
        menu_header "5. 常用工具集成"
        docker_status=$(get_menu_item_status_simple docker)
        nginx_status=$(get_menu_item_status_simple nginx)
        xui_status=$(get_menu_item_status_simple 3x-ui)
        komari_status=$(get_menu_item_status_simple komari)
        panel_status=$(get_menu_item_status_simple 1panel)
        lucky_status=$(get_menu_item_status_simple lucky)

        status_pair "Docker" "$docker_status"
        status_pair "Nginx" "$nginx_status"
        status_pair "3x-ui" "$xui_status"
        status_pair "Komari" "$komari_status"
        status_pair "1Panel" "$panel_status"
        status_pair "Lucky" "$lucky_status"

        menu_section "安装与部署"
        menu_pair "[1] 安装常用包" "[2] 安装Docker"
        menu_pair "[3] 安装3x-ui" "[4] 安装Lucky普通版"
        menu_pair "[5] 安装1Panel" "[6] 安装Nginx"
        menu_pair "[F] 安装Komari"

        menu_section "配置与辅助"
        menu_pair "[7] 部署Compose仓库" "[8] 创建ssl证书目录"
        menu_pair "[9] 为现有3x-ui配置反代" "[I] 补全Nginx/3x-ui sudo"

        menu_section "卸载与清理"
        menu_pair "[A] 卸载Docker" "[B] 卸载3x-ui"
        menu_pair "[C] 卸载Lucky" "[D] 卸载1Panel"
        menu_pair "[E] 卸载Nginx" "[G] 卸载哪吒面板"
        menu_pair "[H] 卸载哪吒探针"
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
                if confirm "安装常用工具包"; then
                    if install_common_ops_tools; then
                        msg_ok "工具包安装完成"
                    else
                        msg_err "工具包安装失败"
                    fi
                fi ;;
            2)
                run_confirmed_action "安装Docker" install_or_configure_docker ;;
            3)
                if confirm "安装3x-ui并预置配置"; then
                    if install_3x_ui_preconfigured; then
                        msg_ok "3x-ui 安装流程完成"
                    else
                        msg_err "3x-ui 安装流程失败或已中止"
                    fi
                fi ;;
            4)
                run_confirmed_action "安装Lucky普通版到/etc/lucky?" install_lucky_standard ;;
            5)
                if confirm "安装1Panel面板?"; then
                    msg_info "将下载并执行1Panel官方安装脚本："
                    msg_text 'https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh'
                    if run_remote_script "https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh" "/tmp/1panel.XXXXXX.sh" "1Panel安装脚本"; then
                        msg_ok "1Panel安装引导已执行，请根据安装程序提示完成后续配置。"
                    else
                        msg_err "1Panel安装引导执行失败，请检查网络或安装脚本输出。"
                    fi
                fi ;;
            6)
                run_confirmed_action "安装Nginx" install_nginx ;;
            9)
                run_confirmed_action "为现有3x-ui配置Nginx反代" configure_existing_3x_ui_nginx_proxy ;;
            I|i)
                run_confirmed_action "补全非root用户 Nginx/3x-ui 受限 sudo 权限" configure_nginx_limited_sudo_for_users ;;
            F|f)
                if confirm "安装 Komari 并预置配置"; then
                    install_komari_preconfigured
                fi ;;
            G|g)
                run_confirmed_action "卸载哪吒面板" uninstall_nezha_dashboard ;;
            H|h)
                run_confirmed_action "卸载哪吒探针" uninstall_nezha_agent ;;
            A|a)
                run_confirmed_action "卸载Docker（保留数据目录需二次确认）" uninstall_docker ;;
            B|b)
                run_confirmed_action "卸载3x-ui（官方命令会同时移除 xray）" uninstall_3x_ui ;;
            C|c)
                run_confirmed_action "卸载Lucky普通版" uninstall_lucky_standard ;;
            D|d)
                run_confirmed_action "调用官方流程卸载1Panel" uninstall_1panel ;;
            E|e)
                run_confirmed_action "卸载Nginx（删除配置需二次确认）" uninstall_nginx ;;
            7)
                run_confirmed_action "部署 LongShengWen/docker-compose 仓库服务" install_docker_compose_repo_services ;;
            8)
                run_confirmed_action "创建 sshl 证书目录 ${SSHL_CERTS_DIR}" create_sshl_certs_dir ;;
        esac
        pause
    done
}

install_system_tools() {
    local sub menu_action

    while true; do
        clear
        menu_header "DD系统"
        menu_pair "[1] DD Linux" "[2] DD Windows"
        menu_footer_back
        menu_read_submenu_action sub menu_action
        case "$menu_action" in
            continue) ;;
            return) return ;;
            retry) continue ;;
            back) break ;;
        esac
        case $sub in
            1) confirm "DD Linux(数据将被清除!)" && {
                download_reinstall_script_if_missing || break
                # 1. 输入版本
                local default_os="debian-13"
                read -p "请输入Linux版本[默认: $default_os]: " input_os
                local target_os=${input_os:-$default_os}
                # 2. 输入密码
                local install_pass
                install_pass=$(get_required_password "ROOT/Administrator")
                msg_text "即将安装: $target_os"
                msg_warn "警告：此操作不可逆，将格式化全盘！"
                
                if confirm "确认执行重装?"; then
                    bash reinstall.sh "$target_os" --password "$install_pass"
                    # 如果脚本执行成功，通常会重启，这里防止脚本继续运行
                    exit 0
                fi
            } ;;
            2) confirm "DD Windows(数据将被清除, 风险较高，需要足够内存)" && {
                download_reinstall_script_if_missing || break
                msg_info "说明：输入 'windows-11', 'windows-10' 等版本号"
                msg_info "或者输入以http开头的完整DD镜像链接"
                # 1. 输入版本或链接
                local default_win="Windows 11 Enterprise LTSC 2024"
                read -p "请输入版本或链接 [默认: $default_win]: " input_win
                local target_win=${input_win:-$default_win}
                # 2. 输入密码
                local install_pass
                install_pass=$(get_required_password "ROOT/Administrator")
                msg_text "即将安装: $target_win"
                msg_warn "警告：Windows 安装耗时较长，请耐心等待，切勿强制重启。"
                if confirm "确认执行重装?"; then
                    # 判断是普通版本号还是 URL
                    if [[ "$target_win" == http* ]]; then
                        # 如果是 URL，使用 -dd 模式
                        bash reinstall.sh -dd "$target_win" --password "$install_pass"
                    else
                        # 如果是版本号，直接传参 (脚本会自动识别为 windows)
                        bash reinstall.sh --image-name "$target_win" --password "$install_pass"
                    fi
                    exit 0
                fi
            } ;;
        esac
        pause
    done
}
