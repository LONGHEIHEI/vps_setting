# ==============================================================================
# Nginx 安装与基础配置
# 安装 Nginx，配置优雅的默认站点页面，启用并启动服务
# ==============================================================================
ensure_nginx_base_config() {
    [ -f /etc/nginx/nginx.conf ] || return 0

    mkdir -p /etc/nginx/conf.d

    # 隐藏 Nginx 版本信息（HTTP 响应头 + 默认错误页）
    if ! grep -q 'server_tokens' /etc/nginx/nginx.conf 2>/dev/null; then
        sed -i '/http {/a \    server_tokens off;' /etc/nginx/nginx.conf 2>/dev/null || true
    elif grep -q 'server_tokens on' /etc/nginx/nginx.conf 2>/dev/null; then
        sed -i 's/server_tokens on/server_tokens off/' /etc/nginx/nginx.conf 2>/dev/null || true
    fi

    # 统一确保 conf.d 被 include，避免 Debian 已安装场景下写入 conf.d 却未生效
    grep -q 'include /etc/nginx/conf.d/\*\.conf;' /etc/nginx/nginx.conf 2>/dev/null || \
        sed -i '/http {/a \    include /etc/nginx/conf.d/*.conf;' /etc/nginx/nginx.conf 2>/dev/null || true

    if [ -f /etc/nginx/sites-available/default ]; then
        # Debian/Ubuntu 风格
        sed -i 's|root .*;|root /var/www/html;|' /etc/nginx/sites-available/default 2>/dev/null || true
    fi
}

reload_or_restart_nginx() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable nginx >/dev/null 2>&1 || true
        systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1
        return $?
    fi

    service nginx reload >/dev/null 2>&1 || service nginx restart >/dev/null 2>&1
}

validate_domain_name() {
    local domain="$1"
    local label

    [ -n "$domain" ] || return 1
    [ "${#domain}" -le 253 ] || return 1
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$domain" == *.* ]] || return 1
    [[ "$domain" != .* && "$domain" != *. ]] || return 1
    [[ "$domain" != *..* ]] || return 1

    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [ -n "$label" ] || return 1
        [ "${#label}" -le 63 ] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done

    return 0
}

normalize_web_base_path() {
    local raw="$1"
    raw=$(printf '%s' "$raw" | tr -d '[:space:]')
    raw="${raw#/}"
    raw="${raw%/}"
    printf '%s\n' "$raw"
}

format_web_base_path_for_url() {
    local raw="$1"
    raw=$(printf '%s' "$raw" | tr -d '[:space:]')
    if [ -z "$raw" ] || [ "$raw" = "/" ]; then
        printf '/\n'
        return 0
    fi
    raw=$(normalize_web_base_path "$raw")
    if [ -z "$raw" ]; then
        printf '/\n'
    else
        printf '/%s\n' "$raw"
    fi
}

validate_web_base_path() {
    local path
    path=$(normalize_web_base_path "$1")
    [ -n "$path" ] || return 1
    [ "${#path}" -ge 4 ] || return 1
    [[ "$path" =~ ^[A-Za-z0-9._~-]+$ ]]
}

prompt_required_file_path() {
    local prompt="$1"
    local default_path="$2"
    local __resultvar="$3"
    local input_path

    while true; do
        read -p "${prompt} [默认: ${default_path}]: " input_path
        input_path=${input_path:-$default_path}
        input_path=$(printf '%s' "$input_path" | tr -d '"' | tr -d "'")

        if [ ! -f "$input_path" ]; then
            msg_warn "文件不存在：${input_path}"
            continue
        fi
        if [ ! -r "$input_path" ]; then
            msg_warn "文件不可读：${input_path}"
            continue
        fi
        if [ ! -s "$input_path" ]; then
            msg_warn "文件为空：${input_path}"
            continue
        fi

        printf -v "$__resultvar" '%s' "$input_path"
        return 0
    done
}

ensure_readable_nonempty_file() {
    local file_path="$1"
    local label="${2:-文件}"

    if [ ! -f "$file_path" ]; then
        msg_err "${label}不存在：${file_path}"
        return 1
    fi
    if [ ! -r "$file_path" ]; then
        msg_err "${label}不可读：${file_path}"
        return 1
    fi
    if [ ! -s "$file_path" ]; then
        msg_err "${label}为空文件：${file_path}"
        return 1
    fi

    return 0
}

