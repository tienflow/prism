#!/usr/bin/env zsh
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

# 版本号单一数据源 = 根 Info.plist（CFBundleShortVersionString），避免与打包脚本漂移
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DIR/Info.plist")"
APP_NAME="Prism.app"
DMG_NAME="Prism-v${VERSION}.dmg"
SIGNING_IDENTITY="Pinner Development"

# 内嵌 Python 运行时（python-build-standalone，可重定位、无需安装）。
# 固定版本，打包可复现；需要升级时改这里，或用环境变量 PRISM_PYTHON_PKG / PRISM_PYTHON_TAG 覆盖。
# 查询可用资产：https://github.com/astral-sh/python-build-standalone/releases
PYTHON_TAG="${PRISM_PYTHON_TAG:-20261013}"
PYTHON_PKG="${PRISM_PYTHON_PKG:-cpython-3.12.15+${PYTHON_TAG}-aarch64-apple-darwin-install_only}"
PYTHON_URL="${PRISM_PYTHON_URL:-https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_TAG}/${PYTHON_PKG}.tar.gz}"
# 解压后的运行时在工程内缓存复用（不入库，见 .gitignore）；每次打包仍全新安装依赖到 Bundle。
RUNTIME_CACHE="$DIR/Sidecar/python-runtime"

echo "=========================================="
echo "🚀 开始构建并打包 Prism (macOS 26 Liquid Glass)"
echo "=========================================="

# 1. 显式锁定稳定版 SDK
export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"

echo "📦 1/6 正在编译 Release 产物..."
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

echo "🎨 2/6 正在组装 ${APP_NAME} Bundle..."
rm -rf "$APP_NAME"
mkdir -p "${APP_NAME}/Contents/MacOS"
BUNDLE_SIDECAR="${APP_NAME}/Contents/Resources/Sidecar"
mkdir -p "$BUNDLE_SIDECAR"

# 拷贝二进制
cp "$BIN_SRC" "${APP_NAME}/Contents/MacOS/PrismApp"
chmod +x "${APP_NAME}/Contents/MacOS/PrismApp"

# 拷贝 Info.plist
cp "$DIR/Info.plist" "${APP_NAME}/Contents/Info.plist"

# 拷贝 Sidecar 完整运行时脚本
# ⚠️ 新增任何 Sidecar .py，必须在这里加一行 cp，否则安装包运行时 ImportError。
cp "$DIR/Sidecar/server.py" "$BUNDLE_SIDECAR/"
cp "$DIR/Sidecar/gemini_engine.py" "$BUNDLE_SIDECAR/"
cp "$DIR/Sidecar/optimizer.py" "$BUNDLE_SIDECAR/"
cp "$DIR/Sidecar/jev.py" "$BUNDLE_SIDECAR/"
cp "$DIR/Sidecar/requirements.txt" "$BUNDLE_SIDECAR/"
# ⚠️ 不打包 .env：其中含实时 Google 会话 Cookie，打进 Bundle 会造成
#   (1) 分发包（DMG / GitHub Release 附件）外泄凭据；
#   (2) 安装包内置过期 Cookie 成为失效种子，运行期又被写回而破坏代码签名。
# 运行期凭据缓存改由引擎写入 ~/Pictures/Prism/credentials.env（不随包分发）。

# App 图标：只认工程根目录持久化的 AppIcon.icns（单一数据源），不引用任何个人目录路径。
USER_ICON="$DIR/AppIcon.icns"
if [ -f "$USER_ICON" ]; then
    cp "$USER_ICON" "${APP_NAME}/Contents/Resources/AppIcon.icns"
    echo "✅ 已配置 App 图标: $USER_ICON"
else
    echo "⚠️ 警告: 未找到工程根目录 AppIcon.icns，将使用系统默认图标"
fi

