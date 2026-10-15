#!/bin/sh
# LYT T68M (RK3568)：硬件看门狗持续喂狗（保命件）。
#
# 为什么：内核整机挂死（如 NPU CMA 分配失败路径，K1 线 2026-10-14 两次实机取证）
# 时软件全灭，只有硬件看门狗能在超时后硬复位自愈；官方 fnOS 对 /dev/watchdog
# 零管理（/usr/trim 全家无一引用），挂死只能人工断电。
#
# 设计要点（勿改）：
#  · fd 常开（exec 3>）——不能每轮 printf > 设备（开-写-关）：部分看门狗驱动在
#    close 时停狗，那样狗会时开时关，内核恰好挂在关狗窗口就永远等不到复位；
#    常开则无论驱动 close 语义如何，喂狗期间狗必然在跑。
#  · 进程死亡后：RK3568 的 Synopsys DesignWare WDT 无 magic close（K1 实测
#    MAGICCLOSE=0），fd 被内核回收后狗继续计数 → 超时硬复位。这正是自愈语义。
#  · systemd Restart=always：脚本异常退出 10 秒内被拉起重新开狗。
#  · 写失败（如 EBUSY：别人占着设备）→ 关 fd 退避重开，反复失败则退出交给 systemd。
WD=/dev/watchdog0
[ -c "$WD" ] || WD=/dev/watchdog
[ -c "$WD" ] || { echo "lyt-t68m-watchdog: no watchdog device" >&2; exit 1; }

exec 3> "$WD" || { echo "lyt-t68m-watchdog: cannot open $WD" >&2; exit 1; }

while true; do
	if ! printf 'x' >&3 2>/dev/null; then
		exec 3>&- 2>/dev/null || true
		sleep 5
		exec 3> "$WD" || { echo "lyt-t68m-watchdog: reopen $WD failed" >&2; exit 1; }
		continue
	fi
	sleep 10
done
