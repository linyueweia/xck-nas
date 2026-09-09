# xck-nas

为 **LYT T68M（RK3568）** 生成**完整设备树 DTB**（`rk3568-lyt-t68m.dtb`）。

> 本仓库只编译 **DTB**，不再打包完整固件。

## 产物

| 产物 | 路径 | 说明 |
|------|------|------|
| 完整 DTB | `dist/rk3568-lyt-t68m.dtb` | 已编译验证的固定产物（SHA256 `e4c4c30a...`），含 NPU/多媒体集群 |
| 云编译 DTB | Actions artifact | 每次触发 `Build DTB only` workflow 重新构建 |

## 这个 DTB 是什么

完整展开式 DTB（自包含，不依赖内核 dtsi），包含：

- **4 网口**：`gmac0`/`gmac1` 双千兆 + 2×PCIe RTL8125 双2.5G（`fe270000`/`fe280000`）
- **NPU/多媒体集群**：`npu@fde40000` + `npu-opp-table` + `rkvdec` + `rkvenc` + `jpegd` + `iep` + `mpp-srv` + 相关 iommu/sram
- **SATA2**（`sata@fc800000`） + **SDIO WiFi AIC8800**（`sdmmc2` + `sdio_pwrseq`）
- 按 iStoreOS v2 策略**禁用 `pcie2x1`**，释放 `combphy2` 给 SATA2
- **LED**：GPIO4_C5（红/state）+ GPIO4_C6（绿/power），default-state=on

> 注：主线上游 `rk3568.dtsi` 不含 RK3568 NPU 节点，因此直接拿主线风格
> `#include` 源码编译会缺 NPU。本仓库改用**展开式完整 DTS** 作为源，
> 任何 dtc 版本均可 100% 无损复现该 DTB（往返编译 sha256 一致）。

## 使用

### GitHub Actions 云编译（推荐）

**Actions → Build DTB only → Run workflow** 手动触发；或 push 修改 `dts/`
或 `build-dtb.sh` 时自动触发。产物以 artifact 形式保留 7 天，tag 推送自动发 Release。

### 本地手动编译

编译 DTB 不需要交叉工具链，仅需 clone 内核源码 + 宿主 gcc/dtc：

```bash
./build-dtb.sh          # 自动：克隆 unifreq/linux-6.12.y → make ARCH=arm64 dtbs
sha256sum rk3568-lyt-t68m.dtb
```

## 目录结构

```
dist/rk3568-lyt-t68m.dtb          # 完整预编译 dtb（固定产物，SHA256 e4c4c30a...）
dts/rk3568-lyt-t68m.dts           # 展开式完整设备树源码（不含 #include，自包含）
build-dtb.sh                      # DTB 编译脚本（仅编译，不打包固件）
.github/workflows/build-dtb.yml   # GitHub Actions 云编译（仅 DTB）
```

## 已知约束

- 禁用 `pcie2x1` 后，原 PCIe2x1/miniPCIe 通道上的非 SATA2 设备不可用。
- GPU 用飞牛主线开源驱动（panfrost）。
- 引导：`fdtfile=rockchip/rk3568-lyt-t68m.dtb`；串口 `console=ttyS2,1500000`。

## 验证（开机后）

```bash
dmesg | grep -E "sata|sdmmc2|wifi|r8125|gmac|usb|npu|rknpu"
lspci -tv   # 2.5G 网卡 RTL8125
cat /sys/block/sata*/device/model   # SATA2 子板硬盘
cat /sys/kernel/debug/rknpu/version 2>/dev/null   # NPU 可用性
```