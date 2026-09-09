"""Status-bar UI tests.

The status bar is 4k lines of AppKit that no other test touches, because
importing it needs PyObjC and CI historically ran nothing. That is how a
missing ``ScriptingBridge`` dependency shipped.

Everything here runs headlessly against real AppKit objects -- a real
``StatusBarController``, a real ``NSMenu``, real ``NSWindow`` hierarchies.
No ``NSApplication.run()``, so nothing appears on screen and nothing blocks.

The highest-value test in this file is ``test_every_selector_literal_resolves``:
menu items and buttons refer to their handlers by *string*, so renaming a
controller method leaves a menu entry that crashes when clicked and that no
type checker or import test would notice.
"""

from __future__ import annotations

import ast
import os
import re
import shlex
import subprocess
import tempfile
import threading
import time
import unittest
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import Mock, patch

if os.uname().sysname != "Darwin":  # pragma: no cover
    raise unittest.SkipTest("status-bar UI tests require macOS")

REPO_ROOT = Path(__file__).resolve().parents[1]

_ENV_PATCH = None


def setUpModule():
    """Point config lookups at a scratch home for the duration of this module.

    Settings are read when the controller is constructed (in setUpClass), not
    at import time, so scoping the patch here keeps it from leaking into other
    test modules while still landing before anything reads configuration.
    """
    global _ENV_PATCH
    scratch = tempfile.mkdtemp(prefix="sidepulse-ui-tests-")
    _ENV_PATCH = patch.dict(
        os.environ,
        {"HOME": scratch, "XDG_CONFIG_HOME": str(Path(scratch) / ".config")},
    )
    _ENV_PATCH.start()


def tearDownModule():
    if _ENV_PATCH is not None:
        _ENV_PATCH.stop()


from AppKit import (  # noqa: E402
    NSApplication,
    NSBitmapImageRep,
    NSControl,
    NSImage,
    NSMenu,
    NSView,
    NSWindow,
)

from sidepulse import status_bar as sb  # noqa: E402
from sidepulse import virtual_device as vd  # noqa: E402
from sidepulse.collector import MonitorSnapshot, SourceSpec  # noqa: E402
from sidepulse.models import AgentMode, AgentStatus, AggregateStatus  # noqa: E402
from sidepulse.models import SOURCE_KIND_HERDR_REMOTE  # noqa: E402
from sidepulse.remote_herdr import (  # noqa: E402
    HerdrConnectionState,
    HerdrConnectionStatus,
    HerdrRemoteTestResult,
    HerdrTransportError,
)
from sidepulse.settings import AgentMonitorSettings, HerdrRemoteSetting  # noqa: E402


# A selector literal: camelCase identifier ending in a single colon.
SELECTOR_LITERAL = re.compile(r"^[a-z][A-Za-z0-9_]*:$")

# Classes that can legally be the target of a selector in this codebase.
def target_classes():
    return (sb.StatusBarController, vd.VirtualStatusDevice)


def make_status(
    *,
    provider: str = "claude",
    agent_id: str = "agent-1",
    display_name: str = "sidepulse",
    mode: AgentMode = AgentMode.WORKING,
    age_seconds: float = 5.0,
    cwd: str | None = "/Users/test/project",
    origin: str | None = None,
    stale: bool = False,
    now: datetime | None = None,
) -> AgentStatus:
    now = now or datetime.now(timezone.utc)
    return AgentStatus(
        provider=provider,
        agent_id=agent_id,
        display_name=display_name,
        mode=mode,
        updated_at=now - timedelta(seconds=age_seconds),
        event_name="PostToolUse",
        session_id=f"session-{agent_id}",
        cwd=cwd,
        tool_name="Bash",
        message="doing a thing",
        origin=origin,
        stale=stale,
    )


def make_snapshot(statuses=(), stale_statuses=()) -> MonitorSnapshot:
    now = datetime.now(timezone.utc)
    statuses = tuple(statuses)
    representative = statuses[0] if statuses else None
    return MonitorSnapshot(
        aggregate=AggregateStatus(
            mode=representative.mode if representative else AgentMode.IDLE_READY,
            active_count=len(statuses),
            stale_count=len(stale_statuses),
            representative=representative,
        ),
        statuses=statuses,
        stale_statuses=tuple(stale_statuses),
        sources=(SourceSpec("event-bus", Path("/tmp/does-not-exist.sock")),),
        collected_at=now,
    )


def walk_menu(menu: NSMenu):
    """Yield every item in a menu tree, descending into submenus."""
    for index in range(menu.numberOfItems()):
        item = menu.itemAtIndex_(index)
        yield item
        submenu = item.submenu()
        if submenu is not None:
            yield from walk_menu(submenu)


def make_device(
    name: str = "PULSEDOT",
    *,
    device_id: str | None = None,
    connected: bool = True,
) -> sb.StatusBarDevice:
    root = Path("/Volumes") / name
    return sb.StatusBarDevice(
        device_id=device_id or name.lower(),
        name=name,
        root=root,
        target=root / "leds.txt",
        connected=connected,
        display=sb.LED_DISPLAY_AGENT,
        brightness=255,
        reason="test",
    )


def walk_views(view: NSView):
    """Yield every view in a view tree."""
    yield view
    for subview in view.subviews():
        yield subview
        yield from walk_views(subview)


class StatusBarTestCase(unittest.TestCase):
    """Shared headless AppKit setup."""

    @classmethod
    def setUpClass(cls):
        # A shared application instance must exist before AppKit objects are
        # created. We never call run(), so this stays headless.
        #
        # Some CI runners have no window server. Skipping there beats a red
        # build, but set SIDEPULSE_REQUIRE_UI_TESTS=1 on any machine that is
        # supposed to have one, so the coverage cannot silently disappear.
        try:
            cls.app = NSApplication.sharedApplication()
            cls.controller = sb.StatusBarController.alloc().init()
        except Exception as exc:  # pragma: no cover - environment dependent
            if os.environ.get("SIDEPULSE_REQUIRE_UI_TESTS") == "1":
                raise
            raise unittest.SkipTest(f"AppKit unavailable in this session: {exc}")
        if cls.controller is None:
            raise unittest.SkipTest("StatusBarController could not be created")


class SelectorWiringTests(StatusBarTestCase):
    """Menu and button actions are strings; a rename must not go unnoticed."""

    def selector_literals(self, path: Path) -> set[str]:
        tree = ast.parse(path.read_text(encoding="utf-8"), str(path))
        return {
            node.value
            for node in ast.walk(tree)
            if isinstance(node, ast.Constant)
            and isinstance(node.value, str)
            and SELECTOR_LITERAL.match(node.value)
        }

    def test_every_selector_literal_resolves(self):
        """Every selector-shaped string in the UI must exist on a real class.

        Catches the "renamed the handler, forgot the menu entry" bug, which
        only surfaces when a user clicks the item and the app dies.
        """
        sources = [
            REPO_ROOT / "src/sidepulse/status_bar.py",
            REPO_ROOT / "src/sidepulse/virtual_device.py",
        ]
        classes = target_classes()
        unresolved = []
        for path in sources:
            for selector in sorted(self.selector_literals(path)):
                if not any(c.instancesRespondToSelector_(selector) for c in classes):
                    unresolved.append(f"{path.relative_to(REPO_ROOT)}: {selector}")
        self.assertEqual(
            [],
            unresolved,
            "Selectors with no implementation:\n  " + "\n  ".join(unresolved),
        )

    def test_scan_finds_the_selectors_we_expect(self):
        """Guard the guard: a regex that matches nothing would pass silently."""
        found = self.selector_literals(REPO_ROOT / "src/sidepulse/status_bar.py")
        for expected in ("openSettings:", "openSetup:", "quit:", "refresh:"):
            self.assertIn(expected, found)

    def test_controller_implements_application_delegate_hook(self):
        for selector in (
            "applicationDidFinishLaunching:",
            "applicationShouldTerminate:",
            "applicationWillTerminate:",
        ):
            with self.subTest(selector=selector):
                self.assertTrue(
                    sb.StatusBarController.instancesRespondToSelector_(selector)
                )


