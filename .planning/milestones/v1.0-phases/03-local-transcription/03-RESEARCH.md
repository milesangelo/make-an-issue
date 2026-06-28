# Phase 3: Local Transcription (bundled-whisper rework) - Research

**Researched:** 2026-06-25
**Domain:** whisper.cpp binary bundling, macOS arm64 cmake build, codesign ad-hoc, Bundle.main resource resolution, SwiftPM test seam
**Confidence:** HIGH (build/model/flag details confirmed via official repo and docs); MEDIUM (SHA256 — must be computed at first download)

> **Rework note:** This RESEARCH.md supersedes the original 03-RESEARCH.md (which covered the
> user-configured ASR CLI pipeline). The original pipeline shipped and passed UAT but is being
> replaced. Research focuses exclusively on the NEW unknowns introduced by the bundled-whisper
> rework.

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Bundle `ggml-small.en.bin` (~466 MB, English-only).
- **D-02:** English-only, no language configuration. The `.en` model enforces this.
- **D-03:** Fetch-at-build: `scripts/fetch-whisper.sh` builds/downloads into gitignored `vendor/`
  with pinned URLs + checksums; `build-app.sh` copies into `Contents/Resources`.
- **D-04:** Ad-hoc signing only (`codesign -s -`) for local dogfooding. Full Developer-ID +
  notarization DEFERRED.
- **D-05:** ROADMAP success criterion #3 amended — Phase 3 success is local dev machine only;
  distribution-grade signing is a future phase.
- **D-06:** Rewire `Transcriber` to bundled binary + model path; drop `{wav}` token.
- **D-07:** `whisper-cli` invoked so **stdout = clean transcript** (no timestamps). Trimmed
  plain text passed to Phase 4. stderr is diagnostics-only (CLIRunner already separates them).
- **D-08:** Remove ASR Command text field, `asrCommand` UserDefaults key, and
  `onRunTranscription` user-config surface from AppState/MenuView. Keep injectable test seam.
- **D-09:** Rework `TranscriberError`: drop `emptyCommand`, `missingWavToken`. Add
  `bundledResourcesMissing`. Keep `asrFailed`, `asrTimedOut`, `emptyTranscript`.
- **D-10:** `CLIRunner` stays generic — unchanged. `/bin/zsh -lc`, 120 s timeout.
- **D-11:** `.transcribing` state on `CaptureState`, async off main actor; transcript shown in
  MenuView and NSLog'd; failure resets state to `.idle` with a short reason.

### Claude's Discretion

- Exact `whisper-cli` invocation flags (as long as stdout = clean, trimmable transcript).
- Runtime bundle path resolution + test seam design for `swift test` / `swift run` environments.
- Build from source vs prebuilt download for `whisper-cli`.
- User-facing status/error string wording.

### Deferred Ideas (OUT OF SCOPE)

- Full Developer-ID signing + hardened-runtime + `notarytool` notarization.
- Multilingual transcription (non-English) or model switching.
- Download-model-on-first-launch delivery and progress/failure UX.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| TRANSCRIBE-01 | App transcribes the recorded WAV with a **bundled** `whisper.cpp` binary + bundled model — zero configuration, no user-supplied ASR command. | Sections: Binary Acquisition, Bundling, Runtime Path Resolution, Transcriber Rework |
| TRANSCRIBE-02 | Transcription output is captured as transcript text for the request. | Sections: whisper-cli Invocation Flags (stdout contract), Transcriber Rework |
</phase_requirements>

---

## Summary

Phase 3's rework replaces the user-configured ASR CLI pipeline with a **bundled `whisper-cli`
binary and a bundled `ggml-small.en.bin` model**, fetched at build time into a gitignored
`vendor/` directory and copied into `MakeAnIssue.app/Contents/Resources` by `build-app.sh`.
The existing `CLIRunner` and the broad shape of `Transcriber.run` survive unchanged; the
implementation changes are: (1) the command source shifts from a user-editable string to a
bundle-resolved path, (2) `Transcriber.prepare()` is replaced by `bundledBinaryURL()` /
`bundledModelURL()`, and (3) the ASR Command field and `asrCommand` UserDefaults key are
deleted from AppState/MenuView.

**The biggest new risk** is `whisper-cli` binary acquisition: no official macOS arm64 prebuilt
binary exists in the GitHub releases. Building from source via cmake is the recommended and
fully pinnable approach. The build takes approximately 2-5 minutes on Apple Silicon and
produces a binary with only macOS system framework dylib dependencies (Metal, Accelerate,
Foundation, libSystem) — no external Homebrew dylibs. [VERIFIED: github.com/ggml-org/whisper.cpp/releases]

