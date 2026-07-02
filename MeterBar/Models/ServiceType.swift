import Foundation

// Public: part of the MeterBar library's API surface consumed by the
// meterbar CLI (MeterBarCLI depends on this package instead of maintaining
// its own copies of the model types).
public enum ServiceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode = "Claude Code"
    case codexCli = "Codex CLI"
    case cursor = "Cursor"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCli: return "OpenAI Codex"
        case .cursor: return "Cursor"
        }
    }

    public var iconName: String {
        switch self {
        case .claudeCode: return "terminal"
        case .codexCli: return "terminal.fill"
        case .cursor: return "cursorarrow.click"
        }
    }
}
