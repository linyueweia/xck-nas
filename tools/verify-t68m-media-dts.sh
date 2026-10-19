#!/usr/bin/env bash
# xck-nas LYT T68M (RK3568) 媒体层 DT 门禁 —— 转码死机事故防回归（2026-10-19）
# 用法: tools/verify-t68m-media-dts.sh [dtb]     默认 dist/rk3568-lyt-t68m.dtb
# 判据来源（勿凭空增删）：
#   L1 仓内官方参照 dist/rk3568-nanopi-r5s-official.dtb 逐节点对照
#      （OPP 链接基线 7 = CPU×4+GPU+NPU+bus-npu；disable-auto-freq=3；rkvdec 锁频 396/396/396/600）
#   L2 K1 同源事故实测定案（lyw-kf TROUBLESHOOTING 6f）：移植 DTB 若在 rkvdec/rkvenc 挂 OPP，
#      编码侧 devfreq 与共享 mpp-srv 复位机制互锁 → 解码任务 timeout、irq:invalid 风暴 → 整机挂死
#   L3 内核只认 rockchip,rk3568-iommu（孤串 rockchip,iommu-v2 不注册 SMMU）；
#      rk_vcodec.ko of_match 认 rockchip,vpu-encoder-v2、不认 rockchip,rk3568-vepu
set -u
DTB="${1:-dist/rk3568-lyt-t68m.dtb}"
[ -f "$DTB" ] || { echo "✗ 找不到 DTB: $DTB"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
dtc -I dtb -O dts "$DTB" -o "$TMP/d.dts" 2>/dev/null || { echo "✗ dtc 反编译失败"; exit 1; }

FAIL=0
ck() { if [ "$2" = "$3" ]; then echo "  OK   $1 = $2"
  else echo "  ✗    $1 = '$2'  期望 '$3'"; FAIL=1; fi; }
has() { if grep -qE "$3" "$1"; then echo "  OK   $2"
  else echo "  ✗    $2 缺失"; FAIL=1; fi; }
hasnt() { if grep -qE "$3" "$1"; then echo "  ✗    $2 仍存在"; FAIL=1
  else echo "  OK   $2 不存在"; fi; }
blk() { awk -v s="$2" 'NR>=s {print; o=gsub(/{/,"{"); c=gsub(/}/,"}"); d+=o-c; if(NR>s && d<=0) exit}' "$1"; }
node_block() { local n; n=$(grep -nE "$1" "$TMP/d.dts" | head -1 | cut -d: -f1)
  if [ -z "$n" ]; then echo "  ✗    节点 $1 缺失"; FAIL=1; return 1; fi
  blk "$TMP/d.dts" "$n" > "$2"; return 0; }

echo "-- OPP 链接基线（官方=7；rkvdec/rkvenc 挂 OPP=移植残留，转码死机根因之一）"
ck "全文件 operating-points-v2 链接数" "$(grep -c 'operating-points-v2 = <' "$TMP/d.dts" || true)" "7"

echo "-- IOMMU compatible 形态（T68M 共 8 个：7 双串 + fe043e00 单串）"
ck "双串 rk3568-iommu+iommu-v2" "$(grep -c 'rk3568-iommu.*rockchip,iommu-v2' "$TMP/d.dts" || true)" "7"
ck "单串 rk3568-iommu（仅 fe043e00）" "$(grep -c 'compatible = \"rockchip,rk3568-iommu\"' "$TMP/d.dts" || true)" "1"
ck "孤串 iommu-v2（内核不认=0）" "$(grep -c 'compatible = \"rockchip,iommu-v2\"' "$TMP/d.dts" || true)" "0"

echo "-- rkvdec@fdf80200：官方锁频形态"
if node_block 'rkvdec@fdf80200 \{' "$TMP/rv"; then
  hasnt "$TMP/rv" "无 OPP 链接" 'operating-points-v2'
  has   "$TMP/rv" "disable-auto-freq" 'rockchip,disable-auto-freq'
  has   "$TMP/rv" "锁频 396/396/396/600" '0x179a7b00 0x179a7b00 0x179a7b00 0x23c34600'
fi

echo "-- rkvenc@fdf40000：官方形态（无 OPP；assigned 297/297）"
if node_block 'rkvenc@fdf40000 \{' "$TMP/en"; then
  hasnt "$TMP/en" "无 OPP 链接" 'operating-points-v2'
  has   "$TMP/en" "assigned 297/297" '0x11b3dc40 0x11b3dc40'
fi

echo "-- 第二编码器 vepu@fdee0000（官方名 + disable-auto-freq）"
if node_block 'vepu@fdee0000 \{' "$TMP/vp"; then
  has   "$TMP/vp" "compatible vpu-encoder-v2" 'compatible = "rockchip,vpu-encoder-v2"'
  hasnt "$TMP/vp" "无旧死名 rk3568-vepu" 'rockchip,rk3568-vepu'
  has   "$TMP/vp" "disable-auto-freq" 'rockchip,disable-auto-freq'
fi

echo "-- 媒体单元齐全（官方 R5S 同清单）"
for u in 'rkvdec@fdf80200 \{' 'rkvenc@fdf40000 \{' 'jpegd@fded0000 \{' 'iep@fdef0000 \{' 'vepu@fdee0000 \{' 'mpp-srv' 'sram@fdcc0000'; do
  ck "存在 $u" "$(grep -cE "$u" "$TMP/d.dts" || true)" "1"
done

echo "-- T68M 自身不变量（既有 CI 判据同源）"
ck "EEE 官方默认（eee-broken=0）" "$(grep -c 'eee-broken' "$TMP/d.dts" || true)" "0"
if grep -A3 'iommu@fde4b000' "$TMP/d.dts" | grep -q 'rk3568-iommu'; then
  echo "  OK   NPU iommu 含 rk3568-iommu 串"; else echo "  ✗    NPU iommu 缺 rk3568-iommu 串"; FAIL=1; fi

echo "------------------------------------------------"
if [ "$FAIL" = "0" ]; then echo "MEDIA-DTS GATE(T68M): ALL PASS"; else echo "MEDIA-DTS GATE(T68M): FAIL"; fi
exit $FAIL
