import XCTest
@testable import MeterBar

/// Locks the JSON contract of the shared metrics cache.
///
/// `UsageDataManager`/`SharedDataStore` encode `[String: UsageMetrics]` with a
/// plain `JSONEncoder()` into the app-group file `cached_usage_metrics.json`.
/// That JSON is decoded by THREE codebases with duplicated struct definitions:
/// the app, the widget (`MeterBarWidget/UsageWidget.swift`), and the CLI
/// (`MeterBarCLI/Sources/MeterBarCLI.swift`). The widget and CLI cannot be
/// imported here, so replica structs below mirror their shapes exactly — if a
/// field or the date strategy changes on the app side, these tests fail before
/// the widget/CLI silently break. See .agents/docs/DEFERRED_WORK.md §1 for the
/// planned shared-package fix.
final class CachedMetricsContractTests: XCTestCase {

    /// Mirrors the widget's `UsageMetrics` (no `extraUsage`, no
    /// `resetCreditsAvailable`, no `windowSeconds` on limits).
    private struct WidgetReplicaMetrics: Codable {
        let id: UUID
        let service: String
        let sessionLimit: ReplicaLimit?
        let weeklyLimit: ReplicaLimit?
        let codeReviewLimit: ReplicaLimit?
        let lastUpdated: Date
    }

    /// Mirrors the CLI's `ServiceMetrics` (subset of keys only).
    private struct CLIReplicaMetrics: Codable {
        let sessionLimit: ReplicaLimit?
        let weeklyLimit: ReplicaLimit?
        let codeReviewLimit: ReplicaLimit?
    }

    private struct ReplicaLimit: Codable {
        let used: Double
        let total: Double
        let resetTime: Date?
    }

    private func makeSampleCache() -> [String: UsageMetrics] {
        let limit = UsageLimit(
            used: 42,
            total: 100,
            resetTime: Date(timeIntervalSinceReferenceDate: 800_000_000),
            windowSeconds: 5 * 60 * 60
        )
        let metrics = UsageMetrics(
            service: .claudeCode,
            sessionLimit: limit,
            weeklyLimit: limit,
            codeReviewLimit: nil,
            extraUsage: ExtraUsageStatus(state: .on, detail: "$5.00 used"),
            resetCreditsAvailable: 2
        )
        return [ServiceType.claudeCode.rawValue: metrics]
    }

    /// Encode exactly the way SharedDataStore does (default JSONEncoder).
    private func encodeLikeSharedDataStore(_ cache: [String: UsageMetrics]) throws -> Data {
        try JSONEncoder().encode(cache)
    }

    func testCacheKeysAreServiceRawValues() throws {
        let data = try encodeLikeSharedDataStore(makeSampleCache())
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // The widget/CLI look services up by ServiceType rawValue strings.
        XCTAssertNotNil(object["Claude Code"])
    }

    func testDatesUseDefaultReferenceDateStrategy() throws {
        // All three decoders rely on the DEFAULT date strategy (seconds since
        // 2001-01-01). Switching either side to ISO8601/secondsSince1970 breaks
        // widget and CLI decode — this pins the wire format.
        let data = try encodeLikeSharedDataStore(makeSampleCache())
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let entry = try XCTUnwrap(object["Claude Code"] as? [String: Any])
        let session = try XCTUnwrap(entry["sessionLimit"] as? [String: Any])
        let resetTime = try XCTUnwrap(session["resetTime"] as? Double)
        XCTAssertEqual(resetTime, 800_000_000, accuracy: 0.001)
    }

    func testWidgetShapedDecoderReadsAppEncodedCache() throws {
        let data = try encodeLikeSharedDataStore(makeSampleCache())
        let decoded = try JSONDecoder().decode(
            [String: WidgetReplicaMetrics].self,
            from: data
        )
        let entry = try XCTUnwrap(decoded["Claude Code"])
        XCTAssertEqual(entry.service, "Claude Code")
        XCTAssertEqual(entry.sessionLimit?.used, 42)
        XCTAssertEqual(entry.sessionLimit?.total, 100)
        XCTAssertEqual(
            entry.sessionLimit?.resetTime?.timeIntervalSinceReferenceDate ?? 0,
            800_000_000,
            accuracy: 0.001
        )
        // extraUsage/resetCreditsAvailable are silently dropped by the widget —
        // documented drift, tolerated because JSONDecoder ignores unknown keys.
    }

    func testCLIShapedDecoderReadsAppEncodedCache() throws {
        let data = try encodeLikeSharedDataStore(makeSampleCache())
        let decoded = try JSONDecoder().decode(
            [String: CLIReplicaMetrics].self,
            from: data
        )
        let entry = try XCTUnwrap(decoded["Claude Code"])
        // The CLI regressed once by declaring used/total as Int (fixed in
        // 2026-06-26 session). Doubles must decode.
        XCTAssertEqual(entry.weeklyLimit?.used, 42)
        XCTAssertEqual(entry.weeklyLimit?.total, 100)
    }

    func testAppRoundTripPreservesExtendedFields() throws {
        let data = try encodeLikeSharedDataStore(makeSampleCache())
        let decoded = try JSONDecoder().decode([String: UsageMetrics].self, from: data)
        let entry = try XCTUnwrap(decoded["Claude Code"])
        XCTAssertEqual(entry.extraUsage?.state, .on)
        XCTAssertEqual(entry.resetCreditsAvailable, 2)
        XCTAssertEqual(entry.sessionLimit?.windowSeconds, 5 * 60 * 60)
    }
}
