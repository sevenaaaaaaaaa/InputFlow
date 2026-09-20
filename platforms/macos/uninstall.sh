#!/usr/bin/env bash
# 卸载输入法；加 --purge 一并删除本地数据（用户词、词典）
set -euo pipefail

APP="InputFlow"
DEST="$HOME/Library/Input Methods/$APP.app"
DATA_DIR="$HOME/Library/Application Support/InputFlow"

killall "$APP" 2>/dev/null || true
rm -rf "$DEST"
defaults delete dev.inputflow.inputmethod 2>/dev/null || true

if [[ "${1:-}" == "--purge" ]]; then
    security delete-generic-password -s dev.inputflow.inputmethod -a userdata-key >/dev/null 2>&1 || true
    rm -rf "$DATA_DIR"
    echo "已删除本地数据与钥匙串密钥: $DATA_DIR"
fi

echo "已卸载 $APP。"
