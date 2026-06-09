ensure_suite_state_dir() {
    mkdir -p "$SUITE_STATE_DIR" 2>/dev/null || true
}

set_firewall_backend_state() {
    local backend="$1"
    case "$backend" in
        iptables|nft|firewalld) ;;
        *) return 1 ;;
    esac
    ensure_suite_state_dir
    printf '%s\n' "$backend" > "$FIREWALL_BACKEND_STATE_FILE"
}

get_firewall_backend_state() {
    local backend
    [ -r "$FIREWALL_BACKEND_STATE_FILE" ] || return 1
    backend=$(tr -d '[:space:]' < "$FIREWALL_BACKEND_STATE_FILE")
    case "$backend" in
        iptables|nft|firewalld)
            printf '%s\n' "$backend"
            return 0
            ;;
    esac
    return 1
}

has_systemd_service() {
    local unit="$1"
    command -v systemctl >/dev/null 2>&1 || return 1

    if [[ ${SYSTEMD_SERVICE_EXISTS_CACHE["$unit"]+_} ]]; then
        [ "${SYSTEMD_SERVICE_EXISTS_CACHE["$unit"]}" = "1" ]
        return $?
    fi

    case "$unit" in
        *.service)
            [ -e "/etc/systemd/system/$unit" ] && { SYSTEMD_SERVICE_EXISTS_CACHE["$unit"]=1; return 0; }
            [ -e "/run/systemd/system/$unit" ] && { SYSTEMD_SERVICE_EXISTS_CACHE["$unit"]=1; return 0; }
            [ -e "/usr/lib/systemd/system/$unit" ] && { SYSTEMD_SERVICE_EXISTS_CACHE["$unit"]=1; return 0; }
            [ -e "/lib/systemd/system/$unit" ] && { SYSTEMD_SERVICE_EXISTS_CACHE["$unit"]=1; return 0; }
            ;;
    esac

    if systemctl list-unit-files --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit"; then
        SYSTEMD_SERVICE_EXISTS_CACHE["$unit"]=1
        return 0
    fi

    SYSTEMD_SERVICE_EXISTS_CACHE["$unit"]=0
    return 1
}

is_systemd_service_active() {
    local unit="$1"
    has_systemd_service "$unit" || return 1
    systemctl is-active --quiet "$unit" 2>/dev/null
}

is_systemd_service_enabled() {
    local unit="$1"
    has_systemd_service "$unit" || return 1
    systemctl is-enabled --quiet "$unit" 2>/dev/null
}

require_native_firewall_backend() {
    local backend="${1:-$(detect_firewall_backend)}"
    if [ "$backend" = "firewalld" ]; then
        msg_err "当前由 firewalld 接管防火墙，不能直接在此菜单里混用 iptables/nft 规则。"
        msg_info "请先使用 [1] 启用Iptables 或 [3] 启用Nftables，脚本会自动停用 firewalld。"
        return 1
    fi
    return 0
}

validate_protocol() {
    case "$1" in
        tcp|udp|all) return 0 ;;
        *) return 1 ;;
    esac
}

