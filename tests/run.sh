#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/14_system_base.sh"
source "$ROOT_DIR/lib/15_ssh_hardening.sh"
source "$ROOT_DIR/lib/03_network_report.sh"
source "$ROOT_DIR/lib/08_nginx.sh"
source "$ROOT_DIR/lib/16_perf_tuning.sh"
source "$ROOT_DIR/lib/18_fail2ban.sh"

for shell_file in "$ROOT_DIR"/*.sh "$ROOT_DIR"/lib/*.sh; do
    bash -n "$shell_file"
done

passed=0
failed=0

assert_status() {
    local expected="$1" label="$2"
    shift 2
    local actual=0
    "$@" >/dev/null 2>&1 || actual=$?
    if [ "$actual" -eq "$expected" ]; then
        printf 'PASS %s\n' "$label"
        passed=$((passed + 1))
    else
        printf 'FAIL %s (期望退出码 %s，实际 %s)\n' "$label" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}

assert_output() {
    local expected="$1" label="$2" actual
    shift 2
    actual=$("$@") || {
        printf 'FAIL %s (命令执行失败)\n' "$label" >&2
        failed=$((failed + 1))
        return
    }
    if [ "$actual" = "$expected" ]; then
        printf 'PASS %s\n' "$label"
        passed=$((passed + 1))
    else
        printf 'FAIL %s (期望 [%s]，实际 [%s])\n' "$label" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}

get_fail2ban_test_matches() {
    fail2ban-regex --out ip "$1" "$2" 2>/dev/null
}

SUITE_BACKUP_DIR="/tmp/vps-suite-test-backups"

# Protocol and port validation.
assert_status 0 '协议 tcp 合法' validate_protocol tcp
assert_status 0 '协议 all 合法' validate_protocol all
assert_status 1 '协议 icmp 不合法' validate_protocol icmp
assert_status 0 '端口 1 合法' validate_port 1
assert_status 0 '端口 65535 合法' validate_port 65535
assert_status 1 '端口 0 不合法' validate_port 0
assert_status 1 '端口超出范围' validate_port 65536
assert_status 0 '端口区间合法' validate_port_or_range 80-443
assert_status 1 '端口区间逆序不合法' validate_port_or_range 443-80
assert_output 'udp:53-55' '端口规则标准化' normalize_port_spec udp:53-55
assert_status 1 '端口规则拒绝非法协议' normalize_port_spec icmp:80
assert_output '80:90' 'iptables 端口区间转换' port_spec_to_iptables_dport 80-90

# Hostname, domain, web path, and account validation.
assert_status 0 '主机名合法' validate_hostname_value node-1.example.com
assert_status 1 '主机名拒绝连续点号' validate_hostname_value node..example
assert_status 0 '域名合法' validate_domain_name panel.example.com
assert_status 1 '域名拒绝下划线' validate_domain_name bad_name.example
assert_output 'admin/path' 'Web 路径去除首尾斜杠' normalize_web_base_path /admin/path/
assert_status 0 'Web 路径合法' validate_web_base_path admin-panel
assert_status 1 'Web 路径拒绝短路径' validate_web_base_path abc
assert_status 0 '系统用户名合法' is_valid_system_username vps_admin
assert_status 1 '系统用户名拒绝空格' is_valid_system_username 'bad user'

# Backup allowlist and port-list normalization.
assert_status 0 '允许套件备份目录' suite_backup_is_safe_path /tmp/vps-suite-test-backups/item.tar
assert_status 1 '拒绝备份目录外路径' suite_backup_is_safe_path /etc/passwd
assert_output '80 443 8080' '端口列表去重' normalize_port_list '80,443 80,8080'
assert_status 1 '端口列表拒绝非法值' normalize_port_list '80,abc'

# Deterministic tuning values.
assert_output '6' '亚洲区域 100Mbps 缓冲值' tcp_tune_calculate_buffer_mb 100 asia
assert_output '64' '海外区域 1000Mbps 缓冲值' tcp_tune_calculate_buffer_mb 1000 overseas
assert_output '16' '非法带宽使用默认值' tcp_tune_calculate_buffer_mb invalid asia

if command -v fail2ban-regex >/dev/null 2>&1; then
    f2b_test_dir=$(mktemp -d)
    FAIL2BAN_SSH_FILTER_FILE="$f2b_test_dir/filter.d/vps-init-suite-sshd.conf"
    SUITE_BACKUP_DIR="$f2b_test_dir/backups"
    write_fail2ban_sshd_filter >/dev/null
    f2b_test_log="$f2b_test_dir/sshd.log"
    cat > "$f2b_test_log" <<'EOF'
Sep 30 11:28:44 host sshd[123]: Timeout before authentication for connection from 116.228.141.62 to 10.0.0.215, pid = 1234
Sep 30 11:29:00 host sshd[124]: Failed password for invalid user admin from 203.0.113.9 port 22 ssh2
EOF
    assert_output $'116.228.141.62\n203.0.113.9' 'Fail2Ban过滤器识别超时及普通认证失败日志' get_fail2ban_test_matches "$f2b_test_log" "$FAIL2BAN_SSH_FILTER_FILE"
    rm -rf "$f2b_test_dir"
fi

printf '\n测试结果：%s 通过，%s 失败\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
