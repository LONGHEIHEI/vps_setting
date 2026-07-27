#!/usr/bin/env bash
set -euo pipefail

REPO="LONGHEIHEI/vps_setting"
REF="${VPS_SETTING_REF:-main}"
ARCHIVE_URL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/${REF}"
TMP_DIR="$(mktemp -d /tmp/vps-setting.XXXXXX)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

command -v curl >/dev/null 2>&1 || { echo "curl 未安装" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar 未安装" >&2; exit 1; }

curl -fsSL "$ARCHIVE_URL" | tar -xzf - -C "$TMP_DIR"
RUN_DIR="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[ -n "$RUN_DIR" ] || { echo "项目解压失败" >&2; exit 1; }

chmod +x "$RUN_DIR/vps_init_suite.sh" "$RUN_DIR/main.sh" "$RUN_DIR/bootstrap.sh" 2>/dev/null || true
exec bash "$RUN_DIR/vps_init_suite.sh" "$@"
