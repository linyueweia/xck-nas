#!/usr/bin/env bash
#
# xck-nas 自打包 FnNAS 完整固件脚本（最简可靠版）
#
# 方案：直接基于 fnnas.com 官方 Arm64 **rockchip** 基础镜像（已含 T68M 的
#       u-boot/内核/官方dtb），只把 boot 分区里的官方 dtb 替换成本仓库
#       编译好的「融合子板补丁」dtb（SATA2 + SDIO WiFi），重新打包成
#       完整可烧录固件。全程保留官方系统体验，子板 dtb 完全自主。
#
# 用法:
#   ./scripts/build-fnnas.sh [镜像版本号]
#     例如: ./scripts/build-fnnas.sh
#     可选指定 rockchip 基础镜像版本，如 1253 / 692，默认取最新
#
# 输出: ./out/fnnas-official-rockchip_<ver>-subboard.img.gz
#
set -e

FNNAS_ORG="ophub"
FNNAS_REPO="fnnas"
FNNAS_BASE_TAG="fnnas_base_image"

BOARD_VERSION="${1:-}"

work="$(pwd)"
img_dir="$work/base-img"
out_dir="$work/out"
fused_dtb="$work/dist/rk3568-lyt-t68m.dtb"
mount_pt="$work/boot-mnt"

echo "=================================================================="
echo " xck-nas FnNAS subboard builder  (rockchip)"
echo "=================================================================="

# 0. 前置校验：必须有融合 dtb（仓库 dist/ 下已放预编译产物）
if [[ ! -f "$fused_dtb" ]]; then
    echo "ERROR: 找不到融合 dtb: $fused_dtb"
    echo "       请先运行 ./build-dtb.sh 生成 dist/rk3568-lyt-t68m.dtb 并提交仓库"
    exit 1
fi
echo ">>> 使用融合 dtb: $(sha256sum "$fused_dtb" | cut -c1-16) ..."

# 1. 下载官方 rockchip 基础镜像 (.img.xz)
mkdir -p "$img_dir" "$out_dir" "$mount_pt"
img_xz="$(ls "$img_dir"/fnnas-official-arm64-image_rockchip_*.img.xz 2>/dev/null | head -1 || true)"
if [[ -z "$img_xz" ]]; then
    echo ">>> 下载官方基础镜像 (fnnas_base_image)"
    curl -fsSL -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$FNNAS_ORG/$FNNAS_REPO/releases/tags/$FNNAS_BASE_TAG" \
        -o /tmp/base_assets.json || { echo "ERROR: 获取 release 信息失败"; exit 1; }

    # 选出 rockchip 官方镜像并按版本号排序
    rows="$(
        jq -r '.assets[] | select(.name | test("rockchip_[0-9]+\\.img\\.xz$")) |
              [(.name|match("rockchip_([0-9]+)")|.captures[0].string|tonumber), .name, .browser_download_url] | @tsv' \
            /tmp/base_assets.json | sort -k1,1 -rn
    )"
    # 若用户指定版本则精确匹配
    if [[ -n "$BOARD_VERSION" ]]; then
        pick="$(echo "$rows" | awk -v v="$BOARD_VERSION" '$1==v')"
        [[ -z "$pick" ]] && { echo "ERROR: 未找到 rockchip_$BOARD_VERSION"; exit 1; }
    else
        pick="$(echo "$rows" | head -1)"
    fi
    url="$(echo "$pick" | cut -f3)"
    name="$(echo "$pick" | cut -f2)"
    echo ">>> 基础镜像: $name"
    curl -fL "$url" -o "$img_dir/$name"
    img_xz="$img_dir/$name"
else
    echo ">>> 官方基础镜像已存在: $(basename "$img_xz")"
fi

# 2. 解压 .img.xz -> .img
img_file="$(basename "$img_xz" .xz)"
if [[ ! -f "$img_dir/$img_file" ]]; then
    echo ">>> 解压基础镜像 -> $img_file (约 7G，请稍候)"
    xz -dc "$img_xz" > "$img_dir/$img_file"
fi
full_img="$img_dir/$img_file"
echo ">>> 完整镜像: $full_img ($(du -h "$full_img" | cut -f1))"
df -h . | tail -1

# 3. 挂载 boot 分区，替换 dtb
echo ">>> 挂载 boot 分区并注入融合 dtb ..."
loop_dev="$(sudo losetup -fP --show "$full_img")"
if [[ -z "$loop_dev" ]]; then
    echo "ERROR: losetup 失败"; exit 1
fi
echo ">>> loop: $loop_dev 分区: $(ls "$loop_dev"p* 2>/dev/null | tr '\n' ' ')"
sudo mount -o rw "${loop_dev}p1" "$mount_pt" || { echo "ERROR: 挂载 boot 分区失败"; sudo losetup -d "$loop_dev"; exit 1; }

dtb_target="$mount_pt/dtb/rockchip/rk3568-lyt-t68m.dtb"
if [[ -f "$dtb_target" ]]; then
    echo ">>> 备份官方 dtb 并写入融合 dtb"
    sudo cp -p "$dtb_target" "$dtb_target.official.bak"
    sudo cp -p "$fused_dtb" "$dtb_target"
    echo ">>> 已写入: $(sudo sha256sum "$dtb_target" | cut -c1-16)"
    sudo sed -i 's|fdtfile=.*|fdtfile=rockchip/rk3568-lyt-t68m.dtb|' "$mount_pt/armbianEnv.txt" 2>/dev/null || true
    echo ">>> armbianEnv fdtfile: $(grep -h fdtfile "$mount_pt/armbianEnv.txt" 2>/dev/null)"
else
    echo "ERROR: boot 分区中未找到 $dtb_target"; sudo umount "$mount_pt"; sudo losetup -d "$loop_dev"; exit 1
fi

sync
sudo umount "$mount_pt"
sudo losetup -d "$loop_dev"
sync

# 4. 压缩成最终产物
ver="$(echo "$img_file" | sed -E 's/.*rockchip_([0-9]+)\.img/\1/')"
final="$out_dir/fnnas-official-rockchip_${ver}-subboard.img.gz"
echo ">>> 压缩最终固件 ..."
gzip -1 -c "$full_img" > "$final"

# 5. 校验
echo "=================================================================="
echo " 完成。最终固件："
ls -lah "$final"
echo " MD5   : $(md5sum "$final" | cut -d' ' -f1)"
echo " SHA256: $(sha256sum "$final" | cut -d' ' -f1)"
echo " 内含融合 dtb SHA256: $(sha256sum "$fused_dtb" | cut -d' ' -f1)"
echo "=================================================================="