validate_port_or_range() {
    local spec="$1"
    local start end

    validate_port "$spec" && return 0
    if [[ "$spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        start="${BASH_REMATCH[1]}"
        end="${BASH_REMATCH[2]}"
        validate_port "$start" || return 1
        validate_port "$end" || return 1
        [ "$start" -le "$end" ]
        return
    fi
    return 1
}

port_spec_to_iptables_dport() {
    local spec="$1"
    printf '%s\n' "${spec/-/:}"
}

port_spec_contains_port() {
    local spec="$1"
    local port="$2"
    local start end

    validate_port "$port" || return 1
    if validate_port "$spec"; then
        [ "$spec" = "$port" ]
        return
    fi
    if [[ "$spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        start="${BASH_REMATCH[1]}"
        end="${BASH_REMATCH[2]}"
        validate_port "$start" || return 1
        validate_port "$end" || return 1
        [ "$port" -ge "$start" ] && [ "$port" -le "$end" ]
        return
    fi
    return 1
}

normalize_port_spec() {
    local raw="${1:-}"
    local proto port

    [ -n "$raw" ] || return 1
    case "$raw" in
        tcp:*|udp:*)
            proto="${raw%%:*}"
            port="${raw#*:}"
            ;;
        *)
            proto="tcp"
            port="$raw"
            ;;
    esac

    port="${port/:/-}"
    validate_protocol "$proto" || return 1
    [ "$proto" = "all" ] && return 1
    validate_port_or_range "$port" || return 1
    printf '%s:%s\n' "$proto" "$port"
}

merge_unique_port_specs() {
    local item normalized
    declare -A seen=()

    for item in "$@"; do
        normalized=$(normalize_port_spec "$item") || continue
        if [ -z "${seen[$normalized]+x}" ]; then
            seen[$normalized]=1
            printf '%s\n' "$normalized"
        fi
    done
}

emit_simple_port_specs_from_token() {
    local token="$1"
    local default_proto="${2:-}"
    local ports_part proto part

    [ -n "$token" ] || return 0

    if [[ "$token" =~ ^([^/]+)/(tcp|udp)$ ]]; then
        ports_part="${BASH_REMATCH[1]}"
        proto="${BASH_REMATCH[2]}"
        IFS=',' read -r -a __port_parts <<< "$ports_part"
        for part in "${__port_parts[@]}"; do
            part="${part/:/-}"
            validate_port_or_range "$part" || continue
            printf '%s:%s\n' "$proto" "$part"
        done
        return 0
    fi

    if [[ "$token" =~ ^([0-9]+([:-][0-9]+)?)$ ]]; then
        part="${BASH_REMATCH[1]}"
        part="${part/:/-}"
        validate_port_or_range "$part" || return 0
        case "$default_proto" in
            all)
                printf 'tcp:%s\n' "$part"
                printf 'udp:%s\n' "$part"
                ;;
            tcp|udp)
                printf '%s:%s\n' "$default_proto" "$part"
                ;;
        esac
    fi
}

collect_simple_open_port_specs_from_iptables_cmd() {
    local cmd="${1:-iptables}"
    local chain rule proto port

    command -v "$cmd" >/dev/null 2>&1 || return 0
    chain=$(get_effective_filter_chain "$cmd")

    while IFS= read -r rule; do
        [[ "$rule" == *" -j ACCEPT"* ]] || continue
        proto=""
        port=""
        [[ "$rule" =~ [[:space:]]-p[[:space:]](tcp|udp)([[:space:]]|$) ]] && proto="${BASH_REMATCH[1]}"
        [ -n "$proto" ] || continue
        [[ "$rule" =~ [[:space:]]--dport[[:space:]]([0-9]+(:[0-9]+)?)([[:space:]]|$) ]] || continue
        port="${BASH_REMATCH[1]}"
        port="${port/:/-}"
        printf '%s:%s\n' "$proto" "$port"
    done < <("$cmd" -S "$chain" 2>/dev/null || true)
}

collect_simple_open_port_specs_from_nft() {
    local rule proto port

    command -v nft >/dev/null 2>&1 || return 0
    nft list chain inet filter input >/dev/null 2>&1 || return 0

    while IFS= read -r rule; do
        [[ "$rule" == *" accept"* ]] || continue
        [[ "$rule" =~ (^|[[:space:]])(tcp|udp)[[:space:]]+dport[[:space:]]+([0-9]+(-[0-9]+)?)([[:space:]]|$) ]] || continue
        proto="${BASH_REMATCH[2]}"
        port="${BASH_REMATCH[3]}"
        printf '%s:%s\n' "$proto" "$port"
    done < <(nft list chain inet filter input 2>/dev/null || true)
}

