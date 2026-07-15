---
status: complete
---

# Release app signing summary

## Completed

- `scripts/build-app.sh` now builds SwiftPM in release mode, copies the release executable, and accepts one `APP_VERSION` override for both bundle version fields.
- Nested whisper dylibs and `whisper-cli` are signed before the outer app bundle is sealed with configurable `CODESIGN_IDENTITY` (default `-`).
- `scripts/verify-app-signing.sh` validates the completed bundle with `codesign --verify --deep --strict --verbose=2`; it documents why `spctl` is intentionally excluded for ad-hoc signatures.
- Reconciled the project agent-memory convention: retained the Claude guidance in `AGENTS.md` and made `CLAUDE.md` the compatibility symlink.

## Verification

- `./scripts/fetch-whisper.sh && ./scripts/build-app.sh`
- `codesign --verify --deep --strict --verbose=2 .build/MakeAnIssue.app`
- Bundled `whisper-cli` transcribed `vendor/whisper.cpp-src/samples/jfk.wav`.
- `swift test` — 164 tests passed.

## Commits

- `8dcfb3d fix: sign release app bundle`
