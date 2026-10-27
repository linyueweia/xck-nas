#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""T68M 媒体簇 vs 官方 R5S 参照件 字节级对标门禁（xck-nas）
用法: python3 tools/r5s-media-parity.py <t68m.dtb> [official.dtb]
默认参照 = dist/rk3568-nanopi-r5s-official.dtb（仓内官方件，勿换）。

背景（2026-10-27 定案）：T68M 的 GPU/VPU/NPU 簇必须与官方 R5S 逐节点一致
（用户口径：完全参照 R5S 方案，别自己融合）。归一化规则：
  - clocks/assigned-clocks/resets/power-domains/assigned-clock-parents/pinctrl-N/nvmem-cells/iommus：
    引用单元（phandle）解析成 @目标节点名（两板编号不同、指向相同即一致）；
    clocks/resets 等 <phandle id> 成对属性的奇数位是真实时钟/复位 ID，保留原值。
  - reg/频率/电压/中断号/compatible/names：全部保留原值。
  - phandle 属性本身删除（本板编号无意义）。
退出码：0=媒体簇全一致；1=有差异（打印逐行 diff）。"""
import re, sys, difflib

MEDIA_NODES = [
    "gpu@fde60000", "npu@fde40000", "npu-opp-table", "bus-npu", "bus-npu-opp-table",
    "video-codec@fdea0400", "vdpu@fdea0400", "rkvdec@fdf80200", "rkvdec-opp-table",
    "rkvenc@fdf40000", "rkvenc-opp-table", "jpegd@fded0000", "vepu@fdee0000",
    "iep@fdef0000", "rga@fdeb0000", "rk_rga@fdeb0000", "mpp-srv", "sram@fdcc0000",
    "power-management@fdd90000",
    "iommu@fde4b000", "iommu@fdea0800", "iommu@fded0480", "iommu@fdee0800",
    "iommu@fdef0800", "iommu@fdf40f00", "iommu@fdf80800",
]

PAIR_ATTRS = {"clocks", "assigned-clocks", "resets", "power-domains",
              "assigned-clock-parents"}
PHLIST_ATTRS = {"pinctrl-0", "pinctrl-1", "nvmem-cells", "iommus"}

def load(p):
    return open(p).read().splitlines()

def parse_ph_map(lines):
    ph2name, cur = {}, None
    for ln in lines:
        m = re.match(r"^\t([A-Za-z0-9,_@.\-]+)[ \t]*\{", ln)
        if m:
            cur = m.group(1)
        m = re.search(r"phandle = <(0x[0-9a-fA-F]+|[0-9]+)>", ln)
        if m and cur:
            v = m.group(1)
            ph2name[int(v, 16) if v.startswith("0x") else int(v)] = cur
    return ph2name

def node_block(lines, name):
    pat = re.compile(r"^\t" + re.escape(name) + r"[ \t]*\{")
    out, grab, depth = [], False, 0
    for ln in lines:
        if not grab and pat.match(ln):
            grab = True
            depth = ln.count("{") - ln.count("}")
            out.append(ln)
            if depth <= 0:
                break
            continue
        if grab:
            out.append(ln)
            depth += ln.count("{") - ln.count("}")
            if depth <= 0:
                break
    return out

def norm(block, ph2name):
    out = []
    for ln in block:
        st = ln.strip()
        if not st or st.startswith("phandle ="):
            continue
        m = re.match(r"^([A-Za-z0-9,_\-]+) = <(.*)>;$", st)
        if m:
            attr, toks = m.group(1), m.group(2).split()
            if attr in PAIR_ATTRS:
                res = []
                for idx, t in enumerate(toks):
                    if idx % 2 == 0:
                        try:
                            v = int(t, 16) if t.startswith("0x") else int(t)
                        except ValueError:
                            res.append(t); continue
                        res.append("@" + ph2name[v] if v in ph2name else t)
                    else:
                        res.append(t)
                st = "%s = <%s>;" % (attr, " ".join(res))
            elif attr in PHLIST_ATTRS:
                res = []
                for t in toks:
                    try:
                        v = int(t, 16) if t.startswith("0x") else int(t)
                    except ValueError:
                        res.append(t); continue
                    res.append("@" + ph2name[v] if v in ph2name else t)
                st = "%s = <%s>;" % (attr, " ".join(res))
            elif attr == "reg" or attr.startswith("rockchip,") or attr in (
                    "compatible", "status", "clock-names", "reset-names",
                    "interrupt-names", "reg-names", "nvmem-cell-names",
                    "power-domain-names", "label", "device_type", "phy-mode",
                    "interrupts", "opp-hz", "opp-microvolt", "opp-supported-hw",
                    "assigned-clock-rates"):
                pass
            else:
                res = []
                for idx, t in enumerate(toks):
                    if idx == 0:
                        try:
                            v = int(t, 16) if t.startswith("0x") else int(t)
                        except ValueError:
                            res.append(t); continue
                        res.append("@" + ph2name[v] if v in ph2name else t)
                    else:
                        res.append(t)
                st = "%s = <%s>;" % (attr, " ".join(res))
        out.append(re.sub(r"\s+", " ", st))
    return out

def main():
    t68m = sys.argv[1] if len(sys.argv) > 1 else "dist/rk3568-lyt-t68m.dtb"
    ref = sys.argv[2] if len(sys.argv) > 2 else "dist/rk3568-nanopi-r5s-official.dtb"
    import subprocess, tempfile, os
    tmp = tempfile.mkdtemp()
    d68, drf = os.path.join(tmp, "a.dts"), os.path.join(tmp, "b.dts")
    for dtb, out in ((t68m, d68), (ref, drf)):
        subprocess.run(["dtc", "-I", "dtb", "-O", "dts", dtb, "-o", out],
                       check=True, stderr=subprocess.DEVNULL)
    a, b = load(d68), load(drf)
    pa, pb = parse_ph_map(a), parse_ph_map(b)
    fails = 0
    for name in MEDIA_NODES:
        ba, bb = node_block(a, name), node_block(b, name)
        if not ba and not bb:
            print("  SKIP %s（两边都无）" % name); continue
        if not ba or not bb:
            print("  ✗ %s 单边缺失（T68M=%s 官方=%s）" % (name, bool(ba), bool(bb)))
            fails += 1; continue
        na, nb = norm(ba, pa), norm(bb, pb)
        if na == nb:
            print("  OK   %s" % name)
        else:
            print("  ✗ %s 与官方 R5S 有差异：" % name)
            for l in difflib.unified_diff(na, nb, lineterm="", n=0):
                if l.startswith(("---", "+++")):
                    continue
                print("       " + l)
            fails += 1
    print("媒体簇对标: %d 个节点，差异 %d" % (len(MEDIA_NODES), fails))
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
