#!/usr/bin/env bash
# 卸载输入法；加 --purge 一并删除本地数据（用户词、剪切板、知你学习数据）与钥匙串密钥
# 同时清理品牌升级前的 InputFlow 遗留（旧 app / 旧数据目录 / 旧偏好域）
set -euo pipefail

APP="Liana"
LEGACY_APP="InputFlow"
DEST="$HOME/Library/Input Methods/$APP.app"
LEGACY_DEST="$HOME/Library/Input Methods/$LEGACY_APP.app"
DATA_DIR="$HOME/Library/Application Support/Liana"
LEGACY_DATA_DIR="$HOME/Library/Application Support/InputFlow"
PLIST="$DEST/Contents/Info.plist"

# 以已安装 bundle 的实际 id 为准（支持 build.sh 的 BUNDLE_ID 覆盖）
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"
[[ -n "$BUNDLE_ID" ]] || BUNDLE_ID="dev.liana.ime"
LEGACY_BUNDLE_ID="dev.inputflow.ime"
# 钥匙串服务名钉死在初代 bundle id 上（EncryptedStore.swift），不随品牌/bundle id 变
KEYCHAIN_SERVICE="dev.inputflow.inputmethod"

killall "$APP" "$LEGACY_APP" 2>/dev/null || true
rm -rf "$DEST" "$LEGACY_DEST"
defaults delete "$BUNDLE_ID" 2>/dev/null || true
defaults delete "$LEGACY_BUNDLE_ID" 2>/dev/null || true

if [[ "${1:-}" == "--purge" ]]; then
    security delete-generic-password -s "$KEYCHAIN_SERVICE" -a userdata-key >/dev/null 2>&1 || true
    rm -rf "$DATA_DIR" "$LEGACY_DATA_DIR"
    echo "已删除本地数据与钥匙串密钥: $DATA_DIR"
fi

echo "已卸载 $APP（$BUNDLE_ID）。"
