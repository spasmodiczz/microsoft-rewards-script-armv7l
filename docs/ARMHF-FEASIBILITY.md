# Microsoft-Rewards-Script (V4-china) 在 armhf 设备部署的可行性评估

> 评估对象：`E:\armbian\Microsoft-Rewards-Script-4-china`（v4.3.2.3，V4-china 分支）
> 目标平台：armhf / armv7l / linux/arm/v7（32 位 ARM）
> 评估日期：2026-09-24
> **更新（设备确认为 Rockchip RK3229）**：RK3229 是四核 Cortex-A7 的 ARMv7-A SoC，**硬件不支持 AArch64**，方案 A 出局。交叉编译相关评估见第九节。

---

## 一、结论先行

**开箱即用的 Docker 部署：不可行。** 存在 3 个硬性架构阻塞（缺二进制，不是配置问题）+ 1 个代码层缺口 + 1 个资源现实问题。

**可行的三条路径，按推荐度排序：**

| 方案 | 做法 | 工作量 | 结论 |
|---|---|---|---|
| **A. 换 64 位系统** | 确认 SoC 支持 aarch64 → 刷 Armbian/Debian arm64 → `docker compose up` | 低 | **强烈推荐**，一劳永逸 |
| **B. armhf 硬跑（魔改）** | Node 22 + 系统 Chromium + 替换 impit + 深度降配 | 高（需改 3 处源码） | 技术上能做，但慢、脆、维护成本高 |
| **C. 拆分部署** | armhf 只做调度/推送，浏览器任务跑在远端 x86/arm64 机器上（用本项目的 API_MODE） | 中 | 稳，适合"我只有这台小盒子"的场景 |

一句话建议：**先花 5 分钟确认这台设备的 SoC 是否支持 64 位。** 绝大多数被当成"armhf 设备"的板子（全志 H3/H6/H616、晶晨 S905/S905X/S912、瑞芯微 RK3328/RK3399、树莓派 3B+/4）**硬件本身都是 64 位的**，只是当年刷了 32 位镜像。若能刷 arm64，方案 A 直接解决全部问题，方案 B 的所有改造都不必做。

---

## 二、项目的硬性环境要求

来自 `package.json` / `Dockerfile`：

```
engines.node      : >= 24.0.0
运行时            : node:24-slim (Dockerfile 两个 stage 均是)
浏览器            : patchright ^1.61.1 (Playwright fork) 自带的 Chrome for Testing 154
原生模块          : impit ^0.14.x (Rust / N-API)
```

---

## 三、五个阻塞点（逐条给了证据）

### B1. Node.js 24 已不再发布 armv7l 二进制 —— 硬阻塞

- Node.js **24.0.0 起停止提供 32 位 ARM（armv7）预编译二进制**；ARMv7 在上游 `BUILDING.md` 中被降级为 **Experimental**，源码仍可编译但不再发布、不再测试。
- `nodejs.org/dist`、`unofficial-builds`、NodeSource 均**没有** v24 的 armhf 包；Docker Hub 上 `node:24-slim` **没有 `linux/arm/v7` manifest**。
- 影响：`docker build` 直接报 `no matching manifest for linux/arm/v7`；`npm ci` 在 `engines` 检查下告警/失败。
- 最后一条官方二进制可用的主线是 **Node 22 LTS**（`node-v22.x-linux-armv7l.tar.xz`）。

### B2. Playwright / Patchright 不支持 32 位 ARM —— 硬阻塞（最致命）

- Playwright 官方预编译浏览器只有 **x86_64 与 arm64** 两个 Linux 目标；上游明确回复 **"arm32 is outside of the scope for Playwright"**（`microsoft/playwright-python#2577`）。
- 本项目的 `Dockerfile` 第 90 行 `npx patchright install --with-deps --only-shell chromium` 在 armv7l 上**必然失败**，`npx patchright install chromium` 同样。
- 没有浏览器就没有登录、没有搜索、没有签到——本项目 90% 的功能（`Browser.ts` → `Login.ts` → `Activities.ts`）全部依赖它。实验性的 `apiSearch` 走 HTTP，但**登录仍需浏览器**，无法绕过。

### B3. impit 无 armv7l 原生构建 —— 硬阻塞

从 npm registry 查到的 `impit@0.14.5` 元数据，napi 构建目标为：

