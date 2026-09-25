# 排障手册

> 这里记录的是在 RK3229（armv7l）+ Armbian 上实测踩到的坑，按**症状**编排。
> 遇到问题先按症状定位，再往下看原因。

---

## 0. 排查前必读

**控制台会吞掉 `[ERROR]` 行** —— 排查一律看日志文件，不要只看终端：

```bash
tail -50 logs/run-$(date +%Y%m%d).log
grep "\[ERROR\]" logs/run-$(date +%Y%m%d).log | tail -20
```

**把完整 HTTP 响应体落盘**（排查接口问题的最强手段）：

```bash
export MRS_HTTP_DEBUG=1
# 响应会写到 /tmp/mrs-httpdump/
```

**一句话自检当前生效配置**：

```bash
cd /opt/mrs
node -e "const{loadConfig,loadAccounts}=require('./dist/util/Load.js');
console.log('accounts:', loadAccounts().map(a=>({e:a.email,lang:a.langCode,geo:a.geoLocale,fp:a.saveFingerprint})));
console.log('pushplus:', loadConfig().webhook.pushplus);"
```

---

## 1. 浏览器 / 环境

### `chromium is not supported on <unknown>`

**原因**：手工跑 `node dist/index.js` 时缺环境变量，patchright 找不到可用浏览器。

**解决**：

```bash
export PLAYWRIGHT_BROWSERS_PATH=0
export CHROME_PATH=/usr/bin/chromium
```

`deploy/run_daily.sh` 已内置这两个变量，所以走 `start.sh` 不会遇到。

### `impit 原生模块在当前平台不可用（无 armv7l 预编译包），已回落到 fetch 后端`

**这不是错误，是预期行为。** `impit` 只发布了 `x86_64` / `aarch64` 的原生二进制。

此时会自动启用**浏览器网络栈桥接**，用真实 Chromium 取数，功能不受影响。
若这条日志后面**没有**跟着 `已启用浏览器网络栈桥接`，说明桥接没装上，检查 `src/index.ts` 的注入点。

### 启动报 `browserType.launch: Target page, context or browser has been closed`

多半是**内存不足**被 OOM Killer 杀掉。

```bash
free -h
dmesg | grep -i "killed process" | tail -5
```

**解决**：确认 zswap/zram 已开（见 [DEPLOY-RK3229.md](DEPLOY-RK3229.md) 第 6.2 节），
并确认 `MRS_LOW_MEMORY=1` 已设置、`blockMedia=true`。

---

## 2. Dashboard / 登录态

### 症状：`Dashboard data missing from API response` + `Flyout response is missing Rewards account data`

**这是最典型的一类问题**，根因通常只有一个：**登录态不对**。

**第一步：看 Cookie 审计**（本项目新增的日志）

```bash
grep "COOKIE-AUDIT" logs/run-$(date +%Y%m%d).log | tail -3
```

对照下表判读：

| 字段 | 正常 | 异常 | 含义 |
|---|---|---|---|
| `身份=` | `MSA=CfDJ8...` | `MUID=...` | 后者说明**没有 MSA 鉴权票据** |
| `rewards关键=n/3` | `3/3` | `1/3`、`2/3` | 缺 `_C_Auth` / `tifacfaatcs` / `MSFPC` |
| `bing关键=n/8` | `8/8` | `7/8` | 缺 Bing 侧登录态 |
| `缺失=` | 只列 `MSPRequ,MSPOK,MSPAuth,WLSSC` | 还包含 `.MSA.Auth`、`tifacfaatcs` | 后者的四个 live 组票据**缺失无影响** |
| `仪表板=` | `primary` | `flyout` | 降级了 |

**第二步：确认是登录态问题后，删掉陈旧会话强制重新登录**

```bash
# 方式一：全删（会重新登录所有账户）
rm -f sessions/sessions.db

# 方式二：只删指定账户（推荐，需 sqlite3）
sqlite3 sessions/sessions.db "DELETE FROM sessions WHERE email='you@example.com';"
```