collect_nginx_proxy_target() {
    local __domain_var="$1"
    local __listen_port_var="$2"
    local __enable_ssl_var="$3"
    local __cert_file_var="$4"
    local __key_file_var="$5"
    local input_domain input_listen_port input_enable_ssl input_cert_file input_key_file

    while true; do
        read -p "请输入绑定域名 (例如 panel.example.com): " input_domain
        if validate_domain_name "$input_domain"; then
            break
        fi
        msg_warn "域名格式无效，请重新输入。"
    done

    while true; do
        read -p "Nginx 对外监听端口 [默认 443]: " input_listen_port
        input_listen_port=${input_listen_port:-443}
        if validate_port "$input_listen_port"; then
            break
        fi
        msg_warn "端口必须是 1-65535 的数字。"
    done

    read -p "是否启用 SSL 反向代理? (Y/n): " input_enable_ssl
    input_enable_ssl=${input_enable_ssl:-Y}
    if [[ "$input_enable_ssl" =~ ^[Nn]$ ]]; then
        input_enable_ssl=0
        input_cert_file=""
        input_key_file=""
    else
        input_enable_ssl=1
        if [ "$input_listen_port" -eq 80 ]; then
            msg_err "启用 SSL 时，Nginx 监听端口不能使用 80。请改用 443/8443 等 HTTPS 端口。"
            return 1
        fi
        input_cert_file="$DEFAULT_PANEL_CERT_FILE"
        input_key_file="$DEFAULT_PANEL_KEY_FILE"
        ensure_readable_nonempty_file "$input_cert_file" "SSL 证书文件" || return 1
        ensure_readable_nonempty_file "$input_key_file" "SSL 私钥文件" || return 1
        msg_info "SSL 证书将固定使用：${input_cert_file}"
        msg_info "SSL 私钥将固定使用：${input_key_file}"
    fi

    printf -v "$__domain_var" '%s' "$input_domain"
    printf -v "$__listen_port_var" '%s' "$input_listen_port"
    printf -v "$__enable_ssl_var" '%s' "$input_enable_ssl"
    printf -v "$__cert_file_var" '%s' "$input_cert_file"
    printf -v "$__key_file_var" '%s' "$input_key_file"
}

prepare_nginx_proxy_environment() {
    local fail_message="$1"

    msg_info "正在预安装/校验 Nginx 环境..."
    install_nginx || {
        msg_err "$fail_message"
        return 1
    }
}

build_nginx_listen_directive() {
    local listen_port="$1"
    local ssl_enabled="$2"
    local cert_file="$3"
    local key_file="$4"

    if [ "$ssl_enabled" -eq 1 ]; then
        cat <<EOF
    listen ${listen_port} ssl http2;
    listen [::]:${listen_port} ssl http2;
    ssl_certificate ${cert_file};
    ssl_certificate_key ${key_file};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
EOF
    else
        cat <<EOF
    listen ${listen_port};
    listen [::]:${listen_port};
EOF
    fi
}

write_generic_nginx_proxy_config() {
    local conf_file="$1"
    local redirect_file="$2"
    local domain="$3"
    local listen_port="$4"
    local ssl_enabled="$5"
    local cert_file="$6"
    local key_file="$7"
    local config_label="$8"
    local server_body="$9"
    local conf_dir conf_backup="" redirect_backup="" listen_directive server_block

    conf_dir=$(dirname "$conf_file")
    mkdir -p "$conf_dir" || {
        msg_err "创建 Nginx 配置目录失败：${conf_dir}"
        return 1
    }

    if [ -f "$conf_file" ]; then
        conf_backup="${conf_file}.bak.$(date +%F_%H%M%S)"
        cp -af "$conf_file" "$conf_backup" || return 1
    fi
    if [ -f "$redirect_file" ]; then
        redirect_backup="${redirect_file}.bak.$(date +%F_%H%M%S)"
        cp -af "$redirect_file" "$redirect_backup" || return 1
    fi

    listen_directive=$(build_nginx_listen_directive "$listen_port" "$ssl_enabled" "$cert_file" "$key_file")
    server_block=$(cat <<EOF
server {
${listen_directive}
    server_name ${domain};

${server_body}
}
EOF
)

    printf '%s\n' "$server_block" > "$conf_file" || {
        msg_err "写入 Nginx 配置失败：${conf_file}"
        return 1
    }

    if [ "$ssl_enabled" -eq 1 ] && [ "$listen_port" -ne 80 ]; then
        cat > "$redirect_file" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$host:${listen_port}\$request_uri;
}
EOF
    else
        rm -f "$redirect_file"
    fi

    if ! nginx -t >/dev/null 2>&1; then
        msg_err "Nginx 配置测试失败，正在回滚${config_label}反代配置。"
        if [ -n "$conf_backup" ] && [ -f "$conf_backup" ]; then
            cp -af "$conf_backup" "$conf_file"
        else
            rm -f "$conf_file"
        fi
        if [ -n "$redirect_backup" ] && [ -f "$redirect_backup" ]; then
            cp -af "$redirect_backup" "$redirect_file"
        else
            rm -f "$redirect_file"
        fi
        return 1
    fi

    reload_or_restart_nginx || {
        msg_err "Nginx 重载失败，请检查服务状态。"
        return 1
    }

    return 0
}

