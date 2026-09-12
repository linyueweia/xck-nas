#!/bin/bash
# FNNAS 镜像自动修改与打包脚本（CI / GitHub Actions 专用）

set -euo pipefail

echo "========================================"
echo "FNNAS 镜像自动修改与打包脚本 (CI版)"
echo "========================================"
echo

: "${DEVICE:?❌ 请指定 DEVICE，例如：DEVICE=lyt-t68m}"

IMG_DIR="fnnas-arm64"
OUT_DIR="$(pwd)/out"
UBOOT_BASE="uboot"
UBOOT_PATH=""

ROOT_SIZE="${ROOT_SIZE:-}"   # 保留变量以兼容调用方引用；默认空 = 官方 resize 行为（固件大小与官方一致）

ROOT_MOUNT="/mnt/fnnas_root"
BOOT_MOUNT="/mnt/fnnas_boot"

# 产物命名（官方风格）：fnos_Mainland-PE_arm_<版本>_<设备标识>_<构建号>.img
#  - DEVICE        : 设备目录名（小写，用于匹配 uboot/<soc>/<device>）
#  - DEVICE_LABEL  : 文件名中的设备标识（默认 = DEVICE；CI 传 LYT-T68M）
#  - BUILD_NUM     : 构建号（CI 传 run_number；本地默认日期）
: "${DEVICE_LABEL:=${DEVICE}}"
: "${BUILD_NUM:=$(date +%Y%m%d)}"
FNOS_VERSION=""   # 构建期间从 rootfs /etc/os-release 读取

mkdir -p "$OUT_DIR" || { echo "❌ 创建输出目录失败"; exit 1; }

SOC_MATCHES=()
DEVICE_LC=$(printf '%s' "$DEVICE" | tr '[:upper:]' '[:lower:]')
for soc_dir in "$UBOOT_BASE"/*; do
  [[ -d "$soc_dir" ]] || continue
  shopt -s nullglob
  for dev_dir in "$soc_dir"/*; do
    [[ -d "$dev_dir" ]] || continue
    dev_base=$(basename "$dev_dir")
    dev_lc=$(printf '%s' "$dev_base" | tr '[:upper:]' '[:lower:]')
    [[ "$dev_lc" == "$DEVICE_LC" ]] && SOC_MATCHES+=("$dev_dir")
  done
done

if [[ ${#SOC_MATCHES[@]} -eq 0 ]]; then
  echo "❌ 未在 $UBOOT_BASE/*/<device> 找到设备目录 (不区分大小写): $DEVICE"; exit 1
