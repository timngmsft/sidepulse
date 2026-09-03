from __future__ import annotations

import io
import json
import queue
import subprocess
import tempfile
import textwrap
import threading
import time
import unittest
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from sidepulse.collector import LiveAgentMonitor, snapshot_from_statuses
from sidepulse.models import (
    AgentMode,
    AgentStatus,
    SOURCE_KIND_HERDR_REMOTE,
)
from sidepulse.remote_herdr import (
    HerdrAgentObservation,
    HerdrAgentSnapshot,
    HerdrCommandClient,
    HerdrConnectionStatus,
    HerdrConnectionState,
    HerdrErrorEnvelope,
    HerdrIncompatibleResponse,
    HerdrInvalidPathOverride,
    HerdrRemoteManager,
    HerdrRemoteTestResult,
    HerdrRemoteWorker,
    HerdrResponseError,
    HerdrStatusReducer,
    HerdrTransportError,
    _LineEvent,
    _read_bounded_lines,
    build_discovery_script,
    build_poll_script,
    build_ssh_args,
    herdr_agent_id,
    herdr_ssh_control_path,
    parse_herdr_record,
    parse_probe_output,
    validate_remote_path,
    validate_ssh_target,
)
from sidepulse.session_actions import (
    available_session_open_actions,
    session_deep_link,
    session_resume_command,
    session_vscode_link,
)
from sidepulse.settings import (
    AgentMonitorSettings,
    HerdrRemoteSetting,
    load_settings,
    new_herdr_remote,
    save_settings,
)


def agent_payload(
    *,
    agent: str = "copilot",
    state: str = "working",
    terminal_id: str = "term-1",
    title: str = "Remote task - GitHub Copilot",
) -> dict[str, object]:
    return {
        "agent": agent,
        "agent_status": state,
        "terminal_id": terminal_id,
        "cwd": "/work/repo",
        "foreground_cwd": "/work/repo",
        "terminal_title": title,
        "terminal_title_stripped": title,
        "pane_id": "w1:p1",
        "tab_id": "w1:t1",
        "workspace_id": "w1",
        "focused": False,
        "revision": 2,
        "state_change_seq": 3,
    }


def success_line(*agents: dict[str, object]) -> str:
    return json.dumps(
        {
            "id": "cli:agent:list",
            "result": {"type": "agent_list", "agents": list(agents)},
        }
    )


def error_line(code: str = "server_not_running") -> str:
    return json.dumps(
        {
            "id": "cli:agent:list",
            "error": {"code": code, "message": f"error: {code}"},
        }
    )


class FakeProcess:
    def __init__(
        self,
        *,
        stdout: bytes = b"",
        stderr: bytes = b"",
        returncode: int = 0,
    ) -> None:
        self.stdout = io.BytesIO(stdout)
        self.stderr = io.BytesIO(stderr)
        self.returncode = returncode
        self.terminated = False

    def wait(self, timeout=None):
        return self.returncode

    def poll(self):
        return self.returncode

    def terminate(self):
        self.terminated = True

    def kill(self):
        self.terminated = True


class BlockingProcess(FakeProcess):
    def __init__(self) -> None:
        super().__init__()
        self.returncode = None
        self.started = threading.Event()

    def wait(self, timeout=None):
        self.started.set()
        if self.returncode is None:
            raise subprocess.TimeoutExpired("ssh", timeout)
        return self.returncode

    def terminate(self):
        self.terminated = True
        self.returncode = -15

    def kill(self):
        self.terminated = True
        self.returncode = -9


class SequencedProcessFactory:
    def __init__(self, processes: list[FakeProcess]) -> None:
        self.processes = list(processes)
        self.calls: list[list[str]] = []

    def __call__(self, args, **_kwargs):
        self.calls.append(list(args))
        return self.processes.pop(0)


class RemoteSettingsTests(unittest.TestCase):
    def test_settings_round_trip_herdr_remotes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "settings.json"
            remote = new_herdr_remote(
                name="Workbox",
                ssh_target="workbox",
                session="agents",
                resolved_herdr_path="/opt/homebrew/bin/herdr",
            )
            settings = AgentMonitorSettings(herdr_remotes=(remote,))

            save_settings(settings, path)

            self.assertEqual(load_settings(path), settings)

    def test_default_session_is_normalized(self) -> None:
        remote = new_herdr_remote(
            name="Workbox",
            ssh_target="workbox",
            session="default",
        )

        self.assertEqual(remote.session, "")
        self.assertEqual(remote.to_dict()["session"], "")


