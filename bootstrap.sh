#!/usr/bin/env bash
set -euo pipefail

REPO="LONGHEIHEI/vps_setting"
REF="${VPS_SETTING_REF:-main}"
if [[ ! "$REF" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ "$REF" == *..* ]]; then
    echo "VPS_SETTING_REF 格式无效" >&2
    exit 2
fi
if [ -n "${VPS_SETTING_SHA256:-}" ] && [[ ! "$VPS_SETTING_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]]; then
    echo "VPS_SETTING_SHA256 必须是64位十六进制摘要" >&2
    exit 2
fi
ARCHIVE_URL="https://codeload.github.com/${REPO}/tar.gz/${REF}"
TMP_DIR="$(mktemp -d /tmp/vps-setting.XXXXXX)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

command -v curl >/dev/null 2>&1 || { echo "curl 未安装" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar 未安装" >&2; exit 1; }

ARCHIVE_FILE="$TMP_DIR/source.tar.gz"
curl -fsSL --connect-timeout 10 --max-time 300 -o "$ARCHIVE_FILE" "$ARCHIVE_URL"
if [ -n "${VPS_SETTING_SHA256:-}" ]; then
    command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum 未安装，无法校验归档" >&2; exit 1; }
    printf '%s  %s\n' "$VPS_SETTING_SHA256" "$ARCHIVE_FILE" | sha256sum -c -
else
    echo "警告：未设置 VPS_SETTING_SHA256，归档未进行摘要校验。固定版本运行请设置 VPS_SETTING_REF 为提交号或标签，并提供摘要。" >&2
fi
tar -xzf "$ARCHIVE_FILE" -C "$TMP_DIR"
RUN_DIR="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[ -n "$RUN_DIR" ] || { echo "项目解压失败" >&2; exit 1; }
[ -f "$RUN_DIR/main.sh" ] && [ -d "$RUN_DIR/lib" ] || { echo "归档内容不完整" >&2; exit 1; }

chmod +x "$RUN_DIR/vps_init_suite.sh" "$RUN_DIR/main.sh" "$RUN_DIR/bootstrap.sh" 2>/dev/null || true
bash "$RUN_DIR/vps_init_suite.sh" "$@"
exit $?
