# Project Summary - MeterBar

**Purpose:** Quick overview of current project state.
**Last Updated:** 2026-01-12

---

## Current Status

**Phase:** Development
**Version:** 0.1.0

**Status:** Core functionality implemented. All planned features complete. Ready for API endpoint research and Xcode project finalization. Widget implementation complete with proper background handling.

---

## Recent Changes

### 2026-01-12

- **Usage Review:** Reviewed Claude Code/Codex/Cursor usage collection and documented display/gating risks (no code changes)
- **Widget Sync Fix:** Aligned widget data source with App Group JSON and added shared entitlements

### 2025-12-31

- **Widget Background Fix:** Added `containerBackground(for: .widget)` modifier to all widget views (Small, Medium, Large)
- **Xcode Scheme Fix:** Deleted xcuserdata folder to regenerate schemes after project rename
- **WidgetKit Simulator Bug:** Identified WidgetKit Simulator crash on macOS 26.2 beta as known Apple bug (not app code)

### 2025-12-29

- **Initial Implementation:** All core features implemented
- **Project Structure:** Complete Swift/SwiftUI architecture
- **Documentation:** Created `.agents/` documentation structure

---

## Active Work

- [ ] Research actual API endpoints for Claude, OpenAI, Cursor usage data
- [ ] Test widget on real device (workaround for WidgetKit Simulator crash)
- [ ] Implement actual API response parsing (currently placeholders)
- [ ] Add cookie extraction automation for Codex (currently manual)
- [ ] Test authentication flows end-to-end
- [ ] Add unit tests for services
- [ ] Add UI tests for views

---

## Blockers

- **API Endpoints:** Actual endpoints need to be researched/reverse-engineered
- **WidgetKit Simulator:** Known crash on macOS 26.2 beta (test on real device)

---

## Next Steps

1. **API Research:**
   - Inspect network requests from Claude dashboard
   - Inspect network requests from OpenAI dashboard
   - Determine exact request/response formats
   - Update service clients with real endpoints

2. **Testing:**
   - Test on real macOS device (bypass WidgetKit Simulator bug)
   - Test authentication flows
   - Test widget updates
   - Test notifications

3. **Distribution:**
   - Configure App Groups in Xcode
   - Set up code signing
   - Create distribution build
   - Submit to App Store (optional)

---

## Key Metrics

| Metric | Value | Target | Status |
|--------|-------|--------|--------|
| Services Supported | 3 (Claude, OpenAI, Cursor) | 3 | ✅ |
| Widget Sizes | 3 (Small, Medium, Large) | 3 | ✅ |
| Authentication Methods | 3 (Session key, API key, API key) | 3 | ✅ |
| Auto-refresh Interval | 15 minutes | 15 minutes | ✅ |
| API Endpoints Researched | 0/3 | 3 | ⚠️ |
| Test Coverage | 0% | 70% | ⚠️ |

---

## Team Notes

**Architecture:**
- **Singleton Pattern:** Used for managers and services
- **ObservableObject:** For reactive UI updates
- **Async/Await:** Modern Swift concurrency
- **App Groups:** For widget extension data sharing
- **Keychain:** Secure credential storage

**Known Issues:**
- API endpoints are placeholders (need research)
- WidgetKit Simulator crashes on macOS 26.2 beta (Apple bug)
- Cursor doesn't provide usage API (returns error)

**Development:**
- **Language:** Swift 5.9+
- **UI:** SwiftUI
- **Widget:** WidgetKit
- **Storage:** Keychain, UserDefaults, App Groups
- **Build:** Xcode 15.0+

**Next Priorities:**
1. Research API endpoints
2. Test on real device
3. Implement actual API parsing
4. Add tests
