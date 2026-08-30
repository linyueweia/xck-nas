#!/usr/bin/env bash
#
# xck-nas 云编译脚本
# 基于飞牛主线内核 unifreq/linux-6.12.y，编译融合子板补丁(SATA2 + SDIO WiFi)的
# LYT T68M (RK3568) 设备树 rk3568-lyt-t68m.dtb，用于飞牛 fnOS。
#
set -e

KERNEL_REPO="${KERNEL_REPO:-https://github.com/unifreq/linux-6.12.y.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-main}"
DTS_SRC="${DTS_SRC:-dts/rk3568-lyt-t68m.dts}"
KERNEL_DIR="${KERNEL_DIR:-kernel}"
JOBS="${JOBS:-$(nproc)}"

# 1. 拉取飞牛主线内核源码
if [ ! -d "$KERNEL_DIR/.git" ]; then
    echo ">>> 克隆飞牛主线内核 $KERNEL_BRANCH"
    git clone --depth 1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
else
    echo ">>> 内核源码已存在"
fi

# 2. 用融合后的 dts 覆盖主线已有的同名校验文件
DTS_TARGET="arch/arm64/boot/dts/rockchip/rk3568-lyt-t68m.dts"
echo ">>> 覆盖设备树: $DTS_SRC -> $KERNEL_DIR/$DTS_TARGET"
cp "$DTS_SRC" "$KERNEL_DIR/$DTS_TARGET"
grep -q "rk3568-lyt-t68m.dtb" "$KERNEL_DIR/arch/arm64/boot/dts/rockchip/Makefile" \
    && echo ">>> Makefile 已含 rk3568-lyt-t68m.dtb 条目" \
    || echo "!! 警告: Makefile 中未找到 rk3568-lyt-t68m.dtb"

# 3. 配置内核（确保 ARCH_ROCKCHIP 开启，arm64 defconfig 默认已开）
cd "$KERNEL_DIR"
echo ">>> 生成 defconfig"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig >/dev/null
# 兜底确保 rockchip 子树被编译
if grep -q "CONFIG_ARCH_ROCKCHIP" .config; then
    grep "CONFIG_ARCH_ROCKCHIP" .config || true
else
    echo "CONFIG_ARCH_ROCKCHIP=y" >> .config
    sed -i 's/# CONFIG_ARCH_ROCKCHIP is not set/CONFIG_ARCH_ROCKCHIP=y/' .config || true
fi

# 4. 编译 device tree
echo ">>> 编译 dtb (jobs=$JOBS)"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- dtbs -j"$JOBS"

# 5. 输出
OUT="arch/arm64/boot/dts/rockchip/rk3568-lyt-t68m.dtb"
if [ -f "$OUT" ]; then
    echo ">>> 编译成功: $OUT"
    cp "$OUT" ../rk3568-lyt-t68m.dtb
    echo ">>> 产出: $(pwd)/../rk3568-lyt-t68m.dtb"
else
    echo "!! 编译失败，未找到 $OUT"
    exit 1
fi
