# Phase 3: Local Transcription (bundled-whisper rework) - Pattern Map

**Mapped:** 2026-06-25
**Files analyzed:** 7 (5 modified, 1 new, 1 with deletions only)
**Analogs found:** 7 / 7

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `scripts/fetch-whisper.sh` | utility / build-script | file-I/O | `scripts/build-app.sh` | role-match (both are sh build scripts) |
| `scripts/build-app.sh` | utility / build-script | file-I/O | itself (extension) | self — add copy+sign steps |
| `Sources/MakeAnIssue/Transcriber.swift` | service | request-response | itself (rework) | self — drop prepare(), add resolver methods |
| `Sources/MakeAnIssue/AppState.swift` | store / orchestrator | event-driven | itself (rework) | self — remove asrCommandKey and old default closure |
| `Sources/MakeAnIssue/MenuView.swift` | component / view | request-response | itself (rework) | self — delete ASR VStack block |
| `Tests/MakeAnIssueTests/TranscriberTests.swift` | test | request-response | itself (rework) | self — delete all, add new bundled-binary tests |
| `Tests/MakeAnIssueTests/AppStateTests.swift` | test | event-driven | itself (rework) | self — delete emptyCommand test, add bundledResourcesMissing test |

---

## Pattern Assignments

### `scripts/fetch-whisper.sh` (new — utility, file-I/O)

**Analog:** `scripts/build-app.sh` (lines 1-9 — shebang + strict mode + path resolution)

**Shell header pattern** (`scripts/build-app.sh` lines 1-9):
```sh
#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
app_dir="$repo_root/.build/MakeAnIssue.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"

cd "$repo_root"
```

Adopt the identical header: `#!/bin/sh`, `set -eu`, and `CDPATH= cd` idiom for a POSIX-portable absolute `repo_root`. The new script diverges after that — it defines pinned constants and conditionally builds/downloads into `vendor/`.

**Full new-file pattern** (from RESEARCH.md §Pattern 1 — authoritative):
```sh
#!/bin/sh
set -eu

WHISPER_TAG="v1.9.1"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
MODEL_SHA256="<sha256-to-fill-in-on-first-download>"

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
VENDOR="$REPO_ROOT/vendor"
SRC="$VENDOR/whisper.cpp-src"

mkdir -p "$VENDOR"

if [ ! -f "$VENDOR/whisper-cli" ]; then
    git clone --depth 1 --branch "$WHISPER_TAG" \
        https://github.com/ggml-org/whisper.cpp "$SRC"
    cmake -B "$SRC/build" -S "$SRC" \
        -DCMAKE_BUILD_TYPE=Release \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_EXAMPLES=ON
    cmake --build "$SRC/build" -j --config Release
    cp "$SRC/build/bin/whisper-cli" "$VENDOR/whisper-cli"
    xattr -cr "$VENDOR/whisper-cli"
    echo "whisper-cli built at $WHISPER_TAG"
fi

if [ ! -f "$VENDOR/ggml-small.en.bin" ]; then
    curl -L -o "$VENDOR/ggml-small.en.bin" "$MODEL_URL"
    echo "Verifying model SHA256..."
    echo "$MODEL_SHA256  $VENDOR/ggml-small.en.bin" | shasum -a 256 -c
    echo "ggml-small.en.bin downloaded and verified"
fi
```

**Note:** `MODEL_SHA256` must be computed on first download: `shasum -a 256 vendor/ggml-small.en.bin`. Do NOT use the 40-char HuggingFace LFS hash (see RESEARCH.md §Pitfall 3).

---

### `scripts/build-app.sh` (modify — utility, file-I/O)

**Analog:** itself — extend after the existing `cp Info.plist` line.

**Existing pattern to preserve** (`scripts/build-app.sh` lines 1-18 — keep verbatim):
```sh
#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
app_dir="$repo_root/.build/MakeAnIssue.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"

cd "$repo_root"

swift build

rm -rf "$app_dir"
mkdir -p "$macos_dir"

cp "$repo_root/.build/debug/MakeAnIssue" "$macos_dir/MakeAnIssue"
cp "$repo_root/Resources/Info.plist" "$contents_dir/Info.plist"
```