**Primary recommendation:** Build `whisper-cli` from source at a pinned git tag inside
`scripts/fetch-whisper.sh`. Use `cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j`.
Invoke as `whisper-cli -m <model> -f <wav> -l en -nt -t 4` — this writes a clean
no-timestamp transcript to stdout. [CITED: github.com/ggml-org/whisper.cpp/blob/master/examples/cli/README.md]

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| STT transcription | Local subprocess (whisper-cli) | — | CPU/GPU-accelerated binary runs off-process; CLIRunner bridges to Swift |
| Binary + model delivery | Build script (`fetch-whisper.sh`) | `build-app.sh` | Artifacts fetched at build time, not at runtime or from git |
| Bundle resource resolution | `Transcriber` (Swift) | AppState seam | Bundle.main only valid in .app; injectable seam handles test environment |
| User-config removal | `AppState` / `MenuView` | — | Delete `asrCommand` key and text field; keep `cliCommand` (Phase 4) |
| Error surface | `Transcriber` to `AppState` | `MenuView` status | New `bundledResourcesMissing` error must reach the status banner |

---

## Standard Stack

### Core

| Library / Tool | Version | Purpose | Why Standard |
|----------------|---------|---------|--------------|
| whisper.cpp | v1.9.1 (pin) | STT binary (`whisper-cli`) | Official C++ Whisper port; Metal-accelerated on Apple Silicon |
| ggml-small.en.bin | locked by D-01 | English STT model | 466 MiB; accuracy/speed balance for English dictation |
| cmake | 3.x / 4.x (system) | Build whisper.cpp from source | Standard whisper.cpp build system |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `codesign` (Xcode CLT) | System | Ad-hoc sign bundled binary | Needed so macOS won't refuse to spawn an unsigned binary |
| `xattr` (BSD) | System | Strip quarantine from downloads | Downloaded files get `com.apple.quarantine`; must remove before use |
| `shasum` (BSD) | System | SHA256 checksum verification in fetch script | Pin model and binary integrity |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Build from source (cmake) | Homebrew `brew install whisper-cpp` | Homebrew is not pinnable to a version/checksum; breaks reproducibility |
| Build from source (cmake) | PyPI `whisper.cpp-cli` wheel | Requires Python/pip; adds a runtime dependency |
| `ggml-small.en.bin` (466 MiB) | `ggml-small.en-q5_1.bin` (181 MiB) | Quantized model is smaller but potentially less accurate; D-01 locks choice |

**Pinned constants for fetch-whisper.sh:**
```bash
WHISPER_TAG="v1.9.1"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
```

**Version verification performed:**
- whisper.cpp latest release: v1.9.1 (published June 19, 2026) [VERIFIED: api.github.com/repos/ggml-org/whisper.cpp/releases/latest]
- ggml-small.en.bin size: 466 MiB [VERIFIED: huggingface.co/ggerganov/whisper.cpp]
- No macOS arm64 prebuilt binary in v1.9.1 release assets — only Ubuntu arm64/x64, Windows, and XCFramework [VERIFIED: github.com/ggml-org/whisper.cpp/releases]

---

## Package Legitimacy Audit

No new Swift packages are installed. The only new external artifact is the `whisper-cli` binary
(C++ build from source) and the `ggml-small.en.bin` model (Hugging Face download). Neither
goes through `npm`, `pip`, or `cargo`.

| Artifact | Source | Age | Downloads | Source Repo | Verdict | Disposition |
|----------|--------|-----|-----------|-------------|---------|-------------|
| whisper.cpp (whisper-cli) | github.com/ggml-org/whisper.cpp | 4+ yrs | Active | ggml-org/whisper.cpp | OK | Approved |
| ggml-small.en.bin | huggingface.co/ggerganov/whisper.cpp | 3+ yrs | Active | ggml-org/whisper.cpp | OK | Approved |

**Packages removed due to SLOP verdict:** none
**Packages flagged as suspicious:** none

---

## Architecture Patterns

### System Architecture Diagram

```
[KeyDown PTT] -> AppState.startRecording()
                    |
                    v
            AudioRecorder -> latest.wav (16 kHz mono, Application Support)
                    |
             [KeyUp PTT] -> AppState.stopRecording()
                    |
                    v
         AppState.onRunTranscription(wavURL)   <- closure seam (tests inject stub here)
                    |
                    v  [real production path]
         Transcriber.run(wavURL:)
           +- bundledBinaryURL()  -> Contents/Resources/whisper-cli   <- Bundle.main
           +- bundledModelURL()   -> Contents/Resources/ggml-small.en.bin
           +- CLIRunner.run(command:) -> /bin/zsh -lc "'whisper-cli' -m '...' -f '...' -l en -nt -t 4"
                    |                          |
                    |                        [stdout]          [stderr]
                    |                     clean transcript    whisper.cpp progress/log noise
                    v
         transcript: String  -> AppState.transcript
                    |
                    v
         MenuView (TranscriptCard) + NSLog
```

### Recommended Project Structure

