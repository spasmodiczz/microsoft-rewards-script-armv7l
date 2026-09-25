import type { HttpMethod, RequestInit as ImpitRequestInit } from 'impit'
import type { AccountProxy } from '../interface/Account'
import { parseBrowserProxyUrl } from './Proxy'

const DEFAULT_TIMEOUT = 20000
const MAX_RETRIES = 3
const RETRY_BASE_DELAY = 1000

/**
 * 跨后端的最小响应契约。impit 的 ImpitResponse 与 WHATWG fetch 的 Response
 * 都满足它，因此上层逻辑（重试 / 解析 / 状态码判定）与具体后端解耦。
 */
export interface HttpHeadersLike {
    forEach(callback: (value: string, key: string) => void): void
    getSetCookie?: () => string[]
}

export interface HttpResponseLike {
    status: number
    statusText: string
    headers: HttpHeadersLike
    text(): Promise<string>
}

export interface HttpFetcher {
    readonly backend: 'impit' | 'fetch'
    fetch(url: string, init: ImpitRequestInit): Promise<HttpResponseLike>
}

/**
 * 浏览器桥接：把请求交给真实 Chromium 的网络栈执行。
 *
 * armv7l 等平台没有 impit 预编译包，HTTP 层会回落到 undici，TLS/HTTP2 指纹
 * 与浏览器不一致，微软会把 rewards.bing.com 的请求判定为未登录（返回登录页）
 * 或把 flyout 降级为匿名响应。此时让同源请求走浏览器即可拿到真实数据。
 * 返回 null 表示"本次不走浏览器"，调用方应回落到普通 fetch。
 */
export interface BrowserBridgeResult {
    status: number
    statusText: string
    text: string
}

export type BrowserBridgeFetch = (
    url: string,
    init: { method?: string; headers?: Record<string, string>; body?: unknown }
) => Promise<BrowserBridgeResult | null>

function makeBridgedResponse(result: BrowserBridgeResult): HttpResponseLike {
    const headers = new Map<string, string>()

    return {
        status: result.status,
        statusText: result.statusText || 'OK',
        headers: {
            forEach(callback: (value: string, key: string) => void): void {
                headers.forEach((value, key) => callback(value, key))
            }
        },
        text: async () => result.text
    }
}

/** 给任意后端套一层浏览器桥接：桥接返回 null 时自动回落到原后端 */
function wrapWithBrowserBridge(inner: HttpFetcher, bridge: BrowserBridgeFetch): HttpFetcher {
    return {
        backend: inner.backend,
        fetch: async (url, init) => {
            try {
                const result = await bridge(url, {
                    method: init.method,
                    headers: init.headers as Record<string, string> | undefined,
                    body: init.body
                })

                if (result && typeof result.text === 'string') {
                    return makeBridgedResponse(result)
                }
            } catch {
                /* 桥接失败不影响主流程，回落到原后端 */
            }

            return inner.fetch(url, init)
        }
    }
}

let fallbackWarned = false

function createImpitFetcher(proxyUrl: string | undefined, timeout: number): HttpFetcher | null {
    try {
        // impit 只发布了 x86_64 / aarch64 的原生二进制，armv7l 上 require 会抛错。
        // 因此这里必须容错，失败时回落到 Node 内置的 fetch(undici)。
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        const impitModule = require('impit') as {
            Impit?: new (options: {
                browser?: string
                proxyUrl?: string
                timeout?: number
            }) => { fetch(url: string, init: ImpitRequestInit): Promise<HttpResponseLike> }
        }

        const ImpitCtor = impitModule.Impit
        if (!ImpitCtor) return null

        const instance = new ImpitCtor({ browser: 'chrome', proxyUrl, timeout })
        return {
            backend: 'impit',
            fetch: (url, init) => instance.fetch(url, init)
        }
    } catch {
        return null
    }
}