**New block to append** (from RESEARCH.md §Pattern 2):
```sh
resources_dir="$contents_dir/Resources"
mkdir -p "$resources_dir"

# Copy artifacts (must exist in vendor/ -- run fetch-whisper.sh first)
cp "$repo_root/vendor/whisper-cli" "$resources_dir/whisper-cli"
cp "$repo_root/vendor/ggml-small.en.bin" "$resources_dir/ggml-small.en.bin"
chmod +x "$resources_dir/whisper-cli"

# Ad-hoc sign whisper-cli BEFORE any .app-level signing (bottom-up order, D-04)
codesign --force -s - "$resources_dir/whisper-cli"
```

**Critical constraint:** Sign the inner binary (`whisper-cli`) first; signing the `.app` shell first would invalidate it. This is D-04 and RESEARCH.md §Pitfall 4 / §Pattern 2.

---

### `Sources/MakeAnIssue/Transcriber.swift` (rework — service, request-response)

**Analog:** itself — the `run` method structure survives; `prepare()` is dropped and replaced by resolver methods.

**What stays** (`Transcriber.swift` lines 61-79 — the CLIRunner invocation + result switch):
```swift
let result = await CLIRunner().run(command: substituted)

switch result {
case .timeout:
    throw TranscriberError.asrTimedOut

case .failed(let exitCode, let stderr):
    throw TranscriberError.asrFailed(exitCode: exitCode, stderr: stderr)

case .success(let stdout, _, _):
    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw TranscriberError.emptyTranscript
    }
    return trimmed
}
```
This switch is the core run pattern. Copy verbatim; only the command construction above it changes.

**POSIX single-quote escape pattern** (`Transcriber.swift` line 43 — copy for path escaping):
```swift
let escapedPath = wavURL.path.replacingOccurrences(of: "'", with: "'\\''")
```
Apply to all three paths (binary, model, wav) in the new `run(wavURL:)`.

**Reworked error enum** (replaces `TranscriberError` at `Transcriber.swift` lines 4-15):
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
Drop: `emptyCommand`, `missingWavToken`. Add: `bundledResourcesMissing(detail: String)`.

**New resolver methods** (from RESEARCH.md §Pattern 4 — copy exactly):
```swift
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
```

**New `run(wavURL:)` signature and command construction** (from RESEARCH.md §Code Examples):
```swift
static func run(wavURL: URL) async throws -> String {
    let binaryURL = try bundledBinaryURL()
    let modelURL  = try bundledModelURL()

    let escapedBin   = binaryURL.path.replacingOccurrences(of: "'", with: "'\\''")
    let escapedModel = modelURL.path.replacingOccurrences(of: "'", with: "'\\''")
    let escapedWav   = wavURL.path.replacingOccurrences(of: "'", with: "'\\''")

    // D-07: -nt suppresses timestamps; -l en matches .en model; -t 4 explicit default.
    let command = "'\(escapedBin)' -m '\(escapedModel)' -f '\(escapedWav)' -l en -nt -t 4"

    let result = await CLIRunner().run(command: command)
    // ... existing switch (see above)
}
```

---

### `Sources/MakeAnIssue/AppState.swift` (rework — store/orchestrator, event-driven)

**Analog:** itself — surgical removals and a one-line default closure replacement.

**Line to DELETE** (`AppState.swift` line 23):
```swift
static let asrCommandKey = "asrCommand"
```

**Default `onRunTranscription` closure to REPLACE** (`AppState.swift` lines 98-101):
```swift
// REMOVE:
onRunTranscription: { url in
    let cmd = UserDefaults.standard.string(forKey: AppState.asrCommandKey) ?? ""
    return try await Transcriber.run(command: cmd, wavURL: url)
},

// REPLACE WITH:
onRunTranscription: { url in
    try await Transcriber.run(wavURL: url)
},
```

