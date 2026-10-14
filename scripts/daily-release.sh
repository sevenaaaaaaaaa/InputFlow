#!/usr/bin/env bash
# 松萝每日发版：同步 → 测试 → 升 patch 版本 → 打 macOS DMG（含放行助手）→ push + tag
#             → GitHub Release → 更新本机输入法
#
# 用法：
#   scripts/daily-release.sh              # 完整发版
#   scripts/daily-release.sh --dry-run    # 只在本地构建 + 打包 + 校验 DMG；不提交/打 tag/推送/发版/安装
#   scripts/daily-release.sh --no-install # 发版但不更新本机输入法
#   scripts/daily-release.sh --force      # 自上个 v* tag 以来没有新提交也照发
#
# 设计约束：可由 launchd 无人值守运行——不交互；只有真失败才非零退出；
# 工作区不干净时打印原因后 exit 0（skipped），绝不替用户提交未完成的改动。
# 日志：~/Library/Logs/liana-daily-release.log
set -euo pipefail

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Liana"
PRODUCT_BUNDLE_ID="dev.liana.inputmethod.ime"
INSTALL_DIR="$HOME/Library/Input Methods"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
HELPER_CMD="打不开？双击我.command"
HELPER_TXT="安装说明.txt"
LOG="$HOME/Library/Logs/liana-daily-release.log"

DRY_RUN=0; NO_INSTALL=0; FORCE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=1 ;;
        --no-install) NO_INSTALL=1 ;;
        --force)      FORCE=1 ;;
        -h|--help)    sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "未知参数：${arg}（可用：--dry-run --no-install --force）" >&2; exit 2 ;;
    esac
done

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo
echo "════════ $(date '+%F %T') daily-release $* ════════"

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
skip() { printf '\033[1;33m— skipped: %s\033[0m\n' "$*"; exit 0; }