function createFetchFetcher(proxyUrl: string | undefined, timeout: number): HttpFetcher {
    // 慢速设备(armhf 小盒子)上 DNS+TCP+TLS 握手很容易超过 undici 默认的 10s connect 超时,
    // 会抛 UND_ERR_CONNECT_TIMEOUT(表现为 "fetch failed")。AbortSignal.timeout 只管整体,
    // 改不了 undici 内部的 connect 超时 —— 必须显式建 Agent/ProxyAgent 放宽。
    const connectTimeout = Math.max(15000, Math.min(timeout * 2, 60000))
    const headersTimeout = Math.max(30000, timeout)
    const bodyTimeout = Math.max(30000, timeout)
    const connect = { timeout: connectTimeout }

    let dispatcher: unknown
    let dispatcherReady: Promise<void> | null = null

    const ensureDispatcher = async (): Promise<unknown> => {
        if (!dispatcherReady) {
            dispatcherReady = (async () => {
                try {
                    const undici = await import('undici')
                    dispatcher = proxyUrl
                        ? new undici.ProxyAgent({
                              uri: proxyUrl,
                              connect,
                              headersTimeout,
                              bodyTimeout
                          })
                        : new undici.Agent({ connect, headersTimeout, bodyTimeout })
                } catch {
                    if (proxyUrl) {
                        throw new Error(
                            'HTTP 层已回落到 fetch 后端，但代理支持需要 undici。请执行: npm i undici'
                        )
                    }
                    // 拿不到 undici 就退回全局 fetch(无自定义超时),不阻断主流程
                    dispatcher = undefined
                }
            })()
        }
        await dispatcherReady
        return dispatcher
    }

    return {
        backend: 'fetch',
        fetch: async (url, init) => {
            const activeDispatcher = await ensureDispatcher()
            const response = await globalThis.fetch(url, {
                method: init.method,
                headers: init.headers as HeadersInit | undefined,
                body: init.body as BodyInit | undefined,
                signal: AbortSignal.timeout(init.timeout ?? timeout),
                ...(activeDispatcher ? { dispatcher: activeDispatcher } : {})
            } as RequestInit)

            return response as unknown as HttpResponseLike
        }
    }
}

/**
 * 优先使用 impit（保留浏览器 TLS/HTTP2 指纹），不可用时回落到 fetch。
 * 可用 MRS_HTTP_BACKEND=impit|fetch 强制指定。
 */
function createFetcher(proxyUrl: string | undefined, timeout: number): HttpFetcher {
    const forced = process.env.MRS_HTTP_BACKEND?.toLowerCase()

    if (forced !== 'fetch') {
        const impitFetcher = createImpitFetcher(proxyUrl, timeout)
        if (impitFetcher) return impitFetcher

        if (forced === 'impit') {
            throw new Error('MRS_HTTP_BACKEND=impit 被强制指定，但 impit 原生模块加载失败')
        }

        if (!fallbackWarned) {
            fallbackWarned = true
            console.warn(
                '[HTTP] impit 原生模块在当前平台不可用（无 armv7l 预编译包），已回落到 fetch 后端。' +
                    'TLS 指纹伪装会降级；如需代理支持请执行 npm i undici。'
            )
        }
    }

    return createFetchFetcher(proxyUrl, timeout)
}

export interface HttpRequestConfig {
    url?: string
    method?: string
    headers?: Record<string, unknown>
    params?: Record<string, string> | URLSearchParams
    data?: unknown
    timeout?: number
    responseType?: 'json' | 'text'
    retries?: number
}

export interface HttpResponse<T = unknown> {
    data: T
    status: number
    statusText: string
    headers: Record<string, string | string[]>
    config: HttpRequestConfig
}

