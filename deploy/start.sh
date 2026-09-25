#!/usr/bin/env bash
# =============================================================================
#  Microsoft-Rewards-Script 管理脚本  v5 (2026-09-25 RK3229 裸金属版)
#
#  用法:
#     bash ~/start.sh           进入菜单
#     bash ~/start.sh 1         直接启动(等同菜单选项1)
#     bash ~/start.sh 2         直接清理缓存
#     bash ~/start.sh 3         直接备份凭证
#     bash ~/start.sh 3r        直接从备份恢复凭证
#     bash ~/start.sh 4         直接进入无人值守模式(自动安装断电保活)
#     bash ~/start.sh 5         关闭无人值守守护(卸载保活 cron + 结束进程)
#     bash ~/start.sh 6         手动把设备公网 IPv6 通过 PushPlus 推送到微信
#     bash ~/start.sh 7         手动推送当日汇总(成功/失败/积分/IPv6)
#     bash ~/start.sh 8         立即跑一轮(含自愈+推送),不等定时点
#     bash ~/start.sh log       实时跟随今日日志(Ctrl+C 退出,不影响后台运行)
#     bash ~/start.sh log 200   先显示最后 200 行再实时跟随
#     bash ~/start.sh 10        查看今日随机执行计划(时刻/状态/统计)
#
# ---------------------------------------------------------------------------
#  v5 相对 v4 的改动（随机化定时调度，降低被判定为机器人的风险）
#
#   [背景] v4 是"每天固定一个时刻"触发。固定时刻本身就是很强的机器特征
#          ——真实用户不会每天在同一分钟开始浏览。v5 改为:
#
#   [调度] 每天从候选锚点里随机抽 1~2 个,每个再叠加 0~60 分钟随机延迟
#      - SCHED_SLOTS     候选锚点,默认 02:00,10:00,17:00
#      - SCHED_PICK      每天抽几个;=variable 时在 [1,SCHED_PICK_MAX] 内随机
#      - SCHED_PICK_MAX  variable 模式随机上限,默认 2
#      - SCHED_DELAY_MAX 每个锚点的额外随机延迟上限(分钟),默认 60
#      - SCHED_MIN_GAP   两个执行点最小间隔(分钟),默认 30,避免刚跑完又跑
#      - SCHED_FALLBACK  设为 true 即退回 v4 的"每天单点固定"行为(逃生阀)
#
#   [一致性] 随机用 **日期确定性伪随机**(sha256(salt|日期|序号) 取模),
#      不是 $RANDOM。因此:同一天无论何时、在哪个进程里算,结果都一样;
#      换一天自动得到新计划;进程重启/断电重启后从计划文件恢复,不会重抽、
#      也不会重复触发(已触发的点被标记 done 并落盘)。
#
#   [落盘] $BASE/.unattended/schedule.plan 当日计划(含每点状态)
#          $BASE/.unattended/day.stats    当日统计(成功/失败/积分/预算)
#      两者都按"日期"校验,日期不匹配即自动重算/重置 → 天然支持跨天。
#      用磁盘而非 /tmp,是为了断电重启后仍能恢复。
#
#   [并发] 触发前先原子地"认领"该计划点(标记 done 再执行),再用
#      is_mrs_running 阻止与手动运行(选项1)/上一轮任务并发。
#      选项8(立即跑一轮)走 do_run_now:不取守护锁、不占计划点,
#      因此常驻守护在跑时也能正常手动补跑一轮。
#
#   [新增] 选项 10 / `bash ~/start.sh 10` 查看今日计划(时刻/状态/相对时间/统计)。
#
# ---------------------------------------------------------------------------
#  v4 相对 v3 的改动（从 OpenStick+Docker 迁移到 RK3229 裸金属）
#
#   [执行层] 全面去 Docker
#     - 设备无 Docker(970MB 内存的 armv7l 也不该装)。所有 docker run/exec/logs/
#       restart/ps/prune 全部移除。
#     - 执行器改为 $BASE/run_daily.sh（仓库 scripts/docker/run_daily.sh 的裸金属
#       适配版）。它仍然输出 v3 依赖的三个判定标记，因此**失败/成功判定逻辑原样保留**:
#           [RUN-END] 全部账户完成 | 处理账户数=N | 获得积分=X | 原余额=.. | ...
#           [run_daily.sh] Script completed successfully.
#           [run_daily.sh] ERROR: Script failed!
#     - 原 v3 的失败路径是 `sleep 60; continue`，容器起不来会静默空转死循环；
#       现在执行器是本机的 bash 脚本，起不来会立刻拿到退出码。
#
#   [删除] 不再需要的功能
#     - step_prepare_params：不再 sed 注入 --single-process。
#       --single-process 是给 OpenStick 380MB 的 hack，RK3229 有 970MB，
#       且 DEPLOY_LOG 里它就是反复段错误的元凶。改由 MRS_LOW_MEMORY /
#       MRS_CHROME_ARGS 环境变量提供(在 Browser.ts 内已支持)。
#     - --memory=350m --memory-swap=750m：实测单页峰值 651MB，350MB 必 OOM。
#       裸金属下不加硬限制，靠 485MB swap + zswap 兜底。
#     - ensure_runs_on_start / ensure_no_container_cron：RUN_ON_START、
#       CRON_SCHEDULE 是 Docker 镜像 entrypoint 变量，裸金属无意义且会污染 .env。
#       换成 ensure_no_systemd_timer（停掉 mrs.timer，消除双调度）。
#     - **多次失败清空 sessions** 的功能已按需求删除（不再自动清会话）。
#       sessions 仍可手工备份/恢复（选项 3）。
#
#   [新增] 针对 RK3229 单账号长耗时
#     - MAX_RUN_SECONDS：单轮硬超时(默认 6h)，超时视为失败但**不重试**。
#     - DAY_BUDGET_SECONDS：当天累计运行预算(默认 10h)，用尽则跳过当天。
#     - 定时点到达前先 pgrep 检查上一轮是否还在跑，防止并发双跑抢 970MB。
#     - maybe_daily_summary 在每轮结束后补调一次（v3 只在等待循环里调，
#       RK3229 单轮几小时会错过 23:00 汇总）。
#
#   [其他]
#     - 路径 /home/user/mrs → /opt/mrs；日志保留 30 天 → 7 天(设备仅 4.5GB 可用)。
#     - shebang 改 bash（需要 PIPESTATUS / local）。
#     - do_unattended_off：不再用 pkill -f(会杀掉自己的 SSH 会话)，
#       /proc/PID/task/PID/children 在 rockchip 内核可能不存在，改用 pgrep -P 兜底。
#     - IPv6 + PushPlus 推送部分原样保留（设备实测有公网 IPv6，回显正常）。
#
#  v3 保留的优秀设计（未改动）:
#   1. 成功后看门狗立即返回，外层回到等待逻辑（每天定时点都能触发）
#   2. 断电保活：crontab(@reboot + 每10分钟检查) + flock 单实例锁
#   3. 假成功检测：0积分 且 原余额=0（余额读取异常）→ 自动重跑
#   4. 每日日志目录 + 自动清理
#   5. 锁加固：退出时校验锁归属；等待循环每小时自检，锁被接管则让位
#
#  无人值守模式建议放 screen 里跑(可选,装了保活后非必需):
#     screen -S mrs
#     bash ~/start_unattended.sh 4
#     # 脱离: Ctrl+A 然后 D    回到: screen -r mrs
# =============================================================================
set -u

BASE="${BASE:-/opt/mrs}"
RUNNER="$BASE/run_daily.sh"
SESSIONS="$BASE/sessions"
BACKUP="$BASE/sessions_backup"

# ---- 日志目录(每日一份,自动清理)----
LOG_DIR="$BASE/logs"
LOG_KEEP_DAYS="${LOG_KEEP_DAYS:-7}"

# ---- 无人值守参数(均可用同名环境变量覆盖,便于测试)----
# ── 每日随机调度(取代 v4 的"每天单一固定时间点")────────────────────────────
# 思路: 每天从 SCHED_SLOTS 里随机抽 SCHED_PICK 个"锚点",每个锚点再叠加
#       0..SCHED_DELAY_MAX 分钟的随机延迟,得到当天的实际执行时刻。
#       这样既保留"有个大致窗口"的可预期性,又打破固定时刻的机器特征。
SCHED_SLOTS="${SCHED_SLOTS:-02:00,10:00,17:00}"  # 候选锚点(24 小时制 HH:MM,逗号分隔)
SCHED_PICK="${SCHED_PICK:-2}"                    # 每天抽几个锚点;<2..len> = 固定抽 N 个,variable = 在 [1, len] 内随机
SCHED_PICK_MAX="${SCHED_PICK_MAX:-2}"            # SCHED_PICK=variable 时随机上限(默认 1 或 2)
SCHED_DELAY_MAX="${SCHED_DELAY_MAX:-60}"         # 每个锚点后额外随机延迟的分钟数,取值区间 [0, N]
SCHED_MIN_GAP="${SCHED_MIN_GAP:-30}"             # 两个执行时刻的最小间隔(分钟),避免刚跑完又跑
SCHED_SEED_SALT="${SCHED_SEED_SALT:-mrs-rk3229}" # 随机种子盐值(改了会让"同一天"的计划重排,谨慎)

