run_docker_compose_file() {
    local compose_file="$1"
    shift

    if docker compose version >/dev/null 2>&1; then
        docker compose -f "$compose_file" "$@"
        return $?
    fi

    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose -f "$compose_file" "$@"
        return $?
    fi

    return 1
}

uninstall_nezha_dashboard() {
    local base_path="/opt/nezha"
    local dashboard_path="${base_path}/dashboard"
    local service_file="/etc/systemd/system/nezha-dashboard.service"
    local service_openrc="/etc/init.d/nezha-dashboard"
    local compose_file="${dashboard_path}/docker-compose.yaml"
    local removed_any=0

    if [ -d "$dashboard_path" ]; then
        confirm "确认卸载哪吒面板并删除目录 ${dashboard_path}（其中数据和配置将被永久删除）?" || return 1
    fi

    if [ -f "$compose_file" ]; then
        if run_docker_compose_file "$compose_file" down >/dev/null 2>&1; then
            msg_ok "已停止哪吒面板 Docker 编排。"
        else
            msg_warn "未能通过 docker compose 停止哪吒面板，继续执行文件清理。"
        fi
        if command -v docker >/dev/null 2>&1; then
            docker rmi -f ghcr.io/nezhahq/nezha >/dev/null 2>&1 || true
            docker rmi -f registry.cn-shanghai.aliyuncs.com/naibahq/nezha-dashboard >/dev/null 2>&1 || true
        fi
        removed_any=1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable nezha-dashboard >/dev/null 2>&1 || true
        systemctl stop nezha-dashboard >/dev/null 2>&1 || true
    else
        service nezha-dashboard stop >/dev/null 2>&1 || true
    fi

    [ -f "$service_file" ] && removed_any=1
    [ -f "$service_openrc" ] && removed_any=1
    rm -f "$service_file" "$service_openrc"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true

    if [ -d "$dashboard_path" ]; then
        rm -rf "$dashboard_path"
        removed_any=1
    fi

    if [ "$removed_any" -eq 1 ]; then
        msg_ok "哪吒面板卸载完成。"
    else
        msg_info "未检测到哪吒面板安装目录或服务文件。"
    fi
}

uninstall_nezha_agent() {
    local agent_path="/opt/nezha/agent"
    local agent_bin="${agent_path}/nezha-agent"
    local removed_any=0
    local config_file
    local unit

    if [ -d "$agent_path" ]; then
        confirm "确认卸载哪吒探针并删除目录 ${agent_path}（其中配置将被永久删除）?" || return 1
    fi

    if [ -x "$agent_bin" ] && [ -d "$agent_path" ]; then
        while IFS= read -r config_file; do
            [ -n "$config_file" ] || continue
            "$agent_bin" service -c "$config_file" uninstall >/dev/null 2>&1 || true
            rm -f "$config_file"
            removed_any=1
        done < <(find "$agent_path" -type f \( -name '*config*.yml' -o -name '*config*.yaml' \) 2>/dev/null)
    fi

    if command -v systemctl >/dev/null 2>&1; then
        while IFS= read -r unit; do
            [ -n "$unit" ] || continue
            systemctl stop "$unit" >/dev/null 2>&1 || true
            systemctl disable "$unit" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/${unit}" "/usr/lib/systemd/system/${unit}" "/lib/systemd/system/${unit}"
            removed_any=1
        done < <(systemctl list-unit-files --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep '^nezha-agent.*\.service$' || true)
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed >/dev/null 2>&1 || true
    fi

    pkill -f '/opt/nezha/agent/nezha-agent' >/dev/null 2>&1 || true

    if [ -d "$agent_path" ]; then
        rm -rf "$agent_path"
        removed_any=1
    fi

    if [ "$removed_any" -eq 1 ]; then
        msg_ok "哪吒探针卸载完成。"
    else
        msg_info "未检测到哪吒探针安装目录或服务文件。"
    fi
}

