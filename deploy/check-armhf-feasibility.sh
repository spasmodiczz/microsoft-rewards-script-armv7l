#!/usr/bin/env bash
# MRS (Microsoft-Rewards-Script) armhf 部署前置体检脚本
# 用法: bash check-armhf-feasibility.sh
# 只读，不修改任何系统配置。

set -uo pipefail

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_INFO=$'\033[36m'; C_RST=$'\033[0m'
say() { printf '%b\n' "$*"; }
hr()  { printf '%s\n' "------------------------------------------------------------"; }

hr
say "${C_INFO}[1/7] 架构${C_RST}"
ARCH=$(uname -m)
DPKG_ARCH=$(dpkg --print-architecture 2>/dev/null || echo "n/a")
say "  uname -m          : ${ARCH}"
say "  dpkg architecture : ${DPKG_ARCH}"
case "$ARCH" in
  armv7l|armv6l|armhf) say "  ${C_BAD}>> 32 位 ARM 用户态，属于本次评估的目标场景${C_RST}" ;;
  aarch64|arm64)       say "  ${C_OK}>> 已经是 64 位，方案 A 已完成，直接 docker compose up 即可${C_RST}" ;;
  *)                   say "  ${C_INFO}>> 非 ARM 架构${C_RST}" ;;
esac

hr
say "${C_INFO}[2/7] 硬件是否支持 64 位（决定能否刷 aarch64 系统）${C_RST}"
HW=$(grep -m1 -i '^Hardware' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')
MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
COMPAT=$(tr -d '\0' < /proc/device-tree/compatible 2>/dev/null | tr '\0' ' ')
[ -n "$HW" ]    && say "  /proc/cpuinfo Hardware : $HW"
[ -n "$MODEL" ] && say "  Device Tree model      : $MODEL"
[ -n "$COMPAT" ]&& say "  Device Tree compatible : $COMPAT"

# 已知"硬件是 64 位但常被刷成 32 位"的 SoC 关键词
KNOWN64="Allwinner sun8i|sun50i|H3|H5|H6|H616|H618|A64|RK3328|RK3399|RK3566|RK3568|RK3588|Amlogic S905|S905X|S905L|S912|S922|A311D|BCM2710|BCM2711|BCM2837|BCM2838"
if echo "$HW $MODEL $COMPAT" | grep -qiE "$KNOWN64"; then
  say "  ${C_OK}>> 命中已知 64 位 SoC，强烈建议刷 Armbian/Debian aarch64 镜像（方案 A）${C_RST}"
else
  say "  ${C_WARN}>> 未命中已知清单，请自行按 SoC 型号到 Armbian 下载页确认是否有 aarch64 镜像${C_RST}"
fi
# 32 位内核下若 CPU 暴露 aarch64 能力
if grep -qi 'aarch64' /proc/cpuinfo 2>/dev/null; then
  say "  ${C_OK}>> cpuinfo 含 aarch64 特性位，CPU 支持 64 位执行态${C_RST}"
fi

hr
say "${C_INFO}[3/7] 内存与 swap${C_RST}"
MEM_MB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
SWAP_MB=$(( $(awk '/SwapTotal/ {print $2}' /proc/meminfo) / 1024 ))
say "  MemTotal  : ${MEM_MB} MB"
say "  SwapTotal : ${SWAP_MB} MB"
if   [ "$MEM_MB" -lt 512 ]; then say "  ${C_BAD}>> <512MB：不建议在本机跑 Chromium，走方案 C${C_RST}"
elif [ "$MEM_MB" -lt 1024 ]; then say "  ${C_BAD}>> ~512MB-1GB：单账号勉强，必须开 zram 并深度降配${C_RST}"
elif [ "$MEM_MB" -lt 2048 ]; then say "  ${C_WARN}>> 1-2GB：可跑 1-2 个账号，务必关闭并行搜索${C_RST}"
else                              say "  ${C_OK}>> >=2GB：资源层面可行${C_RST}"; fi
[ "$SWAP_MB" -eq 0 ] && say "  ${C_WARN}>> 无 swap，建议启用 zram${C_RST}"
command -v zramctl >/dev/null 2>&1 && say "  zramctl 可用" || say "  ${C_WARN}zramctl 不可用，可 apt install zram-tools${C_RST}"

hr
say "${C_INFO}[4/7] Node.js${C_RST}"
if command -v node >/dev/null 2>&1; then
  NODEV=$(node -v); MAJ=${NODEV#v}; MAJ=${MAJ%%.*}
  say "  node : $NODEV  ($(command -v node))"
  say "  项目要求: >=24，但 Node 24 起不再发布 armv7l 二进制，armhf 可用上限为 22.x"
  if   [ "$MAJ" -ge 24 ]; then say "  ${C_OK}>> >=24（若已能安装，说明并非 armv7l 或为自编译版）${C_RST}"
  elif [ "$MAJ" -ge 22 ]; then say "  ${C_WARN}>> 22.x：armhf 上的现实上限，需放宽 package.json engines${C_RST}"
  else                        say "  ${C_BAD}>> <22：需升级，建议 nodejs.org 下载 linux-armv7l 包${C_RST}"; fi
else
  say "  ${C_BAD}>> 未安装 node${C_RST}"
fi

hr
say "${C_INFO}[5/7] Chromium${C_RST}"
CHROME_BIN=$(command -v chromium || command -v chromium-browser || command -v chromium-headless-shell || echo "")
if [ -n "$CHROME_BIN" ]; then
  say "  ${C_OK}找到系统 Chromium: $CHROME_BIN${C_RST}"
  "$CHROME_BIN" --version 2>/dev/null | sed 's/^/  /'
else
  if command -v apt-cache >/dev/null 2>&1; then
    CAND=$(apt-cache policy chromium 2>/dev/null | awk '/Candidate:/ {print $2}')
    say "  未安装；apt 候选版本: ${CAND:-无}"
    [ -n "$CAND" ] && [ "$CAND" != "(none)" ] && \
      say "  ${C_OK}>> 可用 sudo apt install -y chromium chromium-headless-shell 后改 executablePath 接入${C_RST}"
  else
    say "  ${C_WARN}>> 未找到 chromium，且非 apt 系发行版${C_RST}"
  fi
fi
say "  注意: npx patchright install chromium 在 armv7l 上必然失败（无该架构构建）"

hr
say "${C_INFO}[6/7] Docker${C_RST}"
if command -v docker >/dev/null 2>&1; then
  say "  docker : $(docker --version 2>/dev/null)"
  DPLAT=$(docker buildx inspect 2>/dev/null | grep -i '^Platforms' | head -1)
  [ -n "$DPLAT" ] && say "  buildx : $DPLAT"
  say "  ${C_BAD}>> 官方 node:24-slim 无 linux/arm/v7 manifest，原 Dockerfile 无法直接构建${C_RST}"
else
  say "  未安装 docker（方案 B 裸跑时不需要）"
fi

hr
say "${C_INFO}[7/7] 磁盘${C_RST}"
df -h / 2>/dev/null | awk 'NR==1 || NR==2 {print "  "$0}'
say "  Chromium + node_modules 约占 1-1.5GB，建议 / 剩余空间 >=3GB"

hr
say "${C_INFO}结论速查${C_RST}"
say "  支持 aarch64 的 SoC  -> 方案 A：刷 64 位系统，原生 Docker 部署（推荐）"
say "  只能用 armhf        -> 方案 B：Node22 + 系统 Chromium(改 executablePath) + impit 换 undici + 深度降配"
say "  内存 <512MB         -> 方案 C：本机只做调度，浏览器任务交给远端机器的 API_MODE 容器"
hr