```
vendor/                   # gitignored — populated by fetch-whisper.sh
+-- whisper-cli           # compiled whisper.cpp CLI binary (arm64-apple-macosx)
+-- ggml-small.en.bin     # 466 MiB English-only ggml model

scripts/
+-- fetch-whisper.sh      # NEW: clone whisper.cpp at pinned tag, cmake build, download model
+-- build-app.sh          # EXTEND: copy vendor/ into Contents/Resources, ad-hoc sign whisper-cli

.build/MakeAnIssue.app/
+-- Contents/
    +-- MacOS/MakeAnIssue
    +-- Info.plist
    +-- Resources/
        +-- whisper-cli          # copied from vendor/ + ad-hoc signed
        +-- ggml-small.en.bin    # copied from vendor/

Sources/MakeAnIssue/
+-- Transcriber.swift    # REWORK: drop prepare(), add bundledBinaryURL/ModelURL(), rework errors
+-- AppState.swift       # REWORK: drop asrCommandKey, update default onRunTranscription, update message()
+-- MenuView.swift       # REWORK: delete ASR Command VStack block, delete @AppStorage asrCommand var
```

### Pattern 1: fetch-whisper.sh — Build from Source + Model Download

**What:** Shell script that clones whisper.cpp at a pinned tag, builds with cmake (Metal
enabled by default on Apple Silicon), downloads the model from Hugging Face, and verifies
checksums into `vendor/`.

**When to use:** Run manually before `build-app.sh` on a fresh checkout. `vendor/` is gitignored.

```bash
#!/bin/sh
set -eu

# Source: github.com/ggml-org/whisper.cpp build instructions
WHISPER_TAG="v1.9.1"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
# Replace with the actual SHA256 computed on first download (see Pitfall 3):
MODEL_SHA256="<sha256-to-fill-in-on-first-download>"

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
VENDOR="$REPO_ROOT/vendor"
SRC="$VENDOR/whisper.cpp-src"

mkdir -p "$VENDOR"

# --- build whisper-cli ---
if [ ! -f "$VENDOR/whisper-cli" ]; then
    git clone --depth 1 --branch "$WHISPER_TAG" \
        https://github.com/ggml-org/whisper.cpp "$SRC"
    cmake -B "$SRC/build" -S "$SRC" \
        -DCMAKE_BUILD_TYPE=Release \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_EXAMPLES=ON
    cmake --build "$SRC/build" -j --config Release
    cp "$SRC/build/bin/whisper-cli" "$VENDOR/whisper-cli"
    xattr -cr "$VENDOR/whisper-cli"           # strip quarantine if any
    echo "whisper-cli built at $WHISPER_TAG"
fi

# --- download model ---
if [ ! -f "$VENDOR/ggml-small.en.bin" ]; then
    curl -L -o "$VENDOR/ggml-small.en.bin" "$MODEL_URL"
    echo "Verifying model SHA256..."
    echo "$MODEL_SHA256  $VENDOR/ggml-small.en.bin" | shasum -a 256 -c
    echo "ggml-small.en.bin downloaded and verified"
fi
```

**Note on SHA256:** On the first successful download, compute
`shasum -a 256 vendor/ggml-small.en.bin` and pin the result as `MODEL_SHA256` in the script.
The HuggingFace file page shows a 40-character git LFS object ID, not a file-content SHA256 —
do NOT use it as the `shasum -a 256` check value. [ASSUMED: SHA256 value — must be computed at
first download and committed into the script]

### Pattern 2: build-app.sh Extension — Copy + Ad-hoc Sign

**What:** Extend the existing `build-app.sh` to add `Contents/Resources` and copy vendor
artifacts, then ad-hoc sign `whisper-cli`.

```sh
# Source: Apple codesign man page / developer.apple.com code signing docs
resources_dir="$contents_dir/Resources"
mkdir -p "$resources_dir"

# Copy artifacts (must exist in vendor/ -- run fetch-whisper.sh first)
cp "$repo_root/vendor/whisper-cli" "$resources_dir/whisper-cli"
cp "$repo_root/vendor/ggml-small.en.bin" "$resources_dir/ggml-small.en.bin"
chmod +x "$resources_dir/whisper-cli"

# Ad-hoc sign whisper-cli BEFORE signing the .app (bottom-up order)
codesign --force -s - "$resources_dir/whisper-cli"
```

**Signing order is critical:** Sign the inner binary first, then the outer `.app`. Signing
the `.app` first then the inner binary invalidates the outer signature. [CITED: developer.apple.com/library/archive/technotes/tn2206/_index.html]

### Pattern 3: whisper-cli Invocation (D-07 compliance)

**What:** The exact argv that produces clean, trimmable transcript on stdout with no timestamps.

**Recommended argv:**
```
whisper-cli -m /path/to/ggml-small.en.bin -f /path/to/latest.wav -l en -nt -t 4
```

**Flag breakdown:**