```
x86_64-apple-darwin, aarch64-apple-darwin,
x86_64-pc-windows-msvc, aarch64-pc-windows-msvc,
x86_64-unknown-linux-gnu, x86_64-unknown-linux-musl,
aarch64-unknown-linux-gnu, aarch64-unknown-linux-musl
```

**没有任何 `armv7l`/`arm-unknown-linux-gnueabihf`。** 可选的 8 个平台包（`impit-linux-x64-gnu` 等）在 armhf 上全部不匹配 → 运行时 `require('impit')` 抛 "Failed to load native binding"。

`src/util/Http.ts` 整个 HTTP 层建立在 `Impit` 之上（含代理 `proxyUrl`），项目里**唯一**的原生依赖就是它（`package-lock.json` 中 8 个带 cpu/os 约束的包全是 `impit-*`）。

### B4. 代码层没有 `executablePath` 出口 —— 需改源码

`src/browser/Browser.ts:114` 的启动调用只有 `headless / channel / proxy / args`：

```ts
browser = await rebrowser.chromium.launch({
    headless,
    ...(useRealEdge && { channel: 'msedge' }),
    ...(proxyConfig && { proxy: proxyConfig }),
    args: [...Browser.BROWSER_ARGS, ...sandboxArgs, ...certArgs]
})
```

即使 `apt install chromium`（Debian armhf 确实有 `chromium` / `chromium-headless-shell` 包，bookworm 与 trixie 都有 armhf 构建），也**无法在不改代码的情况下**把 Patchright 指向系统 Chromium。必须自行加一个 `executablePath`（建议读环境变量 `CHROME_PATH`）。

### B5. 资源现实：Chromium 在 32 位小盒子上很吃力

- 典型 armhf 设备 512MB–2GB RAM、SD 卡存储。headless Chromium 冷启动 + Bing 页面在单板机上常见 5–15s/次页面加载；一个账号要做约 90 次搜索（桌面 + 移动 + 奖励搜索），还要跑 DailySet / PunchCard / ReadToEarn 等。
- 粗估：**x86 上约 15–25 分钟/账号，armhf 上大概率拉长到 1–2 小时/账号**。3 个账号串行就可能跑满一天，且 cron 每天 07:00 触发会自我重叠。
- 32 位进程地址空间受限，渲染进程 OOM 概率显著高于 arm64；`config.json` 默认 `parallelSearching: true` + `clusterSearch: true` 会同时开多页面，进一步放大内存峰值。
- 项目已有 `--disable-dev-shm-usage`（好），但没有 `--disable-gpu` / 内存上限相关参数。

---

## 四、方案 A：换成 64 位系统（推荐）

1. 在设备上确认 SoC 型号：`cat /proc/cpuinfo`、`cat /proc/device-tree/compatible`、`lscpu`、`armbianmonitor -u`。
2. 到 Armbian 下载页按 SoC 找 **aarch64** 镜像（H3/H6/H616/S905/S912/RK3328/RK3399 均有）。树莓派用 Raspberry Pi OS 64-bit / Ubuntu arm64。
3. 刷机后：`docker compose up -d` 即可，Dockerfile、镜像源（m.daocloud.io）、cron、API_MODE 全部照常工作。
4. 若内存 ≤2GB，仍建议按第六节降配。

---

## 五、方案 B：在 armhf 上硬跑（改造清单）

只在确认无法刷 64 位时才走这条。需要动手改 3 处：

### 1) 运行时：Node 22 armv7l

```bash
# 官方二进制（最后支持 armv7l 的主线）
curl -fsSL https://nodejs.org/dist/latest-v22.x/node-v22.x-linux-armv7l.tar.xz -o node.tar.xz
sudo tar -xJf node.tar.xz -C /usr/local --strip-components=1
```

然后放宽 `package.json` 的 `engines.node` 为 `>=22`（或 `npm ci --engine-strict=false`）。注意 `typescript@6`、`eslint@10` 本身对 Node 22 兼容，风险主要在项目是否用到 Node 24 才有 API——grep 后未见依赖。

> 提速技巧：**`npm run build` 的 `dist/` 是纯 JS，与架构无关**，可以在 x86 机器上编译好再 rsync 到板子，省掉板子上 tsc 的漫长编译。

### 2) 浏览器：Debian armhf 的 Chromium + 加 `executablePath`

