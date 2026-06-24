# Phase 2: Push-to-Talk Voice Capture - Context

**Gathered:** 2026-06-24
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 2 delivers user-configurable global push-to-talk capture for the repo-bound menu-bar app. While the configured shortcut is held, the app records microphone audio; on release, it stops and writes one ASR-ready `16 kHz` mono WAV file for Phase 3 to consume.

This phase does not transcribe audio, invoke ASR/model CLIs, create GitHub issues, add a review screen, or add advanced recovery/retry behavior.

</domain>

<decisions>
## Implementation Decisions

### Shortcut Behavior
- **D-01:** Ship with a default global push-to-talk shortcut, while still allowing the user to change it.
- **D-02:** The default shortcut is `Control-Option-I`.
- **D-03:** Recording starts on the first key-down event and stops on key-up.
- **D-04:** Repeating key-down events while already recording are ignored.
- **D-05:** Use the `KeyboardShortcuts` package for global shortcut registration and user configuration, matching the project stack.

### Recording File Contract
- **D-06:** Write recordings under the app's Application Support directory, not inside the bound repository.
- **D-07:** Replace the prior recording instead of retaining a timestamped history.
- **D-08:** Phase 2 must write `16 kHz` mono WAV directly so Phase 3 can consume the file without conversion.
- **D-09:** The stable handoff path should be `Application Support/MakeAnIssue/latest.wav`.

### the agent's Discretion
No user decisions were delegated to the agent. Planning should preserve the decisions above and choose the simplest implementation that satisfies them.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Scope and Requirements
- `.planning/ROADMAP.md` — Defines Phase 2 goal, requirements, success criteria, and planned slices.
- `.planning/REQUIREMENTS.md` — Defines `CAPTURE-01`, `CAPTURE-02`, and `CAPTURE-03`; confirms Phase 2 stops at WAV capture.
- `.planning/PROJECT.md` — Captures v1 happy-path boundaries and project-level decisions, including push-to-talk over wake phrase and non-sandboxed native macOS app.
- `.planning/STATE.md` — Current project position and Phase 2 permission concerns.

### Existing App Integration
- `Package.swift` — SwiftPM manifest where `KeyboardShortcuts` and AVFoundation-facing app code will be integrated.
- `Sources/MakeAnIssue/MakeAnIssueApp.swift` — App entry point owns the shared `AppState` and menu-bar scene.
- `Sources/MakeAnIssue/AppState.swift` — Shared observable state where recording status and latest WAV path should be surfaced.
- `Sources/MakeAnIssue/MenuView.swift` — Existing menu UI where minimal idle/recording/finished feedback should appear.
- `Tests/MakeAnIssueTests/AppStateTests.swift` — Existing state tests to extend for recording state.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `AppState`: Existing `@MainActor ObservableObject` with `@Published` menu-facing state; use this for capture status and latest recording path.
- `MenuView`: Existing compact `MenuBarExtra` content; extend it minimally for recording status rather than adding a separate review or workflow UI.
- `scripts/build-app.sh`: Existing local app bundle build path for hands-on permission and menu-bar verification.

### Established Patterns
- Shared state is owned by `MakeAnIssueApp` and injected into menu UI via `.environmentObject`.
- Tests are focused Swift unit tests around state and small utilities.
- v1 favors narrow happy-path behavior with clear boundaries over generalized recovery systems.

### Integration Points
- Add the `KeyboardShortcuts` dependency to `Package.swift`.
- Register the push-to-talk shortcut from app lifecycle/state code so it works while other apps are focused.
- Add an audio recorder component that writes `Application Support/MakeAnIssue/latest.wav`.
- Surface recording state through `AppState` so `MenuView` can show idle/recording/finished status.

</code_context>

<specifics>
## Specific Ideas

- The default shortcut is `Control-Option-I`.
- The stable capture artifact is `Application Support/MakeAnIssue/latest.wav`.
- The recording contract is exactly `16 kHz` mono WAV.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 2-Push-to-Talk Voice Capture*
*Context gathered: 2026-06-24*
