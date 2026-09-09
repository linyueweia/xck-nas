#!/usr/bin/env python3
"""
修复 T68M 完整 DTB 的 NPU 子系统为 SDK 血统（参考 R5S 官方固件 DTB）
策略：保留 mainline 血统的 phandle 引用编号（DTB 内部自洽），只修复三类缺陷：
  1. iommu@fde4b000 compatible 缺少 "rockchip,rk3568-iommu"（SDK 驱动匹配失败）
  2. npu-opp-table 缺少 SDK 的 nvmem-cells（leakage/pvtm/mbist-vmin/opp-info/serial...）
  3. efuse nvmem-layout 缺少 SDK 需要的 6 个 cell
  4. bus-npu / bus-npu-opp-table 缺少 pvtm 校准
安全：phandle 保持 T68M 原值（0x0f/0x11/0x302/0x303/0x305 等），新增 cell 分配 0x312+
"""
import re

SRC = "dts/rk3568-lyt-t68m.dts"
DST = "dts/rk3568-lyt-t68m.dts"

with open(SRC) as f:
    txt = f.read()

# 现有 phandle 水位线
used = {int(x, 16) for x in re.findall(r"phandle = <(0x[0-9a-fA-F]+)>;", txt)}
next_ph = 0x312
def alloc():
    global next_ph
    while next_ph in used:
        next_ph += 1
    used.add(next_ph)
    p = next_ph
    next_ph += 1
    return p

# phandle 分配（新增 6 个 efuse cell，按 R5S 官方顺序）
ph_spec_serial = alloc()   # specification-serial-number@7
ph_mbist_vmin  = alloc()   # mbist-vmin@9
ph_core_pvtm   = alloc()   # core-pvtm@2a
ph_remark_serial = alloc() # remark-spec-serial-number@56
ph_gpu_opp_info = alloc()  # gpu-opp-info@3c
ph_npu_opp_info = alloc()  # npu-opp-info@42
print(f"allocated phandles: spec_serial={ph_spec_serial:#x} mbist={ph_mbist_vmin:#x} "
      f"core_pvtm={ph_core_pvtm:#x} remark={ph_remark_serial:#x} "
      f"gpu_opp={ph_gpu_opp_info:#x} npu_opp={ph_npu_opp_info:#x}")

# ============ 1. iommu@fde4b000 compatible ============
old_iommu = """\tiommu@fde4b000 {
\t\tcompatible = "rockchip,iommu-v2";"""
new_iommu = """\tiommu@fde4b000 {
\t\tcompatible = "rockchip,rk3568-iommu\\0rockchip,iommu-v2";"""
assert old_iommu in txt, "[1] iommu compatible pattern not found"
txt = txt.replace(old_iommu, new_iommu, 1)
print("[1] iommu compatible fixed")

# ============ 2. efuse nvmem-layout 补齐 6 个 cell ============
old_nvmem_end = """\t\t\tgpu-leakage@1d {
\t\t\t\treg = <0x1d 0x01>;
\t\t\t\tphandle = <0x123>;
\t\t\t};
\t\t};
\t};"""
new_cells = f"""\t\t\tgpu-leakage@1d {{
\t\t\t\treg = <0x1d 0x01>;
\t\t\t\tphandle = <0x123>;
\t\t\t}};

\t\t\tspecification-serial-number@7 {{
\t\t\t\treg = <0x07 0x01>;
\t\t\t\tbits = <0x00 0x05>;
\t\t\t\tphandle = <{ph_spec_serial:#x}>;
\t\t\t}};

\t\t\tmbist-vmin@9 {{
\t\t\t\treg = <0x09 0x01>;
\t\t\t\tbits = <0x00 0x04>;
\t\t\t\tphandle = <{ph_mbist_vmin:#x}>;
\t\t\t}};

\t\t\tcore-pvtm@2a {{
\t\t\t\treg = <0x2a 0x02>;
\t\t\t\tphandle = <{ph_core_pvtm:#x}>;
\t\t\t}};

\t\t\tremark-spec-serial-number@56 {{
\t\t\t\treg = <0x56 0x01>;
\t\t\t\tbits = <0x00 0x05>;
\t\t\t\tphandle = <{ph_remark_serial:#x}>;
\t\t\t}};

\t\t\tgpu-opp-info@3c {{
\t\t\t\treg = <0x3c 0x06>;
\t\t\t\tphandle = <{ph_gpu_opp_info:#x}>;
\t\t\t}};

\t\t\tnpu-opp-info@42 {{
\t\t\t\treg = <0x42 0x06>;
\t\t\t\tphandle = <{ph_npu_opp_info:#x}>;
\t\t\t}};
\t\t}};
\t}};"""
assert old_nvmem_end in txt, "[2] nvmem layout pattern not found"
txt = txt.replace(old_nvmem_end, new_cells, 1)
print("[2] nvmem-layout cells added")

