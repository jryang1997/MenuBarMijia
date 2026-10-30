#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT_DIR"

if [ -d "$ROOT_DIR/.git/hooks" ] && [ ! -e "$ROOT_DIR/.git/hooks/pre-commit" ]; then
    ln -s ../../scripts/check.sh "$ROOT_DIR/.git/hooks/pre-commit" 2>/dev/null || true
fi

search_matches() {
    local pattern="$1"
    shift
    if command -v rg >/dev/null 2>&1; then
        rg -n "$pattern" "$@"
    else
        grep -rnE "$pattern" "$@"
    fi
}

search_quiet() {
    local pattern="$1"
    shift
    if command -v rg >/dev/null 2>&1; then
        rg -q "$pattern" "$@"
    else
        grep -qE "$pattern" "$@"
    fi
}

search_files() {
    local pattern="$1"
    shift
    if command -v rg >/dev/null 2>&1; then
        rg -l "$pattern" "$@"
    else
        grep -rlE "$pattern" "$@"
    fi
}

echo "🔍 [1/4] 检查是否存在硬编码 JWT / 密钥 / 个人局域网地址泄露..."
if search_matches 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' Sources/ Tests/; then
    echo "❌ 检测到疑似 JWT Token，请移除后再提交！"
    exit 1
fi

if ! search_quiet 'defaultSeededToken = ""' Sources/MijiaCore/KeychainAndPrefs.swift; then
    echo "❌ KeychainAndPrefs.swift 中的 defaultSeededToken 必须为空字符串！"
    exit 1
fi

if ! search_quiet 'defaultHost = ""' Sources/MijiaCore/LGWebOSClient.swift; then
    echo "❌ LGWebOSClient.swift 中的 defaultHost 必须为空字符串！"
    exit 1
fi

if search_matches '10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' Sources/ Tests/ || search_matches 'localhost:3425' Sources/; then
    echo "❌ 检测到硬编码的个人局域网 IP 或本机调试端口 (localhost:3425)，请移除！"
    exit 1
fi

echo "🔍 [2/4] 检查机械性编码规范 (kVK_* 键码常量 & UNUserNotificationCenter Bundle 守卫)..."
if search_matches 'event\.keyCode[[:space:]]*==[[:space:]]*[0-9]+' Sources/; then
    echo "❌ 请使用 Carbon 的 kVK_* 常量，不要直接比较 event.keyCode 数字字面量！"
    exit 1
fi

for f in $(search_files 'UNUserNotificationCenter\.current\(\)' Sources || true); do
    if ! search_quiet 'pathExtension == "app"' "$f"; then
        echo "❌ $f 调用了 UNUserNotificationCenter.current()，但缺少 Bundle.main.bundleURL.pathExtension == \"app\" 守卫（会导致 swift test 崩溃）！"
        exit 1
    fi
done

for f in $(search_files '\.glassEffect\(|GlassEffectContainer' Sources || true); do
    if [ "$f" != "Sources/MenuBarMijiaApp/ThemeAndMotion.swift" ]; then
        echo "❌ $f 直接使用了 macOS 26 专属的 .glassEffect 或 GlassEffectContainer，请改用 ThemeAndMotion.swift 中的 adaptiveGlass / AdaptiveGlassContainer 以保持 macOS 14+ 兼容！"
        exit 1
    fi
done

if command -v rg >/dev/null 2>&1; then
    if rg -nU 'return \([^;{}]*\bawait\b' Sources; then
        echo "❌ 请勿在 return 元组字面量内直接内联 await（Swift 6.4 -O 协程分片优化会消除元组首字段写入导致 EXC_BAD_ACCESS），请先用 let 变量接收 await 结果再构造返回值！"
        exit 1
    fi
elif search_matches 'return \([^)]*\bawait\b' Sources; then
    echo "❌ 请勿在 return 元组字面量内直接内联 await（Swift 6.4 -O 协程分片优化会消除元组首字段写入导致 EXC_BAD_ACCESS），请先用 let 变量接收 await 结果再构造返回值！"
    exit 1
fi

if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout docs/assets/*.svg Resources/AppIcon/*.svg
elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, xml.etree.ElementTree as ET; [ET.parse(f) for f in sys.argv[1:]]' docs/assets/*.svg Resources/AppIcon/*.svg
fi

if ! cmp -s Resources/AppIcon/AppIcon-Dark.svg docs/assets/logo-dark.svg || ! cmp -s Resources/AppIcon/AppIcon-Light.svg docs/assets/logo-light.svg; then
    echo "❌ docs/assets/logo-{dark,light}.svg 与 Resources/AppIcon/AppIcon-{Dark,Light}.svg 不一致，请运行 swift scripts/generate_app_icon.swift 同步！"
    exit 1
fi

python3 scripts/check_design_tokens.py

if [ "${1:-}" = "--lint-only" ]; then
    echo "✅ 密钥与机械性编码规范检查通过！"
    exit 0
fi

echo "🧪 [3/4] 运行 Swift 单元测试 (swift test) 与双端黄金语料校验..."
swift test
if [ -x "windows/node_modules/.bin/tsx" ]; then
    (cd windows && npm test && npm run typecheck)
fi

echo "✅ [4/4] 所有门禁检查与单元测试全部通过！"
