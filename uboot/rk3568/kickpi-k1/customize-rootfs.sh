#!/bin/bash
# ============================================================
# KICKPI K1 (RK3568) rootfs 定制脚本
# 由 buildfnos.sh 在挂载 rootfs 后调用
# 作用: 让 MAXIO MAE0621A PHY 驱动能被飞牛内核正确加载
# ============================================================
set -e

: "${DEVICE_ROOT:?❌ 需要 DEVICE_ROOT 环境变量（rootfs 挂载点）}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MODULE_SRC="$REPO_ROOT/kernel-module/maxio.ko"

KVER="6.18.18.c951-trim"
KMOD_DIR="$DEVICE_ROOT/lib/modules/$KVER"
PHY_DIR="$KMOD_DIR/kernel/drivers/net/phy"

echo "🔧 [customize] rootfs = $DEVICE_ROOT"
echo "🔧 [customize] kernel = $KVER"

# ---------- 1. 注入 MAXIO PHY 驱动模块 ----------
if [[ ! -f "$MODULE_SRC" ]]; then
  echo "❌ [customize] 找不到 $MODULE_SRC"; exit 1
fi
sudo mkdir -p "$PHY_DIR"
sudo cp -f "$MODULE_SRC" "$PHY_DIR/maxio.ko"
sudo chmod 644 "$PHY_DIR/maxio.ko"
echo "   ✅ maxio.ko 已注入 ($(stat -c%s "$PHY_DIR/maxio.ko") 字节)"

# ---------- 2. 修复 kmod 软链（飞牛只装了 kmod 无软链）----------
for p in /sbin /usr/sbin /bin; do
  sudo mkdir -p "$DEVICE_ROOT$p"
  for n in modprobe insmod rmmod depmod modinfo lsmod; do
    sudo ln -sf /usr/bin/kmod "$DEVICE_ROOT$p/$n"
  done
done
echo "   ✅ kmod 软链已建立 (modprobe/insmod/depmod/modinfo/lsmod)"

# ---------- 3. 写模块自动加载配置 ----------
sudo mkdir -p "$DEVICE_ROOT/etc/modules-load.d"
cat > /tmp/20-maxio.conf <<'EOF'
# KICKPI-K1 的 PHY 是 MAXIO MAE0621A，必须在 MAC 驱动之前加载
maxio
EOF
sudo cp -f /tmp/20-maxio.conf "$DEVICE_ROOT/etc/modules-load.d/20-maxio.conf"

cat > /tmp/30-kickpi-k1-net.conf <<'EOF'
# KICKPI-K1 网口：MAXIO PHY 驱动必须先于 MAC 驱动加载
maxio
dwmac-rk
stmmac-platform
EOF
sudo cp -f /tmp/30-kickpi-k1-net.conf "$DEVICE_ROOT/etc/modules-load.d/30-kickpi-k1-net.conf"

# /etc/modules 也追加（部分发行版走这里）
if [[ -f "$DEVICE_ROOT/etc/modules" ]]; then
  if ! grep -q '^maxio' "$DEVICE_ROOT/etc/modules"; then
    sudo tee -a "$DEVICE_ROOT/etc/modules" >/dev/null <<'EOF'

# KICKPI-K1 双千兆网口（驱动为模块，需显式加载）
maxio
dwmac-rk
stmmac-platform
EOF
  fi
fi
echo "   ✅ 模块加载配置已写入"

# ---------- 4. 重建 depmod 索引（关键！modprobe 实际读 .bin）----------
if command -v depmod >/dev/null 2>&1; then
  sudo depmod -b "$DEVICE_ROOT" "$KVER" 2>&1 | head -5 || true
  echo "   ✅ depmod 索引已重建 ($(stat -c%s "$KMOD_DIR/modules.dep.bin" 2>/dev/null || echo 0) 字节)"
else
  echo "   ⚠️ 宿主无 depmod，稍后由容器步骤处理"
fi

# ---------- 5. 兜底加载脚本 + systemd 服务 ----------
sudo mkdir -p "$DEVICE_ROOT/usr/local/bin"
cat > /tmp/k1-net-setup.sh <<'EOF'
#!/bin/sh
# KICKPI-K1: 加载 MAXIO PHY 驱动，并把结果写入 BOOT 分区便于取证
LOG=/boot/k1-net.log
K=/lib/modules/6.18.18.c951-trim/kernel/drivers/net/phy/maxio.ko
KM=/usr/bin/kmod
{
  echo "===== k1-net-setup $(date 2>/dev/null || echo '?') ====="
  echo "-- insmod maxio.ko --"
  if [ -f "$K" ]; then
    "$KM" insmod "$K" 2>&1 && echo "  insmod OK" || echo "  insmod 返回非0（可能已加载）"
  else
    echo "  !! $K 不存在"
  fi
  echo "-- lsmod --"
  "$KM" lsmod 2>/dev/null | grep -E "maxio|stmmac|dwmac" || echo "  (无 maxio/stmmac/dwmac)"
  echo "-- dmesg: MAXIO / gmac / phy --"
  dmesg 2>/dev/null | grep -iE "maxio|mae0621|rk_gmac|reset the dma|Link is Up|attach to PHY" | tail -50
  echo "-- ip link --"
  ip -br link 2>/dev/null || echo "  (无 ip)"
  echo "===== end ====="
} >> "$LOG" 2>&1
chmod 666 "$LOG" 2>/dev/null
exit 0
EOF
sudo cp -f /tmp/k1-net-setup.sh "$DEVICE_ROOT/usr/local/bin/k1-net-setup.sh"
sudo chmod 755 "$DEVICE_ROOT/usr/local/bin/k1-net-setup.sh"

sudo mkdir -p "$DEVICE_ROOT/etc/systemd/system"
cat > /tmp/k1-net-setup.service <<'EOF'
[Unit]
Description=KICKPI-K1 load MAXIO PHY module and dump net log
After=local-fs.target systemd-modules-load.service
Wants=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/k1-net-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo cp -f /tmp/k1-net-setup.service "$DEVICE_ROOT/etc/systemd/system/k1-net-setup.service"

sudo mkdir -p "$DEVICE_ROOT/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /etc/systemd/system/k1-net-setup.service \
            "$DEVICE_ROOT/etc/systemd/system/multi-user.target.wants/k1-net-setup.service"
echo "   ✅ 兜底脚本 + systemd 服务已安装并启用"

# ---------- 6. 自检 ----------
echo "   --- 定制自检 ---"
[[ -f "$PHY_DIR/maxio.ko" ]] && echo "      ✓ maxio.ko 在位" || { echo "      ✗ maxio.ko 缺失"; exit 1; }
[[ -L "$DEVICE_ROOT/sbin/modprobe" ]] && echo "      ✓ modprobe 软链" || { echo "      ✗ modprobe 软链缺失"; exit 1; }
grep -q '^maxio' "$DEVICE_ROOT/etc/modules-load.d/20-maxio.conf" && echo "      ✓ 20-maxio.conf" || { echo "      ✗ 配置缺失"; exit 1; }
[[ -x "$DEVICE_ROOT/usr/local/bin/k1-net-setup.sh" ]] && echo "      ✓ 兜底脚本" || { echo "      ✗ 脚本缺失"; exit 1; }

echo "✅ [customize] K1 rootfs 定制完成"