get_3x_ui_cli_path() {
    if [ -x /usr/local/x-ui/x-ui ]; then
        printf '%s\n' "/usr/local/x-ui/x-ui"
        return 0
    fi
    if command -v x-ui >/dev/null 2>&1; then
        command -v x-ui
        return 0
    fi
    return 1
}

set_3x_ui_panel_settings() {
    local xui_cli="$1"
    local username="$2"
    local password="$3"
    local port="$4"
    local web_base_path="$5"

    "$xui_cli" setting \
        -username "$username" \
        -password "$password" \
        -port "$port" \
        -webBasePath "$web_base_path" >/dev/null 2>&1
}

set_3x_ui_subscription_paths() {
    local subscription_token="$1"
    local db_path="/etc/x-ui/x-ui.db"
    local sub_path="/${subscription_token}/"
    local sub_json_path="/${subscription_token}-json/"
    local sub_clash_path="/${subscription_token}-clash/"

    [ -f "$db_path" ] || {
        msg_warn "未找到 3x-ui 数据库文件，跳过订阅 URI 路径预设：${db_path}"
        return 1
    }

    ensure_basic_tool_installed python3 python3 || {
        msg_warn "未检测到 python3，无法自动预设 3x-ui 订阅 URI 路径。"
        return 1
    }

    python3 - "$db_path" "$sub_path" "$sub_json_path" "$sub_clash_path" <<'PY'
import sqlite3
import sys

db_path, sub_path, sub_json_path, sub_clash_path = sys.argv[1:5]
updates = {
    "subPath": sub_path,
    "subJsonPath": sub_json_path,
    "subClashPath": sub_clash_path,
}

conn = sqlite3.connect(db_path)
try:
    cur = conn.cursor()
    for key, value in updates.items():
        cur.execute("UPDATE settings SET value=? WHERE key=?", (value, key))
        if cur.rowcount == 0:
            cur.execute("INSERT INTO settings(key, value) VALUES(?, ?)", (key, value))
    conn.commit()
finally:
    conn.close()
PY
}

patch_3x_ui_install_script_for_suite() {
    local script_path="$1"
    local tmp_file patched=0

    tmp_file=$(mktemp) || return 1
    awk '
        BEGIN { patched = 0 }
        {
            if (!patched && $0 ~ /^[[:space:]]*config_after_install[[:space:]]*$/) {
                print "    # config_after_install skipped by VPS Init Suite"
                print "    true"
                patched = 1
                next
            }
            print
        }
        END {
            if (!patched) exit 1
        }
    ' "$script_path" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }

    cat "$tmp_file" > "$script_path" || {
        rm -f "$tmp_file"
        return 1
    }
    rm -f "$tmp_file"
}

write_3x_ui_nginx_proxy_config() {
    local domain="$1"
    local listen_port="$2"
    local ssl_enabled="$3"
    local cert_file="$4"
    local key_file="$5"
    local xui_port="$6"
    local xui_url_path="$7"
    local conf_dir="/etc/nginx/conf.d"
    local conf_file="${conf_dir}/3x-ui.conf"
    local redirect_file="${conf_dir}/3x-ui-redirect.conf"
    local server_body

    server_body=$(cat <<EOF
    # 3x-ui 面板入口：${xui_url_path}
    location / {
        proxy_pass http://127.0.0.1:${xui_port};
        proxy_http_version 1.1;
        proxy_redirect off;
        proxy_buffering off;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
    }
EOF
)

    write_generic_nginx_proxy_config \
        "$conf_file" "$redirect_file" "$domain" "$listen_port" "$ssl_enabled" \
        "$cert_file" "$key_file" " 3x-ui" "$server_body"
}

