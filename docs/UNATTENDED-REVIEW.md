# `start_unattended.sh` 评审与修改建议

> 状态：**评审已完成，v4 已落地并实机验证**（2026-09-24）  
> 产出文件：`G:\start_unattended.sh`（v4，原 v3 备份在 `G:\start_unattended.sh.v3.bak`）、`G:\run_daily.sh`

---

## 附录：v4 实际落地内容 + 实机测试结果（2026-09-24 21:30）

### A. 架构决定：你的失败判定是对的，保留

查证结果：仓库自带 `scripts/docker/run_daily.sh`，它正是  
`Script completed successfully.` / `ERROR: Script failed!` 两个标记的**来源**；  
`[RUN-END]` 来自 `Logger.ts`，格式为  
`[时间] [用户] [INFO] [desktop] [RUN-END] 全部账户完成 | 处理账户数=N | 获得积分=X | 原余额=.. | ...`。

所以 **v4 保留了你原本的三标记判定逻辑，一字未改**；只是把"容器"换成  
`$BASE/run_daily.sh`（`scripts/docker/run_daily.sh` 的裸金属适配版，4 处改动：  
工作目录、**载入 .env**、锁进程判据放宽、`MRS_CMD` 可覆盖）。

> **重大发现**：MRS 项目**不含 dotenv**，`ACCOUNT_*` 必须由环境注入。  
> 之前 `mrs-run.sh` 直接 `node dist/index.js` → 账号根本没被读到。  
> `run_daily.sh` 里加了逐行解析的 `.env` 载入（不用 source，避免密码里的 `! # $ &` 被 shell 解释）。

### B. 按你的要求删除

- **多次失败清空 sessions** 的功能（`FAIL_CLEAR_THRESHOLD` / `CLEARED_TODAY` / `AUTO_BACKUP`）已全部移除。  
  sessions 手工备份/恢复（选项 3）保留。
- `mrs-run.sh` 已弃用（改名 `mrs-run.sh.deprecated`）。
- `mrs.timer`（03:00）已 `disable --now`，避免与脚本 01:00 双调度。

### C. 其余改动（按评审清单）

| 项                                  | 结果                                                |
| ---------------------------------- | ------------------------------------------------- |
| 去 Docker                           | ✅ 全部替换，见第 7 节对照表                                  |
| 删 `--single-process` 注入            | ✅ 改由 `MRS_LOW_MEMORY=1` + `MRS_CHROME_ARGS`       |
| 删 `--memory=350m`                  | ✅ 不加硬限制，靠 485MB swap + zswap                      |
| 路径 → `/opt/mrs`                    | ✅ 含保活 crontab 自身路径                                |
| 删 `RUN_ON_START` / `CRON_SCHEDULE` | ✅ 换 `ensure_no_systemd_timer`                     |
| 日志保留 30→7 天                        | ✅ 且 prune 覆盖 `run-*.log`                          |
| `pkill -f` → `pkill -x` / `pgrep`  | ✅（实测 `pkill -f` 把 SSH 会话杀了两次，exit 255）            |
| `children` 兜底 `pgrep -P`           | ✅                                                 |
| shebang → bash                     | ✅（需要 `PIPESTATUS`）                                |
| 单轮超时 + 当日预算                        | ✅ `MAX_RUN_SECONDS=6h` / `DAY_BUDGET_SECONDS=10h` |
| 防并发（`pgrep dist/index.js`）         | ✅                                                 |
| 每轮结束补推汇总                           | ✅                                                 |
| 关键参数可环境变量覆盖                        | ✅ 便于测试                                            |
| 新增选项 8「立即跑一轮」                      | ✅ 单轮模式跑完即退出，不转常驻                                  |

### D. 实机测试结果

