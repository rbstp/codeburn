import Foundation

/// Mirror of ClaudeSubscriptionService for Codex (ChatGPT-mode). Hits
/// /backend-api/wham/usage with the bearer token from CodexCredentialStore,
/// applies an independent 429 backoff, and surfaces terminal vs transient
/// failures to the UI.
enum CodexSubscriptionService {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    private static let usageBlockedUntilKey = "codeburn.codex.usage.blockedUntil"

    enum FetchError: Error, LocalizedError {
        case notBootstrapped
        case bootstrapFailed(CodexCredentialStore.StoreError)
        case rateLimited(retryAt: Date)
        case usageHTTPError(Int, String?)
        case usageDecodeFailed
        case network(Error)
        case credential(CodexCredentialStore.StoreError)

        var errorDescription: String? {
            switch self {
            case .notBootstrapped:
                return "Connect Codex in Settings to start tracking quota."
            case let .bootstrapFailed(err): return err.errorDescription
            case let .rateLimited(retryAt):
                let f = RelativeDateTimeFormatter()
                f.unitsStyle = .short
                return "ChatGPT rate-limited the quota endpoint. Retrying \(f.localizedString(for: retryAt, relativeTo: Date()))."
            case let .usageHTTPError(code, body):
                return "Codex quota fetch failed (HTTP \(code))\(body.map { ": \($0)" } ?? "")"
            case .usageDecodeFailed: return "Codex quota response was malformed."
            case let .network(err): return "Network error: \(err.localizedDescription)"
            case let .credential(err): return err.errorDescription
            }
        }

        var isTerminal: Bool {
            if case let .credential(err) = self { return err.isTerminal }
            if case let .bootstrapFailed(err) = self { return err.isTerminal }
            return false
        }

        var rateLimitRetryAt: Date? {
            if case let .rateLimited(retryAt) = self { return retryAt }
            return nil
        }
    }

    static func bootstrap() async throws -> CodexUsage {
        // Honour the same 429 backoff that refreshIfBootstrapped respects.
        // A user clicking Reconnect during a sustained ChatGPT rate-limit
        // window would otherwise re-hit /wham/usage on every click and keep
        // the backoff window pegged.
        if let until = usageBlockedUntil(), until > Date() {
            throw FetchError.rateLimited(retryAt: until)
        }
        let record: CodexCredentialStore.CredentialRecord
        do {
            record = try CodexCredentialStore.bootstrap()
        } catch let err as CodexCredentialStore.StoreError {
            throw FetchError.bootstrapFailed(err)
        }
        return try await fetchWithToken(record.accessToken, allowOne401Recovery: true)
    }

    static func refreshIfBootstrapped() async throws -> CodexUsage? {
        guard CodexCredentialStore.isBootstrapCompleted else { return nil }
        if let until = usageBlockedUntil(), until > Date() {
            throw FetchError.rateLimited(retryAt: until)
        }
        do {
            let token = try await CodexCredentialStore.freshAccessToken()
            guard let token else { throw FetchError.notBootstrapped }
            return try await fetchWithToken(token, allowOne401Recovery: true)
        } catch let err as CodexCredentialStore.StoreError {
            throw FetchError.credential(err)
        }
    }

    static func disconnect() {
        CodexCredentialStore.resetBootstrap()
        clearUsageBlock()
    }

    private static func fetchWithToken(_ token: String, allowOne401Recovery: Bool) async throws -> CodexUsage {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodeBurn", forHTTPHeaderField: "User-Agent")
        // chatgpt.com routes the rate_limit envelope per ChatGPT account. Without
        // this header the response often comes back as a guest-shape document
        // missing rate_limit entirely, which our decoder then fails on.
        if let accountId = try? CodexCredentialStore.currentRecord()?.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FetchError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.usageHTTPError(-1, nil)
        }

