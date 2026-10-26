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
has_group_u=0
# 2026-10-27：改用【LYW 仓构建的 iStoreOS U-Boot】（32MiB，RKNS idbloader + u-boot.itb 一体）：
#   U-Boot 2025.10-OpenWrt-r33338-0465e2cf57 / ddr-v1.23-03ea844c5d
#   boot_targets=mmc1 mmc0 nvme scsi usb …（mmc 优先）/ 含 fdt_fixup_memory
#   取法：gzip -dc istoreos-rockchip-armv8-lyt_lyw-squashfs-sysupgrade.img.gz | head -c 32M
# 弃用飞牛官方 2026.04-TRIM：该引导件在 RK3568 板上跑不完全链路（实测 booti 后无输出）。
UNIVERSAL_UBOOT="${UNIVERSAL_UBOOT:-uboot/lyw-istoreos-first32m.bin}"
[[ -f "$UNIVERSAL_UBOOT" ]] && has_group_u=1

[[ -f "$UBOOT_PATH/idbloader.img" && -f "$UBOOT_PATH/u-boot.itb" ]] && has_group_a=1
[[ -f "$UBOOT_PATH/idbloader.bin" && -f "$UBOOT_PATH/uboot.img" && -f "$UBOOT_PATH/trust.bin" ]] && has_group_b=1

BOOT_GROUP_RAW="${BOOT_GROUP:-auto}"
BOOT_GROUP_UPPER=$(printf '%s' "$BOOT_GROUP_RAW" | tr '[:lower:]' '[:upper:]')

if [[ "$BOOT_GROUP_UPPER" == "AUTO" ]]; then
  if [[ $has_group_u -eq 1 ]]; then
    BOOT_GROUP_UPPER="U"
  elif [[ $has_group_a -eq 1 && $has_group_b -eq 1 ]]; then
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
elif [[ "$BOOT_GROUP_UPPER" == "U" ]]; then
  [[ $has_group_u -eq 1 ]] || { echo "❌ 已指定 BOOT_GROUP=U 但缺少 $UNIVERSAL_UBOOT"; exit 1; }
else
  echo "❌ BOOT_GROUP 仅支持 A/B/U/auto"; exit 1
fi

echo "✅ 设备文件齐全 (使用启动格式: $BOOT_GROUP_UPPER)"

echo
echo "2️⃣ 注入 Rockchip Bootloader ($BOOT_GROUP_UPPER)"

if [[ "$BOOT_GROUP_UPPER" == "U" ]]; then
  [[ "$(stat -c%s "$UNIVERSAL_UBOOT")" -eq 33554432 ]] || { echo "❌ 通用 U-Boot 必须是 32MiB 提取件"; exit 1; }
  sudo dd if="$UNIVERSAL_UBOOT" of="$MODIFIED_IMG" bs=512 skip=34 seek=34 conv=notrunc,fsync status=none || { echo "❌ 写入通用 U-Boot 失败"; exit 1; }
  python3 - "$MODIFIED_IMG" <<'PYU'
