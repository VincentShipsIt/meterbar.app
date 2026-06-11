import Foundation
import AppKit
import Combine

class ClaudeCodeLocalService: ObservableObject {
    static let shared = ClaudeCodeLocalService()

    // Working endpoint (discovered via testing)
    private let usageEndpoint = "https://api.anthropic.com/api/oauth/usage"

    private let baseURL = "https://api.anthropic.com"
    private let keychainService = "Claude Code-credentials"
    private let cliUsageService = ClaudeCodeCLIUsageService.shared
    private let oauthFallbackUserDefaultsKey = "ClaudeCodeEnableOAuthFallback"

    // URLSession with timeout configuration
    private lazy var urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30.0
        configuration.timeoutIntervalForResource = 60.0
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    @Published private(set) var hasAccess: Bool = false
    @Published private(set) var subscriptionType: String?
    @Published private(set) var rateLimitTier: String?
    @Published private(set) var lastError: ServiceError?
    @Published private(set) var authState: ClaudeCodeAuthState = .unavailable

    private init() {
        // Check if we have Claude Code credentials on init
        checkAccess()
    }

    // MARK: - Keychain Access

    /// Get OAuth token from Claude Code's keychain storage
    func getOAuthToken() -> String? {
        guard let credentials = getCredentials() else {
            return nil
        }

        guard !OAuthTokenExpiry.isExpired(unixTimestamp: credentials.claudeAiOauth.expiresAt) else {
            DispatchQueue.main.async {
                self.subscriptionType = credentials.claudeAiOauth.subscriptionType
                self.rateLimitTier = credentials.claudeAiOauth.rateLimitTier
                self.hasAccess = false
            }
            return nil
        }

        DispatchQueue.main.async {
            self.subscriptionType = credentials.claudeAiOauth.subscriptionType
            self.rateLimitTier = credentials.claudeAiOauth.rateLimitTier
            self.hasAccess = true
        }

        return credentials.claudeAiOauth.accessToken
    }

    private func getCredentials() -> ClaudeCodeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let jsonString = String(data: data, encoding: .utf8) else {
            return nil
        }

        guard let jsonData = jsonString.data(using: .utf8),
              let credentials = try? JSONDecoder().decode(ClaudeCodeCredentials.self, from: jsonData) else {
            return nil
        }

