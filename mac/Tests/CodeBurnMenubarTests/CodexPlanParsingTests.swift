import Foundation
import XCTest
@testable import CodeBurnMenubar

/// Covers `plan_type` parsing and the credit-metered branch of the wham/usage
/// decoder — ChatGPT Business / Edu / Enterprise workspaces on flexible pricing
/// report no rate-limit windows at all, so `spend_control.individual_limit` is
/// the only limit they have.
final class CodexPlanParsingTests: XCTestCase {
    private func decode(_ json: String) throws -> CodexUsage {
        try CodexSubscriptionService.decodeUsage(data: Data(json.utf8))
    }

    // MARK: - Plan types

    func testKnownTiersMapToDisplayNames() {
        let expected: [String: String] = [
            "guest": "Guest", "free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro",
            "prolite": "Pro Lite", "pro_lite": "Pro Lite", "pro-lite": "Pro Lite",
            "free_workspace": "Free Workspace", "team": "Team", "business": "Business",
            "education": "Education", "quorum": "Quorum", "k12": "K-12",
            "enterprise": "Enterprise", "edu": "Edu",
        ]
        for (raw, display) in expected {
            XCTAssertEqual(CodexUsage.planType(from: raw).displayName, display, "plan_type: \(raw)")
        }
    }

    func testTierMatchingIsCaseInsensitive() {
        XCTAssertEqual(CodexUsage.planType(from: "pLuS"), .plus)
        XCTAssertEqual(CodexUsage.planType(from: "ENTERPRISE"), .enterprise)
    }

    /// Credit-based-pricing workspaces ship composite tiers; they should land on
    /// the tier they actually are rather than falling through to the raw string.
    func testCreditBasedPricingCompositesNormalize() {
        XCTAssertEqual(CodexUsage.planType(from: "enterprise_cbp_usage_based"), .enterprise)
        XCTAssertEqual(CodexUsage.planType(from: "self_serve_business_usage_based"), .business)
        XCTAssertEqual(CodexUsage.planType(from: "business_cbp"), .business)
    }

    func testUnknownTierPreservesTheRawStringItWasSent() {
        // The stripped form must not leak out — an unrecognized tier should show
        // exactly what OpenAI sent.
        XCTAssertEqual(CodexUsage.planType(from: "some_future_tier_usage_based"),
                       .unknown("some_future_tier_usage_based"))
        XCTAssertEqual(CodexUsage.planType(from: nil), .unknown(""))
        XCTAssertEqual(CodexUsage.planType(from: nil).displayName, "Subscription")
    }

    // MARK: - Credit-metered workspaces

