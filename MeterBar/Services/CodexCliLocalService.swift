import Foundation
import AppKit
import Combine

/// Service for fetching Codex CLI usage data from https://chatgpt.com/backend-api/wham/usage
/// Reads authentication token from ~/.codex/auth.json (stored by Codex CLI).
/// Similar to ClaudeCodeLocalService, but for Codex CLI usage tracking.
///
/// The API endpoint returns usage data with:
/// - Primary window: 5-hour limit (18000 seconds)
/// - Secondary window: 7-day limit (604800 seconds)
/// - Code review rate limit: 7-day limit for code review features
class CodexCliLocalService: ObservableObject {
    static let shared = CodexCliLocalService()

    // API endpoint for Codex CLI usage
    private let usageEndpoint = "https://chatgpt.com/backend-api/wham/usage"

    // Path to Codex CLI auth file
    private var authFilePath: String {
        let homeDir = getRealHomeDirectory()
        return "\(homeDir)/.codex/auth.json"
    }

    /// Get the REAL home directory (not sandboxed container)
    private func getRealHomeDirectory() -> String {
        // In sandboxed apps, FileManager.homeDirectoryForCurrentUser returns the container path
        // We need the actual user home directory to access Codex CLI's auth file
        if let pw = getpwuid(getuid()) {
            return String(cString: pw.pointee.pw_dir)
        }
        // Fallback to environment variable
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            return home
        }
        // Last resort - this will be sandboxed but better than nothing
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    // URLSession with timeout configuration
    private lazy var urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30.0
        configuration.timeoutIntervalForResource = 60.0
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    @Published private(set) var hasAccess: Bool = false
    @Published private(set) var lastError: ServiceError?
    @Published private(set) var subscriptionType: String?

    private init() {
        // Check if we have Codex CLI credentials on init
        checkAccess()
    }

    // MARK: - Auth File Access

    /// Read OAuth access token from ~/.codex/auth.json
    /// This file is created and maintained by the Codex CLI when user logs in
    func getAuthToken() -> String? {
        guard let token = readAuthFile()?.tokens?.accessToken else {
            return nil
        }

        guard !OAuthTokenExpiry.isExpired(jwt: token) else {
            return nil
        }

        return token
    }

    /// Read account ID from ~/.codex/auth.json
    /// Required for the ChatGPT-Account-Id header to get team/workspace data
    func getAccountId() -> String? {
        readAuthFile()?.tokens?.accountId
    }

    private func readAuthFile() -> CodexAuthFile? {
        guard FileManager.default.fileExists(atPath: authFilePath),
              let data = FileManager.default.contents(atPath: authFilePath) else {
            return nil
        }

        return try? JSONDecoder().decode(CodexAuthFile.self, from: data)
    }

    /// Check and update access status
    func checkAccess() {
        let token = getAuthToken()
        let hasToken = token != nil
        if hasToken {
            hasAccess = true
        } else {
            hasAccess = false
            subscriptionType = nil
        }
    }

    // MARK: - Usage Fetching

