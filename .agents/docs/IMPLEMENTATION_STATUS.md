# Implementation Status

**Last Updated:** 2026-07-09 (rewritten — the previous version described the original planning-phase
design, including `CodexService`/`CursorService` classes and "Codex cookies" that were never shipped
under those names; see `docs/audits/00-repo-map.md` for the audited current state)

## ✅ Shipped

### Providers
- ✅ Claude Code via `claude /usage` CLI parsing (multi-account via `CLAUDE_CONFIG_DIR`)
- ✅ Claude Code legacy OAuth fallback (opt-in `ClaudeCodeEnableOAuthFallback` UserDefaults flag)
- ✅ OpenAI Codex CLI via `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`) + wham/usage endpoint (incl. extra-usage + reset credits)
- ✅ Cursor via local SQLite token + usage-summary endpoint
- ✅ Anthropic Admin API org usage (optional, user-provided key)
- ✅ OpenAI Admin API org usage (optional, user-provided key)
- ✅ Admin-key migration from the v1.0-v1.6 Keychain service into the current migration-stable service

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
- ✅ CI: required test/coverage, SwiftLint, secret scan, and universal app/widget/CLI gates (`.github/workflows/ci.yml`)
- ✅ Release: universal ad-hoc-signed zip with architecture/version/entitlement verification + GitHub Release + Homebrew tap bump
- ✅ Secret scanning (gitleaks, pinned + checksum-verified)

## ❌ Not implemented / known gaps

- ❌ Developer ID signing, authorized provisioning, and notarization (ad-hoc signatures do not provide Gatekeeper or app-group authorization)
- ❌ Crash reporting / telemetry of any kind
- ❌ Credential-backed provider integration and notarized-install/widget verification remain environment-dependent
- ❌ Mac App Store distribution (the app is deliberately un-sandboxed so it can read other tools'
  credential/log files; MAS would require a different architecture)