class RemoteCommandTests(unittest.TestCase):
    def test_command_validation_and_ssh_option_terminator(self) -> None:
        self.assertEqual(validate_ssh_target("user@workbox"), "user@workbox")
        self.assertEqual(validate_remote_path("/opt/herdr"), "/opt/herdr")
        with self.assertRaises(ValueError):
            validate_ssh_target("bad\nhost")
        with self.assertRaises(ValueError):
            validate_remote_path("relative/herdr")

        control_path = Path("/tmp/sidepulse-test-control")
        args = build_ssh_args(
            "-oProxyCommand=id",
            "true",
            control_path=control_path,
        )

        self.assertEqual(args[-3:], ["--", "-oProxyCommand=id", "true"])
        self.assertIn("BatchMode=yes", args)
        self.assertIn("ControlMaster=auto", args)
        self.assertIn("ServerAliveInterval=10", args)
        self.assertIn("ServerAliveCountMax=3", args)
        self.assertIn(str(control_path), args)

    def test_control_paths_are_stable_private_and_namespaced(self) -> None:
        first = herdr_ssh_control_path("remote-1", "workbox")
        repeated = herdr_ssh_control_path("remote-1", "workbox")
        second = herdr_ssh_control_path("remote-2", "workbox")
        changed_target = herdr_ssh_control_path("remote-1", "buildbox")
        auth_attempt = herdr_ssh_control_path(
            "remote-1",
            "workbox",
            "auth-attempt",
        )

        self.assertEqual(first, repeated)
        self.assertNotEqual(first, second)
        self.assertNotEqual(first, changed_target)
        self.assertNotEqual(first, auth_attempt)
        self.assertEqual(first.parent.stat().st_mode & 0o777, 0o700)

    def test_cancelled_probe_terminates_in_flight_ssh(self) -> None:
        process = BlockingProcess()
        client = HerdrCommandClient(
            process_factory=SequencedProcessFactory([process])
        )
        remote = HerdrRemoteSetting(
            "remote-1",
            "Workbox",
            "workbox",
            herdr_path_override="/usr/bin/herdr",
        )
        cancel_event = threading.Event()
        observed: list[object | None] = []
        errors: list[Exception] = []

        def run_probe() -> None:
            try:
                client.test_remote(
                    remote,
                    cancel_event=cancel_event,
                    process_observer=observed.append,
                )
            except Exception as exc:
                errors.append(exc)

        thread = threading.Thread(target=run_probe)
        thread.start()
        self.assertTrue(process.started.wait(timeout=1))

        cancel_event.set()
        thread.join(timeout=2)

        self.assertFalse(thread.is_alive())
        self.assertTrue(process.terminated)
        self.assertIs(observed[0], process)
        self.assertIsNone(observed[-1])
        self.assertIsInstance(errors[0], HerdrTransportError)
        self.assertIn("cancelled", str(errors[0]).lower())

    def test_pre_cancelled_probe_does_not_start_ssh(self) -> None:
        factory = SequencedProcessFactory([])
        client = HerdrCommandClient(process_factory=factory)
        remote = HerdrRemoteSetting(
            "remote-1",
            "Workbox",
            "workbox",
            herdr_path_override="/usr/bin/herdr",
        )
        cancel_event = threading.Event()
        cancel_event.set()

        with self.assertRaisesRegex(HerdrTransportError, "cancelled"):
            client.test_remote(remote, cancel_event=cancel_event)

        self.assertEqual(factory.calls, [])

    def test_failed_master_close_unlinks_socket_before_retry(self) -> None:
        client = HerdrCommandClient()
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        with tempfile.TemporaryDirectory() as tmp:
            control_path = Path(tmp) / "control"
            control_path.touch()

            with patch(
                "sidepulse.remote_herdr.subprocess.run",
                side_effect=subprocess.TimeoutExpired("ssh", 2),
            ):
                client.close_control_master(
                    remote,
                    control_path=control_path,
                )

            self.assertFalse(control_path.exists())

    def test_poll_script_is_newline_free_and_forwards_errors(self) -> None:
        script = build_poll_script("/opt/herdr", "agents")

        self.assertNotIn("\n", script)
        self.assertIn("/opt/herdr --session agents agent list 2>&1 | cat || exit", script)
        self.assertIn("[ -x /opt/herdr ] || exit 127", script)

    def test_discovery_script_reports_all_candidates(self) -> None:
        script = build_discovery_script()

        self.assertNotIn("\n", script)
        self.assertIn("SIDEPULSE_HERDR_CANDIDATE", script)
        self.assertNotIn("exit 0", script)

    def test_probe_parser_requires_one_supported_os(self) -> None:
        remote_os, candidates = parse_probe_output(
            "\n".join(
                [
                    "noise",
                    "SIDEPULSE_REMOTE_OS=Linux",
                    "SIDEPULSE_HERDR_CANDIDATE=/old/herdr",
                    "SIDEPULSE_HERDR_CANDIDATE=/good/herdr",
                ]
            ),
            require_candidates=True,
        )

        self.assertEqual(remote_os, "Linux")
        self.assertEqual(candidates, ("/old/herdr", "/good/herdr"))

    def test_command_client_tries_candidates_until_one_is_usable(self) -> None:
        factory = SequencedProcessFactory(
            [
                FakeProcess(
                    stdout=(
                        b"SIDEPULSE_REMOTE_OS=Linux\n"
                        b"SIDEPULSE_HERDR_CANDIDATE=/old/herdr\n"
                        b"SIDEPULSE_HERDR_CANDIDATE=/good/herdr\n"
                    )
                ),
                FakeProcess(stdout=b"old cli output\n", returncode=2),
                FakeProcess(
                    stdout=(error_line() + "\n").encode(),
                    returncode=1,
                ),
            ]
        )
        client = HerdrCommandClient(process_factory=factory)
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")

        result = client.test_remote(remote)

        self.assertEqual(result.setting.resolved_herdr_path, "/good/herdr")
        self.assertEqual(
            result.connection.state,
            HerdrConnectionState.HERDR_NOT_RUNNING,
        )
        self.assertEqual(len(factory.calls), 3)

    def test_override_skips_candidate_discovery(self) -> None:
        factory = SequencedProcessFactory(
            [
                FakeProcess(stdout=b"SIDEPULSE_REMOTE_OS=Linux\n"),
                FakeProcess(
                    stdout=(error_line() + "\n").encode(),
                    returncode=1,
                ),
            ]
        )
        client = HerdrCommandClient(process_factory=factory)
        remote = HerdrRemoteSetting(
            "remote-1",
            "Workbox",
            "workbox",
            herdr_path_override="/custom/herdr",
        )

        result = client.test_remote(remote)

        self.assertEqual(
            result.connection.state,
            HerdrConnectionState.HERDR_NOT_RUNNING,
        )
        self.assertEqual(len(factory.calls), 2)
        self.assertTrue(
            all(
                "SIDEPULSE_HERDR_CANDIDATE" not in " ".join(call)
                for call in factory.calls
            )
        )

    def test_unknown_error_proves_override_binary_is_compatible(self) -> None:
        factory = SequencedProcessFactory(
            [
                FakeProcess(stdout=b"SIDEPULSE_REMOTE_OS=Linux\n"),
                FakeProcess(
                    stdout=(error_line("agent_not_found") + "\n").encode(),
                    returncode=1,
                ),
            ]
        )
        client = HerdrCommandClient(process_factory=factory)
        remote = HerdrRemoteSetting(
            "remote-1",
            "Workbox",
            "workbox",
            herdr_path_override="/custom/herdr",
        )

        result = client.test_remote(remote)

        self.assertEqual(
            result.connection.state,
            HerdrConnectionState.REMOTE_ERROR,
        )
        self.assertEqual(result.connection.message, "error: agent_not_found")
        self.assertEqual(result.setting.herdr_path_override, "/custom/herdr")
        self.assertEqual(len(factory.calls), 2)

    def test_invalid_override_is_reported_without_running_ssh(self) -> None:
        factory = SequencedProcessFactory([])
        client = HerdrCommandClient(process_factory=factory)
        remote = HerdrRemoteSetting(
            "remote-1",
            "Workbox",
            "workbox",
            herdr_path_override="relative/herdr",
        )

        with self.assertRaises(HerdrInvalidPathOverride):
            client.test_remote(remote)

        self.assertEqual(factory.calls, [])

    def test_invalid_cached_path_is_discarded_and_rediscovered(self) -> None:
        factory = SequencedProcessFactory(
            [
                FakeProcess(
                    stdout=(
                        b"SIDEPULSE_REMOTE_OS=Linux\n"
                        b"SIDEPULSE_HERDR_CANDIDATE=/good/herdr\n"
                    )
                ),
                FakeProcess(
                    stdout=(error_line() + "\n").encode(),
                    returncode=1,
                ),
            ]
        )
        client = HerdrCommandClient(process_factory=factory)
        remote = HerdrRemoteSetting(
            "remote-1",
            "Workbox",
            "workbox",
            resolved_herdr_path="relative/herdr",
        )

        result = client.test_remote(remote, use_cached_path=True)

        self.assertEqual(result.setting.resolved_herdr_path, "/good/herdr")
        self.assertEqual(len(factory.calls), 2)

    def test_process_start_failure_is_a_transport_error(self) -> None:
        def fail_to_start(*_args, **_kwargs):
            raise OSError("ssh unavailable")

        client = HerdrCommandClient(process_factory=fail_to_start)

        with self.assertRaises(HerdrTransportError):
            client.run("workbox", "true")


