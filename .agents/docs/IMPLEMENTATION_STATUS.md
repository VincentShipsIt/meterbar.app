# Implementation Status

**Last Updated:** 2026-07-02 (rewritten — the previous version described the original planning-phase
design, including `CodexService`/`CursorService` classes and "Codex cookies" that were never shipped
under those names; see `docs/audits/00-repo-map.md` for the audited current state)

## ✅ Shipped

### Providers
- ✅ Claude Code via `claude /usage` CLI parsing (multi-account via `CLAUDE_CONFIG_DIR`)
- ✅ Claude Code legacy OAuth fallback (opt-in `ClaudeCodeEnableOAuthFallback` UserDefaults flag)
- ✅ OpenAI Codex CLI via `~/.codex/auth.json` + wham/usage endpoint (incl. extra-usage + reset credits)
- ✅ Cursor via local SQLite token + usage-summary endpoint
- ✅ Anthropic Admin API org usage (optional, user-provided key)
- ✅ OpenAI Admin API org usage (optional, user-provided key)

### App
- ✅ Menu bar status item showing most-constrained-quota percentage
- ✅ Popover (`MenuBarView`) with per-provider accordion cards
- ✅ Usage dashboard window (`UsageDashboardView`) with daily cost charts
- ✅ Settings (`SettingsView`): provider toggles, admin keys, Claude accounts, refresh interval, Dock toggle
- ✅ Local notifications at 90%/100% with stable ids and re-arm-on-drop
- ✅ Cost tracking from local session logs (Claude JSONL + Codex archived sessions/SQLite)
- ✅ WidgetKit widget fed via app group JSON
- ✅ `meterbar` CLI (usage/cost subcommands) bundled in `Contents/Helpers/`

### Infra
- ✅ CI: xcodebuild build + `swift test` gate + coverage check + SwiftLint (`.github/workflows/ci.yml`)
- ✅ Release: unsigned zip + GitHub Release + Homebrew tap bump
- ✅ Secret scanning (gitleaks, pinned + checksum-verified)

## ❌ Not implemented / known gaps

- ❌ Code signing + notarization (releases are unsigned; users must clear quarantine)
- ❌ Shared `MeterBarShared` package — model structs duplicated in widget + CLI (see `DEFERRED_WORK.md` §1)
- ❌ Crash reporting / telemetry of any kind
- ❌ Tests for `UsageDataManager` orchestration, `CostTracker` scan paths, view layer, CLI package
- ❌ Mac App Store distribution (the app is deliberately un-sandboxed so it can read other tools'
  credential/log files; MAS would require a different architecture)
