#!/bin/bash
# 在 Mac 的「终端」里运行：一键把 Home Assistant 部署到群晖 NAS。
# 用法（在仓库根目录）：bash nas/deploy_ha.sh
# 可选环境变量：
#   GH_PROXY=前缀     下载集成时 GitHub 直连失败后改用的代理前缀，如 https://ghproxy.net/（默认不用；
#                     下载后会按下方 PINNED 清单校验 SHA256，校验失败直接退出，代理不能替换内容）
#   PACKAGE_ONLY=1    只下载并打包集成，生成 components.tar.gz 后退出，不连接 NAS
#   FORCE_NEW=1       NAS 上发现旧 HA 容器时不再询问，直接全新安装（旧容器只停止不删除）
#   MIRROR_FALLBACK=1 官方镜像失败后尝试第三方镜像（仍校验摘要）
# 过程中只需输入两次密码：NAS 登录密码、sudo 密码（同一个）。
#
# 安全设计（#31）：镜像与集成都钉住版本和哈希，内容不对就退出；
# NAS 上的工作目录用 mktemp -d 生成（仅目录所有者和 root 可读），执行前会打印将要运行的命令。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CTL="/tmp/ha-nas-ssh-%r@%h"

# ---------- 钉住的版本与哈希（升级集成时更新这两组值，不要用"最新版"） ----------
# HA 镜像：版本号与 ghcr.io 多架构 manifest 摘要一起钉死（remote_setup.sh 里用摘要拉取）。
# 获取方式：docker manifest inspect ghcr.io/home-assistant/home-assistant:<tag>
#   或 curl -fsSI -H "Authorization: Bearer $(curl -fsS "https://ghcr.io/token?scope=repository:home-assistant/home-assistant:pull" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')" \
#        -H "Accept: application/vnd.oci.image.index.v1+json" \
#        https://ghcr.io/v2/home-assistant/home-assistant/manifests/<tag> | grep -i docker-content-digest
HA_VERSION=2026.10.4
HA_IMAGE_DIGEST=sha256:23f4dfbb69ce76315dbc4de7915504f1c2dcecd7ca2648113a493a385972e133
# 集成：tag + 对应源码包（archive/refs/tags/<tag>.tar.gz）的 SHA256。
# 升级方式：到 GitHub Releases 找新 tag，下载同名 tar.gz，sha256sum 后更新这里。
PINNED="xiaomi_home=XiaoMi/ha_xiaomi_home=v0.5.0=ec28afff5c6a2c3705ec4efc5a75f758b71bb5721726a2cc2fed1a6230fba9ad
midea_ac_lan=wuwentao/midea_ac_lan=v2026.10.0=836888230aebb7b36b5fe542b90cb727aca49d1ca027f4a9ba0d158acda13ad3"

