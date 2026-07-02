import AppKit
import SwiftUI

struct SettingsPanelSection<Content: View>: View {
    let title: String
    let logoKind: ProviderLogoKind?
    let systemImage: String?
    let color: Color
    let content: Content

    init(
        title: String,
        logoKind: ProviderLogoKind,
        color: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.logoKind = logoKind
        self.systemImage = nil
        self.color = color
        self.content = content()
    }

    init(
        title: String,
        systemImage: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.logoKind = nil
        self.systemImage = systemImage
        self.color = color
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            HStack(spacing: 6) {
                if let logoKind {
                    ProviderLogoView(kind: logoKind, size: 14, foregroundColor: color)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(color)
                }
                Text(title)
            }
        }
    }
}

struct SettingsRowView<Content: View>: View {
    let title: String
    let detail: String?
    let content: Content

    init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        LabeledContent {
            content
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SettingsNotice: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider()
    }
}

struct StatusPill: View {
    let title: String
    let isConnected: Bool

    var body: some View {
        Label(title, systemImage: isConnected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isConnected ? MeterBarTheme.success : Color.secondary)
            .font(.subheadline)
    }
}

struct AccountProfileRow: View {
    let account: ClaudeCodeAccount
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: account.isDefault ? "person.crop.circle" : "person.crop.circle.badge.plus")
                .foregroundStyle(MeterBarTheme.claudeAccent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(account.configDirectory ?? "Default Claude CLI profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !account.isDefault {
                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