export function mergeRequestHeaders(
    defaultHeaders: Record<string, unknown>,
    requestHeaders: Record<string, unknown> = {}
): Record<string, unknown> {
    const merged = { ...defaultHeaders }

    for (const [key, value] of Object.entries(requestHeaders)) {
        const existingKey = Object.keys(merged).find(name => name.toLowerCase() === key.toLowerCase())
        if (existingKey) delete merged[existingKey]
        merged[key] = value
    }

    return merged
}

function toInit(config: HttpRequestConfig): { url: string; init: ImpitRequestInit } {
    let url = config.url ?? ''
    if (config.params) {
        const qs =
            config.params instanceof URLSearchParams
                ? config.params.toString()
                : new URLSearchParams(config.params).toString()
        if (qs) url += (url.includes('?') ? '&' : '?') + qs
    }

    const headers: Record<string, string> = {}
    if (config.headers) {
        for (const [key, value] of Object.entries(config.headers)) {
            if (value === undefined || value === null) continue
            headers[key] = Array.isArray(value) ? value.join(', ') : String(value)
        }
    }

    let body: ImpitRequestInit['body']
    const data = config.data
    if (data !== undefined && data !== null) {
        if (
            typeof data === 'string' ||
            data instanceof URLSearchParams ||
            data instanceof Uint8Array ||
            data instanceof ArrayBuffer
        ) {
            body = data
        } else {
            body = JSON.stringify(data)
            if (!Object.keys(headers).some(h => h.toLowerCase() === 'content-type')) {
                headers['Content-Type'] = 'application/json'
            }
        }
    }

    const init: ImpitRequestInit = {
        method: (config.method ?? 'GET').toUpperCase() as HttpMethod,
        headers,
        body,
        timeout: config.timeout ?? DEFAULT_TIMEOUT
    }

    return { url, init }
}

async function toResponse<T>(res: HttpResponseLike, config: HttpRequestConfig): Promise<HttpResponse<T>> {
    const text = await res.text()

    // 临时排障开关: MRS_HTTP_DEBUG=1 时打印概要,并把完整响应体落盘到 /tmp/mrs-httpdump/
    if (process.env.MRS_HTTP_DEBUG === '1') {
        console.log(
            `[HTTP-DEBUG] ${config.method ?? 'GET'} ${config.url ?? '?'} -> ${res.status} | ${text
                .slice(0, 400)
                .replace(/\s+/g, ' ')}`
        )
        try {
            const fs = await import('node:fs')
            const dir = '/tmp/mrs-httpdump'
            fs.mkdirSync(dir, { recursive: true })
            const name = (config.url ?? 'unknown').replace(/[^a-zA-Z0-9]/g, '_').slice(-50)
            fs.writeFileSync(`${dir}/${Date.now()}-${name}.txt`, text)
        } catch {
            /* 落盘失败不影响主流程 */
        }
    }

    let data: unknown = text
    if (config.responseType !== 'text') {
        try {
            data = JSON.parse(text)
        } catch {
            data = text
        }
    }

    const headers: Record<string, string | string[]> = {}
    res.headers.forEach((value, key) => {
        headers[key.toLowerCase()] = value
    })

    const withSetCookie = res.headers as HttpHeadersLike & { getSetCookie?: () => string[] }
    const setCookie = typeof withSetCookie.getSetCookie === 'function' ? withSetCookie.getSetCookie() : undefined
    if (setCookie && setCookie.length) headers['set-cookie'] = setCookie

    return {
        data: data as T,
        status: res.status,
        statusText: res.statusText,
        headers,
        config
    }
}

function backoff(retry: number): Promise<void> {
    const ms = RETRY_BASE_DELAY * 2 ** (retry - 1) + Math.floor(Math.random() * 250)
    return new Promise(resolve => setTimeout(resolve, ms))
}