class ApplicationLifecycleTests(StatusBarTestCase):
    def test_termination_defers_cleanup_and_carries_unsaved_operations(self):
        controller = sb.StatusBarController.alloc().init()
        remote = HerdrRemoteSetting("draft-1", "Draft", "workbox")
        control_path = Path("/tmp/sidepulse-draft-control")
        cancel_event = threading.Event()
        controller.remote_test_in_flight = True
        controller.remote_test_cancel_event = cancel_event
        controller.remote_test_setting = remote
        controller.remote_test_control_path = control_path

        with patch.object(sb.threading, "Thread") as thread_type:
            result = controller.applicationShouldTerminate_(None)

            self.assertEqual(result, sb.NSTerminateLater)
            self.assertTrue(cancel_event.is_set())
            self.assertEqual(
                thread_type.call_args.kwargs["args"],
                ((remote, control_path), (), ()),
            )
            thread_type.return_value.start.assert_called_once_with()
            self.assertEqual(
                controller.applicationShouldTerminate_(None),
                sb.NSTerminateLater,
            )
            thread_type.assert_called_once()

        controller.termination_cleanup_finished = True
        self.assertEqual(
            controller.applicationShouldTerminate_(None),
            sb.NSTerminateNow,
        )

    def test_cleanup_failure_still_replies_to_appkit(self):
        events = []

        class BrokenManager:
            def stop(self, **_kwargs):
                events.append("stop")
                raise RuntimeError("cleanup failed")

        class TestThread:
            def join(self):
                events.append("join")

        class Harness:
            remote_manager = BrokenManager()

            def __init__(self):
                self.scheduled = []

            def performSelectorOnMainThread_withObject_waitUntilDone_(
                self,
                selector,
                payload,
                wait,
            ):
                self.scheduled.append((selector, payload, wait))

        harness = Harness()

        with patch.object(sb, "log_status_bar") as log_status:
            sb.StatusBarController.finish_application_cleanup(
                harness,
                None,
                (),
                (TestThread(),),
            )

        self.assertEqual(events, ["join", "stop"])
        log_status.assert_called_once_with(
            "remote shutdown cleanup failed (RuntimeError)"
        )
        self.assertEqual(
            harness.scheduled,
            [("completeApplicationTermination:", None, False)],
        )

    def test_late_authentication_completion_is_ignored_after_cancel(self):
        class RemoteManager:
            def __init__(self):
                self.closed = []
                self.adopted = []

            def close_control_master(
                self,
                remote,
                *,
                control_path=None,
                wait=False,
            ):
                self.closed.append((remote, control_path, wait))

            def adopt_control_path(self, remote, control_path):
                self.adopted.append((remote, control_path))
                return None

        controller = sb.StatusBarController.alloc().init()
        manager = RemoteManager()
        controller.remote_manager = manager
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            attempt = sb.HerdrAuthenticationAttempt(
                remote=remote,
                token="token",
                marker=root / "complete",
                acknowledgement=root / "ack",
                cancellation=root / "cancel",
                control_path=root / "control",
            )
            controller.remote_auth_attempts[remote.remote_id] = attempt

            controller.cancel_herdr_authentication(remote.remote_id)
            controller.resumeHerdrRemoteAfterAuth_(
                {"remote_id": remote.remote_id, "token": attempt.token}
            )

            self.assertTrue(attempt.cancellation.exists())
            self.assertEqual(
                manager.closed,
                [(remote, attempt.control_path, False)],
            )
            self.assertEqual(manager.adopted, [])

    def test_authentication_ack_failure_restores_previous_control_path(self):
        class RemoteManager:
            def __init__(self, current):
                self.current = current
                self.adopted = []
                self.closed = []
                self.retried = []

            def adopt_control_path(self, remote, control_path):
                previous = (
                    self.current
                    if self.current is not None and self.current != control_path
                    else None
                )
                self.current = control_path
                self.adopted.append((remote, control_path))
                return previous

            def close_control_master(
                self,
                remote,
                *,
                control_path=None,
                wait=False,
            ):
                self.closed.append((remote, control_path, wait))

            def retry(self, remote_id):
                self.retried.append(remote_id)

        controller = sb.StatusBarController.alloc().init()
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        controller.settings = AgentMonitorSettings(herdr_remotes=(remote,))
        controller.remote_manager_started = True
        previous_control_path = Path("/tmp/sidepulse-previous-control")
        manager = RemoteManager(previous_control_path)
        controller.remote_manager = manager
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "missing"
            attempt = sb.HerdrAuthenticationAttempt(
                remote=remote,
                token="token",
                marker=missing / "complete",
                acknowledgement=missing / "ack",
                cancellation=missing / "cancel",
                control_path=Path(tmp) / "new-control",
            )
            controller.remote_auth_attempts[remote.remote_id] = attempt

            controller.resumeHerdrRemoteAfterAuth_(
                {"remote_id": remote.remote_id, "token": attempt.token}
            )

        self.assertEqual(manager.current, previous_control_path)
        self.assertEqual(
            manager.adopted,
            [
                (remote, attempt.control_path),
                (remote, previous_control_path),
            ],
        )
        self.assertEqual(
            manager.closed,
            [(remote, attempt.control_path, False)],
        )
        self.assertEqual(manager.retried, [])
        self.assertNotIn(remote.remote_id, controller.remote_auth_attempts)

    def test_remote_actions_surface_control_path_preparation_errors(self):
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")

        class TestHarness:
            remote_test_status = ""

            def __init__(self):
                self.refreshed = False

            def herdr_remote_from_fields(self):
                return remote

            def start_herdr_remote_test(self, _remote):
                raise HerdrTransportError("control directory unavailable")

            def refresh_remote_connection_labels(self):
                self.refreshed = True

        test_harness = TestHarness()
        sb.StatusBarController.__dict__["testHerdrRemote_"].callable(
            test_harness,
            None,
        )

        self.assertEqual(
            test_harness.remote_test_status,
            "Test failed: control directory unavailable",
        )
        self.assertTrue(test_harness.refreshed)

        class AuthenticationHarness:
            settings = AgentMonitorSettings()
            remote_test_status = ""

            def __init__(self):
                self.refreshed = False

            def herdr_remote_from_fields(self):
                return remote

            def cancel_herdr_authentication(self, _remote_id):
                return None

            def refresh_remote_connection_labels(self):
                self.refreshed = True

        authentication_harness = AuthenticationHarness()
        with patch.object(
            sb,
            "herdr_ssh_control_path",
            side_effect=HerdrTransportError("control directory unavailable"),
        ):
            sb.StatusBarController.__dict__["authenticateHerdrRemote_"].callable(
                authentication_harness,
                None,
            )

        self.assertEqual(
            authentication_harness.remote_test_status,
            "Could not prepare authentication: control directory unavailable",
        )
        self.assertTrue(authentication_harness.refreshed)

    def test_failed_remote_writes_do_not_mutate_controller_settings(self):
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")

        class SaveHarness:
            def __init__(self):
                self.settings = AgentMonitorSettings()
                self.remote_test_status = ""
                self.refreshed = False

            def herdr_remote_from_fields(self):
                return remote

            def refresh_remote_connection_labels(self):
                self.refreshed = True

        save_harness = SaveHarness()
        original_save_settings = save_harness.settings
        with patch.object(
            sb,
            "save_settings",
            side_effect=OSError("read-only settings"),
        ):
            sb.StatusBarController.__dict__["saveHerdrRemote_"].callable(
                save_harness,
                None,
            )

        self.assertIs(save_harness.settings, original_save_settings)
        self.assertEqual(
            save_harness.remote_test_status,
            "Could not save remote: read-only settings",
        )
        self.assertTrue(save_harness.refreshed)

        class RemoveHarness:
            def __init__(self):
                self.settings = AgentMonitorSettings(herdr_remotes=(remote,))
                self.remote_test_status = ""
                self.refreshed = False

            def selected_herdr_remote(self):
                return remote

            def refresh_remote_connection_labels(self):
                self.refreshed = True

        remove_harness = RemoveHarness()
        original_remove_settings = remove_harness.settings
        with patch.object(
            sb,
            "save_settings",
            side_effect=OSError("read-only settings"),
        ):
            sb.StatusBarController.__dict__["removeHerdrRemote_"].callable(
                remove_harness,
                None,
            )

        self.assertIs(remove_harness.settings, original_remove_settings)
        self.assertEqual(
            remove_harness.remote_test_status,
            "Could not remove remote: read-only settings",
        )
        self.assertTrue(remove_harness.refreshed)


