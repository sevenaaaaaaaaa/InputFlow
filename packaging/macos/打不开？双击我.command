#!/bin/bash
# Liana Gatekeeper helper (shipped inside every macOS DMG).
#
# Downloaded copies of an un-notarized app carry the com.apple.quarantine flag, so macOS
# reports "已损坏，无法打开". This script only removes that flag from the Liana apps,
# re-signs ad-hoc solely when the existing signature fails verification, then opens it.
# No network access, no other system changes.
set -u

APP_NAME="Liana.app"
INSTALLER_NAME="松萝安装器.app"
HERE="$(cd "$(dirname "$0")" && pwd)"

say()  { printf '%s\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }

finish() {
    say ""
    read -r -n 1 -s -p "按任意键关闭此窗口…" _ || true
    say ""
    exit "${1:-0}"
}

say "松萝（Liana）· 解除 macOS「已损坏 / 无法打开」拦截"
say "────────────────────────────────────────────"

# Collect installed copies first; fall back to the copies next to this script.
targets=()
for p in "/Applications/$INSTALLER_NAME" \
         "$HOME/Library/Input Methods/$APP_NAME" \
         "/Library/Input Methods/$APP_NAME" \
         "/Applications/$APP_NAME"; do
    [[ -d "$p" ]] && targets+=("$p")
done
if [[ ${#targets[@]} -eq 0 ]]; then
    for p in "$HERE/$INSTALLER_NAME" "$HERE/$APP_NAME"; do
        [[ -d "$p" ]] && targets+=("$p")
    done
fi
if [[ ${#targets[@]} -eq 0 ]]; then
    warn "没有找到松萝。请先把「${INSTALLER_NAME}」拖进「应用程序」文件夹，再双击我。"
    finish 1
fi

# Run a command; if it fails for lack of permission, explain and retry once with sudo.
run_maybe_sudo() {
    local why="$1"; shift
    "$@" 2>/dev/null && return 0
    say "  需要管理员权限：$why"
    say "  （下面输入的是本机登录密码，输入时不显示字符）"
    sudo "$@"
}

opened=""
for app in "${targets[@]}"; do
    say ""
    say "处理：$app"
    case "$app" in
        /Volumes/*)
            # Mounted DMG is read-only; the quarantine flag cannot be removed in place.
            warn "它还在安装盘（DMG）里，无法直接修改。请先拖进「应用程序」文件夹，再双击我。"
            continue
            ;;
    esac

    if xattr -r "$app" 2>/dev/null | grep -q 'com.apple.quarantine'; then
        if run_maybe_sudo "该 App 不属于当前用户，去除隔离标记需要授权" \
                xattr -dr com.apple.quarantine "$app"; then
            ok "已去除隔离标记"
        else
            warn "去除隔离标记失败"
            continue
        fi
    else
        ok "没有隔离标记，无需处理"
    fi

    if codesign --verify "$app" >/dev/null 2>&1; then
        ok "签名校验通过"
    else
        warn "签名校验未通过，改用本机临时签名（ad-hoc）"
        run_maybe_sudo "重签该 App 需要写入权限" \
            codesign --force --deep -s - "$app" >/dev/null && ok "已重新签名"
    fi

    [[ -z "$opened" ]] && opened="$app"
done

say ""
if [[ -n "$opened" ]]; then
    case "$opened" in
        *"$INSTALLER_NAME")
            ok "正在打开安装器，按提示完成安装即可。"
            ;;
        *)
            ok "正在启动输入法。若输入法列表里还没有「松萝」："
            say "  系统设置 → 键盘 → 文字输入 → 输入法 → 编辑… → + → 中文（简体）→ 松萝"
            say "  仍然没有的话，注销并重新登录一次。"
            ;;
    esac
    open "$opened" || warn "打开失败，请手动双击：$opened"
    finish 0
fi
finish 1
