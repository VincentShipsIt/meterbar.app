# MeterBar

Claude-specific entry point. Documentation in `.agents/`.

## Commands

Check `.agents/SYSTEM/RULES.md` for coding standards.
Architecture reality-check: `.agents/SYSTEM/ARCHITECTURE.md` and `docs/audits/00-repo-map.md`.

## Sessions

Document all work in `.agents/SESSIONS/YYYY-MM-DD.md` (one file per day).

## Testing Policy
- Write tests FIRST before implementation (TDD)
- All new features must include tests before code
- Aim for 80%+ coverage on new code
- Run tests before committing (`swift test`; requires full Xcode — CLT alone lacks XCTest)
