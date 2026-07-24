#!/bin/bash

# =================================================================
# 名称: VPS Master Ultimate Suite - Comprehensive Edition
# 描述: 工业级分级目录，全状态感知 UI，集成安全、网络、运维深度管理
# 更新: 2026-04-29 - 优化缓存/远程脚本执行/交互输入处理
# =================================================================

# --- [1. 基础变量与颜色定义] ---
detect_terminal_theme() {
    local theme="${VPS_SUITE_THEME:-auto}"
    local colorfgbg bg_index

    case "$theme" in
        light|dark)
            printf '%s\n' "$theme"
            return 0
            ;;
    esac

    colorfgbg="${COLORFGBG:-}"
    if [ -n "$colorfgbg" ]; then
        bg_index="${colorfgbg##*;}"
        if [[ "$bg_index" =~ ^[0-9]+$ ]]; then
            if [ "$bg_index" -eq 7 ] || [ "$bg_index" -eq 15 ] || [ "$bg_index" -ge 10 ]; then
                printf 'light\n'
                return 0
            fi
        fi
    fi

    printf 'dark\n'
}

init_color_palette() {
    local theme
    theme=$(detect_terminal_theme)

    if [ -n "${NO_COLOR:-}" ]; then
        RED=''
        GREEN=''
        YELLOW=''
        BLUE=''
        CYAN=''
        MAGENTA=''
        DIM=''
        W1=''
        NC=''
        return 0
    fi

    if [ "$theme" = "light" ]; then
        RED='\033[31m'
        GREEN='\033[32m'
        YELLOW='\033[33m'
        BLUE='\033[34m'
        CYAN='\033[36m'
        MAGENTA='\033[35m'
        DIM='\033[37m'
        W1='\033[0m'
    else
        RED='\033[31m'
        GREEN='\033[32m'
        YELLOW='\033[33m'
        BLUE='\033[34m'
        CYAN='\033[36m'
        MAGENTA='\033[35m'
        DIM='\033[37m'
        W1='\033[0m'
    fi

    NC='\033[0m'
}

init_color_palette

DEFAULT_SSH_PORT=60110
AUTO_DEPLOY_SSH_PORT="$DEFAULT_SSH_PORT"
DEFAULT_TIMEZONE="Asia/Shanghai"
DEFAULT_AUTO_INIT_USER="admin"
AUTO_DEPLOY_USER="$DEFAULT_AUTO_INIT_USER"
AUTO_DEPLOY_USER_PASS=''
AUTO_DEPLOY_ROOT_PASS=''
SSHL_CERTS_DIR="/data/certs"
SSHL_CERTS_OWNER="${AUTO_DEPLOY_USER}:${AUTO_DEPLOY_USER}"
DEFAULT_PANEL_CERT_FILE="${SSHL_CERTS_DIR}/cert.crt"
DEFAULT_PANEL_KEY_FILE="${SSHL_CERTS_DIR}/cert.key"
IPTABLES_RULE_DIR="/etc/iptables"
IPTABLES_RULES_V4="${IPTABLES_RULE_DIR}/rules.v4"
IPTABLES_RULES_V6="${IPTABLES_RULE_DIR}/rules.v6"
LEGACY_IPTABLES_RULES_V4="/etc/iptables.rules"
LEGACY_IPTABLES_RULES_V6="/etc/ip6tables.rules"
IPTABLES_RESTORE_SERVICE_NAME="vps-iptables-restore.service"
IPTABLES_RESTORE_SERVICE_PATH="/etc/systemd/system/${IPTABLES_RESTORE_SERVICE_NAME}"
IPTABLES_MANAGED_CHAIN="VPS_SUITE_INPUT"
IP6TABLES_MANAGED_CHAIN="VPS_SUITE_INPUT6"
SUITE_STATE_DIR="/etc/vps-init-suite"
FIREWALL_BACKEND_STATE_FILE="${SUITE_STATE_DIR}/firewall_backend"
DOCKER_GUARD_CONFIG_FILE="${SUITE_STATE_DIR}/docker_guard.conf"
DOCKER_GUARD_CHAIN="VPS_DOCKER_GUARD"
DOCKER_GUARD_CHAIN6="VPS_DOCKER_GUARD6"
DOCKER_GUARD_APPLY_SCRIPT="/usr/local/sbin/vps-docker-guard-apply.sh"
DOCKER_GUARD_SERVICE_NAME="vps-docker-guard.service"
DOCKER_GUARD_SERVICE_PATH="/etc/systemd/system/${DOCKER_GUARD_SERVICE_NAME}"
DOCKER_COMPOSE_REPO_URL="https://github.com/LongShengWen/docker-compose.git"
DOCKER_COMPOSE_STACK_DIR="/data/docker/compose"
SSHD_MANAGED_OVERRIDE_FILE="/etc/ssh/sshd_config.vps-init-suite.conf"
FAIL2BAN_SSH_JAIL_FILE="/etc/fail2ban/jail.local"
FAIL2BAN_LEGACY_JAILD_FILE="/etc/fail2ban/jail.d/vps-init-suite-sshd.local"
BBR_SYSCTL_FILE="/etc/sysctl.d/99-vps-init-suite-bbr.conf"
IPV6_SYSCTL_FILE="/etc/sysctl.d/99-vps-init-suite-ipv6.conf"
NETPLAN_IPV6_FIX_FILE="/etc/netplan/99-vps-init-suite-ipv6.yaml"
IFUPDOWN_OCI_IPV6_FIX_FILE="/etc/network/interfaces.d/99-vps-init-suite-oci-ipv6.cfg"
OCI_IPV6_APPLY_SCRIPT="/usr/local/sbin/vps-oci-ipv6-apply.sh"
OCI_IPV6_SERVICE_NAME="vps-oci-ipv6.service"
OCI_IPV6_SERVICE_PATH="/etc/systemd/system/${OCI_IPV6_SERVICE_NAME}"
LAST_SSHD_OVERRIDE_BACKUP=""
EXIT_ALL=0
AUTO_DEPLOY_LAST_SSH_BACKUP=""
DOCKER_DAEMON_CONFIG_STATE=""
PKG_MANAGER_CACHE=""
SSH_SERVICE_NAME_CACHE=""
UI_MIN_WIDTH=60
UI_MAX_WIDTH=88
UI_MENU_SPLIT_THRESHOLD=72
UI_MENU_GAP=4
UI_STATUS_LABEL_WIDTH=14
MENU_RESULT_CONTINUE=0
MENU_RESULT_EXIT_ALL=10
MENU_RESULT_RETRY=11
MENU_RESULT_BACK=12
declare -Ag DISPLAY_WIDTH_CACHE=()
declare -Ag SYSTEMD_SERVICE_EXISTS_CACHE=()

