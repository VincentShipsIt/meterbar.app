import Foundation

/// Shared helpers for the local provider usage services.
///
/// Centralizes the previously duplicated URLSession configuration, the
/// `URLError` → user message mapping, and the real (non-sandboxed) home
/// directory lookup so all services behave consistently.
enum ServiceSupport {
    /// A `URLSession` configured with the standard MeterBar usage-request timeouts.
    static func makeUsageSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    /// Human-readable message for a `URLError`, shared so error copy stays consistent.
    static func message(for urlError: URLError) -> String {
        switch urlError.code {
        case .notConnectedToInternet:
            return "No internet connection"
        case .cannotFindHost, .dnsLookupFailed:
            return "DNS lookup failed"
        case .timedOut:
            return "Request timed out"
        default:
            return urlError.localizedDescription
        }
    }

    /// Performs `request`, validates the HTTP status, and decodes the body.
    ///
    /// Shared by the admin-key API services (Claude/OpenAI usage reports) so the
    /// status-handling and decode boilerplate lives in one place. Maps 401 to
    /// `.notAuthenticated` and other non-2xx codes to `.apiError`.
    static func fetchDecoded<T: Decodable>(
        _ request: URLRequest,
        decoder: JSONDecoder,
        session: URLSession = .shared
    ) async throws -> T {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.apiError("Invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw ServiceError.notAuthenticated
            }
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ServiceError.apiError("API error (\(httpResponse.statusCode)): \(errorMessage)")
        }

        return try decoder.decode(T.self, from: data)
    }

    /// The real home directory for the current user.
    ///
    /// In sandboxed builds `FileManager.homeDirectoryForCurrentUser` returns the
    /// app container path; CLI credential/log files live under the user's actual
    /// home, so resolve it via `getpwuid` (with environment and FileManager
    /// fallbacks).
    static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()) {
            return String(cString: pw.pointee.pw_dir)
        }
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return home
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
}