echo "🐍 3/6 正在内嵌自包含 Python 运行时..."
# 3.1 缓存的解压运行时不存在则下载（约 40MB，解压后约 100MB）
CACHED_PYTHON="$RUNTIME_CACHE/python/bin/python3"
if [ ! -x "$CACHED_PYTHON" ]; then
    echo "   首次打包，下载 python-build-standalone: $PYTHON_PKG"
    mkdir -p "$RUNTIME_CACHE"
    TMP_TGZ="$RUNTIME_CACHE/runtime.tgz"
    TMP_EXTRACT="$RUNTIME_CACHE/extract"
    rm -rf "$TMP_EXTRACT"
    mkdir -p "$TMP_EXTRACT"
    curl -fL --retry 3 -o "$TMP_TGZ" "$PYTHON_URL"
    tar -xzf "$TMP_TGZ" -C "$TMP_EXTRACT"
    # install_only 资产解压后顶层即 python/
    if [ ! -x "$TMP_EXTRACT/python/bin/python3" ]; then
        echo "❌ 运行时包结构异常（未找到 python/bin/python3），请检查 PRISM_PYTHON_PKG"
        exit 1
    fi
    rm -rf "$RUNTIME_CACHE/python"
    mv "$TMP_EXTRACT/python" "$RUNTIME_CACHE/python"
    rm -rf "$TMP_EXTRACT" "$TMP_TGZ"
fi

# 3.2 拷贝解释器进 Bundle（保留符号链接与可执行位）
cp -R "$RUNTIME_CACHE/python" "$BUNDLE_SIDECAR/python"
BUNDLED_PYTHON="$BUNDLE_SIDECAR/python/bin/python3"
chmod +x "$BUNDLED_PYTHON"

# 3.3 用内嵌解释器把依赖装进 Bundle 内的 site-packages（与解释器解耦，SidecarManager 靠 PYTHONPATH 挂载）
#     不用 venv：venv 的 bin/python 是指向绝对路径的符号链接，安装到 /Applications 后会断裂。
"$BUNDLED_PYTHON" -B -m pip install --no-cache-dir --disable-pip-version-check \
    --target "$BUNDLE_SIDECAR/site-packages" \
    -r "$DIR/Sidecar/requirements.txt"
# 依赖里的 console 脚本入口在本项目用不到，删掉以缩小体积并避免 Gatekeeper 对额外可执行文件的扫描
rm -rf "$BUNDLE_SIDECAR/site-packages/bin"
# 清字节码：统一在运行时以 -B + dont_write_bytecode 禁止，包内不留 __pycache__
find "$BUNDLE_SIDECAR/python" "$BUNDLE_SIDECAR/site-packages" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# 3.4 组装完成后立刻用 Bundle 内解释器做依赖自检，打包机上先失败比用户机器上失败强
echo "   校验内嵌运行时依赖..."
PYTHONPATH="$BUNDLE_SIDECAR/site-packages" "$BUNDLED_PYTHON" -B -c "import gemini_webapi, cryptography, PIL; print('   内嵌 Python 依赖自检通过')"

echo "🔏 4/6 正在对 App 进行本地代码签名 (证书: ${SIGNING_IDENTITY})..."
# 内嵌 Python 含大量 dylib / .so，--deep 会递归签入；未指定证书时回退 ad-hoc。
if security find-identity -v -p codesigning | grep -q "${SIGNING_IDENTITY}"; then
    codesign --force --deep --timestamp=none --sign "${SIGNING_IDENTITY}" "${APP_NAME}"
    echo "✅ 证书签名成功: ${SIGNING_IDENTITY}"
else
    echo "⚠️ 未找到 '${SIGNING_IDENTITY}'，回退至 Ad-hoc 签名..."
    codesign --force --deep --sign - "${APP_NAME}"
fi

# 签名后再次验证内嵌解释器仍可执行（签名损坏会在此处暴露）
echo "   签名后复验内嵌运行时..."
PYTHONPATH="$BUNDLE_SIDECAR/site-packages" "$BUNDLED_PYTHON" -B -c "import gemini_webapi, cryptography, PIL; print('   签名后运行时复验通过')"

echo "💿 5/6 正在制作可拖拽安装的 DMG 镜像 (${DMG_NAME})..."
DMG_STAGE_DIR="$DIR/.dmg_stage"
rm -rf "$DMG_STAGE_DIR" "$DMG_NAME"
mkdir -p "$DMG_STAGE_DIR"

cp -R "${APP_NAME}" "$DMG_STAGE_DIR/"
ln -s /Applications "$DMG_STAGE_DIR/Applications"

hdiutil create -volname "Prism" -srcfolder "$DMG_STAGE_DIR" -ov -format UDZO "$DMG_NAME"
rm -rf "$DMG_STAGE_DIR"

echo "✅ DMG 制作完成: $DIR/$DMG_NAME"

echo "🔄 6/6 正在安装并平滑重启本地 /Applications/Prism.app..."
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

# 刷新 LaunchServices 注册（不再向 Finder 注入图标，避免对个人下载目录路径的依赖）
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