**原因说明**：上游的登录态判定只看**主机名** —— URL 落在 `*.bing.com` 就认定「已登录」。
复用陈旧会话时，页面会停在 `rewards.bing.com/dashboard` 却没有身份票据，
于是**登录流程被整个跳过，服务端从未下发票据**，导致：

```
rewards.bing.com/api/getuserinfo   →  返回登录页（约 5KB）
panelflyout/getuserinfo            →  返回匿名响应
```

本仓库已修正为**先校验票据再判已登录**（`hasAuthIdentity()`），缺失时主动回 `/auth/login` 重新换取。
但**已经陈旧的会话仍需删一次**才能触发真正的重新登录。

**第三步：验证修复**

```bash
# 主接口响应长度应在 600KB+ 而不是 5KB
grep "HTTP-BRIDGE" logs/run-$(date +%Y%m%d).log | grep getuserinfo | tail -2

# 数据源统计：应全部是 primary，flyout 为 0
awk "/<轮次起始时间>/,0" logs/run-$(date +%Y%m%d).log | grep -c "数据源=primary"
awk "/<轮次起始时间>/,0" logs/run-$(date +%Y%m%d).log | grep -c "数据源=flyout"
```

### `HTTP-BRIDGE 预热导航失败 | page.goto: net::ERR_CONNECTION_RESET`

设备到微软的网络不稳定（这类盒子很常见）。**属瞬时错误**，本仓库的桥接会回落普通后端，
flyout 兜底也会重试 3 次。

如果**高频**出现，说明网络质量太差：

```bash
# 检查丢包与延迟
ping -c 20 www.bing.com
# 建议用有线网；WiFi 只作备份
```

### 症状：`serpbotscore=未解析` / `字段缺失`

看日志里紧邻的一行：

| `机器人检测指标` 的内容 | 含义 |
|---|---|
| `serpbotscore=0.79` | 正常 |
| `字段缺失(profile已返回但未含serpbotscore)` | 接口没下发这个字段（可能该账户/市场不需要） |
| `匿名兜底:未返回profile` | **登录态失效** → 回到上一节 |

---

## 3. 推送

### 症状：`start.sh` 的推送正常，但 MRS 自己跑完不推送

**这是两套独立实现**，配置来源不同：

| 实现 | 读哪里 | 是否走 `config.json` |
|---|---|---|
| `start.sh::push_msg()` | 直接 `grep` `.env` 的 `CONFIG_PUSHPLUS_TOKEN` 后 `curl` | ❌ 绕过了 |
| MRS 内部 | `config.json` 的 `webhook.pushplus.{enabled,token}` | ✅ |

**所以：`start.sh` 能推 ≠ MRS 能推。**

**排查步骤**：

```bash
# 1) 看 MRS 读到的配置
cd /opt/mrs && node -e "console.log(require('./dist/util/Load.js').loadConfig().webhook.pushplus)"

# 2) 若 enabled=true 但 token 为空 → 这就是原因
```

**修复**：把 token 写进 `config.json`

```bash
nano /opt/mrs/config.json
```

```jsonc
"pushplus": {
  "enabled": true,
  "token": "你的_token",       // ← 放这里
  "title": "Microsoft-Rewards-Script",
  "template": "txt",
  "channel": ""                // ← 这是推送渠道(wechat/cp/wx/mail…)，不是放 token 的地方
}
```

**验证**：

```bash
cd /opt/mrs && node -e "
const {loadConfig}=require('./dist/util/Load.js');
const {sendPushPlus,flushPushPlusQueue}=require('./dist/logging/PushPlus.js');
const pp=loadConfig().webhook.pushplus;
console.log('token len =', pp.token.length);
sendPushPlus(pp,'链路自检').then(()=>flushPushPlusQueue(8000)).then(()=>console.log('已提交'));
"
```

也可以直连接口看响应码：

```bash
node -e "
const t=require('/opt/mrs/config.json').webhook.pushplus.token;
fetch('https://www.pushplus.plus/send',{method:'POST',
  headers:{'Content-Type':'application/json'},
  body:JSON.stringify({token:t,title:'t',content:'c',template:'txt'})})
 .then(r=>r.text()).then(console.log);
// 期望: {\"code\":200,\"data\":\"...\",\"msg\":\"执行成功\"}
"
```