        switch http.statusCode {
        case 200:
            clearUsageBlock()
            // The usage payload normally carries the reset-credit inventory
            // inline, so only pay for the companion request when it doesn't.
            // Strictly best-effort either way: any failure yields nil and the
            // Plan view simply omits the row. Neither path may break the quota
            // display.
            var resetCredits = inlineResetCredits(data: data)
            if resetCredits == nil {
                resetCredits = await fetchResetCredits(token: token)
            }
            do {
                return try decodeUsage(data: data, resetCredits: resetCredits)
            } catch {
                // Do not log the response body — it's user-account data from
                // chatgpt.com and is readable by other local users via
                // `log stream`. The decode error type alone is enough to
                // bisect schema drift if needed.
                NSLog("CodeBurn: codex usage decode failed: %@", String(describing: error))
                throw FetchError.usageDecodeFailed
            }
        case 401:
            if allowOne401Recovery {
                let newToken = try await CodexCredentialStore.refreshAfter401(failedToken: token)
                return try await fetchWithToken(newToken, allowOne401Recovery: false)
            }
            throw FetchError.usageHTTPError(401, String(data: data, encoding: .utf8))
        case 429:
            // Honour the RFC Retry-After header when present — ChatGPT's quota
            // endpoint sometimes sets it to a window shorter than our 5-min
            // floor, and ignoring it forced users to wait longer than the
            // server actually wanted.
            let retryAfter = parseRetryAfterHeader(http.value(forHTTPHeaderField: "Retry-After"))
            let until = recordUsageRateLimit(retryAfterSeconds: retryAfter)
            throw FetchError.rateLimited(retryAt: until)
        default:
            throw FetchError.usageHTTPError(http.statusCode, String(data: data, encoding: .utf8))
        }
    }

    /// chatgpt.com is inconsistent about how it encodes numbers across this one
    /// payload — `credits.balance` arrives as a Double or a String, and
    /// `spend_control.individual_limit` mixes strings ("limit": "10000") with
    /// numbers ("used_percent": 30) side by side. Every numeric field goes
    /// through here so a shape flip on any one of them can't fail the fetch.
    private enum Flexible {
        // `decode` rather than `decodeIfPresent`: a missing key, an explicit
        // null and a wrong-typed value should all mean "not available here",
        // and `try?` collapses the three into one nil without the
        // double-optional footgun `decodeIfPresent` introduces.
        static func double<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Double? {
            if let v = try? c.decode(Double.self, forKey: key) { return v }
            if let v = try? c.decode(Int.self, forKey: key) { return Double(v) }
            if let v = try? c.decode(String.self, forKey: key) {
                return Double(v.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }
        static func int<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int? {
            double(c, key).map(Int.init)
        }
        static func bool<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Bool {
            (try? c.decode(Bool.self, forKey: key)) ?? false
        }
    }

    private struct UsageDTO: Decodable {
        let plan_type: String?
        let rate_limit: RateLimit?
        let additional_rate_limits: [AdditionalLimitDTO]?
        let credits: Credits?
        let spend_control: SpendControl?
        /// Forward-compat: some payload variants hoist the spend control to the
        /// top level instead of nesting it under `spend_control`.
        let individual_limit: IndividualLimit?

        enum CodingKeys: String, CodingKey {
            case plan_type, rate_limit, additional_rate_limits, credits, spend_control
            case individual_limit
            case individualLimit
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            plan_type = try? c.decode(String.self, forKey: .plan_type)
            rate_limit = try? c.decode(RateLimit.self, forKey: .rate_limit)
            additional_rate_limits = try? c.decode([AdditionalLimitDTO].self, forKey: .additional_rate_limits)
            credits = try? c.decode(Credits.self, forKey: .credits)
            spend_control = try? c.decode(SpendControl.self, forKey: .spend_control)
            individual_limit = (try? c.decode(IndividualLimit.self, forKey: .individual_limit))
                ?? (try? c.decode(IndividualLimit.self, forKey: .individualLimit))
        }

        struct RateLimit: Decodable {
            let primary_window: WindowDTO?
            let secondary_window: WindowDTO?
            /// Forward-compat: another observed position for the spend control.
            let individual_limit: IndividualLimit?

            enum CodingKeys: String, CodingKey {
                case primary_window, secondary_window, individual_limit
                case individualLimit
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                primary_window = try? c.decode(WindowDTO.self, forKey: .primary_window)
                secondary_window = try? c.decode(WindowDTO.self, forKey: .secondary_window)
                individual_limit = (try? c.decode(IndividualLimit.self, forKey: .individual_limit))
                    ?? (try? c.decode(IndividualLimit.self, forKey: .individualLimit))
            }
        }
        struct AdditionalLimitDTO: Decodable {
            let limit_name: String?
            let rate_limit: RateLimit?
        }
        struct WindowDTO: Decodable {
            let used_percent: Double?
            let reset_at: Int?
            let limit_window_seconds: Int?
        }
        /// Credit-metered workspaces (ChatGPT Business / Edu / Enterprise on
        /// flexible pricing) report `rate_limit: null` and carry their real
        /// limit here instead — the monthly credit allowance an admin sets.
        struct SpendControl: Decodable {
            let reached: Bool
            let individualLimit: IndividualLimit?

            enum CodingKeys: String, CodingKey {
                case reached
                case individual_limit
                case individualLimit
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                reached = Flexible.bool(c, .reached)
                individualLimit = (try? c.decode(IndividualLimit.self, forKey: .individual_limit))
                    ?? (try? c.decode(IndividualLimit.self, forKey: .individualLimit))
            }
        }
        struct IndividualLimit: Decodable {
            let limit: Double?
            let used: Double?
            let usedPercent: Double?
            let remainingPercent: Double?
            let resetAt: Int?

            enum CodingKeys: String, CodingKey {
                case limit, used
                case used_percent, usedPercent
                case remaining_percent, remainingPercent
                case reset_at, resets_at, resetsAt
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                limit = Flexible.double(c, .limit)
                used = Flexible.double(c, .used)
                usedPercent = Flexible.double(c, .used_percent) ?? Flexible.double(c, .usedPercent)
                remainingPercent = Flexible.double(c, .remaining_percent)
                    ?? Flexible.double(c, .remainingPercent)
                resetAt = Flexible.int(c, .reset_at)
                    ?? Flexible.int(c, .resets_at)
                    ?? Flexible.int(c, .resetsAt)
            }
        }
        // chatgpt.com sometimes serializes balance as a Double ("balance": 0.0)
        // and other times as a String ("balance": "0.00"). Mirror CodexBar's
        // resilient decode so a schema drift on either shape doesn't blow up
        // the whole quota fetch.
        struct Credits: Decodable {
            let balance: Double?
            /// The account settles in credits rather than dollars, which changes
            /// how `balance` must be labelled.
            let hasCredits: Bool
            /// Credit-metered but deliberately uncapped.
            let unlimited: Bool

            enum CodingKeys: String, CodingKey {
                case balance
                case has_credits
                case unlimited
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                balance = Flexible.double(c, .balance)
                hasCredits = Flexible.bool(c, .has_credits)
                unlimited = Flexible.bool(c, .unlimited)
            }
        }
    }

    private static func fetchResetCredits(token: String) async -> CodexUsage.ResetCredits? {
        var request = URLRequest(url: resetCreditsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodeBurn", forHTTPHeaderField: "User-Agent")
        // The Codex desktop clients send this beta gate header on this
        // endpoint; keep parity so chatgpt.com routes us the same response
        // shape. If the endpoint ever rejects us anyway, the row just hides.
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        if let accountId = try? CodexCredentialStore.currentRecord()?.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return parseResetCredits(data: data)
    }

    /// Reset-credit inventory carried inline on the usage payload. Unlike the
    /// dedicated endpoint this form has no per-credit expiry list, so the
    /// popover shows the count without a "next expires" caption. Returns nil
    /// when the block is absent, which is the signal to fall back to
    /// `fetchResetCredits`. Internal so tests can drive it with fixtures.
    static func inlineResetCredits(data: Data) -> CodexUsage.ResetCredits? {
        struct InlineDTO: Decodable {
            struct Block: Decodable { let available_count: Int? }
            let rate_limit_reset_credits: Block?
        }
        guard let count = (try? JSONDecoder().decode(InlineDTO.self, from: data))?
            .rate_limit_reset_credits?.available_count, count >= 0
        else { return nil }
        return CodexUsage.ResetCredits(availableCount: count, nextExpiresAt: nil)
    }

    /// Internal (not private) so tests can drive it with fixture payloads.
    /// Returns nil on any unexpected shape — the caller treats nil as
    /// "feature unavailable", never as an error.
    static func parseResetCredits(data: Data, now: Date = Date()) -> CodexUsage.ResetCredits? {
        struct CreditDTO: Decodable {
            let status: String?
            let expires_at: String?
        }
        struct ResponseDTO: Decodable {
            let credits: [CreditDTO]?
            let available_count: Int?
        }
        guard let root = try? JSONDecoder().decode(ResponseDTO.self, from: data),
              let count = root.available_count, count >= 0 else {
            return nil
        }
        let nextExpiry = (root.credits ?? [])
            .filter { ($0.status ?? "").lowercased() == "available" }
            .compactMap { $0.expires_at.flatMap(parseISO8601) }
            .filter { $0 > now }
            .min()
        return CodexUsage.ResetCredits(availableCount: count, nextExpiresAt: nextExpiry)
    }

    /// chatgpt.com serializes these timestamps as ISO-8601, sometimes with
    /// fractional seconds and sometimes without; accept both.
    private static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// Internal (not private) so tests can drive it with fixture payloads.
    static func decodeUsage(data: Data, resetCredits: CodexUsage.ResetCredits? = nil) throws -> CodexUsage {
        let root = try JSONDecoder().decode(UsageDTO.self, from: data)
        let additional: [CodexUsage.AdditionalLimit] = (root.additional_rate_limits ?? []).compactMap { dto in
            guard let name = dto.limit_name, !name.isEmpty else { return nil }
            return CodexUsage.AdditionalLimit(
                name: name,
                primary: makeWindow(dto.rate_limit?.primary_window),
                secondary: makeWindow(dto.rate_limit?.secondary_window)
            )
        }
        // `spend_control` is the position the live API uses; the other two are
        // forward-compat fallbacks for variants seen in other clients.
        let limitDTO = root.spend_control?.individualLimit
            ?? root.individual_limit
            ?? root.rate_limit?.individual_limit
        return CodexUsage(
            plan: CodexUsage.planType(from: root.plan_type),
            primary: makeWindow(root.rate_limit?.primary_window),
            secondary: makeWindow(root.rate_limit?.secondary_window),
            additionalLimits: additional,
            creditsBalance: root.credits?.balance,
            hasCredits: root.credits?.hasCredits ?? false,
            creditsUnlimited: root.credits?.unlimited ?? false,
            creditLimit: makeCreditLimit(limitDTO, reached: root.spend_control?.reached ?? false),
            resetCredits: resetCredits,
            fetchedAt: Date()
        )
    }

    private static func makeCreditLimit(
        _ dto: UsageDTO.IndividualLimit?,
        reached: Bool
    ) -> CodexUsage.CreditLimit? {
        guard let dto, let limit = dto.limit, limit > 0 else { return nil }
        // Prefer the server's own percentage, then remaining_percent, then the
        // raw ratio — a partial payload should still render a bar.
        let raw = dto.usedPercent
            ?? dto.remainingPercent.map { 100 - $0 }
            ?? dto.used.map { $0 / limit * 100 }
            ?? 0
        let percent = min(max(raw, 0), 100)
        let resetsAt = dto.resetAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        return CodexUsage.CreditLimit(
            used: dto.used ?? limit * percent / 100,
            limit: limit,
            usedPercent: percent,
            resetsAt: resetsAt,
            windowSeconds: monthlyWindowSeconds(endingAt: resetsAt),
            reached: reached
        )
    }

    /// Spend controls reset on a calendar-month boundary, so the window length
    /// is the month preceding the reset — not a fixed 30 days, and not the
    /// payload's `reset_after_seconds` (which is time *remaining*). QuotaPace
    /// needs the whole-window duration to extrapolate honestly.
    private static func monthlyWindowSeconds(endingAt resetsAt: Date?) -> Int? {
        guard let resetsAt,
              let start = Calendar.current.date(byAdding: .month, value: -1, to: resetsAt)
        else { return nil }
        let seconds = Int(resetsAt.timeIntervalSince(start))
        return seconds > 0 ? seconds : nil
    }

    private static func makeWindow(_ dto: UsageDTO.WindowDTO?) -> CodexUsage.Window? {
        guard let dto, let used = dto.used_percent, let windowSeconds = dto.limit_window_seconds else {
            return nil
        }
        let resetsAt = dto.reset_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return CodexUsage.Window(usedPercent: used, resetsAt: resetsAt, limitWindowSeconds: windowSeconds)
    }

    // MARK: - 429 backoff

    private static func usageBlockedUntil() -> Date? {
        UserDefaults.standard.object(forKey: usageBlockedUntilKey) as? Date
    }

    private static func clearUsageBlock() {
        UserDefaults.standard.removeObject(forKey: usageBlockedUntilKey)
    }

    @discardableResult
    /// RFC 7231 says Retry-After is either a delta-seconds or an HTTP-date.
    /// chatgpt.com appears to send delta-seconds today; we still parse both
    /// shapes defensively so a future change to HTTP-date doesn't drop us
    /// onto the silent 5-minute floor.
    private static func parseRetryAfterHeader(_ value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value), seconds >= 0 { return seconds }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = f.date(from: value) {
            return max(0, Int(date.timeIntervalSinceNow))
        }
        return nil
    }

    private static func recordUsageRateLimit(retryAfterSeconds: Int?) -> Date {
        let seconds = max(retryAfterSeconds ?? 300, 60)
        let until = Date().addingTimeInterval(TimeInterval(seconds))
        UserDefaults.standard.set(until, forKey: usageBlockedUntilKey)
        return until
    }
}