async function send<T>(
    fetcher: HttpFetcher,
    url: string,
    init: ImpitRequestInit,
    config: HttpRequestConfig
): Promise<HttpResponse<T>> {
    const configuredRetries = config.retries ?? MAX_RETRIES
    const maxRetries = Number.isFinite(configuredRetries) ? Math.max(0, Math.floor(configuredRetries)) : MAX_RETRIES

    for (let attempt = 0; attempt <= maxRetries; attempt++) {
        let responseStatus: number | undefined

        try {
            const res = await fetcher.fetch(url, init)
            responseStatus = res.status
            const out = await toResponse<T>(res, config)

            if (out.status >= 200 && out.status < 300) return out

            const error = new Error(`Request failed with status code ${out.status}`) as Error & {
                response?: HttpResponse<T>
                status?: number
            }
            error.response = out
            error.status = out.status
            throw error
        } catch (error) {
            const status = (error as { status?: number })?.status ?? responseStatus
            const permanentClientError =
                typeof status === 'number' &&
                status >= 400 &&
                status < 500 &&
                status !== 408 &&
                status !== 425 &&
                status !== 429

            if (permanentClientError || attempt >= maxRetries) throw error

            await backoff(attempt + 1)
        }
    }

    throw new Error('Request failed after maximum retries')
}

class HttpClient {
    private raw: HttpFetcher
    private instance: HttpFetcher
    private direct: HttpFetcher | null = null
    private account: AccountProxy
    private defaultHeaders: Record<string, unknown>

    constructor(account: AccountProxy, defaultHeaders: Record<string, unknown> = {}) {
        this.account = account
        this.defaultHeaders = { ...defaultHeaders }

        const proxyUrl = this.account.url && this.account.proxyHttp ? this.buildProxyUrl(this.account) : undefined

        this.raw = createFetcher(proxyUrl, DEFAULT_TIMEOUT)
        this.instance = this.raw
    }

    /** 当前 HTTP 后端：impit（浏览器指纹）或 fetch（undici，指纹会降级） */
    public get backend(): 'impit' | 'fetch' {
        return this.raw.backend
    }

    /**
     * 注册浏览器桥接。armv7l 等无 impit 的平台靠它绕过 TLS 指纹识别。
     * 传 null 可解除桥接。
     */
    public setBrowserBridge(bridge: BrowserBridgeFetch | null): void {
        this.instance = bridge ? wrapWithBrowserBridge(this.raw, bridge) : this.raw
        this.direct = null
    }

    public setDefaultHeaders(headers: Record<string, unknown>): void {
        this.defaultHeaders = mergeRequestHeaders(this.defaultHeaders, headers)
    }

    public async request<T = unknown>(config: HttpRequestConfig, useProxy = true): Promise<HttpResponse<T>> {
        const requestConfig: HttpRequestConfig = {
            ...config,
            headers: mergeRequestHeaders(this.defaultHeaders, config.headers)
        }
        const { url, init } = toInit(requestConfig)

        if (!useProxy) {
            if (!this.direct) this.direct = createFetcher(undefined, DEFAULT_TIMEOUT)
            return send<T>(this.direct, url, init, requestConfig)
        }

        return send<T>(this.instance, url, init, requestConfig)
    }

    private buildProxyUrl(proxyConfig: AccountProxy): string {
        const { url: baseUrl, port, username, password } = proxyConfig

        const urlObj = parseBrowserProxyUrl(baseUrl)
        const protocol = urlObj.protocol.toLowerCase()

        if (username && password) {
            urlObj.username = encodeURIComponent(username)
            urlObj.password = encodeURIComponent(password)
            urlObj.port = port.toString()
            return urlObj.toString()
        }

        return `${protocol}//${urlObj.hostname}:${port}`
    }
}

let sharedFetcher: HttpFetcher | undefined

export async function httpRequest<T = unknown>(config: HttpRequestConfig): Promise<HttpResponse<T>> {
    if (!sharedFetcher) sharedFetcher = createFetcher(undefined, DEFAULT_TIMEOUT)
    const { url, init } = toInit(config)
    return send<T>(sharedFetcher, url, init, config)
}

export default HttpClient