# 兼容:仅在有程序引用 UNATTEND_HOUR 时保留,现仅用于打印/提示,不再参与调度
UNATTEND_HOUR="${UNATTEND_HOUR:-1}"                       # (已废弃)旧版每天几点执行
MAX_ATTEMPTS="${MAX_ATTEMPTS:-5}"                         # 每天最多自动重启几次
ZERO_POINT_RERUNS="${ZERO_POINT_RERUNS:-2}"               # "假成功"(0积分0余额)每天最多自动重跑几次
MAX_RUN_SECONDS="${MAX_RUN_SECONDS:-$((6*3600))}"         # 单轮硬超时(秒)，0=不限制
DAY_BUDGET_SECONDS="${DAY_BUDGET_SECONDS:-$((10*3600))}"  # 当天累计运行预算(秒)，0=不限制
LOG_FIFO=/tmp/mrs_log_fifo          # 日志管道
WATCH_FLAG=/tmp/mrs_log_failed      # 失败标记
WATCH_DONE_FLAG=/tmp/mrs_log_done   # 成功完成标记
RUNEND_FILE=/tmp/mrs_last_runend    # 最近一次 [RUN-END] 行(用于假成功检测)
LOCKFILE=/tmp/mrs_unattended.lock   # 单实例锁(保活 cron 防重复启动)

# ── 调度计划持久化 ────────────────────────────────────────────────────────
# PLAN 文件存"当天计划"(日期+各时刻+状态),STATS 文件存"当天统计"。
# 两者都按日期校验:日期不匹配即视为过期,自动重算/重置。
# 放在磁盘而非 /tmp,是为了进程重启/断电重启后仍能恢复当天计划与已完成标记,
# 从而避免"守护重启 → 同一个时刻被重复触发"。
SCHED_DIR="${SCHED_DIR:-$BASE/.unattended}"
PLAN_FILE="$SCHED_DIR/schedule.plan"        # 当日执行计划
STATS_FILE="$SCHED_DIR/day.stats"           # 当日统计(成功/失败/积分/预算)

SUMMARY_HOUR="${SUMMARY_HOUR:-23}"                  # 每日汇总推送时间(24 小时制)
SUMMARY_FLAG="$SCHED_DIR/summary.day"                # 当天汇总已推送标记(内容为日期)
IPV6_SERVICES="${IPV6_SERVICES:-https://api6.ipify.org https://v6.ident.me https://ifconfig.co/ip}"
IMMEDIATE="${IMMEDIATE:-false}"                      # 遗留逃生阀:置 true 时选项4 只跑一轮即退出
                                                     # (选项8 已改为 do_run_now,不再依赖此变量)

# ---- 无人值守增强开关 ----
ENABLE_SUPERVISOR="${ENABLE_SUPERVISOR:-true}"       # 自动安装 crontab 保活(断电重启自恢复)
PUSH_ENABLED="${PUSH_ENABLED:-true}"                 # PushPlus 推送开关(需 .env 里有 CONFIG_PUSHPLUS_TOKEN)
SELF="${SELF:-/root/start.sh}"                       # 保活 crontab 里调用的自身路径

# =============================================================================
#  通用工具
# =============================================================================
# 输出到终端 + 追加到当日日志
log_msg() {
    echo "$@"
    mkdir -p "$LOG_DIR" 2>/dev/null
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_DIR/unattended-$(date +%Y%m%d).log" 2>/dev/null
}

# 清理过期日志(只留最近 LOG_KEEP_DAYS 天)
prune_logs() {
    [ -d "$LOG_DIR" ] || return 0
    find "$LOG_DIR" -type f \( -name 'unattended-*.log' -o -name 'run-*.log' \) \
        -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null
}

# 获取设备公网 IPv6 动态地址(依次尝试回显服务;全部失败返回空)
get_public_ipv6() {
    for _svc in $IPV6_SERVICES; do
        _v6=$(curl -6 -s -m 6 "$_svc" 2>/dev/null | tr -d '[:space:]' | head -c 64)
        case "$_v6" in
            *:*) printf '%s\n' "$_v6"; return 0 ;;
        esac
    done
    return 1
}

# JSON 字符串转义(反斜杠/双引号/回车;换行转 \n)
json_escape() {
    printf '%s' "$1" \
      | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g' \
      | awk '{ if (NR>1) printf "\\n"; printf "%s", $0 }'
    printf '\n'
}

# PushPlus 推送(同步版,返回响应文本;自动附带设备公网 IPv6)
push_msg_sync() {
    _title="$1"; _content="$2"
    _token=$(grep '^CONFIG_PUSHPLUS_TOKEN=' "$BASE/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d ' ')
    [ -n "$_token" ] || { echo "!! .env 未配置 CONFIG_PUSHPLUS_TOKEN"; return 1; }
    _v6=$(get_public_ipv6 2>/dev/null)
    _v6line="[IPv6] ${_v6:-获取失败}"
    _body=$(printf '%s\n\n%s' "$_content" "$_v6line")
    _json=$(json_escape "$_body")
    curl -s -m 30 -X POST 'https://www.pushplus.plus/send' \
        -H 'Content-Type: application/json' \
        -d "{\"token\":\"$_token\",\"title\":\"$_title\",\"content\":\"$_json\"}"
    echo ""
}

# PushPlus 推送(后台执行,不阻塞;token 未配置则跳过)
push_msg() {
    _title="$1"; _content="$2"
    [ "$PUSH_ENABLED" = "true" ] || return 0
    _token=$(grep '^CONFIG_PUSHPLUS_TOKEN=' "$BASE/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d ' ')
    [ -n "$_token" ] || return 0
    ( push_msg_sync "$_title" "$_content" >/dev/null 2>&1 ) &
}

# 解析最近一次 [RUN-END] 行里的 获得积分 / 原余额
last_runend_fields() {
    _got=""; _before=""
    [ -f "$RUNEND_FILE" ] || return 0
    _end=$(cat "$RUNEND_FILE" 2>/dev/null)
    [ -n "$_end" ] || return 0
    _got=$(printf '%s' "$_end" | sed -n 's/.*获得积分=\([0-9][0-9]*\).*/\1/p')
    _before=$(printf '%s' "$_end" | sed -n 's/.*原余额=\([0-9][0-9]*\).*/\1/p')
    _got=${_got:-}
    _before=${_before:-}
}

# 是否已有 MRS 主进程在跑(不用 pkill -f，避免匹配自身)
is_mrs_running() {
    pgrep -f 'dist/index\.js' >/dev/null 2>&1
}

# =============================================================================
#  每日随机调度器
#
#  设计目标(对应需求 1~4):
#    1. 候选时间点 / 每日选取数量 / 随机延迟范围 全部可配置,默认 02:00,10:00,17:00
#       + 抽 1~2 个 + 延迟 0~60 分钟;
#    2. 每天重算计划,同一天内结果保持一致(确定性伪随机 + 计划落盘);
#       已触发的时刻打标记,不重复触发;计划时刻与实际触发时刻都写日志;
#    3. 沿用原有入口(选项4/8)、锁与 crontab 保活;手动运行(选项1)不读写计划文件,
#       与之互不干扰;触发前用 is_mrs_running 拦并发;
#    4. 各配置含义、边界(跨天、重启恢复、参数非法)见下方各函数注释。
# =============================================================================

# ---- 失败关掉调度,退回旧的"每天单一固定时间点"行为(逃生阀)----
# 设为 true 后:plan_load 只生成 [今天/明天 UNATTEND_HOUR:00],且不抽签不延迟。
SCHED_FALLBACK="${SCHED_FALLBACK:-false}"

# 解析 HH:MM → 当天 0 点起的分钟数;非法返回空
sched_parse_hhmm() {
    case "$1" in
        [0-9]:*|[0-9][0-9]:*) ;;
        *) return 1 ;;
    esac
    _h=${1%%:*}; _m=${1##*:}
    case "$_h" in ''|*[!0-9]*) return 1 ;; esac
    case "$_m" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_h" -le 23 ] && [ "$_m" -le 59 ] || return 1
    # 10# 前缀:避免 08/09 被当成八进制
    printf '%s\n' $(( 10#$_h * 60 + 10#$_m ))
}

# 分钟数 → HH:MM:SS
sched_fmt_mins() {
    _t=$1
    [ "$_t" -lt 0 ] && _t=0
    _d=$((_t / 1440)); _t=$((_t % 1440))
    printf '%s%02d:%02d:00' "$([ "$_d" -gt 0 ] && printf '+%dd ' "$_d")" $((_t / 60)) $((_t % 60))
}

# 分钟刻度 → epoch: sched_tick_to_epoch <日期YYYYMMDD> <从当天0点起的分钟数>
#   刻度允许 >=1440(锚点 + 延迟越过午夜),此时自动落到次日,不会回绕到当天早上。
#   用 date -d "日期 00:00:00" 拿到当天 0 点(带正确时区/DST),再按分钟相加。
sched_tick_to_epoch() {
    _d="$1"; _tick="$2"
    _base=$(date -d "${_d:0:4}-${_d:4:2}-${_d:6:2} 00:00:00" +%s 2>/dev/null) || return 1
    [ -n "$_base" ] || return 1
    printf '%s\n' $(( _base + _tick * 60 ))
}

# 确定性伪随机:相同 (seed, idx) 永远得到同一个数,区间 [0, mod)
#   用 sha256(str(seed,idx)) 取前 8 个十六进制位。不依赖 $RANDOM(每次调用都不同,
#   无法满足"同一天结果一致"),也不同步外部状态,因此在任何进程里算都一样。
sched_rand() {
    _seed="$1"; _idx="$2"; _mod="$3"
    [ "$_mod" -gt 0 ] 2>/dev/null || { printf '0\n'; return 0; }
    _hex=$(printf '%s' "$SCHED_SEED_SALT|${_seed}|${_idx}" \
           | sha256sum 2>/dev/null | cut -c1-8)
    [ -n "$_hex" ] || { printf '0\n'; return 0; }
    printf '%s\n' $(( 16#$_hex % _mod ))
}

# 校验并规范化配置;非法值给默认并记一条日志(避免用户在菜单里看到怪东西却不知道原因)
sched_validate() {
    _ok=1
    # 锚点列表
    _clean=""
    _cnt=0
    _oldifs=$IFS; IFS=','
    for _s in $SCHED_SLOTS; do
        IFS=$_oldifs
        _s=$(printf '%s' "$_s" | tr -d ' ')
        if [ -n "$_s" ]; then
            if _mm=$(sched_parse_hhmm "$_s"); then
                _clean="${_clean}${_clean:+,}${_s}"
                _cnt=$((_cnt + 1))
            else
                log_msg "!! SCHED_SLOTS 里 \"$_s\" 不是合法的 HH:MM,已忽略"
                _ok=0
            fi
        fi
        IFS=','
    done
    IFS=$_oldifs
    if [ "$_cnt" -eq 0 ]; then
        log_msg "!! SCHED_SLOTS 无有效锚点,回退默认 02:00,10:00,17:00"
        SCHED_SLOTS="02:00,10:00,17:00"; _cnt=3
    else
        SCHED_SLOTS="$_clean"
    fi
    SCHED_SLOT_COUNT=$_cnt

    # 每日抽签数量: 数字 = 固定个数; variable = 在 [1, SCHED_PICK_MAX] 内随机
    if [ "$SCHED_PICK" = "variable" ] || [ "$SCHED_PICK" = "random" ]; then
        SCHED_PICK_MODE=variable
        case "$SCHED_PICK_MAX" in ''|*[!0-9]*) SCHED_PICK_MAX=2; _ok=0 ;; esac
        [ "$SCHED_PICK_MAX" -lt 1 ] && { SCHED_PICK_MAX=1; _ok=0; }
        [ "$SCHED_PICK_MAX" -gt "$SCHED_SLOT_COUNT" ] && SCHED_PICK_MAX=$SCHED_SLOT_COUNT
        [ "$SCHED_PICK_MAX" -lt 1 ] && SCHED_PICK_MAX=1
    else
        SCHED_PICK_MODE=fixed
        case "$SCHED_PICK" in ''|*[!0-9]*) SCHED_PICK=2; _ok=0 ;; esac
        [ "$SCHED_PICK" -lt 1 ] && { SCHED_PICK=1; _ok=0; }
        [ "$SCHED_PICK" -gt "$SCHED_SLOT_COUNT" ] && SCHED_PICK=$SCHED_SLOT_COUNT
    fi

    case "$SCHED_DELAY_MAX" in ''|*[!0-9]*) SCHED_DELAY_MAX=60; _ok=0 ;; esac
    case "$SCHED_MIN_GAP" in ''|*[!0-9]*) SCHED_MIN_GAP=30; _ok=0 ;; esac
    [ "$SCHED_DELAY_MAX" -gt 1440 ] && SCHED_DELAY_MAX=1440
    return 0
}