```bash
sudo apt install -y chromium chromium-headless-shell chromium-driver
export CHROME_PATH=$(command -v chromium)   # 或 /usr/lib/chromium/chromium
```

修改 `src/browser/Browser.ts`：

```ts
browser = await rebrowser.chromium.launch({
    headless,
    ...(process.env.CHROME_PATH && { executablePath: process.env.CHROME_PATH }),
    ...
})
```

并在 `Dockerfile`/安装流程里跳过浏览器下载：设置 `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`，删掉 `npx patchright install chromium` 那一步。

**代价**：Patchright 的核心反检测补丁在 JS 层（CDP 调用顺序、`navigator.webdriver` 等），换二进制仍保留大部分效果；但版本不再锁定（Debian armhf 的 chromium 更新滞后于 Chrome for Testing），可能出现协议不兼容。同时 `fingerprint-generator` 仍会伪造 Windows/Edge 指纹，与真实 32 位 Linux 环境不一致——这层风险本来就有，不因架构改变。

### 3) HTTP 层：替换 impit

`src/util/Http.ts` 只用到 Impit 的 `new Impit({browser, proxyUrl, timeout})` / `instance.fetch(url, init)`，返回值的 `status / statusText / headers(有 forEach 与 getSetCookie) / text()`。**与 `fetch` 的 Response 接口高度兼容**，可用 `undici` 做最小替换：

```ts
import { ProxyAgent, fetch } from 'undici'
// proxyUrl → new ProxyAgent(proxyUrl) 作为 dispatcher
```

差异提醒：
- 丧失 impit 的 **TLS/HTTP2 指纹伪装**（impit 的价值就在于此），反爬风险上升；建议配合代理使用。
- `undici` 的 `ProxyAgent` 支持 http/https 代理，**socks 需另加 `socks-proxy-agent`**。
- 若追求原汁原味：交叉编译 impit 的 `armv7-unknown-linux-gnueabihf` 目标（需 rustup target + `napi build --target`），成本高，不推荐。

### 4) Docker 用户额外一步

`node:24-slim` 没有 arm/v7 镜像，需自建基础镜像：

```dockerfile
FROM debian:bookworm            # armhf 有官方 manifest
# 手动装 node22 armv7l + 系统 chromium，其余沿用原 Dockerfile 的 runtime stage
```

或直接放弃容器，用 `systemd timer` / `cron` + `npm start` 裸跑（armhf 小盒子上反而更省资源）。

---

## 六、低配设备的配置建议（方案 A/B 通用）

```jsonc
{
  "clusters": 1,                          // 禁用 cluster 多进程
  "headless": true,
  "globalTimeout": "60sec",               // 30s 在慢设备上容易超时
  "searchSettings": {
    "parallelSearching": false,           // 关键：关闭并行搜索
    "clusterSearch": false,               // 关键：关闭多标签搜索
    "searchResultVisitTime": "10sec",
    "searchDelay": { "min": "30sec", "max": "1min" }
  },
  "workers": { "doVisualSearch": false, "doBonusSearches": false }
}
```

配套系统侧：

- 开 **zram 或 1–2GB swap**（SD 卡上慎用 swap，优先 zram）。
- 每设备 **1–2 个账号**；账号多就把 `CRON_SCHEDULE` 错开或手动分批。
- 浏览器额外参数建议追加 `--disable-gpu --disable-software-rasterizer --no-zygote`（`--single-process` 不稳，别用）。
- 监控 OOM：`journalctl -k | grep -i oom`、`dmesg`；`STUCK_PROCESS_TIMEOUT_HOURS` 适当调大。

---

## 七、方案 C：拆分部署（不愿刷机时的务实选择）

armhf 盒子只承担"轻量控制面"：cron 定时 → 调用远端容器的 API → 接收 PushPlus/微信推送。

- 远端（x86 小主机 / 云服务器 / 另一台 arm64 设备）跑 `API_MODE=true` 的完整容器；
- 本地盒子用 `cron + curl` 触发 `POST /trigger`（见 `scripts/api/`）；
- 好处：架构阻塞全部绕开，armhf 上只需 curl；坏处：需要一个常开的第二台机器。

---

## 八、落地检查清单

