# xck-nas

为 **LYT T68M（RK3568）** 生成**完整设备树 DTB**（`rk3568-lyt-t68m.dtb`），并基于**飞牛官方通用基镜像**自动打包**完整 fnOS 固件镜像**（`.img`）。

## 仓库能做什么

本仓库包含两条独立流水线：

| 流水线 | Workflow | 产物 | 触发方式 |
|--------|----------|------|----------|
| **完整固件打包** | `Build FnOS T68M Image` | `lyt-t68m_YYYYMMDD.img.xz` + SHA256SUMS（发布到 Release） | 手动触发 |
| **DTB 云编译** | `Build DTB only` | `rk3568-lyt-t68m.dtb`（artifact 保留 7 天；tag 推送自动发 Release） | 手动 / push `dts/**`、`build-dtb.sh` |

## 固件打包流程（Build FnOS T68M Image）

```
飞牛官方通用基镜像 (linyueweia/fnnas-base-images v1.0.0, .img.gz)
        │  gunzip 解压
        ▼
   fnnas-arm64/fnnas-arm64.img
        │  buildfnos.sh（DEVICE=lyt-t68m）
        ├── dd 写入 idbloader.img  @ LBA 64（32KB）
        ├── dd 写入 u-boot.itb     @ LBA 16384（8MB）
        ├── 挂载 BOOT 分区（ext4，@ 32MiB/360MiB）
        │     ├── 覆盖 fnEnv.txt（fdtfile=rk3568-lyt-t68m.dtb, kernelfile=vmlinuz-6.18.18.c951-trim）
        │     ├── 覆盖 extlinux/extlinux.conf（存在时）
        │     └── 强覆盖 dtb/rockchip/rk3568-lyt-t68m.dtb（d96ff486 最终版）
        ├── 挂载 rootfs 分区（btrfs）
        │     └── 不扩容，保持官方默认大小
        ▼
   out/lyt-t68m_YYYYMMDD.img
        │  xz -9 压缩
        ▼
   out-compressed/lyt-t68m_YYYYMMDD.img.xz + SHA256SUMS
        │  action-gh-release
        ▼
   Release: fnos_t68m_<run_number>
```

**基镜像**：`linyueweia/fnnas-base-images` Release `v1.0.0` 的
`fnnas-official-arm64-image_rockchip.img.gz`——飞牛官方通用基镜像
（rockchip arm64），含全量 dtb + 通用内核 `6.18.18.c951-trim`，无设备绑定。

**关键校验（Verify 步骤）**：注入完成后校验产出镜像 BOOT 分区中的
`rk3568-lyt-t68m.dtb` sha256 必须与源 DTB 完全一致，否则构建失败。

## 这个 DTB 是什么

完整展开式 DTB（自包含，不依赖内核 dtsi），包含：

- **4 网口**：`gmac0`/`gmac1` 双千兆 + 2×PCIe RTL8125 双2.5G（`fe270000`/`fe280000`）
- **NPU/多媒体集群**：`npu@fde40000` + `npu-opp-table` + `rkvdec` + `rkvenc` + `jpegd` + `iep` + `mpp-srv` + 相关 iommu/sram
- **SATA2**（`sata@fc800000`）+ **SDIO WiFi AIC8800**（`sdmmc2` + `sdio_pwrseq`）
- 按 iStoreOS v2 策略**禁用 `pcie2x1`**，释放 `combphy2` 给 SATA2
- **LED**：GPIO4_C5（红/state）+ GPIO4_C6（绿/power），default-state=on

> 注：主线上游 `rk3568.dtsi` 不含 RK3568 NPU 节点，因此直接拿主线风格
> `#include` 源码编译会缺 NPU。本仓库改用**展开式完整 DTS** 作为源，
> 任何 dtc 版本均可 100% 无损复现该 DTB（往返编译 sha256 一致）。

## 使用

### 打包完整 fnOS 固件（推荐）

**Actions → Build FnOS T68M Image → Run workflow** 手动触发。
构建完成后 Release 产出 `.img.xz` + SHA256SUMS，直接下载刷写。
rootfs 不扩容，保持官方默认大小。

### GitHub Actions 云编译 DTB

**Actions → Build DTB only → Run workflow** 手动触发；或 push 修改 `dts/`
或 `build-dtb.sh` 时自动触发。产物以 artifact 形式保留 7 天，tag 推送自动发 Release。

### 本地手动编译

编译 DTB 不需要交叉工具链，仅需 clone 内核源码 + 宿主 gcc/dtc：

```bash
./build-dtb.sh          # 自动：克隆 unifreq/linux-6.18.y → make ARCH=arm64 dtbs
sha256sum rk3568-lyt-t68m.dtb
```

## 目录结构

```
dts/rk3568-lyt-t68m.dts           # 展开式完整设备树源码（不含 #include，自包含）
dist/rk3568-lyt-t68m.dtb          # 完整预编译 dtb（固定产物，SHA256 d96ff486...）
build-dtb.sh                      # DTB 编译脚本（仅编译，不打包固件）
buildfnos.sh                      # fnOS 固件打包脚本（基镜像 + u-boot + dtb）
uboot/rk3568/lyt-t68m/            # T68M 设备目录（u-boot/fnEnv/extlinux/dtbfinal）
.github/workflows/build-dtb.yml       # GitHub Actions 云编译（仅 DTB）
.github/workflows/build-fnos-t68m.yml # GitHub Actions 打包完整固件
```

### uboot/rk3568/lyt-t68m/（T68M 设备目录）

| 文件 | 说明 |
|------|------|
| `idbloader.img` | first-stage bootloader（复用 R5S，RK3568 通用） |
| `u-boot.itb` | FIT 格式 u-boot（复用 R5S，RK3568 通用） |
| `fnEnv.txt` | 引导变量：`fdtfile=rockchip/rk3568-lyt-t68m.dtb` |
| `extlinux.conf` | 系统引导配置 |
| `rk3568-lyt-t68m.dtb` | 最终设备树（d96ff486，与 dist/ 一致） |

## 已知约束

- 禁用 `pcie2x1` 后，原 PCIe2x1/miniPCIe 通道上的非 SATA2 设备不可用。
- GPU 用飞牛主线开源驱动（panfrost）。
- 引导：`fdtfile=rockchip/rk3568-lyt-t68m.dtb`；串口 `console=ttyS2,1500000`。
- 内核 `6.18.18.c951-trim`，rknpu v0.9.8。

## 验证（开机后）

```bash
dmesg | grep -E "sata|sdmmc2|wifi|r8125|gmac|usb|npu|rknpu"
lspci -tv   # 2.5G 网卡 RTL8125
cat /sys/block/sata*/device/model   # SATA2 子板硬盘
cat /sys/kernel/debug/rknpu/version 2>/dev/null   # NPU 可用性
```