# 通用提示函数（统一风格，便于国际化/定制）
msg_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
msg_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
msg_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
msg_err()  { echo -e "${RED}[ERR]${NC} $*"; }
msg_prompt(){ echo -ne "${YELLOW}➤ $* ${NC}"; }
msg_plain() { echo -e "${BLUE}$*${NC}"; }
msg_text() { echo -e "$*"; }

is_utf8_locale() {
    local locale_text="${LANG:-}${LC_ALL:-}${LC_CTYPE:-}"
    [[ "$locale_text" =~ [Uu][Tt][Ff]-?8 ]]
}

invalidate_runtime_caches() {
    SSH_SERVICE_NAME_CACHE=""
    SYSTEMD_SERVICE_EXISTS_CACHE=()
}

# 权限校验
if [[ $EUID -ne 0 ]]; then
    msg_err "必须以 root 权限运行！"
    exit 1
fi

# --- [2. 核心底层工具函数] ---

# 操作前确认机制
confirm() {
    local prompt="$1"
    local response
    if is_utf8_locale; then
        printf "\n"
        msg_warn "⚠️ 警告: ${prompt}"
        msg_prompt "是否继续执行? (y/N):"
        IFS= read -r response
    else
        printf "\nWARNING: %s\n" "${prompt}"
        read -r -p "Proceed? (y/N): " response
    fi
    [[ "$response" =~ ^[Yy]$ ]]
}

# 打印分割线
draw_line_color() {
    local color="${1:-$BLUE}"
    local fill_char="${2:-}"
    local width

    width=$(get_ui_width)
    if [ -z "$fill_char" ]; then
        if is_utf8_locale; then
            fill_char="─"
        else
            fill_char="-"
        fi
    fi

    printf "%b%s%b\n" "$color" "$(repeat_char "$fill_char" "$width")" "$NC"
}

draw_line() {
    draw_line_color "$BLUE"
}

repeat_char() {
    local char="$1"
    local count="$2"
    local output=""

    while [ "$count" -gt 0 ]; do
        output+="$char"
        count=$((count - 1))
    done

    printf '%s' "$output"
}

get_terminal_width() {
    local cols="${COLUMNS:-}"

    if ! [[ "$cols" =~ ^[0-9]+$ ]] || [ "$cols" -le 0 ]; then
        cols=$(tput cols 2>/dev/null || echo 80)
    fi

    if ! [[ "$cols" =~ ^[0-9]+$ ]] || [ "$cols" -le 0 ]; then
        cols=80
    fi

    printf '%s\n' "$cols"
}