- [ ] `uname -m` → 确认是 `armv7l`
- [ ] 确认 SoC 是否支持 aarch64（能 → 走方案 A，直接结束）
- [ ] 内存 ≥1GB（<512MB 基本不用考虑方案 B）
- [ ] `node -v` ≥22（armv7l）
- [ ] `apt-cache policy chromium` 有 armhf 候选版本
- [ ] 完成 3 处源码改造（executablePath / impit→undici / engines）
- [ ] 降配 config + zram + 单账号试跑 24h 观察 OOM 与耗时

配套的 `check-armhf-feasibility.sh` 可直接在设备上执行，一次性输出上述体检结果。

---

## 附：关键证据来源

| 结论 | 来源 |
|---|---|
| Node 24 起无 armv7l 预编译二进制，ARMv7 降为 Experimental | Node.js v22→v24 迁移文档（Platform support 段） |
| `node:24` 无 `linux/arm/v7` manifest | Docker Hub node 官方镜像架构列表 |
| Playwright 仅支持 x86_64 / arm64，arm32 不在范围内 | `microsoft/playwright-python#2577` 官方回复 |
| impit 无 armv7l 目标 | npm registry `impit@0.14.5` 元数据 `napi.targets` |
| Debian armhf 有 chromium / chromium-headless-shell | Debian Package Tracker（bookworm / trixie 均含 armhf 构建） |
| 项目依赖 Node 24、patchright、impit | 本仓库 `package.json`（v4.3.2.3） |
| 浏览器启动无 executablePath 出口 | 本仓库 `src/browser/Browser.ts:114` |
| RK3229 = 四核 Cortex-A7 / ARMv7-A，无 AArch64 | Rockchip 官方 RK3229 产品页 |
| Debian trixie/bookworm armhf 提供 chromium 与 chromium-headless-shell | Debian Package Tracker |

---

## 九、RK3229 专项：交叉编译到底值不值

### 9.1 硬件事实（决定了天花板）

| 项 | RK3229 |
|---|---|
| CPU | 四核 Cortex-A7 @ 最高 1.5GHz，**ARMv7-A，纯 32 位** |
| GPU | Mali-400MP2 |
| 内存 | 32bit DDR3/LPDDR3，**最大 2GB**（此类盒子常见 1GB） |
| 参考性能 | Geekbench 4 单核 ~416 / 多核 ~833（约树莓派 3B 的 60%，现代 x86 桌面的 1/12 左右） |
| 系统 | Armbian 社区（CSC）有 `rk322x-box` 镜像，当前 rolling + Debian **trixie**，默认启用 **zswap** |

**结论：方案 A（刷 64 位）彻底不可行**，这是硬件层级的事，不是镜像没找对。

### 9.2 缺的三样东西，逐个评估"要不要自己编译"

| 组件 | 交叉编译可行性 | 成本 | 我的建议 |
|---|---|---|---|
| **Node.js 24 (armv7l)** | 可行，Node 官方支持 `--cross-compiling --dest-cpu=arm`，需 gcc ≥12.2 的 armhf 工具链 + sysroot + 先编 host 侧的 mksnapshot/torque | 40–90 分钟，还要踩 ARMv7 在 Node 24 已是 Experimental 的坑 | **不值得**。直接装官方 Node 22 armv7l 二进制，2 分钟。项目没有用到任何 Node 24 独有 API，`engines` 只是声明 |
| **Chromium (armv7l)** | 理论可行，实际上是最差选择 | 源码 2GB+、构建产物 30–60GB 磁盘、16GB+ 内存、数小时；32 位 Linux Chromium 上游几乎无人测试，GN 参数 `target_cpu="arm"` 大概率要自己修构建错误 | **绝对不要自己编**。Debian trixie armhf 仓库里有现成的 `chromium` / `chromium-headless-shell`，`apt install` 两分钟，本质上就是"别人已经帮你交叉/原生编译好的成果" |
| **impit (armv7l)** | **可行且是唯一值得自己编的** | 见下 | 值得考虑，但有更省事的替代 |

### 9.3 impit 交叉编译的具体评估

**好消息**：`impit` crate 的 TLS 后端是 `rustls 0.23`（纯 Rust）+ `rustls-platform-verifier` + `webpki-root-certs`，**不依赖 C 版 OpenSSL**。这让交叉编译难度大幅下降。

**坏消息**：它的 reqwest 声明是