class SystemSleepTests(StatusBarTestCase):
    def setUp(self):
        self.controller = sb.StatusBarController.alloc().init()
        self.addCleanup(self.controller.stop_power_notifications)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.device = replace(
            make_device(),
            root=root,
            target=root / "LEDS.LED",
        )
        self.controller.status_bar_devices = Mock(return_value=[self.device])

    def test_sleep_clears_done_and_suppresses_refreshes(self):
        self.controller.sync_leds_now(
            AgentMode.COMPLETED, None, sb.LED_DISPLAY_AGENT
        )
        self.assertNotEqual(self.device.target.read_text(), "off")

        self.controller.systemWillSleep_(None)

        self.assertTrue(self.controller.system_sleeping)
        self.assertEqual(self.device.target.read_text(), "off")
        with (
            patch.object(self.controller.monitor, "snapshot") as snapshot,
            patch.object(sb.threading, "Thread") as thread_type,
        ):
            self.controller.refresh_(None)
            self.controller.sync_leds(
                AgentMode.WORKING, None, sb.LED_DISPLAY_AGENT
            )
            self.controller.play_lid_animation(sb.LID_ANIMATION_CLOSED)
            self.controller.pollLid_(None)

        snapshot.assert_not_called()
        thread_type.assert_not_called()
        self.assertEqual(self.device.target.read_text(), "off")

    def test_sleep_only_clears_connected_managed_physical_devices(self):
        devices = [self.device]
        for name, display, connected in (
            ("battery", sb.LED_DISPLAY_BATTERY, True),
            ("manual", sb.LED_DISPLAY_CUSTOM, True),
            ("disconnected", sb.LED_DISPLAY_AGENT, False),
            ("virtual", sb.LED_DISPLAY_AGENT, True),
        ):
            root = self.device.root / name
            devices.append(
                replace(
                    self.device,
                    device_id=sb.VIRTUAL_DEVICE_ID if name == "virtual" else name,
                    name=name,
                    root=root,
                    target=root / "LEDS.LED",
                    display=display,
                    connected=connected,
                )
            )
        for device in devices:
            device.root.mkdir(parents=True, exist_ok=True)
            device.target.write_text("#00FF66")
        self.controller.status_bar_devices.return_value = devices
        original_settings = self.controller.settings

        self.controller.systemWillSleep_(None)

        for device in devices[:2]:
            self.assertEqual(device.target.read_text(), "off")
        for device in devices[2:]:
            self.assertEqual(device.target.read_text(), "#00FF66")
        self.assertIs(self.controller.settings, original_settings)

    def test_sleep_does_not_touch_disabled_leds(self):
        self.controller.leds_enabled = False
        self.device.target.write_text("#00FF66")
        with patch.object(sb.threading, "Thread") as thread_type:
            self.controller.systemWillSleep_(None)

        thread_type.assert_not_called()
        self.assertEqual(self.device.target.read_text(), "#00FF66")

    def test_sleep_invalidates_queued_status_and_animation_writes(self):
        with patch.object(sb.threading, "Thread") as thread_type:
            self.controller.sync_leds(
                AgentMode.COMPLETED, None, sb.LED_DISPLAY_AGENT
            )
            self.controller.play_lid_animation(sb.LID_ANIMATION_CLOSED)
        queued = [call.kwargs for call in thread_type.call_args_list]
        self.assertEqual(len(queued), 2)
        animation_token = self.controller.led_animation_token

        self.controller.systemWillSleep_(None)
        sleep_generation = self.controller.led_sleep_generation
        for job in queued:
            job["target"](*job["args"])
        self.controller.restoreLedDisplay_(str(animation_token))
        self.assertEqual(self.device.target.read_text(), "off")

        self.controller.refresh_ = Mock()
        self.controller.systemDidWake_(None)
        self.device.target.write_text("new live display")
        self.controller.led_sync_in_flight = True
        for job in queued:
            job["target"](*job["args"])
        self.controller.clear_leds_for_sleep(sleep_generation)
        self.controller.restoreLedDisplay_(str(animation_token))

        self.assertEqual(self.device.target.read_text(), "new live display")
        self.assertTrue(self.controller.led_sync_in_flight)

    def test_sleep_clear_waits_for_in_flight_status_write(self):
        entered = threading.Event()
        finish_write = threading.Event()
        sync_now = self.controller.sync_leds_now
        clear_for_sleep = self.controller.clear_leds_for_sleep

        def blocked_write(*args):
            entered.set()
            if not finish_write.wait(timeout=2):
                raise TimeoutError("test status write was not released")
            sync_now(*args)

        def clear_after_writer(generation):
            finish_write.set()
            clear_for_sleep(generation)

        self.controller.sync_leds_now = blocked_write
        self.controller.clear_leds_for_sleep = clear_after_writer
        writer = threading.Thread(
            target=self.controller.sync_leds_worker,
            args=(
                AgentMode.COMPLETED,
                None,
                sb.LED_DISPLAY_AGENT,
                self.controller.led_sleep_generation,
            ),
            daemon=True,
        )
        writer.start()
        try:
            self.assertTrue(entered.wait(timeout=1))
            self.controller.systemWillSleep_(None)
        finally:
            finish_write.set()
            writer.join(timeout=2)

        self.assertFalse(writer.is_alive())
        self.assertEqual(self.device.target.read_text(), "off")

    def test_wake_refreshes_live_status_and_invalidates_led_cache(self):
        for mode in (AgentMode.IDLE_READY, AgentMode.COMPLETED):
            with self.subTest(mode=mode):
                self.controller.sync_leds_now(
                    AgentMode.COMPLETED, None, sb.LED_DISPLAY_AGENT
                )
                self.controller.last_snapshot = make_snapshot(
                    statuses=[make_status(mode=AgentMode.COMPLETED)]
                )
                self.controller.systemWillSleep_(None)
                self.assertEqual(self.device.target.read_text(), "off")
                fresh = make_snapshot(
                    statuses=[] if mode == AgentMode.IDLE_READY else [
                        make_status(mode=mode)
                    ]
                )
                self.controller.monitor.snapshot = Mock(return_value=fresh)
                self.controller.read_battery_snapshot = Mock(return_value=None)
                self.controller.read_mac_sleep_snapshot = Mock(return_value=None)
                self.controller.record_status_history = Mock()
                self.controller.sync_keep_awake = Mock()
                self.controller.observe_connected_devices = Mock(return_value=False)
                self.controller.set_status = Mock()
                self.controller.status_item = Mock()

                with patch.object(sb.threading, "Thread") as thread_type:
                    self.controller.systemDidWake_(None)
                job = thread_type.call_args.kwargs
                job["target"](*job["args"])

                self.assertFalse(self.controller.system_sleeping)
                self.assertIs(self.controller.last_snapshot, fresh)
                self.controller.monitor.snapshot.assert_called_once_with(
                    include_stale=False
                )
                self.assertEqual(
                    self.device.target.read_text(),
                    sb.program_for_display_state(sb.display_state_for_mode(mode)),
                )

    def test_sleep_clear_timeout_is_bounded_and_reported(self):
        with (
            patch.object(sb.threading, "Thread") as thread_type,
            patch.object(sb, "log_status_bar") as log_status,
        ):
            thread_type.return_value.is_alive.return_value = True
            self.controller.systemWillSleep_(None)

        thread_type.return_value.join.assert_called_once_with(
            timeout=sb.SLEEP_LED_CLEAR_TIMEOUT_SECONDS
        )
        log_status.assert_any_call(
            "sleep LED clear timed out; allowing system sleep"
        )
        self.assertTrue(self.controller.system_sleeping)

    def test_sleep_clear_reports_device_write_failure(self):
        with (
            patch.object(sb, "write_led_program", side_effect=OSError("disconnected")),
            patch.object(sb, "log_status_bar") as log_status,
        ):
            self.controller.systemWillSleep_(None)

        log_status.assert_any_call(
            f"sleep LED clear error {self.device.name}: disconnected"
        )
        self.assertTrue(self.controller.system_sleeping)

    def test_workspace_sleep_observers_are_registered_and_removed(self):
        self.controller.leds_enabled = False
        self.controller.refresh_ = Mock()
        self.controller.start_power_notifications()
        self.controller.start_power_notifications()
        center = sb.NSWorkspace.sharedWorkspace().notificationCenter()

        center.postNotificationName_object_(sb.NSWorkspaceWillSleepNotification, None)
        self.assertTrue(self.controller.system_sleeping)
        center.postNotificationName_object_(sb.NSWorkspaceDidWakeNotification, None)
        self.assertFalse(self.controller.system_sleeping)
        self.assertEqual(self.controller.led_sleep_generation, 2)
        self.controller.refresh_.assert_called_once_with(None)

        self.controller.stop_power_notifications()
        center.postNotificationName_object_(sb.NSWorkspaceWillSleepNotification, None)
        self.assertFalse(self.controller.system_sleeping)

    def test_lid_close_without_system_sleep_preserves_live_display(self):
        self.device.target.write_text("#00FF66")
        self.controller.last_lid_closed = False
        self.controller.pending_lid_closed = True
        with patch.object(sb.threading, "Thread") as thread_type:
            self.controller.handleLidPollResult_(None)

        self.assertFalse(self.controller.system_sleeping)
        self.assertEqual(self.device.target.read_text(), "#00FF66")
        self.assertEqual(
            thread_type.call_args.kwargs["args"][0], sb.LID_ANIMATION_CLOSED
        )
        thread_type.return_value.start.assert_called_once_with()