| 测试              | 结果                                                                                          |
| --------------- | ------------------------------------------------------------------------------------------- |
| `.env` 注入       | ✅ 账号 `***@qq.com` 被正确读入                                                                     |
| 成功路径            | ✅ `获得积分=55 原余额=100` → 判定成功，不重跑                                                              |
| 假成功路径           | ✅ `0积分+原余额=0` → 重跑 1 次后接受                                                                   |
| 失败路径            | ✅ 检测到 `Script failed` → 退避重试 → 达上限放弃                                                        |
| PushPlus + IPv6 | ✅ `code:200`，IPv6 `2409:8a44:...` 正常回显                                                      |
| crontab 保活      | ✅ `@reboot` + `*/10` 已安装                                                                    |
| **真实登录**        | ✅ 完整走通 `EMAIL_INPUT → FOOTER_ACTION → PASSWORD_INPUT → KMSI_PROMPT → LOGGED_IN`，Bing 会话验证成功 |

### E. 真实运行卡住的地方（非脚本问题）

登录成功，但 **拿不到 Dashboard 数据 → 0 积分**：

```
GET-DASHBOARD-DATA 主接口请求失败 | 信息=Dashboard data missing from API response
GET-DASHBOARD-DATA 获取仪表板数据失败（主接口与 Bing flyout 兜底均失败）: Flyout response is missing Rewards account data
```

实测两个接口（带 cookie）：

- `rewards.bing.com/api/getuserinfo` → 返回 **HTML**（`Market:ZH-CN, PrefCountry: CN`），没有 `dashboard` 字段  
  （源码里这个 URL 本身就标注了 `// Legacy, avoid!`）
- `www.bing.com/rewards/panelflyout/getuserinfo` → `{"userInfo":{"isRewardsUser":false,"nonuser":"True","ruid":"null-null"}}`

对照：`curl` 打 `getuserinfo` 是 HTTP/2 + 302（未登录跳转，正常）；  
`node/undici` 打同一 URL 得到 200 + 「JavaScript required to sign in」HTML。  
两者都不返回 JSON，**说明不是 impit/undici 后端差异问题**，而是  
**该账号在中国大陆市场下不被识别为 Rewards 用户**。

顺带修掉一个真 bug（见下）。

### F. 顺带修复：undici 建连超时

`src/util/Http.ts` 的 fetch 回落实现只用了 `AbortSignal.timeout`，  
**改不了 undici 内部默认 10s 的 connect 超时**。RK3229 上 TLS 握手慢，  
直接抛 `UND_ERR_CONNECT_TIMEOUT`（表现为 `fetch failed`）。  
已改为显式建 `Agent`/`ProxyAgent` 放宽：

```ts
const connectTimeout = Math.max(15000, Math.min(timeout * 2, 60000))
dispatcher = proxyUrl
    ? new undici.ProxyAgent({ uri: proxyUrl, connect, headersTimeout, bodyTimeout })
    : new undici.Agent({ connect, headersTimeout, bodyTimeout })
```

修复后错误信息从 `fetch failed` 变为 `Dashboard data missing from API response`（网络层已通）。  
另加了 `MRS_HTTP_DEBUG=1` 环境变量开关（打印每次响应状态与前 400 字符），排障用。

### G. 下一步建议（需要你决定）

1. **换/确认 Rewards 账号地区**：当前账号市场是 ZH-CN/CN，Rewards 不开放。  
   用美区/港区等受支持地区的账号，或确认该账号已在 rewards.bing.com 注册 Rewards。
2. **或挂代理**：`.env` 里加 `ACCOUNT_1_PROXY_URL=http://user:pass@host:port`，  
   MRS 支持每账号独立代理，让出口不在中国大陆。
3. 解决后启动无人值守：`bash /opt/mrs/start_unattended.sh 4`（装 crontab 保活）；  
   想立刻验证一次：`bash /opt/mrs/start_unattended.sh 8`。

> 目前已**停止**无人值守（选项 5），避免每天空跑 0 分并反复登录你的账号。  
> `mrs.timer` 也保持 disabled。

---

## 0. 一句话结论

> 评审对象：`G:\start_unattended.sh`（v3，867 行，2026-09-18）  
> 目标环境：RK3229 / armv7l / Armbian trixie / 970MB RAM / 4.5GB 可用盘  
> 当前已部署：`/opt/mrs/`（裸金属 Node 22 + 系统 Chromium）+ `/opt/mrs/mrs-run.sh` + `mrs.service` + `mrs.timer`