get_ui_width() {
    local cols
    cols=$(get_terminal_width)

    if [ "$cols" -lt "$UI_MIN_WIDTH" ]; then
        cols=$UI_MIN_WIDTH
    elif [ "$cols" -gt "$UI_MAX_WIDTH" ]; then
        cols=$UI_MAX_WIDTH
    fi

    printf '%s\n' "$cols"
}

print_menu_line() {
    local text="$1"
    local width content_width

    width=$(get_ui_width)
    content_width=$((width - 2))
    [ "$content_width" -lt 1 ] && content_width=1

    printf "${W1} "
    print_padded_text "$text" "$content_width"
    printf " ${NC}\n"
}

get_display_width() {
    local text="$1"
    local width

    if [ -z "$text" ]; then
        printf '0\n'
        return 0
    fi

    if [[ ${DISPLAY_WIDTH_CACHE["$text"]+_} ]]; then
        printf '%s\n' "${DISPLAY_WIDTH_CACHE["$text"]}"
        return 0
    fi

    if printf '%s' "$text" | LC_ALL=C grep -qx '[ -~]*'; then
        width=${#text}
        DISPLAY_WIDTH_CACHE["$text"]=$width
        printf '%s\n' "$width"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        width=$(python3 - "$text" <<'PY' 2>/dev/null
import sys, unicodedata
text = sys.argv[1]
width = 0
for ch in text:
    width += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
print(width)
PY
)
        width=${width:-0}
        DISPLAY_WIDTH_CACHE["$text"]=$width
        printf '%s\n' "$width"
        return 0
    fi

    width=$(printf '%s' "$text" | awk '{print length($0)}')
    DISPLAY_WIDTH_CACHE["$text"]=$width
    printf '%s\n' "$width"
}

print_centered_text() {
    local text="$1"
    local total_width
    local text_width pad
    total_width=$(get_ui_width)
    text_width=$(get_display_width "$text")
    [ -n "$text_width" ] || text_width=0
    pad=$(( (total_width - text_width) / 2 ))
    [ "$pad" -lt 0 ] && pad=0
    printf '%*s%s\n' "$pad" '' "$text"
}

print_padded_text() {
    local text="$1"
    local target_width="$2"
    local text_width pad
    text_width=$(get_display_width "$text")
    [ -n "$text_width" ] || text_width=0
    pad=$(( target_width - text_width ))
    [ "$pad" -lt 0 ] && pad=0
    printf '%s%*s' "$text" "$pad" ''
}

menu_header() {
    local title="$1"
    local accent_char="-"

    if is_utf8_locale; then
        accent_char="═"
    fi

    draw_line_color "$MAGENTA" "$accent_char"
    printf "${W1}"
    print_centered_text "$title"
    printf "${NC}"
    draw_line_color "$MAGENTA" "$accent_char"
}

draw_centered_title() {
    local title="$1"
    local total_width
    local title_width dash_total left_dash right_dash left_str right_str line_char
    total_width=$(get_ui_width)
    title_width=$(get_display_width "$title")
    [ -n "$title_width" ] || title_width=0
    dash_total=$(( total_width - title_width - 2 ))
    if [ "$dash_total" -lt 2 ]; then
        printf '%s\n' "$title"
        return 0
    fi
    left_dash=$(( dash_total / 2 ))
    right_dash=$(( dash_total - left_dash ))
    line_char="-"
    if is_utf8_locale; then
        line_char="─"
    fi
    left_str=$(repeat_char "$line_char" "$left_dash")
    right_str=$(repeat_char "$line_char" "$right_dash")
    printf "${CYAN}%s${NC} ${W1}%s${NC} ${CYAN}%s${NC}\n" "$left_str" "$title" "$right_str"
}

menu_section() {
    local title="$1"
    printf "\n"
    draw_centered_title "$title"
}

menu_pair() {
    local left="$1"
    local right="${2:-}"
    local ui_width content_width gap_width left_width right_width left_col_width right_col_width

    if [ -z "$right" ]; then
        print_menu_line "$left"
        return 0
    fi

    ui_width=$(get_ui_width)
    content_width=$((ui_width - 2))
    [ "$content_width" -lt 1 ] && content_width=1
    gap_width=$UI_MENU_GAP
    left_col_width=$(( (content_width - gap_width) / 2 ))
    right_col_width=$(( content_width - gap_width - left_col_width ))

    left_width=$(get_display_width "$left")
    right_width=$(get_display_width "$right")

    if [ "$ui_width" -lt "$UI_MENU_SPLIT_THRESHOLD" ] || \
       [ "$left_width" -gt "$left_col_width" ] || \
       [ "$right_width" -gt "$right_col_width" ]; then
        print_menu_line "$left"
        print_menu_line "$right"
        return 0
    fi

    printf "${W1} "
    print_padded_text "$left" "$left_col_width"
    printf '%*s' "$gap_width" ''
    print_padded_text "$right" "$right_col_width"
    printf " ${NC}\n"
}

status_pair() {
    local label="$1"
    local value="$2"
    local label_width="$UI_STATUS_LABEL_WIDTH"
    local ui_width

    ui_width=$(get_ui_width)
    if [ "$ui_width" -lt 72 ]; then
        label_width=12
    fi

    printf "${CYAN}"
    print_padded_text "$label" "$label_width"
    printf "${DIM} : ${NC}${W1}%s${NC}\n" "$value"
}

# 等待用户输入
pause() {
    printf "\n"
    msg_warn ">>> 处理完成。按任意键返回..."
    read -n 1 -s -r
}

menu_footer_back() {
    draw_line
    menu_pair "[0] 返回上级菜单"
    draw_line
}

read_menu_choice() {
    local -n __resultref="$1"
    local prompt="${2:-请输入选择:}"
    local __choice_value

    msg_prompt "$prompt"
    IFS= read -r __choice_value
    __resultref="$__choice_value"
}

handle_standard_menu_control() {
    local choice="$1"

    case "$choice" in
        [XxQq])
            if confirm "退出整个脚本?"; then
                EXIT_ALL=1
                return "$MENU_RESULT_EXIT_ALL"
            fi
            return "$MENU_RESULT_RETRY"
            ;;
        0)
            return "$MENU_RESULT_BACK"
            ;;
        *)
            return "$MENU_RESULT_CONTINUE"
            ;;
    esac
}