class ResponseParsingTests(unittest.TestCase):
    def test_success_response_is_validated_as_a_whole(self) -> None:
        record = parse_herdr_record(success_line(agent_payload()))

        self.assertIsInstance(record, HerdrAgentSnapshot)
        self.assertEqual(record.agents[0].agent, "copilot")
        self.assertEqual(record.agents[0].state, "working")

        malformed = agent_payload()
        malformed.pop("terminal_id")
        with self.assertRaises(HerdrResponseError):
            parse_herdr_record(success_line(agent_payload(), malformed))

    def test_duplicate_identity_rejects_snapshot(self) -> None:
        with self.assertRaises(HerdrResponseError):
            parse_herdr_record(
                success_line(
                    agent_payload(),
                    agent_payload(title="Another title"),
                )
            )

    def test_error_response_is_typed(self) -> None:
        record = parse_herdr_record(error_line("server_not_running"))

        self.assertEqual(
            record,
            HerdrErrorEnvelope(
                code="server_not_running",
                message="error: server_not_running",
            ),
        )

    def test_wrong_envelope_id_is_rejected(self) -> None:
        with self.assertRaises(HerdrResponseError):
            parse_herdr_record(
                json.dumps(
                    {
                        "id": "something-else",
                        "result": {"type": "agent_list", "agents": []},
                    }
                )
            )


class ReducerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        self.reducer = HerdrStatusReducer(self.remote)
        self.now = datetime(2026, 9, 1, 12, tzinfo=timezone.utc)

    def observation(self, state: str, **kwargs) -> HerdrAgentObservation:
        values = agent_payload(state=state, **kwargs)
        return HerdrAgentObservation(
            agent=str(values["agent"]),
            state=str(values["agent_status"]),
            terminal_id=str(values["terminal_id"]),
            cwd=str(values["cwd"]),
            foreground_cwd=str(values["foreground_cwd"]),
            terminal_title=str(values["terminal_title"]),
            terminal_title_stripped=str(values["terminal_title_stripped"]),
            pane_id=str(values["pane_id"]),
            tab_id=str(values["tab_id"]),
            workspace_id=str(values["workspace_id"]),
            focused=bool(values["focused"]),
            revision=int(values["revision"]),
            state_change_seq=int(values["state_change_seq"]),
        )

    def test_initial_settled_state_is_suppressed(self) -> None:
        result = self.reducer.apply(
            HerdrAgentSnapshot((self.observation("done"),)),
            observed_at=self.now,
        )

        self.assertEqual(result.statuses, ())

    def test_working_blocked_and_completion_transitions(self) -> None:
        working = self.reducer.apply(
            HerdrAgentSnapshot((self.observation("working"),)),
            observed_at=self.now,
        )
        blocked = self.reducer.apply(
            HerdrAgentSnapshot((self.observation("blocked"),)),
            observed_at=self.now + timedelta(seconds=2),
        )
        completed = self.reducer.apply(
            HerdrAgentSnapshot((self.observation("idle"),)),
            observed_at=self.now + timedelta(seconds=4),
        )

        self.assertEqual(working.statuses[0].mode, AgentMode.WORKING)
        self.assertEqual(blocked.statuses[0].mode, AgentMode.WAITING_FOR_INPUT)
        self.assertEqual(completed.statuses[0].mode, AgentMode.COMPLETED)

    def test_completed_survives_raw_done_to_idle_churn(self) -> None:
        self.reducer.apply(
            HerdrAgentSnapshot((self.observation("working"),)),
            observed_at=self.now,
        )
        completed = self.reducer.apply(
            HerdrAgentSnapshot((self.observation("done"),)),
            observed_at=self.now + timedelta(seconds=2),
        ).statuses[0]
        settled = self.reducer.apply(
            HerdrAgentSnapshot((self.observation("idle"),)),
            observed_at=self.now + timedelta(seconds=4),
        )

        self.assertEqual(settled.statuses[0].mode, AgentMode.COMPLETED)
        self.assertEqual(settled.statuses[0].updated_at, completed.updated_at)
        self.assertEqual(
            settled.statuses[0].last_observed_at,
            self.now + timedelta(seconds=4),
        )
        self.assertFalse(settled.refresh_needed)

    def test_authoritative_absence_removes_status(self) -> None:
        self.reducer.apply(
            HerdrAgentSnapshot((self.observation("working"),)),
            observed_at=self.now,
        )

        result = self.reducer.apply(HerdrAgentSnapshot(()), observed_at=self.now)

        self.assertEqual(result.statuses, ())
        self.assertTrue(result.refresh_needed)

    def test_reconnect_baseline_preserves_unchanged_mode_age(self) -> None:
        initial = self.reducer.apply(
            HerdrAgentSnapshot((self.observation("working"),)),
            observed_at=self.now,
        ).statuses[0]
        self.reducer.rearm_baseline(preserve_published=True)

        result = self.reducer.apply(
            HerdrAgentSnapshot((self.observation("working"),)),
            observed_at=self.now + timedelta(seconds=30),
        )

        self.assertEqual(result.statuses[0].updated_at, initial.updated_at)
        self.assertEqual(
            result.statuses[0].last_observed_at,
            self.now + timedelta(seconds=30),
        )
        self.assertFalse(result.refresh_needed)

    def test_reconnect_baseline_preserves_unexpired_completion(self) -> None:
        self.reducer.apply(
            HerdrAgentSnapshot((self.observation("working"),)),
            observed_at=self.now,
        )
        completed = self.reducer.apply(
            HerdrAgentSnapshot((self.observation("done"),)),
            observed_at=self.now + timedelta(seconds=2),
        ).statuses[0]
        self.reducer.rearm_baseline(preserve_published=True)

        result = self.reducer.apply(
            HerdrAgentSnapshot((self.observation("done"),)),
            observed_at=self.now + timedelta(seconds=30),
        )

        self.assertEqual(result.statuses[0].mode, AgentMode.COMPLETED)
        self.assertEqual(result.statuses[0].updated_at, completed.updated_at)
        self.assertEqual(
            result.statuses[0].last_observed_at,
            self.now + timedelta(seconds=30),
        )
        self.assertFalse(result.refresh_needed)

    def test_metadata_change_refreshes_without_advancing_mode_age(self) -> None:
        initial = self.reducer.apply(
            HerdrAgentSnapshot((self.observation("working"),)),
            observed_at=self.now,
        ).statuses[0]
        moved = replace(
            self.observation("working"),
            terminal_title="Renamed task",
            terminal_title_stripped="Renamed task",
            pane_id="w2:p4",
            tab_id="w2:t2",
            workspace_id="w2",
            focused=True,
        )

        result = self.reducer.apply(
            HerdrAgentSnapshot((moved,)),
            observed_at=self.now + timedelta(seconds=2),
        )

        status = result.statuses[0]
        self.assertEqual(status.updated_at, initial.updated_at)
        self.assertEqual(status.display_name, "Renamed task")
        self.assertEqual(status.pane_id, "w2:p4")
        self.assertTrue(status.focused)
        self.assertTrue(result.refresh_needed)

    def test_pane_move_does_not_change_identity(self) -> None:
        original = self.observation("working")
        moved = replace(
            original,
            pane_id="w2:p8",
            tab_id="w2:t3",
            workspace_id="w2",
        )

        self.assertEqual(
            herdr_agent_id(self.remote.remote_id, original),
            herdr_agent_id(self.remote.remote_id, moved),
        )

    def test_agent_kind_replacement_removes_old_identity(self) -> None:
        self.reducer.apply(
            HerdrAgentSnapshot((self.observation("working"),)),
            observed_at=self.now,
        )

        result = self.reducer.apply(
            HerdrAgentSnapshot(
                (
                    replace(
                        self.observation("working"),
                        agent="claude",
                    ),
                )
            ),
            observed_at=self.now + timedelta(seconds=2),
        )

        self.assertEqual(len(result.statuses), 1)
        self.assertTrue(result.statuses[0].agent_id.endswith(":claude"))


