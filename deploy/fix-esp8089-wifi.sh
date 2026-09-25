#!/bin/bash
# ============================================================
# ESP8089 SDIO WiFi 修复 / 诊断脚本  (RK3229 rk322x-box, Armbian)
# 内核: 6.18.52-current-rockchip  |  armv7l
#
# 用法:
#   修复配置(需要root, 不重启):   bash fix-esp8089-wifi.sh fix
#   仅诊断, 不改动任何文件:        bash fix-esp8089-wifi.sh diag
#   连接指定 WiFi:                 bash fix-esp8089-wifi.sh connect "SSID" "密码"
#   完全验证(连接后跑):            bash fix-esp8089-wifi.sh verify
# ============================================================
set -u

CONF=/etc/modprobe.d/esp8089.conf

# ------------------------------------------------------------
# 晶振参数映射 (来自 modinfo esp8089 官方定义, 权威)
#   crystal=0  -> 40MHz  (驱动内建默认值)
#   crystal=1  -> 26MHz
#   crystal=2  -> 24MHz
#
# 本机实测: 26MHz, 即 crystal=1
#
# !!! 写错晶振值的后果 !!!
#   dmesg 会看到:
#     esp8089: resetting event timeout
#     esp8089: esp_init_all failed: -110
#     esp8089: first error exit
#     PC is at esp_pub_init_all+0x60/0x350 [esp8089]
#   然后 probe 失败导致 Oops, 反复重试会拖死 MMC 子系统 -> 整机假死
# ------------------------------------------------------------
CRYSTAL=1
# 注意: no_auto_sleep 在当前内核已不存在, 传了只会被忽略:
#   esp8089: unknown parameter 'no_auto_sleep' ignored
# 所以配置里不要写它.

case "${1:-diag}" in
# ============================================================
fix)
    if [ "$(id -u)" != "0" ]; then echo "请用 root 运行"; exit 1; fi
    echo ">>> 备份现有配置"
    [ -f "$CONF" ] && cp -n "$CONF" "$CONF.bak.$(date +%Y%m%d_%H%M%S)"
    ls -l "$CONF"* 2>/dev/null

    # 检查是否有脚本在循环重载 esp8089 (这是死机循环的元凶之一)
    echo ">>> 检查是否有自动重载 esp8089 的脚本/服务"
    grep -rn -iE 'esp8089|insmod|rmmod' \
        /etc/rc.local /etc/crontab /etc/cron.d/ /etc/systemd/system/ \
        /root/ /etc/network/if-up.d/ 2>/dev/null \
        | grep -v 'Binary' || echo "   (未发现自动重载, 正常)"

    echo ">>> 写入正确配置"
    cat > "$CONF" <<EOF
# ESP8089 SDIO WiFi (RK3229 / rk322x-box)
# crystal frequency: 0=40MHz, 1=26MHz, 2=24MHz
# 本机实测晶振 26MHz -> crystal=1
# 写错会导致 esp_init_all 超时(-110) 并 Oops -> 整机假死
options esp8089 crystal=$CRYSTAL
EOF
    cat "$CONF"

    echo
    echo ">>> 配置已修正。注意: 当前已加载的模块参数不会变,"
    echo "    需要下次启动(或手动 reload)才生效 —— 本脚本不自动重启。"
    echo "    当前运行中的参数: $(cat /sys/module/esp8089/parameters/crystal 2>/dev/null || echo '模块未加载')"
    echo
    echo ">>> 运行中的驱动是否健康看这里:"
    if ip link show wlan0 >/dev/null 2>&1; then
        echo "    wlan0 存在 -> 驱动 OK"
    else
        echo "    !! 无 wlan0 -> 驱动未起来, 检查 dmesg | grep -i esp"
    fi
    ;;