### ⚠️ 最重要的一个坑：`CONFIG_*` 环境变量不会自动生效

在 `.env` 里写 `CONFIG_PUSHPLUS_TOKEN=xxx`，**对 MRS 完全无效**。

原因：`src/util/ConfigEnvOverrides.ts` 是个**独立 CLI 工具，主流程从不 import 它**（已验证 `dist/` 内无任何引用）。
`CONFIG_*` 只是它的输入，必须手动执行才会写回 `config.json`。

```bash
# 查变量名 → 配置路径 的映射表
node dist/util/ConfigEnvOverrides.js list  --config /opt/mrs/config.json

# 把 .env 里的 CONFIG_* 写回 config.json
node dist/util/ConfigEnvOverrides.js apply --config /opt/mrs/config.json
```

> **建议**：直接编辑 `config.json`，最直观也最可靠。

### 症状：`channel` 字段里放了个 32 位十六进制串

那是把 **token 填错字段**了。`channel` 的合法值是推送渠道（`wechat` / `cp` / `wx` / `mail` / `webhook`…）。

本仓库已在 token 为空时打 `WARN` 并给出定向提示，日志里能直接看到。

---

## 4. 配置

### 改了 `.env` / `config.json` 不生效？

**先放心：改完不需要重启守护，下一轮会自动生效。**

原因：每轮都是**全新进程链**

```
守护(start.sh，常驻)
   └─ run_daily.sh        ← 新进程
        └─ node dist/index.js   ← 新进程
```

两个配置文件都在**各自进程启动时从磁盘读取**，没有任何跨轮缓存。

**但要注意三点**：

1. **正在跑的那一轮用旧值** —— 配置只影响下一轮。
2. `config.json` 必须是**合法 JSON**（MRS 只认 `config.json`，**不认 `config.ini`**）。
   格式写坏会导致该轮启动失败：
   ```bash
   node -e "JSON.parse(require('fs').readFileSync('/opt/mrs/config.json','utf8'))" && echo "JSON OK"
   ```
3. `CONFIG_*` 环境变量不会自动生效（见上一节）。

### `loadConfig()` 到底读的哪个文件？

读**项目根目录**的 `config.json`（回退 `dist/`、`src/`）。确认实际路径：

```bash
cd /opt/mrs && ls -l config.json dist/config.json src/config.json 2>&1
```

### ⚠️ 多账号序号坑（最容易静默失败的一处）

**账号序号 = `.env` 里 `ACCOUNT_N_EMAIL` 的 N**（`getAccountIndexes()` 只扫 `ACCOUNT_N_EMAIL`）。

把 `ACCOUNT_1_EMAIL` 注释掉、改用 `ACCOUNT_2_EMAIL` 后，下面这些**会全部静默失效**：

- `ACCOUNT_1_LANG_CODE` → 回退 `en`
- `ACCOUNT_1_GEO_LOCALE` → 回退 `auto`
- `ACCOUNT_1_SAVE_FINGERPRINT_MOBILE` / `_DESKTOP` → 回退 `false`

**症状**：日志里出现 `locale: en-CN`（而不是 `zh-CN`），且每次都要重新登录（不存指纹）。

**修复**：把辅助项的前缀改成与账号编号一致。

**自检**：

```bash
cd /opt/mrs && node -e "console.log(require('./dist/util/Load.js').loadAccounts())"
# 期望: langCode='zh-CN', geoLocale='CN', saveFingerprint={mobile:true,desktop:true}
```

---

## 5. 无人值守守护

### `已有无人值守实例在运行`（但实际没有）

**原因**：守护用 `flock` 锁 `/tmp/mrs_unattended.lock`，而 **fd 会被子进程继承**。
守护被 `kill -9` 后，遗留的 `sleep 3600` 子进程**仍然持有**这把锁。

**定位与处理**：

```bash
ls -l /proc/*/fd/* 2>/dev/null | grep mrs_unattended   # 找到持锁进程
kill <那个子进程>
rm -f /tmp/mrs_unattended.lock
```

