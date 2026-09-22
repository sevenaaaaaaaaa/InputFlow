#!/usr/bin/env bash
# 构建 macOS 输入法（不依赖 Xcode 工程：Rust 静态库 + swiftc + 手工 bundle）
#
# 默认产出 Universal Binary（arm64 + x86_64），覆盖 Apple Silicon（M1–M6…）
# 与 Intel 芯片；部署目标 macOS 13.0，可运行于 macOS 13/14/15/26+。
# 单架构构建：UNIVERSAL=0 ./build.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
APP="InputFlow"
BUILD="$HERE/build"
BUNDLE="$BUILD/$APP.app"
CONTENTS="$BUNDLE/Contents"
BIN_DIR="$CONTENTS/MacOS"
DEPLOY_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
UNIVERSAL="${UNIVERSAL:-1}"
# 签名身份：优先 CODESIGN_IDENTITY，其次自动选用钥匙串里的 Apple Development，最后退回 ad-hoc。
# macOS 26+ 只收录有效签名（Apple 签发、带 Team ID）的第三方输入法，ad-hoc 不会出现。
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"

echo "==> 1/5 构建 Rust 内核静态库"
mkdir -p "$ROOT/target/release"
if [[ "$UNIVERSAL" == "1" ]]; then
    # 零 crates 依赖，两个 target 都能干净交叉编译
    cargo build --release --manifest-path "$ROOT/Cargo.toml" -p inputflow-ffi \
        --target aarch64-apple-darwin
    cargo build --release --manifest-path "$ROOT/Cargo.toml" -p inputflow-ffi \
        --target x86_64-apple-darwin
    lipo -create \
        "$ROOT/target/aarch64-apple-darwin/release/libinputflow_ffi.a" \
        "$ROOT/target/x86_64-apple-darwin/release/libinputflow_ffi.a" \
        -output "$ROOT/target/release/libinputflow_ffi.a"
else
    cargo build --release --manifest-path "$ROOT/Cargo.toml" -p inputflow-ffi
fi

echo "==> 2/5 编译 Swift 外壳（目标 macOS ${DEPLOY_TARGET}）"
rm -rf "$BUNDLE"
mkdir -p "$BIN_DIR" "$CONTENTS/Resources"
# 显式链接静态库（避免链接到同目录的 .dylib，保证 app 自包含可分发）
RUST_LIB="$ROOT/target/release/libinputflow_ffi.a"
[[ -f "$RUST_LIB" ]] || { echo "缺少 $RUST_LIB" >&2; exit 1; }

# swiftc 驱动不支持 -arch：逐架构编译出可执行文件，最后 lipo 合成 Universal
SWIFT_SOURCES=("$HERE/Sources/main.swift" "$HERE/Sources/Engine.swift" \
    "$HERE/Sources/CandidateWindow.swift" "$HERE/Sources/AppProfile.swift" \
    "$HERE/Sources/PetWindow.swift" "$HERE/Sources/EncryptedStore.swift" \
    "$HERE/Sources/ClipboardMonitor.swift" "$HERE/Sources/ClipboardWindow.swift" \
    "$HERE/Sources/AIModelStore.swift" "$HERE/Sources/BackupManager.swift" \
    "$HERE/Sources/SettingsWindow.swift" "$HERE/Sources/InputController.swift" \
    "$HERE/Sources/AppModeMemory.swift" "$HERE/Sources/Theme.swift" \
    "$HERE/Sources/PermissionCenter.swift" "$HERE/Sources/PetStats.swift")
if [[ "$UNIVERSAL" == "1" ]]; then
    SWIFT_ARCHS=(arm64 x86_64)
else
    SWIFT_ARCHS=("$(uname -m)")
fi
for arch in "${SWIFT_ARCHS[@]}"; do
    swiftc -O -wmo \
        -target "${arch}-apple-macos${DEPLOY_TARGET}" \
        -import-objc-header "$ROOT/crates/ffi/include/inputflow.h" \
        "$RUST_LIB" \
        -framework AppKit -framework InputMethodKit -framework Carbon \
        -o "$BIN_DIR/$APP.$arch" \
        "${SWIFT_SOURCES[@]}"
done
if [[ "${#SWIFT_ARCHS[@]}" -gt 1 ]]; then
    lipo -create "$BIN_DIR/$APP."{"${SWIFT_ARCHS[0]}","${SWIFT_ARCHS[1]}"} -output "$BIN_DIR/$APP"
    rm -f "$BIN_DIR/$APP."*
else
    mv "$BIN_DIR/$APP.${SWIFT_ARCHS[0]}" "$BIN_DIR/$APP"
fi

cp "$HERE/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp "$HERE/assets/InputFlow.icns" "$CONTENTS/Resources/InputFlow.icns"

echo "==> 3/5 生成外部词典（base.ifd，20 万词条）"
DICT_OUT="$HERE/build/base.ifd"
DICT_SRC="$ROOT/crates/dict/data/base-large.tsv"
if [[ ! -f "$DICT_OUT" || "$DICT_SRC" -nt "$DICT_OUT" ]]; then
    cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p xtask -- \
        dict build "$DICT_SRC" -o "$DICT_OUT"
else
    echo "词典已是最新，跳过（源文件未变）"
fi

echo "==> 4/5 构建图形安装器"
INSTALLER="$BUILD/InputFlow 安装器.app"
INSTALLER_CONTENTS="$INSTALLER/Contents"
INSTALLER_BIN="$INSTALLER_CONTENTS/MacOS"
INSTALLER_RES="$INSTALLER_CONTENTS/Resources"
rm -rf "$INSTALLER"
mkdir -p "$INSTALLER_BIN" "$INSTALLER_RES"
swiftc -O -wmo -parse-as-library \
    -target "$(uname -m)-apple-macos${DEPLOY_TARGET}" \
    -framework AppKit -framework Carbon \
    -o "$INSTALLER_BIN/InputFlowInstaller" \
    "$HERE/installer/Installer.swift"
cp "$HERE/installer/Info.plist" "$INSTALLER_CONTENTS/Info.plist"
printf 'APPL????' > "$INSTALLER_CONTENTS/PkgInfo"
cp "$HERE/assets/InputFlowInstaller.icns" "$INSTALLER_RES/InputFlowInstaller.icns"
cp "$HERE/assets/InputFlow.icns" "$INSTALLER_RES/InputFlow.icns"
# 把输入法本体与词库作为安装包内嵌资源
cp -R "$BUNDLE" "$INSTALLER_RES/InputFlow.app"
cp "$HERE/build/base.ifd" "$INSTALLER_RES/base.ifd"

echo "==> 5/5 签名"
if [[ -n "$CODESIGN_IDENTITY" ]]; then
    echo "    使用签名身份: $CODESIGN_IDENTITY"
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$BUNDLE" >/dev/null 2>&1 \
        || echo "（签名失败，退化为 ad-hoc）"
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$INSTALLER" >/dev/null 2>&1 \
        || echo "（安装器签名失败）"
else
    echo "    未找到有效签名身份，使用 ad-hoc（macOS 26+ 不会被系统收录）"
    codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 \
        || echo "（签名失败不影响本地安装）"
    codesign --force --deep --sign - "$INSTALLER" >/dev/null 2>&1 \
        || echo "（安装器签名失败不影响本地使用）"
fi
codesign -dv "$BUNDLE" 2>&1 | rg 'TeamIdentifier|Signature' | sed 's/^/    /' || true

echo
echo "完成: $BUNDLE"
echo "安装器: $INSTALLER"
echo "下一步: ./install.sh 或双击安装器"
