# Project Structure

This document describes the structure of the MeterBar project.

## Directory Layout

```
apps/ai-usage-tracker/
├── AGENTS.md                    # AI agent entry point
├── CLAUDE.md                    # Claude-specific entry
├── CODEX.md                     # Codex-specific entry
├── README.md                    # Main project documentation
├── LICENSE                      # MIT License
├── CONTRIBUTING.md              # Contribution guidelines
├── SETUP.md                     # Setup instructions
├── Package.swift                # Swift Package Manager manifest
├── .gitignore                   # Git ignore rules
├── .agents/                      # AI documentation
│   └── README.md
├── .github/                     # GitHub templates
│   ├── ISSUE_TEMPLATE/
│   ├── pull_request_template.md
│   └── CODE_OF_CONDUCT.md
└── MeterBar/              # Source code
    ├── App/
    │   └── MeterBarApp.swift
    ├── Models/
    │   ├── ServiceType.swift
    │   ├── UsageLimit.swift
    │   └── UsageMetrics.swift
    ├── Services/
    │   ├── KeychainManager.swift
    │   ├── AuthenticationManager.swift
    │   ├── ClaudeService.swift
    │   ├── CodexService.swift
    │   ├── CursorService.swift
    │   └── UsageDataManager.swift
    ├── Views/
    │   ├── SettingsView.swift
    │   └── MenuBarView.swift
    ├── Widget/
    │   ├── UsageWidget.swift
    │   └── UsageWidgetBundle.swift
    └── Info.plist
```

## Key Components

### App
- `MeterBarApp.swift`: Main app entry point, menu bar setup, notifications

### Models
- `ServiceType.swift`: Enum for supported services (Claude, Codex, Cursor)
- `UsageLimit.swift`: Model for usage limits with percentage calculations
- `UsageMetrics.swift`: Unified model for service usage data

### Services
- `KeychainManager.swift`: Secure credential storage using macOS Keychain
- `AuthenticationManager.swift`: Manages authentication state for all services
- `ClaudeService.swift`: API client for Claude usage data
- `CodexService.swift`: API client for Codex usage data
- `CursorService.swift`: API client for Cursor usage data
- `UsageDataManager.swift`: Centralized data management, caching, auto-refresh

### Views
- `SettingsView.swift`: Settings window for authentication and preferences
- `MenuBarView.swift`: Menu bar dropdown with usage metrics

### Widget
- `UsageWidget.swift`: WidgetKit widget implementation (small/medium/large)
- `UsageWidgetBundle.swift`: Widget bundle entry point

## Architecture Patterns

### Singleton Pattern
- `KeychainManager.shared`
- `AuthenticationManager.shared`
- `UsageDataManager.shared`
- Service classes (ClaudeService, CodexService, CursorService)

### ObservableObject
- `AuthenticationManager`: Published properties for auth state
- `UsageDataManager`: Published properties for metrics and loading state

### Async/Await
- All API calls use async/await
- Background refresh uses Task

### Keychain Storage
- All credentials stored securely in macOS Keychain
- No plaintext storage of sensitive data

## Data Flow

1. User authenticates via Settings
2. Credentials stored in Keychain
3. UsageDataManager fetches data from services
4. Data cached in UserDefaults
5. UI updates via @Published properties
6. Widget updates via TimelineProvider

## Dependencies

- SwiftUI (native)
- WidgetKit (native)
- Combine (native)
- UserNotifications (native)
- Foundation (native)

No external dependencies required.

