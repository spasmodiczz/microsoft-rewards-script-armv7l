# Microsoft-Rewards-Script · armv7l / RK3229 无人值守版

[![Base](https://img.shields.io/badge/基于-chiihero%2FMicrosoft--Rewards--Script%20V4--china-informational)](https://github.com/chiihero/Microsoft-Rewards-Script)
[![Upstream](https://img.shields.io/badge/上游-TheNetsky%2FMicrosoft--Rewards--Script-informational)](https://github.com/TheNetsky/Microsoft-Rewards-Script)
[![License](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](./LICENSE)
[![Node](https://img.shields.io/badge/node-%3E%3D22-green.svg)](./package.json)
[![Arch](https://img.shields.io/badge/arch-armv7l%20%C2%B7%20aarch64%20%C2%B7%20x86__64-orange.svg)](#-平台支持)

> 把 [Microsoft-Rewards-Script](https://github.com/TheNetsky/Microsoft-Rewards-Script)（`V4-china` 分支）
> 搬到了**只有 970MB 内存的 32 位 ARM 机顶盒**（RK3229 / armv7l / Armbian）上，并配上
> **随机化无人值守调度器**，让它 7×24 自动攒积分。

本仓库 = **上游 V4-china 源码 + armv7l 适配补丁 + 无人值守调度脚本 + 完整部署文档**。

---

## 📑 目录

- [这个仓库比上游多了什么](#-这个仓库比上游多了什么)
- [平台支持](#-平台支持)
- [目录结构](#-目录结构)
- [依赖与运行环境](#-依赖与运行环境)
- [快速开始](#-快速开始)
  - [A. 通用平台（x86_64 / aarch64）](#a-通用平台x86_64--aarch64)
  - [B. RK3229 等 armv7l 弱设备](#b-rk3229-等-armv7l-弱设备)
- [配置说明](#-配置说明)
- [无人值守模式](#-无人值守模式)
- [常见问题](#-常见问题)
- [文档索引](#-文档索引)
- [同步与致谢](#-同步与致谢)
- [免责声明](#-免责声明)

---

## ✨ 这个仓库比上游多了什么

上游 V4-china 在 x86_64 上开箱可用，但直接丢到 **armv7l 会全线失败**。本仓库解决了这些问题：

### 1. armv7l 平台适配（核心）

| 问题 | 现象 | 解决方式 |
|---|---|---|
| **`impit` 无 armv7l 预编译包** | `HTTP` 层回落到 `undici`，TLS/HTTP2 指纹与真实 Chromium 不一致 → 微软返回登录页 → dashboard 永远拉不到 | 新增**浏览器网络栈桥接**：把同源请求交给真实 Chromium 的 `page.evaluate(fetch)` 执行，桥接失败才回落原后端（`src/util/Http.ts`、`src/browser/BrowserFunc.ts`、`src/index.ts`） |
| **弱设备导航超时** | `page.goto()` 默认等 `load` 事件，被挂起的第三方资源卡满 90s 超时 → 桌面搜索**开场就异常退出**（搜索次数 = 0） | 搜索/落地导航统一改为 `waitUntil: 'domcontentloaded'`（`Browser.ts`、`BrowserSearch.ts`、`BrowserSearchOnBing.ts`） |
| **Node 版本门槛** | 上游要求 `node >= 24`，Armbian 仓库只给到 22 | `engines.node` 放宽为 `>= 22.0.0`，并显式声明 `undici` 依赖 |
| **日志无 Cookie 可观测性** | 出问题只能猜「是不是没登录」 | 新增 `COOKIE-AUDIT`：每次取数打印关键 Cookie 的**来源 / 身份票据 / 缺失项 / 与浏览器实时态是否同步** |

### 2. Dashboard 取数健壮性

- **主接口失败可恢复**：降级到 flyout 后，每 10 分钟自动回探主接口，恢复即切回（原来一旦降级，**整轮**都只能用残缺的 flyout 数据）。
- **flyout 兜底带重试**：3 次尝试 + 退避，抵御 `ERR_CONNECTION_RESET` 这类瞬时网络错误。
- **报错可诊断**：flyout 被拒时明确告知原因（`isError` / `isRewardsUser=false(errorCode)` / `profile` 缺失 / 顶层键清单），不再是一句笼统文案。

### 3. 登录态判定修正

上游只看**主机名**：URL 落在 `*.bing.com` 就无条件认定「已登录」。复用陈旧会话时，页面会停在
`rewards.bing.com/dashboard` 却没有身份票据，导致：

```
rewards.bing.com/api/getuserinfo   →  返回登录页（5KB）
panelflyout/getuserinfo            →  返回匿名响应
→  Dashboard data missing from API response
→  Flyout response is missing Rewards account data
```

现在会**先校验身份票据**（`.MSA.Auth` / `tifacfaatcs`），缺失则主动回 `/auth/login` 重新换取
（最多 3 次，超限退回原行为，避免登录卡死）。

> ⚠️ 判定只能用 `.MSA.Auth` 为主：实测 **CN 市场账号即使主接口完全正常也拿不到 `tifacfaatcs`**。

### 4. 推送可观测性

`webhook.pushplus` 启用但 `token` 为空时，上游是**静默 return**（既不推送也不打日志）。
现在会打 `WARN`，并在 `channel` 疑似被误填成 token 时给出提示。

### 5. 无人值守随机化调度器（`deploy/start.sh`）

打破固定运行规律的守护脚本，详见 [无人值守模式](#-无人值守模式)。

---

## 🖥 平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| **x86_64** | ✅ 开箱可用 | 官方支持路径，`impit` 原生可用，无需桥接 |
| **aarch64** | ✅ 开箱可用 | 同上 |
| **armv7l (armhf)** | ✅ 本仓库适配 | 自动启用浏览器桥接；建议 ≥ 900MB 内存 + zswap |

实测环境：**RK3229（4×Cortex-A7，970MB RAM）+ Armbian trixie（Debian 13）+ Node 22**。

---

## 📁 目录结构

```
.
├── README.md                     ← 本文件
├── CHANGELOG.md                  ← 版本与改动历史
├── src/                          ← 源码（含 armv7l 适配补丁）
├── scripts/                      ← 上游辅助脚本（copyAssets / api / main）
├── package.json                  ← Node >= 22，含 undici 依赖
├── tsconfig.json
├── config.example.json           ← 上游通用配置模板
├── env.example                   ← 上游通用环境变量模板
├── Dockerfile / compose.yaml     ← 上游 Docker 方案（未在 armv7l 验证）
│
├── deploy/                       ← 【新增】部署与无人值守资产
│   ├── README.md                 ←   deploy 目录用法
│   ├── start.sh                  ←   ★ 无人值守守护脚本（随机调度 v5）
│   ├── run_daily.sh              ←   单轮执行器（装载 .env → 启动 node）
│   ├── deploy-rk3229.sh          ←   一键部署（装依赖 / 构建 / 配置 / 注册保活）
│   ├── check-armhf-feasibility.sh←   刷机前的可行性自检
│   ├── smoke-test-rk3229.sh      ←   部署后冒烟测试
│   ├── fix-esp8089-wifi.sh       ←   ESP8089 板载 WiFi 晶振参数修复
│   ├── config.rk3229.example.json←   针对弱设备调优的 config.json 模板
│   └── env.rk3229.example        ←   针对弱设备调优的 .env 模板
│
└── docs/                         ← 【新增】文档
    ├── MODIFICATIONS.md          ←   全部改动清单（逐文件、逐点、含原因）
    ├── DEPLOY-RK3229.md          ←   armv7l 从零部署手册
    ├── UNATTENDED-SCHEDULER.md   ←   随机化调度器设计说明
    ├── TROUBLESHOOTING.md        ←   踩坑与排障手册
    ├── ARMHF-FEASIBILITY.md      ←   32 位 ARM 可行性评估报告
    ├── UNATTENDED-REVIEW.md      ←   无人值守方案评审记录
    ├── UPSTREAM-README.md        ←   上游 README 存档
    ├── upstream-ci/              ←   上游 CI 工作流存档（本仓库不启用，见其 README）
    └── patches/
        └── armv7l-adaptation.patch  ← 相对上游的全部源码差异（可直接 git apply）
```

---

## 📦 依赖与运行环境

### 必需

| 依赖 | 版本 | 说明 |
|---|---|---|
| **Node.js** | **≥ 22.0.0** | 上游要求 24；本 fork 放宽到 22 以兼容 Debian 13 / Armbian 仓库 |
| **npm** | 随 Node | 用于安装依赖 |
| **Chromium** | 任意较新版本 | 通过 `patchright` 驱动。armv7l 上建议直接用系统包（见下） |
| **操作系统** | Linux / macOS / Windows | armv7l 验证于 Armbian trixie |

### npm 依赖

全部在 `package.json` 中声明，`npm i` 即可。关键几项：

| 包 | 作用 |
|---|---|
| `patchright` | 补丁版 Playwright（反检测），核心浏览器驱动 |
| `fingerprint-generator` / `fingerprint-injector` | 浏览器指纹生成与注入 |
| `ghost-cursor-playwright-port` | 拟人化鼠标轨迹 |
| **`undici`** | 本 fork 显式声明：armv7l 上 `impit` 不可用时的 HTTP 回落后端 |
| `impit` | 上游的 TLS 指纹伪装后端（**armv7l 无预编译包，会失败，属预期**） |
| `p-queue` / `zod` / `otpauth` / `semver` / `chalk` / `ms` / `fast-xml-parser` / `qrcode-terminal` / `ts-node` | 运行时与工具链 |

> `npm i` 在 armv7l 上会为 `impit` 打印安装失败警告 —— **这是正常的**，主流程已内置回落。
> 若 `npm i` 整体失败，可加 `--omit=optional`，或用 `deploy/deploy-rk3229.sh` 的一键流程。

### 首次运行还会需要

`patchright` 需要一份 Chromium。两种方式：

```bash
# 方式一（推荐 armv7l）：用系统包，省内存省磁盘
sudo apt install -y chromium
export CHROME_PATH=/usr/bin/chromium
export PLAYWRIGHT_BROWSERS_PATH=0

# 方式二：让 patchright 自己下载（x86_64 / aarch64 常见做法）
npx patchright install chromium
```

---

## 🚀 快速开始

### A. 通用平台（x86_64 / aarch64）

```bash
git clone <本仓库地址> && cd <仓库目录>

npm i                       # 安装依赖
npx patchright install chromium   # 若不用系统 Chromium
npx tsc                     # 编译到 dist/

cp env.example .env
cp config.example.json config.json
# 编辑 .env（账号）与 config.json（行为与推送），见「配置说明」

npm start                   # 前台跑一轮
```

### B. RK3229 等 armv7l 弱设备

> 完整流程（含刷机、内存保护、WiFi 修复）见 **[docs/DEPLOY-RK3229.md](docs/DEPLOY-RK3229.md)**。
> 这里给「已有可用 Armbian，只想把脚本跑起来」的最短路径。

```bash
# 1) 先做可行性自检（架构 / 内存 / 磁盘 / 依赖）
bash deploy/check-armhf-feasibility.sh

# 2) 一键部署（装依赖 → 构建 → 生成配置 → 注册断电保活）
sudo bash deploy/deploy-rk3229.sh

# 3) 填账号（必做，否则起不来）
sudo nano /opt/mrs/.env          # ACCOUNT_1_EMAIL / ACCOUNT_1_PASSWORD
sudo nano /opt/mrs/config.json   # 需要推送的话填 webhook.pushplus.token

# 4) 手动跑一轮验证
sudo bash /root/start.sh 8

# 5) 启动无人值守守护
sudo bash /root/start.sh 4
```

**关键环境变量**（手工跑 `node` 时必须带上，否则报 `chromium is not supported on <unknown>`）：

```bash
export PLAYWRIGHT_BROWSERS_PATH=0
export CHROME_PATH=/usr/bin/chromium
```

`deploy/run_daily.sh` 已经内置了这两个变量，所以走 `start.sh` 不需要手动设置。

---

## ⚙️ 配置说明

两套配置，**分工明确、来源不同**：

| 文件 | 管什么 | 谁读它 |
|---|---|---|
| **`.env`** | 账号（`ACCOUNT_N_*`）、日志级别等环境变量 | `run_daily.sh` 解析后 export；`src/util/Load.ts` 补缺 |
| **`config.json`** | 行为开关、搜索策略、**所有 webhook 推送** | `src/util/Load.ts::loadConfig()`，读**项目根**目录 |

### `.env`：多账号序号是坑点

```dotenv
# 账号（编号无需连续，但「辅助配置」必须用同一个编号！）
ACCOUNT_1_EMAIL=you@example.com
ACCOUNT_1_PASSWORD=your-password

# 下面这组是「账号维度」的调优项，前缀必须与上面的账号编号一致
ACCOUNT_1_LANG_CODE=zh-CN
ACCOUNT_1_GEO_LOCALE=CN
ACCOUNT_1_SAVE_FINGERPRINT_MOBILE=true
ACCOUNT_1_SAVE_FINGERPRINT_DESKTOP=true
```

> ⚠️ **最容易踩的坑**：账号序号 = `.env` 里 `ACCOUNT_N_EMAIL` 的 **N**。
> 如果你把 `ACCOUNT_1_EMAIL` 注释掉、改用 `ACCOUNT_2_EMAIL`，那么
> `ACCOUNT_1_LANG_CODE` / `ACCOUNT_1_GEO_LOCALE` / `ACCOUNT_1_SAVE_FINGERPRINT_*`
> **会全部静默失效**，账号将以 `langCode=en`、`geoLocale=auto`、不保存指纹运行。
>
> 自检命令：
> ```bash
> node -e "console.log(require('./dist/util/Load.js').loadAccounts())"
> ```

### `config.json`：推送必须写在这里

```jsonc
{
  "webhook": {
    "pushplus": {
      "enabled": true,
      "token": "你的_pushplus_token",   // ← token 放这里
      "title": "Microsoft-Rewards-Script",
      "template": "txt",
      "channel": ""                     // ← 这是推送渠道(wechat/cp/wx/mail…)，不是放 token 的地方
    }
  }
}
```

> ⚠️ **`.env` 里写 `CONFIG_PUSHPLUS_TOKEN=...` 对 MRS 无效**。
> `CONFIG_*` 环境变量**不会**自动写回 `config.json` —— 主流程从不 import
> `src/util/ConfigEnvOverrides.ts`（那是个独立 CLI）。两种正确做法：
>
> 1. **直接编辑 `config.json`**（推荐，最可靠）；
> 2. 在 `.env` 写 `CONFIG_XXX=...`，然后手动落盘：
>    ```bash
>    node dist/util/ConfigEnvOverrides.js list  --config ./config.json   # 查变量名→配置路径映射
>    node dist/util/ConfigEnvOverrides.js apply --config ./config.json   # 写回
>    ```

### 弱设备推荐配置

直接用本仓库的模板：

```bash
cp deploy/env.rk3229.example .env
cp deploy/config.rk3229.example.json config.json
```

模板相对默认值的调整（每一项都是为 970MB 内存 / 单核性能调优）：

| 配置项 | 值 | 原因 |
|---|---|---|
| `headless` | `true` | 无显示器，且 headless 更省内存 |
| `clusters` | `1` | 单账号 + 小内存，多进程只会 OOM |
| `accountDelay` | 拉长 | 弱设备单轮耗时长，避免账号间抢资源 |
| `globalTimeout` | 适中 | 兼顾慢网络与不无限挂起 |
| `searchSettings.parallelSearching` / `searchSettings.clusterSearch` | `false` | 并发搜索在弱设备上必崩 |
| `experimental.blockMedia` | `true` | 拦截图片/媒体，省内存省流量（注意路径在 `experimental` 下，不是 `searchSettings`） |
| `debugLogs` | `true` | 保留详细日志便于排障；**磁盘紧张时可改 `false`**（开启后单日日志可达十几 MB） |

### 本 fork 新增的环境变量

这几个是 armv7l 适配过程中新增的，上游没有：

| 环境变量 | 默认 | 作用 |
|---|---|---|
| `CHROME_PATH` | 空（用 patchright 自带） | 指定浏览器可执行文件。armv7l 建议 `=/usr/bin/chromium` |
| `PLAYWRIGHT_BROWSERS_PATH` | — | 设为 `0` 时只用系统浏览器，不查找 patchright 下载目录 |
| `MRS_LOW_MEMORY` | 空 | 设为 `1` 追加省内存启动参数（`--disable-gpu` 等），**≤2GB 设备建议开** |
| `MRS_CHROME_ARGS` | 空 | 追加任意 Chromium 启动参数（空格分隔），用于临时调试 |
| `MRS_HTTP_DEBUG` | 空 | 设为 `1` 把完整 HTTP 响应体落盘到 `/tmp/mrs-httpdump/`，排查接口问题用 |

> `deploy/run_daily.sh` 已经预设了 `CHROME_PATH` / `PLAYWRIGHT_BROWSERS_PATH=0` / `MRS_LOW_MEMORY=1`，
> 所以走 `deploy/start.sh` 时不需要手工设置。

---

## 🤖 无人值守模式

`deploy/start.sh` 是一个**交互菜单式守护脚本**，负责「什么时候跑、跑完怎么办、崩了怎么恢复」。

### 菜单

| 选项 | 作用 |
|---|---|
| `1` | 前台跑一轮 |
| `4` | **启动无人值守守护**（装断电保活 crontab） |
| `5` | 停止守护并卸载保活 |
| `8` | **立即跑一轮**（不占计划点，守护在跑时也能用） |
| `9` / `log` | 跟随日志 |
| `10` / `plan` | **查看当日执行计划** |

### 随机化调度（核心设计）

需求是「打破固定运行规律，降低被判定为机器人行为的风险」。做法：

- 候选锚点 `SCHED_SLOTS`（默认 `02:00,10:00,17:00`）
- 每天随机抽 `SCHED_PICK` 个（默认 2 个）
- 每个锚点再随机延迟 `SCHED_DELAY_MAX` 分钟内（默认 0–60 分钟）执行
- 两个执行点之间保证 `SCHED_MIN_GAP`（默认 30 分钟）最小间隔

**关键设计**：

- **确定性伪随机**：用 `sha256(salt|日期|序号)` 取模，而不是 `$RANDOM`。
  这样**同一天内任意时刻、任意进程、任意重启后算出的计划完全一致**，跨天自动变。
- **计划落盘**：`/opt/mrs/.unattended/schedule.plan`（不放 `/tmp`），断电重启可恢复，且保留 `done` / `missed` 状态。
- **原子认领**：**先标记 `done` 再执行**，中途被 kill 也不会重复触发。
- **跨午夜正确**：分钟刻度 ≥ 1440 会自动落到次日（`23:30 + 55分` = 次日 `00:25`）。
- **手动与自动互不干扰**：选项 8 走独立的 `do_run_now()`，**不取守护锁、不读写计划文件**，只用
  `is_mrs_running` 判断真冲突。
- **并发保护**：`flock` 单实例锁，重复启动直接让位。

### 日志关键行

```
[计划] 当日执行计划(日期=2026-09-25 | 候选=02:00,10:00,17:00 | 抽取=2(固定) | 延迟=0~60分钟 | 最小间隔=30分钟)
       #1 锚点10:00 + 延迟45分钟 → 2026-09-25 10:45:00 [pending]
       #2 锚点17:00 + 延迟19分钟 → 2026-09-25 17:19:00 [pending]
下次自动执行: 2026-09-25 10:45:00 (锚点10:00 + 延迟45分钟, 24764秒后)
===== 到达计划执行点 #1 =====
[计划] 计划时刻=2026-09-25 10:45:00 | 锚点=10:00 | 随机延迟=45分钟
[计划] 实际触发时刻=2026-09-25 10:50:08 | 与计划偏差=308秒
```

### 可配置项

| 变量 | 默认 | 含义 |
|---|---|---|
| `SCHED_SLOTS` | `02:00,10:00,17:00` | 候选锚点（`HH:MM`，逗号分隔） |
| `SCHED_PICK` | `2` | 数字 = 固定抽 N 个；`variable` = 在 `[1, PICK_MAX]` 随机 |
| `SCHED_PICK_MAX` | `2` | `variable` 模式的随机上限 |
| `SCHED_DELAY_MAX` | `60` | 每锚点的额外随机延迟，`[0, N]` 分钟 |
| `SCHED_MIN_GAP` | `30` | 两执行点最小间隔（分钟） |
| `SCHED_SEED_SALT` | `mrs-rk3229` | 伪随机种子盐值（改动会重新洗牌） |
| `SCHED_FALLBACK` | `false` | `true` = 退回「每天固定单点」模式（逃生阀） |

详细设计与边界处理见 **[docs/UNATTENDED-SCHEDULER.md](docs/UNATTENDED-SCHEDULER.md)**。

---

## 🔧 常见问题

**Q：`chromium is not supported on <unknown>`**
手工跑 `node dist/index.js` 时缺环境变量。补上：
```bash
export PLAYWRIGHT_BROWSERS_PATH=0
export CHROME_PATH=/usr/bin/chromium
```

**Q：`impit 原生模块在当前平台不可用（无 armv7l 预编译包），已回落到 fetch 后端`**
这是**预期行为**，不是错误。此时会自动启用浏览器桥接，用真实 Chromium 的网络栈取数。

**Q：dashboard 拉不到、`Flyout response is missing Rewards account data`**
先用 Cookie 审计定位：
```bash
grep "COOKIE-AUDIT" logs/run-$(date +%Y%m%d).log | tail -3
```
重点看 `身份=`（应为 `MSA=...` 而不是 `MUID=...`）和 `rewards关键=n/3`。
若身份票据缺失，删掉陈旧会话强制重新登录：
```bash
rm -f sessions/sessions.db      # 或只删对应账户行
```

**Q：配置改了不生效**
- 两个配置文件都是**进程启动时从磁盘读**，所以**改完不用重启守护，下一轮自动生效**；
- 但**正在跑的那一轮用旧值**；
- `config.json` 必须是**合法 JSON**（MRS 只认 `config.json`，不认 `config.ini`）。

**Q：`已有无人值守实例在运行`**
守护用 `flock` 锁 `/tmp/mrs_unattended.lock`，且 fd 会被子进程继承。
若守护被 `kill -9`，遗留的 `sleep` 仍持有该锁：
```bash
ls -l /proc/*/fd/* | grep mrs_unattended    # 找到持锁进程
kill <那个子进程>; rm -f /tmp/mrs_unattended.lock
```

**Q：想临时回到「每天固定一个时间点」跑**
```bash
SCHED_FALLBACK=true bash /root/start.sh 4
```

更多排障见 **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**。

---

## 📚 文档索引

| 文档 | 内容 |
|---|---|
| [docs/MODIFICATIONS.md](docs/MODIFICATIONS.md) | **全部改动清单**：逐文件、逐点、含原因与验证方式 |
| [docs/DEPLOY-RK3229.md](docs/DEPLOY-RK3229.md) | armv7l 从零部署手册（刷机 → 依赖 → 配置 → 保活） |
| [docs/UNATTENDED-SCHEDULER.md](docs/UNATTENDED-SCHEDULER.md) | 随机化调度器设计、边界处理、配置项 |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | 踩坑与排障手册 |
| [docs/ARMHF-FEASIBILITY.md](docs/ARMHF-FEASIBILITY.md) | 32 位 ARM 可行性评估（含内存/性能实测） |
| [docs/UNATTENDED-REVIEW.md](docs/UNATTENDED-REVIEW.md) | 无人值守方案评审记录 |
| [docs/patches/armv7l-adaptation.patch](docs/patches/armv7l-adaptation.patch) | 相对上游的完整源码差异补丁 |
| [docs/UPSTREAM-README.md](docs/UPSTREAM-README.md) | 上游 README 存档（完整配置项说明） |
| [deploy/README.md](deploy/README.md) | 部署脚本用法 |

---

## 📜 同步与致谢

| | |
|---|---|
| 上游项目 | [TheNetsky/Microsoft-Rewards-Script](https://github.com/TheNetsky/Microsoft-Rewards-Script) |
| 本 fork 的直接基线 | [chiihero/Microsoft-Rewards-Script](https://github.com/chiihero/Microsoft-Rewards-Script) `V4-china` 分支（版本 `4.3.2.3`） |
| 本仓库新增 | armv7l 适配 + 通用健壮性修复 + 无人值守随机调度器 + 部署文档 |

相对基线的源码差异见 [`docs/patches/armv7l-adaptation.patch`](docs/patches/armv7l-adaptation.patch)，
逐项说明见 [`docs/MODIFICATIONS.md`](docs/MODIFICATIONS.md)。

---

## ⚠️ 免责声明

- 本项目仅用于**个人学习与技术研究**。
- 使用自动化工具操作微软账号**可能违反 Microsoft 服务条款**，存在账号被限制的风险，**请自行评估并承担后果**。
- 请勿用于商业用途、批量刷号或任何形式的滥用。
- 作者不对因使用本项目导致的账号封禁、积分清零、数据丢失或任何其他损失负责。
- 本项目基于 GPL-3.0-or-later 许可，继承上游全部许可条款。
