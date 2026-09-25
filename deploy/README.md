# deploy/ —— 部署与无人值守资产

这个目录放的是**跑在设备上**的东西：一键部署脚本、运行时执行器、无人值守守护、以及针对弱设备的配置模板。

---

## 文件一览

| 文件 | 跑在哪 | 作用 |
|---|---|---|
| `deploy-rk3229.sh` | 设备（root） | **一键部署**：装 Node/Chromium → 开 zswap → 构建 → 生成降配配置 → 崩溃防护 → 注册 `mrs.timer` |
| `check-armhf-feasibility.sh` | 设备 | **刷机后先跑这个**：检查架构/内存/swap/磁盘/依赖是否达标 |
| `smoke-test-rk3229.sh` | 设备 | 部署后冒烟测试：逐项验证环境与关键依赖 |
| `start.sh` | 设备 | **无人值守守护**（随机调度 v5）+ 交互式管理菜单 |
| `run_daily.sh` | 设备 | **单轮执行器**：装载 `.env` → 设置浏览器环境变量 → 启动 `node dist/index.js` → 解析结果 |
| `fix-esp8089-wifi.sh` | 设备 | 修复 RK3229 板载 ESP8089 WiFi 的晶振参数 |
| `env.rk3229.example` | → `.env` | 弱设备调优的环境变量模板 |
| `config.rk3229.example.json` | → `config.json` | 弱设备调优的配置文件模板 |

---

## 推荐流程

```bash
# ── 在开发机上：把仓库送到设备 ──────────────────────────────
scp -r . root@<设备IP>:/root/mrs-src

# ── 在设备上 ───────────────────────────────────────────────
ssh root@<设备IP>
cd /root/mrs-src

# 1) 可行性自检（强烈建议先跑）
bash deploy/check-armhf-feasibility.sh

# 2) 一键部署（装依赖 + 构建 + 生成配置 + 注册 mrs.timer）
bash deploy/deploy-rk3229.sh

# 3) 填账号（必做）
nano /opt/mrs/.env              # ACCOUNT_1_EMAIL / ACCOUNT_1_PASSWORD
nano /opt/mrs/config.json       # 需要推送则填 webhook.pushplus.token

# 4) 冒烟测试
bash deploy/smoke-test-rk3229.sh

# 5) 切换到本仓库推荐的随机化无人值守调度
cp deploy/start.sh /root/start.sh && chmod +x /root/start.sh
bash /root/start.sh 4          # 会自动 disable 掉 mrs.timer，避免双重调度
```

---

## `start.sh` 交互菜单

```bash
bash /root/start.sh        # 菜单
bash /root/start.sh 4      # 启动无人值守守护（+ 断电保活）
bash /root/start.sh 5      # 停止守护（+ 卸载保活）
bash /root/start.sh 8      # 立即跑一轮（不占计划点）
bash /root/start.sh 10     # 查看当日执行计划
bash /root/start.sh log    # 跟随日志
```

完整说明见 [`../docs/UNATTENDED-SCHEDULER.md`](../docs/UNATTENDED-SCHEDULER.md)。

### 与 `mrs.timer` 的关系

`deploy-rk3229.sh` 注册的是 **systemd timer**（每天固定一点跑）。
`start.sh` 用的是**随机化调度 + crontab 保活**，两者会**双重调度**。

`start.sh` 启动守护时会自动执行 `ensure_no_systemd_timer()`，把 `mrs.timer` 停掉：

```
[*] 已停用 mrs.timer,避免与 start.sh 的随机调度双跑
```

所以推荐流程是：**先用一键脚本装好环境，再切到 `start.sh`**。

---

## `run_daily.sh` 会设置的环境变量

这是**手工跑 `node` 时报 `chromium is not supported on <unknown>` 的原因** ——
这些变量必须带上：

| 变量 | 默认 | 作用 |
|---|---|---|
| `PLAYWRIGHT_BROWSERS_PATH` | `0` | 只用系统浏览器，不找 patchright 下载目录 |
| `CHROME_PATH` | `/usr/bin/chromium` | 浏览器可执行路径（不存在时自动探测常见位置） |
| `MRS_LOW_MEMORY` | `1` | 追加省内存启动参数（`--disable-gpu` 等） |
| `MRS_CHROME_ARGS` | 空 | 追加任意 Chromium 参数，调试用 |

另外 `run_daily.sh` 会用**逐行解析**的方式载入 `/opt/mrs/.env`（不用 `source`），
避免密码里的 `!`、`#`、`$`、`&` 被 shell 解释。

---

## 相关文档

- [从零部署到 armv7l](../docs/DEPLOY-RK3229.md)
- [无人值守随机调度器](../docs/UNATTENDED-SCHEDULER.md)
- [排障手册](../docs/TROUBLESHOOTING.md)
- [改动清单](../docs/MODIFICATIONS.md)
