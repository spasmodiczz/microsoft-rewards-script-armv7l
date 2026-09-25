#!/usr/bin/env bash
# =============================================================================
#  run_daily.sh —— 裸金属适配版（基于 scripts/docker/run_daily.sh v4.3.2.3）
#
#  作用：单次运行 MRS，并输出 start_unattended.sh 依赖的三个判定标记：
#          [RUN-END] 全部账户完成 | 处理账户数=N | 获得积分=X | 原余额=.. | ...（由 Logger.ts 输出）
#          [run_daily.sh] Script completed successfully.     （成功）
#          [run_daily.sh] ERROR: Script failed!              （失败）
#
#  相对上游的改动（4 处，均已标注 [BARE-METAL]）：
#   1. 工作目录 /usr/src/microsoft-rewards-script → /opt/mrs（可覆写 BASE）
#   2. 启动时载入 /opt/mrs/.env：MRS 自身**不含 dotenv**，ACCOUNT_* 必须由环境注入，
#      否则进程读不到账号。用逐行解析而非 source，避免密码里的 ! # $ & 被 shell 解释。
#   3. 锁进程识别判据从 'scripts/docker/run_daily\.sh' 放宽为 'run_daily\.sh'：
#      原判据只认 Docker 路径，在裸金属下会把"活着的自己"误判为无关 PID 而删锁 → 并发双跑。
#   4. 启动命令可用 MRS_CMD 覆盖（默认 node ./dist/index.js，比 npm start 省约 50-80MB）。
#
#  可调环境变量：
#      BASE                       工作目录，默认 /opt/mrs
#      MRS_CMD                    实际启动命令，默认 node ./dist/index.js
#      SKIP_RANDOM_SLEEP=true     跳过 5-50 分钟随机延迟（调度由外层负责，默认已跳过）
#      STUCK_PROCESS_TIMEOUT_HOURS 卡死进程被强杀的时限，默认 8 小时
#      MIN_SLEEP_MINUTES / MAX_SLEEP_MINUTES  随机延迟区间（仅 SKIP_RANDOM_SLEEP != true 时生效）
# =============================================================================
set -euo pipefail

_SKIP_SLEEP_OVERRIDE="${SKIP_RANDOM_SLEEP:-}"
BASE="${BASE:-/opt/mrs}"

# ---------------------------------------------------------------------------
# [BARE-METAL] 载入 .env
# ---------------------------------------------------------------------------
load_env_file() {
    [ -f "$BASE/.env" ] || return 0
    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
            *=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        key="$(printf '%s' "$key" | tr -d '[:space:]')"
        # 变量名必须合法，否则 export 会报错（并因 set -e 中断）
        case "$key" in
            [A-Za-z_][A-Za-z0-9_]*) ;;
            *) echo "[$(date)] [run_daily.sh] WARN: 跳过非法变量名: $key" >&2; continue ;;
        esac
        # 去掉成对引号
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        export "$key=$val"
    done < "$BASE/.env"
}
load_env_file

# [BARE-METAL] 运行时环境默认值（无论被 systemd / cron / 手工调用都能正确启动）
export NODE_ENV="${NODE_ENV:-production}"
export TZ="${TZ:-Asia/Shanghai}"
export MRS_LOW_MEMORY="${MRS_LOW_MEMORY:-1}"
export MRS_HTTP_BACKEND="${MRS_HTTP_BACKEND:-fetch}"
export MRS_CHROME_ARGS="${MRS_CHROME_ARGS:-}"
export CHROME_PATH="${CHROME_PATH:-/usr/bin/chromium}"
export PLAYWRIGHT_BROWSERS_PATH=0
export SKIP_RANDOM_SLEEP=true            # [BARE-METAL] 调度交给外层，默认不等随机延迟
export STUCK_PROCESS_TIMEOUT_HOURS="${STUCK_PROCESS_TIMEOUT_HOURS:-8}"
# stdbuf 强制行缓冲：外层守护 tail -f 日志时才能实时看到进度，否则 node 走管道会攒着输出
MRS_CMD="${MRS_CMD:-stdbuf -oL -eL node ./dist/index.js}"