```toml
reqwest = { version="0.13.1", features = ["json","gzip","brotli","zstd","deflate","http3","cookies","stream","socks"] }
```

**没有 `default-features = false`**，所以 reqwest 的默认 `default-tls`（→ native-tls → openssl-sys）仍会被编译进来，链接时需要 armhf 的 OpenSSL。绕开办法二选一：

- 给交叉环境准备 armhf sysroot（内含 `libssl-dev:armhf`）；
- 或者给 reqwest 补上 `default-features = false, "rustls-tls"`（改上游，需自行承担行为差异）。

**两条实现路径：**

```bash
# 路径 1：宿主机交叉编译（需要一台装了 Docker 的 x86 Linux）
git clone https://github.com/apify/impit && cd impit
cargo install cross --locked
cd impit-node
cross build --release --target armv7-unknown-linux-gnueabihf
# 产物：target/armv7-unknown-linux-gnueabihf/release/libimpit_node.so

# 路径 2：在 RK3229 本机编译（不用配 sysroot，更简单）
sudo apt install -y build-essential pkg-config libssl-dev curl
curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain stable
cd impit/impit-node && npx napi build --platform --release
```

路径 2 在 A7 四核上大约 40–120 分钟（几百个 crate，含 hyper / quinn / tokio / lol_html）。**我更推荐路径 2**，因为 napi 会按当前平台直接产出命名正确的 `.node` 文件，省掉手工适配加载器。

**一个必须知道的坑**：impit npm 包的 `napi.targets` 里没有 armv7l，所以它的 `index.wrapper.js` 里**没有 arm 分支**。你可能需要在 `impit-node/package.json` 的 `napi.targets` 中补上 `"armv7-unknown-linux-gnueabihf"`，否则要么 napi CLI 拒绝构建，要么编译出来的 .so 没有对应的加载路径，得手工塞进 `node_modules/impit/` 并改 wrapper。

**替代方案（更省事）**：直接用 Node 内置的 `fetch`（undici）替换 `src/util/Http.ts` 里的 Impit。impit 在项目里只用于 rewards API 的 HTTP 请求，而反爬的主战场是浏览器指纹；TLS 指纹的差异有风险但不是致命的。**建议先这样跑通，再回头决定是否值得为 impit 折腾交叉编译。**

### 9.4 但真正的瓶颈不是二进制，是性能

就算三样东西都补齐，RK3229 上 Chromium 的现实是：

- Cortex-A7 单核性能约为现代 x86 的 1/12，而 Chromium 的主渲染线程/JS 执行是**单线程瓶颈**；
- 1GB RAM（默认开 zswap 能救一点，但 zswap 压缩也要 CPU）；
- 每账号约 90 次搜索 + DailySet / PunchCard / ReadToEarn 等交互；
- 粗估：**单次 Bing 页面加载 15–40 秒时，单账号总耗时 1.5–2.5 小时**，且中途崩一次就白跑。

**所以我的建议是：先花 20 分钟做性能 smoke test，拿到实测数据再决定要不要投入交叉编译。** 编译 impit 是一天的工作量，smoke test 是二十分钟，别反过来。

---

## 十、决策流程（RK3229 版）

1. **跑 `smoke-test-rk3229.sh`**（不需要 Node、不需要编译任何东西，只用系统 chromium 实测页面加载耗时与内存峰值）。
2. 看结果：
   - 单次加载 **< 5 秒** → 值得继续，按第五节方案 B 改造（Node22 + apt chromium + impit 本机编译或 undici 替换）。
   - **5–10 秒** → 能跑但勉强，必须 1 个账号 + 关闭并行搜索 + 只保留核心任务，做好每天跑 1 小时的心理准备。
   - **> 10 秒** 或内存直接 OOM → **放弃在本机跑浏览器**，走方案 C：RK3229 只做 cron 调度与推送，浏览器任务交给远端一台 x86/arm64 机器上的 `API_MODE=true` 容器。
3. 若第 1 步的耗时数据可接受，再按顺序做：Node 22 → `apt install chromium` → 改 `executablePath` → HTTP 层（先 undici 跑通，impit 留作优化项）。

---

## 十一、RK3229 实测数据与最终方案（已落地改造）

### 11.1 实测结果（2026-09-24）