# ============================================================
diag)
    echo "==================== 1. 系统 ===================="
    uname -a
    echo "uptime: $(uptime)"
    echo
    echo "==================== 2. 模块加载状态 ===================="
    lsmod | grep -Ei 'esp|mac80211|cfg80211' || echo "!! esp8089 未加载"
    echo
    echo "--- 当前生效参数 ---"
    for f in /sys/module/esp8089/parameters/*; do
        [ -e "$f" ] && echo "  $(basename "$f") = $(cat "$f")"
    done 2>/dev/null
    echo
    echo "--- modinfo 权威定义 ---"
    modinfo esp8089 2>/dev/null | grep -iE 'parm|filename'
    echo
    echo "==================== 3. 配置文件 ===================="
    echo "--- $CONF ---"
    cat "$CONF" 2>/dev/null || echo "(不存在)"
    echo
    echo "--- 备份文件 ---"
    ls -l "$CONF"* 2>/dev/null
    echo
    echo "==================== 4. 设备树 / overlay ===================="
    echo "--- armbianEnv.txt ---"
    cat /boot/armbianEnv.txt 2>/dev/null
    echo
    echo "--- 可用 wlan 相关 overlay ---"
    ls /boot/dtb/overlay/ 2>/dev/null | grep -iE 'wlan|wifi|esp|sdio'
    echo
    echo "==================== 5. 固件 ===================="
    ls -l /lib/firmware/eagle_fw_*.bin 2>/dev/null || echo "!! 固件缺失"
    echo "eagle_path = $(cat /sys/module/esp8089/parameters/eagle_path 2>/dev/null)"
    echo
    echo "==================== 6. dmesg (esp/sdio) ===================="
    dmesg | grep -iE 'esp|mmc1' | tail -30
    echo
    echo "==================== 7. 接口 & 网络 ===================="
    ip -br link
    echo
    echo "--- NM 设备 ---"
    nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null
    echo
    echo "--- NM 已存连接 ---"
    nmcli -t -f NAME,TYPE,DEVICE connection show 2>/dev/null
    echo
    echo "--- 扫描测试 (能列出AP = 射频/固件正常) ---"
    nmcli -f SSID,SIGNAL,CHAN,SECURITY device wifi list 2>/dev/null | head -10
    echo
    echo "--- 服务状态 ---"
    for s in NetworkManager wpa_supplicant systemd-networkd; do
        printf '  %-20s %s\n' "$s:" "$(systemctl is-active $s 2>/dev/null)"
    done
    ;;

# ============================================================
connect)
    SSID="${2:-}"; PASS="${3:-}"
    if [ -z "$SSID" ]; then echo "用法: $0 connect \"SSID\" \"密码\""; exit 1; fi
    echo ">>> 连接 $SSID ..."
    nmcli device wifi connect "$SSID" password "$PASS"
    sleep 6
    echo "--- 结果 ---"
    nmcli -t -f DEVICE,TYPE,STATE device | grep wlan
    ip -br addr show wlan0
    ;;

# ============================================================
verify)
    echo "==================== WiFi 恢复验证 ===================="
    echo "--- 1) 接口存在且 UP ---"
    ip -br link show wlan0 || { echo "FAIL: 无 wlan0"; exit 1; }
    echo
    echo "--- 2) 已连接 AP ---"
    nmcli -t -f DEVICE,STATE,CONNECTION device | grep wlan0
    iw dev wlan0 link 2>/dev/null || nmcli device show wlan0 2>/dev/null | grep -E 'GENERAL.STATE|IP4.ADDRESS|IP4.GATEWAY'
    echo
    echo "--- 3) 拿到 IP ---"
    ip -br addr show wlan0 | grep -q 'inet ' && ip -br addr show wlan0 || echo "FAIL: 无 IP"
    echo
    echo "--- 4) 网关可达 ---"
    ping -c 2 -W 3 192.168.1.1 >/dev/null 2>&1 && echo "OK: 网关通" || echo "FAIL: 网关不通"
    echo
    echo "--- 5) 外网可达 ---"
    ping -c 2 -W 3 223.5.5.5 >/dev/null 2>&1 && echo "OK: 外网通" || echo "FAIL: 外网不通"
    echo
    echo "--- 6) DNS 解析 ---"
    getent hosts www.baidu.com >/dev/null 2>&1 && echo "OK: DNS 正常" || echo "FAIL: DNS 异常"
    echo
    echo "--- 7) 信号质量 ---"
    cat /proc/net/wireless 2>/dev/null
    ;;

*)
    echo "用法: $0 {fix|diag|connect \"SSID\" \"密码\"|verify}"
    ;;
esac