---

## 0. 一句话结论

这份脚本的**调度/自愈/推送骨架写得很好，v3 的 12 项改进基本都站得住**，但它整份是为  
**OpenStick + Docker + 旧版 run_daily.sh** 写的。搬到 RK3229 上有三类硬伤：

1. **执行层全错** —— 所有 `docker *` 调用在这台设备上不存在（也没必要装）；
2. **判定标记全错** —— `[RUN-END]` / `Script completed successfully` / `Script failed` 是旧版 `run_daily.sh` 的输出，当前 `src/index.ts` 换成了 `全部账户完成 | 处理账户数=.. | 获得积分=..`；
3. **职责重叠** —— 新部署的 `mrs-run.sh` 已经实现了重试 / 假成功重跑 / 清会话 / 清 core / 磁盘体检，外层再套一层会变成 3×3 层嵌套重试。

还有一个**会立刻发生的事故**：`mrs.timer`（每天 03:00）和脚本自己的 01:00 循环会**双调度**，一天跑两遍。

---

## 1. 三个根本性问题

### 1.1 Docker 层整体失效

设备实测：无 Docker、无 `docker` 命令。970MB 内存的 armv7l 上装 Docker 也不划算。  
脚本里 `step_start_container` 有三处几乎完全一样的 `docker run`（复制粘贴），  
`step_clean_core` / `watch_logs` / `wait_until_0100` 空闲巡检全都依赖 `docker logs`。

后果不是"报错"，而是**静默死循环**：

```sh
if ! step_start_container; then
    log_msg "!! 容器启动失败,60s 后重试"; sleep 60; continue   # ← 每 60 秒空转一次，永远不会跑任务
fi
```

### 1.2 判定标记对不上

| 用途  | 脚本里写的（旧版）                       | 实际输出（当前版）                                                                             |
| --- | ------------------------------- | ------------------------------------------------------------------------------------- |
| 成功  | `Script completed successfully` | 进程退出码 0 + 日志含 `全部账户完成`                                                                |
| 失败  | `Script failed`                 | 无统一标记，只能靠退出码 / 缺汇总行                                                                   |
| 积分  | `[RUN-END] ... 获得积分=N`          | `全部账户完成 \| 处理账户数=N \| 获得积分=X \| 原余额=.. \| 现余额=.. \| 运行分钟数=..`（`src/index.ts:388/641`） |
| 假成功 | `获得积分=0` **且** `原余额=0`          | 同上，`mrs-run.sh` 目前**只判了 0 积分，漏了原余额**                                                  |

### 1.3 与 `mrs-run.sh` 职责重叠

`mrs-run.sh` 已内置（且已跑通）：

| 能力           | mrs-run.sh               | start_unattended.sh        |
| ------------ | ------------------------ | -------------------------- |
| 失败重试 + 退避    | ✅ `MAX_ATTEMPTS=3`       | ✅ `MAX_ATTEMPTS=5`         |
| 假成功重跑        | ✅ `ZERO_POINT_RERUNS=1`  | ✅ `ZERO_POINT_RERUNS=2`    |
| 失败达阈值清会话     | ✅ `CLEAR_SESSIONS_AT=2`  | ✅ `FAIL_CLEAR_THRESHOLD=2` |
| 清会话前自动备份     | ✅ `sessions_backup_auto` | ✅ `sessions_backup_auto`   |
| core dump 清理 | ✅                        | ✅                          |
| 磁盘体检         | ✅ <300MB 清旧日志            | ❌                          |
| 退出码语义        | ✅ 0=成功 / 1=放弃            | ❌（靠日志关键字）                  |

两层相乘 = 最坏 **9 次完整运行**。RK3229 单账号一轮几小时 → 直接跨天。

---

## 2. P0：不改就会坏 / 双跑 / 空转

### P0-1 【双调度】停用 `mrs.timer`

