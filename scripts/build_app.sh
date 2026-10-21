#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || echo 1.0.0)"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
# 留空 = 本机临时签名（只能自己用）；发布时由 scripts/release.sh 传入 "Developer ID Application: …"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "▶ 正在编译 MenuBarMijiaApp $VERSION (Release)..."
swift build -c release --product MenuBarMijiaApp

BIN_PATH="$(swift build -c release --show-bin-path)/MenuBarMijiaApp"
APP_DIR="$ROOT/MenuBarMijia.app"
rm -rf "$ROOT/米家控制中心.app" "$ROOT/MenuMijia.app"  # 清理旧名字产物

WAS_RUNNING=0
if pgrep -x MenuBarMijiaApp >/dev/null 2>&1; then
    WAS_RUNNING=1
    killall MenuBarMijiaApp 2>/dev/null || true
    sleep 0.5
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/MenuBarMijiaApp"
chmod +x "$APP_DIR/Contents/MacOS/MenuBarMijiaApp"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>MenuBarMijia</string>
    <key>CFBundleExecutable</key>
    <string>MenuBarMijiaApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.yangzhiyuan.MenuBarMijia</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MenuBarMijia</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>用于局域网自动发现并实时连接 Home Assistant 及电视等智能家居设备。</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_home-assistant._tcp</string>
    </array>
    <key>NSMicrophoneUsageDescription</key>
    <string>用于通过语音指令直接控制米家智能家居设备。</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>用于将您的中文语音指令实时识别为智能家居控制动作。</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP_DIR"
else
    # 正式签名：开启 Hardened Runtime（苹果公证的前提），并声明麦克风权限
    codesign --force --options runtime --timestamp \
        --entitlements "$ROOT/scripts/MenuBarMijia.entitlements" \
        --sign "$SIGN_IDENTITY" "$APP_DIR"
fi
echo "✅ 已打包完成：$APP_DIR"

if [ "$WAS_RUNNING" = "1" ]; then
    open "$APP_DIR"
    echo "🔄 已自动重启 MenuBarMijia.app"
fi
