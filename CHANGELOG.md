# 改动历史

本文件记录本仓库（armv7l 适配 fork）相对上游基线的**版本级改动**。
逐文件、逐点的详细说明见 [`docs/MODIFICATIONS.md`](docs/MODIFICATIONS.md)。

- **基线**：[`chiihero/Microsoft-Rewards-Script`](https://github.com/chiihero/Microsoft-Rewards-Script) `V4-china` 分支，版本 `4.3.2.3`
- **完整补丁**：[`docs/patches/armv7l-adaptation.patch`](docs/patches/armv7l-adaptation.patch)

---

## [armv7l-1.0] — 2026-09-25

首次发布：把 V4-china 适配到 RK3229（armv7l）并配上随机化无人值守调度。

### 新增：armv7l 平台适配

- **浏览器网络栈桥接**（`src/util/Http.ts`、`src/browser/BrowserFunc.ts`、`src/index.ts`）
  - 根问题：`impit` 无 armv7l 预编译包 → HTTP 层回落 `undici` → TLS 指纹与 Chromium 不一致 → 微软返回登录页
  - 方案：把同源请求交给真实 Chromium 的网络栈执行（`page.evaluate(fetch)`），桥接失败时自动回落原后端
  - 新增跨后端响应契约 `HttpResponseLike` / `HttpFetcher`，并把 `impit` 降级为可选依赖
- **弱设备导航超时修复**（`Browser.ts`、`BrowserSearch.ts`、`BrowserSearchOnBing.ts`）
  - `page.goto()` 默认等 `load` 事件，被挂起的第三方资源卡满 90s 超时 → 桌面搜索开场即异常退出（搜索次数=0）
  - 统一改为 `waitUntil: 'domcontentloaded'`；实测每次搜索稳定 +3 分
- **浏览器启动参数可配置**（`src/browser/Browser.ts`）
  - 新增 `CHROME_PATH`（用系统 Chromium，armv7l 必需）
  - 新增 `MRS_LOW_MEMORY=1`（追加省内存启动参数）
  - 新增 `MRS_CHROME_ARGS`（追加任意启动参数，调试用）

### 新增：Dashboard 取数健壮性

- **主接口降级可恢复**（`BrowserFunc.ts`）：降级到 flyout 后每 10 分钟自动回探主接口，恢复即切回
  （原实现一旦降级，**整轮**都只能用残缺的 flyout 数据）
- **flyout 兜底带重试**（`BrowserFunc.ts`）：3 次尝试 + `3s/6s` 退避，抵御 `ERR_CONNECTION_RESET` 类瞬时错误（原实现零重试）
- **flyout 报错可诊断**（`FlyoutDashboard.ts`）：新增 `buildFlyoutRejectionMessage()`，
  拆出 `isError` / `isRewardsUser=false(errorCode)` / `profile` 缺失 / 顶层键清单（原来只有一句笼统文案）

### 修复：登录态判定

- `src/browser/auth/Login.ts`：新增 `hasAuthIdentity()`，在「假设已登录」前校验 `.MSA.Auth` / `tifacfaatcs`
  - 原实现只看主机名，URL 落在 `*.bing.com` 就认定已登录 → 复用陈旧会话时**登录流程被整个跳过**，
    服务端从未下发身份票据 → dashboard 全线失败
  - 缺票据时主动回 `/auth/login` 重新换取，最多 3 次；超限退回原行为，避免登录卡死
  - **注意**：判定只能以 `.MSA.Auth` 为主 —— 实测 CN 市场账号即使主接口完全正常也拿不到 `tifacfaatcs`

### 新增：可观测性

- **`COOKIE-AUDIT` Cookie 审计**（`BrowserFunc.ts`）：每次取数打印关键 Cookie 的
  来源 / 身份票据 / 缺失项 / 与浏览器实时态是否同步 / 指纹是否跨账户串号
- **`serpbotscore` 双路径解析**（`BrowserFunc.ts`）：兼容两处等价路径与 flyout 侧大小写写法，
  并区分「字段未下发」与「匿名兜底」
- **pushplus 未配置不再静默失败**（`index.ts`）：启用但 token 为空时打 `WARN`，
  并在 `channel` 疑似被误填成 token 时给出定向提示

### 新增：无人值守随机化调度器（`deploy/start.sh` v5）

- 每天从候选锚点随机抽 1~2 个，每个再叠加 0~60 分钟随机延迟，保证最小间隔
- **确定性伪随机**：`sha256(salt|日期|序号)` 取模（不是 `$RANDOM`），同一天任意进程/重启后结果一致
- **计划落盘**：`$BASE/.unattended/schedule.plan`（不放 `/tmp`，断电可恢复），按日期校验，保留 `done`/`missed`
- **原子认领**：先标记 `done` 再执行，中途被 kill 也不会重复触发
- **锁分离**：选项 8（立即跑一轮）走独立 `do_run_now()`，不取守护锁、不读写计划文件
- **crontab 幂等**：修复旧版标记串不匹配导致的保活条目无限膨胀

### 变更：依赖与工程

- `package.json`：`engines.node` 由 `>=24.0.0` 放宽为 `>=22.0.0`（Debian 13 / Armbian 仓库上限）
- `package.json`：显式声明 `undici` 依赖（armv7l 上 `impit` 不可用时实际生效的 HTTP 后端）
- `package-lock.json`：同步重新生成
- `.gitignore`：取消忽略 `/docs`；新增忽略 `.env.rk3229`、`deploy/` 运行期产物与 `*.log`/`*.tgz`
- **上游 CI 工作流移出 `.github/workflows/`**：三个工作流全部绑定上游的 `v3`/`v4` 分支
  （本仓库是 `main`，永不触发），且推送工作流文件需要额外的 `Workflows` 权限。
  文件原样保留在 [`docs/upstream-ci/`](docs/upstream-ci/) 供参考，恢复方式见该目录 README。

### 新增：部署资产与文档

- `deploy/deploy-rk3229.sh`：一键部署（装 Node 22 / Chromium、开 zswap、构建、生成降配配置、崩溃防护、注册定时器）
- `deploy/check-armhf-feasibility.sh`：刷机后可行性自检
- `deploy/run_daily.sh`：单轮执行器（逐行解析 `.env`，内置浏览器环境变量）
- `deploy/smoke-test-rk3229.sh`：部署后冒烟测试
- `deploy/fix-esp8089-wifi.sh`：板载 WiFi 晶振参数修复
- `deploy/env.rk3229.example` / `deploy/config.rk3229.example.json`：弱设备配置模板（已脱敏）
- `docs/`：README、改动清单、部署手册、调度器说明、排障手册、可行性评估、评审记录

---

## 上游同步

本仓库基于 `V4-china`（`4.3.2.3`）修改。上游更新后，可用补丁重放：

```bash
git remote add upstream https://github.com/chiihero/Microsoft-Rewards-Script.git
git fetch upstream V4-china
git checkout -b sync upstream/V4-china
git apply docs/patches/armv7l-adaptation.patch    # 有冲突则逐个解决
```

> 补丁集中在 8 个源文件，冲突面很小。

---

## 图例

| 标记 | 含义 |
|---|---|
| 新增 | 本仓库新加的能力 |
| 修复 | 修正上游的行为缺陷 |
| 变更 | 修改了上游的既有行为或元数据 |