import sys
d=open(sys.argv[1],'rb').read(32*1024*1024)
assert d[0x8000:0x8004]==b'RKNS', "通用 U-Boot: idbloader 魔数缺失"
assert d[0x800000:0x800004]==bytes.fromhex('d00dfeed'), "通用 U-Boot: FIT 魔数缺失"
# 注意：版本串与 boot_targets 都在 FIT 负载里（本件 0x89fb64 / 0x89e266），
# 不能只看前 8MiB（0x800010）—— 那里只有 FIT 头。全量搜 32MiB 前缀。
assert b'U-Boot 2025.10-OpenWrt' in d, "U-Boot 版本串不对（应含 U-Boot 2025.10-OpenWrt）"
assert b'boot_targets=mmc1 mmc0' in d, "boot_targets 不是 mmc 优先"
assert b'boot_targets=usb mmc1 mmc0' not in d, "boot_targets 仍是 usb 优先（插 USB 盘就抢引导）"
assert b'ddr-v1.23' in d, "DDR 固件不是 v1.23（与本板 eMMC 原厂一致的版本）"
assert b'fdt_fixup_memory' in d, "缺 fdt_fixup_memory（内存靠它注入）"
print("✅ LYW iStoreOS U-Boot 注入断言通过（RKNS + FIT + 2025.10-OpenWrt + mmc 优先 + ddr-v1.23 + memory 注入）")
PYU
elif [[ "$BOOT_GROUP_UPPER" == "A" ]]; then
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
# ── fnEnv.txt：以【基镜像自带】为底稿，只覆盖必须改的键 ──────────────────────
# 血的教训（2026-10-27）：原来把仓库里的静态 fnEnv 整份覆盖进 p1，里面写死
#   kernelfile=vmlinuz-6.18.18.c951-trim，而基镜像 latest 已是 6.18.18.c1145-trim →
#   boot.scr 按名找不到内核文件，固件刷进去必黑。
# 正确做法（与官方 boot.cmd 的契约一致）：保留基镜像的 kernelfile/verbosity/console/
#   earlycon/extraargs，只把 fdtfile 指到本板 DTB；kernelfile 若指向不存在的文件，
#   自动改成本板 p1 里唯一的 vmlinuz-*（并断言它真实存在）。
echo "✏️ 合并 fnEnv.txt（以基镜像为底稿，只改 fdtfile）"
sudo cat "$BOOT_MOUNT/fnEnv.txt" > /tmp/base_fnEnv.txt 2>/dev/null || : > /tmp/base_fnEnv.txt
grep -q . /tmp/base_fnEnv.txt || echo "ℹ️ 基镜像无 fnEnv.txt，改用仓库模板 + 自动探测内核"
python3 - "$BOOT_MOUNT" "$UBOOT_PATH/fnEnv.txt" /tmp/base_fnEnv.txt /tmp/new_fnEnv.txt <<'PYF'
import os, sys, glob
boot, tpl_p, base_p, out_p = sys.argv[1:5]

def parse(p):
    d = {}
    if os.path.exists(p):
        for ln in open(p, encoding='utf-8', errors='replace'):
            ln = ln.strip()
            if not ln or ln.startswith('#') or '=' not in ln:
                continue
            k, v = ln.split('=', 1)
            d[k.strip()] = v.strip()
    return d

base, tpl = parse(base_p), parse(tpl_p)
# 底稿：基镜像优先；基镜像没有的键才用模板补
env = dict(tpl); env.update(base)
if not base:
    env = dict(tpl)
# extraargs 属于板级故意覆盖（如 cma 大小），模板给了就以模板为准
if 'extraargs' in tpl and tpl['extraargs'] != base.get('extraargs'):
    env['extraargs'] = tpl['extraargs']
    print(f"  · extraargs 用板级模板覆盖: {tpl['extraargs']}（基镜像为 {base.get('extraargs') or '(无)'}）")

# 本板 p1 里真实存在的内核文件
kerns = sorted(os.path.basename(x) for x in glob.glob(os.path.join(boot, 'vmlinuz*')))
ker = env.get('kernelfile', '')
if ker and os.path.exists(os.path.join(boot, ker)):
    pass                                   # 基镜像的 kernelfile 有效 → 原样保留
elif kerns:
    old_ker = ker
    env['kernelfile'] = kerns[0]
    print(f"  ⚠ kernelfile '{old_ker or '(未设置)'}' 在 p1 不存在 → 改为 {kerns[0]}")
else:
    sys.exit("❌ p1 里没有任何 vmlinuz* 内核文件，无法引导")

# 只强制改 fdtfile（本板 DTB）
fdt = tpl.get('fdtfile')
if not fdt:
    sys.exit("❌ 模板 fnEnv 没给 fdtfile")
env['fdtfile'] = fdt

order = ['verbosity', 'bootlogo', 'console', 'earlycon', 'extraargs', 'kernelfile', 'fdtfile', 'initrdfile']
lines = [f"{k}={env[k]}" for k in order if k in env]
lines += [f"{k}={v}" for k, v in env.items() if k not in order]
open(out_p, 'w', encoding='utf-8').write("\n".join(lines) + "\n")
print("  ── 合并结果 ──")
for l in lines:
    print("     " + l)
ker = env['kernelfile']
kp = os.path.join(boot, ker)
if not os.path.exists(kp):
    sys.exit(f"❌ 断言失败：kernelfile={ker} 在 p1 不存在")