menu_read_standard_choice() {
    local -n __resultref="$1"
    local prompt="${2:-请输入选择:}"
    local menu_choice_value

    read_menu_choice menu_choice_value "$prompt"
    __resultref="$menu_choice_value"
    handle_standard_menu_control "$menu_choice_value"
}

menu_read_submenu_action() {
    local -n __choiceref="$1"
    local -n __actionref="$2"
    local prompt="${3:-请输入选择:}"
    local menu_choice_buffer
    local menu_status="$MENU_RESULT_CONTINUE"
    local submenu_action_value="continue"

    menu_read_standard_choice menu_choice_buffer "$prompt" || menu_status=$?

    case "$menu_status" in
        "$MENU_RESULT_CONTINUE") submenu_action_value="continue" ;;
        "$MENU_RESULT_EXIT_ALL") submenu_action_value="return" ;;
        "$MENU_RESULT_RETRY") submenu_action_value="retry" ;;
        "$MENU_RESULT_BACK") submenu_action_value="back" ;;
    esac

    __choiceref="$menu_choice_buffer"
    __actionref="$submenu_action_value"
}

run_confirmed_action() {
    local prompt="$1"
    shift

    confirm "$prompt" || return 0
    "$@"
}

create_sshl_certs_dir() {
    local cert_owner_user="${SSHL_CERTS_OWNER%%:*}"
    local input_owner default_owner

    if [ -z "$cert_owner_user" ]; then
        msg_err "证书目录属主未设置。"
        return 1
    fi

    if ! id "$cert_owner_user" >/dev/null 2>&1; then
        msg_warn "用户 ${cert_owner_user} 不存在，无法设置 ${SSHL_CERTS_OWNER}。"

        default_owner="${SUDO_USER:-root}"
        if ! id "$default_owner" >/dev/null 2>&1; then
            default_owner="root"
        fi

        while true; do
            prompt_valid_username "请输入证书目录属主用户名" "$default_owner" input_owner || return 1
            if id "$input_owner" >/dev/null 2>&1; then
                cert_owner_user="$input_owner"
                SSHL_CERTS_OWNER="${input_owner}:${input_owner}"
                break
            fi
            msg_warn "用户 ${input_owner} 不存在，请输入已存在用户。"
        done
    fi

    mkdir -p "$SSHL_CERTS_DIR" || {
        msg_err "创建目录失败: ${SSHL_CERTS_DIR}"
        return 1
    }

    chown -R "$SSHL_CERTS_OWNER" "$SSHL_CERTS_DIR" || {
        msg_err "设置目录属主失败: ${SSHL_CERTS_OWNER}"
        return 1
    }

    chmod 755 "$SSHL_CERTS_DIR" || {
        msg_err "设置目录权限失败: ${SSHL_CERTS_DIR}"
        return 1
    }

    msg_ok "sshl 证书目录已创建: ${SSHL_CERTS_DIR}"
    msg_info "属主: ${SSHL_CERTS_OWNER} | 权限: 755"
}