脚本 `UNATTEND_HOUR=1` 自己调度，`mrs.timer` 又设了 `OnCalendar=*-*-* 03:00:00` + `Persistent=true`。  
两者共存 = 一天跑两遍，第二遍大概率撞上第一遍（RK3229 一轮要跑很久）。

建议：**由脚本统一调度**（它有 flock 单实例 + 断电保活 + 推送，能力比裸 timer 强），停掉 timer 并在脚本里加自检：

```sh
ensure_no_systemd_timer() {
    if systemctl is-enabled mrs.timer >/dev/null 2>&1; then
        systemctl disable --now mrs.timer >/dev/null 2>&1
        log_msg "[*] 已停用 mrs.timer(03:00)，避免与脚本 ${UNATTEND_HOUR}:00 调度双跑"
    fi
}
```

在 `do_unattended` 里替换掉 `ensure_runs_on_start` / `ensure_no_container_cron` 两个函数。

> 反向方案（保留 systemd 调度、脚本只做监控+推送）也可以，但脚本的 crontab 保活链路就没意义了，不推荐。

### P0-2 【执行层】`docker run` → 直接跑 `mrs-run.sh`

删掉 `step_start_container` 三分支复制粘贴，换成：

```sh
MRS_RUN="$BASE/mrs-run.sh"
RUN_LOG="$LOG_DIR/run-$(date +%Y%m%d).log"

step_start_run() {
    log_msg "[*] 启动 MRS（mrs-run.sh 内部自带重试/自愈）..."
    MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}" \
    ZERO_POINT_RERUNS="${ZERO_POINT_RERUNS:-1}" \
    CLEAR_SESSIONS_AT="${CLEAR_SESSIONS_AT:-2}" \
    bash "$MRS_RUN" 2>&1 | tee -a "$_logfile"
    return "${PIPESTATUS[0]}"      # ← 需要 bash（见 P1-7）
}
```

`docker restart "$NAME"` → 重新执行 `bash "$MRS_RUN"`。  
`docker ps --format '{{.Names}}' | grep -qx "$NAME"` → `pgrep -f 'dist/index.js' >/dev/null`。

### P0-3 【`--single-process`】整个 `step_prepare_params` 删掉

这是给 OpenStick 380MB 的 hack。RK3229 有 970MB，**不需要**；而且 `DEPLOY_LOG.md` 里已经验证  
`--single-process` 是反复 segfault 的元凶（渲染进程和浏览器挤在一个进程里，一个页面崩 = 全崩）。

更关键的是：新版 `Browser.ts` 已经支持环境变量，**不用再 sed 改 dist 文件了**：

```sh
export MRS_LOW_MEMORY="${MRS_LOW_MEMORY:-1}"
export MRS_CHROME_ARGS="${MRS_CHROME_ARGS:---disable-dev-shm-usage}"
```

低内存参数（`--disable-gpu --disable-software-rasterizer --disable-extensions --disable-features=Translate,MediaRouter,OptimizationHints,AcceptCHFrame`）已内置在  
`Browser.ts` 的 `MRS_LOW_MEMORY` 分支里。

### P0-4 【内存限制】`--memory=350m --memory-swap=750m` 必删

350MB 是按 OpenStick 380MB 定的。RK3229 实测 **Chromium 单页峰值 651MB RSS**，350MB 会立刻 OOM。

裸金属下改用 systemd drop-in（软限制 + 硬上限 + OOM 后停止而不是随机杀）：

```ini
# /etc/systemd/system/mrs.service.d/memory.conf
[Service]
MemoryHigh=700M
MemoryMax=850M
OOMPolicy=stop
```

如果按 P0-2 改成脚本直接跑（不走 systemd），则**不加硬限制** —— 靠 485MB swap + zswap 兜底，  
`mrs.service` 里的 `TimeoutStartSec=8h` 保证长任务不被掐。别用 `ulimit -v`（Chromium 会 malloc 失败直接崩）。

### P0-5 【路径】`/home/user/mrs` → `/opt/mrs`

