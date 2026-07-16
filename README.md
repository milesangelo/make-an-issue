# make-an-issue

A native macOS menu-bar utility that turns a spoken thought into a GitHub issue for the
repository you're working in. Hold a global shortcut, describe the issue, and the app
transcribes your speech, hands the transcript to Claude Code, which investigates the repo,
drafts the issue through a GitHub MCP server, and speaks
"created issue #NUMBER" back to you.

No manually managed API tokens. No browser. No leaving the keyboard.

---

## How It Works

```
┌─────────────────┐      ┌─────────────────────┐
│  Launcher cmd   │─────▶│  Menu-bar app binds  │
│  (from repo)    │      │  to git repo root    │
└─────────────────┘      └────────┬────────────-┘
                                  │
┌─────────────────┐      ┌────────▼────────────-┐
│  Hold shortcut  │─────▶│  AudioRecorder       │
│  (push-to-talk) │      │  16kHz mono WAV      │
└─────────────────┘      └────────┬────────────-┘
                                  │
                         ┌────────▼────────────-┐
                         │  Bundled whisper.cpp  │
                         │  (speech → text)      │
                         └────────┬────────────-┘
                                  │
                         ┌────────▼────────────-┐
                         │  Claude Code + MCP   │
                         │  (draft & file issue) │
                         └────────┬────────────-┘
                                  │
                         ┌────────▼────────────-┐
                         │  🔊 "Created #42"    │
                         └──────────────────────┘
```

### Issue-to-PR worker

The foundational `make-an-issue-worker` CLI is governed by the
[product contract](docs/make-an-issue-worker-product-contract.md) and companion
[threat model](docs/make-an-issue-worker-threat-model.md).

---

## Prerequisites

Before building or running make-an-issue, ensure you have the following installed:

