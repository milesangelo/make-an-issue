# Phase 3: Local Transcription - Context

**Gathered:** 2026-06-24 · **Reworked:** 2026-06-25 (bundled-whisper rework)
**Status:** Ready for planning

> ⟳ **Reopened 2026-06-25.** The original pipeline (user-configured ASR CLI) shipped
> and passed UAT but is being **replaced** by a bundled `whisper.cpp` model — zero
> config, no user ASR command. The decisions below are for that rework (plans 03-03,
> 03-04). The original-pipeline decisions are preserved at the bottom under
> "Superseded — Original Pipeline" for history.

<domain>
## Phase Boundary

Phase 3 (reworked) transcribes the recorded WAV (`Application Support/MakeAnIssue/latest.wav`,
produced by Phase 2) into transcript text by invoking a **bundled `whisper.cpp` `whisper-cli`
binary with a bundled English model** — zero configuration, no user-supplied ASR command. It
delivers `TRANSCRIBE-01` (reworked: bundled whisper, not a user CLI) and `TRANSCRIBE-02`
(capture the output as transcript text). The transcript is surfaced in the menu/log for the
request.

The shared `CLIRunner` (`Process` wrapper, already shipped) is **kept generic** — it runs the
bundled binary here and is reused by Phase 4 (already shipped) to run the AI coding CLI.

This phase does NOT investigate the repo, draft an issue, invoke the AI CLI, file issues, add a
review screen, or add retry/queue recovery. Those belong to Phase 4 (already complete).

**This phase does NOT do full distribution-grade signing/notarization** — that is explicitly
deferred (see D-04). Success criterion #3 in ROADMAP is being amended accordingly.

</domain>

<decisions>
## Implementation Decisions (bundled-whisper rework)

### Model Choice
- **D-01:** Bundle the **`ggml-small.en.bin`** whisper.cpp model (~466 MB, **English-only**).
  Chosen over `large-v3-turbo-q5_0` (~574 MB, multilingual) and `base.en` (~142 MB). Rationale:
  good accuracy/speed balance for English dictation at a moderate footprint; the user only
  dictates in English, so the English-only model is faster and more accurate per byte than a
  multilingual model.

### Language Handling
- **D-02:** **English-only, no language configuration.** Forced by the `.en` model choice — there
  is no multilingual auto-detect path. If non-English dictation is ever needed, that requires
  switching to a multilingual model (e.g. `large-v3-turbo`) and is out of scope for this rework.

### Binary + Model Delivery
- **D-03:** **Fetch-at-build into the app bundle.** A `scripts/fetch-whisper.sh` builds or
  downloads `whisper-cli` and downloads `ggml-small.en.bin` into a **gitignored `vendor/`
  directory**, using **pinned URLs + checksums** for reproducibility. `scripts/build-app.sh` then
  copies the binary + model into `MakeAnIssue.app/Contents/Resources`. The model is **bundled in
  the .app** (no first-launch network download), but the ~466 MB artifacts are **kept out of git
  history**.

### Signing / Notarization Scope
- **D-04:** **Notarization is deferred to a later distribution phase.** For now (solo dogfooding),
  `build-app.sh` **ad-hoc signs** the bundled `whisper-cli` (`codesign -s -`) so it runs locally
  without Gatekeeper issues. Full Developer-ID signing + hardened-runtime + `notarytool` is NOT
  done in this phase.
- **D-05:** **ROADMAP success criterion #3 must be amended** — move "signed + hardened-runtime
  notarized; not Gatekeeper-blocked" out of Phase 3 and into the future distribution phase. Phase 3
  success is: bundled `whisper-cli` + model transcribes locally on the dev machine with no ASR
  command field and no PATH setup.

### Transcriber Rewire
- **D-06:** Rewire `Transcriber` to invoke the **bundled** binary + bundled model at a resolved
  bundle path, dropping the user ASR command and the user-facing `{wav}` token. The WAV absolute
  path is passed by the app directly (still shell-safe / quoted), not via a user placeholder.
- **D-07:** **Preserve the transcript contract for Phase 4:** the transcript is **trimmed plain
  text** (leading/trailing whitespace trimmed, otherwise verbatim). `whisper-cli` must be invoked
  so that **stdout is the clean transcript** (no timestamps) — see Claude's Discretion for flags.