```sh
BASE=/opt/mrs                       # 原: /home/user/mrs
IMAGE=   NAME=   PATCHED=   TARGET=   # 这 4 个 Docker 专用变量整行删掉
SESSIONS="$BASE/sessions"
BACKUP="$BASE/sessions_backup"
AUTO_BACKUP="$BASE/sessions_backup_auto"
MRS_RUN="$BASE/mrs-run.sh"
RUN_LOG="$LOG_DIR/run-$(date +%Y%m%d).log"
```

`ensure_supervisor` 里写死的 `sh /home/user/start.sh 4` 也要改（见 P1-8）。

### P0-6 【日志判定】`watch_logs` 的模式匹配全换

`mrs-run.sh` 已经把每次尝试的结果写清楚了，直接匹配它：

```sh
while IFS= read -r line; do
    case "$line" in
        *"全部账户完成"*|*"本次完成："*)
            printf '%s\n' "$line" > "$RUNEND_FILE"
            : > "$WATCH_DONE_FLAG"
            break ;;
        *"本轮结束：失败"*|*"本轮结束：成功"*)      # 注意是全角冒号 ：
            break ;;                                # 内层已放弃/已成功，交给外层看退出码
    esac
done < "$LOG_FIFO"
```

日志源：`docker logs -f --since 5s "$NAME"` → `tail -n 0 -f "$RUN_LOG"`。

> 前提：`mrs-run.sh` 里 `node ... | tee -a` 的 node 输出要行缓冲，否则 tail 到的内容滞后。  
> 建议把 `mrs-run.sh` 那行改成 `stdbuf -oL -eL node "$MRS_DIR/dist/index.js" 2>&1 | tee -a "$RUN_LOG"`。

### P0-7 【并发双跑】定时点到达前先查有没有在跑

RK3229 一轮可能跨越 01:00。`wait_until_0100` 一到点就无脑启动 → 两个 node 进程抢 970MB。

```sh
if pgrep -f 'dist/index.js' >/dev/null 2>&1; then
    log_msg "上一轮仍在运行(pid $(pgrep -f 'dist/index.js' | tr '\n' ' '))，跳过本次触发"
    sleep 300; continue
fi
```

同理 `watch_logs` 返回 1（日志流中断）时的处理也改成：进程还在 → 继续跟；进程没了 → 看退出码。

---

## 3. P1：强烈建议

### P1-1 【去重】外层只留"调度 + 解析 + 推送 + 保活"

把 P0-2 的 `step_start_run` 用上之后，`do_unattended` 内层那个 `while true` 循环里的  
失败计数 / 清会话 / 假成功重跑 / 退避 / `docker restart` 全部可以删掉，只保留：

```sh
step_start_run; _rc=$?
last_runend_fields                      # 从 RUNEND_FILE 解析 获得积分 / 原余额
if [ "$_rc" -eq 0 ]; then
    DAY_SUCCESS_COUNT=$((DAY_SUCCESS_COUNT + 1))
    DAY_TOTAL_POINTS=$((DAY_TOTAL_POINTS + ${_got:-0}))
    push_msg "MRS无人值守-完成" "..."
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    push_msg "MRS无人值守-放弃本轮" "..."
fi
```

内层重试交给 `mrs-run.sh`（把 `MAX_ATTEMPTS` / `ZERO_POINT_RERUNS` / `CLEAR_SESSIONS_AT`  
通过环境变量传下去，见 P0-2）。`MAX_ATTEMPTS=5` / `ZERO_POINT_RERUNS=2` 这两个外层变量  
改名或删掉，避免和 `mrs-run.sh` 同名变量混淆。


### P1-2 【时长预算】RK3229 必须加

`config.json` 现在是 `searchDelay/readDelay=1-2min`，单账号实测 30 分钟 ~ 2 小时。  
但一旦改回 `config.example.json` 的 6-12min 就是 9.4 小时/账号。

```sh
MAX_RUN_SECONDS=$((6*3600))      # 单轮硬超时 6h
DAY_BUDGET_SECONDS=$((10*3600))  # 当天累计运行预算 10h
```