get_3x_ui_panel_runtime_settings() {
    local xui_cli="$1"
    local __port_var="$2"
    local __path_var="$3"
    local info port path

    info=$("$xui_cli" setting -show true 2>/dev/null) || return 1
    port=$(printf '%s\n' "$info" | awk -F': ' '/^port:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')
    path=$(printf '%s\n' "$info" | awk -F': ' '/^webBasePath:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')

    validate_port "$port" || return 1
    printf -v "$__port_var" '%s' "$port"
    printf -v "$__path_var" '%s' "$(format_web_base_path_for_url "$path")"
    return 0
}

install_nginx() {
    local nginx_version nginx_status

    # 检查是否已安装
    if command -v nginx >/dev/null 2>&1; then
        ensure_nginx_base_config
        nginx_version=$(nginx -v 2>&1 | awk '{print $NF}')
        nginx_status=$(systemctl is-active nginx 2>/dev/null || echo '未运行')
        msg_warn "Nginx 已安装: ${nginx_version}"
        msg_info "如需重装，请先卸载现有版本。"
        status_pair "Nginx" "${nginx_version}"
        status_pair "配置目录" "/etc/nginx"
        status_pair "站点目录" "/var/www/html"
        status_pair "状态" "${nginx_status}"
        return 0
    fi

    msg_info "正在安装 Nginx..."
    pkg_update || true
    pkg_install nginx || {
        msg_err "Nginx 安装失败，请检查软件源。"
        return 1
    }

    ensure_nginx_base_config

    # 配置测试
    nginx -t 2>/dev/null || {
        msg_warn "Nginx 配置测试未通过，请检查 /etc/nginx/nginx.conf"
    }

    # 启用并启动服务
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable nginx >/dev/null 2>&1 || true
        systemctl restart nginx >/dev/null 2>&1 || {
            msg_err "Nginx 服务启动失败，请检查: systemctl status nginx"
            return 1
        }
    else
        service nginx restart >/dev/null 2>&1 || {
            msg_err "Nginx 服务启动失败。"
            return 1
        }
    fi

    nginx_version=$(nginx -v 2>&1 | awk '{print $NF}')
    msg_ok "Nginx 安装完成！"
    draw_line
    status_pair "Nginx" "${nginx_version}"
    status_pair "配置目录" "/etc/nginx"
    status_pair "站点目录" "/var/www/html"
    status_pair "状态" "运行中"
    draw_line
    msg_info "默认站点已配置，请根据需要修改 /etc/nginx 下的配置文件。"

    # 为管理用户配置受限 sudo 权限（用于 Certimate 等工具自动部署证书）
    local certsync_user="${AUTO_DEPLOY_USER:-$DEFAULT_AUTO_INIT_USER}"
    local sudoers_file="/etc/sudoers.d/vps-init-suite-certsync-${certsync_user}"
    if id "$certsync_user" >/dev/null 2>&1; then
        if [ ! -f "$sudoers_file" ]; then
            cat > "$sudoers_file" <<SUDOERSEOF
# Managed by VPS Init Suite - 允许 ${certsync_user} 用户非交互执行证书部署相关命令
# 用途：Certimate 后置命令需要非交互执行 install（创建目录/复制文件/设置权限）和重载 Nginx
Defaults:${certsync_user} !requiretty
Cmnd_Alias CERTSYNC = /usr/bin/install, /usr/bin/systemctl reload nginx, /usr/bin/systemctl reload nginx.service
${certsync_user} ALL=(root) NOPASSWD: CERTSYNC
SUDOERSEOF
            chmod 440 "$sudoers_file"
            # 校验 sudoers 语法
            if visudo -c >/dev/null 2>&1; then
                msg_ok "已为 ${certsync_user} 配置受限 sudo 权限（证书部署 + 重载 Nginx）"
            else
                msg_err "sudoers 语法校验失败，正在回滚。"
                rm -f "$sudoers_file"
            fi
        else
            msg_info "${certsync_user} 受限 sudo 权限已存在 (${sudoers_file})，跳过。"
        fi
    else
        msg_warn "用户 ${certsync_user} 不存在，跳过受限 sudo 权限配置。"
        msg_info "创建 ${certsync_user} 用户后可重新安装 Nginx 以自动配置。"
    fi
}
