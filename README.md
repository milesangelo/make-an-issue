# make-an-issue

A native macOS menu-bar utility that turns a spoken thought into a GitHub issue for the
repository you're working in. Hold a global shortcut, describe the issue, and the app
transcribes your speech, hands the transcript to your AI coding CLI (e.g. `claude`), which
investigates the repo, drafts the issue, files it via its own MCP server — and speaks
"created issue #NUMBER" back to you.

No API tokens. No browser. No leaving the keyboard.

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
                         │  AI CLI + MCP        │
                         │  (draft & file issue) │
                         └────────┬────────────-┘
                                  │
                         ┌────────▼────────────-┐
                         │  🔊 "Created #42"    │
                         └──────────────────────┘
```

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
| **An AI coding CLI** | — | Drafts & files issues via MCP | e.g. [claude](https://docs.anthropic.com/en/docs/claude-cli) (validated), `codex` (experimental) |

> [!NOTE]
> The app itself holds **no API tokens**. It rides the AI CLI's existing MCP OAuth session for
> issue filing. You authenticate once through your AI CLI's normal setup flow.

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
whisper-cli + model + dylibs into `Contents/Resources/`, rewrites the rpath, and code-signs the
nested whisper binaries before sealing the outer app last. Signing uses `CODESIGN_IDENTITY`
(ad-hoc by default), and the build finishes by running `scripts/verify-app-signing.sh`, a strict
`codesign --verify --deep --strict` check of the sealed bundle.

### 4. Authenticate your tools

```bash
# Authenticate gh (needed to provide the GitHub token to the AI CLI's MCP server)
gh auth login

# Ensure your AI CLI is set up (e.g. claude)
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
   - Invokes your AI CLI in the bound repo to draft & file the issue via MCP
   - Speaks "created issue #NUMBER" aloud

### Menu Bar UI

Click the **exclamationmark.bubble** (❗💬) icon in your menu bar to see:

- **Repository picker** — Lists every repo you've launched from, marks the active one, and lets you switch which repo the next dictation files against; the list and active selection persist across relaunches. Empty and single-repo states render as before.
- **Status badge** — Current state (IDLE, RECORDING, ASR, FILING, DONE)
- **Transcript** — The last transcription result (copyable)
- **Settings** — Configure your push-to-talk shortcut and CLI command

---

## Configuration

### Push-to-Talk Shortcut

The default shortcut is **⌃⌥I** (Control + Option + I). To change it:

1. Click the menu-bar icon
2. Expand the **⚙ Settings** section
3. Click the shortcut recorder and press your desired key combination

The shortcut is persisted across launches via UserDefaults.

### AI CLI Command

The CLI command used for issue drafting and filing defaults to `claude`. To change it:

1. Open **⚙ Settings** in the menu-bar popover
2. Edit the **CLI Command** text field (e.g. `claude`, `codex`)

> [!IMPORTANT]
> Only `claude` with the GitHub MCP server is validated end-to-end in v1.
> `codex` support is experimental and blocked by an upstream issue with non-interactive MCP writes.

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `MAKE_AN_ISSUE_REQUEST_DIR` | `~/Library/Application Support/make-an-issue` | Directory for launch request JSON |
| `MAKE_AN_ISSUE_OPEN_COMMAND` | `/usr/bin/open` | Command to open the app bundle (must be an absolute path) |

---

## macOS Permissions

The app requires two system permissions on first launch. macOS will prompt you automatically:

| Permission | Why | Where to Grant |
|---|---|---|
| **Microphone** | Records voice for push-to-talk | System Settings → Privacy & Security → Microphone |
| **Accessibility / Input Monitoring** | Global keyboard shortcut while app is in background | System Settings → Privacy & Security → Accessibility (or Input Monitoring) |

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
│   ├── MakeAnIssueApp.swift               # @main — MenuBarExtra scene
│   ├── AppDelegate.swift                  # NSApplicationDelegate setup
│   ├── AppState.swift                     # Central state machine (idle → recording → ASR → filing → done)
│   ├── MenuView.swift                     # SwiftUI menu-bar popover UI
│   ├── RepoBinding.swift                  # Git repo resolution from cwd
│   ├── AudioRecorder.swift                # AVAudioEngine mic → 16kHz mono WAV
│   ├── Transcriber.swift                  # Invokes bundled whisper-cli
│   ├── CLIRunner.swift                    # Foundation Process wrapper (stdout/stderr/exit)
│   ├── IssueFilingConfig.swift            # Provider-agnostic config seam (claude+GitHub, etc.)
│   ├── IssueFilingRunner.swift            # Orchestrates AI CLI → MCP → issue filed
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
│   └── verify-app-signing.sh              # Strict codesign verification of the sealed bundle
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
```

### Key Dependencies

| Dependency | Source | Purpose |
|---|---|---|
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | SPM | Global push-to-talk hotkey via Carbon events |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (v1.9.1) | Vendored at build time | Bundled speech-to-text (ggml-small.en model) |

### Architecture at a Glance

The app follows a **sequential pipeline** pattern:

1. **RepoBinding** — Resolves the git root from the launcher's working directory
2. **HotkeyManager** — `onKeyDown` starts recording, `onKeyUp` stops
3. **AudioRecorder** — Captures mic audio to a 16kHz mono WAV file
4. **Transcriber** — Runs bundled `whisper-cli` against the WAV
5. **IssueFilingRunner** — Invokes the AI CLI with the transcript + repo context; the CLI drafts and files the issue via its own MCP server
6. **IssueResultParser** — Extracts the issue number/URL from CLI stdout
7. **SpeechOutput** — Speaks "created issue #N" via `AVSpeechSynthesizer`

State transitions flow through a central `AppState` observable:
`idle → recording → transcribing → finished → filing → idle`

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

- Grant **Accessibility** or **Input Monitoring** permission in System Settings
- Try re-setting the shortcut in the Settings panel

### Microphone permission denied

- Grant **Microphone** access in System Settings → Privacy & Security → Microphone
- The app will show a status banner if mic permission is missing

### AI CLI times out or fails

- Ensure Docker is running (`docker info`)
- Verify `gh auth status` shows you're authenticated
- Check that your AI CLI is on your `PATH` (GUI apps inherit a minimal PATH — configure the
  CLI command as an absolute path if needed)
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
