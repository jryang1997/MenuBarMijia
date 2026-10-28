#!/bin/bash
# 在群晖 NAS 上以 root 运行：部署 Home Assistant 容器，并放入米家/美的集成。
# 由 Mac 上的 deploy_ha.sh 上传并调用，不需要手动运行。
# 用法：HA_VERSION=… HA_IMAGE_DIGEST=sha256:… bash remote_setup.sh <工作目录>
#   工作目录必须由调用方创建为 700，并用 COMPONENTS_SHA256 传入集成包摘要。
set -euo pipefail

WORK="${1:-}"
NAME=homeassistant
FORCE_NEW="${FORCE_NEW:-0}"
# 镜像按 digest 钉住（#31）：这两个值由 deploy_ha.sh 传入；手动运行时必须自己提供，
# 或者接受下面的默认值（与仓库 deploy_ha.sh 保持一致，升级时同步更新）。
HA_VERSION="${HA_VERSION:-2026.10.4}"
HA_IMAGE_DIGEST="${HA_IMAGE_DIGEST:-sha256:23f4dfbb69ce76315dbc4de7915504f1c2dcecd7ca2648113a493a385972e133}"

say()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✘ %s\033[0m\n' "$*"; exit 1; }

[[ "$WORK" = /* && -d "$WORK" && ! -L "$WORK" ]] || die "请提供已创建的私有工作目录。"
WORK_MODE=$(stat -c '%a' "$WORK" 2>/dev/null || stat -f '%Lp' "$WORK")
[ "$WORK_MODE" = "700" ] || die "工作目录权限必须为 700。"
[[ "$HA_IMAGE_DIGEST" =~ ^sha256:[[:xdigit:]]{64}$ ]] || die "HA_IMAGE_DIGEST 必须为有效 SHA256 摘要。"
[[ "${COMPONENTS_SHA256:-}" =~ ^[[:xdigit:]]{64}$ ]] || die "请用 COMPONENTS_SHA256 提供集成包 SHA256。"
[[ "$FORCE_NEW" =~ ^[01]$ && "${MIRROR_FALLBACK:-0}" =~ ^[01]$ ]] || die "FORCE_NEW 和 MIRROR_FALLBACK 只能为 0 或 1。"
[ -f "$WORK/components.tar.gz" ] && [ ! -L "$WORK/components.tar.gz" ] || die "缺少集成包。"
if command -v sha256sum >/dev/null 2>&1; then
  GOT_SHA256=$(sha256sum "$WORK/components.tar.gz" | cut -d' ' -f1)
else
  GOT_SHA256=$(shasum -a 256 "$WORK/components.tar.gz" | cut -d' ' -f1)
fi
[ "$GOT_SHA256" = "$(printf '%s' "$COMPONENTS_SHA256" | tr '[:upper:]' '[:lower:]')" ] || die "集成包 SHA256 不匹配。"
STAGED=$(mktemp -d "$WORK/staged.XXXXXX")
trap 'rm -rf "$STAGED"' EXIT
# 先在私有目录完整解压并检查，坏包不能移动现有集成。
tar -xzf "$WORK/components.tar.gz" -C "$STAGED" || die "解压集成失败。"
for comp in xiaomi_home midea_ac_lan; do
  [ -f "$STAGED/$comp/manifest.json" ] || die "$comp 缺少 manifest.json。"
done

# ---------- 1. 环境检查 ----------
say "检查 NAS 环境"
DOCKER=$(command -v docker || echo /usr/local/bin/docker)
[ -x "$DOCKER" ] || die "没找到 docker。请在 DSM「套件中心」安装 Container Manager 后再运行。"
"$DOCKER" info >/dev/null 2>&1 || die "docker 服务没在运行。请在 DSM 打开一次 Container Manager 再重试。"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|aarch64) ok "CPU 架构 ${ARCH}，支持" ;;
  *) die "CPU 架构 $ARCH 不受 Home Assistant 新版本支持。" ;;
esac

VOL=""
for v in /volume1 /volume2 /volume3; do [ -d "$v" ] && { VOL=$v; break; }; done
[ -n "$VOL" ] || die "没找到 /volumeN 存储卷。"
BASE="$VOL/docker/homeassistant"
ok "数据目录：$BASE/config"

# ---------- 2. 检查旧的 HA ----------
say "检查以前装过的 Home Assistant"
CONTAINERS=$("$DOCKER" ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Label "managed-by"}}') || die "无法读取现有容器，已中止。"
OLD=$(printf '%s\n' "$CONTAINERS" | grep -v '|menubar-mijia$' | cut -d'|' -f1-3 | grep -i 'home-assistant\|homeassistant' || true)
if [ -n "$OLD" ]; then
  echo "$OLD" | while IFS='|' read -r n img st; do
    echo "  容器: $n"
    echo "  镜像: $img"
    echo "  状态: $st"
    echo "  挂载: $("$DOCKER" inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}  {{end}}' "$n")"
    echo "  版本: $("$DOCKER" inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$n" 2>/dev/null)"
  done
  if [ "$FORCE_NEW" != "1" ]; then
    warn "发现旧的 HA 容器，为避免误操作，本次没有做任何改动。"
    warn "请带上以上输出到 GitHub Issues 反馈，或自行决定沿用旧配置升级，还是用 FORCE_NEW=1 全新安装。"
    exit 2
  fi
else
  ok "没有旧容器"
fi

# ---------- 3. 拉取镜像（按 digest 钉住，内容不可变；默认只用官方源，#31） ----------
# deploy_ha.sh 会传 HA_VERSION 与 HA_IMAGE_DIGEST 进来；手动运行时也可自己设置。
# 按摘要拉取意味着任何镜像站都只能原样搬运这份内容，替换/投毒会在摘要校验处失败。
say "下载 Home Assistant $HA_VERSION 镜像（约 1.5GB，视网络需要几分钟到十几分钟）"
TARGET=homeassistant/home-assistant:stable
IMAGE="ghcr.io/home-assistant/home-assistant@${HA_IMAGE_DIGEST}"
PULLED=""
# 默认只从官方源拉。网络确实不通且你接受第三方镜像站时，才显式 MIRROR_FALLBACK=1
#（内容仍由摘要校验保证，但请理解镜像站能看到你的拉取行为）。
if [ "${MIRROR_FALLBACK:-0}" = "1" ]; then
  warn "MIRROR_FALLBACK=1：官方源失败后改用第三方镜像站（内容按摘要校验）"
  SRCS="$IMAGE
    ghcr.m.daocloud.io/home-assistant/home-assistant@${HA_IMAGE_DIGEST}
    docker.m.daocloud.io/homeassistant/home-assistant@${HA_IMAGE_DIGEST}
    dockerproxy.net/homeassistant/home-assistant@${HA_IMAGE_DIGEST}"
else
  ok "默认只使用官方源 ghcr.io；如拉取失败可加 MIRROR_FALLBACK=1 重试"
  SRCS="$IMAGE"
fi
for src in $SRCS
do
  echo "  尝试 $src"
  if "$DOCKER" pull "$src"; then PULLED=$src; break; fi
  warn "这个源失败，换下一个"
done
[ -n "$PULLED" ] || die "所有镜像源都失败了，请带上以上输出到 GitHub Issues 反馈。"
GOT_VERSION=$("$DOCKER" inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$PULLED")
[ "$GOT_VERSION" = "$HA_VERSION" ] || die "镜像版本不匹配：期望 ${HA_VERSION}，实际 ${GOT_VERSION}。说明 HA_IMAGE_DIGEST 与 HA_VERSION 没有配套更新，请修正后再跑。"
ok "镜像就绪：${HA_VERSION}（摘要 ${HA_IMAGE_DIGEST#sha256:}）"

# ---------- 4. 安装集成 ----------
# 校验与镜像下载均完成后才变更既有服务。
"$DOCKER" tag "$PULLED" "$TARGET"
if [ -n "$OLD" ]; then
  warn "FORCE_NEW=1：旧容器保持原样（只停止并取消自动启动，不删除），继续全新安装。"
  echo "$OLD" | cut -d'|' -f1 | while read -r n; do
    "$DOCKER" update --restart=no "$n" >/dev/null 2>&1
    "$DOCKER" stop "$n" >/dev/null 2>&1
    # 让出容器名
    if [ "$n" = "$NAME" ]; then
      "$DOCKER" rename "$n" "${n}_old_$(date +%Y%m%d%H%M%S)"
    fi
  done
fi
say "放入米家官方集成、美的局域网集成"
mkdir -p "$BASE/config/custom_components"
for comp in xiaomi_home midea_ac_lan; do
  dst="$BASE/config/custom_components/$comp"
  if [ -d "$dst" ]; then
    mv "$dst" "${dst}.bak_$(date +%Y%m%d%H%M%S)"
  fi
  mv "$STAGED/$comp" "$dst"
done

# ---------- 5. 启动容器 ----------
say "启动 Home Assistant"
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1 || true
# host 网络：HA 依靠它做 SSDP/mDNS 发现与手机端广播；配合 NAS 防火墙只放行 8123/5353/1900 使用。
"$DOCKER" run -d \
  --name "$NAME" \
  --restart unless-stopped \
  --label managed-by=menubar-mijia \
  --network host \
  -e TZ=Asia/Shanghai \
  -v "$BASE/config:/config" \
  "$TARGET" >/dev/null || die "容器启动失败"
ok "容器已启动"

# ---------- 6. 等待就绪 ----------
say "等待 Home Assistant 初始化（首次约 1~5 分钟）"
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8123/ 2>/dev/null || true)
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then
    IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || true)
    ok "Home Assistant 已就绪： http://${IP:-NAS的IP}:8123"
    exit 0
  fi
  printf '.'; sleep 5
done
echo
warn "5 分钟内没就绪，可能还在首次初始化。最近日志："
"$DOCKER" logs --tail 30 "$NAME"
exit 3