class MenuBuildTests(StatusBarTestCase):
    """build_menu must produce a wired, clickable menu for any snapshot."""

    def setUp(self):
        # Real device discovery would make these tests depend on whatever
        # hardware happens to be plugged in.
        patcher = patch.object(sb, "discover_devices", return_value=[])
        self.discover_devices = patcher.start()
        self.addCleanup(patcher.stop)

    def assert_menu_is_wired(self, menu: NSMenu):
        for item in walk_menu(menu):
            if item.submenu() is not None:
                continue  # AppKit owns submenuAction: on parent items
            action = item.action()
            if action is None:
                continue
            selector = action if isinstance(action, str) else action.decode()
            target = item.target()
            if target is None:
                # Nil-targeted items go up the responder chain; the controller
                # is the app delegate, so it must still implement the action.
                self.assertTrue(
                    any(c.instancesRespondToSelector_(selector) for c in target_classes()),
                    f"menu item {item.title()!r} has unroutable action {selector}",
                )
                continue
            self.assertTrue(
                target.respondsToSelector_(selector),
                f"menu item {item.title()!r} targets {target} "
                f"which does not implement {selector}",
            )

    def test_empty_snapshot_builds_menu(self):
        menu = sb.build_menu(make_snapshot(), sb.STATE_IDLE, self.controller)
        self.assertGreater(menu.numberOfItems(), 0)
        titles = [item.title() for item in walk_menu(menu)]
        self.assertIn("No recent sessions", titles)
        self.assert_menu_is_wired(menu)

    def test_populated_snapshot_builds_menu(self):
        snapshot = make_snapshot(
            statuses=[
                make_status(agent_id="a", display_name="alpha"),
                make_status(agent_id="b", display_name="beta", provider="codex"),
            ]
        )
        menu = sb.build_menu(snapshot, sb.STATE_WORKING, self.controller)
        titles = " ".join(item.title() for item in walk_menu(menu))
        self.assertNotIn("No recent sessions", titles)
        self.assert_menu_is_wired(menu)

    def test_menu_builds_for_every_agent_mode(self):
        for mode in AgentMode:
            with self.subTest(mode=mode.value):
                snapshot = make_snapshot(statuses=[make_status(mode=mode)])
                menu = sb.build_menu(snapshot, sb.STATE_WORKING, self.controller)
                self.assertGreater(menu.numberOfItems(), 0)
                self.assert_menu_is_wired(menu)

    def test_menu_builds_for_every_provider(self):
        for provider in ("claude", "codex", "grok", "unknown-provider"):
            with self.subTest(provider=provider):
                snapshot = make_snapshot(statuses=[make_status(provider=provider)])
                menu = sb.build_menu(snapshot, sb.STATE_IDLE, self.controller)
                self.assert_menu_is_wired(menu)

    def test_menu_handles_colliding_session_titles(self):
        """Two sessions with the same name must still produce distinct rows."""
        snapshot = make_snapshot(
            statuses=[
                make_status(agent_id="a", display_name="same", cwd="/one"),
                make_status(agent_id="b", display_name="same", cwd="/two"),
            ]
        )
        menu = sb.build_menu(snapshot, sb.STATE_WORKING, self.controller)
        self.assert_menu_is_wired(menu)

    def test_menu_handles_hostile_session_names(self):
        """Session titles come from user directories and must not break layout."""
        for name in ("", " ", "a" * 500, "emoji 🚀 name", "with\nnewline", "%s %d {}"):
            with self.subTest(name=repr(name)):
                snapshot = make_snapshot(statuses=[make_status(display_name=name)])
                menu = sb.build_menu(snapshot, sb.STATE_WORKING, self.controller)
                self.assertGreater(menu.numberOfItems(), 0)

    def test_menu_includes_core_actions(self):
        menu = sb.build_menu(make_snapshot(), sb.STATE_IDLE, self.controller)
        titles = [item.title() for item in walk_menu(menu)]
        for expected in ("Setup...", "Settings...", "Quit"):
            self.assertIn(expected, titles)

    def test_recent_statuses_are_capped(self):
        """The menu must not grow unbounded with session count."""
        snapshot = make_snapshot(
            statuses=[make_status(agent_id=f"a{i}") for i in range(50)]
        )
        self.assertLessEqual(len(sb.recent_statuses(snapshot)), 12)

    def test_remote_agents_are_grouped_and_not_actionable_locally(self):
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        status = make_status(
            provider="copilot",
            agent_id="herdr:remote-1:term-1:copilot",
            display_name="Remote task",
            origin="Workbox via Herdr",
        )
        status = AgentStatus(
            **{
                **status.__dict__,
                "source_kind": SOURCE_KIND_HERDR_REMOTE,
                "source_id": "remote-1",
            }
        )
        original_settings = self.controller.settings
        original_manager = self.controller.remote_manager
        self.controller.settings = AgentMonitorSettings(herdr_remotes=(remote,))
        self.controller.remote_manager = type(
            "RemoteManager",
            (),
            {
                "connection_status": lambda _self, _remote_id: HerdrConnectionStatus(
                    "remote-1",
                    HerdrConnectionState.CONNECTED,
                )
            },
        )()
        self.addCleanup(setattr, self.controller, "settings", original_settings)
        self.addCleanup(setattr, self.controller, "remote_manager", original_manager)

        menu = sb.build_menu(
            make_snapshot(statuses=[status]),
            sb.STATE_WORKING,
            self.controller,
        )
        titles = [item.title() for item in walk_menu(menu)]
        remote_item = next(
            item for item in walk_menu(menu) if item.title().startswith("Remote task")
        )

        self.assertIn("Local", titles)
        self.assertIn("Workbox via Herdr", titles)
        disable_item = next(item for item in walk_menu(menu) if item.title() == "Disable")
        self.assertEqual(disable_item.action(), "toggleHerdrRemote:")
        self.assertEqual(disable_item.representedObject(), "remote-1")
        self.assertIn("Connected", titles)
        self.assertFalse(remote_item.isEnabled())
        self.assertIsNone(remote_item.action())

    def test_disabled_remote_menu_offers_enable_action(self):
        remote = HerdrRemoteSetting(
            "remote-1",
            "Workbox",
            "workbox",
            enabled=False,
        )
        original_settings = self.controller.settings
        original_manager = self.controller.remote_manager
        self.controller.settings = AgentMonitorSettings(herdr_remotes=(remote,))
        self.controller.remote_manager = type(
            "RemoteManager",
            (),
            {
                "connection_status": lambda _self, _remote_id: HerdrConnectionStatus(
                    "remote-1",
                    HerdrConnectionState.DISABLED,
                )
            },
        )()
        self.addCleanup(setattr, self.controller, "settings", original_settings)
        self.addCleanup(setattr, self.controller, "remote_manager", original_manager)

        menu = sb.build_menu(make_snapshot(), sb.STATE_IDLE, self.controller)
        enable_item = next(item for item in walk_menu(menu) if item.title() == "Enable")

        self.assertEqual(enable_item.action(), "toggleHerdrRemote:")
        self.assertEqual(enable_item.representedObject(), "remote-1")

    def test_remote_menu_toggle_persists_and_reconfigures_manager(self):
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        applied_settings = []
        cancelled = []
        messages = []
        refreshes = []

        class ToggleHarness:
            def __init__(self):
                self.settings = AgentMonitorSettings(herdr_remotes=(remote,))
                self.remote_manager_started = True
                self.remote_manager = type(
                    "RemoteManager",
                    (),
                    {
                        "apply_settings": lambda _self, settings: applied_settings.append(
                            tuple(settings)
                        )
                    },
                )()

            def cancel_herdr_authentication(self, remote_id):
                cancelled.append(remote_id)

            def refresh_remote_settings_controls(self):
                refreshes.append("controls")

            def set_remote_settings_message(self, message):
                messages.append(message)

            def refresh_(self, _sender):
                refreshes.append("menu")

        harness = ToggleHarness()
        with patch.object(sb, "save_settings") as save:
            sb.StatusBarController.set_herdr_remote_enabled(
                harness,
                "remote-1",
                False,
            )

        updated = harness.settings.herdr_remote("remote-1")
        self.assertIsNotNone(updated)
        self.assertFalse(updated.enabled)
        save.assert_called_once_with(harness.settings)
        self.assertEqual(applied_settings, [harness.settings.herdr_remotes])
        self.assertEqual(cancelled, ["remote-1"])
        self.assertEqual(messages, ["Workbox: remote disabled."])
        self.assertEqual(refreshes, ["controls", "menu"])

    def test_local_history_cap_does_not_hide_remote_agents(self):
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        local_statuses = [
            make_status(agent_id=f"local-{index}", age_seconds=float(index))
            for index in range(20)
        ]
        remote_status = replace(
            make_status(
                provider="copilot",
                agent_id="herdr:remote-1:term-1:copilot",
                display_name="Older remote task",
                age_seconds=100,
                origin="Workbox via Herdr",
            ),
            source_kind=SOURCE_KIND_HERDR_REMOTE,
            source_id="remote-1",
        )
        original_settings = self.controller.settings
        original_manager = self.controller.remote_manager
        self.controller.settings = AgentMonitorSettings(herdr_remotes=(remote,))
        self.controller.remote_manager = type(
            "RemoteManager",
            (),
            {
                "connection_status": lambda _self, _remote_id: HerdrConnectionStatus(
                    "remote-1",
                    HerdrConnectionState.CONNECTED,
                )
            },
        )()
        self.addCleanup(setattr, self.controller, "settings", original_settings)
        self.addCleanup(setattr, self.controller, "remote_manager", original_manager)

        menu = sb.build_menu(
            make_snapshot(statuses=[*local_statuses, remote_status]),
            sb.STATE_WORKING,
            self.controller,
        )
        titles = [item.title() for item in walk_menu(menu)]

        self.assertTrue(any(title.startswith("Older remote task") for title in titles))


