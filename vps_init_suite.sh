#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 通过 bash <(curl ...) 启动时，stdin 指向脚本内容本身，子进程会立即读到 EOF，
# 导致 sudo 密码提示和菜单输入不可用。stdin 不是终端时切回 /dev/tty。
rebind_stdin() {
    # 仅当 /dev/tty 能真正打开时才切换，避免无控制终端的环境（cron、容器）报错。
    if [ ! -t 0 ] && { true </dev/tty; } 2>/dev/null; then
        exec "$@" < /dev/tty
    fi
    exec "$@"
}

# 非 root 时自动提权；提权后 EUID 为 0，不会重复进入该分支。
if [ "$EUID" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "[ERR] 需要 root 权限，但系统未安装 sudo；请切换到 root 后重试。" >&2
        exit 1
    fi
    echo "[INFO] 当前非 root，正在通过 sudo 提权..." >&2
    rebind_stdin sudo -- bash "${SCRIPT_DIR}/vps_init_suite.sh" "$@"
fi

rebind_stdin bash "${SCRIPT_DIR}/main.sh" "$@"
