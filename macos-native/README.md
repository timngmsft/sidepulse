# SidePulse Native for macOS

A standalone Swift/AppKit and SwiftUI application, developed independently of the existing Python implementation. Native source and build output stay in this folder; live application data uses its own native namespace.

The application owns monitoring, settings, history, and the UI. Its bundled `SidePulseHook` executable is a small, one-shot event transport used by agent hooks, not a separate service. Running the app requires neither Python, PyObjC, a Python environment, nor the existing `sidepulse` / `agent-monitor` CLI.

## Build and open

Requires macOS 13 or later and a Swift 6 toolchain. Full Xcode is required for the native test runner.

```sh
./macos-native/build.sh
./start-native.sh
```

The launcher starts the full native application by default and forwards optional application flags. Quit an already-running preview or restricted testing instance before switching modes.

The script builds for the current Mac's architecture and signs the bundle locally. It uses `/Applications/Xcode.app` when available, without changing the system's selected developer directory. Set `DEVELOPER_DIR` to override that selection. No packages are downloaded.

The generated `.app` is self-contained and can be copied elsewhere. Put it in its intended location before installing native agent hooks, because those hooks reference the helper inside that app bundle. If the app moves later, use **Update** in Agent Hooks to refresh the paths.

For Developer ID signing, supply `SIGN_IDENTITY` to `build.sh`. The default ad-hoc signature is for local use; public distribution additionally requires appropriate signing and notarization.

## Release build

For an optimized native app and a versioned archive, run:

```sh
./macos-native/build-release.sh
```

This uses the existing native build and bundle assembly, forces Release mode
even if `CONFIGURATION=debug` is set, and runs the native tests against a
relocated copy of the app before packaging. Full Xcode is required. The app
and its bundled hook helper target the current Mac's architecture, not a
universal Intel/Apple Silicon binary. No Python environment is needed.

The outputs are in `macos-native/dist/`:

- `SidePulse Native.app` -- the standalone application.
- `SidePulse-Native-<version>-<build>-<architecture>.zip` -- the app bundle,
  archived with macOS metadata preserved.
- The matching `.zip.sha256` file -- verify it from that directory with
  `shasum -a 256 -c <archive>.zip.sha256`.

Set `CFBundleShortVersionString` and `CFBundleVersion` in
`macos-native/Resources/Info.plist` before building a new release. Rebuilding
the same version, build, and architecture replaces its ZIP and checksum only
after the build, tests, and archive creation succeed. The script does not
install the app, enable login startup, or change real agent hooks. Copy the
app to its final location before installing or updating hooks.

The default ad-hoc signature is suitable for this Mac. To use an existing
Developer ID Application identity instead:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./macos-native/build-release.sh
```

Signing alone does not make this a notarized public release. The script does
not upload anything to Apple; public distribution still requires
[notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
`DEVELOPER_DIR` has the same behavior as in `build.sh`; use `--help` for a
summary of the release command.

## Safe side-by-side preview

```sh
"macos-native/dist/SidePulse Native.app/Contents/MacOS/SidePulseNative" \
  --state-dir "$PWD/macos-native/.run" \
  --development --show-window
