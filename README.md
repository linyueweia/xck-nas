# xck-nas

为 **LYT T68M（RK3568）** 生成**飞牛 fnOS 完整可烧录固件**，并注入融合子板补丁的
设备树（`rk3568-lyt-t68m.dtb`），使子板（SATA2 + SDIO WiFi）可用。

## 产物

| 产物 | 路径 | 说明 |
|------|------|------|
| 预编译融合 dtb | `dist/rk3568-lyt-t68m.dtb` | 已编译验证的固定产物（SHA256 `4d99b3f8...`），**不会每次重新构建** |
| 完整固件 | Actions 打包输出 | 官方基础镜像 + 注入融合 dtb 后打包 |


## 背景

- 飞牛官方**基础镜像**已含 T68M 的 u-boot/内核/官方 dtb，但**官方 dtb 不含子板定义**（SATA2、SDIO WiFi 均 disabled，走 PCIe2x1 路线）。
- 本仓库在主线 `rk3568-lyt-t68m.dts` 基础上**融合 iStoreOS 的子板补丁**并预编译：
  - **SATA2**（`sata@fc800000`）
  - **SDIO WiFi AIC8800**（`sdmmc2` + `sdio_pwrseq`）
  - 按 iStoreOS v2 策略**禁用 `pcie2x1`**，释放 `combphy2` 给 SATA2（RK3568 的 combphy2 在 SATA2 与 PCIe2x1 之间互斥）。

> dtb 是**构建一次即固定**的产物，因此本仓库不设自动构建 dtb 的 workflow；
> 仅当需要调整子板配置时，才手动用 `dts/` 源码 + `build-dtb.sh` 重新生成。

## 打包完整固件

在 **Actions → Build full FnNAS image → Run workflow** 手动触发：

- 输入 `base_version`：官方 rockchip 基础镜像版本（留空取最新，如 `1253`）
- 流程：
  1. 下载 fnnas.com 官方 **rockchip** Arm64 基础镜像
  2. 解压 → 挂载 boot 分区
  3. 把 `dist/` 里预编译的融合 dtb 覆盖到 `/dtb/rockchip/rk3568-lyt-t68m.dtb`（官方原版备份为 `.official.bak`）
  4. 重新打包为 `.img.gz`
- 产物：`fnnas-official-rockchip_<ver>-subboard.img.gz`

## 目录结构

```
dist/rk3568-lyt-t68m.dtb          # 预编译融合 dtb（固定产物）
dts/rk3568-lyt-t68m.dts           # 融合后的设备树源码（参考/手动再编译用）
build-dtb.sh                      # dtb 手动编译脚本（改源码时才用）
scripts/build-fnnas.sh            # 完整固件打包脚本
.github/workflows/build-fnnas-image.yml  # GitHub Actions 云打包
```

## 烧录到 T68M（eMMC / TF）

```bash
gzip -dk fnnas-official-rockchip_<ver>-subboard.img.gz
# 写盘（把 /dev/sdX 换成目标盘，务必先确认盘符）
sudo dd if=fnnas-official-rockchip_<ver>-subboard.img of=/dev/sdX bs=4M status=progress conv=fsync
# 或在 Windows 下用 balenaEtcher / Rufus / Win32DiskImager 烧录
```

> 引导 `fdtfile=rockchip/rk3568-lyt-t68m.dtb` 已配置；串口 `console=ttyS2,1500000`。

## 手动改 dtb 需重新生成时

```bash
# 修改 dts/rk3568-lyt-t68m.dts 后，本地（或临时 Actions）重新编译
./build-dtb.sh
cp rk3568-lyt-t68m.dtb dist/rk3568-lyt-t68m.dtb
git add dist/rk3568-lyt-t68m.dtb && git commit -m "update dtb"
```

## 验证（开机后）

```bash
dmesg | grep -E "sata|sdmmc2|wifi|r8125|gmac|usb"
lspci -tv   # 2.5G 网卡 RTL8125
cat /sys/block/sata*/device/model   # SATA2 子板硬盘
```

> 已知约束：禁用 `pcie2x1` 后，原 PCIe2x1/miniPCIe 通道上的非 SATA2 设备不可用。
> GPU 用飞牛主线开源驱动（panfrost）。