        return credentials
    }

    /// Check and update access status
    func checkAccess() {
        if cliUsageService.isAvailable() {
            hasAccess = true
            authState = .cliAvailable
        } else if isOAuthFallbackEnabled, let _ = getOAuthToken() {
            hasAccess = true
            authState = .connected(.legacyOAuth)
        } else {
            hasAccess = false
            authState = .unavailable
            if !isOAuthFallbackEnabled || getCredentials() == nil {
                subscriptionType = nil
                rateLimitTier = nil
            }
        }
    }

    // MARK: - Usage Fetching

    func fetchUsageMetrics(account: ClaudeCodeAccount = .defaultAccount) async throws -> UsageMetrics {
        do {
            let metrics = try await cliUsageService.fetchUsageMetrics(account: account)
            await MainActor.run {
                self.lastError = nil
                self.hasAccess = true
                if account.isDefault || self.authState == .unavailable {
                    self.authState = .connected(.cli)
                }
            }
            return metrics
        } catch {
            if !account.isDefault || !isOAuthFallbackEnabled {
                let serviceError = serviceError(from: error)
                await MainActor.run {
                    self.lastError = serviceError
                    if account.isDefault {
                        self.hasAccess = false
                        self.authState = authState(from: error)
                    }
                }
                throw serviceError
            }
        }

        guard let token = getOAuthToken() else {
            let error = ServiceError.notAuthenticated
            await MainActor.run {
                self.lastError = error
                self.hasAccess = false
                self.authState = .needsLogin
            }
            throw error
        }

        guard let url = URL(string: usageEndpoint) else {
            throw ServiceError.apiError("Invalid usage endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 30.0

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceError.apiError("Invalid response type")
            }

            if httpResponse.statusCode == 401 {
                await MainActor.run {
                    self.hasAccess = false
                    self.lastError = ServiceError.notAuthenticated
                    self.authState = .needsLogin
                }
                throw ServiceError.notAuthenticated
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw ServiceError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let usageResponse = try decoder.decode(ClaudeCodeUsageResponse.self, from: data)

            await MainActor.run {
                self.lastError = nil
                self.hasAccess = true
                self.authState = .connected(.legacyOAuth)
            }

            // Session limit = 5-hour window
            let sessionLimit = UsageLimit(
                used: usageResponse.fiveHour.utilization,
                total: 100.0,
                resetTime: usageResponse.fiveHour.resetsAt,
                windowSeconds: 5 * 60 * 60
            )

            // Weekly limit = 7-day window (all models)
            let weeklyLimit = UsageLimit(
                used: usageResponse.sevenDay.utilization,
                total: 100.0,
                resetTime: usageResponse.sevenDay.resetsAt,
                windowSeconds: 7 * 24 * 60 * 60
            )

            // Sonnet-only weekly limit (if available)
            var sonnetLimit: UsageLimit? = nil
            if let sonnet = usageResponse.sevenDaySonnet {
                sonnetLimit = UsageLimit(
                    used: sonnet.utilization,
                    total: 100.0,
                    resetTime: sonnet.resetsAt,
                    windowSeconds: 7 * 24 * 60 * 60
                )
            }

            return UsageMetrics(
                service: .claudeCode,
                sessionLimit: sessionLimit,
                weeklyLimit: weeklyLimit,
                codeReviewLimit: sonnetLimit
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
            await MainActor.run {
                self.lastError = error
                self.authState = .error(errorMessage)
            }
            throw error
        } catch let error as ServiceError {
            throw error
        } catch {
            let serviceError = ServiceError.parsingError
            await MainActor.run {
                self.lastError = serviceError
                self.authState = .error(serviceError.localizedDescription)
            }
            throw serviceError
        }
    }

    private var isOAuthFallbackEnabled: Bool {
        UserDefaults.standard.bool(forKey: oauthFallbackUserDefaultsKey)
    }

    private func serviceError(from error: Error) -> ServiceError {
        if let serviceError = error as? ServiceError {
            return serviceError
        }

        if let cliError = error as? ClaudeCodeCLIUsageError {
            switch cliError {
            case .cliNotFound:
                return .notAuthenticated
            case .parsingFailed:
                return .parsingError
            case .timedOut, .launchFailed, .commandFailed:
                return .apiError(cliError.localizedDescription)
            }
        }

        return .apiError(error.localizedDescription)
    }

    private func authState(from error: Error) -> ClaudeCodeAuthState {
        guard let cliError = error as? ClaudeCodeCLIUsageError else {
            return .error(error.localizedDescription)
        }

        switch cliError {
        case .cliNotFound:
            return .unavailable
        case let .commandFailed(message):
            let lowercased = message.lowercased()
            if lowercased.contains("login") || lowercased.contains("auth") || lowercased.contains("unauthorized") {
                return .needsLogin
            }
            return .error(cliError.localizedDescription)
        case .timedOut, .launchFailed, .parsingFailed:
            return .error(cliError.localizedDescription)
        }
    }
}

enum ClaudeCodeUsageSource: String {
    case cli = "Claude CLI"
    case legacyOAuth = "Legacy OAuth"
}

enum ClaudeCodeAuthState: Equatable {
    case unavailable
    case cliAvailable
    case connected(ClaudeCodeUsageSource)
    case needsLogin
    case error(String)

    var statusText: String {
        switch self {
        case .unavailable:
            return "Not Connected"
        case .cliAvailable:
            return "Ready (Claude CLI)"
        case let .connected(source):
            return "Connected (\(source.rawValue))"
        case .needsLogin:
            return "Login Required"
        case .error:
            return "Needs Attention"
        }
    }

    var guidanceText: String {
        switch self {
        case .unavailable:
            return "Install Claude Code and run 'claude login'."
        case .cliAvailable:
            return "Using Claude CLI usage output; refresh to update."
        case .connected(.cli):
            return "Using Claude CLI usage output."
        case .connected(.legacyOAuth):
            return "Using legacy OAuth fallback."
        case .needsLogin:
            return "Run 'claude login' again."
        case let .error(message):
            return message
        }
    }
}

// MARK: - Response Models

struct ClaudeCodeCredentials: Codable {
    let claudeAiOauth: ClaudeAiOAuth

    enum CodingKeys: String, CodingKey {
        case claudeAiOauth = "claudeAiOauth"
    }
}

struct ClaudeAiOAuth: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int64
    let scopes: [String]
    let subscriptionType: String?
    let rateLimitTier: String?
}

struct ClaudeCodeUsageResponse: Codable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let sevenDaySonnet: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
    }
}

struct UsageWindow: Codable {
    let utilization: Double
    let resetsAt: Date

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}