sha256_of() { # sha256_of <file>：跨 macOS（无 sha256sum）与 Linux 取 SHA256
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

verify_local_archive() {
  local archive="$1" want got
  [ -f "$archive.sha256" ] || { echo "✘ $archive 缺少同名 .sha256 文件，无法校验 SHA256。"; return 1; }
  want=$(awk 'NR == 1 {print $1}' "$archive.sha256")
  [[ "$want" =~ ^[[:xdigit:]]{64}$ ]] || { echo "✘ $archive.sha256 必须提供 64 位 SHA256。"; return 1; }
  want=$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')
  got=$(sha256_of "$archive") || return 1
  [ "$got" = "$want" ] || { echo "✘ $archive SHA256 不匹配，已中止。"; return 1; }
}

fetch() { # fetch <url> <out>：先直连官方，失败且设置了 GH_PROXY 时走代理
  curl -fsSL --retry 2 -o "$2" "$1" && return 0
  [ -n "${GH_PROXY:-}" ] && { echo "  直连失败，改用代理 $GH_PROXY"; curl -fsSL --retry 2 -o "$2" "${GH_PROXY}$1" && return 0; }
  return 1
}

build_components() { # build_components <工作目录>：产出 <工作目录>/components.tar.gz
  local pkg="$1" pair comp repo tag want got dl
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    comp="${pair%%=*}"; rest="${pair#*=}"; repo="${rest%%=*}"; rest="${rest#*=}"
    tag="${rest%%=*}"; want="${rest#*=}"
    mkdir -p "$pkg/$comp"
    if [ -f "$HERE/components/$comp.zip" ]; then
      verify_local_archive "$HERE/components/$comp.zip" || return 1
      echo "▶ 使用本地 nas/components/$comp.zip（SHA256 已校验）"
      unzip -q "$HERE/components/$comp.zip" -d "$pkg/$comp" || return 1
    elif [ -f "$HERE/components/$comp.tar.gz" ]; then
      verify_local_archive "$HERE/components/$comp.tar.gz" || return 1
      echo "▶ 使用本地 nas/components/$comp.tar.gz（SHA256 已校验）"
      tar -xzf "$HERE/components/$comp.tar.gz" -C "$pkg/$comp" --strip-components=1 || return 1
    else
      echo "▶ 下载 $repo ${tag}（钉住版本，SHA256 必须匹配）"
      dl="$(mktemp -d)"
      fetch "https://github.com/$repo/archive/refs/tags/$tag.tar.gz" "$dl/src.tar.gz" \
        || { echo "✘ 下载 $repo 失败。可设置 GH_PROXY，或手动下载后放到 nas/components/$comp.tar.gz + .sha256"; rm -rf "$dl"; return 1; }
      got=$(sha256_of "$dl/src.tar.gz")
      [ "$got" = "$want" ] || { echo "✘ $repo $tag 的 SHA256 不匹配：期望 ${want}，实际 ${got}。内容可能被替换，已中止。"; rm -rf "$dl"; return 1; }
      tar -xzf "$dl/src.tar.gz" -C "$dl" || { rm -rf "$dl"; return 1; }
      cp -R "$dl"/*/custom_components/"$comp"/. "$pkg/$comp/" || { echo "✘ $repo 源码包里没有 custom_components/$comp"; rm -rf "$dl"; return 1; }
      rm -rf "$dl"
    fi
    [ -f "$pkg/$comp/manifest.json" ] || { echo "✘ $comp 缺少 manifest.json，压缩包结构不对"; return 1; }
  done <<< "$PINNED"
  # 打成 <域名>/ 结构的压缩包，上传后解压到 custom_components/
  COPYFILE_DISABLE=1 tar --no-xattrs -czf "$pkg/components.tar.gz" -C "$pkg" xiaomi_home midea_ac_lan
}

PKG="$(mktemp -d)"
trap 'rm -rf "$PKG"' EXIT
build_components "$PKG" || { rm -rf "$PKG"; exit 1; }
if [ "${PACKAGE_ONLY:-0}" = "1" ]; then
  trap - EXIT
  echo "✅ 已生成 $PKG/components.tar.gz"
  exit 0
fi

if [ -z "${NAS_IP:-}" ]; then
  read -r -p "群晖 NAS 的局域网 IP (例如 192.168.1.100): " NAS_IP
fi
[ -n "$NAS_IP" ] || { echo "NAS IP 不能为空"; exit 1; }

read -r -p "群晖 NAS 的管理员用户名: " NAS_USER
[ -n "$NAS_USER" ] || { echo "用户名不能为空"; exit 1; }
[[ "${FORCE_NEW:-0}" =~ ^[01]$ && "${MIRROR_FALLBACK:-0}" =~ ^[01]$ ]] \
  || { echo "FORCE_NEW 和 MIRROR_FALLBACK 只能为 0 或 1"; exit 1; }

SSH_OPTS=(-o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=15m -o StrictHostKeyChecking=accept-new)

echo "▶ 连接 NAS（输入 NAS 登录密码）"
# NAS 上的工作目录用 mktemp -d 生成：仅目录所有者和 root 可读，不再用所有人可写的 /tmp/ha_setup（#31）。
REMOTE_WORK=$(ssh "${SSH_OPTS[@]}" "$NAS_USER@$NAS_IP" 'd=$(mktemp -d /tmp/ha_setup.XXXXXX) && chmod 700 "$d" && echo "$d"') \
  || { echo "❌ 无法在 NAS 上创建工作目录"; exit 1; }
[[ "$REMOTE_WORK" =~ ^/tmp/ha_setup\.[A-Za-z0-9]+$ ]] || { echo "❌ NAS 返回的工作目录无效"; exit 1; }
COMPONENTS_SHA256=$(sha256_of "$PKG/components.tar.gz")
cat "$PKG/components.tar.gz" | ssh "${SSH_OPTS[@]}" "$NAS_USER@$NAS_IP" "cat > '$REMOTE_WORK/components.tar.gz'"
cat "$HERE/remote_setup.sh"   | ssh "${SSH_OPTS[@]}" "$NAS_USER@$NAS_IP" "cat > '$REMOTE_WORK/remote_setup.sh'"
rm -rf "$PKG"

echo "▶ 开始部署（接下来如提示 Password，输入同一个密码）"
REMOTE_CMD="sudo FORCE_NEW=${FORCE_NEW:-0} MIRROR_FALLBACK=${MIRROR_FALLBACK:-0} HA_VERSION=${HA_VERSION} HA_IMAGE_DIGEST=${HA_IMAGE_DIGEST} COMPONENTS_SHA256=${COMPONENTS_SHA256} bash '$REMOTE_WORK/remote_setup.sh' '$REMOTE_WORK'"
echo "  将在 NAS 上执行：$REMOTE_CMD"
set +e
ssh -t "${SSH_OPTS[@]}" "$NAS_USER@$NAS_IP" "$REMOTE_CMD"
rc=$?
ssh "${SSH_OPTS[@]}" "$NAS_USER@$NAS_IP" "rm -rf '$REMOTE_WORK'" 2>/dev/null
ssh "${SSH_OPTS[@]}" -O exit "$NAS_USER@$NAS_IP" 2>/dev/null
echo
case $rc in
  0) echo "✅ 完成。浏览器打开 http://$NAS_IP:8123 创建 HA 账号。" ;;
  2) echo "ℹ️ 发现旧的 HA，未做改动。请带上以上输出到 GitHub Issues 反馈。" ;;
  *) echo "❌ 没有成功（代码 ${rc}）。请带上以上输出到 GitHub Issues 反馈。" ;;
esac
exit "$rc"