collect_simple_open_port_specs_from_firewalld() {
    local zones=()
    local zone token service ports_line

    command -v firewall-cmd >/dev/null 2>&1 || return 0
    firewall-cmd --state >/dev/null 2>&1 || return 0

    while IFS= read -r zone; do
        [[ "$zone" =~ ^[[:alnum:]_-]+$ ]] || continue
        zones+=("$zone")
    done < <(firewall-cmd --get-active-zones 2>/dev/null || true)

    if [ "${#zones[@]}" -eq 0 ]; then
        zone=$(firewall-cmd --get-default-zone 2>/dev/null || true)
        [[ "$zone" =~ ^[[:alnum:]_-]+$ ]] && zones=("$zone")
    fi

    for zone in "${zones[@]}"; do
        for token in $(firewall-cmd --zone="$zone" --list-ports 2>/dev/null); do
            emit_simple_port_specs_from_token "$token"
        done

        for service in $(firewall-cmd --zone="$zone" --list-services 2>/dev/null); do
            ports_line=$(firewall-cmd --info-service="$service" 2>/dev/null | awk -F': ' '/^[[:space:]]*ports:[[:space:]]*/ {print $2; exit}')
            [ -n "$ports_line" ] || continue
            for token in $ports_line; do
                emit_simple_port_specs_from_token "$token"
            done
        done
    done
}

collect_simple_open_port_specs_from_ufw() {
    local line token

    command -v ufw >/dev/null 2>&1 || return 0
    LC_ALL=C ufw status 2>/dev/null | while IFS= read -r line; do
        [[ "$line" == *" ALLOW "* || "$line" == *" LIMIT "* ]] || continue
        [[ "$line" == *" ALLOW OUT "* || "$line" == *" LIMIT OUT "* ]] && continue
        token=$(printf '%s\n' "$line" | awk '{print $1}')
        token="${token%%(v6)}"
        token="${token// /}"
        [ -n "$token" ] || continue
        emit_simple_port_specs_from_token "$token" all
    done
}

collect_preserved_open_port_specs() {
    local combined=()
    local spec

    while IFS= read -r spec; do
        [ -n "$spec" ] && combined+=("$spec")
    done < <(collect_simple_open_port_specs_from_firewalld)

    while IFS= read -r spec; do
        [ -n "$spec" ] && combined+=("$spec")
    done < <(collect_simple_open_port_specs_from_ufw)

    while IFS= read -r spec; do
        [ -n "$spec" ] && combined+=("$spec")
    done < <(collect_simple_open_port_specs_from_nft)

    while IFS= read -r spec; do
        [ -n "$spec" ] && combined+=("$spec")
    done < <(collect_simple_open_port_specs_from_iptables_cmd iptables)

    while IFS= read -r spec; do
        [ -n "$spec" ] && combined+=("$spec")
    done < <(collect_simple_open_port_specs_from_iptables_cmd ip6tables)

    merge_unique_port_specs "${combined[@]}"
}

validate_ip_or_cidr() {
    local value="$1"
    [ -n "$value" ] || return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$value" <<'PY' >/dev/null 2>&1
import ipaddress, sys
value = sys.argv[1]
try:
    if "/" in value:
        ipaddress.ip_network(value, strict=False)
    else:
        ipaddress.ip_address(value)
except Exception:
    raise SystemExit(1)
PY
        return $?
    fi

    local addr mask o1 o2 o3 o4
    addr="$value"
    if [[ "$value" == */* ]]; then
        addr="${value%/*}"
        mask="${value#*/}"
        [[ "$mask" =~ ^[0-9]+$ ]] && [ "$mask" -ge 0 ] && [ "$mask" -le 32 ] || return 1
    fi
    IFS='.' read -r o1 o2 o3 o4 <<< "$addr"
    for oct in "$o1" "$o2" "$o3" "$o4"; do
        [[ "$oct" =~ ^[0-9]+$ ]] || return 1
        [ "$oct" -ge 0 ] && [ "$oct" -le 255 ] || return 1
    done
}

get_ip_family() {
    local value="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$value" <<'PY' 2>/dev/null
import ipaddress, sys
value = sys.argv[1]
obj = ipaddress.ip_network(value, strict=False) if "/" in value else ipaddress.ip_address(value)
print("ipv6" if obj.version == 6 else "ipv4")
PY
        return $?
    fi
    case "$value" in
        *:*) echo "ipv6" ;;
        *) echo "ipv4" ;;
    esac
}

