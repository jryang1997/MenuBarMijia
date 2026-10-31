#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -d "$ROOT/.git/hooks" ] && [ ! -e "$ROOT/.git/hooks/pre-commit" ]; then
    ln -s ../../scripts/check.sh "$ROOT/.git/hooks/pre-commit" 2>/dev/null || true
fi

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || echo 1.0.0)"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
# 留空 =优先使用本机钥匙串中的 "MenuBarMijia Release Signing" 固定签名证书（支持应用内自更新），
# 找不到时退回本机临时 ad-hoc 签名；发布或 CI 可显式传入：
#   MACOS_SIGNING_IDENTITY  codesign 身份名称（CI secret 导入后自动填）
#   MACOS_CERT_SHA1         该证书的 SHA-1（40 位十六进制），会写进 Info.plist 供更新校验钉住
# SIGN_IDENTITY 为旧调用方式（scripts/release.sh）保留。
DEFAULT_RELEASE_SIGN_IDENTITY="MenuBarMijia Release Signing"
if [ -z "${MACOS_SIGNING_IDENTITY:-}" ] && [ -z "${SIGN_IDENTITY:-}" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$DEFAULT_RELEASE_SIGN_IDENTITY\""; then
        SIGN_IDENTITY="$DEFAULT_RELEASE_SIGN_IDENTITY"
    else
        SIGN_IDENTITY="-"
    fi
else
    SIGN_IDENTITY="${MACOS_SIGNING_IDENTITY:-${SIGN_IDENTITY:--}}"
fi
MACOS_CERT_SHA1="$(printf '%s' "${MACOS_CERT_SHA1:-}" | tr 'A-F' 'a-f')"
if [ "$SIGN_IDENTITY" != "-" ] && [ -z "$MACOS_CERT_SHA1" ]; then
    MACOS_CERT_SHA1="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -v id="$SIGN_IDENTITY" 'index($0, id) { print $2; exit }' \
        | tr 'A-F' 'a-f' || true)"
fi
if [ "$SIGN_IDENTITY" != "-" ] && [ -z "$MACOS_CERT_SHA1" ]; then
    MACOS_CERT_SHA1="$(security find-certificate -c "$SIGN_IDENTITY" -p 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha1 2>/dev/null \
        | sed 's/^.*=//' \
        | tr -d ':' \
        | tr 'A-F' 'a-f' || true)"
fi
if [ "$SIGN_IDENTITY" != "-" ] && [ -z "$MACOS_CERT_SHA1" ]; then
    echo "❌ 无法确定签名证书 SHA-1，已停止打包；应用内更新必须钉住签名身份。" >&2
    exit 1
fi
if [ -n "$MACOS_CERT_SHA1" ] && ! printf '%s' "$MACOS_CERT_SHA1" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "❌ MACOS_CERT_SHA1 必须是 40 位十六进制证书 SHA-1" >&2
    exit 1
fi

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
cp "$ROOT/Resources/AppIcon/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/AppIcon/AppIcon-Dark.icns" "$APP_DIR/Contents/Resources/AppIcon-Dark.icns"
cp "$ROOT/Resources/AppIcon/AppIcon-Light.icns" "$APP_DIR/Contents/Resources/AppIcon-Light.icns"
cp "$ROOT/Resources/AppIcon/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"
RESOURCE_BUNDLE="$(dirname "$BIN_PATH")/MenuBarMijia_MijiaCore.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "❌ 缺少本地化资源包 MenuBarMijia_MijiaCore.bundle" >&2
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/MenuBarMijia_MijiaCore.bundle"

GO2RTC_CACHED="$HOME/Library/Application Support/MenuBarMijia/bin/go2rtc"
if [ -x "$GO2RTC_CACHED" ]; then
    mkdir -p "$APP_DIR/Contents/Resources/bin"
    cp "$GO2RTC_CACHED" "$APP_DIR/Contents/Resources/bin/go2rtc"
    chmod +x "$APP_DIR/Contents/Resources/bin/go2rtc"
fi

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/MenuBarMijiaApp"
chmod +x "$APP_DIR/Contents/MacOS/MenuBarMijiaApp"
strip -S -x "$APP_DIR/Contents/MacOS/MenuBarMijiaApp"
if ! SYMBOL_TABLE="$(nm -ap "$APP_DIR/Contents/MacOS/MenuBarMijiaApp")"; then
    echo "❌ 无法读取 MenuBarMijiaApp 符号表，不能确认发布包是否泄露本机路径。" >&2
    exit 1
fi
LEAKED_SYMBOLS="$(printf '%s\n' "$SYMBOL_TABLE" | grep "/Users/" || true)"
if [ -n "$LEAKED_SYMBOLS" ]; then
    echo "❌ MenuBarMijiaApp 符号表中仍残留本地编译路径 (/Users/)！"
    printf '%s\n' "$LEAKED_SYMBOLS" | head -n 5 >&2
    exit 1
fi
if grep -aq "/Users/" "$APP_DIR/Contents/MacOS/MenuBarMijiaApp"; then
    echo "❌ MenuBarMijiaApp 二进制中仍残留本地编译路径 (/Users/)！" >&2
    grep -aob "/Users/" "$APP_DIR/Contents/MacOS/MenuBarMijiaApp" | head -n 5 >&2
    exit 1
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>CFBundleDisplayName</key>
    <string>MenuBarMijia</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>MenuBarMijiaApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.jryang1997.MenuBarMijia</string>
    <!-- #57 External URL Scheme: menumijia://toggle?device=…, scene?name=…, ask?text=…
         App Intents themselves need Metadata.appintents, which Xcode's
         appintentsmetadataprocessor emits; SwiftPM does not produce the compiler's const-value
         side outputs, so Shortcuts discovery may require an Xcode-project build. The URL Scheme
         and in-app execution are unaffected. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.jryang1997.MenuBarMijia.external</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>menumijia</string>
            </array>
        </dict>
    </array>
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
    <string>14.0</string>
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

mkdir -p "$APP_DIR/Contents/Resources/zh-Hans.lproj"
cat > "$APP_DIR/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<'STRINGS_ZH'
"NSLocalNetworkUsageDescription" = "用于局域网自动发现并实时连接 Home Assistant 及电视等智能家居设备。";
"NSMicrophoneUsageDescription" = "用于通过语音指令直接控制米家智能家居设备。";
"NSSpeechRecognitionUsageDescription" = "用于将您的语音指令实时识别为智能家居控制动作。";
STRINGS_ZH

mkdir -p "$APP_DIR/Contents/Resources/en.lproj"
cat > "$APP_DIR/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS_EN'
"NSLocalNetworkUsageDescription" = "Used to automatically discover and connect to Home Assistant and smart TVs on your local network.";
"NSMicrophoneUsageDescription" = "Used to control your Xiaomi Home smart devices with voice commands.";
"NSSpeechRecognitionUsageDescription" = "Used to transcribe your voice commands into smart home actions in real time.";
STRINGS_EN

# SwiftPM executable targets emit const values through Xcode but do not run the app metadata
# extraction phase. Build those values with Xcode, then process them before signing the bundle.
APP_INTENTS_MODULE="MenuBarMijiaApp"
APP_INTENTS_BUNDLE_ID="com.jryang1997.MenuBarMijia"
APP_INTENTS_DEPLOYMENT_TARGET="14.0"

# Xcode writes `extract.actionsdata` directly into `--output`; accept either that layout or a
# nested Metadata.appintents so both the processor and xcodebuild outputs can be harvested.
app_intents_bundle_dir() {
    local candidate="$1"
    if [ -f "$candidate/extract.actionsdata" ]; then
        printf '%s\n' "$candidate"
    elif [ -f "$candidate/Metadata.appintents/extract.actionsdata" ]; then
        printf '%s\n' "$candidate/Metadata.appintents"
    fi
}

generate_app_intents_metadata_via_xcode() {
    # Xcode's build graph requests const values itself and runs ExtractAppIntentsMetadata per target.
    local derived="$ROOT/.build/appintents-derived"
    command -v xcodebuild >/dev/null 2>&1 || return 1
    rm -rf "$derived"
    mkdir -p "$derived"

    # SwiftPM exposes one scheme per product; consult the list instead of assuming a name.
    local listing name
    local -a candidates=()
    listing="$(xcodebuild -list -json -derivedDataPath "$derived" 2>/dev/null || true)"
    while IFS= read -r name; do
        [ -n "$name" ] && candidates+=("$name")
    done < <(printf '%s' "$listing" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    candidates+=("$APP_INTENTS_MODULE")

    local built=0 scheme
    # macOS ships bash 3.2, where expanding an empty array under `set -u` is an error.
    for scheme in "${candidates[@]+"${candidates[@]}"}"; do
        case "$scheme" in
        *"$APP_INTENTS_MODULE"*) ;;
        *) continue ;;
        esac
        if xcodebuild \
            -scheme "$scheme" \
            -destination 'platform=macOS' \
            -configuration Release \
            -derivedDataPath "$derived" \
            build >"$ROOT/.build/appintents-build.log" 2>&1; then
            built=1
            break
        fi
    done
    if [ "$built" = "0" ]; then
        echo "   （xcodebuild 未能构建含 $APP_INTENTS_MODULE 的 scheme；可用 xcodebuild -list 查看）" >&2
        tail -n 40 "$ROOT/.build/appintents-build.log" >&2
        return 1
    fi

    local bundle
    bundle="$(app_intents_bundle_dir "$derived/Build/Products/Release/$APP_INTENTS_MODULE.appintents")"
    if [ -z "$bundle" ]; then
        local developer_dir toolchain sdk_root xcode_version
        developer_dir="$(xcode-select -p)"
        toolchain="$developer_dir/Toolchains/XcodeDefault.xctoolchain"
        sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
        xcode_version="$(xcodebuild -version | awk '/Build/ {print $3; exit}')"
        find "$derived" -path "*/${APP_INTENTS_MODULE}*.build/*" -name '*.swiftconstvalues' > "$derived/constvals.txt"
        find "$ROOT/Sources/$APP_INTENTS_MODULE" -name '*.swift' > "$derived/sources.txt"
        if [ ! -s "$derived/constvals.txt" ]; then
            echo "❌ Xcode 构建未产生 ${APP_INTENTS_MODULE} 的 swiftconstvalues，构建日志：$ROOT/.build/appintents-build.log" >&2
            find "$derived" -name '*.swiftconstvalues' >&2
            return 1
        fi
        "$toolchain/usr/bin/appintentsmetadataprocessor" \
            --toolchain-dir "$toolchain" \
            --module-name "$APP_INTENTS_MODULE" \
            --sdk-root "$sdk_root" \
            --xcode-version "$xcode_version" \
            --platform-family macOS \
            --deployment-target "$APP_INTENTS_DEPLOYMENT_TARGET" \
            --bundle-identifier "$APP_INTENTS_BUNDLE_ID" \
            --output "$derived/metadata" \
            --target-triple "$(uname -m)-apple-macos${APP_INTENTS_DEPLOYMENT_TARGET}" \
            --binary-file "$derived/Build/Products/Release/$APP_INTENTS_MODULE" \
            --source-file-list "$derived/sources.txt" \
            --swift-const-vals-list "$derived/constvals.txt" \
            --force --compile-time-extraction --no-app-shortcuts-localization || return 1
        bundle="$(app_intents_bundle_dir "$derived/metadata")"
        [ -n "$bundle" ] || return 1
    fi
    rm -rf "$APP_DIR/Contents/Resources/Metadata.appintents"
    cp -R "$bundle" "$APP_DIR/Contents/Resources/Metadata.appintents"
    rm -rf "$derived"
    return 0
}