# 生成某一天的计划(纯函数:只依赖 date 与配置,不读任何外部状态)
#   输出每行格式: <epoch> <分钟刻度> <来源锚点> <延迟分钟>
#   抽取算法:
#     a) 对每个锚点算一个排序键 sched_rand(date, 1000+i),按此键升序取前 N 个
#        → 等价于"无放回随机抽 N 个且与顺序无关",同样的日期组合永远相同;
#     b) 每个锚点叠加 sched_rand(date, i) 的 [0, SCHED_DELAY_MAX] 分钟延迟;
#     c) 按实际时刻排序;若相邻两点间隔 < SCHED_MIN_GAP,把后一个右移(最多 8 轮,
#        推不动就丢弃该点)—— 保证不会出现"刚跑完马上又跑"。
sched_compute_plan() {
    _date="$1"
    _pick=$SCHED_PICK
    if [ "$SCHED_PICK_MODE" = "variable" ]; then
        _pick=$(( $(sched_rand "$_date" 9001 "$SCHED_PICK_MAX") + 1 ))
    fi
    [ "$_pick" -lt 1 ] && _pick=1
    [ "$_pick" -gt "$SCHED_SLOT_COUNT" ] && _pick=$SCHED_SLOT_COUNT

    _i=0
    _cand=""
    _oldifs=$IFS; IFS=','
    for _s in $SCHED_SLOTS; do
        IFS=$_oldifs
        _mm=$(sched_parse_hhmm "$_s") || { IFS=','; _i=$((_i + 1)); continue; }
        _key=$(sched_rand "$_date" $((1000 + _i)) 1000000)
        # 左侧补零到 7 位,保证 sort 按数值字典序正确
        _cand="${_cand}$(printf '%07d' "$_key") ${_mm} ${_s} ${_i}"$'\n'
        _i=$((_i + 1))
        IFS=','
    done
    IFS=$_oldifs

    _chosen=$(printf '%s' "$_cand" | grep -v '^$' | sort | head -n "$_pick")

    _rows=""
    _n=0
    while IFS=' ' read -r _key _mm _src _idx; do
        [ -n "$_mm" ] || continue
        _delay=$(sched_rand "$_date" "$_idx" $((SCHED_DELAY_MAX + 1)))
        _rows="${_rows}$((_mm + _delay)) ${_src} ${_delay}"$'\n'
        _n=$((_n + 1))
    done <<EOF
$_chosen
EOF
    [ "$_n" -gt 0 ] || return 1

    # 排序 + 最小间隔拉平
    _sorted=$(printf '%s' "$_rows" | grep -v '^$' | sort -n)
    _out=""; _prev=""; _round=0
    while [ "$_round" -lt 8 ]; do
        _out=""; _prev=""; _moved=0
        while IFS=' ' read -r _t _src _delay; do
            [ -n "$_t" ] || continue
            if [ -n "$_prev" ] && [ $((_t - _prev)) -lt "$SCHED_MIN_GAP" ]; then
                _t=$((_prev + SCHED_MIN_GAP)); _moved=1
            fi
            _out="${_out}${_t} ${_src} ${_delay}"$'\n'
            _prev=$_t
        done <<EOF
$_sorted
EOF
        _sorted=$(printf '%s' "$_out" | grep -v '^$' | sort -n)
        [ "$_moved" -eq 0 ] && break
        _round=$((_round + 1))
    done

    _prev=""
    while IFS=' ' read -r _t _src _delay; do
        [ -n "$_t" ] || continue
        if [ -n "$_prev" ] && [ $((_t - _prev)) -lt "$SCHED_MIN_GAP" ]; then
            printf '%s\n' "DROP $_src"
            continue
        fi
        printf '%s %s %s\n' "$_t" "$_src" "$_delay"
        _prev=$_t
    done <<EOF
$_sorted
EOF
}

# 载入当天计划落盘文件;校验日期,过期或不完整则重算
#   文件格式(逐行): <date> <slot_index> <epoch> <src> <delay> <status>
#   status: pending=待执行 / done=已执行或已跳过(防重复触发的关键)
plan_load() {
    _today=$(date +%Y%m%d)
    mkdir -p "$SCHED_DIR" 2>/dev/null

    if [ "$SCHED_FALLBACK" = "true" ]; then
        _t=$(date -d "today ${UNATTEND_HOUR}:00" +%s 2>/dev/null) || return 1
        printf '%s 0 %s %s:00 0 pending\n' "$_today" "$_t" "$(printf '%02d:%02d' "$UNATTEND_HOUR" 0)"
        return 0
    fi

    if [ -f "$PLAN_FILE" ]; then
        _fdate=$(head -n1 "$PLAN_FILE" 2>/dev/null | awk '{print $1}')
        _flines=$(grep -c '^[0-9]' "$PLAN_FILE" 2>/dev/null)
        # 日期一致且至少有 1 行 → 直接复用(这就是"同一天内结果保持一致"的来源)
        if [ "$_fdate" = "$_today" ] && [ "${_flines:-0}" -ge 1 ]; then
            grep '^[0-9]' "$PLAN_FILE"
            return 0
        fi
    fi

    # 重算
    sched_compute_plan "$_today" > "$PLAN_FILE.tmp" 2>/dev/null
    if [ ! -s "$PLAN_FILE.tmp" ]; then
        rm -f "$PLAN_FILE.tmp"
        log_msg "!! 当天计划生成失败,退回每天 ${UNATTEND_HOUR}:00 单点模式"
        _t=$(date -d "today ${UNATTEND_HOUR}:00" +%s 2>/dev/null) || return 1
        printf '%s 0 %s %s:00 0 pending\n' "$_today" "$_t" "$(printf '%02d:%02d' "$UNATTEND_HOUR" 0)" > "$PLAN_FILE"
        grep '^[0-9]' "$PLAN_FILE"
        return 0
    fi

    _i=0
    : > "$PLAN_FILE"
    while IFS=' ' read -r _tick _src _delay; do
        case "$_tick" in DROP) 
            log_msg "[计划] 锚点 $_src 因与前一时刻间隔不足 ${SCHED_MIN_GAP} 分钟被丢弃"
            continue ;;
        esac
        case "$_tick" in ''|*[!0-9]*) continue ;; esac
        # 刻度 → epoch(刻度可 >=1440,自动落到次日)
        _ep=$(sched_tick_to_epoch "$_today" "$_tick") || continue
        printf '%s %s %s %s %s pending\n' "$_today" "$_i" "$_ep" "$_src" "$_delay" >> "$PLAN_FILE"
        _i=$((_i + 1))
    done < "$PLAN_FILE.tmp"
    rm -f "$PLAN_FILE.tmp"

    [ "$_i" -gt 0 ] || { log_msg "!! 有效计划为空,退回每天 ${UNATTEND_HOUR}:00"; return 1; }
    grep '^[0-9]' "$PLAN_FILE"
}

