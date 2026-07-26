import Foundation

/// Codex (ChatGPT-mode) live quota snapshot returned by /backend-api/wham/usage.
/// Two windows are exposed: primary (typically the 5-hour rolling window) and
/// secondary (typically the weekly window). Window size is dynamic per
/// account — `limitWindowSeconds` tells us whether it's a 5-hour or 7-day
/// boundary so we can label correctly.
struct CodexUsage: Sendable, Equatable {
    enum PlanType: Sendable, Equatable {
        case guest, free, go, plus, pro, prolite, freeWorkspace, team
        case business, education, quorum, k12, enterprise, edu
        /// Captures any plan_type string OpenAI ships that we haven't enumerated
        /// yet, so the Settings/Plan UI can still show "Plan: <raw>" instead of
        /// a generic "Subscription" placeholder. Preserves forward compatibility
        /// without requiring a CodeBurn update for every new tier.
        case unknown(String)

        var displayName: String {
            switch self {
            case .guest: "Guest"
            case .free: "Free"
            case .go: "Go"
            case .plus: "Plus"
            case .pro: "Pro"
            case .prolite: "Pro Lite"
            case .freeWorkspace: "Free Workspace"
            case .team: "Team"
            case .business: "Business"
            case .education: "Education"
            case .quorum: "Quorum"
            case .k12: "K-12"
            case .enterprise: "Enterprise"
            case .edu: "Edu"
            case let .unknown(raw): raw.isEmpty ? "Subscription" : raw.capitalized
            }
        }
    }

    struct Window: Sendable, Equatable {
        let usedPercent: Double          // 0.0 ... 100.0
        let resetsAt: Date?
        let limitWindowSeconds: Int

        /// Human label inferred from window size: 5h, 1d, 7d, etc.
        var windowLabel: String {
            switch limitWindowSeconds {
            case 0..<3600:                return "Hourly"
            case 3600..<7200:             return "Hour"
            case 18000..<19000:           return "5-hour"
            case 86400..<87000:           return "Daily"
            case 604800..<605000:         return "Weekly"
            default:
                let hours = limitWindowSeconds / 3600
                if hours < 24 { return "\(hours)-hour" }
                return "\(hours / 24)-day"
            }
        }
    }

    /// Additional per-model / per-feature quotas exposed by ChatGPT alongside
    /// the main rate_limit (e.g. "GPT-5.3-Codex-Spark"). Each entry has its
    /// own primary/secondary windows. Only ones with non-zero utilization are
    /// surfaced in the popover so users on plans that don't touch these
    /// features don't see clutter.
    struct AdditionalLimit: Sendable, Equatable {
        let name: String
        let primary: Window?
        let secondary: Window?
    }

    /// Account-level limit-reset credits: grants that restore a rate-limit
    /// window early, each with its own expiry. Only what the popover renders —
    /// the available count and the soonest expiry among available credits.
    struct ResetCredits: Sendable, Equatable {
        let availableCount: Int
        let nextExpiresAt: Date?
    }

    /// The monthly credit allowance an admin sets on a credit-metered workspace
    /// (ChatGPT Business / Edu / Enterprise on flexible pricing). These accounts
    /// report `rate_limit: null` — the spend control *is* their only limit, so
    /// without this the popover has nothing to draw. Mirrors what ChatGPT's own
    /// Settings → Usage panel shows: "3,029 of 10,000 credits used".
    struct CreditLimit: Sendable, Equatable {
        let used: Double
        let limit: Double
        let usedPercent: Double        // 0.0 ... 100.0
        let resetsAt: Date?
        /// Whole-window length for pace projection: the calendar month the
        /// allowance resets on. Deliberately *not* the payload's
        /// `reset_after_seconds`, which is the time remaining.
        let windowSeconds: Int?
        /// The workspace has already spent the allowance — a hard stop, not a
        /// near-limit warning.
        let reached: Bool
    }

    let plan: PlanType
    let primary: Window?
    let secondary: Window?
    let additionalLimits: [AdditionalLimit]
    let creditsBalance: Double?
    /// True when the account settles in *credits* rather than dollars, which
    /// changes how `creditsBalance` must be formatted.
    let hasCredits: Bool
    /// Credit-metered but deliberately uncapped. Distinguishes "no limit shown
    /// because there is none" from "no limit shown because we failed to read it".
    let creditsUnlimited: Bool
    let creditLimit: CreditLimit?
    let resetCredits: ResetCredits?
    let fetchedAt: Date

    static func planType(from raw: String?) -> PlanType {
        guard let original = raw?.lowercased() else { return .unknown("") }
        let raw = normalizePlanType(original)
        switch raw {
        case "guest": return .guest
        case "free": return .free
        case "go": return .go
        case "plus": return .plus
        case "pro": return .pro
        case "prolite", "pro_lite", "pro-lite": return .prolite
        case "free_workspace": return .freeWorkspace
        case "team": return .team
        case "business": return .business
        case "education": return .education
        case "quorum": return .quorum
        case "k12": return .k12
        case "enterprise": return .enterprise
        case "edu": return .edu
        // Preserve the *original* string so an unrecognized tier still shows
        // exactly what OpenAI sent rather than our stripped-down guess.
        default: return .unknown(original)
        }
    }

    /// Credit-based-pricing workspaces report composite tiers such as
    /// `enterprise_cbp_usage_based` or `self_serve_business_usage_based`. Strip
    /// the billing-mode decorations so they land on the tier they actually are;
    /// anything we don't recognize passes through untouched.
    private static func normalizePlanType(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["_usage_based", "-usage-based"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        if value.hasPrefix("self_serve_") { value.removeFirst("self_serve_".count) }
        if value.hasSuffix("_cbp") { value.removeLast("_cbp".count) }
        value = value.replacingOccurrences(of: "_cbp_", with: "_")
        return value
    }
}
