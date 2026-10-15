#!/bin/bash
# 在 Mac 的「终端」里运行：一键把 Home Assistant 部署到群晖 NAS。
# 用法：bash ~/Desktop/菜单栏米家/nas/deploy_ha.sh
# 过程中只需输入两次密码：NAS 登录密码、sudo 密码（同一个）。
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
CTL="/tmp/ha-nas-ssh-%r@%h"

if [ -z "${NAS_IP:-}" ]; then
  read -r -p "群晖 NAS 的局域网 IP (例如 192.168.1.100): " NAS_IP
fi
[ -n "$NAS_IP" ] || { echo "NAS IP 不能为空"; exit 1; }

read -r -p "群晖 NAS 的管理员用户名: " NAS_USER
[ -n "$NAS_USER" ] || { echo "用户名不能为空"; exit 1; }

# 把集成打成 custom_components/<域名>/ 结构的压缩包
PKG="$(mktemp -d)"
for comp in xiaomi_home midea_ac_lan; do
  mkdir -p "$PKG/$comp"
  unzip -q "$HERE/components/$comp.zip" -d "$PKG/$comp"
done
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$PKG/components.tar.gz" -C "$PKG" xiaomi_home midea_ac_lan

SSH_OPTS=(-o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=15m -o StrictHostKeyChecking=accept-new)

echo "▶ 连接 NAS（输入 NAS 登录密码）"
ssh "${SSH_OPTS[@]}" "$NAS_USER@$NAS_IP" "mkdir -p /tmp/ha_setup"
cat "$PKG/components.tar.gz" | ssh "${SSH_OPTS[@]}" "$NAS_USER@$NAS_IP" "cat > /tmp/ha_setup/components.tar.gz"
cat "$HERE/remote_setup.sh"   | ssh "${SSH_OPTS[@]}" "$NAS_USER@$NAS_IP" "cat > /tmp/ha_setup/remote_setup.sh"
rm -rf "$PKG"

echo "▶ 开始部署（接下来如提示 Password，输入同一个密码）"
set +e
ssh -t "${SSH_OPTS[@]}" "$NAS_USER@$NAS_IP" "sudo FORCE_NEW=${FORCE_NEW:-0} bash /tmp/ha_setup/remote_setup.sh"
rc=$?
ssh "${SSH_OPTS[@]}" -O exit "$NAS_USER@$NAS_IP" 2>/dev/null
echo
case $rc in
  0) echo "✅ 完成。浏览器打开 http://$NAS_IP:8123 创建 HA 账号。" ;;
  2) echo "ℹ️ 发现旧的 HA，未做改动。把上面的输出发给 AI 助手即可。" ;;
  *) echo "❌ 没有成功（代码 $rc）。把上面的输出发给 AI 助手即可。" ;;
esac