    func fetchUsageMetrics() async throws -> UsageMetrics {
        guard let token = getAuthToken() else {
            let error = ServiceError.notAuthenticated
            await MainActor.run {
                self.lastError = error
                self.hasAccess = false
            }
            throw error
        }

        guard let url = URL(string: usageEndpoint) else {
            throw ServiceError.apiError("Invalid usage endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Use Bearer token auth (from ~/.codex/auth.json)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        // CRITICAL: Include ChatGPT-Account-Id header to get team/workspace data
        // Without this header, API returns free plan data even for team accounts
        if let accountId = getAccountId() {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        // Browser-like headers to avoid blocks
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30.0

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceError.apiError("Invalid response type")
            }

            print("[CodexCliLocalService] Usage response status: \(httpResponse.statusCode)")

            if httpResponse.statusCode == 401 {
                await MainActor.run {
                    self.hasAccess = false
                    self.lastError = ServiceError.notAuthenticated
                }
                throw ServiceError.notAuthenticated
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                print("[CodexCliLocalService] Usage error: \(errorMessage.prefix(200))")
                throw ServiceError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage.prefix(100))")
            }

            let decoder = JSONDecoder()
            // Note: Codex CLI API uses Unix timestamps (Int64), not ISO8601 dates
            
            // Decode the actual Codex CLI usage response
            let usageResponse = try decoder.decode(CodexCliUsageResponse.self, from: data)

            await MainActor.run {
                self.lastError = nil
                self.hasAccess = true
                self.subscriptionType = usageResponse.planType
            }

            // Check if rate limits exist (free accounts have null rate_limit)
            guard let rateLimit = usageResponse.rateLimit else {
                print("[CodexCliLocalService] No rate limit data (free account or no usage yet)")
                // Return empty metrics for free accounts
                return UsageMetrics(
                    service: .codexCli,
                    sessionLimit: nil,
                    weeklyLimit: nil,
                    codeReviewLimit: nil
                )
            }

            // Map the response to UsageMetrics
            // Primary window (5 hours = 18000 seconds) = session limit
            let primaryWindow = rateLimit.primaryWindow
            print("[CodexCliLocalService] Primary window: usedPercent=\(primaryWindow.usedPercent), resetAt=\(primaryWindow.resetAt)")
            let sessionLimit = UsageLimit(
                used: primaryWindow.usedPercent,
                total: 100.0,
                resetTime: Date(timeIntervalSince1970: Double(primaryWindow.resetAt)),
                windowSeconds: TimeInterval(primaryWindow.limitWindowSeconds)
            )

            // Secondary window (7 days = 604800 seconds) = weekly limit
            let secondaryWindow = rateLimit.secondaryWindow
            print("[CodexCliLocalService] Secondary window: usedPercent=\(secondaryWindow?.usedPercent ?? -1), resetAt=\(secondaryWindow?.resetAt ?? 0)")
            let weeklyLimit = UsageLimit(
                used: secondaryWindow?.usedPercent ?? 0.0,
                total: 100.0,
                resetTime: secondaryWindow != nil ? Date(timeIntervalSince1970: Double(secondaryWindow!.resetAt)) : Date(),
                windowSeconds: secondaryWindow.map { TimeInterval($0.limitWindowSeconds) }
            )

            // Code review rate limit (7 days window) = code review limit
            var codeReviewLimit: UsageLimit? = nil
            if let codeReviewPrimary = usageResponse.codeReviewRateLimit?.primaryWindow {
                print("[CodexCliLocalService] Code review: usedPercent=\(codeReviewPrimary.usedPercent), resetAt=\(codeReviewPrimary.resetAt)")
                codeReviewLimit = UsageLimit(
                    used: codeReviewPrimary.usedPercent,
                    total: 100.0,
                    resetTime: Date(timeIntervalSince1970: Double(codeReviewPrimary.resetAt)),
                    windowSeconds: TimeInterval(codeReviewPrimary.limitWindowSeconds)
                )
            }

            print("[CodexCliLocalService] Final metrics: session=\(sessionLimit.percentage)%, weekly=\(weeklyLimit.percentage)%, codeReview=\(codeReviewLimit?.percentage ?? -1)%")
            return UsageMetrics(
                service: .codexCli,
                sessionLimit: sessionLimit,
                weeklyLimit: weeklyLimit,
                codeReviewLimit: codeReviewLimit
            )
        } catch let urlError as URLError {
            let errorMessage: String
            switch urlError.code {
            case .notConnectedToInternet:
                errorMessage = "No internet connection"
            case .cannotFindHost, .dnsLookupFailed:
                errorMessage = "DNS lookup failed"
            case .timedOut:
                errorMessage = "Request timed out"
            default:
                errorMessage = urlError.localizedDescription
            }
            let error = ServiceError.apiError(errorMessage)
            await MainActor.run { self.lastError = error }
            throw error
        } catch let error as ServiceError {
            throw error
        } catch let decodingError as DecodingError {
            print("[CodexCliLocalService] Decoding error: \(decodingError)")
            let serviceError = ServiceError.parsingError
            await MainActor.run { self.lastError = serviceError }
            throw serviceError
        } catch {
            let serviceError = ServiceError.parsingError
            await MainActor.run { self.lastError = serviceError }
            throw serviceError
        }
    }
}

// MARK: - Response Models

/// Response structure for Codex CLI usage API from https://chatgpt.com/backend-api/wham/usage
struct CodexCliUsageResponse: Codable {
    let planType: String
    let rateLimit: RateLimit?  // Can be null for free accounts
    let codeReviewRateLimit: CodeReviewRateLimit?
    let credits: Credits?  // Can be null for free accounts

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case codeReviewRateLimit = "code_review_rate_limit"
        case credits
    }
}

struct RateLimit: Codable {
    let allowed: Bool
    let limitReached: Bool
    let primaryWindow: LimitWindow
    let secondaryWindow: LimitWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct CodeReviewRateLimit: Codable {
    let allowed: Bool
    let limitReached: Bool
    let primaryWindow: LimitWindow
    let secondaryWindow: LimitWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct LimitWindow: Codable {
    let usedPercent: Double
    let limitWindowSeconds: Int
    let resetAfterSeconds: Int
    let resetAt: Int64

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }
}

struct Credits: Codable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: Double?
    let approxLocalMessages: Int?
    let approxCloudMessages: Int?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
        case approxLocalMessages = "approx_local_messages"
        case approxCloudMessages = "approx_cloud_messages"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = (try? container.decode(Bool.self, forKey: .hasCredits)) ?? false
        unlimited = (try? container.decode(Bool.self, forKey: .unlimited)) ?? false

        if let doubleBalance = try? container.decode(Double.self, forKey: .balance) {
            balance = doubleBalance
        } else if let stringBalance = try? container.decode(String.self, forKey: .balance) {
            balance = Double(stringBalance)
        } else {
            balance = nil
        }

        approxLocalMessages = Self.decodeMessageEstimate(container, forKey: .approxLocalMessages)
        approxCloudMessages = Self.decodeMessageEstimate(container, forKey: .approxCloudMessages)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hasCredits, forKey: .hasCredits)
        try container.encode(unlimited, forKey: .unlimited)
        try container.encodeIfPresent(balance, forKey: .balance)
        try container.encodeIfPresent(approxLocalMessages, forKey: .approxLocalMessages)
        try container.encodeIfPresent(approxCloudMessages, forKey: .approxCloudMessages)
    }

    private static func decodeMessageEstimate(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let values = try? container.decode([Int].self, forKey: key) {
            return values.last ?? values.first
        }
        return nil
    }
}

// MARK: - Auth File Models

/// Structure of ~/.codex/auth.json
struct CodexAuthFile: Codable {
    let openaiApiKey: String?
    let tokens: CodexTokens?
    let lastRefresh: String?

    enum CodingKeys: String, CodingKey {
        case openaiApiKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }
}

struct CodexTokens: Codable {
    let idToken: String?
    let accessToken: String?
    let refreshToken: String?
    let accountId: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountId = "account_id"
    }
}