    /// Captured from a live ChatGPT Enterprise workspace (identifiers replaced).
    private let enterprisePayload = #"""
    {
      "plan_type": "business",
      "rate_limit": null,
      "code_review_rate_limit": null,
      "additional_rate_limits": null,
      "credits": {
        "has_credits": false, "unlimited": false, "overage_limit_reached": false,
        "balance": null, "approx_local_messages": null, "approx_cloud_messages": null
      },
      "spend_control": {
        "reached": false,
        "individual_limit": {
          "source": "workspace_spend_controls",
          "limit": "10000",
          "used": "3028.9909675121307",
          "remaining": "6971.009032487869",
          "used_percent": 30,
          "remaining_percent": 70,
          "reset_after_seconds": 441896,
          "reset_at": 1785542400
        }
      },
      "rate_limit_reset_credits": {"available_count": 0, "applicable_available_count": 0}
    }
    """#

    func testEnterprisePayloadDecodesTheSpendControlLimit() throws {
        let usage = try decode(enterprisePayload)
        // `rate_limit: null` must stay non-fatal — it is the normal shape here.
        XCTAssertNil(usage.primary)
        XCTAssertNil(usage.secondary)
        XCTAssertTrue(usage.additionalLimits.isEmpty)

        let credits = try XCTUnwrap(usage.creditLimit)
        XCTAssertEqual(credits.limit, 10_000)
        XCTAssertEqual(credits.used, 3028.9909675121307, accuracy: 0.0001)
        XCTAssertEqual(credits.usedPercent, 30)
        XCTAssertEqual(credits.resetsAt, Date(timeIntervalSince1970: 1_785_542_400))
        XCTAssertFalse(credits.reached)
        // Calendar month preceding the reset — July 2026, so 31 days — for pace
        // extrapolation. Not the payload's `reset_after_seconds`, which is the
        // time *remaining*. Tolerance absorbs a DST-shifted hour in whatever
        // timezone the test runner is in.
        XCTAssertEqual(Double(try XCTUnwrap(credits.windowSeconds)), Double(31 * 86_400), accuracy: 3600)

        // OpenAI reports Enterprise workspaces as "business" on this endpoint;
        // we show what it sends rather than inventing a tier.
        XCTAssertEqual(usage.plan, .business)
        XCTAssertNil(usage.creditsBalance)
        XCTAssertFalse(usage.hasCredits)
        XCTAssertFalse(usage.creditsUnlimited)
    }

    func testSpendControlIsReadAtEveryObservedPosition() throws {
        let bodies = [
            #"{"spend_control": {"individual_limit": {"limit": 10000, "used_percent": 25}}}"#,
            #"{"spend_control": {"individualLimit": {"limit": 10000, "usedPercent": 25}}}"#,
            #"{"individual_limit": {"limit": 10000, "used_percent": 25}}"#,
            #"{"rate_limit": {"individual_limit": {"limit": 10000, "used_percent": 25}}}"#,
        ]
        for body in bodies {
            let credits = try XCTUnwrap(decode(body).creditLimit, body)
            XCTAssertEqual(credits.usedPercent, 25, body)
            // `used` is back-derived from the percent when the payload omits it.
            XCTAssertEqual(credits.used, 2500, body)
        }
    }

    func testPercentFallsBackThroughRemainingPercentThenRawRatio() throws {
        let fromRemaining = try XCTUnwrap(
            decode(#"{"spend_control": {"individual_limit": {"limit": 10000, "remaining_percent": 70}}}"#).creditLimit)
        XCTAssertEqual(fromRemaining.usedPercent, 30, accuracy: 0.0001)

        let fromRatio = try XCTUnwrap(
            decode(#"{"spend_control": {"individual_limit": {"limit": 400, "used": 100}}}"#).creditLimit)
        XCTAssertEqual(fromRatio.usedPercent, 25, accuracy: 0.0001)
    }

    func testUnusableSpendControlYieldsNoRow() throws {
        let bodies = [
            #"{"spend_control": {"individual_limit": {"limit": 0, "used": 5}}}"#,
            #"{"spend_control": {"individual_limit": {"limit": null}}}"#,
            #"{"spend_control": {"individual_limit": {"used_percent": 40}}}"#,
            #"{"spend_control": {"individual_limit": null}}"#,
            #"{"spend_control": null}"#,
            "{}",
        ]
        for body in bodies {
            XCTAssertNil(try decode(body).creditLimit, body)
        }
    }

    func testReachedSpendControlIsCarriedThrough() throws {
        let credits = try XCTUnwrap(decode(#"""
        {"spend_control": {"reached": true, "individual_limit": {"limit": 10000, "used_percent": 100}}}
        """#).creditLimit)
        XCTAssertTrue(credits.reached)
        XCTAssertEqual(credits.usedPercent, 100)
    }

    func testCreditFlagsAndMixedNumberEncodings() throws {
        let usage = try decode(#"""
        {"credits": {"has_credits": true, "unlimited": true, "balance": "3410.40"}}
        """#)
        XCTAssertTrue(usage.hasCredits)
        XCTAssertTrue(usage.creditsUnlimited)
        XCTAssertEqual(try XCTUnwrap(usage.creditsBalance), 3410.40, accuracy: 0.0001)
    }

    func testRateWindowsStillDecodeAlongsideASpendControl() throws {
        let usage = try decode(#"""
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {"used_percent": 20, "reset_at": 1800000000, "limit_window_seconds": 18000}
          },
          "spend_control": {"individual_limit": {"limit": 10000, "used_percent": 30}}
        }
        """#)
        XCTAssertEqual(usage.primary?.usedPercent, 20)
        XCTAssertEqual(usage.primary?.windowLabel, "5-hour")
        XCTAssertEqual(usage.creditLimit?.usedPercent, 30)
    }

    // MARK: - Inline reset credits

    func testInlineResetCreditsAvoidTheCompanionRequest() {
        let inline = CodexSubscriptionService.inlineResetCredits(data: Data(enterprisePayload.utf8))
        XCTAssertEqual(inline?.availableCount, 0)
        // The inline form carries no per-credit expiry list.
        XCTAssertNil(inline?.nextExpiresAt)
    }

    func testInlineResetCreditsAbsentSignalsFallback() {
        XCTAssertNil(CodexSubscriptionService.inlineResetCredits(data: Data("{}".utf8)))
        XCTAssertNil(CodexSubscriptionService.inlineResetCredits(data: Data("not json".utf8)))
        XCTAssertNil(CodexSubscriptionService.inlineResetCredits(
            data: Data(#"{"rate_limit_reset_credits": {}}"#.utf8)))
    }
}