| 项 | 实测 |
|---|---|
| 系统 | Armbian，内核 6.18.52-current-rockchip，Debian trixie，armv7l |
| CPU / 内存 | 4 核 @1.5GHz，**970 MB 可用**，swap 485 MB，**zswap enabled=N** |
| Chromium | 150.0.7871.181（Debian trixie armhf 官方包），`--headless=new` 可用 |
| 页面加载 | 第 1 次 **超时 >180 秒**（冷启动）；第 2/3 次 **15.4 / 15.7 秒** |
| 进程树峰值内存 | **643 / 651 MB（占可用内存 67%）** |

**三条结论：**

1. **页面加载 15.6 秒是可接受的** —— 比预想的好，Chromium 在 A7 上能用。
2. **内存是真正的红线** —— 651MB 只是**一个页面**的峰值。MRS 还要叠加 Node 主进程（100–200MB）、多标签页、fingerprint 注入。**必须**关掉 `parallelSearching` / `clusterSearch`、开启 `blockMedia`、启用 zswap，否则必 OOM。
3. **首次冷启动 >180 秒** —— `globalTimeout` 必须调大（建议 90 秒以上），并且不要按"3 分钟没反应就以为挂了"来判断。

### 11.2 最大的坑：`searchDelay` 默认值

`src/functions/activities/search/BrowserSearch.ts:186` 里，`searchDelay` 是**每一次搜索之后**的等待；`ReadToEarn.ts` 里 `readDelay` 是**每篇文章之间**的等待，共 10 篇。

而 `config.example.json` 给的是：

```json
"searchDelay": { "min": "6min",  "max": "12min" }
"readDelay":   { "min": "6min",  "max": "11min" }
```

照抄的后果（按 50 次搜索 + 10 篇文章算）：

**50 × 9 分钟 + 10 × 8.5 分钟 ≈ 8.5 小时/账号** —— 一天都跑不完，跨天还会叠加。

（注：`Validator.ts` 里的代码默认值其实是 30sec–1min，与 example 文件不一致，这是 fork 的保守化改动。）

**推荐值 1–2 分钟**，据此测算单账号总耗时：

| 配置 | 搜索部分 | ReadToEarn | 其他活动 | 合计 |
|---|---|---|---|---|
| example 原值 6–12min | ~7.5h | ~1.4h | ~0.5h | **≈9.4 小时**（不可行） |
| **1–2min（推荐）** | 50×(15.6s+90s+15s)≈1.7h | 10×90s≈15min | ~30min | **≈2.5 小时** |
| 代码默认 30–60s | ~1.1h | ~8min | ~30min | **≈1.6 小时**（风控风险偏高） |

延迟越小越快，但被判定为机器人的风险越高。**1–2 分钟是这台机器上的平衡点。**

### 11.3 已完成的源码改造（已通过 tsc 类型检查）

| 文件 | 改动 | 影响面 |
|---|---|---|
| `src/util/Http.ts` | 抽出 `HttpFetcher` 抽象层：优先 impit，`require('impit')` 失败时自动回落到 Node 内置 `fetch`(undici)；代理场景动态加载 undici 的 `ProxyAgent`；可用 `MRS_HTTP_BACKEND=impit\|fetch` 强制指定 | x86 行为完全不变（仍走 impit） |
| `src/browser/Browser.ts` | 新增 `CHROME_PATH`（指定系统 Chromium）、`MRS_LOW_MEMORY=1`（追加省内存参数）、`MRS_CHROME_ARGS`（任意追加参数） | 不设环境变量时行为不变 |
| `package.json` | `engines.node` 放宽为 `>=22.0.0`；新增纯 JS 依赖 `undici` | — |

**已做的验证（x86 环境）：**
- `tsc --noEmit` 与 `npm run build` 均通过；
- 强制 `MRS_HTTP_BACKEND=fetch` 实测请求 cn.bing.com：status 200、响应头解析正常、`set-cookie` 提取成功；
- 默认路径（impit）同样 200，未破坏原有行为。

### 11.4 部署步骤（`deploy-rk3229.sh` 已封装）

```bash
sudo mkdir -p /opt/mrs
# 把改好的代码同步过去（git clone / scp / rsync）
sudo MRS_DIR=/opt/mrs bash deploy-rk3229.sh
# 填账号
sudo nano /opt/mrs/.env
# 手动试跑一次，观察日志
sudo systemctl start mrs.service && sudo journalctl -u mrs.service -f
```

