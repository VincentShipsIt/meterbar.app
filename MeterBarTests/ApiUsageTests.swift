import XCTest
@testable import MeterBar

final class ApiUsageTests: XCTestCase {
    // MARK: - Pricing

    func testAnthropicPricingMatchesModel() {
        // 1M input + 1M output of Sonnet = $3 + $15.
        let cost = ApiUsagePricing.cost(
            provider: .anthropic,
            model: "claude-sonnet-4-5",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000
        )
        XCTAssertEqual(cost, 18.0, accuracy: 0.0001)
    }

    func testAnthropicOpus4UsesReducedRate() {
        // opus-4-8 = $5 in / $25 out, not the legacy opus $15/$75.
        let cost = ApiUsagePricing.cost(
            provider: .anthropic,
            model: "claude-opus-4-8",
            inputTokens: 1_000_000,
            outputTokens: 0
        )
        XCTAssertEqual(cost, 5.0, accuracy: 0.0001)
    }

    func testOpenAIPricingMatchesModel() {
        // gpt-4o = $2.50 in / $10 out.
        let cost = ApiUsagePricing.cost(
            provider: .openai,
            model: "gpt-4o",
            inputTokens: 2_000_000,
            outputTokens: 500_000
        )
        XCTAssertEqual(cost, 2 * 2.50 + 0.5 * 10.0, accuracy: 0.0001)
    }

    func testUnknownModelFallsBackToProviderDefault() {
        let anthropic = ApiUsagePricing.cost(
            provider: .anthropic, model: "totally-unknown", inputTokens: 1_000_000, outputTokens: 0
        )
        let openai = ApiUsagePricing.cost(
            provider: .openai, model: nil, inputTokens: 1_000_000, outputTokens: 0
        )
        XCTAssertEqual(anthropic, 3.0, accuracy: 0.0001) // anthropic default input
        XCTAssertEqual(openai, 2.50, accuracy: 0.0001)   // openai default input
    }

    // MARK: - Window

    func testWindowRanges() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let sevenDays = ApiUsageWindow.last7Days.dateRange(now: now)
        XCTAssertEqual(now.timeIntervalSince(sevenDays.start), 7 * 86_400, accuracy: 1)
        XCTAssertEqual(sevenDays.end, now)

        let thirty = ApiUsageWindow.last30Days.dateRange(now: now)
        XCTAssertEqual(now.timeIntervalSince(thirty.start), 30 * 86_400, accuracy: 1)
    }

    func testCustomWindowNormalizesOrder() {
        let calendar = utcCalendar
        let early = date(year: 2026, month: 7, day: 2, hour: 15)
        let late = date(year: 2026, month: 7, day: 5, hour: 9)

        // Reversed picker values normalize to the first selected day through
        // the start of the day after the final selected day.
        let range = ApiUsageWindow.custom(start: late, end: early).dateRange(calendar: calendar)
        XCTAssertEqual(range.start, date(year: 2026, month: 7, day: 2))
        XCTAssertEqual(range.end, date(year: 2026, month: 7, day: 6))
    }

    func testSameDayCustomWindowIncludesTheWholeSelectedDay() {
        let selected = date(year: 2026, month: 7, day: 9, hour: 18)

        let range = ApiUsageWindow.custom(start: selected, end: selected)
            .dateRange(calendar: utcCalendar)

        XCTAssertEqual(range.start, date(year: 2026, month: 7, day: 9))
        XCTAssertEqual(range.end, date(year: 2026, month: 7, day: 10))
        XCTAssertEqual(range.end.timeIntervalSince(range.start), 86_400)
    }

    // MARK: - DTO decoding

    func testAnthropicUsageResponseDecodes() throws {
        let json = """
        {
          "data": [
            {
              "starting_at": "2026-07-01T00:00:00Z",
              "ending_at": "2026-07-02T00:00:00Z",
              "results": [
                {
                  "uncached_input_tokens": 1000,
                  "cache_read_input_tokens": 400,
                  "cache_creation": {
                    "ephemeral_1h_input_tokens": 300,
                    "ephemeral_5m_input_tokens": 200
                  },
                  "output_tokens": 500,
                  "server_tool_use": {
                    "web_search_requests": 2
                  },
                  "model": "claude-sonnet-4-5",
                  "service_tier": "standard"
                }
              ]
            }
          ],
          "has_more": false,
          "next_page": null
        }
        """
        let response = try JSONDecoder().decode(AnthropicUsageResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.data.count, 1)
        let result = try XCTUnwrap(response.data.first?.results.first)
        XCTAssertEqual(result.model, "claude-sonnet-4-5")
        XCTAssertEqual(result.uncachedInputTokens, 1000)
        XCTAssertEqual(result.cacheReadInputTokens, 400)
        XCTAssertEqual(result.cacheCreation?.ephemeral1HourInputTokens, 300)
        XCTAssertEqual(result.cacheCreation?.ephemeral5MinuteInputTokens, 200)
        XCTAssertEqual(result.outputTokens, 500)
        XCTAssertEqual(result.totalInputTokens, 1900)
        XCTAssertEqual(response.hasMore, false)

        let usage = ApiUsageService.aggregateAnthropic(
            buckets: response.data,
            start: date(year: 2026, month: 7, day: 1),
            end: date(year: 2026, month: 7, day: 2)
        )
        XCTAssertEqual(usage.inputTokens, 1900)
        XCTAssertEqual(usage.outputTokens, 500)
        XCTAssertEqual(usage.models.first?.model, "claude-sonnet-4-5")
    }

    func testOpenAIUsageResponseDecodes() throws {
        let json = """
        {
          "data": [
            { "results": [
              { "model": "gpt-4o", "input_tokens": 800, "output_tokens": 400 }
            ] }
          ],
          "has_more": true,
          "next_page": "abc"
        }
        """
        let response = try JSONDecoder().decode(OpenAIUsageResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.data.first?.results.first?.model, "gpt-4o")
        XCTAssertEqual(response.data.first?.results.first?.outputTokens, 400)
        XCTAssertEqual(response.nextPage, "abc")
    }

    // MARK: - Safe errors

    func testHTTPValidationDropsProviderResponseBody() throws {
        let url = try XCTUnwrap(URL(string: "https://api.example.test/usage"))
        let response = try XCTUnwrap(
            HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)
        )
        let body = Data(#"{"email":"person@example.test","token":"sk-secret"}"#.utf8)

        XCTAssertThrowsError(try ServiceSupport.validate(response, data: body)) { error in
            XCTAssertEqual((error as? ServiceError)?.errorDescription, "HTTP 500")
            XCTAssertFalse(error.localizedDescription.contains("person@example.test"))
            XCTAssertFalse(error.localizedDescription.contains("sk-secret"))
        }
    }

    func testSafeErrorMessageDropsUnknownLocalizedDetails() {
        struct SecretError: LocalizedError {
            var errorDescription: String? { "provider body contained sk-secret" }
        }

        XCTAssertEqual(ServiceSupport.safeErrorMessage(for: SecretError()), "Request failed")
        XCTAssertEqual(
            ServiceSupport.safeErrorMessage(for: ServiceError.apiError("HTTP 429: account@example.test")),
            "HTTP 429"
        )

        let urlError = URLError(
            .badServerResponse,
            userInfo: [NSLocalizedDescriptionKey: "request failed for https://example.test?token=sk-secret"]
        )
        XCTAssertEqual(ServiceSupport.safeErrorMessage(for: urlError), "Network request failed")
    }

    // MARK: - Helpers

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }
}