**`message(for:)` switch to UPDATE** (`AppState.swift` lines 294-305 — remove two cases, add one):
```swift
// DELETE these two cases:
case .emptyCommand:
    return "Set your ASR command in the menu to transcribe"
case .missingWavToken:
    return "ASR command must include {wav} — add it where the audio path goes"

// ADD this case (before .asrFailed):
case .bundledResourcesMissing(let detail):
    return "Whisper not bundled — rebuild the app: \(detail)"
```

**`@MainActor` + Task/await mutation pattern to copy for any new error surface** (`AppState.swift` lines 217-232):
```swift
} catch let error as TranscriberError {
    let message = Self.message(for: error)
    await MainActor.run {
        self.transcriptError = message
        self.statusText = message
        self.captureState = .idle   // D-11: reset so next push-to-talk works
    }
}
```
This is the established pattern for routing async errors back to main-actor state — do not change it.

**Seam declaration to PRESERVE** (`AppState.swift` line 45):
```swift
private let onRunTranscription: (URL) async throws -> String
```
The closure type signature does not change; only the default value changes.

---

### `Sources/MakeAnIssue/MenuView.swift` (rework — component/view, request-response)

**Analog:** itself — delete the ASR Command VStack block and its `@AppStorage` property.

**`@AppStorage` line to DELETE** (`MenuView.swift` line 10):
```swift
@AppStorage(AppState.asrCommandKey) private var asrCommand: String = ""
```

**VStack block to DELETE** (`MenuView.swift` lines 76-83):
```swift
VStack(alignment: .leading, spacing: 4) {
    Text("ASR Command")
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.secondary)

    TextField("e.g. whisper {wav} --model base", text: $asrCommand)
        .textFieldStyle(.roundedBorder)
}
```

**What STAYS** (do not touch — these are the pattern for the remaining Settings UI):
- `@AppStorage(AppState.cliCommandKey) private var cliCommand: String = "claude"` (`MenuView.swift` line 11)
- CLI Command VStack block (`MenuView.swift` lines 85-92) — identical structure to the deleted ASR block; keep as-is
- `TranscriptCard` and `.transcribing` status in `ActionCard` (`MenuView.swift` lines 289-302) — unchanged
- `onReceive(UserDefaults.didChangeNotification)` listener (`MenuView.swift` line 113) — kept (drives shortcut text refresh)

---

### `Tests/MakeAnIssueTests/TranscriberTests.swift` (rework — test, request-response)

**Analog:** itself — DELETE all existing tests (they all test `prepare(command:wavURL:)` which is removed). Add new tests for the bundled-binary path.

**Test file header pattern to copy** (`TranscriberTests.swift` lines 1-6):
```swift
import XCTest
@testable import MakeAnIssue

final class TranscriberTests: XCTestCase {
```

**`XCTAssertThrowsError` error-cast pattern** (`TranscriberTests.swift` lines 12-15):
```swift
XCTAssertThrowsError(try Transcriber.prepare(command: "", wavURL: wavURL)) { error in
    XCTAssertEqual(error as? TranscriberError, .emptyCommand)
}
```
Adapt for new cases — cast to `TranscriberError` and match `.bundledResourcesMissing`.

**New tests to add** (per RESEARCH.md §Validation Architecture — Wave 0 gaps):

1. `testBundledBinaryURLThrowsWhenResourceURLNil` — verify `bundledBinaryURL()` throws `bundledResourcesMissing` when `Bundle.main.resourceURL` is nil. Note: `Bundle.main.resourceURL` cannot be directly stubbed in XCTest; test via a temporary directory path stub instead (create a temp dir without the `whisper-cli` file).

2. `testBundledModelURLThrowsWhenModelAbsent` — same pattern, temp dir without `ggml-small.en.bin`.

3. `testRunConstructsCorrectCommand` — create a fake echo-script named `whisper-cli` in a temp dir, write a stub model file, and verify the command constructed by `run(wavURL:)` contains `-nt`, `-l en`, `-t 4`, and the quoted paths. This requires making `bundledBinaryURL()` / `bundledModelURL()` injectable or using a test-only subpath — align with the seam design chosen in planning.