| Flag | Default | Purpose |
|------|---------|---------|
| `-m FNAME` | models/ggml-base.en.bin | Model path |
| `-f FNAME` | (required) | Input WAV file path |
| `-l en` | en | Language — forces English (matches .en model) |
| `-nt` / `--no-timestamps` | false | Omit `[00:00:00.000 --> ...]` from stdout |
| `-t 4` | 4 | Thread count (explicit; default is already 4) |

**What goes where:**
- `stdout`: The transcript text (trimmed by `Transcriber.run`). Without `-nt`, timestamps
  appear as `[00:00:00.000 --> 00:00:02.340]   text here`. With `-nt`, just `   text here`
  (still has leading whitespace — `trimmingCharacters(in: .whitespacesAndNewlines)` handles it).
- `stderr`: whisper.cpp loading messages, Metal initialization, per-segment timing. CLIRunner
  captures stderr separately and never merges it into stdout.

[CITED: huggingface.co/spaces/natasa365/whisper.cpp/blob/.../examples/cli/README.md]
[CITED: til.simonwillison.net/macos/whisper-cpp]

**Do NOT use `-otxt`** — that writes to a file and does not affect stdout. Without `-otxt`,
transcript goes to stdout (the default output path).

### Pattern 4: Runtime Bundle Path Resolution with Test Seam

**What:** Resolve the bundled binary and model path in `Transcriber`. Work correctly both in
the assembled `.app` (Bundle.main.resourceURL is valid) and in the test/dev runner (it is not).

**Design:** `Transcriber` gets static resolver methods that throw `bundledResourcesMissing`
when the resources are not found. The **primary test seam** remains the
`AppState.onRunTranscription` closure — unit tests inject a stub closure and never call
`Transcriber.run` at all. The bundle resolver exists only for the production default closure.

```swift
// Source: Apple developer docs — Bundle.main.resourceURL
extension Transcriber {

    static func bundledBinaryURL() throws -> URL {
        guard let base = Bundle.main.resourceURL else {
            throw TranscriberError.bundledResourcesMissing(detail: "Bundle.main.resourceURL is nil")
        }
        let url = base.appendingPathComponent("whisper-cli")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriberError.bundledResourcesMissing(detail: "whisper-cli not found in Resources")
        }
        return url
    }

    static func bundledModelURL() throws -> URL {
        guard let base = Bundle.main.resourceURL else {
            throw TranscriberError.bundledResourcesMissing(detail: "Bundle.main.resourceURL is nil")
        }
        let url = base.appendingPathComponent("ggml-small.en.bin")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriberError.bundledResourcesMissing(detail: "ggml-small.en.bin not found in Resources")
        }
        return url
    }
}
```

**The updated default closure in AppState.init:**
```swift
onRunTranscription: { url in
    try await Transcriber.run(wavURL: url)
}
```

`Transcriber.run(wavURL:)` calls `bundledBinaryURL()` and `bundledModelURL()` internally.
Unit tests never reach this code — they inject their own stub.

### Anti-Patterns to Avoid

- **Using `-otxt` to capture the transcript:** `-otxt` writes a file next to the WAV, not to
  stdout. Reading that file adds I/O complexity and a cleanup burden. Stdout is already captured
  by CLIRunner.
- **Storing whisper-cli or the model in git:** At 466 MiB the model would bloat the repo
  permanently. Use a gitignored `vendor/` and `fetch-whisper.sh`.
- **Building whisper.cpp with Homebrew dylib dependencies:** Building against Homebrew-installed
  BLAS libraries creates runtime dylib dependencies outside the bundle. Use the default cmake
  build which uses system Metal/Accelerate only.
- **Ad-hoc signing the .app before signing its contents:** Signing must be bottom-up. Sign
  `whisper-cli` first, then the `.app` if the `.app` itself is also signed.
- **Using Bundle.module instead of Bundle.main for executable resources:** `Bundle.module` is
  for SwiftPM declared resources. The bundled `whisper-cli` and model live in the
  hand-assembled `.app/Contents/Resources` which is resolved via `Bundle.main.resourceURL`.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Speech-to-text | Custom STT pipeline | `whisper-cli` (whisper.cpp) | whisper.cpp handles Metal acceleration, BLAS, beam search |
| Model inference | Custom ggml runner | `whisper-cli` binary | ggml inference is complex; hundreds of edge cases |
| Build pinning | Custom source fetch | `git clone --depth 1 --branch TAG` | Pinned depth-1 clone is reproducible and fast |
| Checksum verification | Custom hash comparison | `shasum -a 256 -c` pattern | POSIX-standard; available on all macOS |

**Key insight:** The entire complexity of neural inference, Metal dispatch, and audio
preprocessing is encapsulated in the compiled `whisper-cli` binary. The only Swift code
needed is path resolution and `CLIRunner` invocation.

---

## Runtime State Inventory

This is a **rework** phase that removes user-configured state.