get_managed_chain_name() {
    if [ "${1:-iptables}" = "ip6tables" ]; then
        echo "$IP6TABLES_MANAGED_CHAIN"
    else
        echo "$IPTABLES_MANAGED_CHAIN"
    fi
}

iptables_chain_exists() {
    local cmd="${1:-iptables}"
    local chain="$2"
    command -v "$cmd" >/dev/null 2>&1 || return 1
    "$cmd" -S "$chain" >/dev/null 2>&1
}

ensure_managed_filter_chain() {
    local cmd="${1:-iptables}"
    local chain
    chain=$(get_managed_chain_name "$cmd")
    command -v "$cmd" >/dev/null 2>&1 || return 1
    "$cmd" -N "$chain" >/dev/null 2>&1 || true
    while "$cmd" -D INPUT -j "$chain" >/dev/null 2>&1; do :; done
    "$cmd" -I INPUT 1 -j "$chain" >/dev/null 2>&1 || return 1
}

get_effective_filter_chain() {
    local cmd="${1:-iptables}"
    local chain
    chain=$(get_managed_chain_name "$cmd")
    if iptables_chain_exists "$cmd" "$chain"; then
        echo "$chain"
    else
        echo "INPUT"
    fi
}

reset_managed_filter_chain_rules() {
    local cmd="${1:-iptables}"
    local sshport="$2"
    shift 2
    local chain proto_opt type_opt p normalized proto port

    ensure_managed_filter_chain "$cmd" || return 1
    chain=$(get_managed_chain_name "$cmd")
    "$cmd" -F "$chain" || return 1

    "$cmd" -A "$chain" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || return 1
    "$cmd" -A "$chain" -i lo -j ACCEPT || return 1

    if [ "$cmd" = "ip6tables" ]; then
        "$cmd" -A "$chain" -p ipv6-icmp -j ACCEPT || return 1
    else
        proto_opt="icmp"
        type_opt="--icmp-type echo-request"
        "$cmd" -A "$chain" -p "$proto_opt" $type_opt -j ACCEPT || return 1
    fi
    "$cmd" -A "$chain" -p tcp -m tcp --dport "$sshport" -j ACCEPT || return 1

    for p in "$@"; do
        normalized=$(normalize_port_spec "$p") || continue
        proto="${normalized%%:*}"
        port="${normalized#*:}"
        [ "$proto" = "tcp" ] && [ "$port" = "$sshport" ] && continue
        "$cmd" -A "$chain" -p "$proto" -m "$proto" --dport "$(port_spec_to_iptables_dport "$port")" -j ACCEPT || return 1
    done

    "$cmd" -A "$chain" -j DROP || return 1
}

get_pkg_manager() {
    if [ -n "$PKG_MANAGER_CACHE" ]; then
        printf '%s\n' "$PKG_MANAGER_CACHE"
        return 0
    fi

    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER_CACHE="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER_CACHE="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER_CACHE="yum"
    else
        PKG_MANAGER_CACHE=""
    fi

    printf '%s\n' "$PKG_MANAGER_CACHE"
}

pkg_update() {
    local pkg_mgr
    pkg_mgr=$(get_pkg_manager)
    case "$pkg_mgr" in
        apt) apt-get update ;;
        dnf) dnf makecache -y ;;
        yum) yum makecache -y ;;
        *) return 1 ;;
    esac
}

pkg_install() {
    local pkg_mgr rc
    pkg_mgr=$(get_pkg_manager)
    case "$pkg_mgr" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ; rc=$? ;;
        dnf) dnf install -y "$@" ; rc=$? ;;
        yum) yum install -y "$@" ; rc=$? ;;
        *) return 1 ;;
    esac

    [ "$rc" -eq 0 ] && invalidate_runtime_caches
    return "$rc"
}

filter_installed_packages() {
    local pkg_mgr pkg
    local installed=()

    pkg_mgr=$(get_pkg_manager)
    case "$pkg_mgr" in
        apt)
            for pkg in "$@"; do
                dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' && installed+=("$pkg")
            done
            ;;
        dnf|yum)
            for pkg in "$@"; do
                rpm -q "$pkg" >/dev/null 2>&1 && installed+=("$pkg")
            done
            ;;
        *)
            return 1
            ;;
    esac

    printf '%s\n' "${installed[@]}"
}