get_menu_item_status_simple() {
    local mode="$1"
    case "$mode" in
        docker)
            if command -v docker >/dev/null 2>&1; then
                printf '%s\n' "已安装"
            else
                printf '%s\n' "未安装"
            fi
            ;;
        nginx)
            if command -v nginx >/dev/null 2>&1; then
                printf '%s\n' "已安装"
            else
                printf '%s\n' "未安装"
            fi
            ;;
        3x-ui)
            if command -v x-ui >/dev/null 2>&1 || [ -x /usr/local/x-ui/x-ui.sh ]; then
                printf '%s\n' "已安装"
            else
                printf '%s\n' "未安装"
            fi
            ;;
        komari)
            if [ -x /usr/local/komari/komari ] || command -v komari >/dev/null 2>&1; then
                printf '%s\n' "已安装"
            else
                printf '%s\n' "未安装"
            fi
            ;;
        1panel)
            if command -v 1pctl >/dev/null 2>&1 || [ -x /usr/local/bin/1pctl ] || [ -x /usr/bin/1pctl ]; then
                printf '%s\n' "已安装"
            else
                printf '%s\n' "未安装"
            fi
            ;;
        lucky)
            if [ -x /etc/lucky/lucky ] || command -v lucky >/dev/null 2>&1; then
                printf '%s\n' "已安装"
            else
                printf '%s\n' "未安装"
            fi
            ;;
        fail2ban)
            if command -v fail2ban-client >/dev/null 2>&1 || [ -d /etc/fail2ban ]; then
                printf '%s\n' "已安装"
            else
                printf '%s\n' "未安装"
            fi
            ;;
        *)
            printf '%s\n' "-"
            ;;
    esac
}

remove_3x_ui_nginx_proxy_configs() {
    local conf_dir="/etc/nginx/conf.d"
    local removed=0

    if [ -f "${conf_dir}/3x-ui.conf" ]; then
        rm -f "${conf_dir}/3x-ui.conf"
        removed=1
    fi
    if [ -f "${conf_dir}/3x-ui-redirect.conf" ]; then
        rm -f "${conf_dir}/3x-ui-redirect.conf"
        removed=1
    fi

    if [ "$removed" -eq 1 ]; then
        if command -v nginx >/dev/null 2>&1; then
            if nginx -t >/dev/null 2>&1; then
                reload_or_restart_nginx >/dev/null 2>&1 || true
            else
                msg_warn "删除 3x-ui 的 Nginx 反代配置后，Nginx 校验未通过，请手动执行 nginx -t 检查。"
            fi
        fi
        msg_ok "已删除 3x-ui 对应的 Nginx 反代配置文件。"
    else
        msg_info "未发现 3x-ui 的 Nginx 反代配置文件。"
    fi
}

uninstall_docker() {
    local pkg_mgr
    local installed_pkgs=()
    local pkg_list=(
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
        docker-compose docker-compose-v2 docker.io docker-doc podman-docker containerd runc moby-engine moby-cli
    )

    pkg_mgr=$(get_pkg_manager)
    [ -n "$pkg_mgr" ] || {
        msg_err "未识别到受支持的包管理器，无法自动卸载 Docker。"
        return 1
    }

    mapfile -t installed_pkgs < <(filter_installed_packages "${pkg_list[@]}" | awk 'NF')

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop docker.service docker.socket containerd.service >/dev/null 2>&1 || true
        systemctl disable docker.service docker.socket containerd.service >/dev/null 2>&1 || true
    else
        service docker stop >/dev/null 2>&1 || true
        service containerd stop >/dev/null 2>&1 || true
    fi

    if has_systemd_service "$DOCKER_GUARD_SERVICE_NAME"; then
        systemctl stop "$DOCKER_GUARD_SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$DOCKER_GUARD_SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    rm -f "$DOCKER_GUARD_SERVICE_PATH" "$DOCKER_GUARD_APPLY_SCRIPT" "$DOCKER_GUARD_CONFIG_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true

    if [ "${#installed_pkgs[@]}" -gt 0 ]; then
        msg_info "准备卸载 Docker 相关软件包：${installed_pkgs[*]}"
        pkg_remove "${installed_pkgs[@]}" || {
            msg_err "Docker 软件包卸载失败。"
            return 1
        }
        [ "$pkg_mgr" = "apt" ] && apt-get autoremove -y >/dev/null 2>&1 || true
    else
        msg_info "未检测到已安装的 Docker 软件包。"
    fi

    rm -f /usr/local/bin/docker-compose /usr/bin/docker-compose 2>/dev/null || true

    if confirm "是否同时删除 Docker 运行数据与配置目录? (/var/lib/docker /var/lib/containerd /etc/docker)"; then
        rm -rf -- /var/lib/docker /var/lib/containerd /etc/docker
        msg_ok "Docker 运行数据与配置目录已删除。"
    else
        msg_warn "已保留 Docker 运行数据与配置目录。"
    fi

    msg_ok "Docker 卸载流程已完成。"
}

