#!/usr/bin/env bash
# 发布门禁（#32）：校验标签/版本/提交，以及两端发布附件是否完整。
#
# 用法：
#   scripts/check_release.sh tag <tag>              # 校验 VERSION、tag、HEAD 与 Windows 版本元数据
#   scripts/check_release.sh assets <version> <dir> # 校验 9 个附件、SHA-256 与 Ed25519 签名
#
# `tag` 在 GitHub Actions 中会把 version/tag/commit 写入 $GITHUB_OUTPUT。
# `assets` 需要 openssl（Ed25519 校验）与 python3；发布工作流在 ubuntu-latest 上执行。
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
    echo "❌ $*" >&2
    exit 1
}

info() {
    echo "▶ $*"
}

usage() {
    cat >&2 <<'EOF'
用法：
  scripts/check_release.sh tag <tag>
  scripts/check_release.sh assets <version> <附件目录>
  scripts/check_release.sh draft-assets <version> <附件目录>
  scripts/check_release.sh notes <输入.md> <输出.md> <version> <signed:true|false>

tag 必须等于 VERSION 加 v 前缀（例如 VERSION=1.0.6 → v1.0.6），并且指向当前 HEAD。
assets 只接受 MenuBarMijia-<version>.dmg / .dmg.sha256 / .dmg.ed25519.sig、
MenuBarMijia-<version>-windows-x64-setup.exe / .exe.sha256 / .exe.ed25519.sig 与
MenuBarMijia-<version>-windows-x64.msi / .msi.sha256 / .msi.ed25519.sig 这 9 个文件。
draft-assets 接受同样的 9 个文件去掉 3 个 .ed25519.sig 后的 6 个待签附件，供 CI 产出草稿时自检；
它不做签名校验，发布前仍必须跑 assets（严格 9 个且三份 Ed25519 签名都必须对得上）。
notes 按 Windows 签名状态增删“未签名”段落，重复执行结果一致。
EOF
    exit 2
}

version_file() {
    tr -d '[:space:]' < VERSION
}

json_version() {
    python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
value = data.get("version")
if not isinstance(value, str) or not value.strip():
    raise SystemExit(f"无法读取 {sys.argv[1]} 的 version")
print(value.strip())
PY
}

bundle_targets() {
    python3 - windows/src-tauri/tauri.conf.json <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
bundle = data.get("bundle") or {}
if not bundle.get("active"):
    raise SystemExit(f"{sys.argv[1]} 的 bundle.active 不是 true")
targets = bundle.get("targets")
if not isinstance(targets, list):
    raise SystemExit(f"{sys.argv[1]} 的 bundle.targets 必须是显式列表（当前：{targets!r}）")
print(" ".join(str(t) for t in targets))
PY
}

