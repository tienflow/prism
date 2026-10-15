#!/usr/bin/env zsh
# Prism 一键编译与启动脚本
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

# 锁定稳定版 macOS 26 SDK，避免 CLT 27 实验性宏缺失
export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"

echo "🔨 正在编译 Prism (macOS 26 Liquid Glass)..."
swift build -c release

BIN_PATH="$DIR/.build/arm64-apple-macosx/release/PrismApp"

echo "🚀 启动 PrismApp..."
exec "$BIN_PATH"
