# xck-nas

为 **LYT T68M（RK3568）** 生成**完整设备树 DTB**（`rk3568-lyt-t68m.dtb`），并基于**飞牛官方通用基镜像**自动打包**完整 fnOS 固件镜像**（`.img.xz`）。

## 现状速览（2026-09）

- **DTB 基底**：飞牛 6.18 原生 **EasePi R1**（`rk3568-easepi-r1.dtb`）展开式骨架 + **T68M 板级覆盖**。
- **NPU 已验证修复**：`iommu@fde4b000` compatible 为**双值**
  `"rockchip,rk3568-iommu" "rockchip,iommu-v2"`，同时匹配
  6.18 主线 rk3568-iommu v2 驱动与 Rockchip SDK 血统（与 SDK 官方 DTB 语义一致）。
- **最终产物哈希**：
  - `dts/rk3568-lyt-t68m.dts` → `599ef97772e58107b4d58dc2653e6655f4eaa29439f6664f024729d10760ee8e`
  - `dist/rk3568-lyt-t68m.dtb` = `uboot/rk3568/lyt-t68m/rk3568-lyt-t68m.dtb` = `0e56384e2de21f76132cb10f37812f8efa7dd261c03b1802882801e1852720c8`
- **内核**：`6.18.18.c951-trim`（飞牛通用内核，含完整 Rockchip drivers），**rknpu v0.9.8**。
- 固件 rootfs **不扩容**，保持官方默认大小（`chore: 移除扩容逻辑`，commit `6bf3f10`）。

## 仓库能做什么

本仓库包含两条独立流水线：

| 流水线 | Workflow | 产物 | 触发方式 |
|--------|----------|------|----------|
| **完整固件打包** | `Build FnOS T68M Image` | `fnos_Mainland-PE_arm_<版本>_LYT-T68M_<构建号>.img.xz` + SHA256SUMS（发布到 Release） | 手动触发 |
| **DTB 云编译** | `Build DTB only` | `rk3568-lyt-t68m.dtb`（artifact 保留 7 天；tag 推送自动发 Release） | 手动 / push `dts/**`、`build-dtb.sh` |

## DTB 移植血统与 NPU 修复

### 基底选择（重要）

本仓库 DTB **只以飞牛 6.18 原生 EasePi R1 为骨架**，不使用其他方案的
DTB 作为骨架。移植流程：

1. 从飞牛 6.18 官方基镜像提取 EasePi R1 原生 DTB（`rk3568-easepi-r1.dtb`）并反编译为展开式 DTS；
2. 以 EasePi R1 骨架为顶层顺序基准，将 T68M 板级节点（网口/PCIe/SATA2/SDIO/LED/regulator/PMIC 等）按「名+地址」配对替换或追加；
3. SoC 通用节点（含 NPU 集群、iommu、opp 表、时钟、电源域）默认**保留骨架值**，T68M 特有的板级电源/外设引用保留 T68M 值。

> 排查记录：前期曾因融合脚本把 `iommu@fde4b000`（NPU 的 MMU）错误覆盖为
> 旧 T68M 固件的**单值** `"rockchip,rk3568-iommu"`——虽然能匹配主线，
> 但丢失 SDK 血统兼容且违背「骨架优先」原则。已修复为双值并重新全流程验证
> （commit `5a2ceb9`）。

### NPU 子系统验证清单（全部通过）