class WindowBuildTests(StatusBarTestCase):
    """Settings and setup windows construct hundreds of views; a crash is a crash."""

    def assert_controls_are_wired(self, window: NSWindow):
        content = window.contentView()
        self.assertIsNotNone(content)
        for view in walk_views(content):
            if not isinstance(view, NSControl):
                continue
            action = view.action()
            if action is None:
                continue
            selector = action if isinstance(action, str) else action.decode()
            target = view.target()
            if target is None:
                self.assertTrue(
                    any(c.instancesRespondToSelector_(selector) for c in target_classes()),
                    f"control has unroutable action {selector}",
                )
                continue
            self.assertTrue(
                target.respondsToSelector_(selector),
                f"control targets {target} which does not implement {selector}",
            )

    def test_settings_window_builds(self):
        window = sb.build_settings_window(self.controller)
        self.assertIsNotNone(window)
        self.assertTrue(window.title())
        self.assert_controls_are_wired(window)

    def test_setup_window_builds(self):
        window = sb.build_setup_window(self.controller)
        self.assertIsNotNone(window)
        self.assert_controls_are_wired(window)

    def test_settings_window_registers_its_fields(self):
        """The controller reads values back out of this dict when saving."""
        self.controller.settings_fields = {}
        sb.build_settings_window(self.controller)
        self.assertTrue(
            self.controller.settings_fields,
            "settings window built no addressable fields; saving would be a no-op",
        )
        self.assertIn("herdr_remote_selector", self.controller.settings_fields)
        self.assertIn("herdr_remote_target", self.controller.settings_fields)

    def test_settings_window_is_not_visible(self):
        window = sb.build_settings_window(self.controller)
        self.assertFalse(window.isVisible(), "building a window must not show it")

    def test_stale_remote_test_result_is_ignored(self):
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        original = {
            "remote_test_generation": self.controller.remote_test_generation,
            "remote_test_in_flight": self.controller.remote_test_in_flight,
            "remote_test_status": self.controller.remote_test_status,
            "remote_tested_setting": self.controller.remote_tested_setting,
        }
        for name, value in original.items():
            self.addCleanup(setattr, self.controller, name, value)
        self.controller.remote_test_generation = 2
        self.controller.remote_test_in_flight = True
        self.controller.remote_test_status = "Current test"
        self.controller.remote_tested_setting = None

        self.controller.finishHerdrRemoteTest_(
            {
                "generation": 1,
                "remote": remote,
                "result": HerdrRemoteTestResult(
                    setting=remote,
                    connection=HerdrConnectionStatus(
                        "remote-1",
                        HerdrConnectionState.CONNECTED,
                    ),
                ),
            }
        )

        self.assertTrue(self.controller.remote_test_in_flight)
        self.assertEqual(self.controller.remote_test_status, "Current test")
        self.assertIsNone(self.controller.remote_tested_setting)

    def test_invalidating_remote_test_cancels_process_and_closes_draft_master(self):
        class BlockingProcess:
            def __init__(self):
                self.terminated = False

            def poll(self):
                return None

            def terminate(self):
                self.terminated = True

        class RemoteManager:
            def __init__(self):
                self.closed = []

            def close_control_master(
                self,
                remote,
                *,
                control_path=None,
                wait=False,
            ):
                self.closed.append((remote, control_path, wait))

        remote = HerdrRemoteSetting("draft-1", "Workbox", "workbox")
        control_path = Path("/tmp/sidepulse-draft-control")
        cancel_event = threading.Event()
        process = BlockingProcess()
        original = {
            "settings": self.controller.settings,
            "remote_manager": self.controller.remote_manager,
            "remote_test_generation": self.controller.remote_test_generation,
            "remote_test_in_flight": self.controller.remote_test_in_flight,
            "remote_test_cancel_event": self.controller.remote_test_cancel_event,
            "remote_test_process": self.controller.remote_test_process,
            "remote_test_setting": self.controller.remote_test_setting,
            "remote_test_control_path": self.controller.remote_test_control_path,
        }
        for name, value in original.items():
            self.addCleanup(setattr, self.controller, name, value)
        manager = RemoteManager()
        self.controller.settings = AgentMonitorSettings()
        self.controller.remote_manager = manager
        self.controller.remote_test_in_flight = True
        self.controller.remote_test_cancel_event = cancel_event
        self.controller.remote_test_process = process
        self.controller.remote_test_setting = remote
        self.controller.remote_test_control_path = control_path

        self.controller.invalidate_herdr_remote_test()

        self.assertTrue(cancel_event.is_set())
        self.assertTrue(process.terminated)
        self.assertFalse(self.controller.remote_test_in_flight)
        self.assertEqual(manager.closed, [(remote, control_path, False)])