# 更新计划里某行的状态: plan_set_status <slot_index> <status>
plan_set_status() {
    _idx="$1"; _st="$2"
    [ -f "$PLAN_FILE" ] || return 0
    _tmp="$PLAN_FILE.tmp"
    awk -v i="$_idx" -v s="$_st" '
        $1 ~ /^[0-9]+$/ { if ($2 == i) $6 = s; print; next }
        { print }
    ' "$PLAN_FILE" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$PLAN_FILE"
    rm -f "$_tmp" 2>/dev/null
}

# 打印当天计划(启动时、跨天重算时调用一次)
plan_print() {
    log_msg "[计划] 当日执行计划(日期=$(date +%F) | 候选=${SCHED_SLOTS} | 抽取=$(
        [ "$SCHED_PICK_MODE" = variable ] && echo "1~${SCHED_PICK_MAX}(随机)" || echo "${SCHED_PICK}(固定)"
    ) | 延迟=0~${SCHED_DELAY_MAX}分钟 | 最小间隔=${SCHED_MIN_GAP}分钟)"
    while IFS=' ' read -r _d _i _t _src _delay _st; do
        [ -n "$_t" ] || continue
        log_msg "         #$((_i + 1)) 锚点${_src} + 延迟${_delay}分钟 → $(date -d "@$_t" '+%F %H:%M:%S') [$_st]"
    done < <(plan_load)
}

# 当日统计的落盘/恢复(进程重启后不丢,避免重复跑或预算误判)
stats_load() {
    _today=$(date +%Y%m%d)
    [ -f "$STATS_FILE" ] || return 0
    _fdate=$(awk '{print $1}' "$STATS_FILE" 2>/dev/null)
    [ "$_fdate" = "$_today" ] || return 0
    _fc=$(awk '{print $2}' "$STATS_FILE" 2>/dev/null)
    _sc=$(awk '{print $3}' "$STATS_FILE" 2>/dev/null)
    _pt=$(awk '{print $4}' "$STATS_FILE" 2>/dev/null)
    _zr=$(awk '{print $5}' "$STATS_FILE" 2>/dev/null)
    _rs=$(awk '{print $6}' "$STATS_FILE" 2>/dev/null)
    case "$_fc" in ''|*[!0-9]*) _fc=0 ;; esac
    case "$_sc" in ''|*[!0-9]*) _sc=0 ;; esac
    case "$_pt" in ''|*[!0-9]*) _pt=0 ;; esac
    case "$_zr" in ''|*[!0-9]*) _zr=0 ;; esac
    case "$_rs" in ''|*[!0-9]*) _rs=0 ;; esac
    FAIL_DAY=$_today;      FAIL_COUNT=$_fc
    DAY_SUCCESS_COUNT=$_sc; DAY_TOTAL_POINTS=$_pt
    ZERO_RERUN_TODAY=$_zr;  DAY_RUN_SECONDS=$_rs
}

stats_save() {
    mkdir -p "$SCHED_DIR" 2>/dev/null
    printf '%s %s %s %s %s %s\n' "$(date +%Y%m%d)" \
        "${FAIL_COUNT:-0}" "${DAY_SUCCESS_COUNT:-0}" "${DAY_TOTAL_POINTS:-0}" \
        "${ZERO_RERUN_TODAY:-0}" "${DAY_RUN_SECONDS:-0}" > "$STATS_FILE" 2>/dev/null
}

# ---- 等待当天计划里的下一个待执行点 ----
#   返回值: 0 = 到点该执行
#   死循环里的每小时 assert_own_lock / maybe_daily_summary 保持原样;
#   滚动到新的一天会自动重算计划并打印(见 plan_load 的日期校验)。
setup_rng() {
    # 占位:调度器用的是确定性伪随机,不需要初始化随机源。
    # 保留该函数是为了让"随机"意图在代码里可搜索,并说明为何不用 $RANDOM。
    return 0
}

wait_until_target() {
    # 选项8:立即执行一轮,不等定时点
    if [ "$IMMEDIATE" = "true" ]; then
        IMMEDIATE=false
        log_msg "[*] 立即执行模式:跳过等待,直接跑一轮"
        return 0
    fi

    setup_rng
    _last_announced_date=""

    while true; do
        # 跨天:plan_load 内部按日期校验,日期变了会重算并覆盖文件
        _plan_now=$(plan_load)
        _today=$(date +%Y%m%d)

        if [ "$_today" != "$_last_announced_date" ]; then
            log_msg ""
            plan_print
            _last_announced_date="$_today"
        fi

        # 找出最早的一个 pending 点
        _next_epoch=""; _next_idx=""; _next_src=""; _next_delay=""
        while IFS=' ' read -r _d _i _t _src _delay _st; do
            [ -n "$_t" ] || continue
            [ "$_st" = "pending" ] || continue
            _next_epoch="$_t"; _next_idx="$_i"; _next_src="$_src"; _next_delay="$_delay"
            break
        done <<EOF
$_plan_now
EOF

        # 今天所有点都处理完了 → 等跨天(每小时醒来一次,让 look over 及时重算)
        if [ -z "$_next_epoch" ]; then
            _now=$(date +%s)
            _tomorrow=$(date -d "tomorrow 00:00" +%s 2>/dev/null || echo "")
            if [ -n "$_tomorrow" ] && [ "$_now" -lt "$_tomorrow" ]; then
                _remain=$((_tomorrow - _now))
                log_msg "守护中... 今日计划已全部完成,${_remain} 秒后进入新一天"
                if [ "$_remain" -gt 3600 ]; then sleep 3600 || continue; else sleep "$_remain" || continue; fi
            else
                sleep 60 || continue
            fi
            continue
        fi

        _now=$(date +%s)
        _remain=$((_next_epoch - _now))

        # 已过点(比如守护刚重启、或系统休眠错过):宽限 10 分钟内照常执行,超时则标记跳过
        if [ "$_remain" -le 0 ]; then
            if [ "$_remain" -ge -600 ]; then
                return 0
            fi
            log_msg "[计划] 点 #$((_next_idx + 1)) ($(date -d "@$_next_epoch" '+%F %H:%M:%S')) 已错过 $((- _remain / 60)) 分钟,标记为跳过"
            plan_set_status "$_next_idx" "missed"
            continue
        fi

        log_msg "下次自动执行: $(date -d "@$_next_epoch" '+%F %H:%M:%S') (锚点${_next_src} + 延迟${_next_delay}分钟, ${_remain}秒后)"

        while true; do
            assert_own_lock
            maybe_daily_summary
            _now=$(date +%s)
            _remain=$((_next_epoch - _now))
            [ "$_remain" -le 0 ] && break
            if [ "$_remain" -gt 3600 ]; then
                # sleep 被打断(如选项5先杀睡眠子进程)绝不能 return 0,
                # 否则"垂死"守护会立刻执行! 改为 continue 重新计算后继续等
                sleep 3600 || continue
                _now=$(date +%s)
                _r=$((_next_epoch - _now))
                [ "$_r" -gt 0 ] && log_msg "守护中... 距下次执行 $((_r / 60)) 分钟"
            else
                sleep "$_remain" || continue
            fi
        done

        # 再次确认:跨天或计划被重算的情况下,这个点仍然有效才返回
        _check=$(plan_load | awk -v i="$_next_idx" '$2 == i {print $6}')
        if [ "$_check" != "pending" ]; then
            log_msg "[计划] 点 #$((_next_idx + 1)) 状态已变为 ${_check:-未知},不再触发"
            continue
        fi
        return 0
    done
}

# =============================================================================
#  基础步骤(选项1 与 无人值守 共用)
# =============================================================================
step_clean_core() {
    log_msg "[*] 清理残留 core dump ..."
    find "$BASE" -maxdepth 2 -type f \( -name 'core' -o -name 'core.*' \) -size +5M -print -delete 2>/dev/null
    log_msg "    可用空间: $(df -h / | tail -1 | awk '{print $4}')"
}

# 检查执行器(裸金属版 run_daily.sh)是否存在
step_prepare_runner() {
    if [ ! -f "$RUNNER" ]; then
        log_msg "    !! 缺少执行器 $RUNNER"
        if [ -f "$BASE/scripts/docker/run_daily.sh" ]; then
            log_msg "    提示: 可基于 $BASE/scripts/docker/run_daily.sh 生成裸金属版"
        fi
        return 1
    fi
    [ -x "$RUNNER" ] || chmod +x "$RUNNER" 2>/dev/null
    if [ ! -f "$BASE/.env" ]; then
        log_msg "    !! 缺少 $BASE/.env(账号配置)"; return 1
    fi
    return 0
}