generate_app_intents_metadata() {
    local resources="$APP_DIR/Contents/Resources/Metadata.appintents"
    rm -rf "$resources"

    if [ "${SKIP_APP_INTENTS:-0}" = "1" ] && [ "$SIGN_IDENTITY" = "-" ]; then
        echo "⚠️ 已跳过 App Intents 元数据生成（SKIP_APP_INTENTS=1，仅限本机 ad-hoc 自用）"
        return 0
    fi

    if [ ! -f "$resources/extract.actionsdata" ]; then
        echo "ℹ️ 生成 App Intents 元数据（xcodebuild ExtractAppIntentsMetadata）..."
        if ! generate_app_intents_metadata_via_xcode; then
            echo "❌ 无法生成 App Intents 元数据（Metadata.appintents）。" >&2
            echo "   缺了它，快捷指令 / Siri / Spotlight 看不到任何动作，属于 #57 的交付缺失，已中止打包。" >&2
            echo "   排查：xcode-select -p 必须指向完整 Xcode；xcodebuild -list 应列出 ${APP_INTENTS_MODULE}。" >&2
            echo "   （若仅本机自用且只安装了 Command Line Tools，可运行 SKIP_APP_INTENTS=1 bash scripts/build_app.sh 跳过）" >&2
            exit 1
        fi
    fi

    if [ ! -f "$resources/extract.actionsdata" ]; then
        echo "❌ 元数据目录缺少 extract.actionsdata，动作不会被系统注册，已中止打包。" >&2
        exit 1
    fi

    echo "🧩 已嵌入 App Intents 元数据：$(du -h "$resources/extract.actionsdata" | awk '{print $1}') extract.actionsdata（快捷指令 / Siri 可发现）"
}
generate_app_intents_metadata