| Dependency | Version | Purpose | Install |
|---|---|---|---|
| **macOS** | 13.0+ (Ventura) | Minimum deployment target | — |
| **Xcode** | 15+ | Swift toolchain & `swift build` | [Mac App Store](https://apps.apple.com/app/xcode/id497799835) or `xcode-select --install` for CLI tools |
| **cmake** | 3.14+ | Builds vendored whisper.cpp | `brew install cmake` |
| **Docker** | Latest | Runs GitHub MCP server container | [Docker Desktop](https://www.docker.com/products/docker-desktop/) |
| **gh** | Latest | Provides GitHub auth token | `brew install gh` |
| **Claude Code** | — | Drafts and files issues via MCP | [Install Claude Code](https://code.claude.com/docs) |

> [!NOTE]
> The app does not persist a GitHub token. For each filing, it obtains a token with `gh auth token`
> (or uses `GITHUB_PERSONAL_ACCESS_TOKEN` when it is already in the app environment), writes a
> temporary MCP configuration, and starts `ghcr.io/github/github-mcp-server` through Docker.
> Authenticate `gh` and keep Docker running before filing an issue.

---

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/milesangelo/make-an-issue.git
cd make-an-issue
```

### 2. Fetch whisper.cpp + model

This script clones whisper.cpp, builds `whisper-cli`, vendors the shared libraries, and
downloads the `ggml-small.en` model (~466 MB). Artifacts land in `vendor/` (git-ignored).

```bash
./scripts/fetch-whisper.sh
```

> [!TIP]
> This step is **guarded** — if `vendor/whisper-cli` and the model already exist, it skips
> rebuilding. To force a clean rebuild, remove `vendor/` and re-run.

### 3. Build the app bundle

```bash
./scripts/build-app.sh
```

This runs `swift build -c release`, assembles the `.app` bundle at `.build/MakeAnIssue.app`,
stamps both bundle version fields (`CFBundleShortVersionString` and `CFBundleVersion`) from
`APP_VERSION` (defaulting to the version in `Resources/Info.plist`), copies the vendored
whisper-cli + model + dylibs into `Contents/Resources/`, rewrites the copied whisper binaries'
build-tree rpaths to `@loader_path`, and code-signs the nested whisper binaries before sealing
the outer app last. Signing uses `CODESIGN_IDENTITY`
(ad-hoc by default), and the build finishes by running `scripts/verify-app-signing.sh`, a strict
`codesign --verify --deep --strict` check of the sealed bundle.

For an assembled-artifact release smoke (no GUI launch and no network writes), run
`./scripts/smoke-app.sh` after `fetch-whisper.sh` and `build-app.sh`. It validates the sealed
bundle, executes bundled Whisper against the checked-in JFK fixture (`scripts/fixtures/jfk.wav`),
and drives the real issue-filing runner through a fake local Claude provider.

### 4. Authenticate your tools

```bash
# Authenticate gh (provides the GitHub token to the MCP server)
gh auth login

# Ensure Claude Code is available
claude --version

# Ensure Docker is running (for the GitHub MCP server container)
docker info
```

### 5. Launch from your repo

Navigate to any git repository where you want to file issues, then run:

```bash
/path/to/make-an-issue/bin/make-an-issue
```

The app appears in your menu bar (no Dock icon). It binds to the git repository resolved from
your current working directory. Launching again from a different repo *adds* it to the menu-bar
picker (rather than forgetting the previous one) and makes it the active target; switch between
known repos from the picker at any time.

> [!TIP]
> For convenience, symlink the launcher into a directory on your `PATH`:
> ```bash
> ln -s /path/to/make-an-issue/bin/make-an-issue /usr/local/bin/make-an-issue
> ```
> Then simply run `make-an-issue` from any repo.

---

## Usage

### Creating an Issue

1. **Launch** — Run `make-an-issue` from within your target git repository
2. **Hold** — Press and hold the push-to-talk shortcut (default: `⌃⌥I` / Control+Option+I)
3. **Speak** — Describe the issue naturally (e.g. *"The login page crashes when the password field is empty"*)
4. **Release** — Let go of the shortcut; the app:
   - Transcribes your speech using the bundled whisper model
   - Invokes Claude Code in the bound repo to draft and file the issue via MCP
   - Speaks "created issue #NUMBER" aloud

### Menu Bar UI

Click the **exclamationmark.bubble** (❗💬) icon in your menu bar to see:

- **Repository picker** — Lists every repo you've launched from, marks the active one, and lets you switch which repo the next dictation files against; the list and active selection persist across relaunches. Empty and single-repo states render as before.
- **Status badge** — Capture state (IDLE, RECORDING, ASR); filing jobs appear separately
- **Transcript** — The last transcription result (copyable)
- **Filing jobs** — Each in-flight or finished filing, with per-job Stop/dismiss controls

**Right-click** (or Control-click) the icon for a menu with **Settings…** (opens the Settings
window with Shortcut and Instructions tabs) and **Quit**.

---

## Configuration

### Push-to-Talk Shortcut

The default shortcut is **⌃⌥I** (Control + Option + I). To change it:

1. Right-click the menu-bar icon and choose **Settings…**
2. Select the **Shortcut** tab
3. Click the shortcut recorder and press your desired key combination

The shortcut is persisted across launches via UserDefaults.

### Drafting Instructions

The app currently uses Claude Code with the GitHub MCP server. There is no provider selector or
editable CLI-command field. A provider selector may be added later, but no alternate provider is
supported today.

To customize how Claude investigates and drafts issues:

1. Right-click the menu-bar icon and choose **Settings…**
2. Select the **Instructions** tab
3. Edit **Drafting Instructions**, or select **Reset to Default** to restore the shipped guidance

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `MAKE_AN_ISSUE_REQUEST_DIR` | `~/Library/Application Support/make-an-issue` | Directory for launch request JSON |
| `MAKE_AN_ISSUE_OPEN_COMMAND` | `/usr/bin/open` | Command to open the app bundle (must be an absolute path) |

---

## macOS Permissions

The app requests microphone access when recording. Its global shortcut uses Carbon hotkey
registration through KeyboardShortcuts, which does not require Accessibility or Input Monitoring
permission.

| Permission | Why | Where to Grant |
|---|---|---|
| **Microphone** | Records voice for push-to-talk | System Settings → Privacy & Security → Microphone |

> [!NOTE]
> The v1 build runs **non-sandboxed** (App Sandbox is disabled) because it needs to spawn
> external CLI processes (`claude`, `gh`, `docker`, whisper-cli). This is intentional for
> the development/happy-path release.

---

## Project Structure

```
make-an-issue/
├── Package.swift                          # SPM manifest (Swift 5.10+, macOS 13+)
├── Sources/MakeAnIssue/
│   ├── MakeAnIssueApp.swift               # @main — app entry (status item lives in AppDelegate)
│   ├── AppDelegate.swift                  # NSApplicationDelegate setup
│   ├── AppState.swift                     # Capture state (idle → recording → transcribing → idle) and filing jobs
│   ├── MenuView.swift                     # SwiftUI menu-bar popover UI
│   ├── SettingsView.swift                 # Settings window (shortcut + drafting instructions)
│   ├── FilingJob.swift                    # Per-recording filing job model (filing → done/failed/cancelled)
│   ├── JobRowStyle.swift                  # Per-state icon/color styling for jobs-list rows
│   ├── RepoBinding.swift                  # Git repo resolution from cwd
│   ├── AudioRecorder.swift                # AVAudioEngine mic → 16kHz mono WAV
│   ├── Transcriber.swift                  # Invokes bundled whisper-cli
│   ├── CLIRunner.swift                    # Foundation Process wrapper (stdout/stderr/exit)
│   ├── IssueFilingConfig.swift            # Claude Code + GitHub MCP configuration
│   ├── IssueFilingRunner.swift            # Orchestrates Claude Code → MCP → issue filed
│   ├── IssueResultParser.swift            # Parses issue URL/number from CLI stdout
│   ├── LaunchRequest.swift                # Launch request model
│   └── LaunchRequestStore.swift           # Reads launch-request.json from disk
├── Resources/
│   └── Info.plist                          # LSUIElement=true, NSMicrophoneUsageDescription
├── Tests/MakeAnIssueTests/                # Unit & integration tests
├── bin/
│   └── make-an-issue                      # Repo-local launcher shell script
├── scripts/
│   ├── build-app.sh                       # Builds .app bundle with vendored whisper
│   ├── fetch-whisper.sh                   # Clones, builds, and vendors whisper.cpp + model
│   ├── fixtures/                          # Smoke fixtures: fake-claude provider, jfk.wav audio
│   ├── smoke-app.sh                       # Assembled-artifact smoke of .build/MakeAnIssue.app
│   └── verify-app-signing.sh              # Strict codesign verification of the sealed bundle
├── docs/                                  # Worker product contract & threat model (design docs)
├── vendor/                                # (git-ignored) whisper-cli, dylibs, model
└── .planning/                             # Design docs, research, roadmap
```

---

## Development

### Building from Source

```bash
# 1. Resolve Swift Package Manager dependencies
swift package resolve

# 2. Build the executable (debug)
swift build

# 3. Run tests
swift test

# 4. Build the full .app bundle (includes whisper vendoring)
./scripts/fetch-whisper.sh   # first time only
./scripts/build-app.sh

# 5. Smoke-test the assembled bundle (no GUI launch, no network writes)
./scripts/smoke-app.sh
```

### Key Dependencies

| Dependency | Source | Purpose |
|---|---|---|
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | SPM | Global push-to-talk hotkey via Carbon events |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (v1.9.1) | Vendored at build time | Bundled speech-to-text (ggml-small.en model) |

### Architecture at a Glance

The app follows a **sequential pipeline** pattern:

1. **RepoBinding** — Resolves the git root from the launcher's working directory
2. **KeyboardShortcuts handlers** (in `AppState`) — `onKeyDown` starts recording, `onKeyUp` stops
3. **AudioRecorder** — Captures mic audio to a 16kHz mono WAV file
4. **Transcriber** — Runs bundled `whisper-cli` against the WAV
5. **IssueFilingRunner** — Invokes Claude Code with the transcript + repo context; it drafts and files the issue through a Docker-hosted GitHub MCP server
6. **IssueResultParser** — Extracts the issue number/URL from CLI stdout
7. **AppState.speak** — Speaks "created issue #N" via `AVSpeechSynthesizer`

Capture transitions flow through the central `AppState` observable:
`idle → recording → transcribing → idle`

After transcription, each issue filing runs as a separate job with its own `filing`, `done`,
`failed`, or `cancelled` state, so capture can return to idle while filings continue.

### Running the App in Development

```bash
# Build the app bundle
./scripts/build-app.sh

# Launch it bound to the current repo
./bin/make-an-issue
```

Or run the raw executable (without the .app bundle — useful for debugging, but no bundled
whisper resources):

```bash
swift run MakeAnIssue
```

---

## Troubleshooting

### "MakeAnIssue app bundle not found"

Run `./scripts/build-app.sh` to create the `.build/MakeAnIssue.app` bundle.

### "vendor/whisper-cli or vendor/ggml-small.en.bin not found"

Run `./scripts/fetch-whisper.sh` before `build-app.sh`. This builds whisper.cpp from source
and downloads the model.

### Push-to-talk shortcut doesn't fire in the background

- Try re-setting the shortcut in the Settings panel
- Check that another app or the system has not claimed the selected shortcut

### Microphone permission denied

- Grant **Microphone** access in System Settings → Privacy & Security → Microphone
- The app will show a status banner if mic permission is missing

### Claude Code times out or fails

- Ensure Docker is running (`docker info`)
- Verify `gh auth status` shows you're authenticated
- Check that `claude` is available on the app's `PATH` (GUI apps can inherit a minimal PATH)
- The default timeout is 300 seconds (5 minutes); complex repos may take longer

### Model download fails (SHA mismatch)

Delete the partial download and retry:
```bash
rm -f vendor/ggml-small.en.bin vendor/ggml-small.en.bin.partial
./scripts/fetch-whisper.sh
```

---

## License

*License TBD.*