# 单次运行：输出全部走 stdout/stderr，由调用方重定向
run_once() {
    if [ "$MAX_RUN_SECONDS" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        timeout -k 60 "$MAX_RUN_SECONDS" bash "$RUNNER"
    else
        bash "$RUNNER"
    fi
}

# =============================================================================
#  选项 1:启动
# =============================================================================
do_start() {
    echo ""
    step_clean_core
    step_prepare_runner || return 1
    echo "[*] 前台运行（日志同时写入 $LOG_DIR/run-$(date +%Y%m%d).log）"
    echo "---------------------------------------------------------------------------"
    run_once 2>&1 | tee -a "$LOG_DIR/run-$(date +%Y%m%d).log"
    _rc=${PIPESTATUS[0]}
    echo "---------------------------------------------------------------------------"
    echo "退出码: $_rc"
    return "$_rc"
}

# =============================================================================
#  选项 2:清理缓存
# =============================================================================
do_clean() {
    echo ""
    echo "清理前可用空间: $(df -h / | tail -1 | awk '{print $4}')"

    echo "[1/4] 删除 core dump"
    find "$BASE" -maxdepth 3 -type f \( -name 'core' -o -name 'core.*' \) -size +1M -print -delete 2>/dev/null
    echo "      已检查/删除"

    echo "[2/4] 清理 npm 缓存"
    if command -v npm >/dev/null 2>&1; then
        npm cache clean --force >/dev/null 2>&1 && echo "      npm 缓存已清" || echo "      (npm 缓存清理失败,跳过)"
    fi

    echo "[3/4] 清理宿主 apt 缓存与 journal"
    apt-get clean >/dev/null 2>&1 && echo "      apt 缓存已清" || echo "      (apt clean 失败,跳过)"
    journalctl --vacuum-size=2M >/dev/null 2>&1 && echo "      journal 已回收" || echo "      (journal 回收失败,跳过)"

    echo "[4/4] 清理 3 天前的 MRS 运行日志"
    find "$LOG_DIR" -type f \( -name 'run-*.log' -o -name 'unattended-*.log' \) -mtime +3 -delete 2>/dev/null
    echo "      已清理"

    echo ""
    echo "清理后可用空间: $(df -h / | tail -1 | awk '{print $4}')"
}

# =============================================================================
#  选项 3:备份 / 恢复凭证
# =============================================================================
do_backup() {
    echo ""
    if [ ! -d "$SESSIONS" ]; then
        echo "!! 源目录 $SESSIONS 不存在"; return 1
    fi
    echo "备份: $SESSIONS"
    echo "  →   $BACKUP"
    echo "     (将覆盖之前的备份)"
    rm -rf "$BACKUP"
    mkdir -p "$BACKUP"
    cp -a "$SESSIONS"/. "$BACKUP"/ 2>/dev/null
    echo ""
    echo "备份完成!"
    echo "--- 备份内容 ---"
    ls -la "$BACKUP"
    echo "备份大小: $(du -sh "$BACKUP" 2>/dev/null | awk '{print $1}')"
}

do_restore() {
    echo ""
    if [ ! -d "$BACKUP" ] || [ -z "$(ls -A "$BACKUP" 2>/dev/null)" ]; then
        echo "!! 备份目录为空或不存在,无法恢复"; return 1
    fi
    echo "即将用备份覆盖当前 sessions:"
    echo "   备份来源: $BACKUP"
    echo "   覆盖目标: $SESSIONS"
    echo "   (建议在任务未运行时执行)"
    printf "确认执行? [y/N] "
    read -r ans
    case "$ans" in
        y|Y) ;;
        *) echo "已取消"; return 0 ;;
    esac
    rm -rf "$SESSIONS"
    mkdir -p "$SESSIONS"
    cp -a "$BACKUP"/. "$SESSIONS"/ 2>/dev/null
    echo ""
    echo "恢复完成!"
    ls -la "$SESSIONS"
}

menu_backup() {
    while true; do
        echo ""
        echo "================ 备份 / 恢复凭证 ================"
        echo "  sessions 目录 : $SESSIONS"
        echo "  备份目录      : $BACKUP"
        echo "  sessions 大小 : $(du -sh "$SESSIONS" 2>/dev/null | awk '{print $1}')"
        echo "  备份  大小    : $(du -sh "$BACKUP" 2>/dev/null | awk '{print $1}')"
        echo "------------------------------------------------"
        echo "  1) 备份(sessions → sessions_backup,覆盖旧备份)"
        echo "  2) 恢复(sessions_backup → sessions)"
        echo "  0) 返回主菜单"
        echo "================================================"
        printf "请输入选项 [0-2]: "
        read -r c || return 0
        case "$c" in
            1) do_backup ;;
            2) do_restore ;;
            0|"") return 0 ;;
            *) echo "无效选项: $c" ;;
        esac
    done
}

# =============================================================================
#  选项 4:无人值守 (v4)
# =============================================================================

# ---- 执行一次并摘录日志 ----
#  返回值: 0=失败  1=日志流结束且无标记  2=本轮运行成功完成
watch_logs() {
    rm -f "$WATCH_FLAG" "$WATCH_DONE_FLAG" "$LOG_FIFO" "$RUNEND_FILE"
    mkfifo "$LOG_FIFO" 2>/dev/null || { log_msg "!! mkfifo 失败"; sleep 10; return 1; }

    # 按天归档:一次 watch 内写同一份文件(跨零点时归入起始日)
    _logfile="$LOG_DIR/unattended-$(date +%Y%m%d).log"
    _runlog="$LOG_DIR/run-$(date +%Y%m%d).log"
    mkdir -p "$LOG_DIR" 2>/dev/null

    run_once > "$LOG_FIFO" 2>&1 &
    _dpid=$!

    # 读到 EOF 为止(不提前 break:run_daily.sh 打完标记后几秒就退出,
    # 提前 break 会留下孤儿进程)
    while IFS= read -r line; do
        printf '%s\n' "$line" >> "$_runlog" 2>/dev/null
        case "$line" in
            *"[INFO]"*|*"[WARN]"*|*"[run_daily.sh]"*)
                printf '%s\n' "$line"
                printf '%s\n' "$line" >> "$_logfile" 2>/dev/null
                ;;
        esac
        case "$line" in
            *"[RUN-END]"*) printf '%s\n' "$line" > "$RUNEND_FILE" 2>/dev/null ;;
        esac
        case "$line" in
            *"Script failed"*)
                printf '\n>>>>>>>>>> 检测到脚本失败 <<<<<<<<<<\n' >&2
                : > "$WATCH_FLAG"
                ;;
            *"Script completed successfully"*)
                printf '\n>>>>>>>>>> 本轮运行完成 <<<<<<<<<<\n' >&2
                : > "$WATCH_DONE_FLAG"
                ;;
        esac
    done < "$LOG_FIFO"

    wait "$_dpid" 2>/dev/null; _rc=$?
    rm -f "$LOG_FIFO"

    [ "$_rc" -eq 124 ] && log_msg "!! 单轮运行超过 ${MAX_RUN_SECONDS}s 被强杀(timeout)"
    # 既没成功标记也没失败标记,但退出码非 0 → 按失败处理
    if [ ! -f "$WATCH_FLAG" ] && [ ! -f "$WATCH_DONE_FLAG" ] && [ "$_rc" -ne 0 ]; then
        log_msg "!! 进程退出码 $_rc 且未见成功/失败标记 → 按失败处理"
        : > "$WATCH_FLAG"
    fi

    if [ -f "$WATCH_FLAG" ]; then return 0; fi
    if [ -f "$WATCH_DONE_FLAG" ]; then return 2; fi
    return 1
}

# ---- 停用 systemd 定时器,消除双调度 ----
ensure_no_systemd_timer() {
    if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled mrs.timer >/dev/null 2>&1; then
        systemctl disable --now mrs.timer >/dev/null 2>&1
        log_msg "[*] 已停用 mrs.timer,避免与 start.sh 的随机调度双跑"
    fi
}

# ---- 一句话描述当前调度策略(用于横幅/菜单)----
sched_describe() {
    if [ "$SCHED_FALLBACK" = "true" ]; then
        printf '每天 %s:00(固定单点,回退模式)' "$(printf '%02d' "$UNATTEND_HOUR")"
        return 0
    fi
    _picktxt=$([ "${SCHED_PICK_MODE:-fixed}" = variable ] \
        && printf '随机 1~%s 个' "$SCHED_PICK_MAX" || printf '%s 个' "$SCHED_PICK")
    printf '每天从 [%s] 中随机取 %s | 每点再延迟 0~%s 分钟' \
        "$SCHED_SLOTS" "$_picktxt" "$SCHED_DELAY_MAX"
}

# ---- 安装断电保活 crontab(@reboot + 每10分钟检查,幂等)----
# 标记串统一用 CRON_TAG:所有本脚本管理的条目都带该注释,便于识别/去重/卸载。
# 注意:历史版本用 'start_unattended.sh 4' 当标记,与实际写入的 'bash $SELF 4' 不匹配,
#       导致每次启动都追加一组 → crontab 无限膨胀。此处一并清理旧格式残留。
CRON_TAG="# MRS unattended guard (managed by start.sh 4)"

# 从 stdin 读取 crontab 内容,过滤掉所有本脚本管理的条目(含历史格式),输出到 stdout
_cron_strip_mrs() {
    grep -v -e 'MRS unattended guard' \
            -e 'start_unattended\.sh 4' \
            -e "bash $SELF 4" \
            -e "bash /root/start\.sh 4" 2>/dev/null
}

