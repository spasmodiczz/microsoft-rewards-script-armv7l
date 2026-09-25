import { createHash } from 'node:crypto'

import { URLs } from '../constants/urls'
import { BING_APP_USER_AGENT } from '../constants/userAgents'
import type { BrowserContext, Cookie, Page } from 'patchright'
import type { BrowserBridgeFetch, BrowserBridgeResult, HttpRequestConfig } from '../util/Http'

import type { MicrosoftRewardsBot } from '../index'
import type { PageSnapshot, ParsedOffer } from './ReactFunc'
import { loadSession, saveStorageState } from '../util/SessionStore'
import { isBrowserClosedError } from '../util/Utils'

import type { DashboardData } from './../interface/DashboardData'
import type { AppUserData } from '../interface/AppUserData'
import type { AppEarnablePoints, BrowserEarnablePoints } from '../interface/Points'
import type { AppDashboardData } from '../interface/AppDashBoardData'
import { detectFlyoutBotWarning, mapFlyoutToDashboard, type RewardsFlyoutData } from './FlyoutDashboard'

/**
 * 搜索计分链路上的关键 Cookie。
 * group 说明它归属于哪个域簇，便于判断"搜索请求到底带没带身份"。
 */
const SEARCH_KEY_COOKIES: ReadonlyArray<{ name: string; group: 'rewards' | 'bing' | 'live' }> = [
    { name: '_C_Auth', group: 'rewards' },
    { name: 'tifacfaatcs', group: 'rewards' },
    { name: 'MSFPC', group: 'rewards' },
    { name: 'SRCHHPGUSR', group: 'bing' },
    { name: 'SRCHUSR', group: 'bing' },
    { name: '_EDGE_V', group: 'bing' },
    { name: '_EDGE_S', group: 'bing' },
    { name: 'MUID', group: 'bing' },
    { name: 'ANON', group: 'bing' },
    { name: 'WLS', group: 'bing' },
    { name: '.MSA.Auth', group: 'bing' },
    { name: 'MSPRequ', group: 'live' },
    { name: 'MSPOK', group: 'live' },
    { name: 'MSPAuth', group: 'live' },
    { name: 'WLSSC', group: 'live' }
]

export interface SearchCookieSnapshot {
    platform: 'MOBILE' | 'DESKTOP'
    account: string
    cacheSource: string
    cachedCount: number
    liveCount: number | null
    inSync: boolean | null
    /** 只在缓存里存在、浏览器实时态已没有的 Cookie 数（陈旧项，不影响结论但有提示价值） */
    cacheOnlyCount: number
    owner: string
    ownerMatches: boolean
    rewardsCount: number
    bingCount: number
    present: string[]
    missing: string[]
    fingerprint: string
    dashboardSource: 'primary' | 'flyout'
}

export default class BrowserFunc {
    private bot: MicrosoftRewardsBot

    private rewardsDeploymentId = ''

    private useFlyoutDashboardFallback = false

    /**
     * 降级到 flyout 后，下一次允许重新探测主接口的时间戳(ms)。
     *
     * 主接口偶发失败（设备网络抖动、上下文刚建立）不应该让整轮运行永久失去主接口：
     * 一旦置真就再也不回退，后面所有 dashboard 取数都只能靠 flyout 那份残缺数据。
     */
    private primaryReprobeAt = 0

    /** 重新探测主接口的间隔（10 分钟） */
    private static readonly PRIMARY_REPROBE_MS = 10 * 60 * 1000

    /** Bing flyout 兜底的最大尝试次数（应对 ERR_CONNECTION_RESET 之类的瞬时错误） */
    private static readonly FLYOUT_MAX_ATTEMPTS = 3

    private botMetricsLoggedPlatforms = new Set<string>()

    private bridgePage: Page | null = null

    /** 审计用：上一次记录 cookies 指纹时的账户/平台，用于判断账户切换后是否同步 */
    private cookieAuditTrail: { account: string; platform: string; fingerprint: string } | null = null

    /** 审计用：(账户|平台) → 登录票据身份标识，用于跨轮次判断是否串号 */
    private cookieOwnerTrail = new Map<string, string>()

    constructor(bot: MicrosoftRewardsBot) {
        this.bot = bot
    }

    /**
     * 构造浏览器桥接函数（armv7l 等无 impit 平台的取数通道）。
     *
     * 背景：impit 只提供 x86_64 / aarch64 预编译包，armv7l 上 HTTP 层会回落到
     * undici，TLS/HTTP2 指纹与浏览器不一致，微软对 rewards.bing.com 的请求会
     * 返回登录页（flyout 则降级成 isRewardsUser:false 的匿名响应）。
     *
     * 关键点：直接用页面内 fetch 打 /api/getuserinfo 会失败 —— 会话里必须先有
     * 服务端下发的 tifacfaatcs cookie，否则接口会把请求 302 到 login.live.com，
     * 跨域重定向被 CORS 拦下，表现就是 "Failed to fetch"。
     * 该 cookie 只有在「顶层导航」到接口时才会下发，因此这里：
     *   1) 先用专用页面做一次顶层导航预热；
     *   2) 之后改用页面内 fetch 复用真实浏览器网络栈（快且不打断主页面）。
     */
    createBrowserBridge(): BrowserBridgeFetch {
        return async (url, init) => {
            // 只有纯文本 / 无 body 的请求能安全地在页面里重放
            const body = init.body
            if (body !== undefined && body !== null && typeof body !== 'string') return null

            const method = (init.method ?? 'GET').toUpperCase()

            try {
                new URL(url)
            } catch {
                return null
            }

            const page = await this.ensureBridgePage()
            if (!page) return null

            const attempt = async (): Promise<BrowserBridgeResult | null> => {
                try {
                    const result = await page.evaluate(
                        async ({ requestUrl, requestMethod, headers, requestBody }) => {
                            const forbidden = new Set([
                                'cookie',
                                'host',
                                'origin',
                                'referer',
                                'content-length',
                                'connection',
                                'accept-encoding',
                                'via',
                                'proxy-authorization'
                            ])
                            const clean: Record<string, string> = {}

                            for (const [key, value] of Object.entries(headers ?? {})) {
                                if (forbidden.has(key.toLowerCase())) continue
                                if (value === undefined || value === null) continue
                                clean[key] = String(value)
                            }

                            const response = await fetch(requestUrl, {
                                method: requestMethod,
                                headers: clean,
                                body: requestBody,
                                credentials: 'include',
                                redirect: 'follow'
                            })

                            return {
                                status: response.status,
                                statusText: response.statusText,
                                text: await response.text()
                            }
                        },
                        {
                            requestUrl: url,
                            requestMethod: method,
                            headers: init.headers,
                            requestBody: body as string | undefined
                        }
                    )

                    return result && typeof result.text === 'string' ? result : null
                } catch {
                    return null
                }
            }

            // 1) 快路径：已经预热过的源，直接页面内 fetch
            const direct = await attempt()
            if (direct) {
                this.bot.logger.debug(
                    this.bot.isMobile,
                    'HTTP-BRIDGE',
                    `${method} ${url} -> ${direct.status} | 长度=${direct.text.length}`
                )
                return direct
            }

            // 2) 预热：顶层导航一次，让服务端下发会话 cookie（仅 GET 安全）
            if (method !== 'GET') return null

            const target = new URL(url)
            const targetOrigin = target.origin

            try {
                // 先在该源上"落地"一次：新上下文（例如刚登录的桌面端）直接打接口会被
                // 判定为未登录而重定向到登录页，必须先加载一个常规页面建立会话。
                const pageOrigin = page.url() && page.url() !== 'about:blank' ? new URL(page.url()).origin : ''
                if (pageOrigin !== targetOrigin) {
                    try {
                        await page.goto(`${targetOrigin}/`, { waitUntil: 'commit', timeout: 30000 })
                    } catch {
                        /* 落地失败不致命，继续尝试直接导航 */
                    }
                }

                await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 })
            } catch (error) {
                this.bot.logger.debug(
                    this.bot.isMobile,
                    'HTTP-BRIDGE',
                    `预热导航失败 | ${error instanceof Error ? error.message : String(error)}`
                )
                return null
            }

