import Foundation

// MARK: - PermissionBypassAcknowledgement

/// Proof that a human explicitly acknowledged running Claude with permission
/// checks disabled.
///
/// Bypass mode (`--dangerously-skip-permissions`) lets a resumed session take any
/// action without approval. It must never be reachable by accident, so the only
/// way to construct this value is to pass `confirmed: true` together with a
/// non-empty reason. A failed construction (returns `nil`) keeps the caller in
/// safe mode.
struct PermissionBypassAcknowledgement: Equatable {
    /// The user-supplied justification, retained for auditing/diagnostics.
    let reason: String
    /// When the acknowledgement was made.
    let acknowledgedAtEpoch: Double

    init?(confirmed: Bool, reason: String, at date: Date = Date()) {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard confirmed, !trimmed.isEmpty else { return nil }
        self.reason = trimmed
        acknowledgedAtEpoch = date.timeIntervalSince1970
    }
}

// MARK: - WakePermissionMode

/// The permission posture a resumed session runs under.
///
/// The default is `.safe`: Claude keeps its normal approval gate and a tool that
/// would need interactive approval fails closed rather than proceeding. `.bypass`
/// can only be formed from a `PermissionBypassAcknowledgement`, so bypass is
/// never the default and always carries explicit consent.
enum WakePermissionMode: Equatable {
    case safe
    case bypass(PermissionBypassAcknowledgement)

    /// The safe posture. Callers must opt into bypass deliberately.
    static var `default`: WakePermissionMode { .safe }

    var isBypass: Bool {
        if case .bypass = self { return true }
        return false
    }

    /// The Claude CLI arguments this mode contributes. Safe mode is explicit
    /// (`--permission-mode default`) so the intent is visible in the argv; bypass
    /// mode adds the dangerous flag only when an acknowledgement exists.
    var claudeArguments: [String] {
        switch self {
        case .safe:
            return ["--permission-mode", "default"]
        case .bypass:
            return ["--dangerously-skip-permissions"]
        }
    }
}

// MARK: - PermissionDenialDetector

/// Recognises a Claude run that ended because it was denied a permission, so the
/// orchestrator can record a *structured* `permissionDenied` outcome.
///
/// Crucially, detection never triggers a retry with bypass: a denied session is
/// reported and left for the user to act on. There is deliberately no code path
/// anywhere that upgrades a safe run to `--dangerously-skip-permissions` on
/// failure.
enum PermissionDenialDetector {
    /// Conservative markers that indicate an approval gate stopped the run. Kept
    /// small and matched case-insensitively to avoid misclassifying unrelated
    /// failures as permission denials.
    private static let markers: [String] = [
        "permission denied",
        "requires permission",
        "requires approval",
        "needs approval",
        "permission to use",
        "permission_denied",
        "--dangerously-skip-permissions"
    ]

    /// Whether `output` (a bounded stdout/stderr capture, never logged) reads as a
    /// permission denial.
    static func indicatesDenial(in output: String) -> Bool {
        let haystack = output.lowercased()
        return markers.contains { haystack.contains($0) }
    }
}
