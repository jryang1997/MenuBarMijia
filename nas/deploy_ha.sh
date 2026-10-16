#!/bin/bash
# 在 Mac 的「终端」里运行：一键把 Home Assistant 部署到群晖 NAS。
# 用法（在仓库根目录）：bash nas/deploy_ha.sh
# 可选环境变量：
#   OFFICIAL_ONLY=1   NAS 只从 ghcr.io / Docker Hub 官方源拉镜像，不用国内第三方镜像
#   GH_PROXY=前缀     下载集成时 GitHub 直连失败后改用的代理前缀，如 https://ghproxy.net/（默认不用）
#   PACKAGE_ONLY=1    只下载并打包集成，生成 components.tar.gz 后退出，不连接 NAS
# 过程中只需输入两次密码：NAS 登录密码、sudo 密码（同一个）。
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
CTL="/tmp/ha-nas-ssh-%r@%h"

# ---------- 准备集成：优先用 nas/components/ 下你自己放的 zip，否则从官方 GitHub 下载 ----------
# 集成不随本仓库分发，各自许可见 README「第三方组件」。
COMP_REPOS="xiaomi_home=XiaoMi/ha_xiaomi_home midea_ac_lan=wuwentao/midea_ac_lan"

fetch() { # fetch <url> <out>：先直连官方，失败且设置了 GH_PROXY 时走代理
  curl -fsSL --retry 2 -o "$2" "$1" && return 0
  [ -n "${GH_PROXY:-}" ] && { echo "  直连失败，改用代理 $GH_PROXY"; curl -fsSL --retry 2 -o "$2" "${GH_PROXY}$1" && return 0; }
  return 1
}

latest_tag() { # latest_tag <owner/repo>：读 releases/latest 跳转后的地址
  local url
  url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" 2>/dev/null) \
    || { [ -n "${GH_PROXY:-}" ] && url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' "${GH_PROXY}https://github.com/$1/releases/latest" 2>/dev/null); } || true
  case "$url" in */releases/tag/*) echo "${url##*/releases/tag/}" ;; *) return 1 ;; esac
}

build_components() { # build_components <工作目录>：产出 <工作目录>/components.tar.gz
  local pkg="$1" pair comp repo tag dl
  for pair in $COMP_REPOS; do
    comp="${pair%%=*}"; repo="${pair#*=}"
    mkdir -p "$pkg/$comp"
    if [ -f "$HERE/components/$comp.zip" ]; then
      echo "▶ 使用本地 nas/components/$comp.zip"
      unzip -q "$HERE/components/$comp.zip" -d "$pkg/$comp"
    else
      tag=$(latest_tag "$repo") || { echo "✘ 查不到 $repo 的最新版本。可设置 GH_PROXY，或手动下载后放到 nas/components/$comp.zip"; return 1; }
      echo "▶ 下载 $repo $tag"
      dl="$(mktemp -d)"
      fetch "https://github.com/$repo/archive/refs/tags/$tag.tar.gz" "$dl/src.tar.gz" \
        || { echo "✘ 下载 $repo 失败。可设置 GH_PROXY，或手动下载后放到 nas/components/$comp.zip"; rm -rf "$dl"; return 1; }
      tar -xzf "$dl/src.tar.gz" -C "$dl"
      cp -R "$dl"/*/custom_components/"$comp"/. "$pkg/$comp/" || { echo "✘ $repo 源码包里没有 custom_components/$comp"; rm -rf "$dl"; return 1; }
      rm -rf "$dl"
    fi
    [ -f "$pkg/$comp/manifest.json" ] || { echo "✘ $comp 缺少 manifest.json，压缩包结构不对"; return 1; }
  done
  # 打成 <域名>/ 结构的压缩包，上传后解压到 custom_components/
  COPYFILE_DISABLE=1 tar --no-xattrs -czf "$pkg/components.tar.gz" -C "$pkg" xiaomi_home midea_ac_lan
}

PKG="$(mktemp -d)"
build_components "$PKG" || { rm -rf "$PKG"; exit 1; }
if [ "${PACKAGE_ONLY:-0}" = "1" ]; then
  echo "✅ 已生成 $PKG/components.tar.gz"
  exit 0
fi

if [ -z "${NAS_IP:-}" ]; then
  read -r -p "群晖 NAS 的局域网 IP (例如 192.168.1.100): " NAS_IP
fi
[ -n "$NAS_IP" ] || { echo "NAS IP 不能为空"; exit 1; }

read -r -p "群晖 NAS 的管理员用户名: " NAS_USER
[ -n "$NAS_USER" ] || { echo "用户名不能为空"; exit 1; }

SSH_OPTS=(-o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=15m -o StrictHostKeyChecking=accept-new)

echo "▶ 连接 NAS（输入 NAS 登录密码）"
ssh "${SSH_OPTS[@]}" "$NAS_USER@$NAS_IP" "mkdir -p /tmp/ha_setup"
cat "$PKG/components.tar.gz" | ssh "${SSH_OPTS[@]}" "$NAS_USER@$NAS_IP" "cat > /tmp/ha_setup/components.tar.gz"
cat "$HERE/remote_setup.sh"   | ssh "${SSH_OPTS[@]}" "$NAS_USER@$NAS_IP" "cat > /tmp/ha_setup/remote_setup.sh"
rm -rf "$PKG"

echo "▶ 开始部署（接下来如提示 Password，输入同一个密码）"
set +e
ssh -t "${SSH_OPTS[@]}" "$NAS_USER@$NAS_IP" "sudo FORCE_NEW=${FORCE_NEW:-0} OFFICIAL_ONLY=${OFFICIAL_ONLY:-0} bash /tmp/ha_setup/remote_setup.sh"
rc=$?
ssh "${SSH_OPTS[@]}" -O exit "$NAS_USER@$NAS_IP" 2>/dev/null
echo
case $rc in
  0) echo "✅ 完成。浏览器打开 http://$NAS_IP:8123 创建 HA 账号。" ;;
  2) echo "ℹ️ 发现旧的 HA，未做改动。请带上以上输出到 GitHub Issues 反馈。" ;;
  *) echo "❌ 没有成功（代码 $rc）。请带上以上输出到 GitHub Issues 反馈。" ;;
esac
