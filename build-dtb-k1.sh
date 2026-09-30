#!/usr/bin/env bash
#
# xck-nas 云编译脚本 —— KICKPI K1 (RK3568) 仅编译 DTB，不打包固件
#
# 产出：rk3568-kickpi-k1.dtb（仓库根）
#
# 说明：dts/rk3568-kickpi-k1-linux.dts 为「展开式自包含」DTS ——
#   由 KICKPI SDK6.1 官方设备树（rk3568-kickpi-k1-linux.dts 及其全部 dtsi 依赖）
#   经 cpp 预处理 + dtc 编译 + dtc 反编译完整展开而成，含全部节点与 phandle，
#   不依赖任何内核 dtsi / dt-bindings，因此只需 dtc 即可复现。
#   若要改走内核流水线（与 build-dtb.sh 同套路），设 USE_KERNEL=1。
#
set -e

DTS_NAME="rk3568-kickpi-k1-linux"
OUT_NAME="rk3568-kickpi-k1.dtb"
DTS_SRC="${DTS_SRC:-dts/${DTS_NAME}.dts}"
USE_KERNEL="${USE_KERNEL:-0}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/unifreq/linux-6.18.y.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-main}"
KERNEL_DIR="${KERNEL_DIR:-kernel}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

[ -f "$DTS_SRC" ] || { echo "!! 找不到 $DTS_SRC"; exit 1; }
command -v dtc >/dev/null 2>&1 || { echo "!! 缺少 device-tree-compiler (dtc)"; exit 1; }

echo ">>> dtc : $(dtc --version 2>&1 | head -1)"
echo ">>> dts : $DTS_SRC ($(wc -l < "$DTS_SRC") 行, $(wc -c < "$DTS_SRC") 字节)"

if [ "$USE_KERNEL" = "1" ]; then
    # 备选：借用内核 scripts/dtc 流水线（自包含 dts 其实不需要）
    if [ ! -d "$KERNEL_DIR/.git" ]; then
        echo ">>> 克隆内核 $KERNEL_REPO ($KERNEL_BRANCH)"
        git clone --depth 1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
    else
        echo ">>> 内核源码已存在"
    fi
    DTS_TARGET="arch/arm64/boot/dts/rockchip/${DTS_NAME}.dts"
    cp "$DTS_SRC" "$KERNEL_DIR/$DTS_TARGET"
    cd "$KERNEL_DIR"
    make ARCH=arm64 defconfig >/dev/null
    dtc -I dts -O dtb -b 0 -o "../$OUT_NAME" -i arch/arm64/boot/dts "$DTS_TARGET"
    cd ..
else
    echo ">>> 直接编译（自包含 dts，无需内核）"
    dtc -I dts -O dtb -b 0 -o "$OUT_NAME" "$DTS_SRC"
fi

[ -f "$OUT_NAME" ] || { echo "!! 编译失败，未找到 $OUT_NAME"; exit 1; }
echo ">>> 编译成功: $(pwd)/$OUT_NAME"
ls -l "$OUT_NAME"
sha256sum "$OUT_NAME"