prepare_main_sshd_config_for_managed_mode() {
    if [ ! -f /etc/ssh/sshd_config ]; then
        msg_err "未找到 SSH 配置文件: /etc/ssh/sshd_config"
        return 1
    fi

    sed -i '/^# BEGIN_MANAGED_BLOCK_INIT_SSH$/,/^# END_MANAGED_BLOCK_INIT_SSH$/d' /etc/ssh/sshd_config
    sed -ri \
        -e '/^[[:space:]]*#/! s/^[[:space:]]*(Port[[:space:]]+.*)$/# \1/I' \
        -e '/^[[:space:]]*#/! s/^[[:space:]]*(PasswordAuthentication[[:space:]]+.*)$/# \1/I' \
        -e '/^[[:space:]]*#/! s/^[[:space:]]*(KbdInteractiveAuthentication[[:space:]]+.*)$/# \1/I' \
        -e '/^[[:space:]]*#/! s/^[[:space:]]*(ChallengeResponseAuthentication[[:space:]]+.*)$/# \1/I' \
        -e '/^[[:space:]]*#/! s/^[[:space:]]*(PubkeyAuthentication[[:space:]]+.*)$/# \1/I' \
        -e '/^[[:space:]]*#/! s/^[[:space:]]*(AuthenticationMethods[[:space:]]+.*)$/# \1/I' \
        -e '/^[[:space:]]*#/! s/^[[:space:]]*(PermitEmptyPasswords[[:space:]]+.*)$/# \1/I' \
        -e '/^[[:space:]]*#/! s/^[[:space:]]*(PermitRootLogin[[:space:]]+.*)$/# \1/I' \
        -e '/^[[:space:]]*#/! s/^[[:space:]]*(AllowUsers[[:space:]]+.*)$/# \1/I' \
        /etc/ssh/sshd_config

    delete_sshd_directive "Port"
    delete_sshd_directive "PasswordAuthentication"
    delete_sshd_directive "KbdInteractiveAuthentication"
    delete_sshd_directive "ChallengeResponseAuthentication"
    delete_sshd_directive "PubkeyAuthentication"
    delete_sshd_directive "AuthenticationMethods"
    delete_sshd_directive "PermitEmptyPasswords"
    delete_sshd_directive "PermitRootLogin"
    delete_sshd_directive "AllowUsers"
}

auto_deploy_create_user_and_passwords() {
    if id "$AUTO_DEPLOY_USER" >/dev/null 2>&1; then
        msg_warn "用户 ${AUTO_DEPLOY_USER} 已存在，将重置密码并补全管理员权限。"
    else
        msg_info "创建用户 ${AUTO_DEPLOY_USER} ..."
        useradd -m -s /bin/bash "$AUTO_DEPLOY_USER" || return 1
    fi

    ensure_user_in_admin_group "$AUTO_DEPLOY_USER" || true

    msg_info "设置用户 ${AUTO_DEPLOY_USER} 密码..."
    echo "${AUTO_DEPLOY_USER}:${AUTO_DEPLOY_USER_PASS}" | chpasswd || return 1

    msg_info "修改 root 密码..."
    echo "root:${AUTO_DEPLOY_ROOT_PASS}" | chpasswd || return 1
}

show_auto_deploy_iptables_rules() {
    printf "\n"
    msg_info "当前 iptables INPUT 规则如下："
    iptables -S INPUT 2>/dev/null || true
    if iptables_chain_exists iptables "$IPTABLES_MANAGED_CHAIN"; then
        msg_info "当前托管链 ${IPTABLES_MANAGED_CHAIN} 规则如下："
        iptables -S "$IPTABLES_MANAGED_CHAIN" 2>/dev/null || true
    fi
    if command -v ip6tables >/dev/null 2>&1 && iptables_chain_exists ip6tables "$IP6TABLES_MANAGED_CHAIN"; then
        msg_info "当前托管链 ${IP6TABLES_MANAGED_CHAIN} 规则如下："
        ip6tables -S "$IP6TABLES_MANAGED_CHAIN" 2>/dev/null || true
    fi
    printf "\n"
}

# ==============================================================================
