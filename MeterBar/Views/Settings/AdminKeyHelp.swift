import AppKit
import SwiftUI

/// Shared admin-key help sheet. The Claude and OpenAI variants only differ by
/// copy and the console URL, so they share one layout.
private struct AdminKeyHelpView: View {
    @Environment(\.dismiss)
    var dismiss

    let title: String
    let intro: String
    let steps: [String]
    let note: String
    let consoleButtonTitle: String
    let consoleURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2)
                .bold()

            Text(intro)
                .foregroundColor(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                }
            }

            Divider()

            Text(note)
                .font(.caption)
                .foregroundStyle(MeterBarTheme.warning)

            HStack {
                Button(consoleButtonTitle) {
                    if let url = URL(string: consoleURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button("Close") {
                    dismiss()
                }
            }
        }
        .padding()
        .frame(width: 500, height: 400)
    }
}

struct ClaudeHelpView: View {
    var body: some View {
        AdminKeyHelpView(
            title: "How to get Claude Admin API Key",
            intro: "The Usage API requires an Admin API key, which is different from a regular API key.",
            steps: [
                "Go to the Claude Console",
                "Navigate to Settings → Admin Keys",
                "Click 'Create Admin Key'",
                "Copy the key (starts with sk-ant-admin...)",
                "Paste it in the field above"
            ],
            note: "Note: You must be an organization admin to create Admin API keys. "
                + "Individual accounts cannot access the Usage API.",
            consoleButtonTitle: "Open Claude Console",
            consoleURL: "https://console.anthropic.com/settings/admin-keys"
        )
    }
}

struct OpenAIHelpView: View {
    var body: some View {
        AdminKeyHelpView(
            title: "How to get OpenAI Admin API Key",
            intro: "The Usage API requires an Admin key from your organization settings.",
            steps: [
                "Go to OpenAI Platform",
                "Navigate to Settings → Organization → Admin Keys",
                "Click 'Create new admin key'",
                "Copy the key",
                "Paste it in the field above"
            ],
            note: "Note: You must be an organization owner or admin to create Admin keys.",
            consoleButtonTitle: "Open OpenAI Settings",
            consoleURL: "https://platform.openai.com/settings/organization/admin-keys"
        )
    }
}