---

### `Tests/MakeAnIssueTests/AppStateTests.swift` (rework — test, event-driven)

**Analog:** itself — one test deleted, one test added. All other tests unchanged.

**Test to DELETE** (grep for `testEmptyCommandShowsError` — tests the removed `TranscriberError.emptyCommand`).

**Existing timeout test to copy as the new bundledResourcesMissing test** (pattern reference — `AppStateTests.swift`; look for `testTimeoutResetsState` or similar):
```swift
func testTimeoutResetsState() {
    // ...stub onRunTranscription to throw TranscriberError.asrTimedOut...
    // ...assert captureState == .idle and statusText contains timeout message...
}
```

**New test to add** (`testBundledResourcesMissingResetsStateAndSurfacesStatus`):
```swift
func testBundledResourcesMissingResetsStateAndSurfacesStatus() async {
    let state = AppState(
        onStartRecording: { true },
        onStopRecording: {},
        onRunTranscription: { _ in
            throw TranscriberError.bundledResourcesMissing(detail: "whisper-cli not found in bundle Resources")
        }
    )
    state.micPermissionGranted = true
    // drive the state machine through stopRecording -> beginTranscription
    state.startRecording()
    state.stopRecording()
    // await the Task completion
    await Task.yield()
    XCTAssertEqual(state.captureState, .idle)
    XCTAssertTrue(state.statusText.contains("rebuild the app"))
}
```
Use `await Task.yield()` (or a brief expectation) consistent with how existing async AppState tests drain the Task — match the pattern already in the test file.

---

## Shared Patterns

### POSIX single-quote path escaping
**Source:** `Sources/MakeAnIssue/Transcriber.swift` line 43
**Apply to:** `Transcriber.swift` (all three paths in the new `run(wavURL:)`)
```swift
let escapedPath = wavURL.path.replacingOccurrences(of: "'", with: "'\\''")
let quoted = "'\(escapedPath)'"
```

### `@MainActor` / Task callback — hop before mutating `@Published`
**Source:** `Sources/MakeAnIssue/AppState.swift` lines 207-232 (`beginTranscription` Task body)
**Apply to:** Any new error path added inside `beginTranscription`; the `bundledResourcesMissing` case goes through the existing `catch let error as TranscriberError` branch automatically — no new hop needed if the error type is correct.
```swift
await MainActor.run {
    self.transcriptError = message
    self.statusText = message
    self.captureState = .idle
}
```

### Injectable closure seam pattern
**Source:** `Sources/MakeAnIssue/AppState.swift` lines 45, 98-101 (property declaration + default value)
**Apply to:** All test files — inject stubs through `onRunTranscription`; never call `Transcriber.run(wavURL:)` directly from tests (RESEARCH.md §Pitfall 6).
```swift
// Property:
private let onRunTranscription: (URL) async throws -> String

// Default (production):
onRunTranscription: { url in
    try await Transcriber.run(wavURL: url)
}

// Stub (tests):
onRunTranscription: { _ in throw TranscriberError.bundledResourcesMissing(detail: "test") }
```

### Shell script `set -eu` + portable root resolution
**Source:** `scripts/build-app.sh` lines 2-4
**Apply to:** `scripts/fetch-whisper.sh` (new file)
```sh
set -eu
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
```

---

## No Analog Found

All files have direct analogs in the existing codebase. No file in this rework introduces a wholly new pattern category — the changes are modifications and deletions within established patterns.

---

## Metadata

**Analog search scope:** `Sources/MakeAnIssue/`, `Tests/MakeAnIssueTests/`, `scripts/`
**Files read:** `Transcriber.swift`, `AppState.swift`, `MenuView.swift`, `CLIRunner.swift`, `build-app.sh`, `TranscriberTests.swift`, `AppStateTests.swift` (partial)
**Pattern extraction date:** 2026-06-25