> 顺带记住：**不要用 `pkill -f "sleep 3600"`** —— ssh 命令行本身也含这个串，会把自己杀掉（exit 255）。

### `crontab` 里保活条目无限膨胀

旧版用 `start_unattended.sh 4` 当标记，但实际写入的是 `bash /root/start.sh 4` ——
**永远匹配不上**，于是每次启动都追加一组；卸载也永远报「不存在」。

**v5 已修**：统一 `CRON_TAG` 注释 + 实际命令串过滤（`_cron_strip_mrs()`），启动时幂等重写。

**核对**：

```bash
crontab -l | grep -c "^@reboot"    # 应为 1
crontab -l | grep -c "^\*/10"      # 应为 1
```

### 计划点没执行 / 状态是 `missed`

```bash
bash /root/start.sh 10      # 看当日计划与状态
grep "\[计划\]" logs/unattended-$(date +%Y%m%d).log | tail -20
```

| 状态 | 含义 |
|---|---|
| `pending` | 未到点，等待中 |
| `done` | 已认领执行（**先标记后执行**，所以被 kill 也不会重复） |
| `missed` | 已过点且**超出 ±600 秒宽限**，不再补跑 |

想手动补跑一轮（**不占计划点**）：

```bash
bash /root/start.sh 8
```

### 守护在跑时，选项 8 报「已有守护在运行」

**v5 已修**。设计上把「守护单例锁」和「单轮执行锁」分开了：
选项 8 走 `do_run_now()`，**不取守护锁、不读写计划文件**，只用 `is_mrs_running` 判断真冲突。

### 无法在 ssh 里后台启动守护

直接 `&` 会让 ssh 会话提前收到 SIGTERM（表现为 exit 255、无输出）。正确姿势：

```bash
ssh host 'nohup setsid bash /root/start.sh 4 </dev/null >/dev/null 2>&1 & disown; exit 0'
```

---

## 6. 网络 / 设备

### SSH 首次连接报 `Host key verification failed`

设备重装或 IP 被复用导致指纹变更：

```bash
ssh-keygen -R <设备IP>
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<设备IP>
```

### 板载 WiFi 连不上 / 整机假死

RK3229 常用 **ESP8089** WiFi 模块。**晶振参数写错会导致整机假死**（不是简单的连不上）。

`crystal` 的权威映射见 `modinfo esp8089`：

| 值 | 晶振 |
|---|---|
| `0` | 40 MHz（驱动默认） |
| `1` | **26 MHz** |
| `2` | 24 MHz |

写错（如本机 26MHz 却写了 `=2`）→ 握手超时 `esp_init_all failed: -110` → probe Oops
→ 反复重试拖死 MMC → **整机假死**。

```bash
bash deploy/fix-esp8089-wifi.sh diag     # 诊断
bash deploy/fix-esp8089-wifi.sh fix      # 修复
```

> `no_auto_sleep` 在 6.x 内核已不存在，写了会被 ignore。

### 设备完全失联（ping 通但 SSH 超时）

IP 变了。在路由器上找，或用：

```bash
for i in $(seq 1 254); do ping -c1 -W1 192.168.1.$i >/dev/null 2>&1 && echo "192.168.1.$i up"; done
```

---

## 7. 快速诊断清单

按顺序跑完，90% 的问题都能定位：

```bash
# 1) 进程与守护
pgrep -af "dist/index[.]js"; pgrep -af "start[.]sh 4"
crontab -l | grep -c "^@reboot"; systemctl is-enabled mrs.timer

# 2) 配置是否生效
cd /opt/mrs
node -e "console.log(require('./dist/util/Load.js').loadAccounts())"
node -e "console.log(require('./dist/util/Load.js').loadConfig().webhook.pushplus)"

# 3) 今天的计划
bash /root/start.sh 10

# 4) 最近一轮的关键结论
tail -200 logs/run-$(date +%Y%m%d).log | grep -E "COOKIE-AUDIT|数据源=|RUN-END|ERROR"

# 5) 内存与内核告警
free -h; dmesg | tail -20
```
