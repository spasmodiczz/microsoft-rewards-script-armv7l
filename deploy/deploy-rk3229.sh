#!/usr/bin/env bash
# Microsoft-Rewards-Script 在 RK3229 (armhf / armv7l) 上的部署脚本
#
# 前置：Armbian (Debian trixie) 已刷好，能上网，建议以 root 执行。
# 用法：
#   sudo bash deploy-rk3229.sh
#
# 说明：本脚本不改动系统分区表，只做「装依赖 + 构建 + 生成配置 + 注册定时任务」。
#       修改 /boot/armbianEnv.txt 前会自动备份。

set -euo pipefail

MRS_DIR="${MRS_DIR:-/opt/mrs}"
RUN_HOUR="${RUN_HOUR:-3}"          # 每天几点跑（凌晨 3 点，避开白天）
SERVICE_USER="${SERVICE_USER:-root}"

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_INFO=$'\033[36m'; C_RST=$'\033[0m'
say() { printf '%b\n' "$*"; }
hr()  { printf '%s\n' "------------------------------------------------------------"; }
ok()  { say "  ${C_OK}$*${C_RST}"; }
warn(){ say "  ${C_WARN}$*${C_RST}"; }
bad() { say "  ${C_BAD}$*${C_RST}"; }

[ "$(id -u)" -eq 0 ] || { bad "请用 root 执行（sudo bash $0）"; exit 1; }

hr
say "${C_INFO}[1/7] 环境检查${C_RST}"
ARCH=$(uname -m)
say "  架构: $ARCH"
[ "$ARCH" = "armv7l" ] || warn "当前不是 armv7l，本脚本针对 32 位 ARM 调优"
MEM_MB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
say "  内存: ${MEM_MB} MB"
[ "$MEM_MB" -lt 900 ] && warn "内存偏小，Chromium 峰值可达 650MB，务必开启 zswap/zram"

hr
say "${C_INFO}[2/7] 内存保护：zswap${C_RST}"
if [ -d /sys/module/zswap/parameters ]; then
  # 立即生效（重启后失效）
  echo Y      > /sys/module/zswap/parameters/enabled          2>/dev/null || true
  echo lz4    > /sys/module/zswap/parameters/compressor       2>/dev/null || true
  echo zsmalloc > /sys/module/zswap/parameters/zpool          2>/dev/null || true
  echo 25     > /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || true
  ok "zswap 已在运行时启用（enabled=$(cat /sys/module/zswap/parameters/enabled 2>/dev/null)）"

  # 永久生效（写 boot 配置，先备份）
  ENV_TXT=/boot/armbianEnv.txt
  if [ -f "$ENV_TXT" ]; then
    cp -n "$ENV_TXT" "${ENV_TXT}.bak.$(date +%s)" && say "  已备份 $ENV_TXT"
    ZARGS="zswap.enabled=1 zswap.compressor=lz4 zswap.zpool=zsmalloc zswap.max_pool_percent=25"
    if grep -q '^extraargs=' "$ENV_TXT"; then
      if ! grep -q 'zswap.enabled' "$ENV_TXT"; then
        sed -i "s/^extraargs=\(.*\)$/extraargs=\1 $ZARGS/" "$ENV_TXT"
        ok "已把 zswap 参数并入现有 extraargs"
      else
        ok "extraargs 中已存在 zswap 参数"
      fi
    else
      echo "extraargs=$ZARGS" >> "$ENV_TXT"
      ok "已写入 extraargs（重启后永久生效）"
    fi
  else
    warn "未找到 /boot/armbianEnv.txt，zswap 仅本次运行时生效"
  fi
else
  warn "内核未暴露 zswap 参数，改用 zram：sudo apt install -y zram-tools"
fi
sysctl -w vm.swappiness=80 >/dev/null 2>&1 && ok "vm.swappiness=80（让冷页面尽早换出）"
echo 'vm.swappiness=80' > /etc/sysctl.d/99-mrs-swappiness.conf 2>/dev/null || true
say "  当前 swap："
swapon --show 2>/dev/null | sed 's/^/    /' || true