| Category | Items Found | Action Required |
|----------|-------------|-----------------|
| Stored data | `UserDefaults` key `"asrCommand"` in `~/Library/Preferences/com.milesangelo.make-an-issue.plist` | Remove key from AppState; remove `@AppStorage` binding from MenuView. Old persisted value is harmlessly ignored once the reading code is deleted. No data migration needed. |
| Live service config | None | None |
| OS-registered state | None | None |
| Secrets/env vars | None — `asrCommand` was not a secret | None |
| Build artifacts | `vendor/` does not yet exist — created by `fetch-whisper.sh` | Run `scripts/fetch-whisper.sh` before first `build-app.sh` |

**UserDefaults scope after rework:** `"asrCommand"` key removed; `"cliCommand"` key (Phase 4,
AI CLI command, `@AppStorage` in MenuView) REMAINS. `UserDefaults` is not eliminated entirely.
The `MenuView.onReceive(UserDefaults.didChangeNotification)` listener also stays (it drives
shortcut text refresh, not ASR-specific).

---

## Common Pitfalls

### Pitfall 1: No macOS arm64 prebuilt binary in GitHub releases

**What goes wrong:** Developer looks at the releases page, finds no macOS binary, and tries to
use the Ubuntu arm64 tarball (ELF format — wrong) or the XCFramework (for embedding in Xcode
projects, not standalone execution).

**Why it happens:** The whisper.cpp GitHub CI does not build macOS arm64 CLI binaries. [VERIFIED: github.com/ggml-org/whisper.cpp/releases]

**How to avoid:** Build from source with cmake (Pattern 1). This is the official and only
reliable macOS arm64 path.

### Pitfall 2: whisper-cli default stdout includes timestamps

**What goes wrong:** Invoking `whisper-cli -m model -f wav` without `-nt` produces:
```
[00:00:00.000 --> 00:00:02.340]   Hello world, this is a test.
```
This string with timestamps would be passed verbatim to Phase 4's AI CLI prompt.

**Why it happens:** whisper.cpp prints timestamps by default when writing to stdout.

**How to avoid:** Always include `-nt`. `Transcriber.run(wavURL:)` must hardcode `-nt` in the
constructed command — it must not be user-configurable. [CITED: huggingface.co/spaces/natasa365/whisper.cpp/blob/.../examples/cli/README.md]

### Pitfall 3: SHA256 checksum confusion with HuggingFace git LFS hash

**What goes wrong:** Developer uses the 40-character hash shown on the HuggingFace file page
(e.g., `db8a495a91d927739e50b3fc1cc4c6b8f6c2d022`) as the `shasum -a 256 -c` check value.
This fails: 40 hex chars is a git LFS pointer hash (SHA1 format), not a SHA256 (64 chars).

**Why it happens:** HuggingFace displays a file's git LFS object identifier, not the
file-content SHA256.

**How to avoid:** On first successful download, run `shasum -a 256 vendor/ggml-small.en.bin`
to get the actual 64-character SHA256 of the file content. Pin this as `MODEL_SHA256` in the
script. [ASSUMED: SHA256 value — must be computed at first run]

### Pitfall 4: Quarantine on downloaded binary or model

**What goes wrong:** `curl`-downloaded files receive the `com.apple.quarantine` extended
attribute. When the app spawns `whisper-cli` via `Process`, Gatekeeper checks the quarantine
attribute. Even an ad-hoc signed binary can be blocked if quarantine is present.

**Why it happens:** macOS applies quarantine to files downloaded by network-aware processes.

**How to avoid:** After downloading in `fetch-whisper.sh`, run `xattr -cr vendor/` before
copying into the bundle. The binary built from source via cmake does NOT receive quarantine
(it is created by a local compile, not downloaded as a pre-built binary). [CITED: gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5]

### Pitfall 5: Ad-hoc signing only works on the build machine

**What goes wrong:** The assembled `.app` (with ad-hoc signed `whisper-cli`) is copied to a
colleague's machine. Gatekeeper kills `whisper-cli` before it runs.

**Why it happens:** Ad-hoc signatures (`codesign -s -`) are local-machine checksums. On
another machine they provide no trusted developer identity. [CITED: gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5]

**How to avoid:** D-04 explicitly defers distribution-grade signing. The current scope is solo
dogfooding on the developer's own machine. Full Developer-ID signing is a future phase.

**Warning signs:** If `whisper-cli` fails to launch on a different machine with an error like
"cannot be opened because the developer cannot be verified" — that is Gatekeeper blocking the
ad-hoc signed binary. Distribution-grade signing is required.

### Pitfall 6: Bundle.main.resourceURL in swift test / swift run

**What goes wrong:** `Transcriber.bundledBinaryURL()` is called from within `swift test`.
`Bundle.main.resourceURL` points to the XCTest runner's bundle, not
`MakeAnIssue.app/Contents/Resources`, so `bundledResourcesMissing` is thrown.

**Why it happens:** `swift test` runs test binaries outside any `.app` bundle.