# ============ 3. npu-opp-table 补齐 SDK 参数 ============
old_opp_head = """\tnpu-opp-table {
\t\tcompatible = "operating-points-v2";
\t\tnvmem-cells = <0x122>;
\t\tnvmem-cell-names = "leakage\\0pvtm\\0mbist-vmin";
\t\tphandle = <0x303>;"""
new_opp_head = f"""\tnpu-opp-table {{
\t\tcompatible = "operating-points-v2";
\t\tmbist-vmin = <0xc96a8 0xdbba0 0xe7ef0>;
\t\tnvmem-cells = <0x122 {ph_core_pvtm:#x} {ph_mbist_vmin:#x} {ph_npu_opp_info:#x} {ph_spec_serial:#x} {ph_remark_serial:#x}>;
\t\tnvmem-cell-names = "leakage\\0pvtm\\0mbist-vmin\\0opp-info\\0specification_serial_number\\0remark_spec_serial_number";
\t\trockchip,supported-hw;
\t\trockchip,max-volt = <0xf4240>;
\t\trockchip,temp-hysteresis = <0x1388>;
\t\trockchip,low-temp = <0x00>;
\t\trockchip,low-temp-adjust-volt = <0x00 0x3e8 0xc350>;
\t\trockchip,pvtm-voltage-sel = <0x00 0x14820 0x00 0x14821 0x153d8 0x01 0x153d9 0x16378 0x02 0x16379 0x186a0 0x03>;
\t\trockchip,pvtm-ch = <0x00 0x05>;
\t\trockchip,init-freq = <0xdbba0>;
\t\tphandle = <0x303>;"""
assert old_opp_head in txt, "[3] npu-opp-table head not found"
txt = txt.replace(old_opp_head, new_opp_head, 1)
print("[3] npu-opp-table SDK params added")

# ============ 4. bus-npu 补齐 pvtm-supply ============
old_bus = """\tbus-npu {
\t\tcompatible = "rockchip,rk3568-bus";
\t\trockchip,busfreq-policy = "clkfreq";
\t\tclocks = <0x02 0x02>;
\t\tclock-names = "bus";
\t\toperating-points-v2 = <0x305>;
\t\tstatus = "okay";
\t\tbus-supply = <0xf6>;
\t\tphandle = <0x304>;
\t};"""
new_bus = """\tbus-npu {
\t\tcompatible = "rockchip,rk3568-bus";
\t\trockchip,busfreq-policy = "clkfreq";
\t\tclocks = <0x02 0x02>;
\t\tclock-names = "bus";
\t\toperating-points-v2 = <0x305>;
\t\tstatus = "okay";
\t\tbus-supply = <0xf6>;
\t\tpvtm-supply = <0x05>;
\t\tphandle = <0x304>;
\t};"""
assert old_bus in txt, "[4] bus-npu pattern not found"
txt = txt.replace(old_bus, new_bus, 1)
print("[4] bus-npu pvtm-supply added")

# ============ 5. bus-npu-opp-table 补齐 nvmem-cells (pvtm) ============
old_bus_opp = """\tbus-npu-opp-table {
\t\tcompatible = "operating-points-v2";
\t\topp-shared;
\t\tnvmem-cell-names = "pvtm";
\t\tphandle = <0x305>;"""
new_bus_opp = f"""\tbus-npu-opp-table {{
\t\tcompatible = "operating-points-v2";
\t\topp-shared;
\t\tnvmem-cells = <{ph_core_pvtm:#x}>;
\t\tnvmem-cell-names = "pvtm";
\t\trockchip,pvtm-voltage-sel = <0x00 0x14820 0x00 0x14821 0x16378 0x01 0x16379 0x186a0 0x02>;
\t\trockchip,pvtm-ch = <0x00 0x05>;
\t\tphandle = <0x305>;"""
assert old_bus_opp in txt, "[5] bus-npu-opp-table pattern not found"
txt = txt.replace(old_bus_opp, new_bus_opp, 1)
print("[5] bus-npu-opp-table pvtm added")

# 校验 opp 条目的 opp-supported-hw（SDK 需要）——批量给 npu-opp-table 内 opp 加后缀
# 不做：mainline 内核也接受无 supported-hw；SDK 驱动在无 supported-hw 时按全部可用处理，
# 但 R5S 官方明确给了。为稳妥，给 npu opp 补上 opp-supported-hw（保持与 R5S 一致）。
# 注意：只处理 npu-opp-table 内的（phandle 0x303 之后到 npu@ 之前）
seg_start = txt.index("npu-opp-table {")
seg_end = txt.index("npu@fde40000 {")
seg = txt[seg_start:seg_end]
# 查找每个 opp-XXX { 下一行的 opp-hz 之后插入 opp-supported-hw
opp_support = {
    "opp-200000000": "<0xfb 0xffff>",
    "opp-300000000": "<0xfb 0xffff>",
    "opp-400000000": "<0xfb 0xffff>",
    "opp-600000000": "<0xfb 0xffff>",
    "opp-700000000": "<0xfb 0xffff>",
    "opp-800000000": "<0xfb 0xffff>",
    "opp-900000000": "<0xf9 0xffff>",
    "opp-1000000000": "<0xf9 0xffff>",
}
for opp, hw in opp_support.items():
    pattern = f"\t\t{opp} {{\n\t\t\topp-hz"
    if pattern in seg:
        seg = seg.replace(pattern, f"\t\t{opp} {{\n\t\t\topp-supported-hw = {hw};\n\t\t\topp-hz", 1)
        print(f"[5b] {opp} supported-hw added")
txt = txt[:seg_start] + seg + txt[seg_end:]

with open(DST, "w") as f:
    f.write(txt)
print("DONE. written to", DST)