pkg_remove() {
    local pkg_mgr rc
    pkg_mgr=$(get_pkg_manager)

    [ "$#" -gt 0 ] || return 0

    case "$pkg_mgr" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get purge -y "$@" ; rc=$? ;;
        dnf) dnf remove -y "$@" ; rc=$? ;;
        yum) yum remove -y "$@" ; rc=$? ;;
        *) return 1 ;;
    esac

    [ "$rc" -eq 0 ] && invalidate_runtime_caches
    return "$rc"
}

pkg_cleanup() {
    local pkg_mgr
    pkg_mgr=$(get_pkg_manager)
    case "$pkg_mgr" in
        apt) apt-get autoremove --purge -y ;;
        dnf) dnf autoremove -y ;;
        yum) yum autoremove -y ;;
        *) return 1 ;;
    esac
}

get_common_ops_tools_summary() {
    printf '%s\n' "vim curl wget unzip sudo tar ca-certificates jq rsync lsof btop/htop lrzsz iftop"
}

install_optional_package_group() {
    local pkg installed_pkg

    for pkg in "$@"; do
        installed_pkg=$(filter_installed_packages "$pkg" 2>/dev/null | head -n 1)
        if [ "$installed_pkg" = "$pkg" ]; then
            printf '%s\n' "$pkg"
            return 0
        fi
    done

    for pkg in "$@"; do
        if pkg_install "$pkg" >/dev/null 2>&1; then
            printf '%s\n' "$pkg"
            return 0
        fi
    done

    return 1
}

install_common_ops_tools() {
    local required_pkgs=(vim curl wget unzip sudo tar ca-certificates jq rsync lsof)
    local required_installed=()
    local optional_installed=()
    local optional_missing=()
    local pkg installed_pkg selected_pkg

    msg_info "准备安装常用工具集..."
    pkg_update || true

    for pkg in "${required_pkgs[@]}"; do
        installed_pkg=$(filter_installed_packages "$pkg" 2>/dev/null | head -n 1)
        if [ "$installed_pkg" = "$pkg" ]; then
            required_installed+=("$pkg")
            continue
        fi

        if pkg_install "$pkg" >/dev/null 2>&1; then
            required_installed+=("$pkg")
        else
            msg_err "安装必需工具失败: ${pkg}"
            return 1
        fi
    done

    selected_pkg=$(install_optional_package_group btop htop) || true
    if [ -n "$selected_pkg" ]; then
        optional_installed+=("$selected_pkg")
    else
        optional_missing+=("btop/htop")
    fi

    selected_pkg=$(install_optional_package_group lrzsz) || true
    if [ -n "$selected_pkg" ]; then
        optional_installed+=("$selected_pkg")
    else
        optional_missing+=("lrzsz")
    fi

    selected_pkg=$(install_optional_package_group iftop) || true
    if [ -n "$selected_pkg" ]; then
        optional_installed+=("$selected_pkg")
    else
        optional_missing+=("iftop")
    fi

    msg_ok "常用工具安装完成。"
    status_pair "基础工具" "$(printf '%s ' "${required_installed[@]}" | sed 's/[[:space:]]*$//')"
    if [ "${#optional_installed[@]}" -gt 0 ]; then
        status_pair "可选工具" "$(printf '%s ' "${optional_installed[@]}" | sed 's/[[:space:]]*$//')"
    fi
    if [ "${#optional_missing[@]}" -gt 0 ]; then
        status_pair "未装可选" "$(printf '%s ' "${optional_missing[@]}" | sed 's/[[:space:]]*$//')"
    fi

    return 0
}

ensure_basic_tool_installed() {
    local tool_name="$1"
    shift
    command -v "$tool_name" >/dev/null 2>&1 && return 0
    pkg_update || true
    pkg_install "$@" || return 1
    command -v "$tool_name" >/dev/null 2>&1
}

