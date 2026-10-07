#!/usr/bin/env bash
#
# make-app.sh —— 构建 DockPeek 并组装成标准的 macOS .app 包
#
# 用法:
#   ./Scripts/make-app.sh          # release 构建（默认）
#   ./Scripts/make-app.sh debug    # debug 构建
#
# 产物: <项目根>/dist/DockPeek.app
#
# 注意: 重新构建会改变代码哈希，macOS 可能因此再次询问
#       「屏幕录制」/「辅助功能」权限 —— 这是预期行为，不是 bug。
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 路径解析：无论从哪个 cwd 调用都能正确定位项目根目录
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="DockPeek"
BUNDLE_ID="com.dockpeek.app"
VERSION="$(cat "$PROJECT_ROOT/VERSION")"
DOCKPEEK_BUILD_ARCH="${DOCKPEEK_BUILD_ARCH:-$(uname -m)}"
BUILD_NUMBER="5"
MIN_MACOS="14.0"
# 构建日期：写进 Info.plist，用于区分机器上同名的多份副本。只到日期，不需要时分。
BUILD_STAMP="$(date '+%Y-%m-%d')"

DIST_DIR="$PROJECT_ROOT/dist"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
# --scratch-path: 构建产物始终落在项目内，绝不污染全局缓存
SCRATCH_PATH="$PROJECT_ROOT/.build"
ICON_SRC="$PROJECT_ROOT/Resources/AppIcon.icns"

# ---------------------------------------------------------------------------
# 构建配置：可选第一个参数 "debug"
# ---------------------------------------------------------------------------
CONFIG="release"
if [[ "${1:-}" == "debug" ]]; then
    CONFIG="debug"
fi

echo "==> 构建配置: $CONFIG"
echo "==> 项目根目录: $PROJECT_ROOT"

# ---------------------------------------------------------------------------
# 0. 把 clang / swift 的模块缓存也固定到项目内
#    目的与 --scratch-path 一致：所有构建产物都留在项目里，不写全局缓存。
#    （顺带解决受限环境下 ~/Library 与系统 Caches 目录不可写导致构建失败的问题）
#    需要时可用同名环境变量覆盖。
# ---------------------------------------------------------------------------
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$SCRATCH_PATH/modulecache/clang}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$SCRATCH_PATH/modulecache/swift}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH"

# ---------------------------------------------------------------------------
# 1. 编译 Swift 包（失败时让错误原样输出，不做任何吞掉处理）
# ---------------------------------------------------------------------------
# SwiftPM 编译 Package.swift 时会用 sandbox-exec 包一层。如果本脚本本身已经
# 运行在沙箱里（CI / 受限环境），再嵌套 sandbox-exec 会直接报
# "sandbox_apply: Operation not permitted"，此时需要关掉 SwiftPM 自带的沙箱。
SWIFT_BUILD_FLAGS=()
if command -v sandbox-exec >/dev/null 2>&1; then
    if ! sandbox-exec -p '(version 1) (allow default)' /usr/bin/true >/dev/null 2>&1; then
        echo "==> 当前环境无法使用 sandbox-exec，构建时关闭 SwiftPM 沙箱"
        SWIFT_BUILD_FLAGS+=(--disable-sandbox)
    fi
fi

if ! swift build --build-system native --triple "${DOCKPEEK_BUILD_ARCH}-apple-macosx14.0" -c "$CONFIG" --product "$APP_NAME" \
        --package-path "$PROJECT_ROOT" \
        --scratch-path "$SCRATCH_PATH" \
        --cache-path "$SCRATCH_PATH/cache" \
        "${SWIFT_BUILD_FLAGS[@]+"${SWIFT_BUILD_FLAGS[@]}"}"; then
    echo "" >&2
    echo "❌ swift build 失败，请查看上方编译错误。" >&2
    exit 1
fi

# 定位可执行文件所在目录
BIN_DIR="$(swift build --build-system native --triple "${DOCKPEEK_BUILD_ARCH}-apple-macosx14.0" -c "$CONFIG" \
    --package-path "$PROJECT_ROOT" \
    --scratch-path "$SCRATCH_PATH" \
    "${SWIFT_BUILD_FLAGS[@]+"${SWIFT_BUILD_FLAGS[@]}"}" --show-bin-path)"
BUILT_BIN="$BIN_DIR/$APP_NAME"
if [[ ! -f "$BUILT_BIN" ]]; then
    # 兜底：老版本 SwiftPM 的默认布局
    BUILT_BIN="$SCRATCH_PATH/$CONFIG/$APP_NAME"
fi
if [[ ! -f "$BUILT_BIN" ]]; then
    echo "❌ 找不到已构建的可执行文件: $BUILT_BIN" >&2
    exit 1
fi
echo "==> 已构建可执行文件: $BUILT_BIN"

# ---------------------------------------------------------------------------
# 2. 组装 bundle 目录结构
# ---------------------------------------------------------------------------
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILT_BIN" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# 图标：存在才拷贝
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"
    echo "==> 已拷贝图标: $ICON_SRC"
else
    echo "==> 未找到 $ICON_SRC，跳过图标（App 仍可正常运行）"
fi

# ---------------------------------------------------------------------------
# 3. 生成 Info.plist
# ---------------------------------------------------------------------------
cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <!-- 构建时间戳：用于关于页和开发诊断，区分应用副本 -->
    <key>DockPeekBuildStamp</key>
    <string>${BUILD_STAMP}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <!-- 菜单栏常驻的 agent 应用：不显示 Dock 图标、不显示主窗口 -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 LiDongB. Released under the MIT License.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>DockPeek captures window thumbnails for previews when you hover over Dock icons.</string>
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS_DIR/Info.plist"

# ---------------------------------------------------------------------------
# 4. PkgInfo: 必须恰好是 APPL???? 且不带结尾换行
# ---------------------------------------------------------------------------
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

# ---------------------------------------------------------------------------
# 5. Ad-hoc 签名
#    重新构建会改变代码哈希，macOS 可能再次弹出
#    「屏幕录制」/「辅助功能」权限请求 —— 这是预期行为。
# ---------------------------------------------------------------------------
if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
    echo "==> 已完成 ad-hoc 签名 (identifier: $BUNDLE_ID)"
else
    echo "==> 未找到 codesign，跳过签名"
fi

# ---------------------------------------------------------------------------
# 6. 中文汇总
# ---------------------------------------------------------------------------
BIN_SIZE_BYTES="$(stat -f%z "$MACOS_DIR/$APP_NAME")"
BIN_SIZE_HUMAN="$(awk -v b="$BIN_SIZE_BYTES" 'BEGIN { printf "%.1f MB", b / 1048576 }')"

echo ""
echo "✅ 构建完成"
echo "   Bundle 路径 : $APP_DIR"
echo "   版本        : ${VERSION}（构建于 ${BUILD_STAMP}）"
echo "   可执行文件  : $MACOS_DIR/$APP_NAME (${BIN_SIZE_HUMAN} / ${BIN_SIZE_BYTES} 字节)"
if [[ -f "$RESOURCES_DIR/AppIcon.icns" ]]; then
    echo "   图标        : $RESOURCES_DIR/AppIcon.icns"
else
    echo "   图标        : 无"
fi
echo ""
echo "下一步运行:"
echo "   open \"$APP_DIR\""