用 `timeout` 包住，**超时(124)视为失败但不重试**（卡死的话重试也一样卡）：

```sh
timeout -k 60 "$MAX_RUN_SECONDS" bash "$MRS_RUN" 2>&1 | tee -a "$_logfile"
```

同时在 `wait_until_0100` 到点前检查 `DAY_BUDGET_SECONDS` 是否用尽，用尽就跳过当天。

### P1-3 【假成功判据】补上"原余额"

当前 `mrs-run.sh` 只在 `获得积分=0` 时重跑。如果账号当天已满额，`获得积分=0` 是**正常**的，  
会白白重跑。旧脚本用 `0积分 AND 原余额=0`（余额读取异常）才是真·假成功。建议同步过去：

```sh
# mrs-run.sh：把 SUMMARY 的 grep 扩展到含原余额
SUMMARY=$(grep -o '全部账户完成 | 处理账户数=[0-9]* | 获得积分=[0-9]* | 原余额=[0-9]*' "$RUN_LOG" | tail -1)
GAINED=$(echo "$SUMMARY" | grep -o '获得积分=[0-9]*' | grep -o '[0-9]*' || echo "")
BEFORE=$(echo "$SUMMARY" | grep -o '原余额=[0-9]*'   | grep -o '[0-9]*' || echo "")

if [ "${GAINED:-0}" -eq 0 ] && [ "${BEFORE:--1}" -eq 0 ] && [ "$zero_rerun" -lt "$ZERO_POINT_RERUNS" ]; then
    ...重跑...
fi
```

> `BEFORE` 默认 `-1`（读不到余额就不重跑），避免误判。

### P1-4 【删废】`ensure_runs_on_start` / `ensure_no_container_cron`

`RUN_ON_START` / `CRON_SCHEDULE` 是 Docker 镜像 entrypoint 的变量，裸金属下无意义，  
而且这两个函数会**往 `.env` 里写行 + 生成 `.env.bak`**，纯噪音。直接删，换成 P0-1 的  
`ensure_no_systemd_timer`。

`RECREATE_DAILY`、`NEVER_CRON` 这两个开关同样删掉。

### P1-5 【清 core】`docker exec rm` → `find`

```sh
step_clean_core() {
    log_msg "[*] 清理残留 core dump ..."
    find "$BASE" -maxdepth 2 -type f \( -name 'core' -o -name 'core.*' \) -size +5M -print -delete 2>/dev/null
    log_msg "    可用空间: $(df -h / | tail -1 | awk '{print $4}')"
}
```

（保底保险：`kernel.core_pattern=/dev/null` 已在 `/etc/sysctl.d/99-no-coredump.conf` 生效，实测 `= /dev/null`，  
正常不会再产生 core。留着 find 是防止改过 sysctl 之前留下的。）

### P1-6 【杀进程】`pkill -f` 是雷，`/proc/.../children` 可能不存在

两个坑，都在 `do_unattended_off` 里：

- **绝对不要用 `pkill -f chromium` / `pkill -f node`** —— 会匹配到脚本自己的命令行，  
  把 SSH 会话一起干掉（实测 exit 255）。要用 `pkill -x chromium` / `pkill -x chrome` / `pkill -x headless_shell`。
- `/proc/$_p/task/$_p/children` 需要内核开 `CONFIG_PROC_CHILDREN`，rockchip 内核大概率没开 →  
  文件不存在 → `_children` 为空 → 直接 `kill $_p`，而 dash 阻塞在 `sleep` 时 TERM 会被推迟处理。

兜底改法：

```sh
_children=$(cat "/proc/$_p/task/$_p/children" 2>/dev/null)
[ -z "$_children" ] && _children=$(pgrep -P "$_p" 2>/dev/null | tr '\n' ' ')
if [ -n "$_children" ]; then kill $_children 2>/dev/null; sleep 1; fi
```

关守护时也要顺手收掉孤儿浏览器：

```sh
pkill -x chromium 2>/dev/null; pkill -x chrome 2>/dev/null; pkill -x headless_shell 2>/dev/null
```