脚本会依次完成：启用 zswap（先运行时生效，再备份后写入 `/boot/armbianEnv.txt`）、`vm.swappiness=80`、安装 Node 22 armv7l（若缺失）、安装 Chromium、`npm install --ignore-scripts` + `npm run build`、生成降配 `config.json` 与 `.env` 模板、注册每天 03:00 的 systemd timer（含 `CHROME_PATH` / `MRS_LOW_MEMORY=1` / `MRS_HTTP_BACKEND=fetch`）。

### 11.5 上线后重点盯这三件事

1. **OOM**：`journalctl -k | grep -i oom`。若发生 → 确认 zswap 生效、`blockMedia=true`、账号减到 1 个。
2. **总耗时**：若超过 4 小时，把 `searchDelay` 往 1 分钟压，或关掉 `doReadToEarn` / `doPunchCards`。
3. **风控告警**：日志里的 `Fraud_UserWarning_BotScore_UX`。出现后把延迟调大而不是调小。

---

## 十二、同类设备实战经验迁移（OpenStick / 骁龙410，382MB RAM）

用户在另一台**更弱**的设备上已成功部署并稳定运行（arm64 + Debian + Docker，382MB RAM / 3.3GB 存储）。那份记录里的踩坑经验对 RK3229 高度适用，已吸收进 `deploy-rk3229.sh`。

### 12.1 两台设备对比：RK3229 其实更有余量

| 项 | OpenStick（骁龙410） | RK3229 |
|---|---|---|
| 架构 | **arm64** | armv7l（32 位） |
| 内存 | **382 MB** | 970 MB（**约 2.5 倍**） |
| 存储 | 3.3 GB（吃紧） | 通常 8–16GB eMMC |
| Node | 24（arm64 有官方包） | 22（armv7l 上限） |
| Chromium | patchright 官方下载 | Debian armhf 包 |
| 结论 | 已跑通 | **条件更好，可行性更高** |

OpenStick 用 382MB 都能跑完整流程，RK3229 有 970MB，内存维度不再是问题——**真正的差异只剩 32 位带来的稳定性风险**。

### 12.2 必须迁移的四条经验（已写进部署脚本）

| 经验 | OpenStick 上的教训 | RK3229 上的处理 |
|---|---|---|
| **core dump 撑爆磁盘** ⚠️ | Chromium 段错误 → 工作目录写出 **555MB core**，两次就把 3.3G 撑到只剩 58M | `kernel.core_pattern=/dev/null` 持久化 + systemd `LimitCORE=0` + 每次运行前清理 core |
| **段错误是常态** | 多次 `Segmentation fault`，任务本身其实已完成，崩溃发生在等待期 | `mrs-run.sh` 失败退避重试 3 次（60/120/180s） |
| **假成功** | 0 积分/0 余额被当作正常完成 | 解析 `全部账户完成 \| ... \| 获得积分=N`，为 0 则额外重跑 1 次 |
| **会话清空后要能自动重登** | 失败达阈值清 sessions 后，靠 TOTP 自动完成重新登录 | 同样机制；**建议 `.env` 配置 `ACCOUNT_1_TOTP_SECRET`**，否则清空会话后需要人工介入 |

还吸收了：会话每次运行前自动备份（`sessions_backup_auto`）、journal 日志限 60M 保留 14 天、磁盘低于 300MB 自动清旧日志。

### 12.3 一条反向结论：不要用 `--single-process`

OpenStick 因为只有 382MB，注入了 `--single-process --disable-gpu --disable-software-rasterizer`。但同一份记录里**反复出现 Chromium 段错误**——这两件事很可能相关：`--single-process` 把渲染、GPU、网络全塞进一个进程，任一页面崩溃即整个浏览器崩溃，在内存紧张时尤其脆弱。记录里也写了"若某个参数导致运行不稳（例如 `--single-process` 偶发崩溃）就删掉"。

**RK3229 有 970MB，不需要这个参数**，所以 `MRS_LOW_MEMORY=1` 里**刻意没有**包含它（只保留了 `--disable-gpu` / `--disable-software-rasterizer` / `--disable-extensions` / `--disable-features=...`）。

如果后续实测内存仍然吃紧，可以通过 `MRS_CHROME_ARGS="--single-process"` 自行加上，但要预期崩溃率上升。

