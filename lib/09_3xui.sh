# ==============================================================================
# 3x-ui 安装与预置配置
# 固定用户名/密码，可选 Nginx 反向代理（域名 + SSL）
# 3x-ui 是基于 Xray 的多协议代理面板，支持 VMess/VLESS/Trojan/Shadowsocks
# ==============================================================================
install_3x_ui_preconfigured() {
    local xui_port
    local xui_user
    local xui_pass
    local xui_path
    local xui_cli use_nginx domain listen_port enable_ssl cert_file key_file access_url
    local default_xui_path
    local xui_url_path

    # main.sh 启用了 pipefail；tr | head 在 head 取够字符后会触发 SIGPIPE，
    # 直接写在赋值语句里可能让整个主菜单退出。这里显式忽略该管道状态。
    default_xui_path=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 18 || true)
    [ -n "$default_xui_path" ] || default_xui_path="panel$(date +%H%M%S)"

    prompt_valid_port "请输入 3x-ui 面板端口" "51888" xui_port || return 1
    prompt_valid_username "请输入 3x-ui 管理用户名" "${AUTO_DEPLOY_USER:-admin}" xui_user || return 1
    prompt_password_twice "3x-ui 管理用户 ${xui_user}" xui_pass || return 1
    prompt_valid_web_path_token "请输入 3x-ui 面板路径标识" "$default_xui_path" xui_path || return 1

    xui_path=$(normalize_web_base_path "$xui_path")
    xui_url_path="/${xui_path}"

    if ! validate_web_base_path "$xui_path"; then
        msg_err "内置的 3x-ui WebBasePath 无效：${xui_path}"
        return 1
    fi

    # --- 询问是否使用 Nginx 反向代理，并在安装 3x-ui 前先完成信息采集/校验 ---
    msg_info "3x-ui 预置配置："
    status_pair "用户名" "${xui_user}"
    status_pair "密码" "已设置"
    status_pair "面板端口" "${xui_port}"
    status_pair "面板路径" "${xui_url_path}"
    draw_line

    read -p "是否在安装 3x-ui 前预设 Nginx 反向代理? (y/N): " use_nginx
    use_nginx=${use_nginx:-N}

    if [[ "$use_nginx" =~ ^[Yy]$ ]]; then
        use_nginx=1
        collect_nginx_proxy_target domain listen_port enable_ssl cert_file key_file || return 1
        prepare_nginx_proxy_environment "Nginx 准备失败，已中止 3x-ui 安装。" || return 1
    else
        use_nginx=0
        enable_ssl=0
    fi

    # --- 1. 执行官方安装脚本，但跳过其安装后交互配置，由本脚本统一落参 ---
    msg_info "正在下载并安装 3x-ui..."
    local _xui_script
    _xui_script=$(download_remote_script "https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh" "/tmp/3x-ui.XXXXXX.sh" "3x-ui安装脚本") || {
        msg_err "3x-ui 安装脚本下载失败。"
        return 1
    }

    patch_3x_ui_install_script_for_suite "$_xui_script" || {
        rm -f "$_xui_script"
        msg_err "无法安全改写 3x-ui 官方安装脚本，已中止安装。"
        return 1
    }

    if ! bash "$_xui_script"; then
        rm -f "$_xui_script"
        msg_err "3x-ui 安装脚本执行失败。"
        return 1
    fi
    rm -f "$_xui_script"

    # --- 2. 检查安装结果并通过官方 CLI 落参 ---
    xui_cli=$(get_3x_ui_cli_path) || {
        msg_err "3x-ui 安装后未检测到 x-ui 命令。"
        return 1
    }

    msg_ok "3x-ui 安装完成，正在写入预置配置..."
    set_3x_ui_panel_settings "$xui_cli" "$xui_user" "$xui_pass" "$xui_port" "$xui_path" || {
        msg_err "3x-ui 面板参数写入失败。"
        return 1
    }
    set_3x_ui_subscription_paths "$xui_path" || {
        msg_warn "3x-ui 订阅 URI 路径预设失败，请稍后在面板里手动检查“订阅设置”。"
    }

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart x-ui >/dev/null 2>&1 || systemctl start x-ui >/dev/null 2>&1 || true
    else
        service x-ui restart >/dev/null 2>&1 || true
    fi

    configure_nginx_limited_sudo_for_users || true

    # --- 3. 在 3x-ui 安装完成后，写入已经预设好的 Nginx 反代 ---
    if [ "$use_nginx" -eq 1 ]; then
        write_3x_ui_nginx_proxy_config "$domain" "$listen_port" "$enable_ssl" "$cert_file" "$key_file" "$xui_port" "$xui_url_path" || {
            msg_err "Nginx 反向代理配置失败。"
            return 1
        }
        msg_ok "Nginx 反向代理配置完成"
    fi

    # --- 4. 输出配置信息 ---
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')
    [ -z "$server_ip" ] && server_ip=$(curl -s4 --connect-timeout 3 --max-time 5 ip.sb 2>/dev/null || echo "你的服务器IP")

    msg_ok "3x-ui 安装并预置配置完成！"
    draw_line
    status_pair "用户名" "${xui_user}"
    status_pair "密码" "已设置"
    status_pair "面板端口" "${xui_port}"
    status_pair "路径前缀" "${xui_url_path}"

    if [ "$use_nginx" -eq 1 ]; then
        if [ "$enable_ssl" -eq 1 ]; then
            access_url="https://${domain}:${listen_port}${xui_url_path}"
        else
            access_url="http://${domain}:${listen_port}${xui_url_path}"
        fi
        status_pair "访问地址" "${access_url}"
        status_pair "反向代理" "Nginx -> http://127.0.0.1:${xui_port}"
        [ "$enable_ssl" -eq 1 ] && status_pair "SSL" "已启用"
    else
        access_url="http://${server_ip}:${xui_port}${xui_url_path}"
        status_pair "访问地址" "${access_url}"
        status_pair "反向代理" "未启用"
    fi

    draw_line
    msg_warn "请记录以上信息！"
    msg_info "防火墙放行: 在本脚本 [4] 防火墙管理 → [2] 端口与连通性 → [1] 开放指定端口"
    if [ "$use_nginx" -eq 1 ]; then
        msg_info "需放行端口: ${listen_port}/tcp"
    else
        msg_info "需放行端口: ${xui_port}/tcp"
    fi
    msg_info "管理命令: x-ui start|stop|restart|status|enable|disable"
}