cargo_package_version() {
    awk '
        /^\[package\]/ { in_package = 1; next }
        /^\[/ { in_package = 0 }
        in_package && /^version[[:space:]]*=/ {
            line = $0
            sub(/^version[[:space:]]*=[[:space:]]*"/, "", line)
            sub(/".*$/, "", line)
            print line
            exit
        }
    ' windows/src-tauri/Cargo.toml
}

if command -v sha256sum >/dev/null 2>&1; then
    HASH_CMD=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
    HASH_CMD=(shasum -a 256)
else
    HASH_CMD=()
fi

TMP_DIR=""
cleanup() {
    if [ -n "${TMP_DIR:-}" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

validate_tag() {
    [ "$#" -eq 1 ] || usage

    local requested="$1"
    case "$requested" in
        refs/tags/*) requested="${requested#refs/tags/}" ;;
    esac

    local version tag head_sha tag_sha
    version="$(version_file)"
    [ -n "$version" ] || fail "VERSION 为空"
    printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
        || fail "VERSION 必须是 x.y.z（当前：$version）"
    tag="v${version}"

    [ "$requested" = "$tag" ] \
        || fail "请求的 tag '$requested' 与 VERSION=$version（应为 $tag）不一致"

    if [ "${GITHUB_EVENT_NAME:-}" = "push" ]; then
        [ "${GITHUB_REF:-}" = "refs/tags/$tag" ] \
            || fail "推送触发的 ref ${GITHUB_REF:-<空>} 不是 refs/tags/$tag"
        [ "${GITHUB_REF_TYPE:-tag}" = "tag" ] \
            || fail "推送触发的 ref 类型不是 tag：${GITHUB_REF_TYPE:-<空>}"
    fi

    command -v git >/dev/null 2>&1 || fail "需要 git 校验标签"
    git rev-parse -q --verify "refs/tags/$tag" >/dev/null \
        || fail "标签 $tag 不存在；发布工作流不会创建标签，请先人工创建并推送"
    head_sha="$(git rev-parse HEAD)"
    tag_sha="$(git rev-parse "refs/tags/${tag}^{commit}")"
    [ "$head_sha" = "$tag_sha" ] \
        || fail "HEAD $head_sha 不是标签 $tag 指向的提交 $tag_sha"

    command -v python3 >/dev/null 2>&1 || fail "需要 python3 校验版本元数据"
    local conf_version pkg_version cargo_version
    conf_version="$(json_version windows/src-tauri/tauri.conf.json)"
    pkg_version="$(json_version windows/package.json)"
    cargo_version="$(cargo_package_version)"
    [ "$conf_version" = "$version" ] \
        || fail "windows/src-tauri/tauri.conf.json 的版本 $conf_version 与 VERSION=$version 不一致"
    [ "$pkg_version" = "$version" ] \
        || fail "windows/package.json 的版本 $pkg_version 与 VERSION=$version 不一致"
    [ "$cargo_version" = "$version" ] \
        || fail "windows/src-tauri/Cargo.toml 的版本 $cargo_version 与 VERSION=$version 不一致"

    # 发布需要 EXE(NSIS) 与 MSI 两种安装包；targets 被改成别的组合时附件清单必然对不上。
    local targets target has_nsis=0 has_msi=0
    targets="$(bundle_targets)" || fail "无法读取 windows/src-tauri/tauri.conf.json 的 bundle 配置"
    for target in $targets; do
        case "$target" in
            nsis) has_nsis=1 ;;
            msi) has_msi=1 ;;
        esac
    done
    [ "$has_nsis" -eq 1 ] && [ "$has_msi" -eq 1 ] \
        || fail "windows/src-tauri/tauri.conf.json 的 bundle.targets 必须同时包含 nsis 与 msi（当前：$targets）"

    [ -s windows/package-lock.json ] \
        || fail "缺少 windows/package-lock.json；发布构建用 npm ci 安装依赖"

    info "标签与版本校验通过：$tag @ $head_sha"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        {
            echo "version=$version"
            echo "tag=$tag"
            echo "commit=$head_sha"
        } >> "$GITHUB_OUTPUT"
    fi
}

verify_checksum() {
    local dir="$1"
    local asset="$2"
    local sum_file="$dir/$asset.sha256"
    local expected_hash="" expected_name="" actual

    [ "${#HASH_CMD[@]}" -gt 0 ] || fail "需要 sha256sum 或 shasum 校验附件"
    [ -s "$sum_file" ] || fail "校验文件缺失或为空：$(basename "$sum_file")"

    read -r expected_hash expected_name < "$sum_file" || true
    expected_hash="${expected_hash%$'\r'}"
    expected_name="${expected_name%$'\r'}"
    expected_name="${expected_name#\*}"

    [ -n "$expected_hash" ] && [ -n "$expected_name" ] \
        || fail "无法解析校验文件：$(basename "$sum_file")"
    [ "$expected_name" = "$asset" ] \
        || fail "$(basename "$sum_file") 指向 $expected_name，预期 $asset"
    printf '%s' "$expected_hash" | grep -Eq '^[0-9a-fA-F]{64}$' \
        || fail "校验文件中的 SHA-256 格式错误：$(basename "$sum_file")"

    expected_hash="$(printf '%s' "$expected_hash" | tr 'A-F' 'a-f')"
    actual="$("${HASH_CMD[@]}" "$dir/$asset" | awk '{print $1}' | tr 'A-F' 'a-f')"
    [ "$actual" = "$expected_hash" ] \
        || fail "SHA-256 不匹配：$asset（期望 $expected_hash，实际 $actual）"

    info "SHA-256 校验通过：$asset"
}

verify_ed25519_file() {
    local pkg="$1"
    local sig="${pkg}.ed25519.sig"
    local source="Sources/MijiaCore/UpdateChecker.swift"

    [ -f "$source" ] || fail "缺少内置更新公钥来源：$source"
    [ -f "$sig" ] || fail "缺少 Ed25519 签名：$(basename "$sig")"
    command -v openssl >/dev/null 2>&1 || fail "需要 openssl 校验 Ed25519 签名"

    TMP_DIR="$(mktemp -d)"
    # 直接从源码里取公钥，不经过 shell 传值：base64 可能以 / 开头，会被路径转换层改写。
    python3 - "$source" "$sig" "$TMP_DIR" <<'PY' || fail "内置 Ed25519 公钥或签名文件不合法"
import base64
import os
import re
import sys

source_path, signature_path, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
pattern = re.compile(r'updateSigningPublicKeyBase64\s*=\s*"([^"]+)"')
match = pattern.search(open(source_path, encoding="utf-8").read())
if not match:
    raise SystemExit(f"无法从 {source_path} 读取 updateSigningPublicKeyBase64")
try:
    key = base64.b64decode(match.group(1).strip(), validate=True)
except Exception as error:
    raise SystemExit(f"内置公钥不是合法 base64：{error}")
if len(key) != 32:
    raise SystemExit(f"内置公钥长度为 {len(key)} 字节，预期 32")

# Ed25519 SubjectPublicKeyInfo: 30 2a 30 05 06 03 2b 65 70 03 21 00 || raw key
open(os.path.join(out_dir, "public.der"), "wb").write(
    bytes.fromhex("302a300506032b6570032100") + key
)

try:
    signature = base64.b64decode(
        b"".join(open(signature_path, "rb").read().split()), validate=True
    )
except Exception as error:
    raise SystemExit(f"签名文件不是合法 base64：{error}")
if len(signature) != 64:
    raise SystemExit(f"签名长度为 {len(signature)} 字节，预期 64")
open(os.path.join(out_dir, "signature.bin"), "wb").write(signature)
PY

    if ! openssl pkey -pubin -inform DER -in "$TMP_DIR/public.der" -out "$TMP_DIR/public.pem" >/dev/null 2>&1; then
        fail "当前 openssl 不支持 Ed25519 公钥（发布校验需在 ubuntu-latest 执行）"
    fi

    if ! openssl pkeyutl -verify -pubin -inkey "$TMP_DIR/public.pem" -rawin \
        -in "$pkg" -sigfile "$TMP_DIR/signature.bin" >/dev/null; then
        fail "Ed25519 签名与 $(basename "$pkg") 不匹配"
    fi

    rm -rf "$TMP_DIR"
    TMP_DIR=""
    info "Ed25519 签名校验通过：$(basename "$pkg")"
}

verify_ed25519() {
    local dir="$1"
    local version="$2"
    verify_ed25519_file "$dir/MenuBarMijia-${version}.dmg"
    verify_ed25519_file "$dir/MenuBarMijia-${version}-windows-x64-setup.exe"
    verify_ed25519_file "$dir/MenuBarMijia-${version}-windows-x64.msi"
}

release_assets() {
    # 单一附件清单：signature 阶段只差 3 个 .ed25519.sig，其余 6 个完全一致。
    local version="$1"
    local with_signature="$2"
    printf '%s\n' \
        "MenuBarMijia-${version}.dmg" \
        "MenuBarMijia-${version}.dmg.sha256"
    if [ "$with_signature" = "1" ]; then
        printf '%s\n' "MenuBarMijia-${version}.dmg.ed25519.sig"
    fi
    printf '%s\n' \
        "MenuBarMijia-${version}-windows-x64-setup.exe" \
        "MenuBarMijia-${version}-windows-x64-setup.exe.sha256"
    if [ "$with_signature" = "1" ]; then
        printf '%s\n' "MenuBarMijia-${version}-windows-x64-setup.exe.ed25519.sig"
    fi
    printf '%s\n' \
        "MenuBarMijia-${version}-windows-x64.msi" \
        "MenuBarMijia-${version}-windows-x64.msi.sha256"
    if [ "$with_signature" = "1" ]; then
        printf '%s\n' "MenuBarMijia-${version}-windows-x64.msi.ed25519.sig"
    fi
}

check_asset_set() {
    # 严格核对目录里的文件集合（不允许多、不允许少、不允许空文件）。
    # 返回需要的附件数量；调用方用 release_assets 生成同一份清单。
    local dir="$1"
    shift
    local -a required=("$@")

    [ -d "$dir" ] || fail "附件目录不存在：$dir"
    [ "${#required[@]}" -gt 0 ] || fail "内部错误：附件清单为空"

    local file name count=0
    while IFS= read -r -d '' file; do
        [ -f "$file" ] || fail "附件目录包含非文件：$file"
        count=$((count + 1))
        name="$(basename "$file")"
        case " ${required[*]} " in
            *" $name "*) ;;
            *) fail "附件目录包含未预期的文件：$name" ;;
        esac
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)

    [ "$count" -eq "${#required[@]}" ] \
        || fail "附件数量为 $count，预期 ${#required[@]}"
    for name in "${required[@]}"; do
        [ -s "$dir/$name" ] || fail "缺少或为空的发布附件：$name"
    done
}

validate_assets() {
    # assets：严格 9 个附件（含三份 Ed25519 签名），签名必须与 DMG/EXE/MSI 字节匹配。
    # draft-assets：只要求 6 个待签附件，供 CI 阶段产出草稿时自检；绝不替代签名验证。
    local mode="$1"
    [ "$#" -eq 3 ] || usage
    local version="$2"
    local dir="$3"

    printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
        || fail "版本必须是 x.y.z（当前：$version）"
    [ "$version" = "$(version_file)" ] \
        || fail "附件版本 $version 与 VERSION=$(version_file) 不一致"

    local with_signature=1 expect="9 个文件（DMG/EXE/MSI、SHA-256 与 Ed25519 签名）"
    if [ "$mode" = "draft-assets" ]; then
        with_signature=0
        expect="6 个待签文件（DMG/EXE/MSI 与 SHA-256；Ed25519 签名由维护者离线补上）"
    fi

    local -a required=()
    local item
    while IFS= read -r item; do
        [ -n "$item" ] && required+=("$item")
    done < <(release_assets "$version" "$with_signature")
    check_asset_set "$dir" "${required[@]}"

    verify_checksum "$dir" "MenuBarMijia-${version}.dmg"
    verify_checksum "$dir" "MenuBarMijia-${version}-windows-x64-setup.exe"
    verify_checksum "$dir" "MenuBarMijia-${version}-windows-x64.msi"

    if [ "$with_signature" -eq 1 ]; then
        verify_ed25519 "$dir" "$version"
    fi

    info "发布附件完整：$expect"
}

sync_notes() {
    # 把“Windows 未签名”段落写进/移出 release notes（幂等，标签块可定位）。
    [ "$#" -eq 4 ] || usage
    local raw="$1" out="$2" version="$3" signed="$4"

    [ -f "$raw" ] || fail "找不到 release notes：$raw"
    python3 - "$raw" "$out" "$version" "$signed" <<'PY' || fail "生成 release notes 失败"
import sys

raw_path, out_path, version, signed = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
BEGIN = "<!-- windows-signing-status:begin -->"
END = "<!-- windows-signing-status:end -->"
BLOCK = [
    "### ⚠️ Windows 安装包未签名",
    "本次 release 的 EXE/MSI 没有 Authenticode 签名，安装时 SmartScreen 会提示“Windows 已保护你的电脑”。",
    f"这与 macOS 侧无关：DMG 仍带 Ed25519 更新签名（`MenuBarMijia-{version}.dmg.ed25519.sig`），应用内更新会强制校验。",
    "Windows 安装包请以本页附带的 `.sha256` 为准。签名接入见 issue #32。",
]

text = open(raw_path, encoding="utf-8").read()
had_block = BEGIN in text

if signed == "true" and not had_block:
    open(out_path, "w", encoding="utf-8").write(text)
    print("no unsigned note to remove")
    raise SystemExit(0)

if had_block:
    head, _, rest = text.partition(BEGIN)
    if END in rest:
        _, _, tail = rest.partition(END)
        text = head.rstrip("\n") + "\n" + tail.lstrip("\n")
    else:
        text = head.rstrip("\n") + "\n"

if signed == "true":
    updated = text.rstrip("\n") + "\n"
    print("removed stale unsigned note")
else:
    section = "\n".join([BEGIN] + BLOCK + [END])
    updated = text.rstrip("\n") + "\n\n" + section + "\n"
    print("wrote unsigned note")

open(out_path, "w", encoding="utf-8").write(updated)
PY
}

command_name="${1:-}"
if [ "$#" -gt 0 ]; then
    shift
fi

case "$command_name" in
    tag) validate_tag "$@" ;;
    assets) validate_assets assets "$@" ;;
    draft-assets) validate_assets draft-assets "$@" ;;
    notes) sync_notes "$@" ;;
    *) usage ;;
esac
