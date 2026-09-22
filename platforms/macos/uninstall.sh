#!/usr/bin/env bash
# 卸载输入法；加 --purge 一并删除本地数据（用户词、剪切板）与钥匙串密钥
set -euo pipefail

APP="InputFlow"
DEST="$HOME/Library/Input Methods/$APP.app"
DATA_DIR="$HOME/Library/Application Support/InputFlow"
PLIST="$DEST/Contents/Info.plist"

# 以已安装 bundle 的实际 id 为准（支持 build.sh 的 BUNDLE_ID 覆盖）
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"
[[ -n "$BUNDLE_ID" ]] || BUNDLE_ID="dev.inputflow.inputmethod"

killall "$APP" 2>/dev/null || true
rm -rf "$DEST"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

if [[ "${1:-}" == "--purge" ]]; then
    security delete-generic-password -s "$BUNDLE_ID" -a userdata-key >/dev/null 2>&1 || true
    rm -rf "$DATA_DIR"
    echo "已删除本地数据与钥匙串密钥: $DATA_DIR"
fi

echo "已卸载 $APP（$BUNDLE_ID）。"