elif [[ ${#SOC_MATCHES[@]} -gt 1 ]]; then
  echo "❌ 找到多个匹配目录，无法确定:";
  printf ' - %s\n' "${SOC_MATCHES[@]}"
  exit 1
else
  UBOOT_PATH="${SOC_MATCHES[0]}"
  echo "✅ 使用设备目录: $UBOOT_PATH"
fi

ORIGINAL_IMG=$(find "$IMG_DIR" -maxdepth 1 -name "*.img" | head -n 1)
[[ -n "$ORIGINAL_IMG" ]] || { echo "❌ 未找到原始 .img 镜像"; exit 1; }
echo "✅ 找到原始镜像: $ORIGINAL_IMG"

TIMESTAMP=$(date +%Y%m%d)
MODIFIED_IMG="$OUT_DIR/${DEVICE_LABEL}_${BUILD_NUM}.img"

echo "📋 创建镜像副本:"
echo "   $MODIFIED_IMG"
cp "$ORIGINAL_IMG" "$MODIFIED_IMG" || { echo "❌ 复制镜像失败"; exit 1; }

echo
echo "1️⃣ 校验设备目录: $DEVICE"
shopt -s nullglob
[[ -f "$UBOOT_PATH/fnEnv.txt" ]] || { echo "❌ 缺少 $UBOOT_PATH/fnEnv.txt"; exit 1; }

has_group_a=0
has_group_b=0

[[ -f "$UBOOT_PATH/idbloader.img" && -f "$UBOOT_PATH/u-boot.itb" ]] && has_group_a=1
[[ -f "$UBOOT_PATH/idbloader.bin" && -f "$UBOOT_PATH/uboot.img" && -f "$UBOOT_PATH/trust.bin" ]] && has_group_b=1

BOOT_GROUP_RAW="${BOOT_GROUP:-auto}"
BOOT_GROUP_UPPER=$(printf '%s' "$BOOT_GROUP_RAW" | tr '[:lower:]' '[:upper:]')

if [[ "$BOOT_GROUP_UPPER" == "AUTO" ]]; then
  if [[ $has_group_a -eq 1 && $has_group_b -eq 1 ]]; then
    echo "❌ 同时存在两种启动格式，请通过 BOOT_GROUP=A 或 BOOT_GROUP=B 指定"; exit 1
  elif [[ $has_group_a -eq 1 ]]; then
    BOOT_GROUP_UPPER="A"
  elif [[ $has_group_b -eq 1 ]]; then
    BOOT_GROUP_UPPER="B"
  else
    echo "❌ 未找到可用的启动文件组 (A 或 B)"; exit 1
  fi
elif [[ "$BOOT_GROUP_UPPER" == "A" ]]; then
  [[ $has_group_a -eq 1 ]] || { echo "❌ 已指定 BOOT_GROUP=A 但缺少 idbloader.img/u-boot.itb"; exit 1; }
elif [[ "$BOOT_GROUP_UPPER" == "B" ]]; then
  [[ $has_group_b -eq 1 ]] || { echo "❌ 已指定 BOOT_GROUP=B 但缺少 idbloader.bin/uboot.img/trust.bin"; exit 1; }
else
  echo "❌ BOOT_GROUP 仅支持 A/B/auto"; exit 1
fi

echo "✅ 设备文件齐全 (使用启动格式: $BOOT_GROUP_UPPER)"

echo
echo "2️⃣ 注入 Rockchip Bootloader ($BOOT_GROUP_UPPER)"

if [[ "$BOOT_GROUP_UPPER" == "A" ]]; then
  sudo dd if="$UBOOT_PATH/idbloader.img" of="$MODIFIED_IMG" bs=512 seek=64 conv=notrunc,fsync status=none || { echo "❌ 写入 idbloader.img 失败"; exit 1; }
  sudo dd if="$UBOOT_PATH/u-boot.itb"    of="$MODIFIED_IMG" bs=512 seek=16384 conv=notrunc,fsync status=none || { echo "❌ 写入 u-boot.itb 失败"; exit 1; }
else
  sudo dd if="$UBOOT_PATH/idbloader.bin" of="$MODIFIED_IMG" bs=512 seek=64 conv=notrunc,fsync status=none || { echo "❌ 写入 idbloader.bin 失败"; exit 1; }
  sudo dd if="$UBOOT_PATH/uboot.img"    of="$MODIFIED_IMG" bs=512 seek=16384 conv=notrunc,fsync status=none || { echo "❌ 写入 uboot.img 失败"; exit 1; }
  sudo dd if="$UBOOT_PATH/trust.bin"     of="$MODIFIED_IMG" bs=512 seek=24576 conv=notrunc,fsync status=none || { echo "❌ 写入 trust.bin 失败"; exit 1; }
fi
sync
echo "✅ Bootloader 注入完成"

echo
echo "3️⃣ 挂载镜像并修改配置"

sudo mkdir -p "$BOOT_MOUNT" "$ROOT_MOUNT" || { echo "❌ 创建挂载目录失败"; exit 1; }

cleanup() {
  sudo umount "$BOOT_MOUNT" 2>/dev/null || true
  sudo umount "$ROOT_MOUNT" 2>/dev/null || true
  [[ -n "${LOOP_DEVICE:-}" ]] && sudo losetup -d "$LOOP_DEVICE" 2>/dev/null || true
}
trap cleanup EXIT

LOOP_DEVICE=$(sudo losetup -fP --show "$MODIFIED_IMG") || { echo "❌ losetup 失败"; exit 1; }
echo "🔗 Loop 设备: $LOOP_DEVICE"

sleep 2

BOOT_PART="${LOOP_DEVICE}p1"
[[ -e "$BOOT_PART" ]] || BOOT_PART="${LOOP_DEVICE}1"
[[ -e "$BOOT_PART" ]] || { echo "❌ boot 分区不存在"; exit 1; }

sudo mount "$BOOT_PART" "$BOOT_MOUNT" || { echo "❌ 挂载 boot 分区失败"; exit 1; }
echo "✏️ 替换 boot 分区 fnEnv.txt"
sudo cp "$UBOOT_PATH/fnEnv.txt" "$BOOT_MOUNT/fnEnv.txt" || { echo "❌ 写入 fnEnv.txt 失败"; exit 1; }

# 检查并处理 extlinux.conf
EXTLINUX_CONF_PATH="$BOOT_MOUNT/extlinux/extlinux.conf"
UBOOT_EXTLINUX_PATH="$UBOOT_PATH/extlinux.conf"

if [[ -f "$EXTLINUX_CONF_PATH" ]]; then
  if [[ -f "$UBOOT_EXTLINUX_PATH" ]]; then
    echo "✏️ 替换 extlinux/extlinux.conf"
    sudo cp "$UBOOT_EXTLINUX_PATH" "$EXTLINUX_CONF_PATH" || { echo "❌ 写入 extlinux.conf 失败"; exit 1; }
  else
    echo "⚠️ 找到 $EXTLINUX_CONF_PATH 但 $UBOOT_EXTLINUX_PATH 不存在"
  fi
else
  echo "ℹ️ 未找到 $EXTLINUX_CONF_PATH，跳过处理"
fi

# 将本设备目录下所有 *.dtb 强制覆盖写入 boot 分区 dtb/rockchip（保证自定义 DTB 生效）
shopt -s nullglob
DTB_FILES=("$UBOOT_PATH"/*.dtb)
if [[ ${#DTB_FILES[@]} -gt 0 ]]; then
  DTB_TARGET_DIR="$BOOT_MOUNT/dtb/rockchip"
  sudo mkdir -p "$DTB_TARGET_DIR" || { echo "❌ 创建 $DTB_TARGET_DIR 失败"; exit 1; }
  for dtb_file in "${DTB_FILES[@]}"; do
    dtb_filename=$(basename "$dtb_file")
    dest="$DTB_TARGET_DIR/$dtb_filename"
    echo "✏️ 覆盖写入 DTB: $dtb_filename -> dtb/rockchip"
    sudo cp -f "$dtb_file" "$dest" || { echo "❌ 复制 $dtb_filename 失败"; exit 1; }
  done
else
  echo "⚠️ 设备目录未找到任何 .dtb 文件"
fi

sudo umount "$BOOT_MOUNT" || { echo "❌ 卸载 boot 分区失败"; exit 1; }

ROOT_PART="${LOOP_DEVICE}p2"
[[ -e "$ROOT_PART" ]] || ROOT_PART="${LOOP_DEVICE}2"
[[ -e "$ROOT_PART" ]] || { echo "❌ root 分区不存在"; exit 1; }

sudo mount "$ROOT_PART" "$ROOT_MOUNT" || { echo "❌ 挂载 root 分区失败"; exit 1; }

# 不扩容：rootfs 保持官方默认大小，不做任何修改

# 读取 fnOS 版本号用于产物命名（/etc/os-release 是 Debian/fnOS 标准位置）
FNOS_VERSION=$(sed -n 's/^VERSION_ID="\?\([^"]*\)"\?/\1/p' "$ROOT_MOUNT/etc/os-release" 2>/dev/null | head -n1)
[[ -n "$FNOS_VERSION" ]] || { echo "⚠️ 无法从 rootfs 读取 VERSION_ID，跳过版本号"; }

sudo umount "$ROOT_MOUNT" || { echo "❌ 卸载 root 分区失败"; exit 1; }

cleanup
echo "✅ 分区处理完成"

echo
echo "========================================"
echo "🎉 处理完成"
echo "📦 设备: $DEVICE ($DEVICE_LABEL)"
echo "📁 输出目录: $OUT_DIR"
echo "📦 镜像文件: $(basename "$MODIFIED_IMG")"
echo "========================================"

# 官方风格最终命名：fnos_Mainland-PE_arm_<VER>_<DEVICE>_<BUILD>.img
if [[ -n "$FNOS_VERSION" ]]; then
  FINAL_IMG="$OUT_DIR/fnos_Mainland-PE_arm_${FNOS_VERSION}_${DEVICE_LABEL}_${BUILD_NUM}.img"
  mv "$MODIFIED_IMG" "$FINAL_IMG" || { echo "❌ 重命名输出镜像失败"; exit 1; }
  echo "📦 最终产物: $(basename "$FINAL_IMG")"
fi
exit 0