# Single-instance lock (launchd + manual run must not overlap).
LOCK="${TMPDIR:-/tmp}/liana-daily-release.lock"
mkdir "$LOCK" 2>/dev/null || die "已有一个 daily-release 在运行（锁：${LOCK}）"
MOUNT=""
cleanup() {
    [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT

START=$(date +%s)
[[ $DRY_RUN == 1 ]] && log "DRY-RUN：只构建与打包，不提交/打 tag/推送/发版/安装"

# ──────────────────── 1. 前置条件 ────────────────────

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
    [[ $DRY_RUN == 1 ]] && warn "当前分支是 ${BRANCH}（正式发版要求 main）" || die "当前分支是 ${BRANCH}，发版只在 main 上进行"
fi

DIRTY="$(git status --porcelain)"
if [[ -n "$DIRTY" ]]; then
    echo "工作区有未提交改动："
    echo "$DIRTY" | sed 's/^/    /'
    [[ $DRY_RUN == 1 ]] && warn "DRY-RUN 继续（产物包含这些未提交改动）" \
        || skip "工作区不干净——请先提交或暂存后再发版（不会自动提交未完成的改动）"
fi

log "同步 origin"
if ! git fetch --quiet --tags origin; then
    [[ $DRY_RUN == 1 ]] && warn "git fetch 失败（DRY-RUN 用本地已有的 origin/main 继续）" || die "git fetch 失败"
fi
BEHIND="$(git rev-list --count HEAD..origin/main)"
if [[ "$BEHIND" -gt 0 ]]; then
    if [[ $DRY_RUN == 1 ]]; then
        warn "落后 origin/main $BEHIND 个提交（DRY-RUN 不拉取）"
    else
        log "落后 $BEHIND 个提交，rebase 拉取"
        if ! git pull --rebase --autostash --quiet origin main; then
            git rebase --abort 2>/dev/null || true
            die "拉取时出现冲突，已 rebase --abort，未做任何强制操作——请手动处理"
        fi
    fi
fi

log "运行测试：cargo test"
cargo test --workspace --quiet || die "cargo test 未通过，中止发版"

# ──────────────────── 2. 是否需要发版 ────────────────────

LAST_TAG="$(git tag -l 'v*' --sort=-v:refname | head -1)"
RESUME=0
if [[ -n "$LAST_TAG" && "$(git rev-parse "$LAST_TAG^{commit}")" == "$(git rev-parse HEAD)" \
      && "$(git log -1 --format=%s)" == "chore(release): $LAST_TAG" ]]; then
    # HEAD is already a release commit: resume an interrupted run (push/release/install).
    RESUME=1
    VERSION="${LAST_TAG#v}"
    PREV_TAG="$(git tag -l 'v*' --sort=-v:refname | sed -n 2p)"
    log "HEAD 已是 $LAST_TAG 的发版提交：续跑未完成的推送/发版/安装"
else
    NEW_COMMITS="$( [[ -n "$LAST_TAG" ]] && git rev-list --count "$LAST_TAG..HEAD" || git rev-list --count HEAD )"
    if [[ "$NEW_COMMITS" -eq 0 && $FORCE == 0 ]]; then
        [[ $DRY_RUN == 1 ]] && warn "自 $LAST_TAG 以来没有新提交（正式运行会跳过；DRY-RUN 继续）" \
            || skip "自 $LAST_TAG 以来没有新提交（--force 可强制发版）"
    fi
    BASE="${LAST_TAG#v}"; BASE="${BASE:-0.0.0}"
    IFS=. read -r MAJ MIN PAT <<<"$BASE"
    VERSION="$MAJ.$MIN.$((PAT + 1))"
    PREV_TAG="$LAST_TAG"
    log "上个版本 ${LAST_TAG:-（无）}，新提交 $NEW_COMMITS 个 → v$VERSION"
fi
TAG="v$VERSION"

# ──────────────────── 3. 升版本号 + 提交 + tag ────────────────────

# Every place the project keeps a version string.
set_version() {
    local v="$1"
    sed -i '' -E '/^\[workspace\.package\]/,/^\[/ s/^version = "[^"]*"/version = "'"$v"'"/' Cargo.toml
    cargo update --workspace --offline --quiet
    # Text substitution (not PlistBuddy) keeps the hand-written plist formatting intact.
    V="$v" perl -0pi -e 's{(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*}{$1$ENV{V}}' \
        platforms/macos/Info.plist platforms/macos/installer/Info.plist
    local code
    code="$(sed -n -E 's/^ *versionCode = ([0-9]+).*/\1/p' platforms/android/app/build.gradle.kts)"
    sed -i '' -E "s/^( *)versionCode = [0-9]+/\1versionCode = $((code + 1))/; s/^( *)versionName = \"[^\"]*\"/\1versionName = \"$v\"/" \
        platforms/android/app/build.gradle.kts
    sed -i '' -E "s/(MARKETING_VERSION: ).*/\1$v/" platforms/ios/project.yml
}
VERSION_FILES=(Cargo.toml Cargo.lock platforms/macos/Info.plist platforms/macos/installer/Info.plist
               platforms/android/app/build.gradle.kts platforms/ios/project.yml)

if [[ $DRY_RUN == 0 && $RESUME == 0 ]]; then
    git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG 已存在但不在 HEAD——请人工检查"
    log "写入版本号 $VERSION"
    set_version "$VERSION"
    git add -- "${VERSION_FILES[@]}"
    git commit --quiet -m "chore(release): $TAG" || die "发版提交失败（pre-commit 检查未通过？）"
    git tag -a "$TAG" -m "$TAG" || die "打 tag 失败"
fi

# ──────────────────── 4. 构建 macOS DMG ────────────────────

BUILD_START=$(date +%s)
log "构建 + 打包 DMG（产品 bundle id，版本 ${VERSION}）"
LIANA_VERSION="$VERSION" BUNDLE_ID="$PRODUCT_BUNDLE_ID" platforms/macos/dist.sh || die "dist.sh 失败"
BUILD_SECS=$(( $(date +%s) - BUILD_START ))

DMG="$(ls -t dist/Liana-"$VERSION"-*.dmg 2>/dev/null | head -1)"
[[ -f "$DMG" ]] || die "没有找到 dist/Liana-$VERSION-*.dmg"
DMG_SUM="$DMG.sha256"

log "校验 DMG 内容"
MOUNT="$(hdiutil attach -nobrowse -readonly -noautoopen "$DMG" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
[[ -d "$MOUNT" ]] || die "DMG 挂载失败"
for entry in "$APP_NAME.app" Applications "$HELPER_CMD" "$HELPER_TXT"; do
    [[ -e "$MOUNT/$entry" ]] || die "DMG 缺少：$entry"
done
[[ -x "$MOUNT/$HELPER_CMD" ]] || die "DMG 里的 $HELPER_CMD 没有可执行权限"
ls -la "$MOUNT" | tail -n +2 | sed 's/^/    /'
hdiutil detach "$MOUNT" -quiet && MOUNT=""
echo "    ✓ 4 项必需内容齐全，助手可执行"

if [[ $DRY_RUN == 1 ]]; then
    echo
    log "DRY-RUN 完成（$(( $(date +%s) - START ))s，其中构建 ${BUILD_SECS}s）"
    echo "  将发布版本: $TAG"
    echo "  DMG:        ${DMG}（$(du -h "$DMG" | cut -f1)）"
    echo "  日志:       $LOG"
    exit 0
fi

# ──────────────────── 5. 推送 + GitHub Release ────────────────────

log "推送 main 与 $TAG"
git push --quiet origin main || die "push main 失败"
git push --quiet origin "$TAG" || die "push $TAG 失败"

NOTES="$(mktemp)"
{
    echo "## 更新内容"
    git log --no-merges --format='- %s' "${PREV_TAG:+$PREV_TAG..}$TAG^" 2>/dev/null || true
    echo
    cat .github/release-notes-template.md
    cat "$DMG_SUM"
    echo '```'
} > "$NOTES"

# CI (.github/workflows/release.yml) also builds on tag push; it uploads only the assets
# missing from an existing release, so the local DMG is never clobbered.
if gh release view "$TAG" >/dev/null 2>&1; then
    log "Release $TAG 已存在，只补传缺失的产物"
    existing="$(gh release view "$TAG" --json assets -q '.assets[].name')"
    for f in "$DMG" "$DMG_SUM"; do
        grep -qxF "$(basename "$f")" <<<"$existing" || gh release upload "$TAG" "$f" || die "上传 $f 失败"
    done
else
    log "创建 GitHub Release $TAG"
    gh release create "$TAG" --verify-tag --title "$TAG" --notes-file "$NOTES" "$DMG" "$DMG_SUM" \
        || die "gh release create 失败"
fi
rm -f "$NOTES"
RELEASE_URL="$(gh release view "$TAG" --json url -q .url 2>/dev/null || echo "?")"

# ──────────────────── 6. 更新本机输入法 ────────────────────

INSTALLED_NOTE="未安装（--no-install）"
if [[ $NO_INSTALL == 0 ]]; then
    WAS_RUNNING=0
    pgrep -f "$INSTALLED_APP/Contents/MacOS/$APP_NAME" >/dev/null && WAS_RUNNING=1
    if [[ $WAS_RUNNING == 1 ]]; then
        log "退出正在运行的 $APP_NAME"
        RUNNING_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || echo "$PRODUCT_BUNDLE_ID")"
        osascript -e "quit app id \"$RUNNING_ID\"" >/dev/null 2>&1 || true
        for _ in $(seq 1 20); do
            pgrep -f "$INSTALLED_APP/Contents/MacOS/$APP_NAME" >/dev/null || break
            sleep 0.5
        done
    fi
    # The DMG build uses the product bundle id; a local .bundle-id override (the id the user's
    # existing IME registration lives under) needs a matching rebuild before install.
    if [[ -f platforms/macos/.bundle-id ]]; then
        log "按本机 bundle id 覆盖（platforms/macos/.bundle-id）重新构建"
        platforms/macos/build.sh || die "本机构建失败"
    fi
    log "安装到 $INSTALL_DIR"
    platforms/macos/install.sh || die "install.sh 失败"
    xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true
    if [[ $WAS_RUNNING == 1 ]]; then
        open -g "$INSTALLED_APP" || warn "重新启动 $APP_NAME 失败（下次切换输入法时系统会自动拉起）"
    fi
    INSTALLED_NOTE="$INSTALLED_APP"
fi

# ──────────────────── 7. 总结 ────────────────────

echo
log "发版完成（$(( $(date +%s) - START ))s）"
echo "  版本:     $TAG"
echo "  Release:  $RELEASE_URL"
echo "  DMG:      $DMG"
echo "  本机安装: $INSTALLED_NOTE"
echo "  日志:     $LOG"