### P1-7 【shebang】`#!/bin/sh`(dash) → `#!/usr/bin/env bash`

P0-2 要用 `PIPESTATUS` 拿 `mrs-run.sh` 的真实退出码，dash 没有。

若坚持 `sh`，用临时文件绕开：

```sh
( bash "$MRS_RUN"; echo $? > /tmp/mrs_rc ) 2>&1 | tee -a "$_logfile"
_rc=$(cat /tmp/mrs_rc)
```

### P1-8 【保活 crontab】路径 + 幂等标识

```sh
echo "@reboot sleep 30 && sh /opt/mrs/start_unattended.sh 4 >/dev/null 2>&1"
echo "*/10 * * * * sh /opt/mrs/start_unattended.sh 4 >/dev/null 2>&1"
```

grep 判重的标识从 `start.sh 4` 改成 `start_unattended.sh 4`。  
（设备实测：cron `enabled` + `active`，root 目前无 crontab，可以直接装。）

### P1-9 【日志保留】30 天 → 7 天

设备只有 4.5GB 可用。MRS 全量日志一天几 MB 起（今天的 `run-20260924.log` 已 16KB，正式跑会大很多）。

```sh
LOG_KEEP_DAYS=7
```

`prune_logs` 里同时清 `run-*.log` 和 `.failcount-*`：

```sh
prune_logs() {
    [ -d "$LOG_DIR" ] || return 0
    find "$LOG_DIR" -type f \( -name 'unattended-*.log' -o -name 'run-*.log' -o -name '.failcount-*' \) \
         -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null
}
```

### P1-10 【汇总推送时机】长任务期间 23:00 推送不会触发

`maybe_daily_summary` 只在 `wait_until_0100` 的等待循环里调用。RK3229 单轮几小时，  
23:00 大概率**正在跑** → 当天汇总静默丢失。

改法：`step_start_run` 结束后立刻调一次 `maybe_daily_summary`，并且在 `tail -f` 的  
`while read` 循环里每 N 行也调一次。

---

## 4. P2：锦上添花

- **P2-1 推送可用**：设备实测有公网 IPv6（`2409:8a44:...`，联通），`curl -6 https://api6.ipify.org`  
  正常返回。IPv6 + PushPlus 那套（`get_public_ipv6` / `json_escape` / `push_msg_sync`）**完全照搬，不用改**。  
  只需要在 `/opt/mrs/.env` 里加一行 `CONFIG_PUSHPLUS_TOKEN=xxx`。
- **P2-2 开机环境自检推送**：每天定时点先把 `mrs-run.sh` 打的环境自检行  
  （`环境：node=.. | CHROME_PATH=.. | MRS_LOW_MEMORY=.. | HTTP=..` 和 `内存：.. 可用 / .. 总计`）  
  一并推送，异常立刻可见。电视盒子断电/断网场景很有用。
- **P2-3 `do_clean` 里的 Docker 段**要重写：换成 apt clean、`journalctl --vacuum-size`（journal 已限 60M）、  
  `npm cache clean --force`、`find /opt/mrs/logs -mtime +3 -delete`。  
  另外它里面有 `read ans`，非交互调用（cron）会读到 EOF —— 建议加 `</dev/null` 保护或直接删交互。
- **P2-4 `watch_logs` 不再需要 mkfifo**：裸金属下 `mrs-run.sh` 自己 tee 到文件，  
  直接 `tail -n 0 -f "$RUN_LOG" | while read` 即可，省掉 FIFO + `_dpid` + `kill/wait` 那一堆。
- **P2-5 `assert_own_lock` / `exec 9>>` + `flock` 这套写得很好，保留**。  
  `LOCKFILE=/tmp/mrs_unattended.lock` 放在 `/tmp` 配合 `@reboot` 保活也合理（重启自动清空）。

---

## 5. 完全不用动的部分

