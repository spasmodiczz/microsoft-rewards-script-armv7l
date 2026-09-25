import type {
    ActivityAndQuiz,
    BasePromotion,
    Dashboard,
    DashboardData,
    DashboardImpression,
    Profile
} from '../interface/DashboardData'

export const BOT_SCORE_WARNING = 'Fraud_UserWarning_BotScore_UX'

type FlyoutProfileAttributes = Profile['attributes'] & {
    rbs?: string | number
    rbs_upd?: string
    SerpBotScore_upd?: string
    AdsBotScore_upd?: string
}

interface FlyoutProfile extends Omit<Profile, 'attributes'> {
    attributes: FlyoutProfileAttributes
}

interface FlyoutCounters {
    PCSearch?: DashboardImpression[]
    MobileSearch?: DashboardImpression[]
    ActivityAndQuiz?: ActivityAndQuiz[]
    DailyPoint?: DashboardImpression[]
    pcSearch?: DashboardImpression[]
    mobileSearch?: DashboardImpression[]
    activityAndQuiz?: ActivityAndQuiz[]
    dailyPoint?: DashboardImpression[]
}

interface FlyoutUserStatus {
    availablePoints?: number
    lifetimePoints?: number
    lifetimeGivingPoints?: number
    lifetimePointsRedeemed?: number
    isRewardsUser?: boolean
    counters?: FlyoutCounters
    [key: string]: unknown
}

interface FlyoutResult {
    userStatus?: FlyoutUserStatus
    dailySetPromotions?: Record<string, BasePromotion[]>
    morePromotions?: BasePromotion[]
    highValueActionPromotions?: BasePromotion[]
    edgeHighValueActionPromotions?: BasePromotion[]
    exploreOnBingPromotions?: BasePromotion[]
    exploreOnOutlookPromotions?: BasePromotion[]
    onboardingChecklistPromotions?: BasePromotion[]
    impressionPromotions?: BasePromotion[]
    [key: string]: unknown
}

interface FlyoutUserInfo {
    isRewardsUser?: boolean
    balance?: number
    lifetimeGivingPoints?: number
    errorCode?: number
    errorMessage?: string | null
    profile?: FlyoutProfile
    [key: string]: unknown
}

export interface RewardsFlyoutData {
    isError?: boolean
    errorMessage?: string | null
    userInfo?: FlyoutUserInfo
    flyoutResult?: FlyoutResult
    [key: string]: unknown
}

export interface FlyoutBotDetection {
    likelyLimited: boolean
    hasBotProfileMarkers: boolean
    hasCollapsedActivities: boolean
    pcSearchMax: number | null
    activityAndQuizMax: number | null
    dailyPointMax: number | null
}

export function detectFlyoutBotWarning(data: RewardsFlyoutData): FlyoutBotDetection {
    const attributes = data.userInfo?.profile?.attributes
    const counters = data.flyoutResult?.userStatus?.counters

    const pcSearchMax = sumCounterMaximum(counters?.PCSearch ?? counters?.pcSearch)
    const activityAndQuizMax = sumCounterMaximum(counters?.ActivityAndQuiz ?? counters?.activityAndQuiz)
    const dailyPointMax = sumCounterMaximum(counters?.DailyPoint ?? counters?.dailyPoint)

    const hasBotProfileMarkers =
        String(attributes?.rbs ?? '').trim() === '1' &&
        Boolean(attributes?.SerpBotScore_upd) &&
        Boolean(attributes?.AdsBotScore_upd)

    const hasCollapsedActivities =
        activityAndQuizMax === 0 && pcSearchMax !== null && dailyPointMax !== null && dailyPointMax === pcSearchMax

    return {
        likelyLimited: hasBotProfileMarkers && hasCollapsedActivities,
        hasBotProfileMarkers,
        hasCollapsedActivities,
        pcSearchMax,
        activityAndQuizMax,
        dailyPointMax
    }
}