**How to avoid:** Unit tests MUST NOT call `Transcriber.run(wavURL:)` directly. The
`AppState.onRunTranscription` closure seam is the test boundary — inject a stub. [ASSUMED: Bundle.main.resourceURL behavior in XCTest — consistent with Swift Forums thread on SwiftPM resource paths]

### Pitfall 7: whisper-cli linking against non-system dylibs

**What goes wrong:** If built in an environment where Homebrew BLAS (e.g., `openblas`) is
installed, cmake may auto-detect and link against it. The binary then has a hard dependency on
that non-system dylib.

**Why it happens:** cmake auto-detects available libraries.

**How to avoid:** Default `cmake -DCMAKE_BUILD_TYPE=Release` on a clean Apple Silicon Mac
produces a binary linking only against system frameworks. After building, verify:
`otool -L vendor/whisper-cli` — no `/opt/homebrew/` paths should appear. [ASSUMED: default cmake link behavior with no extra flags]

---

## Code Examples

### TranscriberError (reworked)

```swift
enum TranscriberError: Error, Equatable {
    /// The bundled whisper-cli binary or ggml model was not found in Contents/Resources (D-09).
    case bundledResourcesMissing(detail: String)
    /// The ASR process exited with a non-zero status.
    case asrFailed(exitCode: Int32, stderr: String)
    /// The ASR process did not finish within the 120s timeout.
    case asrTimedOut
    /// The ASR process exited 0 but produced no output after trimming (D-07).
    case emptyTranscript
}
```

**Removed:** `emptyCommand`, `missingWavToken`.

### Transcriber.run (reworked signature)

```swift
struct Transcriber {

    static func bundledBinaryURL() throws -> URL {
        guard let base = Bundle.main.resourceURL else {
            throw TranscriberError.bundledResourcesMissing(detail: "Bundle.main.resourceURL is nil")
        }
        let url = base.appendingPathComponent("whisper-cli")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriberError.bundledResourcesMissing(detail: "whisper-cli not found in bundle Resources")
        }
        return url
    }

    static func bundledModelURL() throws -> URL {
        guard let base = Bundle.main.resourceURL else {
            throw TranscriberError.bundledResourcesMissing(detail: "Bundle.main.resourceURL is nil")
        }
        let url = base.appendingPathComponent("ggml-small.en.bin")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriberError.bundledResourcesMissing(detail: "ggml-small.en.bin not found in bundle Resources")
        }
        return url
    }

    /// Run the bundled whisper-cli on `wavURL` and return the trimmed transcript.
    static func run(wavURL: URL) async throws -> String {
        let binaryURL = try bundledBinaryURL()
        let modelURL  = try bundledModelURL()

        // POSIX single-quote escape for all paths
        let escapedBin   = binaryURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedModel = modelURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedWav   = wavURL.path.replacingOccurrences(of: "'", with: "'\\''")

        // D-07: -nt suppresses timestamps; stdout = clean transcript.
        // -l en: English (matches .en model). -t 4: thread count (explicit default).
        let command = "'\(escapedBin)' -m '\(escapedModel)' -f '\(escapedWav)' -l en -nt -t 4"

        let result = await CLIRunner().run(command: command)

        switch result {
        case .timeout:
            throw TranscriberError.asrTimedOut
        case .failed(let exitCode, let stderr):
            throw TranscriberError.asrFailed(exitCode: exitCode, stderr: stderr)
        case .success(let stdout, _, _):
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw TranscriberError.emptyTranscript }
            return trimmed
        }
    }
}
```

### AppState changes

```swift
// REMOVE this constant:
static let asrCommandKey = "asrCommand"

// REMOVE this default closure body; REPLACE with:
onRunTranscription: { url in
    try await Transcriber.run(wavURL: url)
}

// UPDATE message(for:) — remove emptyCommand and missingWavToken cases; add bundledResourcesMissing:
case .bundledResourcesMissing(let detail):
    return "Whisper not bundled — rebuild the app: \(detail)"
```

### MenuView changes

```swift
// DELETE this @AppStorage property:
@AppStorage(AppState.asrCommandKey) private var asrCommand: String = ""

// DELETE this entire VStack block from the Settings disclosure group:
VStack(alignment: .leading, spacing: 4) {
    Text("ASR Command")
    TextField("e.g. whisper {wav} --model base", text: $asrCommand)
}
```

`@AppStorage(AppState.cliCommandKey) private var cliCommand` and its TextField STAY.

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| User-configured ASR command string | Bundled `whisper-cli` + bundled model, zero config | 2026-06-25 realignment | Removes user setup friction; TRANSCRIBE-01 no longer user-config-gated |
| `{wav}` placeholder substitution | Direct absolute path argument in Swift | This rework | `Transcriber.prepare()` is replaced by resolver methods |
| `emptyCommand` / `missingWavToken` TranscriberError cases | `bundledResourcesMissing(detail:)` | This rework | Validation shifts from user input to resource presence |

