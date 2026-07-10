import Foundation

/// The distinguishable results of `meterbar wake`, each with a stable exit code
/// so scripts can branch on outcome.
///
/// The exit codes are deliberately outside the 1–2 range that argument-parsing
/// and generic errors use, and cancellation follows the 128+SIGINT convention.
enum WakeCLIOutcome: String, Codable, Equatable, Sendable {
    case success
    case blockedWithoutWait
    case quotaUnknown
    case validationFailure
    case partialFailure
    case cancellation

    var exitCode: Int32 {
        switch self {
        case .success: return 0
        case .blockedWithoutWait: return 10
        case .quotaUnknown: return 11
        case .validationFailure: return 12
        case .partialFailure: return 13
        case .cancellation: return 130 // 128 + SIGINT(2)
        }
    }
}