# CHROME_PATH 指向的文件不存在时自动探测
if [ ! -x "$CHROME_PATH" ]; then
    for _c in /usr/bin/chromium /usr/bin/chromium-browser /usr/bin/chromium-headless-shell \
              /usr/lib/chromium/chromium; do
        if [ -x "$_c" ]; then CHROME_PATH="$_c"; break; fi
    done
fi
export CHROME_PATH

# Restore container environment (ACCOUNT_*, CONFIG_*, etc.) lost when cron spawns this job
if [ -f /etc/container_env ]; then
    # shellcheck source=/dev/null
    . /etc/container_env
fi

# Re-apply the caller's override so sourcing /etc/container_env can't reset it.
[ -n "$_SKIP_SLEEP_OVERRIDE" ] && SKIP_RANDOM_SLEEP="$_SKIP_SLEEP_OVERRIDE"
unset _SKIP_SLEEP_OVERRIDE

# [BARE-METAL] 工作目录
cd "$BASE"

LOCKFILE=/tmp/run_daily.lock

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_nonnegative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_run_daily_process() {
    local pid="$1"
    [ -r "/proc/$pid/cmdline" ] || return 1
    # [BARE-METAL] 原判据 'scripts/docker/run_daily\.sh' 在裸金属下永远不匹配
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q 'run_daily\.sh'
}

self_heal_lockfile() {
    # If lockfile exists but is empty → remove it
    if [ -f "$LOCKFILE" ]; then
        local lock_content
        lock_content=$(<"$LOCKFILE" || echo "")

        if [[ -z "$lock_content" ]]; then
            echo "[$(date)] [run_daily.sh] Found empty lockfile → removing."
            rm -f "$LOCKFILE"
            return
        fi

        # If lockfile contains non-numeric PID → remove it
        if ! [[ "$lock_content" =~ ^[0-9]+$ ]]; then
            echo "[$(date)] [run_daily.sh] Found corrupted lockfile content ('$lock_content') → removing."
            rm -f "$LOCKFILE"
            return
        fi

        # If lockfile contains PID but process is dead → remove it
        if ! kill -0 "$lock_content" 2>/dev/null; then
            echo "[$(date)] [run_daily.sh] Lockfile PID $lock_content is dead → removing stale lock."
            rm -f "$LOCKFILE"
            return
        fi

        if ! is_run_daily_process "$lock_content"; then
            echo "[$(date)] [run_daily.sh] Lockfile PID $lock_content is not run_daily.sh → removing stale lock."
            rm -f "$LOCKFILE"
        fi
    fi
}

acquire_lock() {
    local max_attempts=5
    local attempt=0
    local timeout_hours=${STUCK_PROCESS_TIMEOUT_HOURS:-8}
    local timeout_seconds
    local existing_pid="unknown"

    if ! is_positive_integer "$timeout_hours"; then
        echo "[$(date)] [run_daily.sh] ERROR: STUCK_PROCESS_TIMEOUT_HOURS must be a positive integer." >&2
        return 2
    fi
    timeout_seconds=$((timeout_hours * 3600))

    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        # Try to create lock with current PID
        if (set -C; echo "$$" > "$LOCKFILE") 2>/dev/null; then
            echo "[$(date)] [run_daily.sh] Lock acquired successfully (PID: $$)"
            return 0
        fi

        # Lock exists, validate it
        if [ -f "$LOCKFILE" ]; then
            existing_pid=$(<"$LOCKFILE" || echo "")

            echo "[$(date)] [run_daily.sh] Lock file exists with PID: '$existing_pid'"

            # If lockfile content is invalid → delete and retry
            if [[ -z "$existing_pid" || ! "$existing_pid" =~ ^[0-9]+$ ]]; then
                echo "[$(date)] [run_daily.sh] Removing invalid lockfile → retrying..."
                rm -f "$LOCKFILE"
                continue
            fi

            # If process is dead → delete and retry
            if ! kill -0 "$existing_pid" 2>/dev/null; then
                echo "[$(date)] [run_daily.sh] Removing stale lock (dead PID: $existing_pid)"
                rm -f "$LOCKFILE"
                continue
            fi

            if ! is_run_daily_process "$existing_pid"; then
                echo "[$(date)] [run_daily.sh] Removing stale lock owned by unrelated PID $existing_pid"
                rm -f "$LOCKFILE"
                continue
            fi

            # Check process runtime → kill if exceeded timeout
            local process_age
            if process_age=$(ps -o etimes= -p "$existing_pid" 2>/dev/null | tr -d ' '); then
                if [ "$process_age" -gt "$timeout_seconds" ]; then
                    echo "[$(date)] [run_daily.sh] Killing stuck process $existing_pid (${process_age}s > ${timeout_hours}h)"
                    kill -TERM "$existing_pid" 2>/dev/null || true
                    sleep 5
                    kill -KILL "$existing_pid" 2>/dev/null || true
                    rm -f "$LOCKFILE"
                    continue
                fi
            fi
        fi

        echo "[$(date)] [run_daily.sh] Lock held by PID $existing_pid, attempt $attempt/$max_attempts"
        sleep 2
    done

    echo "[$(date)] [run_daily.sh] Could not acquire lock after $max_attempts attempts; exiting."
    return 1
}

