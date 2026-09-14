# SidePulse Native for macOS

A standalone Swift/AppKit and SwiftUI application, developed independently of the existing Python implementation. Native source and build output stay in this folder; live application data uses its own native namespace.

The application owns monitoring, settings, history, and the UI. Its bundled `SidePulseHook` executable is a small, one-shot event transport used by agent hooks, not a separate service. Running the app requires neither Python, PyObjC, a Python environment, nor the existing `sidepulse` / `agent-monitor` CLI.

## Build and open

Requires macOS 13 or later and a Swift 6 toolchain. Full Xcode is required for the native test runner.

```sh
./macos-native/build.sh
open "macos-native/dist/SidePulse Native.app"
```

The script builds for the current Mac's architecture and signs the bundle locally. It uses `/Applications/Xcode.app` when available, without changing the system's selected developer directory. Set `DEVELOPER_DIR` to override that selection. No packages are downloaded.

The generated `.app` is self-contained and can be copied elsewhere. Put it in its intended location before installing native agent hooks, because those hooks reference the helper inside that app bundle. If the app moves later, use **Update** in Agent Hooks to refresh the paths.

For Developer ID signing, supply `SIGN_IDENTITY` to `build.sh`. The default ad-hoc signature is for local use; public distribution additionally requires appropriate signing and notarization.

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
./start-native.sh
```

**GitHub Copilot > Install / Update / Remove** and **Remotes** are enabled in this mode. The other local providers, physical output, keep-awake, eject prevention, and login registration remain disabled. No hooks are installed automatically. The `--copilot-testing` launch flag is retained for compatibility.

Click **Install** and confirm the displayed path. This creates or updates only `~/.copilot/hooks/sidepulse-native.json` (or the equivalent under `COPILOT_HOME`). Existing Copilot hooks, including the original SidePulse installation, are preserved. Start a new Copilot CLI session afterward. The Agent Hooks page distinguishes an installed configuration from receiving actual events.

Without a `--state-dir` override, this mode uses the normal native data directory and socket. Those hook commands therefore keep working when the app is subsequently opened normally; they do not point into the temporary preview directory.

Copilot hooks use PascalCase event names to select VS Code-compatible input and pass their registered event name as a legacy-format fallback. Permission and question-dialog notifications produce **Ask**; background completion notifications do not end an active or waiting parent session. For a Stop event that lacks reply text, the native helper reads at most the final 256 KiB of the supplied transcript to find the latest assistant reply. This is an on-demand read, not transcript polling or an ML classifier.

The hook commands emit no permission decisions and remain non-blocking for Copilot even if the app bundle is moved, removed, or unavailable. Failures are reported to stderr; the running helper queues events when the receiver is offline.

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

## Scope and limitations

This is a separate native implementation, not a complete migration of every legacy feature:

- It does not import the original application's preferences, hooks, history, or installation state.
- Local activity requires native hooks. The legacy transcript-only polling fallback is not included. Copilot Stop hooks can read the latest reply from their supplied transcript; other providers use reply text supplied by their hooks.
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

Presentation coverage verifies that heartbeat-only timestamps and ordering do not invalidate the UI while content changes and timed expiry still do. The bundled Herdr case checks that raw heartbeat timestamps keep advancing without application-wide UI notifications; the read-only `ui.modelUpdates` snapshot counter supports that check.

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
