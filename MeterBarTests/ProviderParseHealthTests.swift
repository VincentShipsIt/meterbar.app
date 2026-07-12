import MeterBarShared
@testable import MeterBar
import XCTest

final class ProviderParseHealthTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "ProviderParseHealthTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testParseMismatchNeedsAttentionAfterOneFailureAndPersists() {
        let now = Date(timeIntervalSince1970: 10_000)
        let store = ProviderParseHealthStore(userDefaults: defaults)

        store.recordFailure(.claudeCode, error: ServiceError.parsingError, at: now)

        let record = store.records[.claudeCode]
        XCTAssertEqual(record?.consecutiveFailures, 1)
        XCTAssertTrue(record?.lastFailureWasShapeMismatch ?? false)
        XCTAssertTrue(record?.needsAttention(now: now) ?? false)
        XCTAssertEqual(ProviderParseHealthStore.persistedRecords(from: defaults)[.claudeCode], record)
    }

    func testOrdinaryFailureNeedsThreeAttemptsAndSuccessResetsCounter() {
        let now = Date(timeIntervalSince1970: 20_000)
        let store = ProviderParseHealthStore(userDefaults: defaults)
        for offset in 0..<2 {
            store.recordFailure(.cursor, error: ServiceError.apiError("Request timed out"), at: now + Double(offset))
        }
        XCTAssertFalse(store.records[.cursor]?.needsAttention(now: now + 2) ?? true)

        store.recordFailure(.cursor, error: ServiceError.apiError("Request timed out"), at: now + 2)
        XCTAssertTrue(store.records[.cursor]?.needsAttention(now: now + 2) ?? false)

        store.recordSuccess(.cursor, at: now + 3)
        XCTAssertEqual(store.records[.cursor]?.consecutiveFailures, 0)
        XCTAssertFalse(store.records[.cursor]?.needsAttention(now: now + 3) ?? true)
    }

    func testSuccessfulDataBecomesStaleAfterPublishedThreshold() {
        let now = Date(timeIntervalSince1970: 30_000)
        let record = ProviderParseHealthRecord.success(at: now)

        XCTAssertFalse(record.needsAttention(now: now + ProviderParseHealthRecord.staleAfter - 1))
        XCTAssertTrue(record.needsAttention(now: now + ProviderParseHealthRecord.staleAfter + 1))
        XCTAssertEqual(ProviderParseHealthRecord.staleAfter, 2 * 60 * 60)
    }
}
