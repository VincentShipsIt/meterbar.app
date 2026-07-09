import Foundation

/// Resolves the Codex state directory consistently for every local integration.
///
/// Codex honors `CODEX_HOME`; MeterBar must therefore use the same directory for
/// activity, auth, readiness, and cost scans. Keeping this path logic pure also
/// lets tests exercise custom homes without mutating the process environment.
enum CodexHomeDirectory {
    static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        guard let rawValue = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty else {
            return (realHomeDirectory as NSString).appendingPathComponent(".codex")
        }

        if rawValue == "~" {
            return realHomeDirectory
        }
        if rawValue.hasPrefix("~/") {
            return (realHomeDirectory as NSString).appendingPathComponent(String(rawValue.dropFirst(2)))
        }
        return (rawValue as NSString).standardizingPath
    }

    static func authFilePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        (path(environment: environment, realHomeDirectory: realHomeDirectory) as NSString)
            .appendingPathComponent("auth.json")
    }
}