uninstall_3x_ui() {
    local xui_cmd=""

    if command -v x-ui >/dev/null 2>&1; then
        xui_cmd=$(command -v x-ui)
    elif [ -x /usr/local/x-ui/x-ui.sh ]; then
        xui_cmd="/usr/local/x-ui/x-ui.sh"
    fi

    if [ -n "$xui_cmd" ]; then
        msg_info "检测到 3x-ui 管理命令：${xui_cmd}"
        if ! printf 'y\n' | "$xui_cmd" uninstall; then
            if [ -d /etc/x-ui ] || [ -d /usr/local/x-ui ]; then
                msg_warn "官方卸载命令返回异常，继续执行手动清理兜底。"
            fi
        fi
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop x-ui >/dev/null 2>&1 || true
        systemctl disable x-ui >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/x-ui.service /usr/lib/systemd/system/x-ui.service
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed >/dev/null 2>&1 || true
    else
        service x-ui stop >/dev/null 2>&1 || true
    fi

    if confirm "确认删除 3x-ui 数据目录 /etc/x-ui 与 /usr/local/x-ui?"; then
        rm -rf -- /etc/x-ui /usr/local/x-ui
    else
        msg_warn "已保留 3x-ui 数据目录。"
    fi
    rm -f /usr/local/bin/x-ui /usr/bin/x-ui

    if confirm "是否同时删除 3x-ui 对应的 Nginx 反代配置文件? (/etc/nginx/conf.d/3x-ui*.conf)"; then
        remove_3x_ui_nginx_proxy_configs
    fi

    msg_ok "3x-ui 卸载流程已完成。"
}

uninstall_lucky_standard() {
    local install_dir="/etc/lucky"
    local service_name="lucky.service"
    local service_path="/etc/systemd/system/${service_name}"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "$service_name" >/dev/null 2>&1 || true
        systemctl disable "$service_name" >/dev/null 2>&1 || true
    fi
    pkill -f '/etc/lucky/lucky' >/dev/null 2>&1 || true

    rm -f "$service_path" /usr/lib/systemd/system/${service_name}
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true

    rm -f /usr/local/bin/lucky
    rm -rf "$install_dir"

    msg_ok "Lucky 普通版卸载完成。"
}

uninstall_1panel() {
    local cmd=""

    if command -v 1pctl >/dev/null 2>&1; then
        cmd=$(command -v 1pctl)
    elif [ -x /usr/local/bin/1pctl ]; then
        cmd="/usr/local/bin/1pctl"
    elif [ -x /usr/bin/1pctl ]; then
        cmd="/usr/bin/1pctl"
    fi

    if [ -z "$cmd" ]; then
        msg_err "未检测到 1Panel 管理命令 1pctl，无法安全调用官方卸载流程。"
        msg_info "请确认 1Panel 是否已安装，或手动执行官方卸载命令。"
        return 1
    fi

    msg_info "将调用官方卸载命令：${cmd} uninstall"
    "$cmd" uninstall
}

