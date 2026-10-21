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
#   若不传 DEVELOPER_ID，脚本会自动在钥匙串中查找 "Developer ID Application:" 证书。
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

echo "▶ [1/5] 编译并签名 MenuBarMijia $VERSION (SIGN_IDENTITY=$DEVELOPER_ID)"
SIGN_IDENTITY="$DEVELOPER_ID" bash scripts/build_app.sh
codesign --verify --strict --verbose=2 "$APP"

echo "▶ [2/5] 制作 DMG（含「应用程序」快捷方式，拖进去就装好）"
rm -rf "$DIST" && mkdir -p "$DIST/stage"
cp -R "$APP" "$DIST/stage/"
ln -s /Applications "$DIST/stage/Applications"
hdiutil create -volname "MenuBarMijia $VERSION" -srcfolder "$DIST/stage" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DIST/stage"

if [ "$DEVELOPER_ID" = "-" ] || [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    codesign --force --sign "$DEVELOPER_ID" "$DMG"
    echo "ℹ️  已生成本地签名 DMG（未检测到 Developer ID Application 证书或已设置 SKIP_NOTARIZE=1；其他用户首次打开可在「隐私与安全性」点「仍要打开」或执行 xattr -cr /Applications/MenuBarMijia.app）。"
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
shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo "✅ 完成：$DMG"
echo "   发布：gh release upload v${VERSION} \"$DMG\" \"$DMG.sha256\" --clobber"