if [ -n "$MACOS_CERT_SHA1" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    /usr/libexec/PlistBuddy -c "Delete :MijiaCodeSignCertSHA1" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :MijiaCodeSignCertSHA1 string $MACOS_CERT_SHA1" "$APP_DIR/Contents/Info.plist"
    echo "🔏 已钉住代码签名证书 SHA-1：$MACOS_CERT_SHA1"
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "⚠️ 未设置 MACOS_SIGNING_IDENTITY：使用 ad-hoc 签名，仅适合本机运行，应用内更新已禁用；发布包必须用固定证书签名。"
    if [ -f "$APP_DIR/Contents/Resources/bin/go2rtc" ]; then
        codesign --force --sign - "$APP_DIR/Contents/Resources/bin/go2rtc"
    fi
    codesign --force --sign - "$APP_DIR"
else
    # 正式签名：开启 Hardened Runtime（苹果公证的前提），并声明麦克风权限。
    # 只有 Apple 签发的证书才向苹果申请时间戳；自签名证书没有 Apple 信任链，申请会失败。
    CODESIGN_ARGS=(--force --options runtime)
    if security find-certificate -c "$SIGN_IDENTITY" -p 2>/dev/null \
        | openssl x509 -noout -issuer 2>/dev/null \
        | grep -q "Apple"; then
        CODESIGN_ARGS+=(--timestamp)
    fi
    if [ -f "$APP_DIR/Contents/Resources/bin/go2rtc" ]; then
        codesign "${CODESIGN_ARGS[@]}" --sign "$SIGN_IDENTITY" "$APP_DIR/Contents/Resources/bin/go2rtc"
    fi
    codesign "${CODESIGN_ARGS[@]}" \
        --entitlements "$ROOT/scripts/MenuBarMijia.entitlements" \
        --sign "$SIGN_IDENTITY" "$APP_DIR"
fi
echo "✅ 已打包完成：$APP_DIR"

if [ "$WAS_RUNNING" = "1" ]; then
    open "$APP_DIR"
    echo "🔄 已自动重启 MenuBarMijia.app"
fi
