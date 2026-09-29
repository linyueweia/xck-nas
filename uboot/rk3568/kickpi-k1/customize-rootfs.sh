#!/bin/bash
# ============================================================
# KICKPI K1 (RK3568) rootfs 定制脚本  v2
# 由 buildfnos.sh 在挂载 rootfs 后调用
#
# v2 关键修正（依据飞牛实际启动机制）:
#   飞牛的 systemd-modules-load.service 不会运行!
#   （sysinit.target 未 Wants 它，且它无 [Install] 段）
#   → 因此 /etc/modules-load.d/*.conf 全部无效
#   → 必须仿照飞牛自己的 set_gpio-init.service 模式:
#       写 WantedBy=sysinit.target 的 oneshot 服务, 直接 insmod
# ============================================================
set -e

: "${DEVICE_ROOT:?❌ 需要 DEVICE_ROOT 环境变量（rootfs 挂载点）}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MODULE_SRC="$REPO_ROOT/kernel-module/maxio.ko"

KVER="6.18.18.c951-trim"
KMOD_DIR="$DEVICE_ROOT/lib/modules/$KVER"
PHY_DIR="$KMOD_DIR/kernel/drivers/net/phy"

echo "🔧 [customize] rootfs = $DEVICE_ROOT"

# ---------- 1. 注入 MAXIO PHY 驱动模块 ----------
if [[ ! -f "$MODULE_SRC" ]]; then
  echo "❌ [customize] 找不到 $MODULE_SRC"; exit 1
fi
sudo mkdir -p "$PHY_DIR"
sudo cp -f "$MODULE_SRC" "$PHY_DIR/maxio.ko"
sudo chmod 644 "$PHY_DIR/maxio.ko"
echo "   ✅ maxio.ko 已注入 ($(stat -c%s "$PHY_DIR/maxio.ko") 字节)"

# ---------- 2. 修复 kmod 软链 ----------
for p in /sbin /usr/sbin /bin /usr/bin; do
  sudo mkdir -p "$DEVICE_ROOT$p"
  for n in modprobe insmod rmmod depmod modinfo lsmod; do
    [ -e "$DEVICE_ROOT$p/$n" ] || sudo ln -sf /usr/bin/kmod "$DEVICE_ROOT$p/$n"
  done
done
echo "   ✅ kmod 软链已确认"

# ---------- 3. 保留 modules-load.d 配置（万一将来生效）----------
sudo mkdir -p "$DEVICE_ROOT/etc/modules-load.d"
printf '# KICKPI-K1 (备用，主要靠 sysinit 服务)\nmaxio\n' \
  | sudo tee "$DEVICE_ROOT/etc/modules-load.d/20-maxio.conf" >/dev/null
printf '# KICKPI-K1 网口驱动链\nmaxio\ndwmac-rk\nstmmac-platform\n' \
  | sudo tee "$DEVICE_ROOT/etc/modules-load.d/30-kickpi-k1-net.conf" >/dev/null

# ---------- 4. 重建 depmod 索引 ----------
if command -v depmod >/dev/null 2>&1; then
  sudo depmod -b "$DEVICE_ROOT" "$KVER" 2>&1 | head -3 || true
  echo "   ✅ depmod 索引已重建"
else
  echo "   ⚠️ 宿主无 depmod"
fi

# ---------- 5. 早期加载脚本（仿飞牛 /usr/trim/bin 风格）----------
sudo mkdir -p "$DEVICE_ROOT/usr/trim/bin" "$DEVICE_ROOT/usr/local/bin"
cat > /tmp/k1-load-maxio.sh <<'EOF'
#!/bin/sh
# KICKPI-K1: 在 sysinit 阶段加载 MAXIO PHY 驱动（早于 NetworkManager）
K=/lib/modules/6.18.18.c951-trim/kernel/drivers/net/phy/maxio.ko
KM=/usr/bin/kmod
LOG=/boot/k1-net.log

{
  echo "===== k1-load-maxio $(date 2>/dev/null || echo '?') ====="
  if [ ! -f "$K" ]; then
    echo "  !! $K 不存在"; exit 0
  fi
  # 优先 modprobe（走索引），失败则直接 insmod 绝对路径
  if "$KM" modprobe maxio 2>&1; then
    echo "  modprobe maxio: OK"
  elif "$KM" insmod "$K" 2>&1; then
    echo "  insmod maxio: OK"
  else
    echo "  !! 加载失败（尝试 --force）"
    "$KM" insmod "$K" 2>&1 || true
  fi
  echo "  --- lsmod ---"
  "$KM" lsmod 2>/dev/null | grep -E "maxio|stmmac|dwmac" || echo "  (无)"
} >> "$LOG" 2>&1
exit 0
EOF
sudo cp -f /tmp/k1-load-maxio.sh "$DEVICE_ROOT/usr/trim/bin/k1-load-maxio.sh"
sudo chmod 755 "$DEVICE_ROOT/usr/trim/bin/k1-load-maxio.sh"