- 单实例锁（`exec 9>>` + `flock -n` + `assert_own_lock` 每小时自检让位）
- `trap '... ; exit 0' EXIT INT TERM` 的写法（注释里 dash trap 不自动退出的坑已经踩过并处理了）
- PushPlus 三件套 + IPv6 回显多服务 fallback
- `json_escape` 的 dash 兼容实现
- 跨天统计 `rollover_day_if_needed` 与 `FAIL_DAY` 初始化的细节（注释解释得很清楚）
- 选项 3 备份/恢复、选项 6/7 手动推送

---

## 6. 最小落地清单

按这个顺序改，改完就能在 RK3229 上跑：

- [ ] 1\. 路径：`BASE=/opt/mrs`，删 `IMAGE/NAME/PATCHED/TARGET`
- [ ] 2\. 删 `step_prepare_params`（`--single-process`），改由 `MRS_LOW_MEMORY=1` + `MRS_CHROME_ARGS` 提供
- [ ] 3\. 删 `step_start_container` 三分支 → `step_start_run`（`bash /opt/mrs/mrs-run.sh`）
- [ ] 4\. 删 `ensure_runs_on_start` / `ensure_no_container_cron` → `ensure_no_systemd_timer`
- [ ] 5\. `systemctl disable --now mrs.timer`（**先手动执行，防双跑**）
- [ ] 6\. `watch_logs`：日志源改 `tail -n 0 -f "$RUN_LOG"`；匹配 `全部账户完成` / `本轮结束：`
- [ ] 7\. `last_runend_fields`：从 `本次完成：全部账户完成 | ... | 获得积分=N | 原余额=M` 解析
- [ ] 8\. `step_clean_core` 改 `find` 版
- [ ] 9\. `ensure_supervisor` 路径改 `/opt/mrs/start_unattended.sh`，判重标识同步
- [ ] 10\. `do_unattended_off`：`pkill -x`，`children` 兜底 `pgrep -P`
- [ ] 11\. `LOG_KEEP_DAYS=7`，prune 覆盖 `run-*.log`
- [ ] 12\. shebang 改 bash（为 `PIPESTATUS`）
- [ ] 13\. 加 `MAX_RUN_SECONDS` / `DAY_BUDGET_SECONDS` + `timeout`
- [ ] 14\. 加"上一轮仍在运行则跳过"（`pgrep -f dist/index.js`）
- [ ] 15\. `/opt/mrs/.env` 加 `CONFIG_PUSHPLUS_TOKEN=`
- [ ] 16\. `mrs-run.sh` 两处小改：`stdbuf -oL -eL` + 假成功判据加"原余额"

---

## 7. Docker → 裸金属 对照表

| Docker 概念                          | RK3229 对应物                                                  |
| ---------------------------------- | ----------------------------------------------------------- |
| `docker run -d --name X`           | `bash /opt/mrs/mrs-run.sh`（前台阻塞）                            |
| `docker restart X`                 | 重新执行 `bash /opt/mrs/mrs-run.sh`                             |
| `docker ps --format '{{.Names}}'`  | `pgrep -f 'dist/index.js'`                                  |
| `docker logs -f --since 5s X`      | `tail -n 0 -f /opt/mrs/logs/run-YYYYMMDD.log`               |
| `docker exec X rm -f core`         | `find /opt/mrs -maxdepth 2 -name 'core*' -size +5M -delete` |
| `--memory=350m --memory-swap=750m` | systemd `MemoryHigh=700M` / `MemoryMax=850M`（或不限，靠 swap）    |
| `--ulimit core=0:0`                | `kernel.core_pattern=/dev/null` + `LimitCORE=0`（已生效）        |
| `--env-file .env`                  | `mrs.service` 的 `Environment=` / `mrs-run.sh` 的 `export`    |
| `--restart unless-stopped`         | cron `@reboot` + `*/10 * * * *` 自检（脚本已有）                    |
| `-v PATCHED:TARGET:ro`（sed 改 dist） | `MRS_CHROME_ARGS` 环境变量（**不用改文件**）                           |
| `CRON_SCHEDULE` / `RUN_ON_START`   | `mrs.timer`（建议停用）/ 无对应                                      |