### 12.4 其余可复用要点

- **`m.daocloud.io` 加速源已失效（401）** —— 本仓库 `Dockerfile` 的 `FROM` 仍指向它。RK3229 裸跑不受影响，但若日后改用 Docker 必须换掉。
- **国内源**：npm 用 `registry.npmmirror.com`，apt 用 163 镜像；`--with-deps` 会触发内部 apt GPG 错误，去掉它。
- **`chromium-headless-shell` 不依赖 GTK**，可卸掉 libgtk/adwaita/gdk 等约 200MB。
- **构建期限制内存会 tsc segfault**（`--memory=300m` 太紧）；改用 legacy builder（`DOCKER_BUILDKIT=0`）可避免 buildkit OOM。
- **登录卡在 `EMAIL_INPUT` 循环**多为网络波动导致登录页推进慢，不是账号问题，重试即可。

---

## 十三、实机部署验证记录（<设备IP>，2026-09-24 完成）

已在真实设备上完成部署并跑通链路。设备：`rk322x-box`，Armbian 26.11.0-trunk.51 trixie，内核 6.18.52，armv7l，970MB RAM，7GB eMMC（可用 4.5G）。

### 13.1 部署过程与实测耗时

| 步骤 | 结果 |
|---|---|
| 免密 SSH（root） | 成功 |
| 体检 | 970MB 内存、已有 zram 485MB、Chromium 150 已装、**Node 缺失**、`core_pattern=core` |
| 网络探测 | nodejs.org 200、npmmirror 200、npmjs 200、163 源 200（网络很好） |
| 安装 Node 22 armv7l | `node-v22.23.3-linux-armv7l.tar.xz`（26MB），成功 |
| 上传源码 | 269KB（排除 node_modules / dist / .git） |
| `npm install`（npmmirror） | 170 包，**1 分 02 秒** |
| `npm run build`（tsc） | **1 分 31 秒** |
| 执行 `deploy-rk3229.sh` | 8 步全部通过 |

### 13.2 三个关键结论被实机证实

1. **impit 在 armv7l 上确实无法加载** —— `require('impit')` 直接失败，加的 fallback 生效，HTTP 请求返回 200（97KB）。这是当初判断"必须改造 HTTP 层"的铁证。
2. **Patchright 能驱动 Debian 的 Chromium 150** —— launch **4.4 秒**，goto cn.bing.com **10.7 秒**（比 smoke test 的 15.6 秒还快）。
3. **完整链路打通** —— 日志确认：`bin=/usr/bin/chromium`；指纹注入成功（`"webdriver": false`，UA 伪装为 Android/Edge）；`媒体加载已禁用`（blockMedia 生效）；真实走到 `login.live.com` 并识别出 `EMAIL_INPUT` 状态、成功提交邮箱。

### 13.3 实机发现并修复的问题

**`mrs-run.sh` 缺少默认 `CHROME_PATH`** —— 手动或 cron 调用时不会继承 systemd 的环境变量，会回落到 `bin=bundled` 并报 `chromium is not supported`。已修复：包装脚本自带默认值并自动探测 Chromium 路径，另加启动环境自检（打印 node 版本 / CHROME_PATH / 可用内存）。

另外踩到一个坑：`pkill -f chromium` 会匹配到执行该命令的 shell 自身导致 SSH 会话被杀（exit 255），应改用 `pkill -x`。

### 13.4 当前状态

- `core_pattern=/dev/null`、zswap=Y、journal 限 60M、timer 每天 03:01
- config 降配全部生效：`clusters=1`、`parallelSearching=false`、`clusterSearch=false`、`blockMedia=true`、`searchDelay/readDelay=1-2min`、`globalTimeout=90sec`
- 无 core 文件、无残留浏览器进程、内存 863MB 可用、磁盘 4.5G 可用

### 13.5 唯一未完成项：账号

`.env` 里仍是占位的 `you@example.com`，**需用户自行填入真实账号**（密码或 TOTP），填完执行 `systemctl start mrs.service`。

> 实机还确认了一件事：单个账号流程失败时，脚本仍会输出 `全部账户完成 | 获得积分=0` 并**以退出码 0 结束**。所以"0 积分自动重跑"不是可选项而是必需项——它是唯一能发现"跑了个寂寞"的机制。