ensure_supervisor() {
    [ "$ENABLE_SUPERVISOR" = "true" ] || return 0
    if ! command -v crontab >/dev/null 2>&1; then
        log_msg "!! 宿主未安装 cron,断电保活无法安装(可执行: apt install -y cron && systemctl enable --now cron)"
        return 1
    fi
    systemctl enable --now cron >/dev/null 2>&1

    _existing=$(crontab -l 2>/dev/null)
    # 先判断是否已有一组完好的保活条目(用实际写入的命令匹配,而非历史标记)
    _has_reboot=$(printf '%s\n' "$_existing" | grep -c "^@reboot sleep 30 && bash $SELF 4 ")
    _has_tick=$(printf '%s\n' "$_existing" | grep -c "^\*/10 \* \* \* \* bash $SELF 4 ")

    if [ "${CRON_FORCE_REWRITE:-false}" != "true" ] && [ "$_has_reboot" -eq 1 ] && [ "$_has_tick" -eq 1 ]; then
        _cnt=$(printf '%s\n' "$_existing" | grep -c "bash $SELF 4 2>&1\|bash $SELF 4 >")
        log_msg "[*] 无人值守保活 crontab 已存在(共 $_cnt 条相关条目)"
        return 0
    fi

    # 幂等重写:先剥离所有历史/重复条目,再写入唯一一组
    {
        printf '%s\n' "$_existing" | _cron_strip_mrs
        echo "$CRON_TAG"
        echo "@reboot sleep 30 && bash $SELF 4 >/dev/null 2>&1"
        echo "*/10 * * * * bash $SELF 4 >/dev/null 2>&1"
    } | sed '/^[[:space:]]*$/d' | crontab - 2>/dev/null

    _now=$(crontab -l 2>/dev/null | grep -c "bash $SELF 4 >")
    log_msg "[*] 已安装无人值守保活 crontab(@reboot + 每10分钟自检,当前 $_now 条)"
    log_msg "    设备断电重启后,无人值守会在 30 秒后自动恢复"
}

# ---- 跨天重置当日统计(成功/失败/积分/假成功预算/时长预算)----
rollover_day_if_needed() {
    _today=$(date +%Y%m%d)
    [ "$_today" = "$DAY" ] && return 0
    DAY=$_today
    FAIL_DAY=$_today
    FAIL_COUNT=0
    ZERO_RERUN_TODAY=0
    DAY_SUCCESS_COUNT=0
    DAY_TOTAL_POINTS=0
    DAY_RUN_SECONDS=0
}

# ---- 组装当日汇总文本(成功情况/失败次数/获得总积分)----
daily_summary_body() {
    _sc=${DAY_SUCCESS_COUNT:-0}; _fc=${FAIL_COUNT:-0}; _pt=${DAY_TOTAL_POINTS:-0}
    if [ "$_sc" -gt 0 ]; then
        _st="今日已成功 $_sc 次"
    elif [ "$_fc" -gt 0 ]; then
        _st="今日未成功(已失败 $_fc 次,仍在自动重试)"
    else
        _st="今日暂无任务执行记录"
    fi
    printf '日期: %s\n----------------\n运行状态: %s\n成功次数: %s\n失败次数: %s\n获得积分: %s\n----------------' \
        "$(date '+%F %A')" "$_st" "$_sc" "$_fc" "$_pt"
}

# ---- 守护内:推送当日汇总(记录日志 + 异步推送,自动附带 IPv6)----
send_daily_summary() {
    log_msg "[*] 推送今日汇总(成功${DAY_SUCCESS_COUNT:-0} 失败${FAIL_COUNT:-0} 积分${DAY_TOTAL_POINTS:-0})"
    push_msg "MRS无人值守-每日汇总" "$(daily_summary_body)"
}

# ---- 每天 23:00 窗口检查,当天只推一次 ----
maybe_daily_summary() {
    [ "$(date +%H)" = "$SUMMARY_HOUR" ] || return 0
    _today=$(date +%Y%m%d)
    _done=$(cat "$SUMMARY_FLAG" 2>/dev/null || echo "")
    [ "$_done" = "$_today" ] && return 0
    echo "$_today" > "$SUMMARY_FLAG"
    send_daily_summary
}

# ---- 锁归属自检:锁文件已被其它实例接管(如锁被删后 cron 重建)时让位 ----
assert_own_lock() {
    _owner=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    if [ "$_owner" != "$$" ]; then
        log_msg "[*] 检测到锁已由其它实例接管(PID ${_owner:-?}),本实例让位退出"
        exit 0
    fi
}

# ---- 监控一轮执行:失败自动重试,成功/放弃后返回 ----
# 被 do_unattended(守护循环)与 do_run_now(选项8 手动立即跑)共用。
# 依赖调用方已初始化:ATTEMPT / ZERO_RERUN_TODAY / FAIL_COUNT / DAY_* 等全局量。
monitor_round() {
    while true; do
        _t0=$(date +%s)
        watch_logs
        _rc=$?
        DAY_RUN_SECONDS=$((DAY_RUN_SECONDS + $(date +%s) - _t0))
        stats_save              # 累计时长/积分落盘,进程重启后不丢

        if [ "$_rc" -eq 0 ]; then
            # ===== 失败 =====
            rollover_day_if_needed
            FAIL_COUNT=$((FAIL_COUNT + 1))
            stats_save
            log_msg "今日第 ${FAIL_COUNT} 次失败"
            push_msg "MRS无人值守-失败" "今日第 ${FAIL_COUNT} 次失败 $(date '+%F %T')"

            ATTEMPT=$((ATTEMPT + 1))
            if [ "$ATTEMPT" -gt "$MAX_ATTEMPTS" ]; then
                log_msg "已连续失败 ${MAX_ATTEMPTS} 次,放弃本轮"
                push_msg "MRS无人值守-放弃本轮" "连续失败 ${MAX_ATTEMPTS} 次,本轮放弃"
                return 0
            fi
            _d=$((ATTEMPT * 60)); [ "$_d" -gt 300 ] && _d=300
            log_msg "第 ${ATTEMPT} 次失败,${_d}s 后重试..."
            sleep "$_d"

        elif [ "$_rc" -eq 2 ]; then
            # ===== 本轮运行成功完成 =====
            rollover_day_if_needed
            last_runend_fields
            _pt=${_got:-0}
            case "$_pt" in ''|*[!0-9]*) _pt=0 ;; esac
            DAY_SUCCESS_COUNT=$((DAY_SUCCESS_COUNT + 1))
            DAY_TOTAL_POINTS=$((DAY_TOTAL_POINTS + _pt))
            stats_save
            log_msg "本轮运行完成: 获得积分=$_pt | 原余额=${_before:-?} | 今日累计: 成功 ${DAY_SUCCESS_COUNT} 次 / 积分 ${DAY_TOTAL_POINTS}"

            # ---- 假成功检测:0积分且余额读取异常 → 重跑(不算失败)----
            if [ "${_got:-0}" = "0" ] && [ "${_before:-0}" = "0" ] && \
               [ "$ZERO_RERUN_TODAY" -lt "$ZERO_POINT_RERUNS" ]; then
                ZERO_RERUN_TODAY=$((ZERO_RERUN_TODAY + 1))
                stats_save
                log_msg "疑似假成功(0积分/余额读取异常) → 第 ${ZERO_RERUN_TODAY} 次重跑"
                push_msg "MRS无人值守-假成功重跑" "本轮 0 积分且余额异常,自动重跑第 ${ZERO_RERUN_TODAY} 次"
                sleep 120
                continue
            fi
            log_msg "本轮运行成功"
            push_msg "MRS无人值守-完成" "本轮成功: 获得积分=$_pt 原余额=${_before:-?} | 当日: 成功 ${DAY_SUCCESS_COUNT} 次 失败 ${FAIL_COUNT} 次 积分 ${DAY_TOTAL_POINTS}"
            ATTEMPT=0
            maybe_daily_summary      # 长任务可能错过 23:00,每轮结束补推一次
            return 0

        else
            # ===== 日志流结束但既无成功也无失败标记 =====
            if is_mrs_running; then
                log_msg "日志流中断但进程仍在,3s 后重新跟随"
                sleep 3
            else
                log_msg "进程已结束但状态不明"
                push_msg "MRS无人值守-状态不明" "本轮既无成功也无失败标记,已结束"
                return 0
            fi
        fi
    done
}