export function mapFlyoutToDashboard(data: RewardsFlyoutData): DashboardData {
    const userInfo = data.userInfo
    const flyout = data.flyoutResult
    const profile = userInfo?.profile
    const flyoutStatus = flyout?.userStatus

    if (data.isError || !userInfo?.isRewardsUser || !profile || !flyout || !flyoutStatus?.isRewardsUser) {
        throw new Error(buildFlyoutRejectionMessage(data))
    }

    const counters = flyoutStatus.counters ?? {}
    const highValuePromotions = flyout.highValueActionPromotions ?? []
    const additionalPromotions = uniquePromotions([
        ...(flyout.edgeHighValueActionPromotions ?? []),
        ...(flyout.exploreOnBingPromotions ?? []),
        ...(flyout.exploreOnOutlookPromotions ?? []),
        ...(flyout.onboardingChecklistPromotions ?? [])
    ])
    const botDetection = detectFlyoutBotWarning(data)

    const dashboard = {
        ...flyout,
        userStatus: {
            ...flyoutStatus,
            availablePoints: numberOrFallback(flyoutStatus.availablePoints, userInfo.balance),
            lifetimePoints: numberOrFallback(flyoutStatus.lifetimePoints, 0),
            lifetimePointsRedeemed: numberOrFallback(flyoutStatus.lifetimePointsRedeemed, 0),
            lifetimeGivingPoints: numberOrFallback(flyoutStatus.lifetimeGivingPoints, userInfo.lifetimeGivingPoints),
            isRewardsUser: true,
            counters: {
                pcSearch: counters.PCSearch ?? counters.pcSearch ?? [],
                mobileSearch: counters.MobileSearch ?? counters.mobileSearch ?? [],
                activityAndQuiz: counters.ActivityAndQuiz ?? counters.activityAndQuiz ?? [],
                dailyPoint: counters.DailyPoint ?? counters.dailyPoint ?? []
            }
        },
        userWarnings: botDetection.likelyLimited ? [{ name: BOT_SCORE_WARNING }] : [],
        userProfile: profile,
        promotionalItem: highValuePromotions[0] ?? null,
        promotionalItems: uniquePromotions([...highValuePromotions.slice(1), ...additionalPromotions]),
        dailySetPromotions: flyout.dailySetPromotions ?? {},
        morePromotions: flyout.morePromotions ?? [],
        morePromotionsWithoutPromotionalItems: [],
        punchCards: [],
        componentImpressionPromotions: flyout.impressionPromotions ?? []
    } as unknown as Dashboard

    return {
        dashboard,
        profile
    } as DashboardData
}

/**
 * 把「Flyout 响应不是有效的 Rewards 账户数据」拆成可读的具体原因。
 *
 * 原实现只抛一句笼统文案，无法区分下面几种完全不同的故障：
 *   - isError=true          : 接口主动报错
 *   - isRewardsUser=false   : 登录态无效 / 账号没开通 Rewards（最常见：缺 tifacfaatcs 票据）
 *   - profile / flyoutResult 缺失 : 响应结构变了，或被拦到了匿名页
 */
function buildFlyoutRejectionMessage(data: RewardsFlyoutData): string {
    const userInfo = data.userInfo
    const flyout = data.flyoutResult
    const reasons: string[] = []

    if (data.isError) {
        reasons.push(`isError=true(${data.errorMessage ?? '无错误信息'})`)
    }
    if (!userInfo) {
        reasons.push('userInfo 缺失')
    } else if (!userInfo.isRewardsUser) {
        reasons.push(
            `userInfo.isRewardsUser=false(errorCode=${userInfo.errorCode ?? 'n/a'}${userInfo.errorMessage ? ` | ${userInfo.errorMessage}` : ''})`
        )
    }
    if (!userInfo?.profile) {
        reasons.push('userInfo.profile 缺失')
    }
    if (!flyout) {
        reasons.push('flyoutResult 缺失')
    } else if (!flyout.userStatus?.isRewardsUser) {
        reasons.push('flyoutResult.userStatus.isRewardsUser=false')
    }

    const topKeys = Object.keys(data ?? {})
    const keys = topKeys.length ? topKeys.join(',') : '(空对象)'

    return `Flyout 响应不是有效的 Rewards 账户数据 | 原因=${reasons.length ? reasons.join('; ') : '未知'} | 顶层键=${keys}`
}

function sumCounterMaximum(counters?: Array<{ pointProgressMax: number }>): number | null {
    if (!counters?.length) return null
    return counters.reduce((total, counter) => total + Math.max(0, Number(counter.pointProgressMax) || 0), 0)
}

function numberOrFallback(primary: unknown, fallback: unknown): number {
    const primaryNumber = Number(primary)
    if (Number.isFinite(primaryNumber)) return primaryNumber

    const fallbackNumber = Number(fallback)
    return Number.isFinite(fallbackNumber) ? fallbackNumber : 0
}

function uniquePromotions(promotions: BasePromotion[]): BasePromotion[] {
    return [...new Map(promotions.filter(Boolean).map(promotion => [promotion.offerId, promotion])).values()]
}
