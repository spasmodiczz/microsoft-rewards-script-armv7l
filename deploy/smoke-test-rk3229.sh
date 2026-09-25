#!/usr/bin/env bash
# RK3229 (armhf) Chromium 性能 smoke test
#
# 目的：在决定要不要交叉编译/改造之前，先用系统 Chromium 实测
#       "打开一个 Bing 搜索页要多久、吃多少内存"，据此推算 MRS 单账号耗时。
#
# 依赖：只需要系统里有 chromium / chromium-headless-shell，不需要 Node、不需要编译。
# 用法：bash smoke-test-rk3229.sh
#
# 本脚本只读 + 用临时目录跑浏览器，不改动系统配置。

set -uo pipefail

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_INFO=$'\033[36m'; C_RST=$'\033[0m'
say() { printf '%b\n' "$*"; }
hr()  { printf '%s\n' "------------------------------------------------------------"; }

hr
say "${C_INFO}[1/5] 设备与系统${C_RST}"
say "  架构        : $(uname -m)"
say "  内核        : $(uname -r)"
[ -f /proc/device-tree/model ] && say "  机型        : $(tr -d '\0' < /proc/device-tree/model)"
CPUMODEL=$(grep -m1 -i 'model name\|Hardware' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')
[ -n "$CPUMODEL" ] && say "  CPU         : $CPUMODEL"
say "  核心数      : $(nproc)"
MEM_MB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
SWAP_MB=$(( $(awk '/SwapTotal/ {print $2}' /proc/meminfo) / 1024 ))
say "  内存        : ${MEM_MB} MB"
say "  Swap        : ${SWAP_MB} MB"
if grep -q 'zswap' /proc/cmdline 2>/dev/null || [ -d /sys/module/zswap ]; then
  ENABLED=$(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo "?")
  say "  zswap       : 模块存在，enabled=${ENABLED}"
else
  say "  ${C_WARN}  zswap       : 未启用（1GB 内存设备强烈建议开启）${C_RST}"
fi
say "  负载        : $(awk '{print $1" "$2" "$3}' /proc/loadavg)"

hr
say "${C_INFO}[2/5] 定位 Chromium${C_RST}"
CHROME=""
for c in chromium chromium-browser chromium-headless-shell /usr/lib/chromium/chromium /usr/lib/chromium/chromium-headless-shell; do
  if command -v "$c" >/dev/null 2>&1; then CHROME=$(command -v "$c"); break; fi
  if [ -x "$c" ]; then CHROME="$c"; break; fi
done
if [ -z "$CHROME" ]; then
  say "  ${C_BAD}未找到 Chromium。先安装：${C_RST}"
  say "    sudo apt update && sudo apt install -y chromium chromium-headless-shell"
  say "  （Debian trixie/bookworm 的 armhf 源里有现成包，不要自己编译）"
  exit 1
fi
say "  使用        : $CHROME"
"$CHROME" --version 2>/dev/null | sed 's/^/  版本        : /'

hr
say "${C_INFO}[3/5] 确定 headless 模式${C_RST}"
TMP_PROBE=$(mktemp -d)
if timeout 60 "$CHROME" --headless=new --no-sandbox --disable-gpu \
     --user-data-dir="$TMP_PROBE" --dump-dom about:blank >/dev/null 2>&1; then
  HL="--headless=new"; say "  使用 --headless=new"
else
  HL="--headless";     say "  回退到 --headless（旧模式）"
fi
rm -rf "$TMP_PROBE"

hr
say "${C_INFO}[4/5] 实测：加载 Bing 搜索页 × 3${C_RST}"

sum_rss_of() {   # 求匹配某字符串的所有进程 RSS 之和 (KB)
  local pat="$1" total=0 p r
  for p in $(pgrep -f "$pat" 2>/dev/null); do
    r=$(awk '/VmRSS/{print $2}' /proc/"$p"/status 2>/dev/null)
    [ -n "${r:-}" ] && total=$((total + r))
  done
  echo "$total"
}

run_once() {
  local url="$1" tmpdir start end pid peak rss elapsed
  tmpdir=$(mktemp -d)
  start=$(date +%s%N 2>/dev/null || echo 0)

  timeout 180 "$CHROME" $HL --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --disable-extensions --no-first-run \
    --user-data-dir="$tmpdir" --dump-dom "$url" >/dev/null 2>&1 &
  pid=$!

  peak=0
  while kill -0 "$pid" 2>/dev/null; do
    rss=$(sum_rss_of "$tmpdir")
    [ "${rss:-0}" -gt "$peak" ] && peak=$rss
    sleep 0.4
  done
  wait "$pid" 2>/dev/null
  local rc=$?

  end=$(date +%s%N 2>/dev/null || echo 0)
  if [ "$start" = "0" ] || [ "$end" = "0" ]; then
    elapsed=0
  else
    elapsed=$(( (end - start) / 1000000 ))   # ms
  fi

  LAST_MS=$elapsed
  LAST_PEAK_MB=$((peak / 1024))
  LAST_RC=$rc
  rm -rf "$tmpdir"
}

TOTAL_MS=0; OK_N=0; MAX_PEAK_MB=0
for i in 1 2 3; do
  run_once "https://www.bing.com/search?q=armbian+smoke+test+$i"
  if [ "$LAST_RC" -ne 0 ]; then
    say "  第 $i 次 : ${C_BAD}失败或超时 (rc=$LAST_RC)${C_RST}"
    continue
  fi
  sec=$(awk -v m="$LAST_MS" 'BEGIN{printf "%.1f", m/1000}')
  say "  第 $i 次 : ${sec} 秒，进程树峰值内存 ${LAST_PEAK_MB} MB"
  TOTAL_MS=$((TOTAL_MS + LAST_MS)); OK_N=$((OK_N + 1))
  [ "$LAST_PEAK_MB" -gt "$MAX_PEAK_MB" ] && MAX_PEAK_MB=$LAST_PEAK_MB
done

hr
say "${C_INFO}[5/5] 推算与建议${C_RST}"
if [ "$OK_N" -eq 0 ]; then
  say "  ${C_BAD}三次都失败：Chromium 在本机无法正常工作，不必再考虑本机部署${C_RST}"
  say "  排查：内存是否不足 / 是否缺依赖库 / chromium 版本是否过旧"
  exit 0
fi

AVG_MS=$((TOTAL_MS / OK_N))
AVG_S=$(awk -v m="$AVG_MS" 'BEGIN{printf "%.1f", m/1000}')
# 每账号约 90 次搜索，另加 DailySet/PunchCard/ReadToEarn 等交互开销 1.35 倍
EST_MIN=$(awk -v m="$AVG_MS" 'BEGIN{printf "%.0f", m/1000*90*1.35/60}')

say "  平均单次页面加载 : ${AVG_S} 秒"
say "  进程树峰值内存   : ${MAX_PEAK_MB} MB（可用内存 ${MEM_MB} MB）"
say "  预估单账号耗时   : 约 ${EST_MIN} 分钟（按 90 次搜索 × 1.35 倍其他活动开销）"
say ""

if awk -v m="$AVG_MS" 'BEGIN{exit !(m < 5000)}'; then
  say "  ${C_OK}判定：可以接受。${C_RST}建议继续：Node 22 armv7l + apt chromium 改 executablePath + HTTP 层改造。"
elif awk -v m="$AVG_MS" 'BEGIN{exit !(m < 10000)}'; then
  say "  ${C_WARN}判定：勉强能跑。${C_RST}必须限 1 个账号、关闭 parallelSearching/clusterSearch、"
  say "        只保留核心任务，并接受每天跑 1 小时左右、偶尔失败重跑。"
else
  say "  ${C_BAD}判定：不实用。${C_RST}单页加载就超过 10 秒，单账号要跑 ${EST_MIN} 分钟以上，"
  say "        OOM 与超时会频繁发生。建议走方案 C：本机只做 cron 调度，"
  say "        浏览器任务交给远端 x86/arm64 机器上的 API_MODE 容器。"
fi

if [ "$MAX_PEAK_MB" -gt $((MEM_MB * 70 / 100)) ]; then
  say ""
  say "  ${C_BAD}警告：峰值内存已超过可用内存的 70%，OOM 风险很高。${C_RST}"
  say "        先开 zswap（sudo apt install zram-tools）再测一次。"
fi

hr
say "补充：把上面的数字贴出来即可判断是否需要编译 impit / 是否值得改造。"
hr
