#!/bin/bash
# 打一个别人能直接安装的版本：正式签名 → 做 DMG → 苹果公证 → 盖章。
#
# 一次性准备（需要苹果开发者账号，99 美元/年）：
#   1. 在 Xcode → Settings → Accounts 里创建 "Developer ID Application" 证书
#   2. 保存公证凭据：xcrun notarytool store-credentials menubarmijia-notary \
#        --apple-id 你的AppleID --team-id 你的TeamID --password App专用密码
#
# 用法：
#   DEVELOPER_ID="Developer ID Application: 你的名字 (TEAMID)" bash scripts/release.sh
#   可选：NOTARY_PROFILE=menubarmijia-notary（默认值）；SKIP_NOTARIZE=1 只签名不公证
#   可选：MACOS_CERT_SHA1=<40 位十六进制>（不传则从钥匙串按签名身份反查）
#   若不传 DEVELOPER_ID，脚本会自动在钥匙串中查找 "Developer ID Application:" 证书。
#
# 发布包必须同时具备固定的签名身份与证书 SHA-1 pin：App 会把 pin 写进 Info.plist，
# 应用内更新据此钉住代码签名证书（ADR-0005）。拿不到身份或 pin 时脚本直接失败，
# 不会产出“能装但永远收不到更新”的包。仅本机自用请直接跑 scripts/build_app.sh。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -z "${DEVELOPER_ID:-}" ]; then
    AUTO_DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -n 1 | tr -d '"' || true)"
    DEVELOPER_ID="${AUTO_DEV_ID:--}"
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-menubarmijia-notary}"
VERSION="$(tr -d '[:space:]' < VERSION)"
APP="$ROOT/MenuBarMijia.app"
DIST="$ROOT/dist"
DMG="$DIST/MenuBarMijia-$VERSION.dmg"

echo "▶ [0/5] 运行门禁检查与 Release 模式单元测试..."
bash scripts/check.sh --lint-only
swift test -c release

# 发布包必须带上正确的 40 位证书 SHA-1。缺失或无效时应用内更新会失败关闭。
if [ "$DEVELOPER_ID" = "-" ]; then
    echo "❌ 未找到代码签名身份：发布包必须用固定证书签名，并钉住证书 SHA-1（更新校验依赖它）。" >&2
    echo "   请用 DEVELOPER_ID=\"Developer ID Application: ...\" 或导入证书后重跑；仅本机自用请直接调用 scripts/build_app.sh。" >&2
    exit 1
fi
MACOS_CERT_SHA1="$(printf '%s' "${MACOS_CERT_SHA1:-}" | tr 'A-F' 'a-f')"
if ! printf '%s' "$MACOS_CERT_SHA1" | grep -Eq '^[0-9a-f]{40}$'; then
    # 与 build_app.sh 相同的反查顺序：先按签名身份查 identity，再退回到证书指纹。
    MACOS_CERT_SHA1="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -v id="$DEVELOPER_ID" 'index($0, id) { print $2; exit }' \
        | tr 'A-F' 'a-f' || true)"
    if ! printf '%s' "$MACOS_CERT_SHA1" | grep -Eq '^[0-9a-f]{40}$'; then
        MACOS_CERT_SHA1="$(security find-certificate -c "$DEVELOPER_ID" -p 2>/dev/null \
            | openssl x509 -noout -fingerprint -sha1 2>/dev/null \
            | sed 's/^.*=//' | tr -d ':' | tr 'A-F' 'a-f' || true)"
    fi
fi
if ! printf '%s' "$MACOS_CERT_SHA1" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "❌ 无法确定签名证书 SHA-1（当前：${MACOS_CERT_SHA1:-<空>}）；发布流程不会产出没有 pin 的包。" >&2
    echo "   请显式传入 MACOS_CERT_SHA1=<40 位十六进制>，或确认钥匙串里有可用的开发者证书。" >&2
    exit 1
fi

echo "▶ [1/5] 编译并签名 MenuBarMijia $VERSION (SIGN_IDENTITY=$DEVELOPER_ID, CERT_SHA1=$MACOS_CERT_SHA1)"
MACOS_CERT_SHA1="$MACOS_CERT_SHA1" SIGN_IDENTITY="$DEVELOPER_ID" bash scripts/build_app.sh
codesign --verify --strict --verbose=2 "$APP"

PINNED="$(/usr/libexec/PlistBuddy -c "Print :MijiaCodeSignCertSHA1" "$APP/Contents/Info.plist" 2>/dev/null || true)"
if ! printf '%s' "$PINNED" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "❌ 打包后的 App 缺少有效的 MijiaCodeSignCertSHA1（当前：${PINNED:-<空>}），更新校验会拒绝所有后续版本。" >&2
    exit 1
fi
if [ "$PINNED" != "$MACOS_CERT_SHA1" ]; then
    echo "❌ App 内钉住的证书 SHA-1（$PINNED）与本次签名证书（$MACOS_CERT_SHA1）不一致。" >&2
    exit 1
fi

echo "▶ [2/5] 制作 DMG（含「应用程序」快捷方式，拖进去就装好）"
rm -rf "$DIST" && mkdir -p "$DIST/stage"
cp -R "$APP" "$DIST/stage/"
ln -s /Applications "$DIST/stage/Applications"
hdiutil create -volname "MenuBarMijia $VERSION" -srcfolder "$DIST/stage" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DIST/stage"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    codesign --force --sign "$DEVELOPER_ID" "$DMG"
    echo "ℹ️  已生成本地签名 DMG（SKIP_NOTARIZE=1，未提交公证；其他用户首次打开可在「隐私与安全性」点「仍要打开」或执行 xattr -cr /Applications/MenuBarMijia.app）。"
else
    codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
    echo "▶ [3/5] 提交苹果公证（通常 1–5 分钟）"
    if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
        xcrun notarytool submit "$DMG" \
            --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_APP_PASSWORD" \
            --wait
    else
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    fi

    echo "▶ [4/5] 盖章（离线也能通过系统检查）"
    xcrun stapler staple "$DMG"
    spctl -a -t open --context context:primary-signature -v "$DMG" || true
fi

echo "▶ [5/5] 最终检查"
for file in "$APP/Contents/MacOS/MenuBarMijiaApp" "$DMG"; do
    if grep -aq "/Users/" "$file"; then
        echo "❌ 检测到 $(basename "$file") 内残留本机路径 (/Users/)，已中止发布！" >&2
        grep -aob "/Users/" "$file" | head -n 5 >&2
        exit 1
    fi
done
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")

echo "✅ 完成：$DMG"
echo "   下一步：先人工创建并推送 tag v${VERSION}，再由 .github/workflows/release.yml 统一发布。"
echo "   手动补发时（仅限不存在的附件）：gh release upload v${VERSION} \"$DMG\" \"$DMG.sha256\""
echo "   已发布的 release 不要用 --clobber 覆盖附件；发布流程会拒绝覆盖，请升版本号。"