class IconTests(StatusBarTestCase):
    """Icon builders return real images rather than None."""

    def test_status_icons_exist_for_every_mode(self):
        for mode in AgentMode:
            with self.subTest(mode=mode.value):
                status = make_status(mode=mode)
                image = sb.session_row_icon_for_status(status)
                self.assertIsInstance(image, NSImage)
                self.assertFalse(image.isTemplate())

    def test_provider_icons_do_not_raise(self):
        for provider in ("claude", "codex", "grok", "nonsense"):
            with self.subTest(provider=provider):
                sb.provider_icon_for_provider(provider)

    def test_state_symbols_render(self):
        for state in (sb.STATE_IDLE, sb.STATE_WORKING, sb.STATE_DONE, sb.STATE_ASK):
            with self.subTest(state=state.label):
                self.assertIsInstance(
                    sb.image_for_symbol(state.symbol, state.label), NSImage
                )

    def test_menu_icons_are_green(self):
        image = sb.tinted_menu_icon(
            sb.image_for_symbol(sb.STATE_DONE.symbol, sb.STATE_DONE.label)
        )
        bitmap = NSBitmapImageRep.imageRepWithData_(image.TIFFRepresentation())
        opaque_colors = [
            bitmap.colorAtX_y_(x, y)
            for y in range(bitmap.pixelsHigh())
            for x in range(bitmap.pixelsWide())
            if bitmap.colorAtX_y_(x, y).alphaComponent() > 0.5
        ]

        self.assertTrue(opaque_colors)
        for color in opaque_colors:
            self.assertGreater(color.greenComponent(), color.redComponent())
            self.assertGreater(color.greenComponent(), color.blueComponent())


