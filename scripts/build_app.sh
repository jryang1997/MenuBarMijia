#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▶ 正在编译 MenuBarMijiaApp (Release)..."
swift build -c release --product MenuBarMijiaApp

BIN_PATH="$(swift build -c release --show-bin-path)/MenuBarMijiaApp"
APP_DIR="$ROOT/米家控制中心.app"

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

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>米家控制中心</string>
    <key>CFBundleExecutable</key>
    <string>MenuBarMijiaApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.yangzhiyuan.MenuBarMijia</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>米家控制中心</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>用于局域网实时连接群晖 NAS 上的 Home Assistant 控制智能家居设备。</string>
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

codesign --force --deep --sign - "$APP_DIR"
echo "✅ 已打包完成：$APP_DIR"

if [ "$WAS_RUNNING" = "1" ]; then
    open "$APP_DIR"
    echo "🔄 已自动重启米家控制中心.app"
fi