hr
say "${C_INFO}[3/7] Node.js ${C_RST}（armv7l 官方二进制的上限是 22.x）"
NEED_NODE=0
if command -v node >/dev/null 2>&1; then
  NODEV=$(node -v); MAJ=${NODEV#v}; MAJ=${MAJ%%.*}
  say "  已安装: $NODEV"
  [ "$MAJ" -lt 22 ] && NEED_NODE=1
else
  NEED_NODE=1
fi

if [ "$NEED_NODE" -eq 1 ]; then
  say "  正在获取 Node 22 armv7l 官方包..."
  # 国内若下载慢，可把下面两个 URL 的主机换成 cdn.npmmirror.com/binaries/node
  TARBALL=$(curl -fsSL https://nodejs.org/dist/latest-v22.x/ \
            | grep -oE 'node-v22\.[0-9]+\.[0-9]+-linux-armv7l\.tar\.xz' | head -1 || true)
  if [ -z "${TARBALL:-}" ]; then
    bad "解析 Node 版本失败，请手动下载 https://nodejs.org/dist/latest-v22.x/ 里的 linux-armv7l 包"
    exit 1
  fi
  say "  下载 $TARBALL"
  curl -fsSL "https://nodejs.org/dist/latest-v22.x/$TARBALL" -o /tmp/node-armv7l.tar.xz
  rm -rf /usr/local/lib/nodejs
  mkdir -p /usr/local/lib/nodejs
  tar -xJf /tmp/node-armv7l.tar.xz -C /usr/local/lib/nodejs --strip-components=1
  ln -sf /usr/local/lib/nodejs/bin/node   /usr/local/bin/node
  ln -sf /usr/local/lib/nodejs/bin/npm    /usr/local/bin/npm
  ln -sf /usr/local/lib/nodejs/bin/npx    /usr/local/bin/npx
  rm -f /tmp/node-armv7l.tar.xz
  ok "Node 已安装: $(node -v)"
else
  ok "Node 版本满足要求"
fi

hr
say "${C_INFO}[4/7] Chromium（用 Debian armhf 官方包，不要自己编译）${C_RST}"
if command -v chromium >/dev/null 2>&1; then
  ok "已安装: $(chromium --version 2>/dev/null || echo '?')"
else
  say "  安装中（约 200MB，视网速 1-3 分钟）..."
  apt-get update -qq
  apt-get install -y --no-install-recommends chromium chromium-headless-shell
  ok "安装完成"
fi
CHROME_BIN=$(command -v chromium || echo /usr/bin/chromium)
say "  CHROME_PATH 将设为: $CHROME_BIN"

hr
say "${C_INFO}[5/7] 项目部署${C_RST}"
if [ ! -d "$MRS_DIR" ]; then
  bad "$MRS_DIR 不存在。请先把代码放过去，例如："
  say "    sudo mkdir -p $MRS_DIR && sudo chown \$USER $MRS_DIR"
  say "    git clone <你的 fork> $MRS_DIR     # 或用 scp / rsync 拷贝"
  exit 1
fi
cd "$MRS_DIR"

say "  安装依赖（跳过浏览器下载，因为 armhf 上没有对应构建）..."
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 PATCHRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
  npm install --ignore-scripts --no-audit --no-fund

say "  编译 TypeScript（armhf 上约 2-5 分钟）..."
npm run build
ok "构建完成：$MRS_DIR/dist/index.js"

mkdir -p "$MRS_DIR/sessions"

hr
say "${C_INFO}[6/7] 生成配置（已按 RK3229 实测数据降配）${C_RST}"

if [ ! -f "$MRS_DIR/config.json" ]; then
node -e '
const fs = require("fs");
const base = fs.existsSync("config.example.json")
  ? JSON.parse(fs.readFileSync("config.example.json", "utf8"))
  : {};

const c = {
  ...base,
  headless: true,
  clusters: 1,
  globalTimeout: "90sec",
  errorDiagnostics: false,
  sessionPath: "sessions",
  accountDelay: { min: "1min", max: "2min" },
  workers: {
    ...(base.workers || {}),
    doVisualSearch: false,
    doBonusSearches: false
  },
  searchSettings: {
    ...(base.searchSettings || {}),
    parallelSearching: false,
    clusterSearch: false,
    searchResultVisitTime: "15sec",
    searchDelay: { min: "1min", max: "2min" },
    readDelay:   { min: "1min", max: "2min" }
  },
  experimental: {
    ...(base.experimental || {}),
    blockMedia: true
  }
};

fs.writeFileSync("config.json", JSON.stringify(c, null, 4) + "\n");
console.log("config.json 已生成");
'
  ok "config.json 已生成（见下方说明）"
else
  warn "已存在 config.json，未覆盖。如需套用降配参数请手动核对以下项："
fi

say ""
say "  ${C_INFO}关键降配项（都写进 config.json 了）：${C_RST}"
say "    clusters=1              单进程，不多开"
say "    parallelSearching=false 不同时开多个搜索页"
say "    clusterSearch=false     不并行多标签"
say "    searchDelay=1-2min      ${C_BAD}重点${C_RST}：example 里的 6-12min 会让单账号跑 9 小时以上"
say "    readDelay=1-2min        ReadToEarn 有 10 篇文章，同理"
say "    blockMedia=true         阻断图片/音视频，明显省内存和带宽"
say "    globalTimeout=90sec     实测单页 15.6 秒，首次更慢，30 秒默认不够"

if [ ! -f "$MRS_DIR/.env" ]; then
cat > "$MRS_DIR/.env" <<'ENVEOF'
# 填好下面两行再启动（账号密码，或用 TOTP / 恢复邮箱）
ACCOUNT_1_EMAIL=you@example.com
ACCOUNT_1_PASSWORD=

# 可选：无密码登录（Authenticator）
#ACCOUNT_1_TOTP_SECRET=
#ACCOUNT_1_RECOVERY_EMAIL=

# 国内账号推荐
ACCOUNT_1_LANG_CODE=zh-CN
ACCOUNT_1_GEO_LOCALE=CN

ACCOUNT_1_SAVE_FINGERPRINT_MOBILE=true
ACCOUNT_1_SAVE_FINGERPRINT_DESKTOP=true
ENVEOF
  warn "已生成 .env 模板，${C_BAD}必须先填入邮箱和密码${C_RST}（$MRS_DIR/.env）"
else
  ok ".env 已存在"
fi

hr
say "${C_INFO}[7/8] 崩溃防护与运行包装（经验来自 382MB 设备上的实战）${C_RST}"

# ── core dump 防护 ────────────────────────────────────────────────
# 低内存设备上 Chromium 会段错误(SIGSEGV)。内核默认 core_pattern=core 时，
# 每次崩溃会在工作目录写出 500MB+ 的 core 文件，几次就能把存储吃光。
echo 'kernel.core_pattern=/dev/null' > /etc/sysctl.d/99-no-coredump.conf
sysctl -w kernel.core_pattern=/dev/null >/dev/null 2>&1 || true
ok "core dump 已禁用：kernel.core_pattern=$(sysctl -n kernel.core_pattern 2>/dev/null)"

# ── journal 日志轮转 ──────────────────────────────────────────────
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-mrs-size.conf <<'EOF'
[Journal]
SystemMaxUse=60M
RuntimeMaxUse=30M
MaxRetentionSec=14day
EOF
systemctl restart systemd-journald 2>/dev/null || true
ok "journal 日志上限 60M，保留 14 天"

# ── 生成运行包装脚本 mrs-run.sh ───────────────────────────────────
cat > "$MRS_DIR/mrs-run.sh" <<'MRSRUN'
#!/usr/bin/env bash
# MRS 单次运行包装：清 core → 磁盘体检 → 备份会话 → 运行 → 失败自愈 → 假成功检测
#
# 可调环境变量：
#   MAX_ATTEMPTS        失败最多重试几次（默认 3）
#   ZERO_POINT_RERUNS   0 积分视为假成功时的重跑次数（默认 1）
#   CLEAR_SESSIONS_AT   当日失败达几次后清空会话强制重登（默认 2，0=从不）

set -uo pipefail

MRS_DIR="${MRS_DIR:-/opt/mrs}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
ZERO_POINT_RERUNS="${ZERO_POINT_RERUNS:-1}"
CLEAR_SESSIONS_AT="${CLEAR_SESSIONS_AT:-2}"

# 关键环境变量自带默认值：无论被 systemd / cron / 手工调用都能正确启动
export NODE_ENV="${NODE_ENV:-production}"
export TZ="${TZ:-Asia/Shanghai}"
export MRS_LOW_MEMORY="${MRS_LOW_MEMORY:-1}"
export MRS_HTTP_BACKEND="${MRS_HTTP_BACKEND:-fetch}"
export CHROME_PATH="${CHROME_PATH:-/usr/bin/chromium}"

# CHROME_PATH 指向的文件不存在时自动探测
if [ ! -x "$CHROME_PATH" ]; then
  for _c in /usr/bin/chromium /usr/bin/chromium-browser /usr/bin/chromium-headless-shell \
            /usr/lib/chromium/chromium; do
    if [ -x "$_c" ]; then CHROME_PATH="$_c"; break; fi
  done
fi

LOG_DIR="$MRS_DIR/logs"
SESS_DIR="$MRS_DIR/sessions"
BACKUP_DIR="$MRS_DIR/sessions_backup_auto"
TODAY=$(date +%Y%m%d)
RUN_LOG="$LOG_DIR/run-$TODAY.log"
FAIL_MARK="$LOG_DIR/.failcount-$TODAY"

mkdir -p "$LOG_DIR" "$SESS_DIR"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$RUN_LOG"; }

# 0) 环境自检（排查时第一眼看这里）
if [ ! -x "$CHROME_PATH" ]; then
  log "ERROR 找不到可用的 Chromium（CHROME_PATH=$CHROME_PATH）"
  log "      请先安装: apt install -y chromium chromium-headless-shell"
  exit 1
fi
log "环境：node=$(node -v 2>/dev/null) | CHROME_PATH=$CHROME_PATH | MRS_LOW_MEMORY=$MRS_LOW_MEMORY | HTTP=$MRS_HTTP_BACKEND"
log "内存：$(awk '/MemAvailable/{printf "%d MB", $2/1024}' /proc/meminfo) 可用 / $(awk '/MemTotal/{printf "%d MB", $2/1024}' /proc/meminfo) 总计"

# 1) 清掉可能存在的 core dump
find "$MRS_DIR" -maxdepth 2 -type f \( -name 'core' -o -name 'core.*' \) -size +5M -print -delete 2>/dev/null \
  | sed 's/^/  删除 core: /' | tee -a "$RUN_LOG"

# 2) 磁盘体检（低于 300MB 先清旧日志）
AVAIL_MB=$(df -Pm "$MRS_DIR" | awk 'NR==2{print $4}')
if [ "${AVAIL_MB:-0}" -lt 300 ]; then
  log "WARN 可用空间仅 ${AVAIL_MB}MB，清理 14 天前的日志"
  find "$LOG_DIR" -name 'run-*.log' -mtime +14 -delete 2>/dev/null
  AVAIL_MB=$(df -Pm "$MRS_DIR" | awk 'NR==2{print $4}')
  log "清理后可用空间 ${AVAIL_MB}MB"
fi
[ "${AVAIL_MB:-0}" -lt 100 ] && log "ERROR 可用空间不足 100MB，仍将尝试运行"

# 3) 备份会话
if [ -d "$SESS_DIR" ] && [ -n "$(ls -A "$SESS_DIR" 2>/dev/null)" ]; then
  mkdir -p "$BACKUP_DIR"
  cp -a "$SESS_DIR/." "$BACKUP_DIR/" 2>/dev/null && log "会话已备份到 $BACKUP_DIR"
fi

fail_count() { [ -f "$FAIL_MARK" ] && cat "$FAIL_MARK" 2>/dev/null || echo 0; }
bump_fail()  { echo $(( $(fail_count) + 1 )) > "$FAIL_MARK"; }

attempt=1
zero_rerun=0

while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  log "===== 第 $attempt/$MAX_ATTEMPTS 次运行开始 ====="

  set -o pipefail
  # stdbuf 强制行缓冲：外层守护脚本 tail -f 本日志时才能实时看到进度
  stdbuf -oL -eL node "$MRS_DIR/dist/index.js" 2>&1 | tee -a "$RUN_LOG"
  rc=${PIPESTATUS[0]}

  SUMMARY=$(grep -o '全部账户完成 | 处理账户数=[0-9]* | 获得积分=[0-9]* | 原余额=[0-9]*' "$RUN_LOG" | tail -1)
  GAINED=$(echo "$SUMMARY" | grep -o '获得积分=[0-9]*' | grep -o '[0-9]*' || echo "")
  # 原余额：读不到时置 -1，避免"余额读取失败"被误判成"账号已满额"
  BEFORE=$(echo "$SUMMARY" | grep -o '原余额=[0-9]*' | grep -o '[0-9]*' || echo "")
  BEFORE=${BEFORE:--1}

  if [ "$rc" -ne 0 ]; then
    bump_fail
    log "本次失败：退出码 $rc（可能是 Chromium 段错误 / OOM / 网络）"
  elif [ -z "$SUMMARY" ]; then
    bump_fail
    log "本次异常：进程退出 0 但未看到「全部账户完成」汇总行"
  else
    log "本次完成：$SUMMARY"
    # 假成功判据：0 积分 **且** 原余额=0（余额读取异常）。
    # 仅 0 积分不足以判定——账号当天已满额也是 0 积分，重跑纯属浪费。
    if [ "${GAINED:-0}" -eq 0 ] && [ "${BEFORE:--1}" -eq 0 ] && [ "$zero_rerun" -lt "$ZERO_POINT_RERUNS" ]; then
      zero_rerun=$((zero_rerun + 1))
      log "疑似假成功（0 积分且原余额异常）→ 第 $zero_rerun 次额外重跑（不计入失败）"
      sleep 60
      continue
    fi
    log "===== 本轮结束：成功 ====="
    exit 0
  fi

  # 失败达阈值 → 清空会话强制重新登录（已备份过）
  if [ "$CLEAR_SESSIONS_AT" -gt 0 ] && [ "$(fail_count)" -ge "$CLEAR_SESSIONS_AT" ]; then
    log "当日失败已达 $(fail_count) 次 → 清空会话强制重新登录"
    find "$SESS_DIR" -mindepth 1 -delete 2>/dev/null
    log "会话已清空（备份在 $BACKUP_DIR）"
  fi

  attempt=$((attempt + 1))
  [ "$attempt" -le "$MAX_ATTEMPTS" ] || break
  backoff=$(( 60 * attempt ))
  log "退避 ${backoff}s 后重试..."
  sleep "$backoff"
done

log "===== 本轮结束：失败（当日累计 $(fail_count) 次）====="
exit 1
MRSRUN

chmod +x "$MRS_DIR/mrs-run.sh"
ok "已生成 $MRS_DIR/mrs-run.sh（失败自愈 + 假成功检测 + 会话备份）"

hr
say "${C_INFO}[8/8] 注册定时任务（systemd timer，每天 ${RUN_HOUR}:00）${C_RST}"

cat > /etc/systemd/system/mrs.service <<EOF
[Unit]
Description=Microsoft Rewards Script (armhf)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$SERVICE_USER
WorkingDirectory=$MRS_DIR
Environment=NODE_ENV=production
Environment=TZ=Asia/Shanghai
Environment=CHROME_PATH=$CHROME_BIN
Environment=MRS_LOW_MEMORY=1
Environment=MRS_HTTP_BACKEND=fetch
Environment=FORCE_HEADLESS=1
ExecStart=$MRS_DIR/mrs-run.sh
TimeoutStartSec=8h
LimitCORE=0
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/mrs.timer <<EOF
[Unit]
Description=Run Microsoft Rewards Script daily

[Timer]
OnCalendar=*-*-* $(printf '%02d' "$RUN_HOUR"):00:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now mrs.timer
ok "定时任务已启用"

hr
say "${C_INFO}完成。常用命令：${C_RST}"
say "  立即跑一次（先看能不能登录）：  systemctl start mrs.service"
say "  跟随系统日志：                  journalctl -u mrs.service -f"
say "  跟随任务日志（含积分汇总）：    tail -f $MRS_DIR/logs/run-\$(date +%Y%m%d).log"
say "  查看下次触发时间：              systemctl list-timers mrs.timer"
say "  停止调度：                      systemctl disable --now mrs.timer"
say "  调整失败重试次数：              编辑 $MRS_DIR/mrs-run.sh 顶部变量"
say ""
say "  ${C_WARN}首次运行建议：${C_RST}"
say "    1) 先填好 $MRS_DIR/.env"
say "    2) systemctl start mrs.service 手动跑一次，用 journalctl -f 观察"
say "    3) 第一次冷启动可能超过 3 分钟（实测首次超时 180 秒），别急"
say "    4) 若报 OOM，先确认 zswap 已开，再把 blockMedia 打开、账号减到 1 个"
say ""
say "  ${C_INFO}无人值守相关（来自 382MB 设备的实战经验）：${C_RST}"
say "    · 会话被清空后要能自动重登 → 建议在 .env 配 ACCOUNT_1_TOTP_SECRET"
say "    · 会话自动备份在 $MRS_DIR/sessions_backup_auto"
say "    · 失败退避重试 3 次、0 积分自动重跑 1 次、失败 2 次清会话重登"
say "    · core dump 已全局禁用（低内存设备上 Chromium 段错误会写出 500MB+ core）"
say "    · 若日后改用 Docker：m.daocloud.io 加速源已失效(401)，Dockerfile 的 FROM 要换"
hr