- **D-08:** **Remove the user-config surface:** delete the **ASR Command text field** from
  `MenuView`, the `asrCommand` persisted setting, and the `onRunTranscription` user-config seam
  from `AppState`/`MenuView`. Keep an injectable seam for tests (so unit tests don't spawn the real
  binary), but it is no longer user-facing.
- **D-09:** **Rework `TranscriberError`:** drop `emptyCommand` and `missingWavToken` (obsolete with
  no user command). Add a clear error for **"bundled whisper-cli / model missing from the app
  bundle"**. Keep `asrFailed`, `asrTimedOut`, and `emptyTranscript`.

### Carried Forward (unchanged from original pipeline)
- **D-10:** `CLIRunner` stays generic — `/bin/zsh -lc`, separate stdout/stderr + exit capture,
  **120 s timeout**. Phase 4 reuses it; do not specialize it for whisper.
- **D-11:** `.transcribing` state on `CaptureState`, run **async off the main actor**, transcript
  shown in `MenuView` (selectable block) **and** `NSLog`'d; on failure show a clear short reason +
  tail of stderr and **reset state** so a new push-to-talk works.

### Claude's Discretion
- Exact `whisper-cli` invocation flags to satisfy D-07 — e.g. `--no-timestamps`, `-l en`, output to
  stdout vs `-otxt`, thread count — as long as stdout yields a clean, trimmable transcript.
- **Runtime path resolution** for the bundled binary + model, with a test seam: `Bundle.main`
  resourcePath works for the assembled `.app`, but **dev/`swift run` builds have no `.app`
  bundle** — design resolution (and the injectable path) so unit tests and dev runs work without
  the real bundle.
- Whether `fetch-whisper.sh` **builds `whisper.cpp` from source** (cmake) or downloads a prebuilt
  binary — pick whichever is reproducible and pinned; this is an implementation detail.
- Exact wording of user-facing status/error strings, as long as they convey the decided meanings.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Scope, Requirements & the Realignment
- `.planning/ROADMAP.md` §"Phase 3: Local Transcription" — reworked goal, `TRANSCRIBE-01/02`,
  success criteria (note #3 is being amended per D-05), and the Wave 3 plans (03-03 vendor +
  sign/notarize; 03-04 rewire Transcriber, remove ASR field).
- `.planning/notes/v1-realign-bundled-whisper-ai-cli-mcp.md` — **the authoritative rework
  rationale.** Fork 1 = bundle whisper, fully remove user ASR config; model-choice flagged as a
  planning decision; signing/notarization commitment; what survives (`CLIRunner`/`Transcriber`).
- `.planning/REQUIREMENTS.md` — `TRANSCRIBE-01` (reworked to bundled whisper), `TRANSCRIBE-02`.
- `.planning/PROJECT.md` — v1 happy-path boundaries; "bundled whisper model (zero setup)";
  non-sandboxed build; "basic clear errors only"; Key Decisions table (bundle whisper.cpp + model).

### Upstream Phase Context
- `.planning/phases/02-push-to-talk-voice-capture/02-CONTEXT.md` — WAV handoff contract
  (`Application Support/MakeAnIssue/latest.wav`, 16 kHz mono) that this phase consumes.

### Existing App Integration
- `Sources/MakeAnIssue/Transcriber.swift` — current implementation to rewire (drop user command /
  `{wav}` token; invoke bundled binary + model; rework `TranscriberError`).
- `Sources/MakeAnIssue/CLIRunner.swift` — shared `Process` wrapper; keep generic (D-10).
- `Sources/MakeAnIssue/AppState.swift` — `.transcribing` state, transcript storage, the injectable
  transcriber seam; remove `onRunTranscription` user-config surface (D-08).
- `Sources/MakeAnIssue/MenuView.swift` — remove the ASR Command field; keep the transcript display
  / "Transcribing…" status.
- `Sources/MakeAnIssue/AudioRecorder.swift` — source of the WAV absolute path to feed the binary.
- `scripts/build-app.sh` — assembles `.app` from the SwiftPM build; extend to copy `whisper-cli` +
  model into `Contents/Resources` and ad-hoc sign (D-03/D-04).
