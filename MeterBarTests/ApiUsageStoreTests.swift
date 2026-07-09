import XCTest
@testable import MeterBar

@MainActor
final class ApiUsageStoreTests: XCTestCase {
    private actor FetchProbe {
        private var slowContinuation: CheckedContinuation<ApiUsage, Never>?
        private(set) var requestedWindows: [ApiUsageWindow] = []

        func fetch(provider: ApiProvider, window: ApiUsageWindow) async -> ApiUsage {
            requestedWindows.append(window)
            if window == .last30Days {
                return await withCheckedContinuation { continuation in
                    slowContinuation = continuation
                }
            }
            return Self.usage(provider: provider, window: window, inputTokens: 1)
        }

        var hasPendingSlowRequest: Bool {
            slowContinuation != nil
        }

        func completeSlowRequest() {
            slowContinuation?.resume(
                returning: Self.usage(provider: .anthropic, window: .last30Days, inputTokens: 30)
            )
            slowContinuation = nil
        }

        private static func usage(
            provider: ApiProvider,
            window: ApiUsageWindow,
            inputTokens: Int
        ) -> ApiUsage {
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            let range = window.dateRange(now: now)
            return ApiUsage(
                provider: provider,
                windowStart: range.start,
                windowEnd: range.end,
                inputTokens: inputTokens,
                outputTokens: 0,
                estimatedCostUSD: 0,
                models: []
            )
        }
    }

    func testSupersededWindowRefreshCannotPublishLateResult() async {
        let probe = FetchProbe()
        let store = makeStore { provider, window in
            await probe.fetch(provider: provider, window: window)
        }

        store.setWindow(.last30Days)
        for _ in 0..<100 {
            if await probe.hasPendingSlowRequest { break }
            await Task.yield()
        }
        let hasPendingSlowRequest = await probe.hasPendingSlowRequest
        guard hasPendingSlowRequest else {
            XCTFail("scheduled refresh did not reach the controlled fetcher")
            return
        }

        let custom = ApiUsageWindow.custom(
            start: Date(timeIntervalSince1970: 1_900_000_000),
            end: Date(timeIntervalSince1970: 1_900_086_400)
        )
        store.setWindow(custom)
        await store.waitForCurrentRefresh()

        XCTAssertEqual(store.window, custom)
        XCTAssertEqual(store.usage[.anthropic]?.inputTokens, 1)
        XCTAssertFalse(store.isLoading)

        await probe.completeSlowRequest()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(store.window, custom)
        XCTAssertEqual(store.usage[.anthropic]?.inputTokens, 1, "a superseded request must never publish late")
        let requestedWindows = await probe.requestedWindows
        XCTAssertEqual(requestedWindows, [.last30Days, custom])
    }

    func testMatchingRefreshCoalescesWithScheduledWindowRequest() async {
        let probe = FetchProbe()
        let store = makeStore { provider, window in
            await probe.fetch(provider: provider, window: window)
        }

        store.setWindow(.last30Days)
        for _ in 0..<100 {
            if await probe.hasPendingSlowRequest { break }
            await Task.yield()
        }
        let hasPendingSlowRequest = await probe.hasPendingSlowRequest
        guard hasPendingSlowRequest else {
            XCTFail("scheduled refresh did not reach the controlled fetcher")
            return
        }

        let overlappingRefresh = Task { await store.refresh() }
        for _ in 0..<10 { await Task.yield() }
        let requestedBeforeCompletion = await probe.requestedWindows
        XCTAssertEqual(requestedBeforeCompletion, [.last30Days])

        await probe.completeSlowRequest()
        await overlappingRefresh.value

        XCTAssertEqual(store.usage[.anthropic]?.inputTokens, 30)
        XCTAssertFalse(store.isLoading)
    }

    func testFailedWindowRefreshPreservesCachedUsageAndSanitizesError() async {
        actor ResponseSequence {
            private var callCount = 0

            func fetch(provider: ApiProvider, window: ApiUsageWindow) throws -> ApiUsage {
                callCount += 1
                if callCount > 1 {
                    throw ServiceError.apiError("HTTP 500: account@example.test")
                }
                let range = window.dateRange(now: Date(timeIntervalSince1970: 2_000_000_000))
                return ApiUsage(
                    provider: provider,
                    windowStart: range.start,
                    windowEnd: range.end,
                    inputTokens: 7,
                    outputTokens: 0,
                    estimatedCostUSD: 0,
                    models: []
                )
            }
        }

        let responses = ResponseSequence()
        let store = makeStore { provider, window in
            try await responses.fetch(provider: provider, window: window)
        }

        await store.refresh()
        XCTAssertEqual(store.usage[.anthropic]?.inputTokens, 7)

        store.setWindow(.last30Days)
        await store.waitForCurrentRefresh()

        XCTAssertEqual(store.usage[.anthropic]?.inputTokens, 7)
        XCTAssertEqual(store.lastError, "HTTP 500")
        XCTAssertFalse(store.lastError?.contains("account@example.test") ?? true)
        XCTAssertFalse(store.isLoading)
    }

    private func makeStore(
        fetch: @escaping (ApiProvider, ApiUsageWindow) async throws -> ApiUsage
    ) -> ApiUsageStore {
        ApiUsageStore(
            authenticatedProviders: { [.anthropic] },
            adminKey: { _ in "test-admin-key" },
            fetchUsage: { provider, _, window in
                try await fetch(provider, window)
            }
        )
    }
}