| 维度 | 结论 |
|------|------|
| 电源链 | `rknpu-supply` → PMIC `DCDC_REG4`（`vdd_npu`，500–1350mV，init 900mV）；`bus-npu bus-supply` → `DCDC_REG1`（vdd_logic）；OPP 最高档 1000mV，余量 350mV |
| 电源域 | `power-domain@6`（reg=06，status=okay），关联时钟 ACLK/HCLK/PCLK_NPU_PRE 与主线 cru.h 全命中 |
| 时钟链 | `CLK_NPU=35 / ACLK_NPU=40 / HCLK_NPU=41 / SCMI_CLK_NPU=2`，resets=SRST_A/H_NPU(43/44)，init-freq 900MHz |
| efuse | `npu-opp-table` 6 个 nvmem-cells 全部正确指向：`npu-leakage@1c`/`core-pvtm@2a`/`mbist-vmin@9`/`npu-opp-info@42`/spec-serial@7/remark-spec-serial@56 |
| OPP 表 | 8 档（200MHz@850mV → 1000MHz@1000mV），`opp-supported-hw` 掩码 0xfb/0xf9，与骨架/SDK 三方一致 |
| 引用完整性 | 257 个 phandle 全唯一、565 节点无重复、无悬空引用、NPU/iommu/bus-npu status 全 okay |
| 归属核对 | NPU 核心 5 节点与 EasePi R1 骨架**语义零差异**；与 SDK 官方 DTB（RK3568 平台参考）交叉验证一致 |

## 这个 DTB 包含什么

完整展开式 DTB（自包含，不依赖内核 dtsi），包含：

- **网络**：`gmac0`/`gmac1` 双千兆 + 2×PCIe RTL8125 双2.5G（`fe270000`/`fe280000`）
- **NPU/多媒体集群**：`npu@fde40000` + `npu-opp-table` + `bus-npu`/`bus-npu-opp-table` +
  `rkvdec` + `rkvenc` + `jpegd` + `iep` + `mpp-srv` + 相关 iommu/sram，全部 status=okay
- **SATA2**（`sata@fc800000`）+ **SDIO WiFi AIC8800**（`sdmmc2` + `sdio_pwrseq`）
- **PCIe**：按 iStoreOS v2 策略**禁用 `pcie2x1`**，释放 `combphy2` 给 SATA2
- **LED**：GPIO4_C5（红/state）+ GPIO4_C6（绿/power），default-state=on
- **PMIC**：RK809（`pmic@20`）完整 regulators（vdd_logic/vdd_gpu/vdd_npu/LDO 9 路）+ 独立 TCS4525（vdd_cpu）

> 注：主线上游 `rk3568.dtsi` 不含 RK3568 NPU 节点，因此直接拿主线风格
> `#include` 源码编译会缺 NPU。本仓库改用**展开式完整 DTS** 作为源，
> 任何 dtc 版本均可 100% 无损复现该 DTB（往返编译 sha256 一致）。

## 固件打包流程（Build FnOS T68M Image）

```
飞牛官方通用基镜像 (linyueweia/fnnas-base-images v1.0.0, .img.gz)
        │  gunzip 解压
        ▼
   fnnas-arm64/fnnas-arm64.img
        │  buildfnos.sh（DEVICE=lyt-t68m）
        ├── dd 写入 idbloader.img  @ LBA 64（32KB）
        ├── dd 写入 u-boot.itb     @ LBA 16384（8MB）
        ├── 挂载 BOOT 分区（ext4）
        │     ├── 覆盖 fnEnv.txt（fdtfile=rk3568-lyt-t68m.dtb, kernelfile=vmlinuz-6.18.18.c951-trim）
        │     ├── 覆盖 extlinux/extlinux.conf
        │     └── 强覆盖 dtb/rockchip/rk3568-lyt-t68m.dtb（0e56384e 最终版）
        ├── 挂载 rootfs 分区（btrfs）
        │     └── 不扩容，保持官方默认大小
        ▼
   out/fnos_Mainland-PE_arm_<版本>_LYT-T68M_<构建号>.img
        │  xz -9 压缩
        ▼
   out-compressed/fnos_Mainland-PE_arm_<版本>_LYT-T68M_<构建号>.img.xz + SHA256SUMS
        │  action-gh-release
        ▼
   Release: fnos_t68m_<run_number>
```

**基镜像**：`linyueweia/fnnas-base-images` Release `v1.0.0` 的
`fnnas-official-arm64-image_rockchip.img.gz`——飞牛官方通用基镜像
（rockchip arm64），含全量 dtb + 通用内核 `6.18.18.c951-trim`，无设备绑定。