do_unattended() {
    # 单轮模式(选项8):跑完一轮就退出,不转常驻守护
    RUN_ONCE="${IMMEDIATE:-false}"
    # ---- 单实例锁(保活 cron 每10分钟都会来,重复则退出)----
    # 用追加模式打开,避免并发实例每次打开时截断文件(破坏 PID 记录)
    exec 9>>"$LOCKFILE"
    if command -v flock >/dev/null 2>&1; then
        flock -n 9 || { echo "[*] 已有无人值守实例在运行,本实例退出"; exit 0; }
    else
        if [ -f "$LOCKFILE" ]; then
            _old=$(cat "$LOCKFILE" 2>/dev/null)
            if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
                echo "[*] 已有无人值守实例在运行(PID $_old),本实例退出"; exit 0
            fi
            rm -f "$LOCKFILE"
        fi
    fi
    echo $$ > "$LOCKFILE"
    # 注意:INT/TERM 处理里必须 exit,否则 trap 不会自动退出,
    # 守护会删掉锁后继续运行 → 锁保护失效,且 kill 杀不死守护
    # 删除锁文件前校验归属:避免"已失守的旧实例"删掉"新实例"刚建好的锁
    trap '_owner=$(cat "$LOCKFILE" 2>/dev/null || echo ""); [ "$_owner" = "$$" ] && rm -f "$LOCKFILE"; exit 0' EXIT INT TERM

    echo ""
    echo "==================== 无人值守模式 (v5 · RK3229裸金属) ===================="
    echo "  工作目录     : $BASE"
    echo "  执行器       : $RUNNER"
    echo "  随机调度     : $(sched_describe)"
    echo "  最小间隔     : 两个执行点至少相隔 ${SCHED_MIN_GAP} 分钟"
    echo "  日志         : 全量 $LOG_DIR/run-YYYYMMDD.log"
    echo "  失败自愈     : 检测到 'Script failed' 自动重跑"
    echo "                 每天最多 ${MAX_ATTEMPTS} 次,退避 60s→300s"
    echo "  假成功检测   : 0积分且原余额=0(余额读取异常)自动重跑(每天最多 ${ZERO_POINT_RERUNS} 次)"
    echo "  时长控制     : 单轮硬超时 $((MAX_RUN_SECONDS/3600))h | 当天累计预算 $((DAY_BUDGET_SECONDS/3600))h"
    echo "  断电保活     : crontab @reboot + 每10分钟自检(flock 单实例)"
    echo "  计划持久化   : $PLAN_FILE (按日期校验,重启后恢复,避免重复触发)"
    echo "  并发保护     : 上一轮未结束时本次跳过 | 手动运行(选项1)不受影响"
    echo "  推送通知     : 失败/放弃/完成/每日${SUMMARY_HOUR}:00汇总 → PushPlus(含公网IPv6)"
    echo "  停止方式     : Ctrl+C 或 另开终端 bash $SELF 5"
    echo "=========================================================================="
    echo ""

    # 依赖与环境准备
    ensure_no_systemd_timer
    ensure_supervisor
    step_prepare_runner || return 1

    # 校验调度配置(非法值给默认并提示),并预生成当天计划
    sched_validate
    mkdir -p "$SCHED_DIR" 2>/dev/null

    ATTEMPT=0
    # 初始化为今天:让 FAIL_DAY 的"新一天"重置块只在真正跨天时触发,
    # 避免当天第一次失败把 ZERO_RERUN_TODAY(假成功重跑预算)误清零
    DAY=$(date +%Y%m%d)
    FAIL_DAY=$DAY
    FAIL_COUNT=0
    ZERO_RERUN_TODAY=0
    DAY_SUCCESS_COUNT=0     # 今日成功次数(23:00 汇总用)
    DAY_TOTAL_POINTS=0      # 今日获得总积分(23:00 汇总用)
    DAY_RUN_SECONDS=0       # 今日累计运行时长(预算用)
    stats_load              # 若本轮是重启/断电后拉起,恢复当日已完成的统计

    while true; do
        prune_logs
        wait_until_target || return 0

        assert_own_lock
        rollover_day_if_needed
        stats_load              # 同日则恢复统计(进程重启/跨天自动处理)

        # ---- 认领触发点(原子操作,彻底杜绝同一时刻被重复触发)----
        #   plan_load 在计划过期时会重算并**保留**已 done/missed 的行,
        #   所以这里在"刚醒来的那一刻"仍未完成的,就是本次要执行的点。
        _slot_idx=""; _slot_epoch=""; _slot_src=""; _slot_delay=""
        while IFS=' ' read -r _d _i _t _src _delay _st; do
            [ -n "$_t" ] || continue
            [ "$_st" = "pending" ] || continue
            _slot_idx="$_i"; _slot_epoch="$_t"; _slot_src="$_src"; _slot_delay="$_delay"
            break
        done < <(plan_load)

        if [ -z "$_slot_idx" ]; then
            log_msg "[计划] 醒来时已无待执行点(可能已被其它实例认领),返回等待"
            continue
        fi

        # 先标记再执行:即使中途被 kill,crontab 重新拉起的守护也不会重复跑这个点
        plan_set_status "$_slot_idx" "done"

        log_msg ""
        log_msg "===== 到达计划执行点 #$((_slot_idx + 1)) ====="
        log_msg "[计划] 计划时刻=$(date -d "@$_slot_epoch" '+%F %H:%M:%S') | 锚点=$_slot_src | 随机延迟=${_slot_delay}分钟"
        log_msg "[计划] 实际触发时刻=$(date '+%F %H:%M:%S') | 与计划偏差=$(( $(date +%s) - _slot_epoch ))秒"

        # ---- 防并发:上一轮还在跑就跳过(手动运行 option1 也可能正在跑)----
        if is_mrs_running; then
            log_msg "上一轮仍在运行(pid $(pgrep -f 'dist/index\.js' | tr '\n' ' ')),跳过本次触发"
            sleep 300
            continue
        fi

        # ---- 当日运行预算 ----
        if [ "$DAY_BUDGET_SECONDS" -gt 0 ] && [ "$DAY_RUN_SECONDS" -ge "$DAY_BUDGET_SECONDS" ]; then
            log_msg "当日运行预算已用尽(${DAY_RUN_SECONDS}s / ${DAY_BUDGET_SECONDS}s),跳过本次,等待下一个计划点"
            push_msg "MRS无人值守-预算用尽" "当日累计运行 ${DAY_RUN_SECONDS}s 已达预算,跳过本次"
            continue
        fi

        step_clean_core
        ATTEMPT=0
        ZERO_RERUN_TODAY=0

        # ---- 监控本轮,失败自动重启;成功则回到等待 ----
        monitor_round

        # 单轮模式:一轮跑完即退出,不进入下一轮等待
        if [ "$RUN_ONCE" = "true" ]; then
            log_msg "===== 单轮模式:执行完毕,退出 ====="
            return 0
        fi
    done
}

# ---- 选项8:立即跑一轮(不取守护锁,与常驻守护并存)----
# 关键设计:
#   * 常驻守护(选项4)持有 /tmp/mrs_unattended.lock。若这里也去抢同一把锁,
#     守护在场时必然失败并误报"已有实例在运行" —— 这正是要修的问题。
#     所以本函数**不取守护锁**,改为用 is_mrs_running 判断"是否真有一轮任务在跑"。
#   * 不读/不写计划文件,不消耗当日计划点(手动补跑是额外的,不顶替计划)。
#   * 与手动运行(选项1)共享 run_daily.sh 自己的 /tmp/run_daily.lock,天然互斥。
do_run_now() {
    echo ""
    echo "==================== 立即执行一轮 (单轮·不占计划点) ===================="
    echo "  工作目录     : $BASE"
    echo "  执行器       : $RUNNER"
    echo "  说明         : 常驻守护可同时在跑;本模式不消耗当日计划点"
    echo "=========================================================================="
    echo ""

    # 依赖与环境准备(与守护一致的准备步骤)
    ensure_no_systemd_timer
    ensure_supervisor
    step_prepare_runner || return 1

    ATTEMPT=0
    DAY=$(date +%Y%m%d)
    FAIL_DAY=$DAY
    FAIL_COUNT=0
    ZERO_RERUN_TODAY=0
    DAY_SUCCESS_COUNT=0
    DAY_TOTAL_POINTS=0
    DAY_RUN_SECONDS=0
    stats_load                  # 续用当日已有统计,不重置

    # 真并发判断:已有一轮 MRS 在跑就不重复启动(这才是真正的"冲突")
    if is_mrs_running; then
        _pids=$(pgrep -f 'dist/index\.js' | tr '\n' ' ')
        echo "  [*] 已有一轮 MRS 正在运行(pid ${_pids% }),本次跳过"
        log_msg "[*] 选项8:检测到已有 MRS 在运行(pid ${_pids% }),跳过本次立即执行"
        return 0
    fi

    prune_logs
    rollover_day_if_needed
    step_clean_core

    log_msg ""
    log_msg "===== 手动立即执行一轮(选项8,不占用计划点) ====="
    log_msg "[计划] 实际触发时刻=$(date '+%F %H:%M:%S') | 触发方式=手动选项8"

    monitor_round
    log_msg "===== 选项8:单轮执行结束 ====="
    return 0
}

# =============================================================================
#  选项 5:关闭无人值守守护
# =============================================================================
do_unattended_off() {
    echo ""
    echo "关闭无人值守守护:"
    if command -v crontab >/dev/null 2>&1; then
        _n=$(crontab -l 2>/dev/null | grep -c "bash $SELF 4 >")
        if [ "$_n" -gt 0 ]; then
            crontab -l 2>/dev/null | _cron_strip_mrs | sed '/^[[:space:]]*$/d' | crontab - 2>/dev/null
            echo "  [*] 已移除保活 crontab(共 $_n 条 @reboot / 每10分钟自检)"
        else
            echo "  [-] 保活 crontab 不存在"
        fi
    fi
    if [ -f "$LOCKFILE" ]; then
        _p=$(cat "$LOCKFILE" 2>/dev/null)
        if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then
            # bash 阻塞在 sleep/等待子进程时会推迟处理 TERM → 先杀其子进程
            _children=$(cat "/proc/$_p/task/$_p/children" 2>/dev/null)
            [ -z "$_children" ] && _children=$(pgrep -P "$_p" 2>/dev/null | tr '\n' ' ')
            if [ -n "$_children" ]; then
                kill $_children 2>/dev/null
                sleep 1
            fi
            kill "$_p" 2>/dev/null && echo "  [*] 已结束无人值守进程(PID $_p)"
            # 兜底:阻塞在 sleep 时 TERM 会被推迟,再等 2 秒仍活着则强杀
            sleep 2
            if kill -0 "$_p" 2>/dev/null; then
                kill -9 "$_p" 2>/dev/null
                echo "  [*] 守护未在 2 秒内退出,已强制结束(PID $_p)"
            fi
        fi
        rm -f "$LOCKFILE"
    else
        echo "  [-] 无人值守进程未在运行"
    fi
    # 收尾:清理可能残留的 MRS 与浏览器进程
    # 注意:绝不能用 pkill -f,它会匹配到自己的命令行把 SSH 会话干掉(exit 255)
    _mrs=$(pgrep -f 'dist/index\.js' 2>/dev/null | tr '\n' ' ')
    if [ -n "$_mrs" ]; then
        kill $_mrs 2>/dev/null && echo "  [*] 已结束 MRS 进程($_mrs)"
        sleep 2
    fi
    pkill -x chromium 2>/dev/null
    pkill -x chrome 2>/dev/null
    pkill -x headless_shell 2>/dev/null
    echo "  完成。"
}

