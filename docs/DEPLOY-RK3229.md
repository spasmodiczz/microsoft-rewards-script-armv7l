# 部署手册：RK3229 / armv7l

> 目标：一台只有 **970MB 内存**的 32 位 ARM 机顶盒，7×24 无人值守自动攒微软积分。
> 本文是**从零到跑起来**的完整流程，包含所有踩过的坑。

实测硬件 / 系统：

| 项 | 值 |
|---|---|
| SoC | RK3229（4×Cortex-A7，armv7l / armhf） |
| 内存 | 970 MB |
| 系统 | Armbian trixie（Debian 13） |
| Node | 22.x（armv7l 官方二进制上限） |
| 浏览器 | Debian armhf 版 Chromium（`/usr/bin/chromium`） |
| 存储 | eMMC / SD，建议 ≥ 4GB 可用空间 |

---

## 目录

- [0. 先做可行性自检](#0-先做可行性自检)
- [1. 一键部署](#1-一键部署)
- [2. 配置账号](#2-配置账号)
- [3. 冒烟测试](#3-冒烟测试)
- [4. 切到无人值守调度](#4-切到无人值守调度)
- [5. 断电保活](#5-断电保活)
- [6. 手工部署（不使用一键脚本）](#6-手工部署不使用一键脚本)
- [附：板载 WiFi（ESP8089）修复](#附板载-wifiesp8089修复)

---

## 0. 先做可行性自检

刷完系统、能上网之后，**先跑自检**，确认硬件不会在关键时刻掉链子：

```bash
scp deploy/check-armhf-feasibility.sh root@<设备IP>:/root/
ssh root@<设备IP> 'bash /root/check-armhf-feasibility.sh'
```

它会检查：架构、内存、swap/zswap、磁盘余量、Node 是否存在、Chromium 是否存在、内核参数。

**判读要点**：

| 指标 | 要求 | 不满足会怎样 |
|---|---|---|
| 内存 | **≥ 900MB** | Chromium 峰值可达 650MB，内存不够会被 OOM Killer 杀掉 |
| swap / zswap | **必须有**（zswap 或 zram） | 同上。970MB 裸跑很勉强 |
| 可用磁盘 | **≥ 2GB** | npm 依赖 + Chromium + 日志 |
| Chromium | 可执行 | 没有就 `apt install -y chromium` |

> 自检报告里如果提示内存偏小，**先解决内存再继续**，否则后面所有问题都会表现为「莫名其妙的崩溃」。

---

## 1. 一键部署

```bash
# 把仓库放到设备上（或用 git clone）
scp -r . root@<设备IP>:/root/mrs-src

ssh root@<设备IP>
cd /root/mrs-src
sudo bash deploy/deploy-rk3229.sh
```

脚本做 8 件事：

| 步骤 | 内容 |
|---|---|
| `[1/8]` | 环境检查（架构 / 内存） |
| `[2/8]` | **内存保护**：开启 zswap（并写入 `/boot/armbianEnv.txt` 持久化，改前自动备份） |
| `[3/8]` | 安装 **Node.js 22**（armv7l 官方二进制的上限就是 22.x） |
| `[4/8]` | 安装 **Chromium**（用 Debian armhf 官方包，**不要自己编译**） |
| `[5/8]` | 部署项目到 `/opt/mrs`，`npm install --ignore-scripts` + `npm run build` |
| `[6/8]` | 生成**已降配**的 `config.json` / `.env` |
| `[7/8]` | 崩溃防护：禁用 core dump、限制 journal 日志体积、生成 `mrs-run.sh` 包装器 |
| `[8/8]` | 注册 `mrs.timer`（systemd 定时器，每天 `RUN_HOUR` 点跑） |

> **关于 `npm install --ignore-scripts`**：armhf 上 `patchright` 的浏览器下载脚本会失败（没有对应构建），
> 所以跳过 scripts，改用系统 Chromium。这是**有意为之**，不是错误。

### 关键降配项（都写进 `config.json` 了）

| 配置 | 值 | 为什么 |
|---|---|---|
| `clusters` | `1` | 单进程，不多开 |
| `parallelSearching` | `false` | 不同时开多个搜索页 |
| `clusterSearch` | `false` | 不并行多标签 |
| `searchDelay` | `1–2min` | **重点**：模板默认的 6–12min 会让单账号跑 **9 小时以上** |
| `readDelay` | `1–2min` | ReadToEarn 有 10 篇文章，同理 |
| `experimental.blockMedia` | `true` | 阻断图片/音视频，明显省内存和带宽（路径在 `experimental` 下） |
| `debugLogs` | `true` | 详细日志，便于排障；磁盘紧张时改 `false` |
| `globalTimeout` | `90sec` | 实测单页 15.6 秒、首次更慢，默认 30 秒不够 |

---

## 2. 配置账号

一键脚本生成的配置里**账号是空的**，必须自己填：

```bash
nano /opt/mrs/.env
```

```dotenv
ACCOUNT_1_EMAIL=you@example.com
ACCOUNT_1_PASSWORD=your-password

# 国内账号强烈建议一起设置（前缀必须与账号编号一致！）
ACCOUNT_1_LANG_CODE=zh-CN
ACCOUNT_1_GEO_LOCALE=CN
ACCOUNT_1_SAVE_FINGERPRINT_MOBILE=true
ACCOUNT_1_SAVE_FINGERPRINT_DESKTOP=true
```

> ⚠️ **账号序号坑**：账号序号 = `ACCOUNT_N_EMAIL` 的 **N**。
> 用 `ACCOUNT_2_EMAIL` 就必须把辅助项也改成 `ACCOUNT_2_*`，否则它们**静默失效**。
> 自检：
> ```bash
> cd /opt/mrs && node -e "console.log(require('./dist/util/Load.js').loadAccounts())"
> ```

要推送的话，**必须改 `config.json` 而不是 `.env`**：

```bash
nano /opt/mrs/config.json     # webhook.pushplus.token = "你的token"
```

> `.env` 里的 `CONFIG_PUSHPLUS_TOKEN` 对 MRS **无效**（`CONFIG_*` 不会自动写回 `config.json`）。
> 详见 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)。

---

## 3. 冒烟测试

```bash
sudo bash deploy/smoke-test-rk3229.sh
```

或手工跑一轮（**必须带环境变量**，否则报 `chromium is not supported on <unknown>`）：

```bash
cd /opt/mrs
export PLAYWRIGHT_BROWSERS_PATH=0
export CHROME_PATH=/usr/bin/chromium
export MRS_LOW_MEMORY=1
node dist/index.js
```

**通过标准**（看 `logs/run-$(date +%Y%m%d).log`）：

```
[RUN-START] 启动微软奖励脚本 | 账户数: 1 | 集群数: 1
[ACCOUNT-START] 开始处理账户: ... | geoLocale: CN | locale: zh-CN
[COOKIE-AUDIT] ... | 身份=MSA=... | rewards关键=3/3 | 仪表板=primary
[HTTP-BRIDGE] 预热后 GET https://rewards.bing.com/api/getuserinfo -> 200 | 长度=630092
[GET-DASHBOARD-DATA] serpbotscore 取值 | 数据源=primary | 分数=0.79
[SEARCH-BING] 获得积分=3 | 当前余额=...
[RUN-END] 全部账户完成 | 获得积分=... | 运行分钟数=...
```

**不通过时优先看这三个**：

| 现象 | 去看 |
|---|---|
| `数据源=flyout` / `serpbotscore=未解析` | `COOKIE-AUDIT` 的 `身份` 是不是 `MSA=`；不是就是登录态问题 |
| `HTTP-BRIDGE ... 长度=5166` | 桥接拿到了登录页 → 同上 |
| `搜索次数=0` | 导航超时；确认已应用本仓库的 `domcontentloaded` 补丁 |

> ⚠️ **控制台会吞掉 `[ERROR]` 行**，排查一律看 `logs/run-YYYYMMDD.log`，不要只看终端。

---

## 4. 切到无人值守调度

一键脚本注册的是 `mrs.timer`（每天固定一点）。**本仓库推荐改用 `deploy/start.sh` 的随机调度**：

```bash
cp deploy/start.sh /root/start.sh
chmod +x /root/start.sh

# 选项 4：启动守护 + 装断电保活
# 它会自动 disable 掉 mrs.timer，避免双重调度
sudo bash /root/start.sh 4
```

它会打印当日生成的随机计划：

```
[计划] 当日执行计划(日期=2026-09-25 | 候选=02:00,10:00,17:00 | 抽取=2(固定) | 延迟=0~60分钟 | 最小间隔=30分钟)
       #1 锚点10:00 + 延迟45分钟 → 2026-09-25 10:45:00 [pending]
       #2 锚点17:00 + 延迟19分钟 → 2026-09-25 17:19:00 [pending]
```

常用命令：

```bash
bash /root/start.sh        # 菜单
bash /root/start.sh 10     # 查看当日执行计划
bash /root/start.sh 8      # 立即补跑一轮（不占计划点）
bash /root/start.sh log    # 跟随日志
bash /root/start.sh 5      # 停止守护
```

详见 [UNATTENDED-SCHEDULER.md](UNATTENDED-SCHEDULER.md)。

---

## 5. 断电保活

`start.sh` 选项 4 会自动安装**幂等**的 crontab 保活条目：

```cron
# MRS unattended guard (managed by start.sh 4)
@reboot sleep 30 && bash /root/start.sh 4 >/dev/null 2>&1
*/10 * * * * bash /root/start.sh 4 >/dev/null 2>&1
```

- `@reboot` + 30 秒延迟：设备断电重启后自动恢复守护；
- `*/10`：每 10 分钟自检一次，守护意外退出会被拉起来（`flock` 保证不会重复跑）。

**核对**：

```bash
crontab -l | grep -c "^@reboot"      # 应为 1
crontab -l | grep -c "^\*/10"        # 应为 1
systemctl is-enabled mrs.timer       # 应为 disabled
pgrep -af "start[.]sh 4"             # 应有守护进程
```

---

## 6. 手工部署（不使用一键脚本）

如果不想跑一键脚本，按下面步骤来。

### 6.1 系统依赖

```bash
sudo apt update
sudo apt install -y curl xz-utils chromium cron

# Node 22（armv7l 官方二进制）
cd /tmp
curl -fLO https://nodejs.org/dist/v22.23.3/node-v22.23.3-linux-armv7l.tar.xz
sudo mkdir -p /usr/local/lib/nodejs
sudo tar -xJf node-v22.23.3-linux-armv7l.tar.xz -C /usr/local/lib/nodejs
sudo ln -sf /usr/local/lib/nodejs/node-v22.23.3-linux-armv7l/bin/node /usr/local/bin/node
sudo ln -sf /usr/local/lib/nodejs/node-v22.23.3-linux-armv7l/bin/npm  /usr/local/bin/npm
node -v
```

### 6.2 内存保护（970MB 必须）

```bash
# 立即生效
echo Y   | sudo tee /sys/module/zswap/parameters/enabled
echo lz4 | sudo tee /sys/module/zswap/parameters/compressor
echo 20  | sudo tee /sys/module/zswap/parameters/max_pool_percent

# 持久化
echo 'zswap.enabled=1 zswap.compressor=lz4 zswap.max_pool_percent=20' | sudo tee -a /boot/armbianEnv.txt
```

### 6.3 构建

```bash
sudo mkdir -p /opt/mrs && sudo chown "$USER" /opt/mrs
cd /opt/mrs
# 把本仓库内容放这里
npm install --ignore-scripts --no-audit --no-fund
npm run build        # 或 npx tsc
```

### 6.4 配置

```bash
cp deploy/env.rk3229.example .env
cp deploy/config.rk3229.example.json config.json
# 然后编辑这两个文件填账号 / token
```

### 6.5 运行

```bash
export PLAYWRIGHT_BROWSERS_PATH=0
export CHROME_PATH=/usr/bin/chromium
export MRS_LOW_MEMORY=1
node dist/index.js
```

---

## 附：板载 WiFi（ESP8089）修复

RK3229 盒子普遍用 **ESP8089** 做板载 WiFi。**晶振参数写错会导致整机假死**，
必须注意。

权威映射见 `modinfo esp8089`：

| `crystal` 值 | 对应晶振 |
|---|---|
| `0` | **40 MHz**（驱动默认） |
| `1` | **26 MHz** |
| `2` | **24 MHz** |

> 常见错误：抄了别人的 `crystal=2`（24MHz），而本机是 26MHz → 握手超时
> `esp_init_all failed: -110` → probe Oops → 反复重试拖死 MMC → **整机假死**。

排查/修复脚本：

```bash
bash deploy/fix-esp8089-wifi.sh diag      # 诊断当前参数与 dmesg
bash deploy/fix-esp8089-wifi.sh fix       # 写入正确的 crystal 值
bash deploy/fix-esp8089-wifi.sh connect   # 连接 WiFi
bash deploy/fix-esp8089-wifi.sh verify    # 验证
```

> `no_auto_sleep` 在 6.x 内核已不存在，写了会被 ignore，不要写。

**建议**：生产环境用**有线网**（更稳、延迟更低）。WiFi 只作备份。