```

Development mode disables hook installation, remote connections, physical LED output, login registration, keep-awake assertions, and eject prevention. It does not alter or restart the existing SidePulse application. The normal application also starts with hardware output and power controls disabled, and never installs hooks automatically.

The development dashboard has **Idle / Working / Ask / Done** preview buttons, so the menu-bar experience can be explored without installing hooks or running diagnostic commands.

Quit the development instance before opening the app normally to set up real agent hooks.

Normal application data is stored separately in:

```text
~/Library/Application Support/SidePulse Native/
```

The bundle identifier is `io.sidepulse.native`. Its private event socket is `/tmp/io.sidepulse.native-<uid>/events.sock`; development instances with a short `--state-dir` use an `events.sock` inside that directory. Longer paths get a stable, separately namespaced socket under `/tmp`. The original application's files and socket are not reused.

## Copilot and Herdr live testing

The **Install** buttons are intentionally disabled in the simulated preview. Quit that instance, then start the restricted live-testing mode from the repository root:

```sh
./start-native.sh --copilot-testing --show-hooks
```

**GitHub Copilot > Install / Update / Remove** and **Remotes** are enabled in this mode. The other local providers, physical output, keep-awake, eject prevention, and login registration remain disabled. No hooks are installed automatically. The `--copilot-testing` launch flag is retained for compatibility.

Click **Install** and confirm the displayed path. This creates or updates only `~/.copilot/hooks/sidepulse-native.json` (or the equivalent under `COPILOT_HOME`). Existing Copilot hooks, including the original SidePulse installation, are preserved. Start a new Copilot CLI session afterward. The Agent Hooks page distinguishes an installed configuration from receiving actual events.

Without a `--state-dir` override, this mode uses the normal native data directory and socket. Those hook commands therefore keep working when the app is subsequently opened normally; they do not point into the temporary preview directory.

Copilot hooks use PascalCase event names to select VS Code-compatible input and pass their registered event name as a legacy-format fallback. Permission and question-dialog notifications produce **Ask**; background completion notifications do not end an active or waiting parent session. For a Stop event that lacks reply text, the native helper reads at most the final 256 KiB of the supplied transcript to find the latest assistant reply. This reply enrichment is on demand, separate from the cancellation observer below; neither uses an ML classifier.

The hook commands emit no permission decisions and remain non-blocking for Copilot even if the app bundle is moved, removed, or unavailable. Failures are reported to stderr; the running helper queues events when the receiver is offline.

## Hardware output

Quit the Python app or any other app controlling the same device, then launch the native app normally:

```sh
./start-native.sh --show-devices
```

In **Settings > Devices**, enable **physical LED output**. Mounted SidePulse Pro (eight LEDs) and SidePulse Dot / PulseDot (two LEDs) devices are detected automatically. Leave a device on **Agent** to mirror the aggregate state: cyan chasing pulses for Working, red-orange pulses for Ask, steady green for Done, and a dim Idle pulse. Per-device brightness, Battery mode, and Custom programs are also available. macOS may request access to removable volumes; allow access for the connected SidePulse.

LED writes, retries, and the once-per-minute device keepalive run on a background queue, not the UI thread. Writes update `LEDS.LED` in place. Unchanged states do not restart animations. Disconnecting cancels pending writes; reconnecting restores the configured display. Disabling a device or global output writes `off` once before releasing it. Sleep turns managed output off and pauses keepalives; wake restores it. Quitting drains final off commands asynchronously with a bounded shutdown deadline.

Hardware remains disabled in `--development` and `--copilot-testing` modes. Enabling physical output does not enable keep-awake, login registration, or eject prevention.

The read-only `snapshot` response includes `hardware` diagnostics: enabled/allowed flags, detected devices, desired programs, and write-attempt/completion counts. A macOS removable-volume consent dialog can pause the first file open without blocking the UI; grant access in that system dialog to let output proceed.

## Herdr remotes

Open **Settings > Remotes > Add Remote**. Enter an SSH alias or `user@host`, optionally a friendly name and Herdr session, then use **Test Connection** before saving. A blank session or `default` selects the default session. Named sessions accept letters, digits, `.`, `_`, and `-`.

Herdr must be installed and running on the remote Mac or Linux host. The app uses `/usr/bin/ssh` and your existing SSH configuration; there is no local Python dependency and no remote SidePulse component. It probes the platform and checks executable candidates from PATH, Homebrew, Cargo, local/mise/Nix installations, and a previously detected path. An absolute **Herdr executable** override takes precedence. A compatible error response, such as a stopped Herdr session, proves the executable is installed without falsely reporting a working session.

If SSH needs a password, key passphrase, or host-key confirmation, save and enable the remote, then select **Authenticate in Terminal**. Prompts remain in Terminal, not in SidePulse. The app resumes monitoring automatically after successful authentication. **Cancel Authentication**, disabling/removing the remote, and sleep cancel the attempt. Each attempt uses an independently owned, private SSH control socket; failed or unaccepted connections are closed.

Connected remotes show their platform, detected Herdr path, agent count, and last successful update. Failures distinguish SSH/authentication problems, missing or stopped Herdr, invalid overrides, unsupported platforms, and incompatible responses. **Reconnect** retries one remote without interrupting the others. Renaming a remote does not restart SSH. Native preferences are independent; existing Python remote settings are not imported or changed.

For a host on your local network, macOS may request Local Network access. If SSH works in Terminal but not in the app, check **System Settings > Privacy & Security > Local Network** for SidePulse Native.

Each enabled remote uses a persistent SSH polling connection with a two-second interval. Working and blocked agents become **Working** and **Ask** in the same aggregation as local sessions. Only an observed active-to-settled transition becomes **Done**; startup, reconnect, and wake do not invent completions. Completion duration follows the Activity setting. Remote state expires after 15 seconds without an authoritative snapshot, and remote sessions are never persisted as local sessions. Monitoring pauses during system sleep and resumes with a new baseline on wake.

Heartbeat freshness is kept separately from UI changes. Unchanged polls do not redraw the dashboard or unrelated Settings tabs, or reorder otherwise unchanged session rows. The Remotes tab still receives live connection details and last-update times; actual activity, metadata changes, and expiry continue to update the UI.

To open the tab when launching an already-built app that is not running:

```sh
open "macos-native/dist/SidePulse Native.app" --args --copilot-testing --show-remotes
```

## Features

- Five menu-bar LEDs: cyan LEDs chase for **Working**, red-orange LEDs breathe together for **Ask**, and green LEDs pulse once and settle for **Done**. **Idle** is dim and static.
- **General > Show status text** controls the label. Turn it off for a **36 pt LED-only item**: five 4 pt LEDs, four 3 pt gaps, and 2 pt padding at each edge, with no reserved text space. State remains available in the tooltip, accessibility label, and dashboard. Text is enabled by default for existing installations; both modes preserve their width across state changes.
- **General > Menu bar alignment** offers **Left / Center / Right** justification of the LEDs and label as one group. Changes apply immediately and persist across launches. **Center** is the default. Alignment is disabled but preserved in LED-only mode and restored when text is shown again. The labeled item uses the native menu-bar font and is sized to the widest label plus the five LEDs.
- Core Animation rather than a per-frame application timer. Animations respect Reduce Motion and pause when displays sleep.
- Native dashboard and settings, multi-agent priority, pending permission tracking, stale-activity expiry, session persistence, and recent history with JSON export.
- Separate **Active** and **Recent** session sections, with short session/agent IDs and last-activity times. Completed items use a green checkmark instead of a status dot. Ended sessions are labeled **Ended**, so independent sessions in the same workspace do not look like duplicate agents.
- Opt-in hook setup for Codex, Claude, GitHub Copilot, and Grok. Existing unrelated hooks are retained, and configuration files are backed up before changes.
- A bounded offline event queue, drained when the application starts or resumes receiving activity. Older events do not overwrite newer state.
- Optional SidePulse Pro / Dot LED output, per-device brightness, agent and battery patterns, and custom `LEDS.LED` programs. Programs are written in place and constrained to the firmware's 512-byte / 20-line limits.
- Optional native status strip beneath the menu bar/notch.
- IOKit battery information and process-scoped keep-awake policies, with a low-battery cutoff.
- Optional in-process prevention of ordinary SidePulse Pro unmount/eject requests.
- Optional Herdr remote monitoring over the macOS SSH client, with connection testing, compatible-binary discovery, bounded streams, reconnects, and cancellable Terminal authentication.
- Opt-in launch at login using `SMAppService`.

To receive real activity, open the app normally and explicitly install the desired provider's hooks from **Settings > Agent Hooks**. Restart that agent afterward. Codex may require approving the new hooks. Native installation preserves existing SidePulse hooks, so both apps can observe activity while comparing them. Keep only one app in control of a physical device.

## Empty dashboard

An empty session list shows **No recent agent activity** when at least one available provider has native hooks installed or any remote is configured, including disabled remotes. **Set Up Agent Hooks** appears only when every available provider has been checked and has no native hooks, and no remote is configured. Preview mode never offers hook setup; restricted live testing considers only Copilot's hooks.

Installation checks read native command entries in the provider's configuration (the managed block for Codex), respecting `COPILOT_HOME`. They refresh when the menu, dashboard, or Settings window opens and after installing or removing hooks. Unreadable files, invalid JSON hook structures, and incomplete Codex managed blocks are reported as unknown, not uninstalled: the dashboard stays neutral and Agent Hooks offers **Check Again**. These checks establish configuration presence, not whether the agent has restarted or successfully delivered an event.

## Local completion fallback

If a final `Stop` hook is missed, an implicit local `PostToolUse` Working state settles to **Done** after two minutes without a newer status event. This applies to Codex, Claude, GitHub Copilot, and Grok. A new tool start, prompt, question, or other status event supersedes the fallback; another successful tool completion starts a new settling interval. Explicit status fields or message markers, pending approvals, recognized errors, and remote Herdr activity are not auto-completed.

**General > Show completion for** counts from the fixed two-minute settling boundary, so even the one-minute option has a visible Done window. The existing stale-activity cutoff can end that window sooner. Unlike Python's event-age-based completion expiry, the native duration does not include the initial two-minute wait. Source event timestamps and modes are not rewritten, and polling, offline replay, or restarting the app does not restart either interval. The menu bar, session list, active count, history, and activity-based keep-awake decisions use the same effective state.

This is a missing-hook heuristic, not proof that an agent finished. An agent silently thinking for more than two minutes after a tool completion can therefore appear Done; an explicit Working status suppresses this inference until the next status event. Existing saved sessions lack the information needed to distinguish explicit Working from implicit Working, so they retain their previous expiry behavior until a new hook arrives. Newly received events persist their optional settling deadline for safe restarts.

## Copilot cancellation recovery

Normal and restricted live-testing modes also check the event logs of known local Copilot sessions on the one-second refresh cycle. An explicit root `abort` record changes only that session to **Idle**, labeled **Cancelled** in Recent; it does not produce a green Done indication. A `SessionEnd` hook with `reason: "abort"` has the same result. Late tool-result, error, or Stop cleanup hooks cannot revive a cancelled turn, whether they arrive before or after the cancellation is detected. A persisted activity timestamp distinguishes that cleanup from a genuinely newer prompt, tool start, or question; a root `assistant.turn_start` can also resume a cancelled session.

Each session ID has its own incremental log cursor, including when several instances use the same workspace. The bundled helper supplies the instance's event-log location using its own `COPILOT_HOME`; the path is persisted, so different configuration directories remain independent across app restarts. Older sessions without this metadata fall back to the app's Copilot configuration directory, and those without an activity timestamp conservatively use their last hook time until new activity establishes one. Subagent aborts never cancel the parent, and an older cancellation cannot overwrite newer activity or a newer question.

The menu bar, dashboard ordering, status strip, and agent LEDs retain the shared priority **Ask > Working > Done > Idle**:

| Instances | Aggregate display |
| --- | --- |
| Running + cancelled, idle, or completed | Working |
| Question/approval + running or cancelled | Ask |
| Completed + cancelled or idle | Done, until the completion duration expires |
| All cancelled or idle | Idle |

Reads run off the main thread, start with at most the last 256 KiB, and consume at most 256 KiB of new data per session per pass (plus a small cursor-integrity check). Partial records and backlogs must be caught up before a signal is applied; file replacement and truncation reset the cursor. A large backlog can take additional refreshes. Missing, unreadable, malformed, or oversized records are reported rather than interpreted as cancellation. Recovery depends on Copilot writing the structured lifecycle record; otherwise normal hooks and the existing stale timeout remain authoritative. This is not a general transcript-only monitoring fallback, and simulated preview does not read these logs.

## Scope and limitations

This is a separate native implementation, not a complete migration of every legacy feature:

- It does not import the original application's preferences, hooks, history, or installation state.
- Local activity requires native hooks. The legacy transcript-only polling fallback is not included. Copilot additionally observes explicit cancellation records for already-known local sessions, and its Stop hook can read the latest reply; other providers use reply text supplied by their hooks.
- Local session actions open the workspace or a terminal; provider-specific resume/deep-link behavior is not yet implemented.
- The native on-screen strip represents agent state, not a full firmware/WASM custom-program simulator.
- Keep-awake does not modify global power settings or override closed-lid sleep.
- Eject prevention lasts only while this app is running. There is no privileged helper, background guard daemon, or automatic remount retry.
- Custom LED programs receive size/line validation, not a complete firmware syntax check.
- Remote monitoring requires Herdr on the remote host and an existing SSH configuration. Physical hardware, real-host SSH authentication, login registration, and real agent-hook installation remain explicit, opt-in operations; the development exercises do not enable them.

## Development

```sh
./macos-native/test.sh
./macos-native/smoke-test.sh
```

Core XCTest coverage includes event normalization, question detection, aggregation, permissions, expiry, hook preservation, native IPC, offline events, and LED write scheduling. Copilot coverage includes restricted-mode policy, dialog notifications, bounded transcript reads, compatible hook payloads, and a missing-helper fail-open case. Herdr fixtures exercise strict protocol parsing, legacy and structured session references, remote-only agent types, discovery, stable completion timestamps, reconnect baselines, grace expiry, executable replacement, bounded stdout/stderr, cancellation under continuous output, and authentication acknowledgement/failure/cancellation.

Post-tool settling coverage checks the exact two-minute boundary, all completion-duration choices, explicit fields and message markers, pending permissions, new and delayed events, aggregation, stale expiry, and persistence compatibility. The bundled app also exercises Working / Done / Idle without a final Stop, including timed UI updates, completion-animation settling, history, and restart behavior.

Presentation coverage verifies that heartbeat-only timestamps and ordering do not invalidate the UI while content changes and timed expiry still do. The bundled Herdr case checks that raw heartbeat timestamps keep advancing without application-wide UI notifications; the read-only `ui.modelUpdates` snapshot counter supports that check.

Empty-dashboard coverage checks installed, missing, and unknown hooks, remote-only configuration, and preview/restricted modes. Hook fixtures cover all four local providers, unrelated markers, malformed configurations, and read failures. The bundled app observes fixture Copilot hook installation, removal, and failed checks without modifying real agent configuration; read-only snapshots expose `installedHooks` (null when unknown) and `dashboardEmptyState` (null while sessions are visible).

Cancellation coverage includes same-workspace instances, separate Copilot homes, question/working/done/idle priority, pending approvals, late cleanup, newer prompts, root versus subagent events, bounded and partial reads, log replacement, malformed input, and persisted cancellation. A bundled-app scenario runs two isolated hook helpers and verifies actual menu-bar states, active counts, and cancellation while the app is closed, without canceling or modifying any real Copilot session.

Hardware coverage checks in-place writes, device release, unplug/reconnect cancellation, retry recovery, keepalive ownership, and bounded shutdown without touching real devices.

The smoke script opens a relocated app bundle with isolated data and drives its bundled helper through the actual UI's Working / Ask / Done transitions, completion settling and expiry, window rendering, persistence, and offline replay. It also installs Copilot hooks in a fixture home, executes the actual generated commands, and removes them without modifying real agent configuration. A separate bundled-app case uses two fake SSH remotes to exercise the live Remotes tab, selective reconfiguration, local Ask priority, sleep/wake, and shutdown. Its `--test-ssh` injection requires `--copilot-testing`, an explicit `--state-dir`, and a fixture executable inside that directory; it is not used by ordinary launches.

For manual development events:

```sh
printf '%s\n' '{"hook_event_name":"UserPromptSubmit","session_id":"demo"}' |
  "macos-native/dist/SidePulse Native.app/Contents/Helpers/SidePulseHook" \
    --provider codex --socket "$PWD/macos-native/.run/events.sock" --strict

"macos-native/dist/SidePulse Native.app/Contents/Helpers/SidePulseHook" \
  --socket "$PWD/macos-native/.run/events.sock" --snapshot
```

The helper also accepts `--ping`. Preview and Copilot-testing `--request` actions include `clear`, `capture`, `capture-status`, `capture-settings`, `capture-hooks`, `capture-devices`, `capture-remotes`, `capture-history`, `show-settings`, and `quit`. Captures render only this application's own views and windows, not the desktop. These diagnostics are not needed for normal use.

The preview-only IPC action `set-menu-alignment` accepts an `alignment` field of `Left`, `Center`, or `Right` for bundled UI checks. `set-menu-text` accepts a boolean `enabled` field to exercise live compact-mode changes. Both General settings are available in every application mode.

```text
Sources/SidePulseCore/     Event/state logic, IPC, hooks, persistence, LED programs
Sources/SidePulseHook/     Bundled native hook transport
Sources/SidePulseNative/   AppKit/SwiftUI application and macOS services
Tests/SidePulseCoreTests/  Native core and opt-in bundled-app coverage
Resources/                Application metadata
Tools/                    Native icon generation
```