release_lock() {
    if [ -f "$LOCKFILE" ]; then
        local lock_pid
        lock_pid=$(<"$LOCKFILE")
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$LOCKFILE"
            echo "[$(date)] [run_daily.sh] Lock released (PID: $$)"
        fi
    fi
}

# Always release the lock on exit, including interrupt/termination paths.
trap release_lock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "[$(date)] [run_daily.sh] Current process PID: $$"
echo "[$(date)] [run_daily.sh] 环境: node=$(node -v 2>/dev/null) | CHROME_PATH=$CHROME_PATH | BASE=$BASE | CMD=$MRS_CMD"
echo "[$(date)] [run_daily.sh] 内存: $(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)MB 可用 / $(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)MB 总计"

# Self-heal any broken or empty locks before proceeding
self_heal_lockfile

if acquire_lock; then
    :
else
    lock_status=$?
    [ "$lock_status" -eq 2 ] && exit 1
    exit 0
fi

# Random sleep between MIN and MAX to spread execution
MINWAIT=${MIN_SLEEP_MINUTES:-5}
MAXWAIT=${MAX_SLEEP_MINUTES:-50}

if ! is_nonnegative_integer "$MINWAIT" || ! is_nonnegative_integer "$MAXWAIT"; then
    echo "[$(date)] [run_daily.sh] ERROR: MIN_SLEEP_MINUTES and MAX_SLEEP_MINUTES must be non-negative integers." >&2
    exit 1
fi
if [ "$MAXWAIT" -lt "$MINWAIT" ]; then
    echo "[$(date)] [run_daily.sh] ERROR: MAX_SLEEP_MINUTES must be greater than or equal to MIN_SLEEP_MINUTES." >&2
    exit 1
fi

MINWAIT_SEC=$((MINWAIT*60))
MAXWAIT_SEC=$((MAXWAIT*60))

if [ "${SKIP_RANDOM_SLEEP:-false}" != "true" ]; then
    if [ "$MAXWAIT_SEC" -eq "$MINWAIT_SEC" ]; then
        SLEEPTIME=$MINWAIT_SEC
    else
        SLEEPTIME=$((MINWAIT_SEC + RANDOM % (MAXWAIT_SEC - MINWAIT_SEC + 1)))
    fi
    echo "[$(date)] [run_daily.sh] Sleeping for $((SLEEPTIME/60)) minutes ($SLEEPTIME seconds)"
    sleep "$SLEEPTIME"
else
    echo "[$(date)] [run_daily.sh] Skipping random sleep"
fi

# Start the actual script
echo "[$(date)] [run_daily.sh] Starting script..."
run_status=0
if [ "${API_MODE:-false}" = "true" ]; then
    if node scripts/api/trigger.js; then
        echo "[$(date)] [run_daily.sh] Script completed successfully (via API)."
    else
        echo "[$(date)] [run_daily.sh] ERROR: Script failed (via API)!" >&2
        run_status=1
    fi
else
    # [BARE-METAL] 原为 npm start；直接跑 node 省一层 npm 进程开销（约 50-80MB RSS）
    if eval "$MRS_CMD"; then
        echo "[$(date)] [run_daily.sh] Script completed successfully."
    else
        echo "[$(date)] [run_daily.sh] ERROR: Script failed!" >&2
        run_status=1
    fi
fi

echo "[$(date)] [run_daily.sh] Script finished"
# Lock is released automatically via trap
exit "$run_status"