- `Resources/Info.plist` — bundle metadata (`LSUIElement`, mic usage string); the `.app` skeleton.
- `Package.swift` — SwiftPM manifest; no new Swift dependency expected (Foundation `Process`).
- `Tests/MakeAnIssueTests/TranscriberTests.swift`, `AppStateTests.swift`, `CLIRunnerTests.swift` —
  existing tests to update for the bundled-binary rework.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `CLIRunner` already ships (`/bin/zsh -lc`, separate stdout/stderr + exit, 120 s timeout) — the
  bundled binary runs through it unchanged.
- `Transcriber.run`'s structure (run via `CLIRunner`, trim stdout, map result → transcript/error)
  largely survives — only the command-source and validation change.
- `AppState` closure-seam pattern (inject transcriber for tests) — keep the test seam, remove the
  user-facing `onRunTranscription` config knob.
- `MenuView` selectable transcript block (`LabeledContent` + `.textSelection(.enabled)`) and the
  `.transcribing` status — keep; only the ASR Command text field is removed.

### Established Patterns
- `@MainActor`-isolated state; background callbacks hop to the main actor before mutating
  `@Published`. The async whisper run must do the same.
- `UserDefaults` was introduced solely for `asrCommand` (original pipeline) — removing the ASR
  field may remove the app's only `UserDefaults` use; verify before deleting.
- The app builds via **SwiftPM** (`swift build`) and is hand-assembled into a `.app` by
  `scripts/build-app.sh` — there is **no Xcode project**, so resource bundling + signing happen in
  that script, not via Xcode build settings.

### Integration Points
- New `scripts/fetch-whisper.sh` → gitignored `vendor/` (binary + model, pinned + checksummed).
- `scripts/build-app.sh` → copy `vendor/` artifacts into `Contents/Resources` + ad-hoc sign.
- `Transcriber` → resolve bundled binary + model path (with test seam), invoke via `CLIRunner`,
  return trimmed stdout.
- `AppState`/`MenuView` → drive `.transcribing`, display transcript, surface failures; ASR field
  and `asrCommand` removed.

</code_context>

<specifics>
## Specific Ideas

- Bundled model file: `ggml-small.en.bin` (~466 MB, English-only).
- Artifacts live in a **gitignored `vendor/`** dir, fetched via pinned URLs + checksums; copied into
  `MakeAnIssue.app/Contents/Resources` at build time. **Never committed to git.**
- Local signing is **ad-hoc** (`codesign -s -`) for solo dogfooding; full notarization is deferred.
- Transcript contract for Phase 4 is unchanged: **trimmed plain text from stdout.**
- 120 s `CLIRunner` timeout retained.

</specifics>

<deferred>
## Deferred Ideas

- **Full distribution-grade signing + hardened-runtime notarization** of the bundled `whisper-cli`
  (Developer-ID, `notarytool`) — moved out of Phase 3 (D-04/D-05) into a future distribution/release
  phase. Required before shipping to enterprise teammates; not needed for solo dogfooding.
- **Multilingual transcription** (non-English dictation) — would require a multilingual model
  (e.g. `large-v3-turbo`) and language handling; out of scope for the English-only v1.
- **Download-model-on-first-launch** delivery (and its progress/failure UX) — considered and
  declined in favor of bundling, to stay within the v1 "basic clear errors only" boundary.

</deferred>

---

## Superseded — Original Pipeline (user-configured ASR CLI, 2026-06-24)

> Kept for history. These decisions shipped (plans 03-01, 03-02) and passed UAT, but are
> **replaced** by the bundled-whisper decisions above. The ASR Command field, `asrCommand`
> setting, `{wav}` token, and `onRunTranscription` config seam are being **removed**.

- ASR command configured via a `MenuView` text field, persisted in `UserDefaults`, run through
  `/bin/zsh -lc`; no default command; `{wav}` placeholder substituted with the quoted absolute WAV
  path; stdout = transcript (trimmed); stderr diagnostics-only; `.transcribing` state; 120 s
  `CLIRunner` timeout.

---

*Phase: 3-Local Transcription*
*Context gathered: 2026-06-24 · Reworked: 2026-06-25*
