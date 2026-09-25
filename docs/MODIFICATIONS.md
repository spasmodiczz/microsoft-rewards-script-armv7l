# 改动清单（相对上游 V4-china）

本文件逐项说明本仓库相对基线所做的**全部源码改动**。

- **基线**：[`chiihero/Microsoft-Rewards-Script`](https://github.com/chiihero/Microsoft-Rewards-Script) 的 `V4-china` 分支，版本 `4.3.2.3`
- **补丁**：[`docs/patches/armv7l-adaptation.patch`](patches/armv7l-adaptation.patch)（可直接 `git apply`）
- **改动规模**：`src/` 下 **8 个文件**，`+1030 / -65` 行；另有 `package.json` 与 `.gitignore` 微调

```
src/browser/Browser.ts                                     +23    -2
src/browser/BrowserFunc.ts                                 +615   -40
src/browser/FlyoutDashboard.ts                             +39    -2
src/browser/auth/Login.ts                                  +68    -1
src/functions/activities/search/BrowserSearch.ts           +20    -4
src/functions/activities/search/BrowserSearchOnBing.ts     +2     -2
src/index.ts                                               +26    -1
src/util/Http.ts                                           +237   -13
package.json                                               +2     -1
```

改动分五类：**① armv7l 平台适配**、**② Dashboard 取数健壮性**、**③ 登录态判定**、**④ 可观测性**、**⑤ 依赖与工程**。

---

## ① armv7l 平台适配

### 1.1 根问题：`impit` 没有 armv7l 预编译包

`impit` 是上游用来做 **TLS/HTTP2 指纹伪装**的 HTTP 后端，只发布了 `x86_64` 与 `aarch64` 的原生二进制。
在 armv7l 上 `require('impit')` 直接抛错，HTTP 层回落到 `undici`/`fetch`。

后果很具体：**TLS 指纹与真实 Chromium 不一致，微软会把 `rewards.bing.com` 的请求判定为未登录**，
`/api/getuserinfo` 返回一个约 5KB 的登录页（正常响应约 630–750KB），`panelflyout/getuserinfo` 返回匿名响应。

**解决：浏览器网络栈桥接（Browser Network-Stack Bridge）**

既然 TLS 指纹对不上，那就**让请求真的走 Chromium 的网络栈**。

#### `src/util/Http.ts`（+237 / -13）

| 改动 | 说明 |
|---|---|
| 移除顶层 `import { Impit } from 'impit'` | 改为运行时 `require`，并把 `impit` 降级为**可选**（type-only import） |
| 新增 `HttpHeadersLike` / `HttpResponseLike` / `HttpFetcher` 契约 | 把「响应」抽象成 `impit` 与 `fetch` 都能满足的最小接口，上层（重试 / 解析 / 状态码判定）与后端解耦 |
| 新增 `BrowserBridgeResult` / `BrowserBridgeFetch` 类型 | 桥接函数签名：接收 `url + init`，返回 `{status, statusText, text} \| null` |
| 新增 `makeBridgedResponse()` | 把桥接结果包装成 `HttpResponseLike`，让上层无感 |
| 新增 `wrapWithBrowserBridge()` | 给任意后端套一层桥接：**桥接返回 `null` 时自动回落原后端**，桥接抛错也不影响主流程 |
| 新增 `setBrowserBridge(bridge \| null)` | 运行时注入/移除桥接。`bridge` 为 `null` 时恢复为原后端 |
| 新增 `backend` 只读属性 | 暴露当前后端是 `'impit'` 还是 `'fetch'`，供上层判断是否需要桥接 |
| impit 加载失败时回落 `fetch` 后端 | 不再让 `require` 抛错冒泡 |

#### `src/browser/BrowserFunc.ts`（+615 / -40）

这是改动最大的文件，桥接的浏览器侧实现都在这里。

| 新增 | 说明 |
|---|---|
| `createBrowserBridge()` | 对外暴露的桥接工厂，返回 `BrowserBridgeFetch`；由 `index.ts` 注入到 `Http` |
| `ensureBridgePage()` | **惰性创建专用于 API 取数的页面**，避免打断主页面（搜索 / 活动）的浏览状态。页面关闭或上下文变更时自动重建 |
| 三段式取数流程 | ① **快路径**：若已预热过该源，直接在页面内 `fetch`；② **预热**：先 `goto(targetOrigin)` 建立会话，再 `goto(url)`；③ **兜底**：直接读顶层导航渲染出的响应体（仅当 `以 { / [ 开头` 或 `长度 > 20000` 时才认为是真响应） |
| `looksLikePayload` 判定 | 防止把 5KB 的登录页当成 API 数据（这正是「假成功」的防线） |

**为什么需要「预热」**：新上下文（例如刚登录的桌面端）直接打接口会被服务端判定为未登录并重定向到登录页，
必须先加载一个常规页面把会话 Cookie 建立起来。

`src/index.ts` 中的注入点：

```ts
// armv7l 等无 impit 预编译包的平台会回落到 undici，TLS 指纹与浏览器不一致，
// 微软会拒绝返回 dashboard。此时把同源请求桥接到真实 Chromium 网络栈。
if (this.http.backend === 'fetch') {
    this.http.setBrowserBridge(this.browser.func.createBrowserBridge())
    this.logger.info('main', 'HTTP-BRIDGE',
        'impit 不可用（非 x86_64/aarch64 平台），已启用浏览器网络栈桥接以绕过 TLS 指纹识别')
}
```

### 1.2 弱设备导航超时：`load` 事件等不起

`page.goto()` 默认等 `load` 事件。在 RK3229 上，挂起的第三方资源会让它**卡满 90 秒导航超时**
→ 桌面搜索会话**开场就异常退出**，表现为「搜索次数 = 0、0 积分」。

| 文件 | 改动 |
|---|---|
| `src/browser/Browser.ts` | 落地导航改用 `waitUntil: 'domcontentloaded', timeout: 30000` |
| `src/functions/activities/search/BrowserSearch.ts` | `page.goto(URLs.bing.origin, { waitUntil: 'domcontentloaded', timeout: 60000 })`（两处） |
| `src/functions/activities/search/BrowserSearchOnBing.ts` | 同上（一处），另加 `waitForLoadState('domcontentloaded')` |

> 实测效果：改前桌面搜索 0 分，改后每次搜索稳定 +3 分。

### 1.3 浏览器启动参数可配置

`src/browser/Browser.ts`（+23 / -2）：

| 新增 | 说明 |
|---|---|
| `CHROME_PATH` 支持 | 优先用系统安装的 Chromium。**armv7l 等没有 Playwright 官方构建的平台必需**；未设置时仍用 patchright 自带浏览器 |
| `MRS_LOW_MEMORY=1` | 追加省内存参数：`--disable-gpu`、`--disable-software-rasterizer`、`--disable-extensions`、`--disable-features=Translate,MediaRouter,OptimizationHints,AcceptCHFrame` |
| `MRS_CHROME_ARGS` | 追加任意 Chromium 启动参数（空格分隔），用于临时调试 |
| 启动日志追加 `bin=<可执行文件路径>` | 一眼确认到底用了哪个浏览器 |

---

## ② Dashboard 取数健壮性

### 2.1 主接口降级不再「一降到底」

**原行为**：`useFlyoutDashboardFallback` 一旦置为 `true` 就**永不回退**。主接口偶发失败（网络抖动、
上下文刚建立）之后，**整轮运行**都只能用残缺的 flyout 数据。

**新行为**（`src/browser/BrowserFunc.ts`）：

```ts
private primaryReprobeAt = 0                                   // 下次允许回探主接口的时间戳
private static readonly PRIMARY_REPROBE_MS = 10 * 60 * 1000    // 回探间隔：10 分钟
```

- 每次取数时判断 `canProbePrimary = !useFlyoutDashboardFallback || Date.now() >= primaryReprobeAt`；
- 主接口恢复时打印 `主接口已恢复，切回完整仪表板`，并把 `useFlyoutDashboardFallback` 复位为 `false`。

### 2.2 flyout 兜底带重试

**原行为**：`getFlyoutDashboardData()` **零重试**，遇到 `ERR_CONNECTION_RESET` 这类瞬时错误直接抛错，
本轮 dashboard 直接失败。

**新行为**：`FLYOUT_MAX_ATTEMPTS = 3` 次尝试，`3s / 6s` 退避；全部失败才抛错，并在错误信息中标注重试次数。

### 2.3 flyout 报错可诊断

`src/browser/FlyoutDashboard.ts`（+39 / -2）：**原实现只抛一句笼统文案**：

```
Flyout response is missing Rewards account data
```

无法区分 `isError`、`isRewardsUser=false`、`profile` 缺失等**完全不同的故障**。新增
`buildFlyoutRejectionMessage()`，把拒绝原因拆开：

```
Flyout 响应不是有效的 Rewards 账户数据 | 原因=userInfo.isRewardsUser=false(errorCode=1001);
userInfo.profile 缺失; flyoutResult.userStatus.isRewardsUser=false | 顶层键=userInfo,flyoutResult
```

有了「顶层键」清单，还能立刻判断响应到底是不是 JSON（拿到 HTML 登录页时键列表会完全不同）。

---

## ③ 登录态判定修正

### 3.1 根问题：「URL 看着像登录了」不等于「真的登录了」

`src/browser/auth/Login.ts` 的 `detectCurrentState()` 原本：

```ts
if (hostname === 'bing.com' || hostname.endsWith('.bing.com') || ...) {
    this.bot.logger.debug(..., '在Bing/奖励/账户页面，假设已登录')
    return 'LOGGED_IN'          // ← 只看主机名
}
```

复用**陈旧会话**时，页面会停在 `rewards.bing.com/dashboard`，于是被判为「已登录」，
**登录流程被整个跳过，服务端从未下发身份票据**。实测会话库对比：

| 账户 | `身份` | `rewards关键` | 有 `tifacfaatcs` | 有 `.MSA.Auth` | dashboard |
|---|---|---|---|---|---|
| 正常账户 | `MSA=CfDJ8…` | 3/3 | ✅ 3910 字节 | ✅ | `数据源=primary` |
| 陈旧会话账户 | `MUID=…` | 1~2/3 | ❌ | mobile 缺失 | `数据源=flyout` → 报错 |

### 3.2 修正方式

新增 `hasAuthIdentity(page)`：检查浏览器上下文里是否存在**非空**的 `.MSA.Auth` **或** `tifacfaatcs`。

```ts
if (await this.hasAuthIdentity(page)) {
    return 'LOGGED_IN'
}

// URL 看着已登录，但服务端没下发任何身份票据 —— 典型成因是复用了陈旧的已保存会话。
if (this.reauthAttempts < Login.MAX_REAUTH_ATTEMPTS) {   // MAX_REAUTH_ATTEMPTS = 3
    this.reauthAttempts++
    this.bot.logger.warn(..., `在Bing/奖励页面但缺少登录身份票据(.MSA.Auth/tifacfaatcs)，` +
        `第 ${this.reauthAttempts}/3 次回 /auth/login 重新换取`)
    await page.goto(URLs.rewards.userLogin, { waitUntil: 'domcontentloaded', timeout: 30000 })
    await this.bot.utils.wait(2000)
    return 'UNKNOWN'          // 下一轮迭代重新检测
}

// 超限：退回原行为，避免登录流程卡死
this.bot.logger.warn(..., '重新换取后仍缺少登录身份票据(.MSA.Auth/tifacfaatcs)，按原行为假定已登录（dashboard 可能不可用）')
return 'LOGGED_IN'
```

**设计要点**：

- **上限 3 次**：重新换取失败时不无限循环，退回原行为 —— 宁可 dashboard 降级，也不让整个登录流程卡死。
- **必须用 `.MSA.Auth` 做主判定**：第一版只认 `tifacfaatcs`，结果**每次登录都白跑 3 次重取** ——
  因为实测 **CN 市场账号即使主接口完全正常也拿不到 `tifacfaatcs`**（修复后 `rewards关键=3/3` 是另一套口径，别混淆）。
- 拿不到 Cookie 时（`page.context().cookies()` 抛错）**返回 `true`**，不凭此判定为未登录。

### 3.3 修复效果

| 指标 | 修复前 | 修复后 |
|---|---|---|
| `ACCOUNT-START` locale | `geoLocale: auto \| locale: en-CN` | `geoLocale: CN \| locale: zh-CN` |
| 登录流程 | 「假设已登录」直接跳过 | 真的走到 `PASSWORD_INPUT` 并保存会话 |
| `COOKIE-AUDIT` 身份 | `MUID=3E57BF133DEE` | `MSA=CfDJ8Pj64jZa` |
| `bing关键` | 7/8 | 8/8 |
| 主接口响应 | `长度=5166`（登录页） | `长度=630092`（真 JSON） |
| `serpbotscore` | `数据源=flyout \| 未解析` | `数据源=primary \| 0.79` |
| 全轮数据源统计 | 降级后 100% flyout | **`primary=15 / flyout=0`** |

---

## ④ 可观测性

### 4.1 Cookie 审计（`COOKIE-AUDIT`）

`src/browser/BrowserFunc.ts` 新增 `captureSearchCookieSnapshot()`，在每次 dashboard 取数前后打印一行：

```
[COOKIE-AUDIT] Cookie 快照 | 来源=DASHBOARD-PRIMARY | 账户=***@***.*** | 平台=MOBILE |
缓存=28 | 实时=28 | 缓存与浏览器同步=是 | 缓存陈旧项=0 |
身份=MSA=CfDJ8Pj64jZa | 归属一致=是 | rewards关键=3/3 | bing关键=8/8 |
缺失=MSPRequ,MSPOK,MSPAuth,WLSSC | 指纹=2c0bde99ec2b | 比对=同账户:指纹稳定 | 仪表板=primary
```

关键 Cookie 分三组（`SEARCH_KEY_COOKIES`）：

| 组 | Cookie | 意义 |
|---|---|---|
| `rewards` (3) | `_C_Auth`、`tifacfaatcs`、`MSFPC` | Rewards 身份票据，**缺了 dashboard 必失败** |
| `bing` (8) | `SRCHHPGUSR`、`SRCHUSR`、`_EDGE_V`、`_EDGE_S`、`MUID`、`ANON`、`WLS`、`.MSA.Auth` | Bing 侧登录态，搜索计分依赖 |
| `live` (4) | `MSPRequ`、`MSPOK`、`MSPAuth`、`WLSSC` | MSA 传统票据，**缺失通常无影响** |

> 排查 dashboard 问题**先看这一行**：`身份=` 是否 `MSA=...`、`rewards关键` 是否 3/3。
> 顺带记录了「缓存 vs 浏览器实时态是否同步」和「指纹是否跨账户串号」，用于诊断多账号切换问题。

### 4.2 `serpbotscore` 双路径解析

`resolveSerpBotScore()`：`serpbotscore` 在 `getuserinfo` 响应里有两处等价路径
（`$.dashboard.userProfile.attributes` 与 `$.profile.attributes`，同源）。优先取前者，兜底后者，
并兼容 flyout 侧的大小写写法 `SerpBotScore` / `SerpBotScore_upd`。

**取不到时会区分两种情况**，不再一律回退成「未知」：

- 走 flyout 匿名兜底（`isRewardsUser:false`）→ 响应里根本没有 `profile` → `匿名兜底`；
- `profile` 有返回但属性里没这个字段 → `字段缺失(profile已返回但未含serpbotscore)`。

### 4.3 pushplus 未配置不再静默失败

`src/index.ts`（+26 / -1）。**原实现**：

```ts
if (!pushplus?.enabled || !pushplus.token) return      // token 为空 → 静默 return，不推送也不打日志
```

**这是个隐蔽的坑**：启用推送、但 token 为空时，「配了推送却一直收不到」**完全无迹可寻**。
（实际踩到过：token 被误填进了 `channel` 字段。）

**新实现**：拆成两道判断，token 为空时打 `WARN`，并在 `channel` 疑似 32 位十六进制 token 时给出定向提示。

```ts
if (!pushplus?.enabled) return

// 启用却没 token 时不能静默返回 —— 否则"配了推送但一直收不到"完全无迹可寻。
if (!pushplus.token) {
    const hint = pushplus.channel && /^[0-9a-f]{32}$/i.test(pushplus.channel)
        ? `；channel 字段的值(${pushplus.channel})看起来像 token，疑似填错了字段`
        : ''
    this.logger.warn('main', 'PUSHPLUS',
        `webhook.pushplus 已启用但 token 为空，跳过推送。请在 config.json 的 webhook.pushplus.token 填写 token${hint}`)
    return
}
```

> **注意**：`.env` 里写 `CONFIG_PUSHPLUS_TOKEN=...` **对 MRS 无效**。
> `CONFIG_*` 环境变量不会自动写回 `config.json` —— 主流程从不 import
> `src/util/ConfigEnvOverrides.ts`（独立 CLI）。
> 这也是「`start.sh` 推送正常、MRS 本身不推送」的原因：前者直接 `grep .env` 后 curl，绕过了 `config.json`。

---

## ⑤ 依赖与工程

### `package.json`（+2 / -1）

```diff
     "engines": {
-        "node": ">=24.0.0"
+        "node": ">=22.0.0"
     },
         "ts-node": "^10.9.2",
+        "undici": "^7.29.1",
         "zod": "^4.4.3"
```

- **Node 门槛放宽到 22**：上游要求 24，而 Debian 13 / Armbian 仓库只提供到 22。
- **显式声明 `undici`**：armv7l 上 `impit` 不可用，`undici` 是实际生效的 HTTP 后端，必须显式依赖，
  不能指望它作为传递依赖存在。

### `package-lock.json`

随 `package.json` 重新生成（`undici` 加入 + `engines` 更新 + npm 版本带来的 `peer: true` 标记差异）。

### `.gitignore`

- 取消忽略 `/docs`（本 fork 把文档作为公开内容随仓库发布）；
- 新增忽略 `/.env.rk3229`、`/deploy/sessions/`、`/deploy/logs/`、`/deploy/browser/`、`*.log`、`*.tgz`。

---

## 未改动 / 明确保留的部分

- **上游全部业务逻辑**（搜索、每日任务、PunchCard、连击保护、Read-to-Earn、多账号、代理、指纹持久化等）**原样保留**。
- 上游的 `Dockerfile` / `compose.yaml` / `flake.nix` **保留但未在 armv7l 上验证**。
- 上游 `README.md` 完整存档于 [`docs/UPSTREAM-README.md`](UPSTREAM-README.md)。
- 本 fork **不含**任何账号、token、设备地址等隐私信息。

---

## 验证方式

| 改动 | 验证手段 |
|---|---|
| 桥接生效 | 日志出现 `HTTP-BRIDGE ... 已启用浏览器网络栈桥接`；主接口响应长度从 ~5KB 变为 ~630KB |
| 导航超时修复 | 桌面搜索从「搜索次数=0」变为稳定 `获得积分=3` |
| 登录态判定 | `COOKIE-AUDIT` 的 `身份` 从 `MUID=` 变为 `MSA=`；`rewards关键` 变为 `3/3` |
| dashboard 健壮性 | `awk "/<轮次起始时间>/,0" logs/run-YYYYMMDD.log \| grep -c "数据源=primary"` → 应等于总取数次数，`flyout` 为 0 |
| flyout 重试 | 人为断网后日志出现 `Bing flyout 第 N/3 次失败，Ns 后重试` |
| 主接口回探 | 主接口恢复后日志出现 `主接口已恢复，切回完整仪表板` |
| pushplus | `node -e "console.log(require('./dist/util/Load.js').loadConfig().webhook.pushplus)"` 应含非空 token；直连 `https://www.pushplus.plus/send` 返回 `{"code":200,"msg":"执行成功"}` |
