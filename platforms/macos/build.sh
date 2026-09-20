#!/usr/bin/env bash
# 构建 macOS 输入法（不依赖 Xcode 工程：Rust 静态库 + swiftc + 手工 bundle）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
APP="InputFlow"
BUILD="$HERE/build"
BUNDLE="$BUILD/$APP.app"
CONTENTS="$BUNDLE/Contents"
BIN_DIR="$CONTENTS/MacOS"
DEPLOY_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
ARCH="$(uname -m)"

echo "==> 1/4 构建 Rust 内核静态库"
cargo build --release --manifest-path "$ROOT/Cargo.toml" -p inputflow-ffi

echo "==> 2/4 编译 Swift 外壳（目标 ${ARCH}-apple-macos${DEPLOY_TARGET}）"
rm -rf "$BUNDLE"
mkdir -p "$BIN_DIR" "$CONTENTS/Resources"
# 显式链接静态库（避免链接到同目录的 .dylib，保证 app 自包含可分发）
RUST_LIB="$ROOT/target/release/libinputflow_ffi.a"
[[ -f "$RUST_LIB" ]] || { echo "缺少 $RUST_LIB" >&2; exit 1; }

swiftc -O -wmo \
    -target "${ARCH}-apple-macos${DEPLOY_TARGET}" \
    -import-objc-header "$ROOT/crates/ffi/include/inputflow.h" \
    "$RUST_LIB" \
    -framework AppKit -framework InputMethodKit -framework Carbon \
    -o "$BIN_DIR/$APP" \
    "$HERE/Sources/main.swift" \
    "$HERE/Sources/Engine.swift" \
    "$HERE/Sources/CandidateWindow.swift" \
    "$HERE/Sources/EncryptedStore.swift" \
    "$HERE/Sources/ClipboardMonitor.swift" \
    "$HERE/Sources/ClipboardWindow.swift" \
    "$HERE/Sources/AIModelStore.swift" \
    "$HERE/Sources/SettingsWindow.swift" \
    "$HERE/Sources/InputController.swift"

cp "$HERE/Info.plist" "$CONTENTS/Info.plist"

echo "==> 3/4 生成外部词典（base.ifd，20 万词条）"
DICT_OUT="$HERE/build/base.ifd"
DICT_SRC="$ROOT/crates/dict/data/base-large.tsv"
if [[ ! -f "$DICT_OUT" || "$DICT_SRC" -nt "$DICT_OUT" ]]; then
    cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p xtask -- \
        dict build "$DICT_SRC" -o "$DICT_OUT"
else
    echo "词典已是最新，跳过（源文件未变）"
fi

echo "==> 4/4 Ad-hoc 签名"
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 \
    || echo "（签名失败不影响本地安装）"

echo
echo "完成: $BUNDLE"
echo "下一步: ./install.sh"
