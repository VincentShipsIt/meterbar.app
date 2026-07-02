import AppKit
import SwiftUI

enum ProviderLogoKind: Equatable {
    case overview
    case codex
    case claude
    case cursor

    var resourceName: String? {
        switch self {
        case .overview:
            return nil
        case .codex:
            return "ProviderIcon-codex"
        case .claude:
            return "ProviderIcon-claude"
        case .cursor:
            return "ProviderIcon-cursor"
        }
    }

    var fallbackSystemName: String {
        switch self {
        case .overview:
            return "square.grid.2x2"
        case .codex:
            return ServiceType.codexCli.iconName
        case .claude:
            return ServiceType.claudeCode.iconName
        case .cursor:
            return ServiceType.cursor.iconName
        }
    }
}

struct ProviderLogoView: View {
    let kind: ProviderLogoKind
    let size: CGFloat
    let foregroundColor: Color

    var body: some View {
        if let resourceName = kind.resourceName,
           let image = ProviderLogoImageCache.image(named: resourceName) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .foregroundColor(foregroundColor)
                .frame(width: size, height: size)
        } else {
            Image(systemName: kind.fallbackSystemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(foregroundColor)
                .frame(width: size, height: size)
        }
    }
}

enum ProviderLogoImageCache {
    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] {
            return cached
        }

        if let image = NSImage(named: name) ?? bundledSVGImage(named: name) {
            image.isTemplate = true
            cache[name] = image
            return image
        }

        return nil
    }

    private static func bundledSVGImage(named name: String) -> NSImage? {
        let bundle = Bundle.main
        let url = bundle.url(forResource: name, withExtension: "svg") ??
            bundle.url(forResource: name, withExtension: "svg", subdirectory: "Resources")

        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }
}
