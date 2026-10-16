#!/bin/bash
# 在群晖 NAS 上以 root 运行：部署 Home Assistant 容器，并放入米家/美的集成。
# 由 Mac 上的 deploy_ha.sh 上传并调用，不需要手动运行。
set -u

WORK=/tmp/ha_setup
NAME=homeassistant
FORCE_NEW="${FORCE_NEW:-0}"
OFFICIAL_ONLY="${OFFICIAL_ONLY:-0}"

say()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✘ %s\033[0m\n' "$*"; exit 1; }

# ---------- 1. 环境检查 ----------
say "检查 NAS 环境"
DOCKER=$(command -v docker || echo /usr/local/bin/docker)
[ -x "$DOCKER" ] || die "没找到 docker。请在 DSM「套件中心」安装 Container Manager 后再运行。"
"$DOCKER" info >/dev/null 2>&1 || die "docker 服务没在运行。请在 DSM 打开一次 Container Manager 再重试。"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|aarch64) ok "CPU 架构 $ARCH，支持" ;;
  *) die "CPU 架构 $ARCH 不受 Home Assistant 新版本支持。" ;;
esac

VOL=""
for v in /volume1 /volume2 /volume3; do [ -d "$v" ] && { VOL=$v; break; }; done
[ -n "$VOL" ] || die "没找到 /volumeN 存储卷。"
BASE="$VOL/docker/homeassistant"
ok "数据目录：$BASE/config"

# ---------- 2. 检查旧的 HA ----------
say "检查以前装过的 Home Assistant"
OLD=$("$DOCKER" ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Label "managed-by"}}' | grep -v '|menubar-mijia$' | cut -d'|' -f1-3 | grep -i 'home-assistant\|homeassistant' || true)
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
  warn "FORCE_NEW=1：旧容器保持原样（只停止并取消自动启动，不删除），继续全新安装。"
  echo "$OLD" | cut -d'|' -f1 | while read -r n; do
    "$DOCKER" update --restart=no "$n" >/dev/null 2>&1
    "$DOCKER" stop "$n" >/dev/null 2>&1
    # 让出容器名
    [ "$n" = "$NAME" ] && "$DOCKER" rename "$n" "${n}_old_$(date +%Y%m%d)"
  done
else
  ok "没有旧容器"
fi

# ---------- 3. 放入集成 ----------
say "放入米家官方集成、美的局域网集成"
mkdir -p "$BASE/config/custom_components"
for comp in xiaomi_home midea_ac_lan; do
  dst="$BASE/config/custom_components/$comp"
  [ -d "$dst" ] && mv "$dst" "${dst}.bak_$(date +%Y%m%d%H%M%S)"
done
tar -xzf "$WORK/components.tar.gz" -C "$BASE/config/custom_components" || die "解压集成失败"
for comp in xiaomi_home midea_ac_lan; do
  ok "$comp 版本 $(grep -o '"version": *"[^"]*"' "$BASE/config/custom_components/$comp/manifest.json" | cut -d'"' -f4)"
done

# ---------- 4. 拉取镜像（默认依次尝试国内第三方镜像，最后回落官方源；OFFICIAL_ONLY=1 只用官方源） ----------
say "下载 Home Assistant 镜像（约 1.5GB，视网络需要几分钟到十几分钟）"
TARGET=homeassistant/home-assistant:stable
PULLED=""
OFFICIAL_SRCS="ghcr.io/home-assistant/home-assistant:stable homeassistant/home-assistant:stable"
if [ "$OFFICIAL_ONLY" = "1" ]; then
  SRCS="$OFFICIAL_SRCS"
  ok "OFFICIAL_ONLY=1：只使用 ghcr.io 与 Docker Hub 官方源"
else
  SRCS="ghcr.m.daocloud.io/home-assistant/home-assistant:stable
    ghcr.nju.edu.cn/home-assistant/home-assistant:stable
    docker.m.daocloud.io/homeassistant/home-assistant:stable
    ghcr.1ms.run/home-assistant/home-assistant:stable
    dockerproxy.net/homeassistant/home-assistant:stable
    docker.1ms.run/homeassistant/home-assistant:stable
    $OFFICIAL_SRCS"
fi
for src in $SRCS
do
  echo "  尝试 $src"
  if "$DOCKER" pull "$src"; then PULLED=$src; break; fi
  warn "这个源失败，换下一个"
done
[ -n "$PULLED" ] || die "所有镜像源都失败了，请带上以上输出到 GitHub Issues 反馈。"
[ "$PULLED" != "$TARGET" ] && "$DOCKER" tag "$PULLED" "$TARGET"
ok "镜像就绪：$("$DOCKER" inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$TARGET")"

# ---------- 5. 启动容器 ----------
say "启动 Home Assistant"
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1
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
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8123/ 2>/dev/null)
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then
    IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    ok "Home Assistant 已就绪： http://${IP:-NAS的IP}:8123"
    exit 0
  fi
  printf '.'; sleep 5
done
echo
warn "5 分钟内没就绪，可能还在首次初始化。最近日志："
"$DOCKER" logs --tail 30 "$NAME"
exit 3
