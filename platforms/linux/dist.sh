#!/usr/bin/env bash
# Linux 发布打包：构建（build.sh --local）→ 组装可安装目录树 → tarball + 校验和
#
# 产物（$ROOT/dist/）：
#   liana-<版本>-linux-<架构>.tar.gz       解包后 sudo ./install.sh 一键安装
#   liana-<版本>-linux-<架构>.tar.gz.sha256
#
# 用法：
#   LIANA_VERSION=v0.4.0 ./dist.sh     # CI 口径，版本号进目录名
#   ./dist.sh                          # 本地试打，版本号记 dev
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VERSION="${LIANA_VERSION:-dev}"
ARCH="$(uname -m)"
NAME="liana-${VERSION}-linux-${ARCH}"
OUT="$ROOT/dist"

echo "==> 1/2 构建内核 + 词典（不安装）"
"$HERE/build.sh" --local
SO="$ROOT/target/release/libliana_ffi.so"

echo "==> 2/2 组装 $NAME.tar.gz"
STAGE="$(mktemp -d)/$NAME"
mkdir -p "$STAGE"
cp "$SO" "$STAGE/libliana_ffi.so"
cp "$HERE/ibus-liana" "$HERE/libliana.py" "$HERE/liana.xml" "$STAGE/"
cp "$HERE/build/base.ifd" "$STAGE/base.ifd"
chmod +x "$STAGE/ibus-liana"

# install.sh：与 build.sh 的安装段同一口径，脱机 tarball 自带
cat > "$STAGE/install.sh" <<'EOF'
#!/usr/bin/env bash
# 松萝 ibus 引擎一键安装（与 platforms/linux/build.sh 的安装段一致）
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sudo mkdir -p /usr/local/lib/liana
sudo cp "$HERE/libliana_ffi.so" /usr/local/lib/liana/libliana_ffi.so
sudo cp "$HERE/ibus-liana" /usr/local/lib/liana/ibus-liana
sudo chmod +x /usr/local/lib/liana/ibus-liana
sudo cp "$HERE/libliana.py" /usr/local/lib/liana/libliana.py
sudo cp "$HERE/base.ifd" /usr/local/lib/liana/base.ifd
sudo mkdir -p /usr/share/ibus/component
sudo cp "$HERE/liana.xml" /usr/share/ibus/component/liana.xml

# 词典放用户数据目录（ibus 引擎以当前用户身份运行）
mkdir -p "$HOME/.local/share/liana"
cp "$HERE/base.ifd" "$HOME/.local/share/liana/base.ifd"

echo
echo "安装完成。启用步骤："
echo "  1. 重启 ibus:  ibus restart"
echo "  2. ibus-setup → 输入法 → 添加 → 中文 → 松萝"
echo "  3. Win+Space 切换到「松萝」"
EOF
chmod +x "$STAGE/install.sh"

mkdir -p "$OUT"
tar -czf "$OUT/$NAME.tar.gz" -C "$(dirname "$STAGE")" "$NAME"
( cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )

echo
echo "产物就绪："
ls -lh "$OUT" | tail -n +2