uninstall_nginx() {
    local pkg_mgr
    local installed_pkgs=()
    local pkg_list=(nginx nginx-common nginx-core nginx-full nginx-light nginx-mod-stream nginx-all-modules)

    pkg_mgr=$(get_pkg_manager)
    [ -n "$pkg_mgr" ] || {
        msg_err "未识别到受支持的包管理器，无法自动卸载 Nginx。"
        return 1
    }

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop nginx >/dev/null 2>&1 || true
        systemctl disable nginx >/dev/null 2>&1 || true
    else
        service nginx stop >/dev/null 2>&1 || true
    fi

    mapfile -t installed_pkgs < <(filter_installed_packages "${pkg_list[@]}" | awk 'NF')
    if [ "${#installed_pkgs[@]}" -gt 0 ]; then
        msg_info "准备卸载 Nginx 相关软件包：${installed_pkgs[*]}"
        pkg_remove "${installed_pkgs[@]}" || {
            msg_err "Nginx 软件包卸载失败。"
            return 1
        }
        [ "$pkg_mgr" = "apt" ] && apt-get autoremove -y >/dev/null 2>&1 || true
    else
        msg_info "未检测到已安装的 Nginx 软件包。"
    fi

    rm -f /etc/sudoers.d/vps-init-suite-certsync-*

    if confirm "是否同时删除 Nginx 配置与站点目录? (/etc/nginx /var/www/html /var/log/nginx)"; then
        rm -rf -- /etc/nginx /var/www/html /var/log/nginx
        msg_ok "Nginx 配置与站点目录已删除。"
    else
        msg_warn "已保留 Nginx 配置与站点目录。"
    fi

    msg_ok "Nginx 卸载流程已完成。"
}

uninstall_fail2ban() {
    local pkg_mgr
    local installed_pkgs=()
    local pkg_list=(fail2ban fail2ban-server fail2ban-systemd)

    pkg_mgr=$(get_pkg_manager)
    [ -n "$pkg_mgr" ] || {
        msg_err "未识别到受支持的包管理器，无法自动卸载 Fail2Ban。"
        return 1
    }

    if command -v fail2ban-client >/dev/null 2>&1; then
        fail2ban-client unban --all >/dev/null 2>&1 || true
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop fail2ban >/dev/null 2>&1 || true
        systemctl disable fail2ban >/dev/null 2>&1 || true
    else
        service fail2ban stop >/dev/null 2>&1 || true
    fi

    remove_fail2ban_managed_jail_local || {
        msg_err "移除 Fail2Ban 托管配置失败，已停止卸载以避免留下不一致状态。"
        return 1
    }

    mapfile -t installed_pkgs < <(filter_installed_packages "${pkg_list[@]}" | awk 'NF')
    if [ "${#installed_pkgs[@]}" -gt 0 ]; then
        msg_info "准备卸载 Fail2Ban 软件包：${installed_pkgs[*]}"
        pkg_remove "${installed_pkgs[@]}" || {
            msg_err "Fail2Ban 软件包卸载失败。"
            return 1
        }
        [ "$pkg_mgr" = "apt" ] && apt-get autoremove --purge -y >/dev/null 2>&1 || true
    else
        msg_info "未检测到已安装的 Fail2Ban 软件包。"
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true

    if confirm "是否同时删除 Fail2Ban 配置、数据库和日志? (/etc/fail2ban /var/lib/fail2ban /var/log/fail2ban.log)"; then
        rm -rf -- /etc/fail2ban /var/lib/fail2ban
        rm -f -- /var/log/fail2ban.log
        msg_ok "Fail2Ban 配置、数据库和日志已删除。"
    else
        msg_warn "已保留 Fail2Ban 配置、数据库和日志。"
    fi

    msg_ok "Fail2Ban 卸载流程已完成。"
}