class CollectorIntegrationTests(unittest.TestCase):
    def remote_status(
        self,
        *,
        mode: AgentMode,
        updated_at: datetime,
        observed_at: datetime,
    ) -> AgentStatus:
        return AgentStatus(
            provider="copilot",
            agent_id="herdr:remote-1:term-1:copilot",
            display_name="Remote task",
            mode=mode,
            updated_at=updated_at,
            last_observed_at=observed_at,
            event_name="HerdrWorking",
            origin="Workbox via Herdr",
            source_kind=SOURCE_KIND_HERDR_REMOTE,
            source_id="remote-1",
        )

    def test_remote_working_freshness_uses_last_observed_at(self) -> None:
        now = datetime(2026, 9, 1, 12, tzinfo=timezone.utc)
        status = self.remote_status(
            mode=AgentMode.WORKING,
            updated_at=now - timedelta(hours=2),
            observed_at=now,
        )

        snapshot = snapshot_from_statuses(
            (status,),
            sources=(),
            collected_at=now,
            stale_after_seconds=60,
            tool_running_timeout_seconds=0,
            completed_visible_seconds=1200,
            idle_visible_seconds=0,
        )

        self.assertEqual(snapshot.statuses, (status,))

    def test_remote_waiting_expires_from_mode_age_while_still_observed(self) -> None:
        now = datetime(2026, 9, 1, 12, tzinfo=timezone.utc)
        status = self.remote_status(
            mode=AgentMode.WAITING_FOR_INPUT,
            updated_at=now - timedelta(hours=2),
            observed_at=now,
        )

        snapshot = snapshot_from_statuses(
            (status,),
            sources=(),
            collected_at=now,
            stale_after_seconds=60,
            tool_running_timeout_seconds=0,
            completed_visible_seconds=1200,
            idle_visible_seconds=0,
        )

        self.assertEqual(snapshot.statuses, ())
        self.assertEqual(snapshot.aggregate.mode, AgentMode.IDLE_READY)
        self.assertEqual(snapshot.stale_statuses, (replace(status, stale=True),))

    def test_completed_age_uses_updated_at(self) -> None:
        now = datetime(2026, 9, 1, 12, tzinfo=timezone.utc)
        status = self.remote_status(
            mode=AgentMode.COMPLETED,
            updated_at=now - timedelta(minutes=30),
            observed_at=now,
        )

        snapshot = snapshot_from_statuses(
            (status,),
            sources=(),
            collected_at=now,
            stale_after_seconds=60,
            tool_running_timeout_seconds=0,
            completed_visible_seconds=1200,
            idle_visible_seconds=0,
        )

        self.assertEqual(snapshot.statuses, ())

    def test_remote_reconciliation_does_not_persist(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            latest = Path(tmp) / "latest.json"
            monitor = LiveAgentMonitor(latest_state_path=latest)
            now = datetime.now(timezone.utc)
            remote = self.remote_status(
                mode=AgentMode.WORKING,
                updated_at=now,
                observed_at=now,
            )

            monitor.reconcile_source(
                SOURCE_KIND_HERDR_REMOTE,
                "remote-1",
                (remote,),
            )

            self.assertFalse(latest.exists())

            local = replace(
                remote,
                agent_id="local-1",
                source_kind="local",
                source_id=None,
            )
            monitor.upsert_status(local)
            persisted = json.loads(latest.read_text())
            self.assertEqual(
                [item["agent_id"] for item in persisted["statuses"]],
                ["local-1"],
            )

    def test_previously_persisted_remote_status_is_discarded(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            latest = Path(tmp) / "latest.json"
            now = datetime.now(timezone.utc)
            remote = self.remote_status(
                mode=AgentMode.WORKING,
                updated_at=now,
                observed_at=now,
            )
            local = replace(
                remote,
                agent_id="local-1",
                source_kind="local",
                source_id=None,
            )
            latest.write_text(
                json.dumps(
                    {
                        "updated_at": now.isoformat(),
                        "statuses": [remote.to_dict(now), local.to_dict(now)],
                    }
                )
            )

            monitor = LiveAgentMonitor(latest_state_path=latest)

            self.assertEqual(
                [status.agent_id for status in monitor.snapshot().statuses],
                ["local-1"],
            )


class SessionActionTests(unittest.TestCase):
    def test_remote_status_has_no_local_session_actions(self) -> None:
        status = AgentStatus(
            provider="claude",
            agent_id="herdr:remote-1:term-1:claude",
            display_name="Claude",
            mode=AgentMode.WORKING,
            updated_at=datetime.now(timezone.utc),
            event_name="HerdrWorking",
            session_id="session-1",
            cwd="/remote/project",
            origin="Workbox via Herdr",
            source_kind=SOURCE_KIND_HERDR_REMOTE,
            source_id="remote-1",
        )

        self.assertIsNone(session_deep_link(status))
        self.assertIsNone(session_vscode_link(status))
        self.assertIsNone(session_resume_command(status))
        self.assertEqual(available_session_open_actions(status), ())


class BoundedReaderTests(unittest.TestCase):
    def test_oversized_record_is_discarded_before_next_line(self) -> None:
        events: queue.Queue = queue.Queue()
        _read_bounded_lines(io.BytesIO(b"123456\nok\n"), events, 4)

        observed = []
        while not events.empty():
            observed.append(events.get())

        self.assertTrue(observed[0].oversized)
        self.assertEqual(observed[1].line, b"ok")
        self.assertTrue(observed[2].eof)

    def test_bounded_queue_reader_can_stop_while_backpressured(self) -> None:
        events: queue.Queue = queue.Queue(maxsize=1)
        stop_event = threading.Event()
        thread = threading.Thread(
            target=_read_bounded_lines,
            args=(
                io.BytesIO(b"first\nsecond\nthird\n"),
                events,
                1024,
                stop_event,
            ),
        )
        thread.start()
        deadline = time.time() + 1
        while events.empty() and time.time() < deadline:
            time.sleep(0.01)

        stop_event.set()
        thread.join(timeout=1)

        self.assertFalse(thread.is_alive())


class FakeWorker:
    instances: list["FakeWorker"] = []

    def __init__(
        self,
        setting,
        generation,
        _monitor,
        *,
        is_current,
        control_path,
        **_kwargs,
    ) -> None:
        self.setting = setting
        self.generation = generation
        self.is_current = is_current
        self.control_path = control_path
        self.started = False
        self.stopped = False
        FakeWorker.instances.append(self)

    def start(self):
        self.started = True

    def stop(self, *, wait=True):
        self.stopped = True

    def update_display_name(self, name):
        self.setting = replace(self.setting, name=name)


class BlockingCleanupWorker(FakeWorker):
    cleanup_started = threading.Event()
    cleanup_release = threading.Event()

    def stop(self, *, wait=True):
        self.stopped = True
        if wait:
            self.cleanup_started.set()
            self.cleanup_release.wait(timeout=1)


class BlockingCloseClient:
    ssh_binary = "ssh"

    def __init__(self) -> None:
        self.close_started = threading.Event()
        self.close_release = threading.Event()
        self.closed_paths: list[Path] = []

    def close_control_master(self, _setting, *, control_path=None) -> None:
        self.close_started.set()
        self.close_release.wait(timeout=1)
        self.closed_paths.append(Path(control_path))


class ManagerLifecycleTests(unittest.TestCase):
    def setUp(self) -> None:
        FakeWorker.instances.clear()
        BlockingCleanupWorker.cleanup_started.clear()
        BlockingCleanupWorker.cleanup_release.clear()

    def test_reconfiguration_invalidates_old_worker_and_clears_source(self) -> None:
        monitor = LiveAgentMonitor()
        manager = HerdrRemoteManager(monitor, worker_factory=FakeWorker)
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        manager.apply_settings((remote,))
        first = FakeWorker.instances[-1]
        status = AgentStatus(
            provider="copilot",
            agent_id="herdr:remote-1:term-1:copilot",
            display_name="Task",
            mode=AgentMode.WORKING,
            updated_at=datetime.now(timezone.utc),
            event_name="HerdrWorking",
            source_kind=SOURCE_KIND_HERDR_REMOTE,
            source_id="remote-1",
        )
        monitor.reconcile_source(
            SOURCE_KIND_HERDR_REMOTE,
            "remote-1",
            (status,),
        )

        manager.apply_settings((replace(remote, ssh_target="buildbox"),))

        self.assertTrue(first.stopped)
        self.assertFalse(first.is_current("remote-1", first.generation))
        self.assertEqual(monitor.snapshot().statuses, ())
        self.assertEqual(len(FakeWorker.instances), 2)

    def test_invalid_remote_does_not_prevent_other_workers_from_starting(self) -> None:
        manager = HerdrRemoteManager(
            LiveAgentMonitor(),
            worker_factory=FakeWorker,
        )
        invalid = HerdrRemoteSetting("bad", "Bad", "workbox\ninvalid")
        valid = HerdrRemoteSetting("good", "Good", "workbox")

        manager.apply_settings((invalid, valid))

        self.assertEqual(len(FakeWorker.instances), 1)
        self.assertEqual(FakeWorker.instances[0].setting, valid)
        connection = manager.connection_status("bad")
        self.assertEqual(
            connection.state,
            HerdrConnectionState.INCOMPATIBLE_RESPONSE,
        )
        self.assertIn("Invalid remote configuration", connection.message)

        valid_worker = FakeWorker.instances[0]
        manager.stop(close_control_masters=True, wait=True)

        self.assertTrue(valid_worker.stopped)
        self.assertEqual(manager.workers_by_id, {})

    def test_control_directory_failure_is_isolated_to_remote(self) -> None:
        manager = HerdrRemoteManager(
            LiveAgentMonitor(),
            worker_factory=FakeWorker,
        )
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")

        with patch(
            "sidepulse.remote_herdr.herdr_ssh_control_path",
            side_effect=HerdrTransportError("control directory unavailable"),
        ):
            manager.apply_settings((remote,))

        self.assertEqual(FakeWorker.instances, [])
        connection = manager.connection_status("remote-1")
        self.assertEqual(
            connection.state,
            HerdrConnectionState.SSH_HOST_UNAVAILABLE,
        )
        self.assertEqual(connection.message, "control directory unavailable")

    def test_disable_invalidates_without_starting_replacement(self) -> None:
        manager = HerdrRemoteManager(
            LiveAgentMonitor(),
            worker_factory=FakeWorker,
        )
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        manager.apply_settings((remote,))
        first = FakeWorker.instances[-1]

        manager.apply_settings((replace(remote, enabled=False),))

        self.assertTrue(first.stopped)
        self.assertFalse(first.is_current("remote-1", first.generation))
        self.assertEqual(len(FakeWorker.instances), 1)
        self.assertEqual(
            manager.connection_status("remote-1").state,
            HerdrConnectionState.DISABLED,
        )

    def test_endpoint_change_clears_previous_connection_timestamp(self) -> None:
        manager = HerdrRemoteManager(
            LiveAgentMonitor(),
            worker_factory=FakeWorker,
        )
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        manager.apply_settings((remote,))
        manager._set_connection(
            HerdrConnectionStatus(
                "remote-1",
                HerdrConnectionState.CONNECTED,
                last_success_at=datetime.now(timezone.utc),
            )
        )

        manager.apply_settings((replace(remote, ssh_target="buildbox"),))

        connection = manager.connection_status("remote-1")
        self.assertEqual(connection.state, HerdrConnectionState.CONNECTING)
        self.assertIsNone(connection.last_success_at)

    def test_stale_generation_cannot_commit_status_or_resolved_path(self) -> None:
        resolved_callbacks: list[tuple[str, int, str | None]] = []
        monitor = LiveAgentMonitor()
        manager = HerdrRemoteManager(
            monitor,
            worker_factory=FakeWorker,
            on_resolved_path=lambda remote_id, generation, path: (
                resolved_callbacks.append((remote_id, generation, path))
            ),
        )
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        manager.apply_settings((remote,))
        first = FakeWorker.instances[-1]
        manager.apply_settings((replace(remote, ssh_target="buildbox"),))
        status = AgentStatus(
            provider="copilot",
            agent_id="herdr:remote-1:term-1:copilot",
            display_name="Task",
            mode=AgentMode.WORKING,
            updated_at=datetime.now(timezone.utc),
            event_name="HerdrWorking",
            source_kind=SOURCE_KIND_HERDR_REMOTE,
            source_id="remote-1",
        )

        committed = manager._commit_statuses(
            "remote-1",
            first.generation,
            (status,),
        )
        manager._resolved_path(
            "remote-1",
            first.generation,
            "/old/herdr",
        )

        self.assertIsNone(committed)
        self.assertEqual(monitor.snapshot().statuses, ())
        self.assertIsNone(
            manager.settings_by_id["remote-1"].resolved_herdr_path
        )
        self.assertEqual(resolved_callbacks, [])

    def test_reconfiguration_does_not_wait_for_worker_cleanup(self) -> None:
        manager = HerdrRemoteManager(
            LiveAgentMonitor(),
            worker_factory=BlockingCleanupWorker,
        )
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        manager.apply_settings((remote,))

        started_at = time.monotonic()
        manager.apply_settings((replace(remote, ssh_target="buildbox"),))
        elapsed = time.monotonic() - started_at

        self.assertLess(elapsed, 0.2)
        self.assertTrue(BlockingCleanupWorker.cleanup_started.wait(timeout=1))
        BlockingCleanupWorker.cleanup_release.set()

    def test_reenable_uses_new_control_path_while_old_cleanup_runs(self) -> None:
        client = BlockingCloseClient()
        manager = HerdrRemoteManager(
            LiveAgentMonitor(),
            command_client=client,
            worker_factory=FakeWorker,
        )
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        manager.apply_settings((remote,))
        first = FakeWorker.instances[-1]

        manager.apply_settings((replace(remote, enabled=False),))
        self.assertTrue(client.close_started.wait(timeout=1))
        manager.apply_settings((remote,))
        second = FakeWorker.instances[-1]

        self.assertTrue(second.started)
        self.assertNotEqual(first.control_path, second.control_path)
        client.close_release.set()
        deadline = time.time() + 1
        while not client.closed_paths and time.time() < deadline:
            time.sleep(0.01)
        self.assertEqual(client.closed_paths, [first.control_path])

    def test_stale_transport_reset_cannot_close_replacement_master(self) -> None:
        client = BlockingCloseClient()
        manager = HerdrRemoteManager(
            LiveAgentMonitor(),
            command_client=client,
            worker_factory=FakeWorker,
        )
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        manager.apply_settings((remote,))
        old_worker = FakeWorker.instances[-1]
        old_control_path = old_worker.control_path
        reset_results: list[Path | None] = []

        thread = threading.Thread(
            target=lambda: reset_results.append(
                manager._reset_worker_control_path(
                    remote.remote_id,
                    old_worker.generation,
                    old_worker.setting,
                    old_control_path,
                )
            )
        )
        thread.start()
        self.assertTrue(client.close_started.wait(timeout=1))

        manager.retry(remote.remote_id)
        replacement_worker = FakeWorker.instances[-1]
        self.assertNotEqual(
            replacement_worker.control_path,
            old_control_path,
        )

        client.close_release.set()
        thread.join(timeout=2)

        self.assertFalse(thread.is_alive())
        self.assertEqual(reset_results, [None])
        self.assertEqual(client.closed_paths, [old_control_path])
        self.assertEqual(
            manager.control_path_for(remote),
            replacement_worker.control_path,
        )

    def test_restart_preserves_adopted_authentication_control_path(self) -> None:
        manager = HerdrRemoteManager(
            LiveAgentMonitor(),
            worker_factory=FakeWorker,
        )
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        adopted = herdr_ssh_control_path(
            remote.remote_id,
            remote.ssh_target,
            "authentication",
        )
        manager.adopt_control_path(remote, adopted)
        manager.apply_settings((remote,))

        manager.restart(LiveAgentMonitor(), (remote,))

        self.assertEqual(FakeWorker.instances[-1].control_path, adopted)

    def test_async_control_close_rotates_path_before_reuse(self) -> None:
        client = BlockingCloseClient()
        manager = HerdrRemoteManager(
            LiveAgentMonitor(),
            command_client=client,
            worker_factory=FakeWorker,
        )
        remote = HerdrRemoteSetting("draft-1", "Draft", "workbox")
        first = manager.control_path_for(remote)

        manager.close_control_master(remote, control_path=first)
        second = manager.control_path_for(remote)

        self.assertNotEqual(first, second)
        self.assertTrue(client.close_started.wait(timeout=1))
        client.close_release.set()

    def test_stop_waits_for_previously_scheduled_cleanup(self) -> None:
        client = BlockingCloseClient()
        manager = HerdrRemoteManager(
            LiveAgentMonitor(),
            command_client=client,
            worker_factory=FakeWorker,
        )
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        manager.apply_settings((remote,))
        manager.apply_settings((replace(remote, enabled=False),))
        self.assertTrue(client.close_started.wait(timeout=1))
        stopped = threading.Event()
        errors: list[Exception] = []

        def stop_manager() -> None:
            try:
                manager.stop(close_control_masters=True, wait=True)
            except Exception as exc:
                errors.append(exc)
            finally:
                stopped.set()

        thread = threading.Thread(target=stop_manager)
        thread.start()
        try:
            self.assertFalse(stopped.wait(timeout=0.1))
        finally:
            client.close_release.set()
        thread.join(timeout=2)

        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(manager.pending_cleanup_threads, set())

    def test_cleanup_registration_cannot_be_drained_before_thread_start(self) -> None:
        real_thread_type = threading.Thread
        start_entered = threading.Event()
        allow_start = threading.Event()

        class PausingThread:
            def __init__(self, *args, **kwargs):
                self.inner = real_thread_type(*args, **kwargs)

            def __hash__(self):
                return hash(self.inner)

            def __eq__(self, other):
                return other is self or other is self.inner

            def start(self):
                start_entered.set()
                allow_start.wait(timeout=1)
                self.inner.start()

            def join(self, timeout=None):
                return self.inner.join(timeout=timeout)

        client = BlockingCloseClient()
        client.close_release.set()
        manager = HerdrRemoteManager(
            LiveAgentMonitor(),
            command_client=client,
            worker_factory=FakeWorker,
        )
        remote = HerdrRemoteSetting("draft-1", "Draft", "workbox")
        control_path = manager.control_path_for(remote)
        schedule_errors: list[Exception] = []
        stop_errors: list[Exception] = []
        stopped = threading.Event()

        def schedule_close() -> None:
            try:
                manager.close_control_master(
                    remote,
                    control_path=control_path,
                )
            except Exception as exc:
                schedule_errors.append(exc)

        def stop_manager() -> None:
            try:
                manager.stop(close_control_masters=True, wait=True)
            except Exception as exc:
                stop_errors.append(exc)
            finally:
                stopped.set()

        with patch(
            "sidepulse.remote_herdr.threading.Thread",
            PausingThread,
        ):
            scheduling_thread = real_thread_type(target=schedule_close)
            scheduling_thread.start()
            self.assertTrue(start_entered.wait(timeout=1))
            stopping_thread = real_thread_type(target=stop_manager)
            stopping_thread.start()
            self.assertFalse(stopped.wait(timeout=0.1))
            allow_start.set()
            scheduling_thread.join(timeout=2)
            stopping_thread.join(timeout=2)

        self.assertEqual(schedule_errors, [])
        self.assertEqual(stop_errors, [])
        self.assertTrue(stopped.is_set())
        self.assertEqual(manager.pending_cleanup_threads, set())

    def test_draft_target_test_does_not_displace_live_control_path(self) -> None:
        client = BlockingCloseClient()
        client.close_release.set()
        manager = HerdrRemoteManager(
            LiveAgentMonitor(),
            command_client=client,
            worker_factory=FakeWorker,
        )
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        live_path = herdr_ssh_control_path(
            remote.remote_id,
            remote.ssh_target,
            "live-authentication",
        )
        manager.adopt_control_path(remote, live_path)
        manager.apply_settings((remote,))
        draft = replace(remote, ssh_target="buildbox")
        draft_path = manager.control_path_for(draft)

        manager.apply_settings((draft,))

        self.assertEqual(FakeWorker.instances[-2].control_path, live_path)
        self.assertEqual(FakeWorker.instances[-1].control_path, draft_path)
        self.assertTrue(client.close_started.wait(timeout=1))
        deadline = time.time() + 1
        while not client.closed_paths and time.time() < deadline:
            time.sleep(0.01)
        self.assertEqual(client.closed_paths, [live_path])

    def test_snapshot_after_grace_is_treated_as_a_new_baseline(self) -> None:
        committed: list[tuple[AgentStatus, ...]] = []
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        worker = HerdrRemoteWorker(
            remote,
            1,
            LiveAgentMonitor(),
            command_client=HerdrCommandClient(
                process_factory=SequencedProcessFactory([])
            ),
            control_path=herdr_ssh_control_path(
                remote.remote_id,
                remote.ssh_target,
            ),
            is_current=lambda _remote_id, _generation: True,
            reset_control_path=lambda *_args: None,
            commit_statuses=lambda _remote_id, _generation, statuses: (
                committed.append(statuses) or True
            ),
            on_connection=lambda _generation, _connection: None,
            on_refresh=lambda: None,
            on_resolved_path=lambda _remote_id, _generation, _path: None,
            monotonic=lambda: 0.0,
        )
        working = HerdrAgentSnapshot(
            (
                HerdrAgentObservation(
                    agent="copilot",
                    state="working",
                    terminal_id="term-1",
                ),
            )
        )
        done = HerdrAgentSnapshot(
            (
                HerdrAgentObservation(
                    agent="copilot",
                    state="done",
                    terminal_id="term-1",
                ),
            )
        )

        worker._apply_authoritative_snapshot(
            working,
            observed_at=datetime.now(timezone.utc),
            observed_monotonic=0.0,
        )
        result = worker._apply_authoritative_snapshot(
            done,
            observed_at=datetime.now(timezone.utc),
            observed_monotonic=16.0,
        )

        self.assertIsNotNone(result)
        self.assertEqual(result.statuses, ())
        self.assertTrue(result.refresh_needed)
        self.assertEqual(committed[-1], ())

    def test_probe_result_does_not_revert_concurrent_remote_rename(self) -> None:
        class ProbeClient:
            ssh_binary = "ssh"

            def test_remote(self, setting, **_kwargs):
                return HerdrRemoteTestResult(
                    setting=setting.with_resolved_path("/usr/bin/herdr"),
                    connection=HerdrConnectionStatus(
                        setting.remote_id,
                        HerdrConnectionState.CONNECTED,
                        last_success_at=datetime.now(timezone.utc),
                    ),
                    snapshot=HerdrAgentSnapshot(()),
                )

        remote = HerdrRemoteSetting("remote-1", "Old name", "workbox")
        worker = HerdrRemoteWorker(
            remote,
            1,
            LiveAgentMonitor(),
            command_client=ProbeClient(),
            control_path=herdr_ssh_control_path(
                remote.remote_id,
                remote.ssh_target,
            ),
            is_current=lambda _remote_id, _generation: True,
            reset_control_path=lambda *_args: None,
            commit_statuses=lambda _remote_id, _generation, _statuses: False,
            on_connection=lambda _generation, _connection: None,
            on_refresh=lambda: None,
            on_resolved_path=lambda _remote_id, _generation, _path: None,
        )
        worker.update_display_name("New name")
        worker._monitor_connection = lambda _path: worker.stop_event.set()

        worker._run()

        self.assertEqual(worker.setting.name, "New name")

    def test_stream_incompatibility_rediscovers_once(self) -> None:
        class RediscoveryClient:
            ssh_binary = "ssh"

            def __init__(self) -> None:
                self.settings: list[HerdrRemoteSetting] = []

            def test_remote(self, setting, **_kwargs):
                self.settings.append(setting)
                path = "/cached/herdr" if len(self.settings) == 1 else "/good/herdr"
                updated = setting.with_resolved_path(path)
                return HerdrRemoteTestResult(
                    setting=updated,
                    connection=HerdrConnectionStatus(
                        setting.remote_id,
                        HerdrConnectionState.CONNECTED,
                        last_success_at=datetime.now(timezone.utc),
                    ),
                    snapshot=HerdrAgentSnapshot(()),
                )

        client = RediscoveryClient()
        resolved: list[str | None] = []
        monitored: list[str] = []
        remote = HerdrRemoteSetting(
            "remote-1",
            "Workbox",
            "workbox",
            resolved_herdr_path="/cached/herdr",
        )
        worker = HerdrRemoteWorker(
            remote,
            1,
            LiveAgentMonitor(),
            command_client=client,
            control_path=herdr_ssh_control_path(
                remote.remote_id,
                remote.ssh_target,
            ),
            is_current=lambda _remote_id, _generation: True,
            reset_control_path=lambda *_args: None,
            commit_statuses=lambda _remote_id, _generation, _statuses: False,
            on_connection=lambda _generation, _connection: None,
            on_refresh=lambda: None,
            on_resolved_path=lambda _remote_id, _generation, path: (
                resolved.append(path)
            ),
        )

        def monitor(path: str) -> None:
            monitored.append(path)
            if len(monitored) == 1:
                raise HerdrIncompatibleResponse("bad cached binary")
            worker.stop_event.set()

        worker._monitor_connection = monitor
        worker._run()

        self.assertEqual(monitored, ["/cached/herdr", "/good/herdr"])
        self.assertIsNone(client.settings[1].resolved_herdr_path)
        self.assertIn(None, resolved)

    def test_transport_retry_closes_shared_master_first(self) -> None:
        class RetryClient:
            ssh_binary = "ssh"

            def __init__(self) -> None:
                self.attempts = 0
                self.closed: list[Path] = []
                self.control_paths: list[Path] = []

            def test_remote(self, setting, **kwargs):
                self.attempts += 1
                self.control_paths.append(Path(kwargs["control_path"]))
                if self.attempts == 1:
                    raise HerdrTransportError("network changed")
                resolved = setting.with_resolved_path("/usr/bin/herdr")
                return HerdrRemoteTestResult(
                    setting=resolved,
                    connection=HerdrConnectionStatus(
                        setting.remote_id,
                        HerdrConnectionState.CONNECTED,
                        last_success_at=datetime.now(timezone.utc),
                    ),
                    snapshot=HerdrAgentSnapshot(()),
                )

            def close_control_master(self, _setting, *, control_path=None):
                self.closed.append(Path(control_path))

        client = RetryClient()
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        control_path = herdr_ssh_control_path(
            remote.remote_id,
            remote.ssh_target,
        )
        replacement_control_path = herdr_ssh_control_path(
            remote.remote_id,
            remote.ssh_target,
            "transport-retry",
        )

        def reset_control_path(*_args):
            client.close_control_master(
                remote,
                control_path=control_path,
            )
            return replacement_control_path

        worker = HerdrRemoteWorker(
            remote,
            1,
            LiveAgentMonitor(),
            command_client=client,
            control_path=control_path,
            is_current=lambda _remote_id, _generation: True,
            reset_control_path=reset_control_path,
            commit_statuses=lambda _remote_id, _generation, _statuses: False,
            on_connection=lambda _generation, _connection: None,
            on_refresh=lambda: None,
            on_resolved_path=lambda _remote_id, _generation, _path: None,
        )
        worker._monitor_connection = lambda _path: worker.stop_event.set()

        with patch(
            "sidepulse.remote_herdr.HERDR_RETRY_DELAYS_SECONDS",
            (0.0,),
        ):
            worker._run()

        self.assertEqual(client.attempts, 2)
        self.assertEqual(client.closed, [control_path])
        self.assertEqual(
            client.control_paths,
            [control_path, replacement_control_path],
        )

    def test_stream_unknown_error_is_a_generic_remote_error(self) -> None:
        process = FakeProcess(
            stdout=(error_line("agent_not_found") + "\n").encode(),
            returncode=None,
        )
        connections: list[HerdrConnectionStatus] = []
        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        worker = HerdrRemoteWorker(
            remote,
            1,
            LiveAgentMonitor(),
            command_client=HerdrCommandClient(
                process_factory=SequencedProcessFactory([])
            ),
            control_path=herdr_ssh_control_path(
                remote.remote_id,
                remote.ssh_target,
            ),
            process_factory=lambda *_args, **_kwargs: process,
            is_current=lambda _remote_id, _generation: True,
            reset_control_path=lambda *_args: None,
            commit_statuses=lambda _remote_id, _generation, _statuses: False,
            on_connection=lambda _generation, connection: (
                connections.append(connection)
            ),
            on_refresh=lambda: None,
            on_resolved_path=lambda _remote_id, _generation, _path: None,
        )

        with self.assertRaises(HerdrTransportError):
            worker._monitor_connection("/custom/herdr")

        self.assertEqual(
            connections[0].state,
            HerdrConnectionState.REMOTE_ERROR,
        )
        self.assertEqual(
            connections[0].message,
            "error: agent_not_found",
        )

    def test_each_invalid_record_checks_incompatibility_deadline(self) -> None:
        class EventQueue:
            def __init__(self, line: bytes):
                self.event = _LineEvent(line=line)

            def get(self, timeout=None):
                if self.event is None:
                    raise AssertionError(
                        "monitor requested another event before classifying output"
                    )
                event = self.event
                self.event = None
                return event

        remote = HerdrRemoteSetting("remote-1", "Workbox", "workbox")
        for line in (b"", b"not-json"):
            with self.subTest(line=line):
                times = iter((0.0, 0.0, 11.0))
                process = FakeProcess(returncode=None)
                worker = HerdrRemoteWorker(
                    remote,
                    1,
                    LiveAgentMonitor(),
                    command_client=HerdrCommandClient(
                        process_factory=SequencedProcessFactory([])
                    ),
                    control_path=herdr_ssh_control_path(
                        remote.remote_id,
                        remote.ssh_target,
                    ),
                    process_factory=lambda *_args, **_kwargs: process,
                    is_current=lambda _remote_id, _generation: True,
                    reset_control_path=lambda *_args: None,
                    commit_statuses=lambda _remote_id, _generation, _statuses: False,
                    on_connection=lambda _generation, _connection: None,
                    on_refresh=lambda: None,
                    on_resolved_path=lambda _remote_id, _generation, _path: None,
                    monotonic=lambda: next(times),
                )
                with (
                    patch(
                        "sidepulse.remote_herdr.queue.Queue",
                        return_value=EventQueue(line),
                    ),
                    patch("sidepulse.remote_herdr._read_bounded_lines"),
                    patch("sidepulse.remote_herdr._drain_stderr"),
                    self.assertRaises(HerdrIncompatibleResponse),
                ):
                    worker._monitor_connection("/custom/herdr")

    def test_fake_ssh_stream_drives_working_then_completed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ssh = Path(tmp) / "fake-ssh"
            ssh.write_text(
                textwrap.dedent(
                    f"""\
                    #!/usr/bin/env python3
                    import json
                    import sys
                    import time

                    command = sys.argv[-1]
                    if "SIDEPULSE_HERDR_CANDIDATE" in command:
                        print("SIDEPULSE_REMOTE_OS=Linux")
                        print("SIDEPULSE_HERDR_CANDIDATE=/fake/herdr")
                    elif "| cat || exit" in command:
                        sys.stderr.write("diagnostic output\\n" * 20000)
                        sys.stderr.flush()
                        print("remote shell startup noise", flush=True)

                        def emit(state):
                            print(json.dumps({{
                                "id": "cli:agent:list",
                                "result": {{
                                    "type": "agent_list",
                                    "agents": [{{
                                        "agent": "copilot",
                                        "agent_status": state,
                                        "terminal_id": "term-1",
                                        "cwd": "/work/repo",
                                        "foreground_cwd": "/work/repo",
                                        "terminal_title": "Remote task",
                                        "terminal_title_stripped": "Remote task",
                                        "pane_id": "w1:p1",
                                        "tab_id": "w1:t1",
                                        "workspace_id": "w1",
                                        "focused": False
                                    }}]
                                }}
                            }}), flush=True)
                        emit("working")
                        time.sleep(0.05)
                        emit("idle")
                        time.sleep(30)
                    else:
                        print({success_line(agent_payload(title="Remote task"))!r})
                    """
                )
            )
            ssh.chmod(0o755)
            monitor = LiveAgentMonitor()
            refreshes: list[bool] = []
            client = HerdrCommandClient(ssh_binary=str(ssh))
            manager = HerdrRemoteManager(
                monitor,
                command_client=client,
                on_refresh=lambda: refreshes.append(True),
            )
            manager.apply_settings(
                (HerdrRemoteSetting("remote-1", "Workbox", "workbox"),)
            )
            deadline = time.time() + 3
            observed_completed = False
            while time.time() < deadline:
                snapshot = monitor.snapshot()
                if (
                    snapshot.statuses
                    and snapshot.statuses[0].mode == AgentMode.COMPLETED
                ):
                    observed_completed = True
                    break
                time.sleep(0.02)
            manager.stop()

            snapshot = monitor.snapshot()
            self.assertTrue(observed_completed)
            self.assertEqual(snapshot.statuses, ())
            self.assertEqual(len(refreshes), 3)


if __name__ == "__main__":
    unittest.main()