**Deprecated in this rework:**
- `Transcriber.prepare(command:wavURL:)`: removed entirely — all existing TranscriberTests test this method and must be deleted/replaced.
- `AppState.asrCommandKey`: deleted.
- `TranscriberError.emptyCommand`, `.missingWavToken`: deleted.
- `AppStateTests.testEmptyCommandShowsError`: must be deleted (tests removed error case).

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | SHA256 (64-char file-content hash) of `ggml-small.en.bin` — must be computed at first download | fetch-whisper.sh pattern | Checksum in script would be wrong; verification fails or is skipped |
| A2 | Default cmake build on macOS arm64 links only against system frameworks with no Homebrew dylib dependencies | Pitfall 7 | whisper-cli has unmet dylib dependencies; subprocess launch fails |
| A3 | `whisper-cli` with `-nt` flag writes transcript to stdout; stderr receives loading/model/progress output | Pitfall 2, Pattern 3 | Transcript might include timestamps or go to stderr; flag set needs adjustment |
| A4 | `Bundle.main.resourceURL` in `swift test` does not resolve to `MakeAnIssue.app/Contents/Resources` | Pitfall 6, Pattern 4 | If wrong, test seam design is overly defensive but still correct |

---

## Open Questions

1. **Exact SHA256 of `ggml-small.en.bin`**
   - What we know: URL and size (466 MiB) confirmed; 40-char HuggingFace LFS hash is NOT the value
   - What's unclear: The 64-character file-content SHA256 for `shasum -a 256 -c` verification
   - Recommendation: Compute `shasum -a 256 vendor/ggml-small.en.bin` on first successful
     download and pin the value in `fetch-whisper.sh`. This is a Wave 0 task in plan 03-03.

2. **whisper-cli dylib dependencies on this specific build machine**
   - What we know: system frameworks (Metal, Accelerate, libSystem) are sufficient on macOS 13+
   - What's unclear: Whether this machine's cmake build picks up any Homebrew libraries
   - Recommendation: Run `otool -L vendor/whisper-cli` after the first build and verify no
     `/opt/homebrew/` paths appear. If they do, unset `CMAKE_PREFIX_PATH` or use
     `-DCMAKE_IGNORE_PATH=/opt/homebrew`.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| swift | SwiftPM build | ✓ | Swift 6.3.2 (Apple) | — |
| cmake | `fetch-whisper.sh` build | ✓ | 4.3.4 (Homebrew) | — |
| git | `fetch-whisper.sh` clone | ✓ | system | — |
| curl | `fetch-whisper.sh` model download | ✓ | system | — |
| codesign | `build-app.sh` ad-hoc sign | ✓ | Xcode 26.5 / Xcode CLTs | — |
| xattr | `fetch-whisper.sh` quarantine strip | ✓ | system (BSD) | — |
| shasum | `fetch-whisper.sh` checksum verify | ✓ | system | — |

**Missing dependencies with no fallback:** None — all required tools are present on this machine.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | XCTest |
| Config file | `Package.swift` (no external config) |
| Quick run command | `swift test --filter MakeAnIssueTests.TranscriberTests` |
| Full suite command | `swift test` |
| Current suite | 112 tests, 0 failures (verified 2026-06-25) |

### Automated vs Manual Boundary

The real `whisper-cli` + ~466 MB model MUST NOT run in unit tests. The automatable boundary
is `AppState.onRunTranscription`: unit tests inject a stub closure; only the production default
closure calls `Transcriber.run(wavURL:)`. All state-machine tests remain fully automated.
The bundled binary invocation is verified manually via the assembled `.app`.

### Phase Requirements to Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| TRANSCRIBE-01 | Bundled whisper-cli invoked, no user command | Manual (assembled .app smoke) | n/a — real binary, ~466 MB model | Manual only |
| TRANSCRIBE-01 | `bundledResourcesMissing` error when binary absent | Unit | `swift test --filter TranscriberTests` | Wave 0 |
| TRANSCRIBE-01 | `Transcriber.run(wavURL:)` constructs correct command string | Unit (capture via CLIRunner stub or process observation) | `swift test --filter TranscriberTests` | Wave 0 (replaces old prepare() tests) |
| TRANSCRIBE-01 | AppState enters `.transcribing` after stopRecording | Unit (existing) | `swift test --filter AppStateTests/testStopRecordingTransitionsToTranscribing` | Exists |
| TRANSCRIBE-01 | Old `emptyCommand` / `missingWavToken` tests REMOVED | Compilation guard | `swift test` fails if old error cases remain in tests | Delete in Wave 0 |
| TRANSCRIBE-02 | Successful transcription stores transcript text | Unit (existing) | `swift test --filter AppStateTests/testSuccessfulTranscriptionStoresText` | Exists |
| TRANSCRIBE-02 | Failure (bundledResourcesMissing) resets state to .idle | Unit | `swift test --filter AppStateTests` | Wave 0 |
| TRANSCRIBE-02 | Timeout error resets state | Unit (existing) | `swift test --filter AppStateTests/testTimeoutResetsState` | Exists |

