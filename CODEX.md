# MeterBar

Codex-specific entry point. Documentation in `.agents/`.

## Documentation

- `.agents/README.md` - Start here
- `.agents/SYSTEM/` - Architecture and rules
- `.agents/docs/DEFERRED_WORK.md` - Known tech debt
- `docs/audits/00-repo-map.md` - Audited repo map

## Testing Policy
- Write tests FIRST before implementation (TDD)
- All new features must include tests before code
- Aim for 80%+ coverage on new code
- Run tests before committing (`swift test`; requires full Xcode — CLT alone lacks XCTest)
