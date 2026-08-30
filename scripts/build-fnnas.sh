#!/usr/bin/env bash
#
# xck-nas 自打包 FnNAS 完整固件脚本
#
# 全程基于 fnnas.com 官方 Arm64 基础镜像（renas 的标准输入），
# 复用 GPL 开源的 ophub renas/u-boot/内核 底料打包，最后把
# 本仓库编译好的「融合子板补丁」dtb（rk3568-lyt-t68m.dtb）注入
# boot 分区，确保 T68M 的子板（SATA2 + SDIO WiFi）可用。
#
# 用法:
#   ./scripts/build-fnnas.sh [model] [kernel]
#     model  目标设备，默认 lyt-t68m
#     kernel renas 的 -k 参数（内核版本），默认留空走 auto
#
# 输出的完整固件在 ./out/ 目录（fnnas_rockchip_lyt-t68m_k*.img.gz）
#
set -e

BASE_URL="https://github.com/ophub/fnnas"
FNNAS_BASE_TAG="fnnas_base_image"

BOARD="${1:-lyt-t68m}"
KERNEL_ARG="${2:-}"

work="$(pwd)"
src="$work/fnnas-src"
img_dir="$work/fnnas-arm64"
out_dir="$work/out"
fused_dtb="$work/rk3568-lyt-t68m.dtb"

echo "=================================================================="
echo " xck-nas FnNAS builder  (board=${BOARD})"
echo "=================================================================="

# 0. 前置校验：必须有融合 dtb（编译产物）
if [[ ! -f "$fused_dtb" ]]; then
    echo "ERROR: 找不到融合 dtb: $fused_dtb"
    echo "       请先运行 ./build-dtb.sh 生成 rk3568-lyt-t68m.dtb"
    exit 1
fi
echo ">>> 使用融合 dtb: $(sha256sum "$fused_dtb" | cut -c1-12) ..."

# 1. 拉取 renas 源码
if [[ ! -d "$src/.git" ]]; then
    echo ">>> 克隆 ophub/fnnas (renas)"
    git clone --depth 1 "$BASE_URL" "$src"
else
    echo ">>> renas 源码已存在"
fi

# 2. 获取官方基础镜像
mkdir -p "$img_dir"
if ! compgen -G "$img_dir/fnnas-official-arm64-image_*.img.xz" >/dev/null; then
    echo ">>> 下载官方基础镜像 (fnnas_base_image)"
    # 通过 releases/tags 接口获取，明确选择 rockchip 平台
    curl -fsSL -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/ophub/fnnas/releases/tags/$FNNAS_BASE_TAG" \
        -o /tmp/base_assets.json || {
            echo "ERROR: 无法获取 $FNNAS_BASE_TAG release 信息"
            exit 1
        }
    # 取最新的 rockchip 官方镜像（按名字中版本号倒序）
    img_url="$(
        jq -r '.assets[] | select(.name | test("rockchip_[0-9]+\\.img\\.xz$")) |
              [(.name|match("rockchip_([0-9]+)")|.captures[0].string | tonumber), .browser_download_url] | @tsv' \
            /tmp/base_assets.json | sort -k1,1 -rn | head -1 | cut -f2
    )"
    if [[ -z "$img_url" ]]; then
        echo "ERROR: 未在 $FNNAS_BASE_TAG 找到 rockchip 基础镜像"
        jq -r '.assets[]?.name // empty' /tmp/base_assets.json | head
        exit 1
    fi
    echo ">>> 基础镜像: $img_url"
    curl -fL "$img_url" -o "$img_dir/$(basename "$img_url")"
else
    echo ">>> 官方基础镜像已存在"
fi

# 3. 安装构建依赖（本地跑时用到；GitHub Actions 环境已装）
if [[ "${SKIP_APT:-0}" != "1" ]]; then
    command -v losetup >/dev/null || sudo apt-get install -y --no-install-recommends \
        btrfs-progs dosfstools parted gdisk util-linux uuid-runtime \
        build-essential fakeroot pigz xz-utils zstd curl xz-utils jq gawk
fi

# 4. 运行 renas 打包（用 renas 自带配置，内核自动选最新）
cd "$src"
chmod +x renas
echo ">>> 运行 renas 打包 ${BOARD} ..."
if [[ -n "$KERNEL_ARG" ]]; then
    sudo ./renas -b "$BOARD" -k "$KERNEL_ARG"
else
    sudo ./renas -b "$BOARD"
fi

# 5. 把融合 dtb 注入最终产物
cd "$work"
echo ">>> 注入融合 dtb 到产物 boot 分区 ..."
for img in "$src"/out/*.img; do
    [[ -e "$img" ]] || continue
    echo "处理: $(basename "$img")"
    boostrap_loop="$(sudo losetup -fP --show "$img")"
    if [[ -z "$boostrap_loop" ]]; then
        echo "!! losetup 失败，跳过 dtb 注入"
        continue
    fi
    sudo mount -o rw "${boostrap_loop}p1" /mnt
    if [[ -f "/mnt/dtb/rockchip/rk3568-lyt-t68m.dtb" ]]; then
        # 备份官方 dtb，写入融合 dtb
        sudo cp -p /mnt/dtb/rockchip/rk3568-lyt-t68m.dtb \
            /mnt/dtb/rockchip/rk3568-lyt-t68m.dtb.official.bak
        sudo cp -p "$fused_dtb" /mnt/dtb/rockchip/rk3568-lyt-t68m.dtb
        echo "   已注入融合 dtb: $(sudo sha256sum /mnt/dtb/rockchip/rk3568-lyt-t68m.dtb | cut -c1-12)"
    else
        # 兼容 dtb 位于 /boot/dtb 或 extlinux 布局
        for cand in /mnt/dtb/rockchip/rk3568-lyt-t68m.dtb /mnt/boot/dtb/rockchip/rk3568-lyt-t68m.dtb; do
            if [[ -f "$cand" ]]; then
                sudo cp -p "$fused_dtb" "$cand"
                echo "   已注入融合 dtb: $cand"
                break
            fi
        done
    fi
    sync
    sudo umount /mnt
    sudo losetup -d "$boostrap_loop"
    sync
done

# 6. 收集产物与校验
mkdir -p "$out_dir"
echo "=================================================================="
echo " 完成。产物列表："
ls -lah "$src"/out/ | grep "\.img" || true
find "$src"/out -name "*.img*" -exec cp -v {} "$out_dir/" \;
echo "=================================================================="