            const primed = await attempt()
            if (primed) {
                this.bot.logger.debug(
                    this.bot.isMobile,
                    'HTTP-BRIDGE',
                    `预热后 ${method} ${url} -> ${primed.status} | 长度=${primed.text.length}`
                )
                return primed
            }

            // 3) 最后兜底：直接读顶层导航渲染出来的响应体（只在看起来像真正的响应时采用）
            try {
                const text = (await page.evaluate(() => document.body?.textContent ?? '')).trim()
                const looksLikePayload = text.startsWith('{') || text.startsWith('[') || text.length > 20000

                if (text && looksLikePayload) {
                    this.bot.logger.debug(
                        this.bot.isMobile,
                        'HTTP-BRIDGE',
                        `读取导航响应体 ${method} ${url} | 长度=${text.length}`
                    )
                    return { status: 200, statusText: 'OK', text }
                }

                this.bot.logger.debug(
                    this.bot.isMobile,
                    'HTTP-BRIDGE',
                    `预热后仍无法取得有效响应，回落普通后端 | 长度=${text.length}`
                )
            } catch {
                /* 忽略 */
            }

            return null
        }
    }

    /** 惰性创建专用于 API 取数的页面，避免打断主页面（搜索 / 活动）的浏览状态 */
    private async ensureBridgePage(): Promise<Page | null> {
        const active = this.getActivePage()
        if (!active) return null

        try {
            if (this.bridgePage && !this.bridgePage.isClosed() && this.bridgePage.context() === active.context()) {
                return this.bridgePage
            }
        } catch {
            this.bridgePage = null
        }

        try {
            const page = await active.context().newPage()
            await page.goto('about:blank')
            this.bridgePage = page
            return page
        } catch (error) {
            this.bot.logger.debug(
                this.bot.isMobile,
                'HTTP-BRIDGE',
                `无法创建专用取数页面 | ${error instanceof Error ? error.message : String(error)}`
            )
            return null
        }
    }

    async getDashboardData(cookies?: Cookie[]): Promise<DashboardData> {
        const fingerprintHeaders = { ...(this.bot.fingerprint?.headers ?? {}) }
        delete fingerprintHeaders['Cookie']
        delete fingerprintHeaders['cookie']

        // 已降级时也要定期回探主接口：网络恢复后自动切回完整仪表板
        const canProbePrimary = !this.useFlyoutDashboardFallback || Date.now() >= this.primaryReprobeAt

        if (canProbePrimary) {
            let primaryError: unknown

            for (let attempt = 1; attempt <= 2; attempt++) {
                try {
                    // 审计：记录本次主接口请求实际携带的 Cookie（来源/关键字段/归属/指纹）
                    await this.captureSearchCookieSnapshot(
                        'DASHBOARD-PRIMARY',
                        URLs.rewards.userInfoApi,
                        'primary',
                        attempt === 1
                    )

                    const response = await this.bot.http.request<DashboardData>({
                        url: URLs.rewards.userInfoApi,
                        method: 'GET',
                        headers: {
                            ...fingerprintHeaders,
                            Cookie: this.buildCookieHeader(this.getCachedCookies(cookies, URLs.rewards.userInfoApi)),
                            Referer: URLs.rewards.referer,
                            Origin: URLs.rewards.origin
                        },
                        retries: 0
                    })

                    await this.applyResponseCookies(URLs.rewards.userInfoApi, response.headers['set-cookie'])

                    if (response.data?.dashboard) {
                        this.logBotDetectionMetrics(response.data, 'primary')
                        if (this.useFlyoutDashboardFallback) {
                            this.bot.logger.info(
                                this.bot.isMobile,
                                'GET-DASHBOARD-DATA',
                                '主接口已恢复，切回完整仪表板'
                            )
                        }
                        this.useFlyoutDashboardFallback = false
                        this.primaryReprobeAt = 0
                        return response.data
                    }
                    throw new Error('Dashboard data missing from API response')
                } catch (error) {
                    primaryError = error
                    if (attempt === 1) {
                        this.bot.logger.warn(
                            this.bot.isMobile,
                            'GET-DASHBOARD-DATA',
                            `主接口请求失败，正在重试一次 | 信息=${this.errorMessage(error)}`
                        )
                        await new Promise(resolve => setTimeout(resolve, 1000))
                    }
                }
            }

            this.useFlyoutDashboardFallback = true
            this.primaryReprobeAt = Date.now() + BrowserFunc.PRIMARY_REPROBE_MS
            this.bot.logger.warn(
                this.bot.isMobile,
                'GET-DASHBOARD-DATA',
                `重试后主接口仍不可用，改用 Bing flyout 兜底（10 分钟后回探） | 信息=${this.errorMessage(primaryError)}`
            )
        }

        return await this.getFlyoutDashboardData(cookies, fingerprintHeaders)
    }

    private async getFlyoutDashboardData(
        cookies: Cookie[] | undefined,
        fingerprintHeaders: Record<string, string>
    ): Promise<DashboardData> {
        let lastError: unknown

        for (let attempt = 1; attempt <= BrowserFunc.FLYOUT_MAX_ATTEMPTS; attempt++) {
            try {
                const response = await this.bot.http.request<RewardsFlyoutData>({
                    url: URLs.bing.rewardsFlyoutUserInfo,
                    method: 'GET',
                    headers: {
                        ...fingerprintHeaders,
                        Accept: 'application/json',
                        Cookie: this.buildCookieHeader(this.getCachedCookies(cookies, URLs.bing.rewardsFlyoutUserInfo)),
                        Referer: `${URLs.bing.origin}/`,
                        Origin: URLs.bing.origin
                    },
                    retries: 0
                })

                await this.applyResponseCookies(URLs.bing.rewardsFlyoutUserInfo, response.headers['set-cookie'])

                const detection = detectFlyoutBotWarning(response.data)
                this.bot.logger.warn(
                    this.bot.isMobile,
                    'GET-DASHBOARD-DATA',
                    `使用 Bing flyout 部分仪表板 | 疑似受限=${detection.likelyLimited} | bot标记=${detection.hasBotProfileMarkers} | 活动折叠=${detection.hasCollapsedActivities}`
                )
                // 审计：主接口已弃用，记录降级到 flyout 时的 Cookie 状态
                await this.captureSearchCookieSnapshot(
                    'DASHBOARD-FLYOUT',
                    URLs.bing.rewardsFlyoutUserInfo,
                    'flyout',
                    true
                )
                const mappedDashboard = mapFlyoutToDashboard(response.data)
                this.logBotDetectionMetrics(mappedDashboard, 'flyout')
                return mappedDashboard
            } catch (error) {
                lastError = error

                if (attempt < BrowserFunc.FLYOUT_MAX_ATTEMPTS) {
                    const backoffMs = attempt * 3000
                    this.bot.logger.warn(
                        this.bot.isMobile,
                        'GET-DASHBOARD-DATA',
                        `Bing flyout 第 ${attempt}/${BrowserFunc.FLYOUT_MAX_ATTEMPTS} 次失败，${backoffMs / 1000}s 后重试 | 信息=${this.errorMessage(error)}`
                    )
                    await new Promise(resolve => setTimeout(resolve, backoffMs))
                }
            }
        }

        this.bot.logger.error(
            this.bot.isMobile,
            'GET-DASHBOARD-DATA',
            `获取仪表板数据失败（主接口与 Bing flyout 兜底均失败，flyout 已重试 ${BrowserFunc.FLYOUT_MAX_ATTEMPTS} 次）: ${this.errorMessage(lastError)}`
        )
        throw lastError
    }

    /**
     * 解析 serpbotscore。
     *
     * getuserinfo 单次返回里该字段会出现在两处，实测（/tmp/getuserinfo.json 全量键枚举）
     * 两处值完全一致：
     *   - $.dashboard.userProfile.attributes.serpbotscore
     *   - $.profile.attributes.serpbotscore
     * 原因是 FlyoutDashboard.mapFlyoutToDashboard() 里 `dashboard.userProfile = profile`，
     * 两者同源，不存在"不同账户取到不同值"的歧义。因此优先取 dashboard.userProfile，
     * 兜底取 profile，并兼容 Flyout 侧的大小写写法 SerpBotScore / SerpBotScore_upd。
     *
     * 取不到时要区分两种情况，不能一律回退成「未知」：
     *   - 走 flyout 匿名兜底（isRewardsUser:false）时响应里根本没有 profile → 匿名兜底；
     *   - profile 有返回但属性里没这个字段 → 接口未下发。
     */
    private resolveSerpBotScore(data: DashboardData): {
        score: string | null
        updated: string | null
        path: string
        reason: string | null
    } {
        const candidates: Array<{ path: string; attributes: unknown }> = [
            { path: 'dashboard.userProfile.attributes', attributes: data.dashboard?.userProfile?.attributes },
            { path: 'profile.attributes', attributes: data.profile?.attributes }
        ]

        for (const candidate of candidates) {
            const attributes = candidate.attributes as Record<string, unknown> | undefined
            if (!attributes) continue

            const rawScore = attributes.serpbotscore ?? attributes.SerpBotScore
            const rawUpdated = attributes.serpbotscore_upd ?? attributes.SerpBotScore_upd

            if (rawScore !== undefined && rawScore !== null && rawScore !== '') {
                return {
                    score: String(rawScore),
                    updated: rawUpdated === undefined || rawUpdated === null ? null : String(rawUpdated),
                    path: candidate.path,
                    reason: null
                }
            }
        }

        const hasProfile = Boolean(data.dashboard?.userProfile ?? data.profile)
        return {
            score: null,
            updated: null,
            path: '无',
            reason: hasProfile
                ? '字段缺失(profile已返回但未含serpbotscore)'
                : '字段缺失(flyout匿名兜底:未返回profile)'
        }
    }

    private logBotDetectionMetrics(data: DashboardData, source: 'primary' | 'flyout' = 'primary'): void {
        const resolved = this.resolveSerpBotScore(data)
        const warningNames = (data.dashboard?.userWarnings ?? [])
            .map(warning => warning?.name)
            .filter((name): name is string => Boolean(name))
        const platform = this.bot.isMobile ? 'MOBILE' : 'DESKTOP'
        const firstTime = !this.botMetricsLoggedPlatforms.has(platform)
        this.botMetricsLoggedPlatforms.add(platform)

        const message =
            `机器人检测指标 | serpbotscore=${resolved.score ?? resolved.reason ?? '未知'} | 更新时间=${
                resolved.updated ? String(resolved.updated).slice(0, 16) : '未知'
            } | userWarnings=${warningNames.length > 0 ? warningNames.join(', ') : '无'}`

        if (warningNames.length > 0) {
            this.bot.logger.warn(this.bot.isMobile, 'GET-DASHBOARD-DATA', message)
        } else if (firstTime) {
            this.bot.logger.info(this.bot.isMobile, 'GET-DASHBOARD-DATA', message)
        } else {
            this.bot.logger.debug(this.bot.isMobile, 'GET-DASHBOARD-DATA', message)
        }

        // 取值来源单独以 debug 输出，避免改动上面指标行的结构与字段名
        this.bot.logger.debug(
            this.bot.isMobile,
            'GET-DASHBOARD-DATA',
            `serpbotscore 取值 | 数据源=${source} | 平台=${platform} | 路径=${resolved.path} | 分数=${
                resolved.score ?? '未解析'
            } | 更新时间=${resolved.updated ?? '未解析'}`
        )
    }

    private errorMessage(error: unknown): string {
        return error instanceof Error ? error.message : String(error)
    }

    /**
     * 从登录票据里提取身份标识，用于跨轮次判断是否换成了别人的票据（串号）。
     * 优先级：WLS 的 cid → MSPRequ 的 id → .MSA.Auth 前缀 → MUID 前缀。
     */
    private extractCookieOwner(cookies: Cookie[]): string | null {
        const valueOf = (name: string): string | undefined => cookies.find(cookie => cookie.name === name)?.value
        const fieldOf = (value: string | undefined, key: string): string | null => {
            if (!value) return null
            const match = new RegExp(`(?:^|[&;])${key}=([^&;]+)`).exec(value)
            return match?.[1] ?? null
        }

        const cid = fieldOf(valueOf('WLS'), 'cid')
        if (cid) return `cid=${cid.slice(0, 12)}`

        const mspId = fieldOf(valueOf('MSPRequ'), 'id')
        if (mspId) return `MSPRequ=${mspId.slice(0, 12)}`

        const msa = valueOf('.MSA.Auth')
        if (msa) return `MSA=${msa.slice(0, 12)}`

        const muid = valueOf('MUID')
        if (muid) return `MUID=${muid.slice(0, 12)}`

        return null
    }

    /**
     * 同一账户同一平台的登录票据身份在多轮之间应保持一致；首次采集视为一致。
     * 按「账户|平台」分别记录 —— 移动端与桌面端的票据种类不同（一个有 .MSA.Auth、
     * 一个只有 MUID），混在一起比会误报串号。
     */
    private checkCookieOwnerMatches(account: string, platform: string, owner: string | null): boolean {
        if (!owner) return false
        const key = `${account}|${platform}`
        const previous = this.cookieOwnerTrail.get(key)
        this.cookieOwnerTrail.set(key, owner)
        return previous === undefined || previous === owner
    }

    /**
     * 采集一次 Cookie 快照（搜索计分链路审计用）。
     *
     * 回答四个问题：
     *   1) 来源 —— 请求实际携带的 Cookie 来自会话缓存（cache）还是浏览器 context 实时态（live），两者是否同步；
     *   2) 关键字段 —— Rewards 计分依赖的身份 Cookie 是否齐全；
     *   3) 账户同步 —— 账户 / 平台切换后 Cookie 指纹有没有跟着更新；
     *   4) 归属 —— 登录票据的身份标识在多轮之间是否稳定（防止串号）。
     *
     * 日志策略：只有「首次采集」「指纹变化」「force=true」时才输出 info 行，其余走 debug，
     * 避免每次搜索都刷屏。
     */
    async captureSearchCookieSnapshot(
        source: string,
        targetUrl: string = URLs.bing.origin,
        dashboardSource: 'primary' | 'flyout' = 'primary',
        force = false,
        liveOverride?: Cookie[]
    ): Promise<SearchCookieSnapshot | null> {
        const platform: 'MOBILE' | 'DESKTOP' = this.bot.isMobile ? 'MOBILE' : 'DESKTOP'
        const account = this.bot.currentAccountEmail || '未知账户'

        let cached: Cookie[] = []
        try {
            cached = this.getCachedCookies(undefined, targetUrl)
        } catch {
            cached = []
        }

        let live: Cookie[] | null = null
        if (liveOverride) {
            live = this.filterCookiesForUrl(liveOverride, targetUrl)
        } else {
            const page = this.getActivePage()
            if (page) {
                try {
                    live = this.filterCookiesForUrl(await page.context().cookies(), targetUrl)
                } catch {
                    live = null
                }
            }
        }

        // buildCookieHeader 实际带上的是缓存集；缓存为空时才退化为实时集
        const effective = cached.length > 0 ? cached : live ?? []
        const byName = new Map<string, Cookie>()
        for (const cookie of effective) {
            if (!byName.has(cookie.name)) byName.set(cookie.name, cookie)
        }

        const present: string[] = []
        const missing: string[] = []
        let rewardsCount = 0
        let bingCount = 0
        for (const { name, group } of SEARCH_KEY_COOKIES) {
            if (byName.has(name)) {
                present.push(name)
                if (group === 'rewards') rewardsCount++
                else if (group === 'bing') bingCount++
            } else {
                missing.push(name)
            }
        }

        const fingerprint = createHash('sha1')
            .update(
                effective
                    .map(cookie => `${cookie.domain}|${cookie.path}|${cookie.name}|${cookie.value}`)
                    .sort()
                    .join('\n')
            )
            .digest('hex')
            .slice(0, 12)

        const owner = this.extractCookieOwner(effective)
        const ownerMatches = this.checkCookieOwnerMatches(account, platform, owner)

        // 同步判定只看「同名 Cookie 的值有没有冲突」：
        // 缓存里多出几条浏览器已删掉的陈旧项不影响计分，因此不计入不同步，只单独统计。
        let inSync: boolean | null = null
        let cacheOnlyCount = 0
        if (live) {
            const liveByKey = new Map(live.map(cookie => [`${cookie.domain}|${cookie.name}`, cookie.value]))
            const conflicting = cached.filter(
                cookie =>
                    liveByKey.has(`${cookie.domain}|${cookie.name}`) &&
                    liveByKey.get(`${cookie.domain}|${cookie.name}`) !== cookie.value
            )
            cacheOnlyCount = cached.filter(cookie => !liveByKey.has(`${cookie.domain}|${cookie.name}`)).length
            inSync = conflicting.length === 0
        }

        const snapshot: SearchCookieSnapshot = {
            platform,
            account,
            cacheSource: source,
            cachedCount: cached.length,
            liveCount: live ? live.length : null,
            inSync,
            cacheOnlyCount,
            owner: owner ?? '无',
            ownerMatches,
            rewardsCount,
            bingCount,
            present,
            missing,
            fingerprint,
            dashboardSource
        }

        // 与上一次采集比对，判断「账户切换后是否同步更新」
        const previous = this.cookieAuditTrail
        let changeNote = '首次采集'
        if (previous) {
            if (previous.account !== account && previous.platform !== platform) {
                changeNote =
                    fingerprint !== previous.fingerprint ? '账户+平台切换:已同步更新' : '账户+平台切换:未同步(指纹未变)'
            } else if (previous.account !== account) {
                changeNote = fingerprint !== previous.fingerprint ? '账户切换:已同步更新' : '账户切换:未同步(指纹未变)'
            } else if (previous.platform !== platform) {
                changeNote = fingerprint !== previous.fingerprint ? '平台切换:已切换Cookie集' : '平台切换:指纹相同'
            } else {
                changeNote = fingerprint !== previous.fingerprint ? '同账户:指纹已刷新' : '同账户:指纹稳定'
            }
        }
        this.cookieAuditTrail = { account, platform, fingerprint }

        const detail =
            `Cookie 快照 | 来源=${source} | 账户=${account} | 平台=${platform} | 缓存=${cached.length} | 实时=${
                live ? live.length : '不可用'
            } | 缓存与浏览器同步=${inSync === null ? '未知' : inSync ? '是' : '否'} | 缓存陈旧项=${cacheOnlyCount} | 身份=${
                owner ?? '无'
            } | 归属一致=${ownerMatches ? '是' : '否'} | rewards关键=${rewardsCount}/3 | bing关键=${bingCount}/8 | 缺失=${
                missing.length ? missing.join(',') : '无'
            } | 指纹=${fingerprint} | 比对=${changeNote} | 仪表板=${dashboardSource}`

        if (force || !previous || previous.fingerprint !== fingerprint) {
            this.bot.logger.info(this.bot.isMobile, 'COOKIE-AUDIT', detail)
        } else {
            this.bot.logger.debug(this.bot.isMobile, 'COOKIE-AUDIT', detail)
        }

        return snapshot
    }

    /**
     * 依据 Cookie 快照判定「本轮未获得积分」是不是 Cookie 引起的。
     * 供搜索流程在 gained === 0 时调用，直接给出可读结论。
     */
    explainZeroPoints(snapshot: SearchCookieSnapshot | null): string {
        if (!snapshot) return '结论=无法判定(未取到 Cookie 快照)'

        const identity = snapshot.present.filter(name => name === '_C_Auth' || name === 'tifacfaatcs')
        if (identity.length === 0) {
            return `结论=是(Cookie 失效导致): 缺少 Rewards 身份票据(${
                snapshot.missing.join(',') || '无'
            })，请求会被服务端判为未登录`
        }
        if (snapshot.inSync === false) {
            return '结论=疑似(Cookie 失效导致): 会话缓存与浏览器实时 Cookie 存在同名但值不同的票据，请求携带的可能是过期票据'
        }
        if (!snapshot.ownerMatches) {
            return `结论=疑似(串号): 登录票据身份(${snapshot.owner})与该账户历史记录不一致`
        }
        return `结论=否(非 Cookie 导致): 身份票据齐全(${identity.join(',')})，且与浏览器实时态一致${
            snapshot.cacheOnlyCount > 0 ? `（另有 ${snapshot.cacheOnlyCount} 条陈旧缓存项，不影响计分）` : ''
        }，0 积分另有原因（当日额度已用尽 / 服务端计分延迟 / 接口判定未计分）`
    }

    async getAppDashboardData(): Promise<AppDashboardData> {
        try {
            const request: HttpRequestConfig = {
                url: URLs.platform.me('SAIOS'),
                method: 'GET',
                headers: {
                    Authorization: `Bearer ${this.bot.accessToken}`,
                    'User-Agent': BING_APP_USER_AGENT,
                    'X-Rewards-Country': this.bot.userData.geoLocale,
                    'X-Rewards-Language': this.bot.userData.langCode,
                    'X-Rewards-IsMobile': 'true'
                }
            }

            const response = await this.bot.http.request(request)
            return response.data as AppDashboardData
        } catch (error) {
            this.bot.logger.error(
                this.bot.isMobile,
                'GET-APP-DASHBOARD-DATA',
                `获取 App 仪表板数据出错: ${error instanceof Error ? error.message : String(error)}`
            )
            throw error
        }
    }

    async getBrowserEarnablePoints(data?: DashboardData): Promise<BrowserEarnablePoints> {
        try {
            data ??= await this.getDashboardData()

            const desktopSearchPoints =
                data.dashboard.userStatus.counters.pcSearch?.reduce(
                    (sum: number, x: { pointProgressMax: number; pointProgress: number }) =>
                        sum + (x.pointProgressMax - x.pointProgress),
                    0
                ) ?? 0

            const mobileSearchPoints =
                data.dashboard.userStatus.counters.mobileSearch?.reduce(
                    (sum: number, x: { pointProgressMax: number; pointProgress: number }) =>
                        sum + (x.pointProgressMax - x.pointProgress),
                    0
                ) ?? 0

            const todayDate = this.bot.utils.getFormattedDate()
            const dailySetPoints =
                data.dashboard.dailySetPromotions[todayDate]?.reduce(
                    (sum: number, x: { pointProgressMax: number; pointProgress: number }) =>
                        sum + (x.pointProgressMax - x.pointProgress),
                    0
                ) ?? 0

            const morePromotionsPoints =
                data.dashboard.morePromotions?.reduce((sum, x) => {
                    if (x.promotionType === 'urlreward' && x.exclusiveLockedFeatureStatus !== 'locked') {
                        return sum + (x.pointProgressMax - x.pointProgress)
                    }
                    return sum
                }, 0) ?? 0

            const totalEarnablePoints = desktopSearchPoints + mobileSearchPoints + dailySetPoints + morePromotionsPoints

            return {
                dailySetPoints,
                morePromotionsPoints,
                desktopSearchPoints,
                mobileSearchPoints,
                totalEarnablePoints
            }
        } catch (error) {
            this.bot.logger.error(
                this.bot.isMobile,
                'GET-BROWSER-EARNABLE-POINTS',
                `发生错误: ${error instanceof Error ? error.message : String(error)}`
            )
            throw error
        }
    }

    async getAppEarnablePoints(): Promise<AppEarnablePoints> {
        try {
            const eligibleOffers = ['ENUS_readarticle3_30points', 'Gamification_Sapphire_DailyCheckIn']

            const request: HttpRequestConfig = {
                url: URLs.platform.me('SAAndroid'),
                method: 'GET',
                headers: {
                    Authorization: `Bearer ${this.bot.accessToken}`,
                    'X-Rewards-Country': this.bot.userData.geoLocale,
                    'X-Rewards-Language': this.bot.userData.langCode,
                    'X-Rewards-ismobile': 'true'
                }
            }

            const response = await this.bot.http.request<AppUserData>(request)
            const userData: AppUserData = response.data
            const eligibleActivities = userData.response.promotions.filter(x =>
                eligibleOffers.includes(x.attributes.offerid ?? '')
            )

            let readToEarn = 0
            let checkIn = 0

            for (const item of eligibleActivities) {
                const attrs = item.attributes

                if (attrs.type === 'msnreadearn') {
                    const pointMax = parseInt(attrs.pointmax ?? '0')
                    const pointProgress = parseInt(attrs.pointprogress ?? '0')
                    readToEarn = Math.max(0, pointMax - pointProgress)
                } else if (attrs.type === 'checkin') {
                    const progress = parseInt(attrs.progress ?? '0')
                    const checkInDay = progress % 7
                    const lastUpdated = new Date(attrs.last_updated ?? '')
                    const today = new Date()

                    if (checkInDay < 6 && today.getDate() !== lastUpdated.getDate()) {
                        checkIn = parseInt(attrs[`day_${checkInDay + 1}_points`] ?? '0')
                    }
                }
            }

            const totalEarnablePoints = readToEarn + checkIn

            return {
                readToEarn,
                checkIn,
                totalEarnablePoints
            }
        } catch (error) {
            this.bot.logger.error(
                this.bot.isMobile,
                'GET-APP-EARNABLE-POINTS',
                `发生错误: ${error instanceof Error ? error.message : String(error)}`
            )
            throw error
        }
    }

    async getCurrentPoints(): Promise<number> {
        try {
            const data = await this.getDashboardData()

            return data.dashboard.userStatus.availablePoints
        } catch (error) {
            this.bot.logger.error(
                this.bot.isMobile,
                'GET-CURRENT-POINTS',
                `发生错误: ${error instanceof Error ? error.message : String(error)}`
            )
            throw error
        }
    }

    async bootstrap(page: Page): Promise<void> {
        try {
            // /earn is the offers page
            await page.goto(URLs.rewards.earn, { waitUntil: 'domcontentloaded' })

            const earnDom = await page.content()
            const earnRaw = await this.fetchBootstrapHtml(page, URLs.rewards.earn, '/earn')

            this.rewardsDeploymentId = this.bot.browser.react.buildId(earnRaw || earnDom) ?? ''

            this.bot.nextRouterStateTree = this.bot.browser.react.routerStateTree('earn')

            // pull /dashboard HTML to capture chunks that /earn doesn't show
            const dashboardHtml = await this.fetchBootstrapHtml(page, URLs.rewards.dashboard, '/dashboard')

            const sources = [earnRaw, earnDom, dashboardHtml].filter(Boolean)
            const snapshot = this.bot.browser.react.snapshotPage(sources)
            this.bot.reactSnapshot = snapshot
            if (this.bot.isMobile) this.bot.reactSnapshots.mobile = snapshot
            else this.bot.reactSnapshots.desktop = snapshot

            // discovered from chunks referenced by either page
            this.bot.nextActions = await this.resolveActionIds(page, sources)

            const dashboardRendered = /<section\b[^>]*\bid=["']dailyset["']/i.test(sources.join('\n'))
            if (!dashboardRendered) {
                throw new Error(
                    'Rewards dashboard did not render (no section#dailyset) - likely a login/redirect issue, aborting'
                )
            }

            if (!this.bot.reactSnapshot.offers.length) {
                this.bot.logger.warn(
                    this.bot.isMobile,
                    'BOOTSTRAP',
                    '未解析到任何优惠活动 - 页面可能未渲染 RSC 载荷（请检查登录/重定向）'
                )
            }

            if (!Object.keys(this.bot.nextActions).length) {
                this.bot.logger.warn(
                    this.bot.isMobile,
                    'BOOTSTRAP',
                    '未发现任何 action id - server-action 调用将失败（bundle 可能已剥离名称）'
                )
            }

            this.bot.logger.info(
                this.bot.isMobile,
                'BOOTSTRAP',
                `上下文就绪 | actions=${Object.keys(this.bot.nextActions).length} | 可上报=${this.bot.reactSnapshot.reportable.length} | 可用积分=${this.bot.reactSnapshot.account.availablePoints}`
            )

            this.bot.logger.info(
                this.bot.isMobile,
                'BUILD',
                `Rewards 构建 | id=${this.rewardsDeploymentId || 'unknown'}`,
                'cyan'
            )
        } catch (error) {
            this.bot.logger.error(
                this.bot.isMobile,
                'BOOTSTRAP',
                `获取上下文失败 | 错误=${error instanceof Error ? error.message : String(error)}`
            )
            throw error
        }
    }

    private async fetchBootstrapHtml(page: Page, url: string, route: string): Promise<string> {
        try {
            const res = await page.request.get(url, { timeout: 20000 })
            if (res.ok()) return await res.text()

            this.bot.logger.warn(
                this.bot.isMobile,
                'BOOTSTRAP',
                `获取 ${route} HTML 失败 | 状态码=${res.status()} - 快照和 action 发现可能不完整`
            )
        } catch (error) {
            this.bot.logger.warn(
                this.bot.isMobile,
                'BOOTSTRAP',
                `获取 ${route} HTML 失败 | 错误=${error instanceof Error ? error.message : String(error)} - 快照和 action 发现可能不完整`
            )
        }

        return ''
    }

    private async resolveActionIds(page: Page, htmls: string[]): Promise<Record<string, string>> {
        const result: Record<string, string> = {}

        try {
            const initialChunks = new Set<string>()
            const chunkRegex = /(?:\/_next\/)?(static\/(?:chunks|immutable|media)\/[\w\-./()]+?\.js)/g
            for (const html of htmls) {
                if (!html) continue
                for (const match of html.matchAll(chunkRegex)) {
                    initialChunks.add('/_next/' + match[1]!)
                }
            }

            if (initialChunks.size === 0) {
                this.bot.logger.warn(
                    this.bot.isMobile,
                    'BOOTSTRAP',
                    '未在 HTML 中发现初始代码块 - 代码块引用形式可能已变化'
                )
            }

            this.bot.logger.debug(this.bot.isMobile, 'BOOTSTRAP', `正在获取 ${initialChunks.size} 个初始 JS 代码块`)
            const jsByPath = await this.fetchJsChunks(page, [...initialChunks])

            const dynamicPaths = new Set<string>()
            for (const js of jsByPath.values()) {
                for (const path of this.extractDynamicChunkPaths(js)) {
                    if (!jsByPath.has(path)) dynamicPaths.add(path)
                }
            }

            if (dynamicPaths.size) {
                this.bot.logger.debug(
                    this.bot.isMobile,
                    'BOOTSTRAP',
                    `正在获取通过 webpack manifest 发现的 ${dynamicPaths.size} 个动态代码块`
                )
                const moreJs = await this.fetchJsChunks(page, [...dynamicPaths])
                for (const [path, js] of moreJs) jsByPath.set(path, js)
            }

            for (const [path, js] of jsByPath) {
                const filename = path.split('/').pop() ?? path
                const ids = this.bot.browser.react.extractActionIds(js)
                const names = Object.keys(ids.byName)

                if (names.length) {
                    Object.assign(result, ids.byName)
                    this.bot.logger.debug(
                        this.bot.isMobile,
                        'BOOTSTRAP',
                        `在 ${filename} 中发现 ${names.length} 个 action id: [${names.join(', ')}]`
                    )
                } else {
                    this.bot.logger.debug(this.bot.isMobile, 'BOOTSTRAP', `在 ${filename} 中未发现 server-action id`)
                }

                const namedSet = new Set(Object.values(ids.byName))
                const unnamed = ids.all.filter(id => !namedSet.has(id))
                if (unnamed.length) {
                    this.bot.logger.debug(
                        this.bot.isMobile,
                        'BOOTSTRAP',
                        `在 ${filename} 中发现 ${unnamed.length} 个未命名 action id: [${unnamed.join(', ')}]`
                    )
                }
            }

            this.bot.logger.debug(
                this.bot.isMobile,
                'BOOTSTRAP',
                `已发现 ${Object.keys(result).length} 个 action id: [${Object.keys(result).join(', ')}]`
            )
        } catch (error) {
            this.bot.logger.error(
                this.bot.isMobile,
                'BOOTSTRAP',
                `解析 action id 失败 | 错误=${error instanceof Error ? error.message : String(error)}`
            )
        }

        return result
    }

    private async fetchJsChunks(page: Page, paths: string[]): Promise<Map<string, string>> {
        const result = new Map<string, string>()

        await Promise.all(
            paths.map(async path => {
                try {
                    const res = await page.request.get(URLs.rewards.path(path))
                    if (res.ok()) {
                        result.set(path, await res.text())
                    }
                } catch (error) {
                    this.bot.logger.debug(
                        this.bot.isMobile,
                        'BOOTSTRAP',
                        `代码块获取失败 | 路径=${path} | ${error instanceof Error ? error.message : String(error)}`
                    )
                }
            })
        )

        return result
    }

    private extractDynamicChunkPaths(js: string): string[] {
        const seen = new Set<string>()

        // Webpack builder
        const builder = /static\/chunks\/"\s*\+\s*\w+\s*\+\s*"([-.])"\s*\+\s*\{([\s\S]*?)\}\s*\[/g
        for (const match of js.matchAll(builder)) {
            const sep = match[1]!
            for (const [, id, hash] of match[2]!.matchAll(/(\d+)\s*:\s*"([a-f0-9]+)"/g)) {
                seen.add(`/_next/static/chunks/${id}${sep}${hash}.js`)
            }
        }

        // Webpack fallback
        for (const [, id, hash] of js.matchAll(/\b(\d{2,6}):"([a-f0-9]{12,})"/g)) {
            seen.add(`/_next/static/chunks/${id}-${hash}.js`)
            seen.add(`/_next/static/chunks/${id}.${hash}.js`)
        }

        // Turbopack
        const turbopackRegex = /"(static\/(?:immutable|chunks|media)\/[\w\-./()]+?\.js)"/g
        for (const match of js.matchAll(turbopackRegex)) {
            seen.add(`/_next/${match[1]}`)
        }

        return [...seen]
    }

    async closeBrowser(browser: BrowserContext, email: string, persistSession = true) {
        const rootBrowser = browser.browser?.() || null

        try {
            if (persistSession) {
                const storageState = await browser.storageState()
                this.bot.logger.debug(
                    this.bot.isMobile,
                    'CLOSE-BROWSER',
                    `正在保存会话 | Cookie数=${storageState.cookies.length} | origins=${storageState.origins.length}`
                )
                saveStorageState(this.bot.config.sessionPath, email, this.bot.isMobile, storageState)
            }
        } catch (error) {
            if (isBrowserClosedError(error)) {
                this.bot.logger.debug(
                    this.bot.isMobile,
                    'CLOSE-BROWSER',
                    `会话未保存（浏览器已在关闭中）: ${error instanceof Error ? error.message : String(error)}`
                )
            } else {
                this.bot.logger.error(this.bot.isMobile, 'CLOSE-BROWSER', `保存会话失败: ${error}`)
            }
        } finally {
            try {
                await browser.close()

                if (rootBrowser) {
                    await rootBrowser.close().catch(() => {})
                }

                this.bot.logger.info(this.bot.isMobile, 'CLOSE-BROWSER', '所有浏览器资源已关闭。')
            } catch (error) {
                if (isBrowserClosedError(error)) {
                    this.bot.logger.debug(this.bot.isMobile, 'CLOSE-BROWSER', '浏览器已处于关闭状态。')
                } else {
                    this.bot.logger.warn(
                        this.bot.isMobile,
                        'CLOSE-BROWSER',
                        '关闭时遇到错误，但进程仍在退出。'
                    )
                }
            }
        }
    }

    private getActivePage(): Page | null {
        const page = this.bot.isMobile ? this.bot.mainMobilePage : this.bot.mainDesktopPage
        return page && !page.isClosed() ? page : null
    }

    async getRewardsPageHtml(url: string, route: string): Promise<string | null> {
        const direct = await this.fetchRewardsHtml(url, route)
        if (direct !== null) return direct

        const page = this.getActivePage()
        if (!page) return null

        try {
            const response = await page.request.get(url, { timeout: 20000 })
            if (response.ok()) {
                await this.syncActiveCookies(page, 'REWARDS-PAGE')
                return await response.text()
            }

            this.bot.logger.debug(
                this.bot.isMobile,
                'REWARDS-PAGE',
                `获取 ${route} 失败 | 状态码=${response.status()}`
            )
        } catch (error) {
            this.bot.logger.debug(
                this.bot.isMobile,
                'REWARDS-PAGE',
                `浏览器请求 ${route} 失败 | ${error instanceof Error ? error.message : String(error)}`
            )
        }

        return null
    }

    private getCachedCookies(explicitCookies?: Cookie[], targetUrl?: string): Cookie[] {
        const cookies = explicitCookies ?? (this.bot.isMobile ? this.bot.cookies.mobile : this.bot.cookies.desktop)
        return targetUrl ? this.filterCookiesForUrl(cookies, targetUrl) : cookies
    }

    async checkpointActiveSession(source = 'SESSION-CHECKPOINT'): Promise<boolean> {
        const page = this.getActivePage()
        if (!page) {
            this.bot.logger.debug(
                this.bot.isMobile,
                source,
                '无法保存会话检查点，因为没有可用的活动浏览器页面'
            )
            return false
        }

        try {
            await this.syncActiveCookies(page, source, true)
            return true
        } catch (error) {
            this.bot.logger.debug(
                this.bot.isMobile,
                source,
                `无法保存活动会话检查点 | 错误=${error instanceof Error ? error.message : String(error)}`
            )
            return false
        }
    }

    async synchronizeActiveBrowserCookies(source: string, applyCached = false): Promise<boolean> {
        const page = this.getActivePage()
        if (!page) return false

        try {
            const context = page.context()
            let liveCookies = await context.cookies()

            if (applyCached) {
                const now = Date.now() / 1000
                const liveByKey = new Map(
                    liveCookies.map(cookie => [`${cookie.domain}|${cookie.path}|${cookie.name}`, cookie])
                )
                const changed = this.getCachedCookies().filter(cookie => {
                    if (cookie.expires !== -1 && cookie.expires <= now) return false
                    const live = liveByKey.get(`${cookie.domain}|${cookie.path}|${cookie.name}`)
                    return (
                        !live ||
                        live.value !== cookie.value ||
                        live.expires !== cookie.expires ||
                        live.httpOnly !== cookie.httpOnly ||
                        live.secure !== cookie.secure ||
                        live.sameSite !== cookie.sameSite
                    )
                })

                if (changed.length) {
                    await context.addCookies(changed)
                    liveCookies = await context.cookies()
                }
            }

            this.updateCookieCache(liveCookies, source)

            // 审计：搜索请求打向 bing.com，按该目标记录一次快照（复用刚取到的实时 Cookie，避免重复 IPC）
            await this.captureSearchCookieSnapshot(
                source,
                URLs.bing.origin,
                this.useFlyoutDashboardFallback ? 'flyout' : 'primary',
                false,
                liveCookies
            )

            return true
        } catch (error) {
            this.bot.logger.debug(
                this.bot.isMobile,
                source,
                `无法同步活动浏览器 Cookie | 错误=${error instanceof Error ? error.message : String(error)}`
            )
            return false
        }
    }

    private updateCookieCache(liveCookies: Cookie[], source: string): boolean {
        const cachedCookies = this.bot.isMobile ? this.bot.cookies.mobile : this.bot.cookies.desktop
        const cookieState = (cookie: Cookie) =>
            JSON.stringify({
                value: cookie.value,
                expires: cookie.expires,
                httpOnly: cookie.httpOnly,
                secure: cookie.secure,
                sameSite: cookie.sameSite
            })
        const cachedByKey = new Map(
            cachedCookies.map(cookie => [`${cookie.domain}|${cookie.path}|${cookie.name}`, cookieState(cookie)])
        )
        const changed =
            cachedCookies.length !== liveCookies.length ||
            liveCookies.some(
                cookie => cachedByKey.get(`${cookie.domain}|${cookie.path}|${cookie.name}`) !== cookieState(cookie)
            )

        if (this.bot.isMobile) this.bot.cookies.mobile = liveCookies
        else this.bot.cookies.desktop = liveCookies

        if (changed) {
            this.bot.logger.debug(
                this.bot.isMobile,
                source,
                `已刷新 Cookie 缓存 | 之前=${cachedCookies.length} | 当前=${liveCookies.length}`
            )
        }

        return changed
    }

    private async syncActiveCookies(page: Page, source: string, forcePersist = false): Promise<void> {
        try {
            const context = page.context()
            const liveCookies = await context.cookies()
            const changed = this.updateCookieCache(liveCookies, source)
            if (!changed && !forcePersist) return

            const email = this.bot.currentAccountEmail
            if (!email) return

            const storageState = await context.storageState()
            saveStorageState(this.bot.config.sessionPath, email, this.bot.isMobile, storageState)
            this.bot.logger.debug(
                this.bot.isMobile,
                source,
                `已持久化活动浏览器会话 | Cookie数=${storageState.cookies.length} | origins=${storageState.origins.length}`
            )
        } catch (error) {
            this.bot.logger.debug(
                this.bot.isMobile,
                source,
                `无法持久化刷新后的 Cookie | 错误=${error instanceof Error ? error.message : String(error)}`
            )
        }
    }

    private filterCookiesForUrl(cookies: Cookie[], targetUrl: string): Cookie[] {
        const url = new URL(targetUrl)
        const host = url.hostname.toLowerCase()
        const requestPath = url.pathname || '/'
        const now = Date.now() / 1000

        return cookies
            .filter(cookie => {
                if (cookie.expires !== -1 && cookie.expires <= now) return false
                if (cookie.secure && url.protocol !== 'https:') return false

                const domain = cookie.domain.replace(/^\./, '').toLowerCase()
                if (host !== domain && !host.endsWith(`.${domain}`)) return false

                const cookiePath = cookie.path || '/'
                if (!requestPath.startsWith(cookiePath)) return false
                if (
                    requestPath.length > cookiePath.length &&
                    !cookiePath.endsWith('/') &&
                    requestPath.charAt(cookiePath.length) !== '/'
                )
                    return false

                return true
            })
            .sort((a, b) => (b.path?.length ?? 0) - (a.path?.length ?? 0))
    }

    private async applyResponseCookies(requestUrl: string, setCookieHeader?: string[] | string): Promise<void> {
        if (!setCookieHeader) return

        const rawCookies = Array.isArray(setCookieHeader)
            ? setCookieHeader
            : this.splitCombinedSetCookieHeader(setCookieHeader)
        if (!rawCookies.length) return

        const current = this.bot.isMobile ? this.bot.cookies.mobile : this.bot.cookies.desktop
        const updated = [...current]
        let changed = false

        for (const raw of rawCookies) {
            const parsed = this.parseSetCookie(raw, requestUrl)
            if (!parsed) continue

            const keyMatches = (cookie: Cookie) =>
                cookie.name === parsed.cookie.name &&
                cookie.domain === parsed.cookie.domain &&
                cookie.path === parsed.cookie.path
            const index = updated.findIndex(keyMatches)

            if (parsed.remove) {
                if (index >= 0) {
                    updated.splice(index, 1)
                    changed = true
                }
                continue
            }

            if (index >= 0) {
                if (JSON.stringify(updated[index]) !== JSON.stringify(parsed.cookie)) {
                    updated[index] = parsed.cookie
                    changed = true
                }
            } else {
                updated.push(parsed.cookie)
                changed = true
            }
        }

        if (!changed) return

        this.updateCookieCache(updated, 'COOKIE-SYNC')

        const email = this.bot.currentAccountEmail
        if (!email) return

        const saved = loadSession(this.bot.config.sessionPath, email, this.bot.isMobile)
        saveStorageState(this.bot.config.sessionPath, email, this.bot.isMobile, {
            cookies: updated,
            origins: saved?.storageState?.origins ?? []
        })
        this.bot.logger.debug(
            this.bot.isMobile,
            'COOKIE-SYNC',
            `已应用 ${rawCookies.length} 个响应 Cookie 并持久化更新后的会话`
        )
    }

    private parseSetCookie(raw: string, requestUrl: string): { cookie: Cookie; remove: boolean } | null {
        const parts = raw.split(';').map(part => part.trim())
        const first = parts.shift()
        if (!first) return null

        const equals = first.indexOf('=')
        if (equals <= 0) return null

        const request = new URL(requestUrl)
        const name = first.slice(0, equals).trim()
        const value = first.slice(equals + 1)
        let domain = request.hostname
        let cookiePath = this.defaultCookiePath(request.pathname)
        let expires = -1
        let secure = false
        let httpOnly = false
        let sameSite: Cookie['sameSite'] = 'Lax'
        let remove = false

        for (const attribute of parts) {
            const separator = attribute.indexOf('=')
            const attributeName = (separator < 0 ? attribute : attribute.slice(0, separator)).trim().toLowerCase()
            const attributeValue = separator < 0 ? '' : attribute.slice(separator + 1).trim()

            if (attributeName === 'domain' && attributeValue) domain = attributeValue.toLowerCase()
            else if (attributeName === 'path' && attributeValue) cookiePath = attributeValue
            else if (attributeName === 'secure') secure = true
            else if (attributeName === 'httponly') httpOnly = true
            else if (attributeName === 'expires' && attributeValue) {
                const parsed = Date.parse(attributeValue)
                if (Number.isFinite(parsed)) expires = parsed / 1000
            } else if (attributeName === 'max-age' && attributeValue) {
                const seconds = Number(attributeValue)
                if (Number.isFinite(seconds)) {
                    if (seconds <= 0) remove = true
                    else expires = Date.now() / 1000 + seconds
                }
            } else if (attributeName === 'samesite') {
                const normalized = attributeValue.toLowerCase()
                if (normalized === 'strict') sameSite = 'Strict'
                else if (normalized === 'none') sameSite = 'None'
                else sameSite = 'Lax'
            }
        }

        if (expires !== -1 && expires <= Date.now() / 1000) remove = true

        return {
            cookie: { name, value, domain, path: cookiePath, expires, httpOnly, secure, sameSite },
            remove
        }
    }

    private defaultCookiePath(pathname: string): string {
        if (!pathname || !pathname.startsWith('/') || pathname === '/') return '/'
        const lastSlash = pathname.lastIndexOf('/')
        return lastSlash <= 0 ? '/' : pathname.slice(0, lastSlash)
    }

    private splitCombinedSetCookieHeader(header: string): string[] {
        return header
            .split(/,(?=\s*[^;,=\s]+=[^;,]*)/g)
            .map(value => value.trim())
            .filter(Boolean)
    }

    buildCookieHeader(cookies: Cookie[], allowedDomains?: string[]): string {
        return cookies
            .filter(cookie => {
                if (!allowedDomains?.length) return true
                return allowedDomains.some(domain => cookie.domain.toLowerCase().endsWith(domain.toLowerCase()))
            })
            .map(cookie => `${cookie.name}=${cookie.value}`)
            .join('; ')
    }

    // Fire a nextjs RSC server action shared by UrlReward / ClaimReward / ClaimBonusPoints
    async reportServerAction(
        actionId: string,
        body: unknown[],
        opts?: { url?: string; referer?: string; routerStateTree?: string }
    ): Promise<{ status: number; acknowledged: boolean; availablePoints: number | null }> {
        const url = opts?.url ?? URLs.rewards.earn
        const referer = opts?.referer ?? url
        const routerStateTree = opts?.routerStateTree ?? this.bot.nextRouterStateTree

        const fingerprintHeaders = { ...this.bot.fingerprint.headers }
        delete fingerprintHeaders['Cookie']
        delete fingerprintHeaders['cookie']

        const headers = {
            ...fingerprintHeaders,
            Referer: referer,
            Origin: URLs.rewards.origin,
            Accept: 'text/x-component',
            'Content-Type': 'text/plain;charset=UTF-8',
            'Next-Action': actionId,
            'Next-Router-State-Tree': routerStateTree,
            ...(this.rewardsDeploymentId ? { 'X-Deployment-Id': this.rewardsDeploymentId } : {})
        }

        const response = await this.bot.http.request({
            url,
            method: 'POST',
            headers: {
                ...headers,
                Cookie: this.buildCookieHeader(this.getCachedCookies(undefined, url))
            },
            data: JSON.stringify(body)
        })
        await this.applyResponseCookies(url, response.headers['set-cookie'])

        return {
            status: response.status,
            acknowledged: this.bot.utils.serverActionAcknowledged(response.data),
            availablePoints: this.bot.browser.react.availablePointsFromPayload(response.data)
        }
    }

    async refreshEarnSnapshot(): Promise<PageSnapshot | null> {
        const page = this.bot.isMobile ? this.bot.mainMobilePage : this.bot.mainDesktopPage
        const usePage = !!page && !page.isClosed()

        const fetchSnapshotPage = async (url: string, route: string): Promise<string | null> => {
            if (!usePage) return await this.fetchRewardsHtml(url, route)
            return await this.getRewardsPageHtml(url, route)
        }

        const pages = await Promise.all([
            fetchSnapshotPage(URLs.rewards.earn, '/earn'),
            fetchSnapshotPage(URLs.rewards.dashboard, '/dashboard')
        ])
        const availablePages = pages.filter((html): html is string => html !== null)

        return availablePages.length ? this.bot.browser.react.snapshotPage(availablePages) : null
    }

    private async fetchRewardsHtml(url: string, route: string): Promise<string | null> {
        try {
            const headers = { ...(this.bot.fingerprint?.headers ?? {}) }
            delete headers['Cookie']
            delete headers['cookie']

            const response = await this.bot.http.request<string>({
                url,
                method: 'GET',
                headers: {
                    ...headers,
                    Cookie: this.buildCookieHeader(this.getCachedCookies(undefined, url)),
                    Referer: URLs.rewards.referer,
                    Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
                },
                responseType: 'text'
            })

            await this.applyResponseCookies(url, response.headers['set-cookie'])
            return typeof response.data === 'string' ? response.data : null
        } catch (error) {
            this.bot.logger.debug(
                this.bot.isMobile,
                'EARN-SNAPSHOT',
                `通过 HTTP 获取 ${route} 失败 | ${error instanceof Error ? error.message : String(error)}`
            )
            return null
        }
    }

    async ensureOffer(offerId: string): Promise<ParsedOffer | null> {
        const cached = this.bot.reactSnapshot?.offers.find(o => o.offerId === offerId)
        if (cached) return cached

        this.bot.logger.debug(
            this.bot.isMobile,
            'EARN-SNAPSHOT',
            `${offerId} 不在缓存快照中 (offers=${this.bot.reactSnapshot?.offers.length ?? 0}) - 正在重新获取 /earn 和 /dashboard`
        )

        const refreshed = await this.refreshEarnSnapshot()
        if (!refreshed) return null

        if (!this.bot.reactSnapshot || refreshed.offers.length >= this.bot.reactSnapshot.offers.length) {
            this.bot.reactSnapshot = refreshed
        }

        const live = refreshed.offers.find(o => o.offerId === offerId) ?? null

        this.bot.logger.debug(
            this.bot.isMobile,
            'EARN-SNAPSHOT',
            `已重新获取 /earn 和 /dashboard | offers=${refreshed.offers.length} | ${offerId} 找到=${!!live}`
        )

        return live
    }
}