# ---------- 6. sysinit 阶段服务（关键，仿 set_gpio-init.service）----------
sudo mkdir -p "$DEVICE_ROOT/etc/systemd/system"
cat > /tmp/k1-load-maxio.service <<'EOF'
[Unit]
Description=KICKPI-K1 Load MAXIO PHY module
Documentation=man:set_gpio(8)
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target

[Service]
Type=oneshot
ExecStart=/usr/trim/bin/k1-load-maxio.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=sysinit.target
EOF
sudo cp -f /tmp/k1-load-maxio.service "$DEVICE_ROOT/etc/systemd/system/k1-load-maxio.service"

# 同时提供 modprobe 兜底配置
cat > /tmp/k1-net-dump.service <<'EOF'
[Unit]
Description=KICKPI-K1 dump net diagnostics to /boot
DefaultDependencies=no
After=local-fs.target network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/k1-net-dump.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
cat > /tmp/k1-net-dump.sh <<'EOF'
#!/bin/sh
LOG=/boot/k1-net.log
{
  echo "===== k1-net-dump $(date 2>/dev/null || echo '?') ====="
  echo "-- lsmod --"; /usr/bin/kmod lsmod 2>/dev/null | grep -E "maxio|stmmac|dwmac" || echo "  (无)"
  echo "-- dmesg net --"; dmesg 2>/dev/null | grep -iE "maxio|mae0621|rk_gmac|reset the dma|Link is Up|attach to PHY" | tail -60
  echo "-- ip link --"; ip -br link 2>/dev/null || echo "  (无 ip)"
} >> "$LOG" 2>&1
exit 0
EOF
sudo cp -f /tmp/k1-net-dump.sh "$DEVICE_ROOT/usr/local/bin/k1-net-dump.sh"
sudo chmod 755 "$DEVICE_ROOT/usr/local/bin/k1-net-dump.sh"
sudo cp -f /tmp/k1-net-dump.service "$DEVICE_ROOT/etc/systemd/system/k1-net-dump.service"

# ---------- 7. 启用（建立 .wants 软链，与飞牛 set_gpio-init 同款）----------
sudo mkdir -p "$DEVICE_ROOT/etc/systemd/system/sysinit.target.wants"
sudo ln -sf /etc/systemd/system/k1-load-maxio.service \
            "$DEVICE_ROOT/etc/systemd/system/sysinit.target.wants/k1-load-maxio.service"
sudo mkdir -p "$DEVICE_ROOT/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /etc/systemd/system/k1-net-dump.service \
            "$DEVICE_ROOT/etc/systemd/system/multi-user.target.wants/k1-net-dump.service"
# 清理 v1 遗留
sudo rm -f "$DEVICE_ROOT/etc/systemd/system/k1-net-setup.service"
sudo rm -f "$DEVICE_ROOT/etc/systemd/system/multi-user.target.wants/k1-net-setup.service"
sudo rm -f "$DEVICE_ROOT/usr/local/bin/k1-net-setup.sh"
echo "   ✅ sysinit 加载服务已启用 (仿飞牛 set_gpio-init 模式)"

# ---------- 8. 自检 ----------
echo "   --- 定制自检 ---"
[[ -f "$PHY_DIR/maxio.ko" ]] && echo "      ✓ maxio.ko" || { echo "      ✗ maxio.ko"; exit 1; }
[[ -L "$DEVICE_ROOT/sbin/modprobe" ]] && echo "      ✓ modprobe" || { echo "      ✗ modprobe"; exit 1; }
[[ -x "$DEVICE_ROOT/usr/trim/bin/k1-load-maxio.sh" ]] && echo "      ✓ 加载脚本" || { echo "      ✗"; exit 1; }
[[ -L "$DEVICE_ROOT/etc/systemd/system/sysinit.target.wants/k1-load-maxio.service" ]] \
  && echo "      ✓ sysinit 服务已启用" || { echo "      ✗ sysinit 服务"; exit 1; }
echo "✅ [customize] K1 rootfs 定制完成 v2"
