# Swift Menubar Port TODO

This checklist tracks differences between the Swift menubar app in `macos-native`
and the Python menubar app in `src`. Work through the items in order; each item
is intended to be implemented, tested, and checked off independently.

## Correctness and reliability

- [x] **1. Settle stale `PostToolUse` activity to Done**
  - Implemented a fixed two-minute settling deadline for newly normalized,
    implicit local `PostToolUse` Working events. Effective state changes without
    rewriting the source event or requiring another hook.
  - Preserved newer events, explicit status fields and markers, pending
    permissions, recognized errors, other active sessions, and remote behavior.
  - Inferred Done lasts for the configured duration starting at the settling
    boundary, subject to the existing stale cutoff. Refreshes, offline replay,
    and restarts do not extend the deadline.
  - Older saved sessions lack explicit/implicit status provenance and retain
    their previous behavior until a new hook arrives. This remains a completion
    heuristic, not proof that an agent has finished.
  - Verified 18 focused regression tests in `PostToolUseSettlingTests.swift`,
    related state tests, and bundled-app checks covering timed menu-bar updates,
    active counts, history, and restart behavior. Details are documented in
    `macos-native/README.md` under Local completion fallback.
  - **Done:** a lone eligible `PostToolUse` changes from Working to Done after the
    settling interval and later becomes Idle.

- [ ] **2. Match Python tool-failure detection**
  - Extend native `PostToolUse` response parsing to detect `interrupted: true`,
    `success: false`, nonzero `exit_code`, and relevant string responses such as
    tracebacks or explicit nonzero exit codes.
  - Keep successful, missing, and unfamiliar response shapes classified as
    Working.
  - Add table-driven normalization tests for every supported failure shape.
  - **Done when:** the same tool responses produce Ask/Error in Swift and Python.

- [ ] **3. Filter known internal Codex helper sessions**
  - Port the Python filtering for Codex suggestion and safety/compliance helper
    prompts so background product activity is not displayed as a user agent.
  - Apply filtering before sessions are persisted or added to history.
  - Add positive and negative tests to avoid filtering ordinary user sessions.
  - **Done when:** known internal helpers are absent while similar normal Codex
    sessions remain visible.

- [ ] **4. Make Herdr shutdown completion explicit**
  - Change Herdr monitor/process/control-master shutdown APIs so callers can wait
    for owned SSH processes and control connections to finish, with a bounded
    deadline.
  - Include remote tests and authentication attempts in the same termination
    lifecycle.
  - Do not reply to AppKit's termination request until both Herdr and LED cleanup
    have completed or reached their documented deadlines.
  - Add lifecycle tests for normal cleanup, timeout, repeated termination
    requests, and cleanup errors.
  - **Done when:** quitting cannot leave an owned SSH child or control master
    running after the bounded cleanup period.

- [ ] **5. Retry transient native IPC reads**
  - Treat `EAGAIN` and `EWOULDBLOCK` as retryable until the existing IPC deadline
    rather than reporting an immediate read failure.
  - Preserve request and response size limits and avoid busy-spinning.
  - Add a socket test that delays the response long enough to exercise the retry.
  - Run the bundled Herdr lifecycle test repeatedly to confirm it is stable.
  - **Done when:** temporary read unavailability no longer causes
    `Could not read event: Resource temporarily unavailable`.

## Menubar feature parity

- [ ] **6. Add battery plug/unplug preview**
  - Add settings for enabling the preview and selecting its duration.
  - Detect transitions between external power and battery power.
  - Temporarily show the battery program on agent-mode devices, then restore the
    current agent state without replaying unrelated animations.
  - Add state-machine and bundled-app tests.
  - **Done when:** plugging or unplugging power shows the configured temporary
    battery display and restores the previous display reliably.

- [ ] **7. Match the Python battery LED program**
  - Render partial charge levels instead of rounding down to whole LEDs.
  - Use the Python low/mid/high battery color ranges.
  - Use the charging color and charge-speed-dependent pulse duration.
  - Add a configurable or automatically selected full-charge wattage baseline.
  - Add fixture tests comparing representative Swift and Python output semantics
    for two-LED and eight-LED devices.
  - **Done when:** charge level, charging frontier, color, and charging speed are
    represented equivalently in both apps.

- [ ] **8. Add remembered and disconnected device management**
  - Display saved device preferences even while a device is disconnected.
  - Clearly distinguish connected, disconnected, enabled, and disabled devices.
  - Allow a user to remove a remembered device without affecting connected
    devices or unrelated preferences.
  - Add persistence and reconnect tests.
  - **Done when:** device configuration survives disconnects and stale entries
    can be removed from Settings.

- [ ] **9. Add editable lid open/close LED animations**
  - Add persisted programs and durations for lid-open and lid-closed animations.
  - Detect lid transitions without treating a closed lid as system sleep.
  - Provide preview, validation, reset-to-default, playback, and restoration of
    the live device display.
  - Keep this independent from the stronger closed-lid sleep override.
  - Add tests for cancellation, overlapping transitions, sleep, disconnect, and
    restoration.
  - **Done when:** configured animations play once on lid transitions and the
    current agent or battery display is restored afterward.

- [ ] **10. Add per-event audit history and CSV/HTML export**
  - Record the provider event, interpreted state, session identity, timestamp,
    and relevant decision metadata rather than only aggregate minute samples.
  - Bound and persist the audit log separately from the dashboard chart history.
  - Add CSV and HTML export actions with deterministic escaping and ordering.
  - Add serialization and export tests.
  - **Done when:** users can inspect and export the event-to-state decisions that
    produced the native display.

## Explicit scope decisions

These Python features were intentionally excluded from the initial native port.
Handle each as a separate product decision before implementation.

- [ ] **11. Decide whether to add provider-specific session resume actions**
  - Current native actions only open the workspace or a Terminal at the workspace.
  - Python supports Codex/Claude app links, Claude VS Code links, and provider CLI
    resume commands, with remembered provider/origin preferences and selectable
    terminal applications.
  - If accepted, split implementation into provider links, CLI resume commands,
    terminal selection, and remembered action preferences.
  - If rejected, document the permanent scope difference and check off this item.

- [ ] **12. Decide whether to add local transcript fallback**
  - Python can optionally recover Codex and Claude state from recent transcripts
    when hooks are missing or stale.
  - Native currently relies on hooks, except for the bounded Copilot Stop
    transcript-tail read.
  - If accepted, define strict file, byte, line, freshness, and privacy bounds
    before implementing provider readers.
  - If rejected, retain the documented hook-only design and check off this item.

- [ ] **13. Decide whether to add closed-lid system sleep override**
  - Native keep-awake currently uses a process-scoped idle-sleep assertion and
    intentionally does not override closed-lid sleep.
  - Python can use an installed privileged helper to toggle the stronger system
    setting.
  - If accepted, design installation, authorization, rollback, crash recovery,
    and uninstall behavior before implementation.
  - If rejected, retain the safer process-scoped policy and check off this item.

- [ ] **14. Decide whether to add the full custom-program simulator**
  - Native currently validates custom programs and provides an agent-state screen
    strip, but does not simulate arbitrary firmware/WASM programs.
  - If accepted, define the supported firmware syntax and rendering contract
    before adding the simulator.
  - If rejected, keep the existing validation-only behavior and check off this
    item.