download_remote_script() {
    local url="$1"
    local tmp_pattern="$2"
    local label="${3:-远程脚本}"
    local script_path

    ensure_basic_tool_installed curl curl || {
        msg_err "curl安装失败，无法下载${label}。"
        return 1
    }

    script_path=$(mktemp "$tmp_pattern") || {
        msg_err "创建${label}临时文件失败。"
        return 1
    }

    if ! curl -fsSL --connect-timeout 5 --max-time 300 -o "$script_path" "$url"; then
        rm -f "$script_path"
        msg_err "下载${label}失败: ${url}"
        return 1
    fi

    chmod +x "$script_path" 2>/dev/null || true
    printf '%s\n' "$script_path"
}

run_remote_script() {
    local url="$1"
    local tmp_pattern="$2"
    local label="${3:-远程脚本}"
    local script_path rc
    shift 3

    script_path=$(download_remote_script "$url" "$tmp_pattern" "$label") || return 1
    bash "$script_path" "$@"
    rc=$?
    rm -f "$script_path"
    return "$rc"
}

get_required_password() {
    local prompt_label="$1"
    local password

    while true; do
        printf '\n'
        prompt_password_twice "$prompt_label" password || return 1
        [ -n "$password" ] && {
            printf '%s\n' "$password"
            return 0
        }
        msg_warn "密码不能为空，请重新输入。"
    done
}

prompt_valid_username() {
    local prompt_text="$1"
    local default_value="$2"
    local __resultvar="$3"
    local input_value

    while true; do
        read -p "${prompt_text} [默认: ${default_value}]: " input_value
        input_value=${input_value:-$default_value}
        if [[ "$input_value" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]]; then
            printf -v "$__resultvar" '%s' "$input_value"
            return 0
        fi
        msg_warn "用户名格式无效，请重新输入。"
    done
}

prompt_valid_port() {
    local prompt_text="$1"
    local default_value="$2"
    local __resultvar="$3"
    local input_value

    while true; do
        read -p "${prompt_text} [默认: ${default_value}]: " input_value
        input_value=${input_value:-$default_value}
        if validate_port "$input_value"; then
            printf -v "$__resultvar" '%s' "$input_value"
            return 0
        fi
        msg_warn "端口必须是 1-65535 的数字。"
    done
}

prompt_valid_ssh_port() {
    local prompt_text="$1"
    local default_value="$2"
    local __resultvar="$3"
    prompt_valid_port "$prompt_text" "$default_value" "$__resultvar"
}

prompt_valid_web_path_token() {
    local prompt_text="$1"
    local default_value="$2"
    local __resultvar="$3"
    local input_value normalized_value

    while true; do
        read -p "${prompt_text} [默认: ${default_value}]: " input_value
        input_value=${input_value:-$default_value}
        normalized_value=$(normalize_web_base_path "$input_value")
        if validate_web_base_path "$normalized_value"; then
            printf -v "$__resultvar" '%s' "$normalized_value"
            return 0
        fi
        msg_warn "路径标识至少 4 位，且仅允许字母、数字、点、下划线、短横线、波浪线。"
    done
}

collect_auto_deploy_inputs() {
    local input_user input_ssh_port input_user_pass input_root_pass

    printf "\n"
    draw_line
    msg_info "[全自动] 部署参数输入"

    prompt_valid_username "请输入管理用户名" "$DEFAULT_AUTO_INIT_USER" input_user || return 1
    prompt_valid_ssh_port "请输入 SSH 端口" "$DEFAULT_SSH_PORT" input_ssh_port || return 1
    prompt_password_twice "用户 ${input_user}" input_user_pass || return 1
    prompt_password_twice "root" input_root_pass || return 1

    AUTO_DEPLOY_USER="$input_user"
    AUTO_DEPLOY_SSH_PORT="$input_ssh_port"
    AUTO_DEPLOY_USER_PASS="$input_user_pass"
    AUTO_DEPLOY_ROOT_PASS="$input_root_pass"
    SSHL_CERTS_OWNER="${AUTO_DEPLOY_USER}:${AUTO_DEPLOY_USER}"
}
