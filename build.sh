#!/bin/bash
# SnapTool 构建脚本：编译 Swift 源码并打包成 .app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/SnapTool.app"
NAME="SnapTool"

echo "==> 清理旧构建"
rm -rf "$ROOT/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 (swiftc)"
swiftc \
  -swift-version 5 \
  -O \
  -target arm64-apple-macosx13.0 \
  -framework Cocoa \
  -framework Carbon \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  -o "$APP/Contents/MacOS/$NAME" \
  "$ROOT"/Sources/*.swift

echo "==> 写入 Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>com.fengyu.snaptool</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>截图小工具</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>SnapTool</string>
</dict>
</plist>
PLIST

echo "==> 写入 PkgInfo"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 临时签名 (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (签名跳过，不影响本机运行)"

echo "==> 完成: $APP"