class StatusLedAnimationTests(StatusBarTestCase):
    def setUp(self):
        self.controller = sb.StatusBarController.alloc().init()
        self.controller.status_reduce_motion = False
        self.button = sb.NSButton.alloc().initWithFrame_(((0, 0), (105, 22)))
        self.controller.status_item = Mock()
        self.controller.status_item.button.return_value = self.button
        self.addCleanup(self.controller.stop_status_display)
        clock = patch.object(sb.time, "monotonic", return_value=1000.0)
        self.clock = clock.start()
        self.addCleanup(clock.stop)

    def test_chase_moves_left_to_right_and_repeats(self):
        for index in range(sb.STATUS_LED_COUNT):
            frame = index * sb.STATUS_LED_CHASE_FRAMES // sb.STATUS_LED_COUNT
            levels = sb.status_led_brightness(sb.STATE_WORKING, frame)
            self.assertEqual(len(levels), 4)
            self.assertEqual(levels.index(max(levels)), index)
            self.assertTrue(all(0.0 < level <= 1.0 for level in levels))
        self.assertEqual(
            sb.status_led_brightness(sb.STATE_WORKING, 0),
            sb.status_led_brightness(sb.STATE_WORKING, sb.STATUS_LED_CHASE_FRAMES),
        )

    def test_done_brightens_once_then_remains_steady(self):
        initial = sb.status_led_brightness(sb.STATE_DONE, 0)
        peak = sb.status_led_brightness(sb.STATE_DONE, sb.STATUS_LED_DONE_FRAMES // 2)
        settled = sb.status_led_brightness(sb.STATE_DONE, sb.STATUS_LED_DONE_FRAMES)
        self.assertEqual(len(set(peak)), 1)
        self.assertGreater(peak[0], initial[0])
        self.assertEqual(initial, settled)
        self.assertEqual(
            settled,
            sb.status_led_brightness(sb.STATE_DONE, sb.STATUS_LED_DONE_FRAMES * 10),
        )

    def test_ask_breathes_in_unison_without_going_dark(self):
        initial = sb.status_led_brightness(sb.STATE_ASK, 0)
        peak = sb.status_led_brightness(sb.STATE_ASK, sb.STATUS_LED_ASK_FRAMES // 2)
        self.assertGreater(peak[0], initial[0])
        self.assertAlmostEqual(peak[0], 1.0)
        for frame in range(sb.STATUS_LED_ASK_FRAMES):
            levels = sb.status_led_brightness(sb.STATE_ASK, frame)
            self.assertEqual(len(levels), 4)
            self.assertEqual(len(set(levels)), 1)
            self.assertGreaterEqual(levels[0], 0.35)
            self.assertLessEqual(levels[0], 1.0)
            self.assertEqual(
                levels,
                sb.status_led_brightness(sb.STATE_ASK, frame + sb.STATUS_LED_ASK_FRAMES),
            )

    def test_led_images_render_four_colored_segments_at_a_fixed_size(self):
        for state in (sb.STATE_WORKING, sb.STATE_DONE, sb.STATE_ASK):
            with self.subTest(state=state.label):
                image = sb.status_led_image(state, 0)
                self.assertIs(image, sb.status_led_image(state, 0))
                self.assertEqual(tuple(image.size()), sb.STATUS_LED_IMAGE_SIZE)
                self.assertFalse(image.isTemplate())
                self.assertEqual(image.accessibilityDescription(), state.label)
                bitmap = NSBitmapImageRep.imageRepWithData_(image.TIFFRepresentation())
                scale_x = bitmap.pixelsWide() / image.size().width
                scale_y = bitmap.pixelsHigh() / image.size().height
                for index in range(sb.STATUS_LED_COUNT):
                    color = bitmap.colorAtX_y_(
                        int((4 + index * 7) * scale_x), int(9 * scale_y)
                    )
                    self.assertGreater(color.alphaComponent(), 0.9)
                    if state == sb.STATE_ASK:
                        self.assertGreater(color.redComponent(), color.greenComponent())
                        self.assertGreater(color.greenComponent(), color.blueComponent())
                    else:
                        self.assertGreater(color.greenComponent(), color.redComponent())
                        if state == sb.STATE_WORKING:
                            self.assertGreater(color.blueComponent(), color.greenComponent())
                        else:
                            self.assertGreater(color.greenComponent(), color.blueComponent())
                for x in (7.5, 14.5, 21.5):
                    color = bitmap.colorAtX_y_(int(x * scale_x), int(9 * scale_y))
                    self.assertLess(color.alphaComponent(), 0.15)

    def test_working_refresh_preserves_the_timer_and_animation_phase(self):
        self.controller.set_status(sb.STATE_WORKING)
        timer = self.controller.status_animation_timer
        started = self.controller.status_animation_started_at
        self.assertTrue(timer.isValid())
        self.assertEqual(self.button.title(), " Working")
        self.assertEqual(
            self.button.accessibilityLabel(), "SidePulse Agent Monitor: Working"
        )
        self.assertEqual(self.button.toolTip(), "SidePulse Agent Monitor: Working")
        self.clock.return_value += 9 * sb.STATUS_LED_FRAME_INTERVAL + 0.001
        with patch.object(self.controller.monitor, "snapshot") as snapshot:
            self.controller.animateStatus_(timer)
        snapshot.assert_not_called()
        self.assertIs(self.button.image(), sb.status_led_image(sb.STATE_WORKING, 9))

        self.controller.set_status(sb.STATE_WORKING)

        self.assertIs(self.controller.status_animation_timer, timer)
        self.assertEqual(self.controller.status_animation_started_at, started)
        self.assertIs(self.button.image(), sb.status_led_image(sb.STATE_WORKING, 9))

    def test_ask_repeats_every_1_6_seconds_without_resetting_on_refresh(self):
        self.controller.set_status(sb.STATE_ASK)
        timer = self.controller.status_animation_timer
        started = self.controller.status_animation_started_at
        self.assertTrue(timer.isValid())
        self.assertEqual(self.button.title(), " Ask")
        self.assertEqual(self.button.accessibilityLabel(), "SidePulse Agent Monitor: Ask")
        self.assertEqual(self.button.toolTip(), "SidePulse Agent Monitor: Ask")
        self.clock.return_value = started + 0.8001
        with patch.object(self.controller.monitor, "snapshot") as snapshot:
            self.controller.animateStatus_(timer)
        snapshot.assert_not_called()
        self.assertIs(
            self.button.image(),
            sb.status_led_image(sb.STATE_ASK, sb.STATUS_LED_ASK_FRAMES // 2),
        )
        self.controller.set_status(sb.STATE_ASK)
        self.assertIs(self.controller.status_animation_timer, timer)
        self.assertEqual(self.controller.status_animation_started_at, started)

        for cycles in (1, 2, 10):
            self.clock.return_value = started + cycles * 1.6 + 0.0001
            self.controller.animateStatus_(timer)
            self.assertIs(self.button.image(), sb.status_led_image(sb.STATE_ASK, 0))
            self.assertTrue(timer.isValid())
            self.assertEqual(self.button.title(), " Ask")

    def test_waiting_and_blocked_modes_use_the_ask_pulse(self):
        for mode in (AgentMode.WAITING_FOR_INPUT, AgentMode.BLOCKED_ERROR):
            self.controller.set_status(sb.state_for_mode(mode))
            self.assertTrue(self.controller.status_animation_timer.isValid())
            self.assertIs(self.button.image(), sb.status_led_image(sb.STATE_ASK, 0))

    def test_ask_clears_immediately_when_work_resumes_or_completes(self):
        for state in (sb.STATE_WORKING, sb.STATE_DONE):
            self.controller.set_status(sb.STATE_ASK)
            timer = self.controller.status_animation_timer
            self.controller.set_status(state)
            self.controller.animateStatus_(timer)
            self.assertFalse(timer.isValid())
            self.assertTrue(self.controller.status_animation_timer.isValid())
            self.assertIs(self.button.image(), sb.status_led_image(state, 0))
            self.assertEqual(self.button.title(), f" {state.label}")

    def test_done_stops_after_one_pulse_and_does_not_replay_on_refresh(self):
        self.controller.set_status(sb.STATE_WORKING)
        working_timer = self.controller.status_animation_timer
        self.controller.set_status(sb.STATE_DONE)
        done_timer = self.controller.status_animation_timer
        self.assertFalse(working_timer.isValid())
        self.assertTrue(done_timer.isValid())
        self.assertIs(self.button.image(), sb.status_led_image(sb.STATE_DONE, 0))
        self.clock.return_value += 9 * sb.STATUS_LED_FRAME_INTERVAL + 0.001
        self.controller.animateStatus_(done_timer)
        self.assertIs(self.button.image(), sb.status_led_image(sb.STATE_DONE, 9))

        self.clock.return_value += 1.0
        self.controller.animateStatus_(done_timer)
        self.assertFalse(done_timer.isValid())
        self.assertIsNone(self.controller.status_animation_timer)
        self.assertIsNone(self.controller.status_animation_started_at)
        self.controller.set_status(sb.STATE_DONE)
        self.assertIsNone(self.controller.status_animation_timer)
        self.assertIs(
            self.button.image(), sb.status_led_image(sb.STATE_DONE, sb.STATUS_LED_DONE_FRAMES)
        )
        self.assertEqual(self.button.title(), " Done")

        self.controller.set_status(sb.STATE_WORKING)
        self.controller.set_status(sb.STATE_DONE)
        self.assertTrue(self.controller.status_animation_timer.isValid())

    def test_idle_interrupts_animation_and_keeps_its_symbol(self):
        for state in (sb.STATE_WORKING, sb.STATE_ASK, sb.STATE_DONE):
            self.controller.set_status(state)
            timer = self.controller.status_animation_timer
            self.controller.set_status(sb.STATE_IDLE)
            self.controller.animateStatus_(timer)
            self.assertFalse(timer.isValid())
            self.assertIsNone(self.controller.status_animation_timer)
            self.assertIs(
                self.button.image(), sb.image_for_symbol(sb.STATE_IDLE.symbol, sb.STATE_IDLE.label)
            )
            self.assertEqual(self.button.title(), " Idle")

    def test_reduce_motion_uses_steady_leds_without_a_timer(self):
        self.controller.status_reduce_motion = True
        for state, frame in (
            (sb.STATE_WORKING, -1),
            (sb.STATE_ASK, -1),
            (sb.STATE_DONE, sb.STATUS_LED_DONE_FRAMES),
        ):
            self.controller.set_status(state)
            self.assertIsNone(self.controller.status_animation_timer)
            self.assertIs(self.button.image(), sb.status_led_image(state, frame))
            self.assertEqual(len(set(sb.status_led_brightness(state, frame))), 1)

    def test_reduce_motion_toggle_stops_and_resumes_ask(self):
        self.controller.set_status(sb.STATE_ASK)
        timer = self.controller.status_animation_timer
        with patch.object(sb, "NSWorkspace") as workspace_type:
            workspace = workspace_type.sharedWorkspace.return_value
            workspace.accessibilityDisplayShouldReduceMotion.return_value = True
            self.controller.statusDisplayOptionsChanged_(None)
            self.assertFalse(timer.isValid())
            self.assertIsNone(self.controller.status_animation_timer)
            self.assertIs(self.button.image(), sb.status_led_image(sb.STATE_ASK, -1))

            workspace.accessibilityDisplayShouldReduceMotion.return_value = False
            self.controller.statusDisplayOptionsChanged_(None)
            self.assertTrue(self.controller.status_animation_timer.isValid())
            self.assertIs(self.button.image(), sb.status_led_image(sb.STATE_ASK, 0))

    def test_display_notifications_apply_immediately_without_replaying_done(self):
        center = sb.NSWorkspace.sharedWorkspace().notificationCenter()
        notification = sb.NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
        with patch.object(sb, "NSWorkspace") as workspace_type:
            workspace = workspace_type.sharedWorkspace.return_value
            workspace.notificationCenter.return_value = center
            workspace.accessibilityDisplayShouldReduceMotion.return_value = False
            self.controller.start_status_display_notifications()
            self.controller.start_status_display_notifications()
            self.controller.set_status(sb.STATE_WORKING)
            timer = self.controller.status_animation_timer

            workspace.accessibilityDisplayShouldReduceMotion.return_value = True
            center.postNotificationName_object_(notification, None)
            self.assertTrue(self.controller.status_reduce_motion)
            self.assertFalse(timer.isValid())
            self.assertIsNone(self.controller.status_animation_timer)
            self.assertIs(self.button.image(), sb.status_led_image(sb.STATE_WORKING, -1))

            self.controller.set_status(sb.STATE_DONE)
            workspace.accessibilityDisplayShouldReduceMotion.return_value = False
            center.postNotificationName_object_(notification, None)
            self.assertIsNone(self.controller.status_animation_timer)
            self.controller.set_status(sb.STATE_WORKING)
            self.assertTrue(self.controller.status_animation_timer.isValid())

            self.controller.stop_status_display()
            workspace.accessibilityDisplayShouldReduceMotion.return_value = True
            center.postNotificationName_object_(notification, None)
            self.assertFalse(self.controller.status_reduce_motion)
            self.assertIsNone(self.controller.status_animation_timer)

    def test_timer_is_registered_in_common_run_loop_modes(self):
        with patch.object(sb, "NSRunLoop") as run_loop:
            self.controller.set_status(sb.STATE_WORKING)
        run_loop.mainRunLoop.return_value.addTimer_forMode_.assert_called_once_with(
            self.controller.status_animation_timer, sb.NSRunLoopCommonModes
        )

    def test_sleep_stops_animation_and_wake_does_not_replay_done(self):
        self.controller.leds_enabled = False
        self.controller.refresh_ = Mock(
            side_effect=lambda _: self.controller.set_status(self.controller.current_state)
        )
        for state in (sb.STATE_WORKING, sb.STATE_ASK, sb.STATE_DONE):
            self.controller.set_status(state)
            timer = self.controller.status_animation_timer
            self.controller.systemWillSleep_(None)
            self.assertFalse(timer.isValid())
            self.assertIsNone(self.controller.status_animation_timer)
            self.controller.systemDidWake_(None)
            if state != sb.STATE_DONE:
                self.assertTrue(self.controller.status_animation_timer.isValid())
            else:
                self.assertIsNone(self.controller.status_animation_timer)
                self.assertIs(
                    self.button.image(),
                    sb.status_led_image(sb.STATE_DONE, sb.STATUS_LED_DONE_FRAMES),
                )

    def test_termination_stops_animation_and_prevents_restarting_it(self):
        self.controller.set_status(sb.STATE_WORKING)
        timer = self.controller.status_animation_timer
        with patch.object(sb.threading, "Thread"):
            self.controller.applicationShouldTerminate_(None)
        self.assertFalse(timer.isValid())
        self.assertIsNone(self.controller.status_animation_timer)
        for state in (sb.STATE_WORKING, sb.STATE_ASK):
            self.controller.set_status(state)
            self.assertIsNone(self.controller.status_animation_timer)

    def test_missing_status_item_stops_animation(self):
        self.controller.set_status(sb.STATE_WORKING)
        timer = self.controller.status_animation_timer
        self.controller.status_item = None
        self.controller.animateStatus_(timer)
        self.assertFalse(timer.isValid())
        self.assertIsNone(self.controller.status_animation_timer)

    def test_native_status_item_keeps_the_same_width_in_every_state(self):
        self.controller.create_status_item()
        item = self.controller.status_item
        self.addCleanup(sb.NSStatusBar.systemStatusBar().removeStatusItem_, item)
        width = item.length()
        self.assertGreater(width, 0)
        for state in (sb.STATE_WORKING, sb.STATE_DONE, sb.STATE_ASK, sb.STATE_IDLE):
            self.controller.set_status(state)
            self.assertEqual(item.length(), width)
            self.assertEqual(item.button().frame().size.width, width)
            self.assertGreaterEqual(width, item.button().cell().cellSize().width)
            self.assertEqual(item.button().title(), f" {state.label}")


class PureUiLogicTests(unittest.TestCase):
    """Label and formatting helpers -- no AppKit objects, fast and exhaustive."""

    def test_remote_authentication_creates_reusable_control_master(self):
        remote = HerdrRemoteSetting(
            "remote-1",
            "Workbox",
            "user@workbox",
        )
        marker = Path("/tmp/sidepulse-auth-marker")
        acknowledgement = Path("/tmp/sidepulse-auth-ack")
        cancellation = Path("/tmp/sidepulse-auth-cancel")
        control_path = Path("/tmp/sidepulse-auth-control")

        command = sb.herdr_authentication_command(
            remote,
            marker,
            acknowledgement,
            cancellation,
            control_path,
        )
        args = shlex.split(command)
        script = args[2]

        self.assertEqual(args[:2], ["/bin/sh", "-c"])
        self.assertIn("BatchMode=no", script)
        self.assertIn("ControlMaster=auto", script)
        self.assertIn(
            f"ControlPersist={sb.HERDR_SSH_CONTROL_PERSIST_SECONDS}",
            script,
        )
        self.assertIn(
            f"ServerAliveInterval={sb.HERDR_SSH_SERVER_ALIVE_INTERVAL_SECONDS}",
            script,
        )
        self.assertIn(
            f"ServerAliveCountMax={sb.HERDR_SSH_SERVER_ALIVE_COUNT_MAX}",
            script,
        )
        self.assertIn('-- "user@workbox" true', script)
        self.assertIn(str(control_path), script)
        self.assertIn(str(marker), script)
        self.assertIn(str(acknowledgement), script)
        self.assertIn(str(cancellation), script)
        self.assertIn('kill -TERM "$ssh_pid"', script)
        self.assertIn("-O exit", script)
        syntax = subprocess.run(
            ["/bin/sh", "-n", "-c", script],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(syntax.returncode, 0, syntax.stderr)

    def test_remote_authentication_cancel_interrupts_terminal_ssh(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_ssh = fake_bin / "ssh"
            pid_file = root / "ssh.pid"
            terminated_file = root / "ssh.terminated"
            fake_ssh.write_text(
                "#!/bin/sh\n"
                'case " $* " in *" -O exit "*) exit 0;; esac\n'
                'printf "%s" "$$" > "$FAKE_SSH_PID_FILE"\n'
                'trap \'printf terminated > "$FAKE_SSH_TERM_FILE"; exit 143\' TERM\n'
                "while :; do sleep 1; done\n",
                encoding="utf-8",
            )
            fake_ssh.chmod(0o700)
            remote = HerdrRemoteSetting(
                "remote-1",
                "Workbox",
                "user@workbox",
            )
            marker = root / "marker"
            acknowledgement = root / "acknowledgement"
            cancellation = root / "cancellation"
            control_path = root / "control"
            command = sb.herdr_authentication_command(
                remote,
                marker,
                acknowledgement,
                cancellation,
                control_path,
            )
            env = dict(os.environ)
            env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
            env["FAKE_SSH_PID_FILE"] = str(pid_file)
            env["FAKE_SSH_TERM_FILE"] = str(terminated_file)
            shell = ["/bin/sh", "-c", command]
            if Path("/bin/csh").exists():
                shell = ["/bin/csh", "-f", "-c", command]
            process = subprocess.Popen(
                shell,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                env=env,
                text=True,
            )
            try:
                deadline = time.monotonic() + 2
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(pid_file.exists())

                cancellation.touch()
                _, stderr = process.communicate(timeout=4)

                self.assertTrue(terminated_file.exists(), stderr)
                self.assertFalse(cancellation.exists())
                self.assertFalse(marker.exists())
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=2)

    def test_format_byte_count_is_monotonic_and_labelled(self):
        for size in (0, 1, 1023, 1024, 1024**2, 1024**3, 1024**4):
            with self.subTest(size=size):
                text = sb.format_byte_count(size)
                self.assertTrue(text)
                self.assertRegex(text, r"\d")

    def test_terminal_app_labels_exist_for_every_choice(self):
        for app in sb.TERMINAL_APP_CHOICES:
            with self.subTest(app=app):
                self.assertTrue(sb.terminal_app_label(app))
                self.assertTrue(sb.terminal_app_menu_label(app))

    def test_provider_open_actions_have_labels(self):
        for provider in ("claude", "codex", "grok"):
            actions = sb.provider_open_actions(provider)
            self.assertTrue(actions, f"{provider} has no open actions")
            self.assertIn(sb.default_provider_open_action(provider), actions)
            for action in actions:
                with self.subTest(provider=provider, action=action):
                    self.assertTrue(sb.provider_open_action_label(provider, action))

    def test_device_name_disambiguation(self):
        # macOS mounts a second volume of the same name as "NAME 1", so both
        # devices report display name "SIDEPULSE" but differ by mount root.
        first = make_device("SIDEPULSE", device_id="one")
        second = make_device("SIDEPULSE", device_id="two")
        second = sb.StatusBarDevice(
            **{
                **second.__dict__,
                "root": Path("/Volumes/SIDEPULSE 1"),
                "target": Path("/Volumes/SIDEPULSE 1/leds.txt"),
            }
        )
        result = sb.disambiguate_device_names([first, second])
        self.assertEqual(2, len(result))
        self.assertEqual(
            2,
            len({device.name for device in result}),
            "duplicate device names must be made distinct in the menu",
        )

    def test_distinct_device_names_are_left_alone(self):
        devices = [make_device("ALPHA"), make_device("BETA")]
        result = sb.disambiguate_device_names(devices)
        self.assertEqual(["ALPHA", "BETA"], [device.name for device in result])

    def test_applescript_quote_escapes_injection(self):
        """Session titles reach AppleScript; quoting must not let them break out."""
        quoted = sb.applescript_quote('evil" & do shell script "rm -rf /')
        self.assertTrue(quoted.startswith('"') and quoted.endswith('"'))
        self.assertNotIn('" & do shell script "', quoted)

    def test_normalize_match_text_is_stable(self):
        self.assertEqual(
            sb.normalize_match_text("  Mixed CASE  "),
            sb.normalize_match_text("mixed case"),
        )


if __name__ == "__main__":
    unittest.main()
