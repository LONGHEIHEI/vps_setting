detect_komari_arch() {
    local machine
    machine=$(uname -m 2>/dev/null | tr '[:upper:]' '[:lower:]')
    case "$machine" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        i386|i686) echo "386" ;;
        riscv64) echo "riscv64" ;;
        *) return 1 ;;
    esac
}

write_komari_nginx_proxy_config() {
    local domain="$1"
    local listen_port="$2"
    local ssl_enabled="$3"
    local cert_file="$4"
    local key_file="$5"
    local komari_port="$6"
    local conf_dir="/etc/nginx/conf.d"
    local conf_file="${conf_dir}/komari.conf"
    local redirect_file="${conf_dir}/komari-redirect.conf"
    local server_body

    server_body=$(cat <<EOF
    location / {
        proxy_pass http://127.0.0.1:${komari_port};
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
    }
EOF
)

    write_generic_nginx_proxy_config \
        "$conf_file" "$redirect_file" "$domain" "$listen_port" "$ssl_enabled" \
        "$cert_file" "$key_file" " Komari" "$server_body"
}

install_komari_preconfigured() {
    local komari_port
    local komari_user="admin"
    local komari_pass
    local install_dir="/usr/local/komari"
    local service_name="komari.service"
    local service_path="/etc/systemd/system/${service_name}"
    local use_nginx domain listen_port enable_ssl cert_file key_file access_url
    local arch download_url tmp_root binary_tmp listen_host server_ip
    local password_set=0

    if ! command -v systemctl >/dev/null 2>&1; then
        msg_err "当前系统未检测到 systemctl，暂不支持自动安装 Komari 服务。"
        return 1
    fi

    ensure_basic_tool_installed curl curl || {
        msg_err "curl安装失败，无法继续安装 Komari。"
        return 1
    }

    arch=$(detect_komari_arch) || {
        msg_err "暂不支持当前架构: $(uname -m 2>/dev/null)"
        return 1
    }

    prompt_valid_port "请输入 Komari 服务端口" "25774" komari_port || return 1
    prompt_password_twice "Komari 管理员 ${komari_user}" komari_pass || return 1

    msg_info "Komari 预置配置："
    status_pair "用户名" "${komari_user}"
    status_pair "密码" "已设置"
    status_pair "服务端口" "${komari_port}"
    status_pair "安装目录" "${install_dir}"
    status_pair "系统架构" "${arch}"
    draw_line

    read -p "是否在安装 Komari 前预设 Nginx 反向代理? (y/N): " use_nginx
    use_nginx=${use_nginx:-N}

    if [[ "$use_nginx" =~ ^[Yy]$ ]]; then
        use_nginx=1
        collect_nginx_proxy_target domain listen_port enable_ssl cert_file key_file || return 1
        prepare_nginx_proxy_environment "Nginx 准备失败，已中止 Komari 安装。" || return 1
        listen_host="127.0.0.1"
    else
        use_nginx=0
        enable_ssl=0
        listen_host="0.0.0.0"
    fi

    download_url="https://github.com/komari-monitor/komari/releases/latest/download/komari-linux-${arch}"
    msg_info "正在下载 Komari 二进制文件..."

    tmp_root=$(mktemp -d /tmp/komari-install.XXXXXX) || {
        msg_err "创建临时目录失败。"
        return 1
    }
    binary_tmp="${tmp_root}/komari"

    if ! curl -A 'Mozilla/5.0' -fsSL --connect-timeout 5 --max-time 300 -o "$binary_tmp" "$download_url"; then
        rm -rf "$tmp_root"
        msg_err "下载 Komari 二进制失败: ${download_url}"
        return 1
    fi

    chmod +x "$binary_tmp" || {
        rm -rf "$tmp_root"
        msg_err "设置 Komari 执行权限失败。"
        return 1
    }

    mkdir -p "$install_dir/data" || {
        rm -rf "$tmp_root"
        msg_err "创建 Komari 安装目录失败：${install_dir}"
        return 1
    }

    systemctl stop komari >/dev/null 2>&1 || true

    install -m 755 "$binary_tmp" "${install_dir}/komari" || {
        rm -rf "$tmp_root"
        msg_err "安装 Komari 二进制失败。"
        return 1
    }
    ln -sf "${install_dir}/komari" /usr/local/bin/komari
    rm -rf "$tmp_root"

    cat > "$service_path" <<EOF
[Unit]
Description=Komari Monitoring Service
After=network.target

[Service]
ExecStart=${install_dir}/komari server -l ${listen_host}:${komari_port}
WorkingDirectory=${install_dir}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "$service_name" >/dev/null 2>&1 || true
    systemctl restart "$service_name" >/dev/null 2>&1 || systemctl start "$service_name" >/dev/null 2>&1 || {
        msg_err "Komari 服务启动失败，请检查: systemctl status ${service_name}"
        return 1
    }

    for _ in $(seq 1 20); do
        if [ -f "${install_dir}/data/komari.db" ] && \
           (cd "$install_dir" && ./komari chpasswd -p "$komari_pass" >/dev/null 2>&1); then
            password_set=1
            break
        fi
        sleep 1
    done

    if [ "$password_set" -ne 1 ]; then
        msg_err "Komari 管理员密码预设失败，请检查服务日志: journalctl -u ${service_name} -f"
        return 1
    fi

    if [ "$use_nginx" -eq 1 ]; then
        write_komari_nginx_proxy_config "$domain" "$listen_port" "$enable_ssl" "$cert_file" "$key_file" "$komari_port" || {
            msg_err "Nginx 反向代理配置失败。"
            return 1
        }
        msg_ok "Nginx 反向代理配置完成"
    fi

    server_ip=$(hostname -I | awk '{print $1}')
    [ -z "$server_ip" ] && server_ip=$(curl -s4 --connect-timeout 3 --max-time 5 ip.sb 2>/dev/null || echo "你的服务器IP")

    msg_ok "Komari 安装并预置配置完成！"
    draw_line
    status_pair "用户名" "${komari_user}"
    status_pair "密码" "已设置"
    status_pair "服务端口" "${komari_port}"
    status_pair "安装目录" "${install_dir}"

    if [ "$use_nginx" -eq 1 ]; then
        if [ "$enable_ssl" -eq 1 ]; then
            access_url="https://${domain}:${listen_port}/"
        else
            access_url="http://${domain}:${listen_port}/"
        fi
        status_pair "访问地址" "${access_url}"
        status_pair "反向代理" "Nginx -> http://127.0.0.1:${komari_port}"
        [ "$enable_ssl" -eq 1 ] && status_pair "SSL" "已启用"
    else
        access_url="http://${server_ip}:${komari_port}/"
        status_pair "访问地址" "${access_url}"
        status_pair "反向代理" "未启用"
    fi

    draw_line
    msg_warn "请记录以上信息！"
    msg_info "防火墙放行: 在本脚本 [3] 防火墙策略 → [2] 端口与连通性 → [1] 开放指定端口"
    if [ "$use_nginx" -eq 1 ]; then
        msg_info "需放行端口: ${listen_port}/tcp"
    else
        msg_info "需放行端口: ${komari_port}/tcp"
    fi
    msg_info "管理命令: systemctl status|restart|stop ${service_name}"
    msg_info "查看日志: journalctl -u ${service_name} -f"
}
