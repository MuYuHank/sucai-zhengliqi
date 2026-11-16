#!/usr/bin/env bash
# 用 Swift Package Manager 和系统自带的 codesign 打出 产物整理器.app。
# 不调用 xcodebuild，不需要完整的 Xcode，只要 Command Line Tools 里的 swift。
# macOS 自带的 bash 是 3.2，这个脚本刻意不使用 bash 4 的语法。

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "make_app.sh 只能在 macOS 上运行。Linux 上请在仓库根目录执行：swift test" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="release"
INSTALL=0
OPEN_APP=0
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

usage() {
  cat <<'EOF'
用法：
  ./scripts/make_app.sh              构建 dist/产物整理器.app
  ./scripts/make_app.sh --debug      用 debug 配置构建
  ./scripts/make_app.sh --install    构建并复制到 /Applications
  ./scripts/make_app.sh --open       构建后用 open 启动
  INSTALL_DIR=~/Applications ./scripts/make_app.sh --install

不要使用 xcodebuild。Command Line Tools 的 swift 就够了。
EOF
}

for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="debug" ;;
    --install) INSTALL=1 ;;
    --open) OPEN_APP=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "未知参数：$arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v swift >/dev/null 2>&1; then
  echo "找不到 swift。安装 Command Line Tools：xcode-select --install" >&2
  exit 1
fi

echo "swift：$(swift --version | head -n 1)"
if ! swift package describe >/dev/null; then
  echo "swift package describe 失败。请在仓库根目录运行。" >&2
  exit 1
fi
if ! swift package describe | grep -q "ChanwuApp"; then
  echo "包描述里没有 ChanwuApp。Package.swift 只在 macOS 上加入这个目标。" >&2
  echo "请确认 swift 是在这台 Mac 上运行，而不是在 Linux 容器里。" >&2
  exit 1
fi

VERSION="$(sed -n 's/.*organizerVersion = "\([^"]*\)".*/\1/p' Sources/OrganizerCore/Models.swift | head -n 1)"
if [[ -z "$VERSION" ]]; then
  VERSION="1.0.0"
fi

echo "正在构建 ChanwuApp（${CONFIG}）…"
swift build -c "$CONFIG" --product ChanwuApp
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/ChanwuApp"
if [[ ! -x "$BIN" ]]; then
  echo "没有找到可执行文件：$BIN" >&2
  exit 1
fi

APP="$ROOT/dist/产物整理器.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ChanwuApp"
chmod 755 "$APP/Contents/MacOS/ChanwuApp"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh-Hans</string>
  <key>CFBundleExecutable</key>
  <string>ChanwuApp</string>
  <key>CFBundleIdentifier</key>
  <string>app.chanwu.organizer</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Chanwu</string>
  <key>CFBundleDisplayName</key>
  <string>产物整理器</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>zh-Hans</string>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>本地整理工具。不联网，不删除文件。</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$APP/Contents/Info.plist"
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP"
  codesign --verify --verbose=2 "$APP"
else
  echo "警告：没有 codesign，应用未签名。macOS 可能拒绝启动。" >&2
fi

ZIP="$ROOT/dist/产物整理器.zip"
rm -f "$ZIP"
if command -v ditto >/dev/null 2>&1; then
  ditto -c -k --keepParent "$APP" "$ZIP"
elif command -v zip >/dev/null 2>&1; then
  (cd "$ROOT/dist" && zip -r -y "产物整理器.zip" "产物整理器.app")
else
  echo "警告：没有 ditto 或 zip，没有生成 产物整理器.zip。" >&2
fi

echo "已生成：$APP"
if [[ -f "$ZIP" ]]; then
  echo "已生成：$ZIP"
fi
echo "直接运行裸的 swift build 二进制没有包标识，菜单栏、热键和隐私权限都会不稳定。请打开这个 .app。"

if [[ "$INSTALL" -eq 1 ]]; then
  DEST="$INSTALL_DIR/产物整理器.app"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "已安装：$DEST"
fi

if [[ "$OPEN_APP" -eq 1 ]]; then
  open "$APP"
fi
