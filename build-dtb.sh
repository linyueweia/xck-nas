#!/usr/bin/env bash
#
# xck-nas 云编译脚本（仅编译 DTB，不打包固件）
#
# 基于飞牛主线内核 unifreq/linux-6.12.y，编译融合子板补丁
# （SATA2 + SDIO WiFi）且含 NPU/多媒体节点（npu@fde40000 / rkvdec /
# rkvenc / jpegd / iep / mpp-srv 等完整集群）的 LYT T68M (RK3568)
# 设备树 rk3568-lyt-t68m.dtb。
#
# 说明：dts/rk3568-lyt-t68m.dts 为展开式自包含 DTS（含全部节点与
# phandle 定义，不依赖内核 dtsi），克隆内核仅用于复用其 scripts/dtc
# 编译流水线；即使未来主线 dtsi 变化也不影响本 DTB 复现。
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

# 2. 用完整 dts 覆盖主线已有的同名校验文件
DTS_TARGET="arch/arm64/boot/dts/rockchip/rk3568-lyt-t68m.dts"
echo ">>> 覆盖设备树: $DTS_SRC -> $KERNEL_DIR/$DTS_TARGET"
cp "$DTS_SRC" "$KERNEL_DIR/$DTS_TARGET"
if grep -q "rk3568-lyt-t68m.dtb" "$KERNEL_DIR/arch/arm64/boot/dts/rockchip/Makefile"; then
    echo ">>> Makefile 已含 rk3568-lyt-t68m.dtb 条目"
else
    echo "!! 警告: Makefile 中未找到 rk3568-lyt-t68m.dtb，请检查内核版本"
fi

# 3. 生成 defconfig（确保 ARCH_ROCKCHIP 开启；编译 dtbs 无需交叉工具链）
cd "$KERNEL_DIR"
echo ">>> 生成 defconfig"
make ARCH=arm64 defconfig >/dev/null

# 4. 编译 device tree
echo ">>> 编译 dtb (jobs=$JOBS)"
make ARCH=arm64 dtbs -j"$JOBS"

# 5. 输出
OUT="arch/arm64/boot/dts/rockchip/rk3568-lyt-t68m.dtb"
if [ -f "$OUT" ]; then
    echo ">>> 编译成功: $OUT"
    cp "$OUT" ../rk3568-lyt-t68m.dtb
    echo ">>> 产出: $(pwd)/../rk3568-lyt-t68m.dtb"
    sha256sum ../rk3568-lyt-t68m.dtb
else
    echo "!! 编译失败，未找到 $OUT"
    exit 1
fi