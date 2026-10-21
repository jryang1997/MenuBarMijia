#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

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

if search_matches '10\.10\.1\.[0-9]+|4c:ba:d7:c3:e9:9a|localhost:3425' Sources/ Tests/; then
    echo "❌ 检测到硬编码的个人局域网 IP / MAC 或本机调试端口 (localhost:3425)，请移除！"
    exit 1
fi

echo "🔍 [2/4] 检查机械性编码规范 (kVK_* 键码常量 & UNUserNotificationCenter Bundle 守卫)..."
if search_matches 'event\.keyCode[[:space:]]*==[[:space:]]*[0-9]+' Sources/; then
    echo "❌ 请使用 Carbon 的 kVK_* 常量，不要直接比较 event.keyCode 数字字面量！"
    exit 1
fi

for f in $(search_files 'UNUserNotificationCenter\.current\(\)' Sources/ || true); do
    if ! search_quiet 'pathExtension == "app"' "$f"; then
        echo "❌ $f 调用了 UNUserNotificationCenter.current()，但缺少 Bundle.main.bundleURL.pathExtension == \"app\" 守卫（会导致 swift test 崩溃）！"
        exit 1
    fi
done

echo "🧪 [3/4] 运行 Swift 单元测试 (swift test)..."
swift test

echo "✅ [4/4] 所有门禁检查与单元测试全部通过！"