**关键校验（Verify 步骤）**：注入完成后校验产出镜像 BOOT 分区中的
`rk3568-lyt-t68m.dtb` sha256 必须与源 DTB 完全一致，否则构建失败。

## 使用

### 1. 打包完整 fnOS 固件（推荐）

**Actions → Build FnOS T68M Image → Run workflow** 手动触发。
构建完成后 Release 产出 `.img.xz` + SHA256SUMS，直接下载刷写。

### 2. GitHub Actions 云编译 DTB

**Actions → Build DTB only → Run workflow** 手动触发；或 push 修改 `dts/`
或 `build-dtb.sh` 时自动触发。产物以 artifact 形式保留 7 天，tag 推送自动发 Release。

### 3. 本地手动编译

编译 DTB 不需要交叉工具链，仅需 clone 内核源码 + 宿主 gcc/dtc：

```bash
./build-dtb.sh          # 自动：克隆 unifreq/linux-6.18.y → make ARCH=arm64 dtbs
sha256sum rk3568-lyt-t68m.dtb   # 应等于 0e56384e...
```

## 目录结构

```
dts/rk3568-lyt-t68m.dts           # 展开式完整设备树源码（不含 #include，自包含）SHA256 599ef977...
dist/rk3568-lyt-t68m.dtb          # 完整预编译 dtb（SHA256 0e56384e...）
build-dtb.sh                      # DTB 编译脚本（仅编译，不打包固件）
buildfnos.sh                      # fnOS 固件打包脚本（基镜像 + u-boot + dtb）
uboot/rk3568/lyt-t68m/            # T68M 设备目录（u-boot/fnEnv/extlinux/dtbfinal）
.github/workflows/build-dtb.yml       # GitHub Actions 云编译（仅 DTB）
.github/workflows/build-fnos-t68m.yml # GitHub Actions 打包完整固件
```

### uboot/rk3568/lyt-t68m/（T68M 设备目录）

| 文件 | 说明 |
|------|------|
| `idbloader.img` | first-stage bootloader（RK3568 通用，182KB） |
| `u-boot.itb` | FIT 格式 u-boot（RK3568 通用，1.1MB） |
| `fnEnv.txt` | 引导变量：`fdtfile=rockchip/rk3568-lyt-t68m.dtb` + `cma=256M` |
| `extlinux.conf` | 系统引导配置（earlycon @ fe660000，console=ttyS2,1500000） |
| `rk3568-lyt-t68m.dtb` | 最终设备树（0e56384e，与 dist/ 一致，76481B） |

## 已知约束

- 禁用 `pcie2x1` 后，原 PCIe2x1/miniPCIe 通道上的非 SATA2 设备不可用。
- GPU 用飞牛主线开源驱动（panfrost）。
- 引导：`fdtfile=rockchip/rk3568-lyt-t68m.dtb`；串口 `console=ttyS2,1500000`。
- 内核 `6.18.18.c951-trim`，rknpu v0.9.8，CMA `256M`（为 NPU/多媒体预留）。

## 验证（开机后）

```bash
dmesg | grep -E "sata|sdmmc2|wifi|r8125|gmac|usb|npu|rknpu"
lspci -tv                            # 2.5G 网卡 RTL8125
cat /sys/block/sata*/device/model    # SATA2 子板硬盘
cat /sys/kernel/debug/rknpu/version  # NPU 可用性（rknpu v0.9.8）
cat /sys/class/devfreq/fdab0000.npu/cur_freq   # NPU 当前频率（应 ≈900MHz）
```

## 变更记录

| commit | 内容 |
|--------|------|
| `5a2ceb9` | **fix**: NPU `iommu@fde4b000` compatible 恢复双值（对齐骨架，兼容主线+SDK 血统） |
| `bd08181` | **feat**: T68M DTB 移植至 6.18 EasePi R1 骨架（460 节点语义对齐，仅 phandle 编号重排） |
| `6bf3f10` | **chore**: 移除扩容逻辑（rootfs 保持官方默认大小） |
| `0b20045` | **docs**: README |
| `6a7be17` | **ci**: 使用自家通用基镜像源，去除旧方案字样 |