configure_existing_3x_ui_nginx_proxy() {
    local xui_cli xui_port xui_url_path
    local domain listen_port enable_ssl cert_file key_file access_url

    xui_cli=$(get_3x_ui_cli_path) || {
        msg_err "未检测到 3x-ui，请先确认 3x-ui 已安装。"
        return 1
    }

    get_3x_ui_panel_runtime_settings "$xui_cli" xui_port xui_url_path || {
        msg_err "读取当前 3x-ui 面板端口/路径失败，请先执行：x-ui setting -show true 检查。"
        return 1
    }

    menu_header "为现有 3x-ui 配置 Nginx 反代"
    status_pair "检测端口" "${xui_port}"
    status_pair "检测路径" "${xui_url_path}"
    draw_line

    collect_nginx_proxy_target domain listen_port enable_ssl cert_file key_file || return 1
    prepare_nginx_proxy_environment "Nginx 准备失败，已中止反代配置。" || return 1

    write_3x_ui_nginx_proxy_config "$domain" "$listen_port" "$enable_ssl" "$cert_file" "$key_file" "$xui_port" "$xui_url_path" || {
        msg_err "Nginx 反向代理配置失败。"
        return 1
    }

    if [ "$enable_ssl" -eq 1 ]; then
        access_url="https://${domain}:${listen_port}${xui_url_path}"
    else
        access_url="http://${domain}:${listen_port}${xui_url_path}"
    fi

    msg_ok "现有 3x-ui 的 Nginx 反代已配置完成。"
    draw_line
    status_pair "3x-ui端口" "${xui_port}"
    status_pair "3x-ui路径" "${xui_url_path}"
    status_pair "访问地址" "${access_url}"
    status_pair "反向代理" "Nginx -> http://127.0.0.1:${xui_port}"
    [ "$enable_ssl" -eq 1 ] && status_pair "SSL" "已启用"
    draw_line
    msg_info "如当前浏览器标签仍显示旧 IP，请执行：systemctl reload nginx 后强制刷新浏览器缓存。"
}
