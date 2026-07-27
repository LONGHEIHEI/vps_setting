# [全自动一键部署] 入口函数
# 流程：更新索引 → SSH → 工具 → 用户 → 证书 → SSH安全配置 → SSH登录Banner → DNS → 终端美化 → 防火墙 → 输出结果
# 设计原则：每步独立，关键步骤失败则终止（return 1），非关键步骤失败跳过（|| true）
# ==============================================================================
run_inlined_auto_deploy() {
    local ssh_backup current_port system_pretty_name
    local step=1
    local total_steps=11

    collect_auto_deploy_inputs || return 1

    # 步骤 1: 更新软件包索引（非关键，失败跳过）
    printf "\n"
    draw_line
    msg_info "[全自动] 步骤 ${step}/${total_steps}: 更新软件索引"
    step=$((step + 1))
    pkg_update || true

    # 步骤 2: 确保 SSH 服务器已安装（关键步骤，失败终止）
    printf "\n"
    draw_line
    msg_info "[全自动] 步骤 ${step}/${total_steps}: 检查并安装 openssh-server"
    step=$((step + 1))
    ensure_ssh_server_installed || return 1

    # 步骤 3: 安装常用运维工具（关键步骤，失败终止）
    printf "\n"
    draw_line
    msg_info "[全自动] 步骤 ${step}/${total_steps}: 安装常用工具"
    step=$((step + 1))
    install_common_ops_tools || return 1

    # 步骤 4: 创建管理用户、设置用户密码和 root 密码（关键步骤）
    printf "\n"
    draw_line
    msg_info "[全自动] 步骤 ${step}/${total_steps}: 创建管理用户并设置密码"
    step=$((step + 1))
    auto_deploy_create_user_and_passwords || return 1

    # 步骤 5: 创建 sshl 证书目录并设置属主/权限
    printf "\n"
    draw_line
    msg_info "[全自动] 步骤 ${step}/${total_steps}: 创建证书目录"
    step=$((step + 1))
    create_sshl_certs_dir || return 1

    # 步骤 6: SSH 安全配置（备份 → 清理冲突 → 设置指令 → 安全校验 → 重启）
    printf "\n"
    draw_line
    msg_info "[全自动] 步骤 ${step}/${total_steps}: 备份并应用 SSH 安全配置"
    step=$((step + 1))
    ssh_backup=$(backup_file_with_timestamp /etc/ssh/sshd_config) || {
        msg_err "备份 sshd 配置失败。"
        return 1
    }
    AUTO_DEPLOY_LAST_SSH_BACKUP="$ssh_backup"

    prepare_main_sshd_config_for_managed_mode || {
        restore_sshd_backup_state "$ssh_backup"
        return 1
    }

    set_sshd_directive "PermitRootLogin" "no"
    set_sshd_directive "PasswordAuthentication" "yes"

    current_port=$(get_current_ssh_port)
    if [ "$current_port" = "$AUTO_DEPLOY_SSH_PORT" ]; then
        set_sshd_directive "Port" "$AUTO_DEPLOY_SSH_PORT"
        apply_sshd_changes "SSH 安全配置已应用" "$ssh_backup" || return 1
    else
        change_ssh_port_safely "$AUTO_DEPLOY_SSH_PORT" "SSH 安全配置已应用" 1 "$ssh_backup" || return 1
    fi

    # 步骤 7: SSH 动态登录 Banner（同时静默系统 MOTD / Last login）
    printf "\n"
    draw_line
    msg_info "[全自动] 步骤 ${step}/${total_steps}: 添加 SSH 动态登录 Banner"
    step=$((step + 1))
    install_ssh_login_banner || true

    # 步骤 8: DNS 解析优化（配置 8.8.8.8 + 1.1.1.1，非关键步骤）
    printf "\n"
    draw_line
    msg_info "[全自动] 步骤 ${step}/${total_steps}: DNS 解析优化"
    step=$((step + 1))
    apply_dns_optimization || true

    # 步骤 9: 终端环境美化（彩色 PS1 + 实用别名，非关键步骤）
    printf "\n"
    draw_line
    msg_info "[全自动] 步骤 ${step}/${total_steps}: 终端环境美化"
    step=$((step + 1))
    apply_terminal_beautification || true

    # 步骤 10: 配置 iptables 防火墙（先识别并保留当前已放行端口，再切换为托管白名单模式）
    printf "\n"
    draw_line
    msg_info "[全自动] 步骤 ${step}/${total_steps}: 配置 iptables 防火墙"
    step=$((step + 1))
    enable_iptables || return 1
    show_auto_deploy_iptables_rules

    # 步骤 11: 输出部署摘要（系统版本、端口、用户密码、防火墙策略等）
    system_pretty_name=$(awk -F= '/^PRETTY_NAME=/{gsub(/^"|"$/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null)

    printf "\n"
    draw_line
    msg_info "[全自动] 步骤 ${step}/${total_steps}: 输出部署结果"
    msg_ok "全部操作完成。"
    draw_line
    status_pair "系统版本" "${system_pretty_name:-unknown}"
    status_pair "SSH 端口" "${AUTO_DEPLOY_SSH_PORT}"
    status_pair "新用户" "${AUTO_DEPLOY_USER}"
    status_pair "用户密码" "已设置"
    status_pair "root 密码" "已设置"
    status_pair "常用工具" "$(get_common_ops_tools_summary)"
    status_pair "证书目录" "${SSHL_CERTS_DIR}"
    status_pair "SSH Banner" "$(get_ssh_login_banner_status)"
    status_pair "DNS" "$(get_dns_status)"
    status_pair "防火墙策略" "允许 ping，保留当前已开放端口，并确保放行入站 TCP/${AUTO_DEPLOY_SSH_PORT}"
    status_pair "sshd 备份" "${AUTO_DEPLOY_LAST_SSH_BACKUP}"
    draw_line
    printf "\n"
    msg_warn "请立即新开终端测试:"
    msg_text "ssh -p ${AUTO_DEPLOY_SSH_PORT} ${AUTO_DEPLOY_USER}@你的服务器IP"
}
