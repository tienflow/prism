#!/usr/bin/env zsh
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

VERSION="1.1.0"
APP_NAME="Prism.app"
DMG_NAME="Prism-v${VERSION}.dmg"
SIGNING_IDENTITY="Pinner Development"

echo "=========================================="
echo "🚀 开始构建并打包 Prism (macOS 26 Liquid Glass)"
echo "=========================================="

# 1. 显式锁定稳定版 SDK
export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"

echo "📦 1/5 正在编译 Release 产物..."
swift build -c release --product PrismApp

# 确定二进制路径
BIN_SRC="$DIR/.build/out/Products/Release/PrismApp"
if [ ! -f "$BIN_SRC" ]; then
    BIN_SRC="$(find "$DIR/.build" -type f -name PrismApp -path "*/Release/*" -not -path "*.dSYM*" | head -n 1)"
fi

if [ ! -f "$BIN_SRC" ]; then
    echo "❌ 错误: 未找到编译产物: $BIN_SRC"
    exit 1
fi

echo "🎨 2/5 正在组装 ${APP_NAME} Bundle..."
rm -rf "$APP_NAME"
mkdir -p "${APP_NAME}/Contents/MacOS"
mkdir -p "${APP_NAME}/Contents/Resources/Sidecar"

# 拷贝二进制
cp "$BIN_SRC" "${APP_NAME}/Contents/MacOS/PrismApp"
chmod +x "${APP_NAME}/Contents/MacOS/PrismApp"

# 拷贝 Info.plist
cp "$DIR/Info.plist" "${APP_NAME}/Contents/Info.plist"

# 拷贝 Sidecar 完整运行时脚本
cp "$DIR/Sidecar/server.py" "${APP_NAME}/Contents/Resources/Sidecar/"
cp "$DIR/Sidecar/gemini_engine.py" "${APP_NAME}/Contents/Resources/Sidecar/"
cp "$DIR/Sidecar/optimizer.py" "${APP_NAME}/Contents/Resources/Sidecar/"
if [ -f "$DIR/Sidecar/.env" ]; then
    cp "$DIR/Sidecar/.env" "${APP_NAME}/Contents/Resources/Sidecar/"
fi

# 强制拷贝用户指定的 App 图标 (优先工程根目录持久化的 AppIcon.icns)
USER_ICON="$DIR/AppIcon.icns"
if [ ! -f "$USER_ICON" ]; then
    USER_ICON="/Users/apple/Downloads/Gemini_gKxdN5gfhP_icns-048920d3e5.icns"
fi

if [ -f "$USER_ICON" ]; then
    cp "$USER_ICON" "${APP_NAME}/Contents/Resources/AppIcon.icns"
    echo "✅ 已成功配置指定 App 图标: $USER_ICON"
else
    echo "❌ 警告: 未找到指定的 AppIcon: $USER_ICON"
fi

echo "🔏 3/5 正在对 App 进行本地代码签名 (证书: ${SIGNING_IDENTITY})..."
if security find-identity -v -p codesigning | grep -q "${SIGNING_IDENTITY}"; then
    codesign --force --deep --sign "${SIGNING_IDENTITY}" "${APP_NAME}"
    echo "✅ 证书签名成功: ${SIGNING_IDENTITY}"
else
    echo "⚠️ 未找到 '${SIGNING_IDENTITY}'，回退至 Ad-hoc 签名..."
    codesign --force --deep --sign - "${APP_NAME}"
fi

echo "💿 4/5 正在制作可拖拽安装的 DMG 镜像 (${DMG_NAME})..."
DMG_STAGE_DIR="$DIR/.dmg_stage"
rm -rf "$DMG_STAGE_DIR" "$DMG_NAME"
mkdir -p "$DMG_STAGE_DIR"

cp -R "${APP_NAME}" "$DMG_STAGE_DIR/"
ln -s /Applications "$DMG_STAGE_DIR/Applications"

hdiutil create -volname "Prism" -srcfolder "$DMG_STAGE_DIR" -ov -format UDZO "$DMG_NAME"
rm -rf "$DMG_STAGE_DIR"

echo "✅ DMG 制作完成: $DIR/$DMG_NAME"

echo "🔄 5/5 正在安装并平滑重启本地 /Applications/Prism.app..."
# 1. 彻底杀掉旧的 App 与 Python Sidecar 进程
killall PrismApp 2>/dev/null || pkill -f PrismApp 2>/dev/null || true
pkill -f "Prism.*/Sidecar/server.py" 2>/dev/null || true
pkill -f "Sidecar/server.py" 2>/dev/null || true
sleep 1.5

# 2. 安装最新 Bundle 至 /Applications
rm -rf "/Applications/${APP_NAME}"
cp -R "${APP_NAME}" "/Applications/"
touch "/Applications/${APP_NAME}"
touch "/Applications/${APP_NAME}/Contents/Info.plist"

# 强制将用户指定图标物理注入 Finder 与系统图标服务
swift -e 'import AppKit; if let img = NSImage(contentsOfFile: "'"$USER_ICON"'") { NSWorkspace.shared.setIcon(img, forFile: "/Applications/'"$APP_NAME"'", options: []) }'
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "/Applications/${APP_NAME}"

# 3. 仅打开目标 App
open "/Applications/${APP_NAME}"

sleep 1.5

# 4. 验证新进程是否成功拉起
echo "=========================================="
echo "🎉 进程拉起状态验证："
ps -eo pid,lstart,command | grep -i "[P]rism" || echo "⚠️ 提示: 请检查窗口是否已在屏幕显示"
echo "=========================================="
echo "🚀 Prism 最新版本已成功安装并启动！"
