#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

echo "🔍 [1/4] 检查是否存在硬编码 JWT / 密钥泄露..."
if rg -n 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' Sources/ Tests/; then
    echo "❌ 检测到疑似 JWT Token，请移除后再提交！"
    exit 1
fi

if ! rg -q 'defaultSeededToken = ""' Sources/MijiaCore/KeychainAndPrefs.swift; then
    echo "❌ KeychainAndPrefs.swift 中的 defaultSeededToken 必须为空字符串！"
    exit 1
fi

echo "🔍 [2/4] 检查机械性编码规范 (kVK_* 键码常量 & UNUserNotificationCenter Bundle 守卫)..."
if rg -n 'event\.keyCode\s*==\s*[0-9]+' Sources/; then
    echo "❌ 请使用 Carbon 的 kVK_* 常量，不要直接比较 event.keyCode 数字字面量！"
    exit 1
fi

for f in $(rg -l 'UNUserNotificationCenter\.current\(\)' Sources/ || true); do
    if ! rg -q 'pathExtension == "app"' "$f"; then
        echo "❌ $f 调用了 UNUserNotificationCenter.current()，但缺少 Bundle.main.bundleURL.pathExtension == \"app\" 守卫（会导致 swift test 崩溃）！"
        exit 1
    fi
done

echo "🧪 [3/4] 运行 Swift 单元测试 (swift test)..."
swift test

echo "✅ [4/4] 所有门禁检查与单元测试全部通过！"