sz = os.path.getsize(kp)
if sz < 5 * 1024 * 1024:
    sys.exit(f"❌ 内核文件只有 {sz} B，不正常")
with open(kp, 'rb') as f:
    head = f.read(0x40)
if b'ARMd' not in head and not head[:2] == b'\x1f\x8b':
    sys.exit("❌ 内核文件既不是未压缩 arm64 Image(ARMd) 也不是 gzip，可疑")
print(f"  ✅ kernelfile 存在且形态正常（{ker}, {sz:,} B）")
PYF
sudo cp /tmp/new_fnEnv.txt "$BOOT_MOUNT/fnEnv.txt" || { echo "❌ 写入 fnEnv.txt 失败"; exit 1; }
[[ -f "$BOOT_MOUNT/boot.scr" ]] || echo "⚠️ p1 缺 boot.scr —— 官方引导脚本不在，bootflow 走不到 fnEnv"

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

# 不扩容：rootfs 保持官方默认大小
# 最小化注入（2026-10-15 定案，与 lyw-kf 同款两层修复的第二层）：
#   硬件看门狗保命件 —— 官方 fnOS 对 /dev/watchdog 零管理（/usr/trim 无一引用，
#   K1 实机取证同款），内核整机挂死（如 NPU CMA 分配失败路径）只能人工断电；
#   注入持续喂狗脚本 + systemd 单元开机自启，挂死时由硬件超时硬复位自愈。
sudo install -Dm755 assets/lyt-t68m-watchdog.sh "$ROOT_MOUNT/usr/local/sbin/lyt-t68m-watchdog.sh" \
  || { echo "❌ 注入 lyt-t68m-watchdog.sh 失败"; exit 1; }
sudo install -Dm644 assets/lyt-t68m-watchdog.service "$ROOT_MOUNT/etc/systemd/system/lyt-t68m-watchdog.service" \
  || { echo "❌ 注入 lyt-t68m-watchdog.service 失败"; exit 1; }
sudo mkdir -p "$ROOT_MOUNT/etc/systemd/system/multi-user.target.wants"
sudo ln -sf ../lyt-t68m-watchdog.service \
  "$ROOT_MOUNT/etc/systemd/system/multi-user.target.wants/lyt-t68m-watchdog.service" \
  || { echo "❌ 启用 lyt-t68m-watchdog.service 失败"; exit 1; }
# 自检：三件缺一即构建失败（-L 判使能链接，避免跟随链接按 CI runner 根解析误判）
[[ -x "$ROOT_MOUNT/usr/local/sbin/lyt-t68m-watchdog.sh" ]] || { echo "❌ 自检：喂狗脚本未就位"; exit 1; }
[[ -f "$ROOT_MOUNT/etc/systemd/system/lyt-t68m-watchdog.service" ]] || { echo "❌ 自检：单元文件未就位"; exit 1; }
[[ -L "$ROOT_MOUNT/etc/systemd/system/multi-user.target.wants/lyt-t68m-watchdog.service" ]] \
  || { echo "❌ 自检：单元未启用（wants 缺链）"; exit 1; }
echo "✅ 已注入硬件看门狗保命件（lyt-t68m-watchdog.service，开机自启）"

# 读取 fnOS 版本号仅作日志信息（产物命名已定案为固定 IMG_NAME，不再拼版本/构建号）
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

# 官方风格最终命名（2026-10-15 定案）：fnos_Mainland-PE_arm_<Debian主版本>_<设备标识>.img
#   例：fnos_Mainland-PE_arm_12_LYT-T68M.img —— 不再拼构建号后缀（多构建并存由 Release tag 区分）；
#   IMG_DEBIAN_MAJOR / IMG_NAME 均可环境变量覆盖（IMG_NAME = 整体覆盖）。
IMG_DEBIAN_MAJOR="${IMG_DEBIAN_MAJOR:-12}"
IMG_NAME="${IMG_NAME:-fnos_Mainland-PE_arm_${IMG_DEBIAN_MAJOR}_${DEVICE_LABEL}.img}"
FINAL_IMG="$OUT_DIR/$IMG_NAME"
mv "$MODIFIED_IMG" "$FINAL_IMG" || { echo "❌ 重命名输出镜像失败"; exit 1; }
echo "📦 最终产物: $(basename "$FINAL_IMG")"
exit 0