# =============================================================================
#  选项 6:手动推送公网 IPv6
# =============================================================================
do_push_ipv6() {
    echo ""
    echo "===== 手动推送公网 IPv6 ====="
    echo "[1/2] 获取设备公网 IPv6(动态)..."
    _v6=$(get_public_ipv6 2>/dev/null)
    if [ -n "$_v6" ]; then
        echo "      当前公网 IPv6: $_v6"
    else
        echo "      !! 未能获取公网 IPv6(无 IPv6 或回显服务不可达)"
        printf "      仍发送推送? [y/N] "
        read -r _ans
        case "$_ans" in
            y|Y) ;;
            *) echo "已取消"; return 0 ;;
        esac
    fi
    echo "[2/2] 通过 PushPlus 推送..."
    push_msg_sync "MRS-公网IPv6" "设备公网 IPv6(动态,可能变化)"
    echo "      (上方为 PushPlus 响应;code:200 即送达)"
}

# =============================================================================
#  选项 7:手动推送当日汇总
# =============================================================================
do_daily_summary() {
    echo ""
    echo "===== 手动推送今日汇总 ====="
    echo "  内容预览:"
    daily_summary_body | sed 's/^/    /'
    echo ""
    printf "确认推送? [y/N] "
    read -r _ans
    case "$_ans" in
        y|Y) ;;
        *) echo "已取消"; return 0 ;;
    esac
    echo "  正在通过 PushPlus 推送..."
    push_msg_sync "MRS无人值守-每日汇总(手动)" "$(daily_summary_body)"
    echo "      (上方为 PushPlus 响应;code:200 即送达)"
}

# =============================================================================
#  选项 10:查看当日执行计划
# =============================================================================
do_show_plan() {
    sched_validate
    echo ""
    echo "================ 当日执行计划 ================"
    echo "  调度策略 : $(sched_describe)"
    echo "  最小间隔 : ${SCHED_MIN_GAP} 分钟"
    echo "  计划文件 : $PLAN_FILE"
    echo "  统计文件 : $STATS_FILE"
    echo "----------------------------------------------"

    _today=$(date +%Y%m%d)
    _fdate=$(head -n1 "$PLAN_FILE" 2>/dev/null | awk '{print $1}')
    if [ "$_fdate" != "$_today" ]; then
        echo "  (今日尚无计划,下次无人值守启动/跨天时自动生成)"
        echo "  —— 下面是按当前配置预演的结果 ——"
        echo ""
    fi

    _now=$(date +%s)
    printf '  %-4s %-9s %-6s %-8s %-9s %s\n' "序号" "计划时刻" "锚点" "延迟" "状态" "相对现在"
    echo "  ------------------------------------------------------------------"
    _any=0
    while IFS=' ' read -r _d _i _t _src _delay _st; do
        [ -n "$_t" ] || continue
        _any=1
        _rel=$((_t - _now))
        if [ "$_rel" -gt 0 ]; then
            _reltxt="还有 $((_rel / 60)) 分"
        else
            _reltxt="已过 $((- _rel / 60)) 分"
        fi
        case "$_st" in
            pending) _sttxt="待执行" ;;
            done)    _sttxt="已执行" ;;
            missed)  _sttxt="已跳过" ;;
            *)       _sttxt="$_st" ;;
        esac
        printf '  #%-3s %-9s %-6s %-8s %-9s %s\n' \
            "$((_i + 1))" "$(date -d "@$_t" '+%H:%M:%S')" "$_src" "${_delay}分" "$_sttxt" "$_reltxt"
    done < <(plan_load)
    [ "$_any" -eq 1 ] || echo "  (今日已无待执行点)"

    echo "----------------------------------------------"
    if [ -f "$STATS_FILE" ]; then
        _fdate=$(awk '{print $1}' "$STATS_FILE" 2>/dev/null)
        if [ "$_fdate" = "$_today" ]; then
            echo "  今日统计 : 成功 $(awk '{print $3}' "$STATS_FILE") 次 | 失败 $(awk '{print $2}' "$STATS_FILE") 次 | 积分 $(awk '{print $4}' "$STATS_FILE") | 累计运行 $(( $(awk '{print $6}' "$STATS_FILE") / 60 )) 分钟"
        fi
    fi
    echo ""
    echo "  配置来源(环境变量可覆盖):"
    echo "    SCHED_SLOTS=${SCHED_SLOTS}     候选锚点"
    echo "    SCHED_PICK=${SCHED_PICK}      每日抽取数量(fixed 数字 / variable)"
    echo "    SCHED_PICK_MAX=${SCHED_PICK_MAX}    variable 模式下的随机上限"
    echo "    SCHED_DELAY_MAX=${SCHED_DELAY_MAX} 每点随机延迟上限(分钟)"
    echo "    SCHED_MIN_GAP=${SCHED_MIN_GAP}     两执行点最小间隔(分钟)"
    echo "    SCHED_FALLBACK=${SCHED_FALLBACK}    true=退回每天单点固定模式"
    echo "=============================================="
}

# =============================================================================
#  实时日志(选项 9 / 参数 log)
#
#  每天两份日志,都在 $LOG_DIR 下:
#    run-YYYYMMDD.log        MRS 全量输出(登录流程、搜索、积分…) ← 看任务进展看这个
#    unattended-YYYYMMDD.log 守护进程自身的决策(到达定时点、重试、假成功、推送)
# =============================================================================
do_follow_logs() {
    _n="${1:-60}"
    case "$_n" in ''|*[!0-9]*) _n=60 ;; esac
    _today=$(date +%Y%m%d)
    _runlog="$LOG_DIR/run-$_today.log"
    _daemonlog="$LOG_DIR/unattended-$_today.log"
    mkdir -p "$LOG_DIR" 2>/dev/null
    [ -f "$_runlog" ] || : > "$_runlog"
    [ -f "$_daemonlog" ] || : > "$_daemonlog"

    echo ""
    echo "===== 实时日志 (Ctrl+C 退出查看,不影响后台运行) ====="
    echo "  全量任务输出: $_runlog"
    echo "  守护决策日志: $_daemonlog"
    echo "------------------------------------------------------------"
    if is_mrs_running; then
        echo "  状态: MRS 正在运行 (pid $(pgrep -f 'dist/index\.js' | tr '\n' ' '))"
    else
        echo "  状态: 当前无任务在跑(下方为历史日志;新输出会实时追加)"
    fi
    echo "============================================================"
    trap ':' INT
    tail -n "$_n" -f "$_runlog" "$_daemonlog"
    trap - INT
}

# =============================================================================
#  主菜单
# =============================================================================
show_menu() {
    echo ""
    echo "================================================================"
    echo "     Microsoft-Rewards-Script  管理面板 (v5 · RK3229裸金属)"
    echo "================================================================"
    echo "  1) 启动        前台运行一次 + 跟随日志"
    echo "  2) 清理缓存    core dump / npm / apt / journal / 旧日志"
    echo "  3) 备份/恢复   sessions  <->  sessions_backup"
    echo "  4) 无人值守    $(sched_describe)"
    echo "  5) 关闭守护    卸载保活 cron 并结束无人值守进程"
    echo "  6) 推送IPv6    把设备公网 IPv6 通过 PushPlus 推送到微信"
    echo "  7) 今日汇总    手动推送当日成功/失败/积分汇总"
    echo "  8) 立即跑一轮  不等计划点,立刻执行一次(不占计划点,可与守护并存)"
    echo "  9) 实时日志    tail -f 今日日志(Ctrl+C 退出,不影响后台)"
    echo "  10) 执行计划   查看今日随机计划时刻/状态/当日统计"
    echo "  0) 退出"
    echo "----------------------------------------------------------------"
    if is_mrs_running; then
        echo "  状态: MRS 运行中 (pid $(pgrep -f 'dist/index\.js' | tr '\n' ' '))"
    else
        echo "  状态: 空闲"
    fi
    echo "  空间: $(df -h / | tail -1 | awk '{print $4}') 可用"
    echo "  内存: $(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)MB 可用"
    echo "  日志: $LOG_DIR/ (每日一份,保留 ${LOG_KEEP_DAYS} 天)"
    echo "  调度: $(sched_describe)"
    echo "  推送: 自动附带公网IPv6 | 每日${SUMMARY_HOUR}:00 汇总 | 选项6/7 手动"
    echo "================================================================"
    printf "请输入选项 [0-10]: "
}

main() {
    while true; do
        show_menu
        read -r choice || exit 0
        case "${choice:-}" in
            1) do_start ;;
            2) do_clean ;;
            3) menu_backup ;;
            4) do_unattended ;;
            5) do_unattended_off ;;
            6) do_push_ipv6 ;;
            7) do_daily_summary ;;
            8) do_run_now ;;
            9) do_follow_logs ;;
            10) do_show_plan ;;
            0|q|Q) exit 0 ;;
            *) echo "无效选项: $choice" ;;
        esac
        printf "\n按回车键返回菜单..."
        read -r _dummy || exit 0
    done
}

# =============================================================================
#  入口
# =============================================================================
case "${1:-}" in
    1)  do_start;      exit 0 ;;
    2)  do_clean;      exit 0 ;;
    3)  do_backup;     exit 0 ;;
    3r|3R) do_restore; exit 0 ;;
    4)  do_unattended; exit 0 ;;
    5|4off|4u) do_unattended_off; exit 0 ;;
    6) do_push_ipv6; exit 0 ;;
    7) do_daily_summary; exit 0 ;;
    8) do_run_now; exit 0 ;;
    log|logs|tail|9) do_follow_logs "${2:-60}"; exit 0 ;;
    10|plan|plan10) do_show_plan; exit 0 ;;
    "") main ;;
    *) echo "用法: bash ~/start.sh [1|2|3|3r|4|5|6|7|8|9|10|log]"; exit 1 ;;
esac
