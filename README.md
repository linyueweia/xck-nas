# xck-nas

基于**飞牛主线内核**（[unifreq/linux-6.12.y](https://github.com/unifreq/linux-6.12.y)）编译 LYT T68M（RK3568）用于**飞牛 fnOS** 的设备树 `rk3568-lyt-t68m.dtb`。

## 背景

- 飞牛主线内核已原生包含 T68M 基础支持（网口/USB/PCIe/启动），但**不含子板定义**。
- 本仓库在主线 `rk3568-lyt-t68m.dts` 基础上，**融合 iStoreOS 的子板补丁**：
  - **SATA2**（`sata@fc800000`）
  - **SDIO WiFi AIC8800**（`sdmmc2` + `sdio_pwrseq`）
  - 按 iStoreOS v2 策略**禁用 `pcie2x1`**，释放 `combphy2` 给 SATA2（RK3568 的 combphy2 在 SATA2 与 PCIe2x1 之间互斥）。

## 目录结构

```
dts/rk3568-lyt-t68m.dts   # 融合后的设备树源码
build-dtb.sh              # 编译脚本（workflow 与本地通用）
.github/workflows/build-dtb.yml  # GitHub Actions 云编译
```

## 手动触发云编译

1. Fork / 进入本仓库
2. **Actions → Build fnOS device tree → Run workflow**
3. 下载产物 `rk3568-lyt-t68m.dtb`

## 部署到飞牛 fnOS

在飞牛系统里，将编译出的 dtb 覆盖到启动分区：

```bash
# 一键覆盖（需先确认 boot 分区挂载位置）
sudo cp rk3568-lyt-t68m.dtb /boot/dtb/rockchip/rk3568-lyt-t68m.dtb
sudo reboot
```

> 若启动引导使用 `armbianEnv.txt`（或 extlinux.conf / fnEnv.txt），确保其中
> `fdtfile=rockchip/rk3568-lyt-t68m.dtb`。串口 `console=ttyS2,1500000`。

## 验证

开机后核对各接口：

```bash
dmesg | grep -E "sata|sdmmc2|wifi|r8125|gmac|usb"
lspci -tv   # 2.5G 网卡 RTL8125
cat /sys/block/sata*/device/model   # SATA2 子板硬盘
```

> 已知约束：由于禁用了 `pcie2x1`，原 PCIe2x1/miniPCIe 通道上的设备（非 SATA2 用法）将不可用。
> GPU 用飞牛主线开源驱动（panfrost），如需对照请参考社区其它已适配 rk3568 机型的 GPU 节点。

## 支持性说明

- 编译**只编 dtb**，不烧写、不改系统；实际能否完整运行仍建议在 T68M 实机验证。
- 飞牛系统根分区需为 **btrfs**（官方 OTA 要求），本 dtb 不涉及根分区格式。
