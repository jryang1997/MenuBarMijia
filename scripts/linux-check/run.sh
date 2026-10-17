#!/bin/bash
# 在 Linux（无 Xcode）上编译并测试 MijiaCore。macOS 上请直接用 scripts/check.sh。
# 做法：把 Sources/MijiaCore 和测试复制到 .work/，只注入 FoundationNetworking 导入、去掉 Linux 没有的 waitsForConnectivity。
set -euo pipefail
L="$(cd "$(dirname "$0")" && pwd)"; R="$(cd "$L/../.." && pwd)"
rm -rf "$L/.work"; mkdir -p "$L/.work"
cp -r "$R/Sources/MijiaCore" "$L/.work/MijiaCore"; cp -r "$R/Tests/MijiaCoreTests" "$L/.work/MijiaCoreTests"
find "$L/.work" -name '*.swift' -exec sed -i -e '1i #if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif' -e '/waitsForConnectivity = /d' {} \;
cd "$L"; TZ="${TZ:-Asia/Shanghai}" swift test "$@"