### Sampling Rate

- **Per task commit:** `swift test` (112+ tests, ~7 s — fast enough for every commit)
- **Per wave merge:** `swift test` (full suite)
- **Phase gate:** Full suite green PLUS manual smoke test via assembled `.app`

### Wave 0 Gaps

- [ ] `Tests/MakeAnIssueTests/TranscriberTests.swift` — DELETE all existing tests (they test
  `prepare(command:wavURL:)` which is removed). ADD new tests:
  - `testBundledBinaryURLThrowsWhenResourcesNil` — mock `Bundle.main.resourceURL` nil condition
  - `testBundledModelURLThrowsWhenModelAbsent`
  - `testRunConstructsCorrectCommand` — use temporary directory to create a fake whisper-cli
    echo script and verify the command built by `run(wavURL:)` contains expected flags
- [ ] `Tests/MakeAnIssueTests/AppStateTests.swift` — DELETE `testEmptyCommandShowsError` (tests
  removed `TranscriberError.emptyCommand`). ADD:
  - `testBundledResourcesMissingResetsStateAndSurfacesStatus` (mirrors `testTimeoutResetsState`)

---

## Security Domain

`security_enforcement` is enabled (absent = enabled per config.json). `security_asvs_level: 1`.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | — |
| V3 Session Management | No | — |
| V4 Access Control | No | — |
| V5 Input Validation | Yes — WAV path passed to shell command | POSIX single-quote escaping (carried forward from original Transcriber.prepare pattern) |
| V6 Cryptography | No (SHA256 is integrity, not crypto) | `shasum -a 256 -c` for model/binary integrity at fetch time |
| V10 Malicious Code / Supply Chain | Yes — bundled binary from external source | Pinned git tag (`v1.9.1`) + SHA256 checksum verification in fetch-whisper.sh |

### Known Threat Patterns for this Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| WAV path with spaces or quotes injected into shell command | Tampering | POSIX single-quote escaping (already used in CLIRunner command construction) |
| Model or binary substituted after fetch (supply chain) | Tampering | SHA256 pinning in fetch-whisper.sh; `vendor/` must not be world-writable |
| Unsigned bundled binary blocked by Gatekeeper (local machine) | Denial of Service | Ad-hoc sign (`codesign -s -`); strip quarantine (`xattr -cr`) |

---

## Sources

### Primary (HIGH confidence)

- [github.com/ggml-org/whisper.cpp/releases](https://github.com/ggml-org/whisper.cpp/releases) — v1.9.1 latest; no macOS arm64 prebuilt binary
- [api.github.com/repos/ggml-org/whisper.cpp/releases/latest](https://api.github.com/repos/ggml-org/whisper.cpp/releases/latest) — programmatic asset list; confirmed no macOS binary assets
- [huggingface.co/ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) — ggml-small.en.bin = 466 MiB
- [github.com/ggml-org/whisper.cpp/blob/master/examples/cli/README.md](https://github.com/ggml-org/whisper.cpp/blob/master/examples/cli/README.md) — flag docs: `-nt`, `-l`, `-f`, `-m`, `-t`, `-np`
- [til.simonwillison.net/macos/whisper-cpp](https://til.simonwillison.net/macos/whisper-cpp) — `-nt` confirmed in help output

### Secondary (MEDIUM confidence)

- [gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5](https://gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5) — ad-hoc signing behavior; local-machine-only limitation; xattr + codesign workflow
- [github.com/ggml-org/whisper.cpp/issues/1811](https://github.com/ggml-org/whisper.cpp/issues/1811) — static linking impossible on macOS arm64; system frameworks remain dynamic

### Tertiary (LOW confidence / ASSUMED)

- cmake default link behavior on macOS arm64 — no Homebrew dylib deps with default flags [ASSUMED]
- SHA256 of `ggml-small.en.bin` — must be computed on first download [ASSUMED]
- Bundle.main.resourceURL behavior in swift test runner — consistent with Swift Forums reports [ASSUMED]

---

## Metadata

**Confidence breakdown:**
- Binary acquisition (cmake build from source): HIGH — confirmed no prebuilt macOS binary exists
- whisper-cli invocation flags: HIGH — confirmed via official CLI README and Simon Willison TIL
- Model URL and size: HIGH — confirmed via HuggingFace model page
- SHA256 for ggml-small.en.bin: LOW — must be computed at first download
- Ad-hoc codesign behavior: MEDIUM — confirmed via Apple developer forums and community docs
- dylib dependencies: MEDIUM — verify with `otool -L` after first build

**Research date:** 2026-06-25
**Valid until:** 2026-09-25 (whisper.cpp behavior documented here is stable across minor versions)
