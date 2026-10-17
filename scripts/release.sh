#!/bin/bash
# 打一个别人能直接安装的版本：正式签名 → 做 DMG → 苹果公证 → 盖章。
#
# 一次性准备（需要苹果开发者账号，99 美元/年）：
#   1. 在 Xcode → Settings → Accounts 里创建 "Developer ID Application" 证书
#   2. 保存公证凭据：xcrun notarytool store-credentials menumijia-notary \
#        --apple-id 你的AppleID --team-id 你的TeamID --password App专用密码
#
# 用法：
#   DEVELOPER_ID="Developer ID Application: 你的名字 (TEAMID)" bash scripts/release.sh
#   可选：NOTARY_PROFILE=menumijia-notary（默认值）；SKIP_NOTARIZE=1 只签名不公证
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEVELOPER_ID="${DEVELOPER_ID:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-menumijia-notary}"
VERSION="$(tr -d '[:space:]' < VERSION)"
APP="$ROOT/MenuMijia.app"
DIST="$ROOT/dist"
DMG="$DIST/MenuMijia-$VERSION.dmg"

echo "▶ [1/5] 编译并签名 MenuMijia $VERSION (SIGN_IDENTITY=$DEVELOPER_ID)"
SIGN_IDENTITY="$DEVELOPER_ID" bash scripts/build_app.sh
codesign --verify --strict --verbose=2 "$APP"

echo "▶ [2/5] 制作 DMG（含「应用程序」快捷方式，拖进去就装好）"
rm -rf "$DIST" && mkdir -p "$DIST/stage"
cp -R "$APP" "$DIST/stage/"
ln -s /Applications "$DIST/stage/Applications"
hdiutil create -volname "MenuMijia $VERSION" -srcfolder "$DIST/stage" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DIST/stage"

if [ "$DEVELOPER_ID" = "-" ] || [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    codesign --force --sign "$DEVELOPER_ID" "$DMG"
    echo "ℹ️  已生成本地签名 DMG（未使用付费 Developer ID 公证；其他用户首次打开可在「隐私与安全性」点「仍要打开」或执行 xattr -cr /Applications/MenuMijia.app）。"
else
    codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
    echo "▶ [3/5] 提交苹果公证（通常 1–5 分钟）"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

    echo "▶ [4/5] 盖章（离线也能通过系统检查）"
    xcrun stapler staple "$DMG"
fi

echo "▶ [5/5] 最终检查"
shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo "✅ 完成：$DMG"
echo "   发布：在 GitHub 新建 Release，标签填 v${VERSION}，上传这个 DMG。App 里的「检查更新」会读到它。"
