# Phase 3: Local Transcription - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-25 (bundled-whisper rework)
**Phase:** 03-local-transcription
**Areas discussed:** Model choice, Notarization scope, Binary + model delivery, Language handling

> Context: Phase 3 was reopened 2026-06-25 to replace the user-configured ASR CLI with a
> bundled `whisper.cpp` model. This log covers the rework discussion; the original-pipeline
> discussion is in git history / the superseded section of CONTEXT.md.

---

## Model Choice

| Option | Description | Selected |
|--------|-------------|----------|
| large-v3-turbo-q5_0 | ~574MB, multilingual, near-large-v3 accuracy at ~8x speed; best technical-vocab accuracy (Claude's recommendation) | |
| small.en | ~466MB, English-only; solid accuracy/speed balance | ✓ |
| base.en | ~142MB, English-only, fast, smallest; weaker on library/API names | |

**User's choice:** small.en
**Notes:** User chose the English-only model over the recommended multilingual turbo. This
locks transcription to English-only and resolves the Language area below.

---

## Notarization Scope

| Option | Description | Selected |
|--------|-------------|----------|
| Defer notarization; ad-hoc sign now | `codesign -s -` for local solo dogfooding; full Developer-ID + hardened-runtime + notarytool deferred to a distribution phase; amend success criterion #3 (Claude's recommendation) | ✓ |
| Full notarization now | Developer-ID signing + hardened-runtime + notarytool this phase; requires Apple Developer Program membership | |

**User's choice:** Defer notarization; ad-hoc sign now
**Notes:** Solo dogfooding, no distribution yet. ROADMAP success criterion #3 (signed +
notarized) is to be amended — notarization moves to a future distribution phase.

---

## Binary + Model Delivery

| Option | Description | Selected |
|--------|-------------|----------|
| Fetch-at-build into the bundle | `scripts/fetch-whisper.sh` → gitignored `vendor/` (pinned URLs + checksums); `build-app.sh` copies into `Contents/Resources` + ad-hoc signs; slim repo, model still bundled (Claude's recommendation) | ✓ |
| Commit artifacts via Git LFS | Check binary + model into the repo through Git LFS; offline, no fetch step, but bloats clones/CI | |
| Download model on first launch | Bundle only the binary; download model to Application Support on first run; slimmest, but adds first-launch download UX (out of v1 scope) | |

**User's choice:** Fetch-at-build into the bundle
**Notes:** Keeps the ~466MB artifacts out of git history while still bundling the model in the
`.app` (no first-run network).

---

## Language Handling

| Option | Description | Selected |
|--------|-------------|----------|
| English-only (forced by `.en` model) | No language config; faster/more accurate for English | ✓ (resolved by model choice) |
| Multilingual + auto-detect | Requires a multilingual model (e.g. large-v3-turbo) | |

**User's choice:** English-only — resolved automatically by selecting `small.en`.
**Notes:** Not separately deliberated; the `.en` model makes this English-only by construction.
Non-English dictation would require switching to a multilingual model (deferred).

---

## Claude's Discretion

- Exact `whisper-cli` flags (`--no-timestamps`, `-l en`, output target, threads) so stdout is a
  clean trimmable transcript.
- Runtime path resolution for the bundled binary + model, with a test seam (dev/`swift run` builds
  have no `.app` bundle).
- Whether `fetch-whisper.sh` builds whisper.cpp from source or downloads a prebuilt binary.
- Wording of user-facing status/error strings.

## Deferred Ideas

- Full distribution-grade signing + hardened-runtime notarization (future distribution phase).
- Multilingual transcription (would require a multilingual model).
- Download-model-on-first-launch delivery (considered, declined for v1 scope).
