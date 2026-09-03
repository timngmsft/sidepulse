from __future__ import annotations

import hashlib
import json
import os
import queue
import re
import shlex
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import BinaryIO, Callable, Iterable

from .collector import COMPLETED_VISIBLE_SECONDS, LiveAgentMonitor
from .models import (
    AgentMode,
    AgentStatus,
    SOURCE_KIND_HERDR_REMOTE,
    provider_label,
)
from .settings import HerdrRemoteSetting


HERDR_POLL_INTERVAL_SECONDS = 2
HERDR_GRACE_SECONDS = 15.0
HERDR_NO_OUTPUT_TIMEOUT_SECONDS = 10.0
HERDR_INCOMPATIBLE_TIMEOUT_SECONDS = 10.0
HERDR_MAX_RECORD_BYTES = 1024 * 1024
HERDR_MAX_PENDING_RECORDS = 8
HERDR_MAX_COMMAND_OUTPUT_BYTES = 128 * 1024
HERDR_DIAGNOSTIC_BYTES = 8192
HERDR_SSH_CONNECT_TIMEOUT_SECONDS = 10
HERDR_SSH_CONTROL_PERSIST_SECONDS = 10 * 60
HERDR_SSH_SERVER_ALIVE_INTERVAL_SECONDS = 10
HERDR_SSH_SERVER_ALIVE_COUNT_MAX = 3
HERDR_RETRY_DELAYS_SECONDS = (1.0, 2.0, 5.0, 15.0, 30.0)
HERDR_SUPPORTED_REMOTE_OSES = frozenset({"Darwin", "Linux"})
HERDR_AGENT_STATES = frozenset({"idle", "working", "blocked", "done", "unknown"})
HERDR_SESSION_PATTERN = re.compile(r"^[A-Za-z0-9._-]*$")

_AUTH_FAILURE_MARKERS = (
    "permission denied",
    "host key verification failed",
    "the authenticity of host",
    "no supported authentication methods available",
    "too many authentication failures",
)


def _read_chunk(stream: BinaryIO, size: int = 4096) -> bytes:
    read1 = getattr(stream, "read1", None)
    if callable(read1):
        return read1(size)
    return stream.read(size)


class HerdrConnectionState(str, Enum):
    DISABLED = "disabled"
    CONNECTING = "connecting"
    CONNECTED = "connected"
    AUTHENTICATION_REQUIRED = "authentication_required"
    HERDR_NOT_INSTALLED = "herdr_not_installed"
    HERDR_NOT_RUNNING = "herdr_not_running"
    SSH_HOST_UNAVAILABLE = "ssh_host_unavailable"
    UNSUPPORTED_PLATFORM = "unsupported_platform"
    INVALID_PATH_OVERRIDE = "invalid_path_override"
    REMOTE_ERROR = "remote_error"
    INCOMPATIBLE_RESPONSE = "incompatible_response"


HERDR_CONNECTION_LABELS = {
    HerdrConnectionState.DISABLED: "Disabled",
    HerdrConnectionState.CONNECTING: "Connecting",
    HerdrConnectionState.CONNECTED: "Connected",
    HerdrConnectionState.AUTHENTICATION_REQUIRED: "Authentication required",
    HerdrConnectionState.HERDR_NOT_INSTALLED: "Herdr not installed",
    HerdrConnectionState.HERDR_NOT_RUNNING: "Herdr not running",
    HerdrConnectionState.SSH_HOST_UNAVAILABLE: "SSH host unavailable",
    HerdrConnectionState.UNSUPPORTED_PLATFORM: "Unsupported platform",
    HerdrConnectionState.INVALID_PATH_OVERRIDE: "Invalid path override",
    HerdrConnectionState.REMOTE_ERROR: "Remote error",
    HerdrConnectionState.INCOMPATIBLE_RESPONSE: "Incompatible Herdr response",
}


class HerdrRemoteError(RuntimeError):
    pass


class HerdrAuthenticationRequired(HerdrRemoteError):
    pass


class HerdrTransportError(HerdrRemoteError):
    pass


class HerdrUnsupportedPlatform(HerdrRemoteError):
    pass


class HerdrNotInstalled(HerdrRemoteError):
    pass


class HerdrInvalidPathOverride(HerdrRemoteError):
    pass


class HerdrIncompatibleResponse(HerdrRemoteError):
    pass


class HerdrResponseError(ValueError):
    pass


@dataclass(frozen=True)
class HerdrAgentObservation:
    agent: str
    state: str
    terminal_id: str
    cwd: str | None = None
    foreground_cwd: str | None = None
    terminal_title: str | None = None
    terminal_title_stripped: str | None = None
    agent_session: str | None = None

    @property
    def effective_cwd(self) -> str | None:
        return self.foreground_cwd or self.cwd

    @property
    def display_title(self) -> str:
        return (
            self.terminal_title_stripped
            or self.terminal_title
            or provider_label(self.agent)
        )


@dataclass(frozen=True)
class HerdrAgentSnapshot:
    agents: tuple[HerdrAgentObservation, ...]


@dataclass(frozen=True)
class HerdrErrorEnvelope:
    code: str
    message: str


HerdrRecord = HerdrAgentSnapshot | HerdrErrorEnvelope


@dataclass(frozen=True)
class HerdrConnectionStatus:
    remote_id: str
    state: HerdrConnectionState
    message: str = ""
    last_success_at: datetime | None = None

    @property
    def label(self) -> str:
        return HERDR_CONNECTION_LABELS[self.state]


def connection_for_herdr_error(
    remote_id: str,
    error: HerdrErrorEnvelope,
) -> HerdrConnectionStatus:
    state = (
        HerdrConnectionState.HERDR_NOT_RUNNING
        if error.code == "server_not_running"
        else HerdrConnectionState.REMOTE_ERROR
    )
    return HerdrConnectionStatus(
        remote_id=remote_id,
        state=state,
        message=error.message,
    )


@dataclass(frozen=True)
class HerdrRemoteTestResult:
    setting: HerdrRemoteSetting
    connection: HerdrConnectionStatus
    snapshot: HerdrAgentSnapshot | None = None


@dataclass(frozen=True)
class HerdrReduction:
    statuses: tuple[AgentStatus, ...]
    refresh_needed: bool


@dataclass(frozen=True)
class SSHCommandResult:
    returncode: int
    stdout: bytes
    stderr: bytes
    stdout_truncated: bool = False
    stderr_truncated: bool = False

    @property
    def stdout_text(self) -> str:
        return self.stdout.decode("utf-8", errors="replace")

    @property
    def stderr_text(self) -> str:
        return self.stderr.decode("utf-8", errors="replace")


def has_control_characters(value: str) -> bool:
    return any(ord(character) < 32 or ord(character) == 127 for character in value)


def validate_ssh_target(target: str) -> str:
    value = str(target).strip()
    if not value:
        raise ValueError("SSH target is required")
    if has_control_characters(value):
        raise ValueError("SSH target cannot contain control characters")
    return value


def normalize_herdr_session(session: str | None) -> str:
    value = str(session or "").strip()
    if value == "default":
        return ""
    if not HERDR_SESSION_PATTERN.fullmatch(value):
        raise ValueError(
            "Herdr session may contain only letters, numbers, '.', '_', and '-'"
        )
    return value


def validate_remote_path(path: str) -> str:
    value = str(path)
    if not value.startswith("/"):
        raise ValueError("Remote Herdr path must be absolute")
    if has_control_characters(value):
        raise ValueError("Remote Herdr path cannot contain control characters")
    return value


def validate_remote_setting(setting: HerdrRemoteSetting) -> HerdrRemoteSetting:
    override = setting.herdr_path_override
    resolved = setting.resolved_herdr_path
    try:
        validated_override = validate_remote_path(override) if override else None
    except ValueError as exc:
        raise HerdrInvalidPathOverride(str(exc)) from exc
    try:
        validated_resolved = validate_remote_path(resolved) if resolved else None
    except ValueError:
        validated_resolved = None
    return replace(
        setting,
        name=setting.name.strip() or validate_ssh_target(setting.ssh_target),
        ssh_target=validate_ssh_target(setting.ssh_target),
        session=normalize_herdr_session(setting.session),
        herdr_path_override=validated_override,
        resolved_herdr_path=validated_resolved,
    )


def herdr_ssh_control_path(
    remote_id: str,
    ssh_target: str,
    key: str = "default",
) -> Path:
    digest = hashlib.sha256(
        f"{remote_id}\0{validate_ssh_target(ssh_target)}\0{key}".encode("utf-8")
    ).hexdigest()[:20]
    root = Path("/tmp") / f"sidepulse-ssh-{os.getuid()}"
    try:
        root.mkdir(mode=0o700, parents=False, exist_ok=True)
        if root.is_symlink() or not root.is_dir() or root.stat().st_uid != os.getuid():
            raise HerdrTransportError("SSH control directory is not secure")
        root.chmod(0o700)
    except OSError as exc:
        raise HerdrTransportError(
            f"Could not prepare SSH control directory: {exc}"
        ) from exc
    return root / f"herdr-{digest}"


def _string_field(
    data: dict[str, object],
    key: str,
    *,
    required: bool = False,
) -> str | None:
    value = data.get(key)
    if value is None and not required:
        return None
    if not isinstance(value, str) or (required and not value.strip()):
        raise HerdrResponseError(f"agent field {key!r} must be a non-empty string")
    return value


def parse_herdr_record(line: str | bytes) -> HerdrRecord:
    text = line.decode("utf-8", errors="replace") if isinstance(line, bytes) else line
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise HerdrResponseError(f"invalid JSON: {exc.msg}") from exc
    if not isinstance(data, dict):
        raise HerdrResponseError("Herdr response must be a JSON object")
    if data.get("id") != "cli:agent:list":
        raise HerdrResponseError("unexpected Herdr response id")

    if "result" in data:
        result = data.get("result")
        if not isinstance(result, dict) or result.get("type") != "agent_list":
            raise HerdrResponseError("unexpected Herdr result type")
        agents_data = result.get("agents")
        if not isinstance(agents_data, list):
            raise HerdrResponseError("Herdr result.agents must be a list")

        agents: list[HerdrAgentObservation] = []
        identities: set[tuple[str, str]] = set()
        for item in agents_data:
            if not isinstance(item, dict):
                raise HerdrResponseError("every Herdr agent must be an object")
            agent = _string_field(item, "agent", required=True)
            state = _string_field(item, "agent_status", required=True)
            terminal_id = _string_field(item, "terminal_id", required=True)
            assert agent is not None and state is not None and terminal_id is not None
            normalized_state = state.lower()
            if normalized_state not in HERDR_AGENT_STATES:
                continue
            identity = (terminal_id, agent.lower())
            if identity in identities:
                raise HerdrResponseError("duplicate Herdr agent identity")
            identities.add(identity)
            agents.append(
                HerdrAgentObservation(
                    agent=agent.lower(),
                    state=normalized_state,
                    terminal_id=terminal_id,
                    cwd=_string_field(item, "cwd"),
                    foreground_cwd=_string_field(item, "foreground_cwd"),
                    terminal_title=_string_field(item, "terminal_title"),
                    terminal_title_stripped=_string_field(
                        item, "terminal_title_stripped"
                    ),
                    agent_session=_string_field(item, "agent_session"),
                )
            )
        return HerdrAgentSnapshot(tuple(agents))

    error = data.get("error")
    if not isinstance(error, dict):
        raise HerdrResponseError("Herdr response contains neither result nor error")
    code = error.get("code")
    message = error.get("message")
    if not isinstance(code, str) or not code:
        raise HerdrResponseError("Herdr error code must be a non-empty string")
    if not isinstance(message, str):
        raise HerdrResponseError("Herdr error message must be a string")
    return HerdrErrorEnvelope(code=code, message=message)


def herdr_agent_id(remote_id: str, observation: HerdrAgentObservation) -> str:
    return (
        f"herdr:{remote_id}:{observation.terminal_id}:"
        f"{observation.agent.lower()}"
    )


def _one_line(parts: Iterable[str]) -> str:
    return " ".join(part.strip() for part in parts if part.strip())


def build_os_probe_script() -> str:
    return _one_line(
        (
            "os=$(uname -s) || exit 1;",
            "printf 'SIDEPULSE_REMOTE_OS=%s\\n' \"$os\";",
        )
    )


def build_discovery_script() -> str:
    candidates = (
        '"$(command -v herdr 2>/dev/null)"',
        "/opt/homebrew/bin/herdr",
        "/usr/local/bin/herdr",
        "/usr/bin/herdr",
        '"$HOME/.local/bin/herdr"',
        '"$HOME/.cargo/bin/herdr"',
        '"$HOME/.local/share/mise/shims/herdr"',
        '"$HOME/.nix-profile/bin/herdr"',
        '"$HOME/bin/herdr"',
    )
    return _one_line(
        (
            build_os_probe_script(),
            "seen=''; n=0;",
            f"for p in {' '.join(candidates)}; do",
            'if [ -n "$p" ] && [ -x "$p" ]; then',
            'case " $seen " in',
            '*" $p "*) ;;',
            "*) seen=\"$seen $p\"; n=$((n+1)); "
            "printf 'SIDEPULSE_HERDR_CANDIDATE=%s\\n' \"$p\" ;;",
            "esac;",
            "fi;",
            "done;",
            '[ "$n" -gt 0 ] || exit 1;',
        )
    )


def wrap_remote_script(script: str) -> str:
    if "\n" in script or "\r" in script:
        raise ValueError("Remote scripts must be newline-free")
    return f"sh -c {shlex.quote(script)}"


def build_agent_list_script(path: str, session: str = "") -> str:
    executable = shlex.quote(validate_remote_path(path))
    normalized_session = normalize_herdr_session(session)
    session_args = (
        f" --session {shlex.quote(normalized_session)}" if normalized_session else ""
    )
    return f"{executable}{session_args} agent list 2>&1"


def build_poll_script(
    path: str,
    session: str = "",
    *,
    interval_seconds: int = HERDR_POLL_INTERVAL_SECONDS,
) -> str:
    if not isinstance(interval_seconds, int) or interval_seconds <= 0:
        raise ValueError("Polling interval must be a positive integer")
    list_command = build_agent_list_script(path, session)
    executable = shlex.quote(validate_remote_path(path))
    # The `| cat` is load-bearing; see "Keeping the remote loop honest" in
    # remote-agent-integration-v2.md. Verified behaviour vs. a bare
    # `herdr agent list 2>&1 || exit`:
    #   - Herdr exits 1 on an error envelope. `cat` exits 0, so the envelope
    #     reaches SidePulse and polling recovers in place; without it the loop
    #     dies and the whole SSH session is torn down on a transient failure.
    #   - `cat` keeps the `[ -x ]` guard as the only source of exit 127, which
    #     SidePulse reads as "binary moved, re-run discovery". A bare pipeline
    #     leaks Herdr's own 127 into that signal.
    #   - `cat` is the process that owns the final write to SSH, so it takes
    #     the SIGPIPE when the reader goes away even if Herdr ignores SIGPIPE.
    #     Without it such a Herdr would leave this loop orphaned on the remote.
    return _one_line(
        (
            "while :; do",
            f"[ -x {executable} ] || exit 127;",
            f"{list_command} | cat || exit;",
            f"sleep {interval_seconds};",
            "done",
        )
    )


def build_ssh_args(
    target: str,
    remote_command: str,
    *,
    ssh_binary: str = "ssh",
    control_path: str | Path | None = None,
) -> list[str]:
    args = [ssh_binary, "-T", "-o", "BatchMode=yes"]
    if control_path is not None:
        args.extend(
            [
                "-o",
                "ControlMaster=auto",
                "-o",
                f"ControlPersist={HERDR_SSH_CONTROL_PERSIST_SECONDS}",
                "-S",
                str(control_path),
            ]
        )
    args.extend(
        [
            "-o",
            f"ConnectTimeout={HERDR_SSH_CONNECT_TIMEOUT_SECONDS}",
            "-o",
            f"ServerAliveInterval={HERDR_SSH_SERVER_ALIVE_INTERVAL_SECONDS}",
            "-o",
            f"ServerAliveCountMax={HERDR_SSH_SERVER_ALIVE_COUNT_MAX}",
        ]
    )
    args.extend(["--", validate_ssh_target(target), remote_command])
    return args


def parse_probe_output(output: str) -> tuple[str, tuple[str, ...]]:
    os_values: list[str] = []
    candidates: list[str] = []
    for line in output.splitlines():
        if line.startswith("SIDEPULSE_REMOTE_OS="):
            os_values.append(line.split("=", 1)[1])
        elif line.startswith("SIDEPULSE_HERDR_CANDIDATE="):
            candidates.append(line.split("=", 1)[1])
    if len(os_values) != 1:
        raise HerdrUnsupportedPlatform("Remote platform could not be identified")
    remote_os = os_values[0]
    if remote_os not in HERDR_SUPPORTED_REMOTE_OSES:
        raise HerdrUnsupportedPlatform(f"Unsupported remote platform: {remote_os}")

    unique_candidates: list[str] = []
    seen: set[str] = set()
    for candidate in candidates:
        value = validate_remote_path(candidate)
        if value not in seen:
            seen.add(value)
            unique_candidates.append(value)
    return remote_os, tuple(unique_candidates)


def _read_stream_limited(
    stream: BinaryIO,
    limit: int,
    result: list[bytes],
    truncated: list[bool],
) -> None:
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = _read_chunk(stream)
        if not chunk:
            break
        remaining = max(0, limit - total)
        accepted = min(len(chunk), remaining)
        if accepted:
            chunks.append(chunk[:accepted])
            total += accepted
        if accepted < len(chunk):
            truncated[0] = True
    result.append(b"".join(chunks))


def _terminate_process(process) -> None:
    if process.poll() is not None:
        return
    try:
        process.terminate()
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except ProcessLookupError:
            return
        process.wait(timeout=1)


class HerdrCommandClient:
    def __init__(
        self,
        *,
        ssh_binary: str = "ssh",
        process_factory: Callable[..., object] = subprocess.Popen,
        timeout_seconds: float = 15.0,
        max_output_bytes: int = HERDR_MAX_COMMAND_OUTPUT_BYTES,
    ) -> None:
        self.ssh_binary = ssh_binary
        self.process_factory = process_factory
        self.timeout_seconds = timeout_seconds
        self.max_output_bytes = max_output_bytes

    def run(
        self,
        target: str,
        remote_command: str,
        *,
        control_path: str | Path | None = None,
        cancel_event: threading.Event | None = None,
        process_observer: Callable[[object | None], None] | None = None,
    ) -> SSHCommandResult:
        if cancel_event is not None and cancel_event.is_set():
            raise HerdrTransportError("SSH command was cancelled")
        try:
            process = self.process_factory(
                build_ssh_args(
                    target,
                    remote_command,
                    ssh_binary=self.ssh_binary,
                    control_path=control_path,
                ),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except OSError as exc:
            raise HerdrTransportError(f"Could not start SSH: {exc}") from exc
        if process_observer is not None:
            process_observer(process)
        if process.stdout is None or process.stderr is None:
            _terminate_process(process)
            if process_observer is not None:
                process_observer(None)
            raise HerdrTransportError("SSH process did not expose output pipes")

        stdout_result: list[bytes] = []
        stderr_result: list[bytes] = []
        stdout_truncated = [False]
        stderr_truncated = [False]
        stdout_thread = threading.Thread(
            target=_read_stream_limited,
            args=(
                process.stdout,
                self.max_output_bytes,
                stdout_result,
                stdout_truncated,
            ),
            daemon=True,
        )
        stderr_thread = threading.Thread(
            target=_read_stream_limited,
            args=(
                process.stderr,
                self.max_output_bytes,
                stderr_result,
                stderr_truncated,
            ),
            daemon=True,
        )
        stdout_thread.start()
        stderr_thread.start()
        try:
            deadline = time.monotonic() + self.timeout_seconds
            while True:
                if cancel_event is not None and cancel_event.is_set():
                    _terminate_process(process)
                    raise HerdrTransportError("SSH command was cancelled")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    _terminate_process(process)
                    raise HerdrTransportError("SSH command timed out")
                try:
                    returncode = process.wait(timeout=min(0.25, remaining))
                    break
                except subprocess.TimeoutExpired:
                    continue
        finally:
            stdout_thread.join(timeout=1)
            stderr_thread.join(timeout=1)
            if process_observer is not None:
                process_observer(None)

        return SSHCommandResult(
            returncode=returncode,
            stdout=stdout_result[0] if stdout_result else b"",
            stderr=stderr_result[0] if stderr_result else b"",
            stdout_truncated=stdout_truncated[0],
            stderr_truncated=stderr_truncated[0],
        )

    def test_remote(
        self,
        setting: HerdrRemoteSetting,
        *,
        use_cached_path: bool = False,
        control_path: str | Path | None = None,
        cancel_event: threading.Event | None = None,
        process_observer: Callable[[object | None], None] | None = None,
    ) -> HerdrRemoteTestResult:
        remote = validate_remote_setting(setting)
        effective_control_path = control_path or herdr_ssh_control_path(
            remote.remote_id,
            remote.ssh_target,
        )
        if remote.herdr_path_override:
            self._probe_os(
                remote,
                control_path=effective_control_path,
                cancel_event=cancel_event,
                process_observer=process_observer,
            )
            result = self._test_path(
                remote,
                remote.herdr_path_override,
                control_path=effective_control_path,
                cancel_event=cancel_event,
                process_observer=process_observer,
            )
            if result is None:
                raise HerdrInvalidPathOverride(
                    f"Herdr path override is not usable: {remote.herdr_path_override}"
                )
            return result

        attempted: set[str] = set()
        if use_cached_path and remote.resolved_herdr_path:
            attempted.add(remote.resolved_herdr_path)
            result = self._test_path(
                remote,
                remote.resolved_herdr_path,
                control_path=effective_control_path,
                cancel_event=cancel_event,
                process_observer=process_observer,
            )
            if result is not None:
                return result

        discovery = self.run(
            remote.ssh_target,
            wrap_remote_script(build_discovery_script()),
            control_path=effective_control_path,
            cancel_event=cancel_event,
            process_observer=process_observer,
        )
        self._raise_transport_failure(discovery)
        if discovery.stdout_truncated:
            raise HerdrIncompatibleResponse("Remote discovery output was too large")
        _, candidates = parse_probe_output(discovery.stdout_text)
        if not candidates:
            raise HerdrNotInstalled("Herdr is not installed in a supported location")

        failures: list[str] = []
        for candidate in candidates:
            if candidate in attempted:
                continue
            attempted.add(candidate)
            result = self._test_path(
                remote,
                candidate,
                control_path=effective_control_path,
                cancel_event=cancel_event,
                process_observer=process_observer,
            )
            if result is not None:
                return result
            failures.append(candidate)
        detail = ", ".join(failures) if failures else "reported candidates"
        raise HerdrIncompatibleResponse(
            f"No compatible Herdr binary found among {detail}"
        )

    def _probe_os(
        self,
        setting: HerdrRemoteSetting,
        *,
        control_path: str | Path,
        cancel_event: threading.Event | None,
        process_observer: Callable[[object | None], None] | None,
    ) -> str:
        result = self.run(
            setting.ssh_target,
            wrap_remote_script(build_os_probe_script()),
            control_path=control_path,
            cancel_event=cancel_event,
            process_observer=process_observer,
        )
        self._raise_transport_failure(result)
        remote_os, _ = parse_probe_output(result.stdout_text)
        return remote_os

    def _test_path(
        self,
        setting: HerdrRemoteSetting,
        path: str,
        *,
        control_path: str | Path,
        cancel_event: threading.Event | None,
        process_observer: Callable[[object | None], None] | None,
    ) -> HerdrRemoteTestResult | None:
        result = self.run(
            setting.ssh_target,
            wrap_remote_script(build_agent_list_script(path, setting.session)),
            control_path=control_path,
            cancel_event=cancel_event,
            process_observer=process_observer,
        )
        self._raise_transport_failure(result)
        if result.stdout_truncated:
            return None
        records = [
            line
            for line in result.stdout_text.splitlines()
            if line.strip()
        ]
        for line in records:
            try:
                record = parse_herdr_record(line)
            except HerdrResponseError:
                continue
            resolved = (
                setting
                if setting.herdr_path_override
                else setting.with_resolved_path(path)
            )
            if isinstance(record, HerdrAgentSnapshot):
                now = datetime.now(timezone.utc)
                return HerdrRemoteTestResult(
                    setting=resolved,
                    connection=HerdrConnectionStatus(
                        remote_id=setting.remote_id,
                        state=HerdrConnectionState.CONNECTED,
                        last_success_at=now,
                    ),
                    snapshot=record,
                )
            return HerdrRemoteTestResult(
                setting=resolved,
                connection=connection_for_herdr_error(
                    setting.remote_id,
                    record,
                ),
            )
        return None

    def close_control_master(
        self,
        setting: HerdrRemoteSetting,
        *,
        control_path: str | Path | None = None,
    ) -> None:
        effective_control_path = Path(
            control_path
            or herdr_ssh_control_path(
                setting.remote_id,
                setting.ssh_target,
            )
        )
        if not effective_control_path.exists():
            return
        args = [
            self.ssh_binary,
            "-T",
            "-S",
            str(effective_control_path),
            "-O",
            "exit",
            "--",
            validate_ssh_target(setting.ssh_target),
        ]
        try:
            subprocess.run(
                args,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            pass
        finally:
            try:
                effective_control_path.unlink(missing_ok=True)
            except OSError:
                pass

    @staticmethod
    def _raise_transport_failure(result: SSHCommandResult) -> None:
        if result.returncode != 255:
            return
        message = result.stderr_text.strip() or "SSH connection failed"
        if any(marker in message.lower() for marker in _AUTH_FAILURE_MARKERS):
            raise HerdrAuthenticationRequired(message)
        raise HerdrTransportError(message)


def _status_public_signature(status: AgentStatus) -> tuple[object, ...]:
    return (
        status.provider,
        status.agent_id,
        status.display_name,
        status.mode,
        status.updated_at,
        status.event_name,
        status.session_id,
        status.cwd,
        status.tool_name,
        status.message,
        status.origin,
        status.source_kind,
        status.source_id,
    )


class HerdrStatusReducer:
    def __init__(
        self,
        remote_id: str,
        name: str,
        *,
        completed_visible_seconds: float = COMPLETED_VISIBLE_SECONDS,
    ) -> None:
        self.remote_id = remote_id
        self.name = name
        self.completed_visible_seconds = completed_visible_seconds
        self.raw_by_id: dict[str, HerdrAgentObservation] = {}
        self.statuses_by_id: dict[str, AgentStatus] = {}
        self.baseline_pending = True
        self.lock = threading.RLock()

    def update_display_name(self, name: str) -> HerdrReduction:
        with self.lock:
            self.name = name
            old = dict(self.statuses_by_id)
            origin = self._origin
            self.statuses_by_id = {
                key: replace(status, origin=origin)
                for key, status in self.statuses_by_id.items()
            }
            return self._reduction(old)

    def rearm_baseline(self, *, preserve_published: bool) -> HerdrReduction:
        with self.lock:
            old = dict(self.statuses_by_id)
            self.raw_by_id.clear()
            self.baseline_pending = True
            if not preserve_published:
                self.statuses_by_id.clear()
            return self._reduction(old)

    def apply(
        self,
        snapshot: HerdrAgentSnapshot,
        *,
        observed_at: datetime | None = None,
    ) -> HerdrReduction:
        now = observed_at or datetime.now(timezone.utc)
        with self.lock:
            old = dict(self.statuses_by_id)
            next_raw: dict[str, HerdrAgentObservation] = {}
            next_statuses: dict[str, AgentStatus] = {}

            for observation in snapshot.agents:
                agent_id = herdr_agent_id(self.remote_id, observation)
                next_raw[agent_id] = observation
                previous_raw = self.raw_by_id.get(agent_id)
                existing = self.statuses_by_id.get(agent_id)

                if self.baseline_pending or previous_raw is None:
                    status = self._baseline_status(
                        observation,
                        existing,
                        now,
                    )
                else:
                    status = self._transition_status(
                        observation,
                        previous_raw,
                        existing,
                        now,
                    )
                if status is not None:
                    next_statuses[agent_id] = status

            self.raw_by_id = next_raw
            self.statuses_by_id = next_statuses
            self.baseline_pending = False
            return self._reduction(old)

    @property
    def _origin(self) -> str:
        return f"{self.name} via Herdr"

    def _baseline_status(
        self,
        observation: HerdrAgentObservation,
        existing: AgentStatus | None,
        now: datetime,
    ) -> AgentStatus | None:
        if observation.state == "working":
            return self._active_status(
                observation,
                existing,
                AgentMode.WORKING,
                now,
            )
        if observation.state == "blocked":
            return self._active_status(
                observation,
                existing,
                AgentMode.WAITING_FOR_INPUT,
                now,
            )
        if (
            existing is not None
            and existing.mode == AgentMode.COMPLETED
            and existing.age_seconds(now) <= self.completed_visible_seconds
        ):
            return self._refresh_status(existing, observation, now)
        return None

    def _transition_status(
        self,
        observation: HerdrAgentObservation,
        previous_raw: HerdrAgentObservation,
        existing: AgentStatus | None,
        now: datetime,
    ) -> AgentStatus | None:
        if observation.state == "working":
            return self._active_status(
                observation,
                existing,
                AgentMode.WORKING,
                now,
            )
        if observation.state == "blocked":
            return self._active_status(
                observation,
                existing,
                AgentMode.WAITING_FOR_INPUT,
                now,
            )
        if (
            previous_raw.state in {"working", "blocked"}
            and observation.state in {"idle", "done"}
        ):
            return self._new_status(
                observation,
                AgentMode.COMPLETED,
                now,
            )
        if (
            existing is not None
            and existing.mode == AgentMode.COMPLETED
            and existing.age_seconds(now) <= self.completed_visible_seconds
        ):
            return self._refresh_status(existing, observation, now)
        return None

    def _active_status(
        self,
        observation: HerdrAgentObservation,
        existing: AgentStatus | None,
        mode: AgentMode,
        now: datetime,
    ) -> AgentStatus:
        if existing is not None and existing.mode == mode:
            return self._refresh_status(existing, observation, now)
        return self._new_status(observation, mode, now)

    def _new_status(
        self,
        observation: HerdrAgentObservation,
        mode: AgentMode,
        now: datetime,
    ) -> AgentStatus:
        return AgentStatus(
            provider=observation.agent,
            agent_id=herdr_agent_id(self.remote_id, observation),
            display_name=observation.display_title,
            mode=mode,
            updated_at=now,
            last_observed_at=now,
            event_name={
                AgentMode.WORKING: "HerdrWorking",
                AgentMode.WAITING_FOR_INPUT: "HerdrBlocked",
                AgentMode.COMPLETED: "HerdrCompleted",
            }[mode],
            session_id=observation.agent_session,
            cwd=observation.effective_cwd,
            message=observation.terminal_title,
            origin=self._origin,
            source_kind=SOURCE_KIND_HERDR_REMOTE,
            source_id=self.remote_id,
        )

    def _refresh_status(
        self,
        existing: AgentStatus,
        observation: HerdrAgentObservation,
        now: datetime,
    ) -> AgentStatus:
        return replace(
            existing,
            display_name=observation.display_title,
            session_id=observation.agent_session,
            cwd=observation.effective_cwd,
            message=observation.terminal_title,
            origin=self._origin,
            last_observed_at=now,
        )

    def _reduction(self, old: dict[str, AgentStatus]) -> HerdrReduction:
        old_signature = {
            key: _status_public_signature(status) for key, status in old.items()
        }
        new_signature = {
            key: _status_public_signature(status)
            for key, status in self.statuses_by_id.items()
        }
        return HerdrReduction(
            statuses=tuple(self.statuses_by_id.values()),
            refresh_needed=old_signature != new_signature,
        )


class _BoundedDiagnosticBuffer:
    def __init__(self, limit: int = HERDR_DIAGNOSTIC_BYTES) -> None:
        self.limit = limit
        self.data = bytearray()
        self.lock = threading.Lock()

    def append(self, chunk: bytes) -> None:
        with self.lock:
            self.data.extend(chunk)
            if len(self.data) > self.limit:
                del self.data[: len(self.data) - self.limit]

    def text(self) -> str:
        with self.lock:
            return bytes(self.data).decode("utf-8", errors="replace")

    def clear(self) -> None:
        with self.lock:
            self.data.clear()


@dataclass(frozen=True)
class _LineEvent:
    line: bytes | None = None
    oversized: bool = False
    eof: bool = False


def _read_bounded_lines(
    stream: BinaryIO,
    events: queue.Queue[_LineEvent],
    max_record_bytes: int,
    stop_event: threading.Event | None = None,
) -> None:
    def emit(event: _LineEvent) -> bool:
        while stop_event is None or not stop_event.is_set():
            try:
                events.put(event, timeout=0.1)
                return True
            except queue.Full:
                continue
        return False

    buffer = bytearray()
    discarding = False
    while True:
        chunk = _read_chunk(stream)
        if not chunk:
            if buffer and not discarding:
                if not emit(_LineEvent(line=bytes(buffer))):
                    return
            emit(_LineEvent(eof=True))
            return
        for byte in chunk:
            if byte == 10:
                if not discarding:
                    if not emit(_LineEvent(line=bytes(buffer))):
                        return
                buffer.clear()
                discarding = False
                continue
            if discarding:
                continue
            if len(buffer) >= max_record_bytes:
                buffer.clear()
                discarding = True
                if not emit(_LineEvent(oversized=True)):
                    return
                continue
            buffer.append(byte)


def _drain_stderr(stream: BinaryIO, diagnostics: _BoundedDiagnosticBuffer) -> None:
    while True:
        chunk = _read_chunk(stream)
        if not chunk:
            return
        diagnostics.append(chunk)


class HerdrRemoteWorker:
    def __init__(
        self,
        setting: HerdrRemoteSetting,
        generation: int,
        *,
        command_client: HerdrCommandClient,
        control_path: Path,
        process_factory: Callable[..., object] = subprocess.Popen,
        is_current: Callable[[str, int], bool],
        reset_control_path: Callable[
            [str, int, HerdrRemoteSetting, Path],
            Path | None,
        ],
        commit_statuses: Callable[
            [str, int, tuple[AgentStatus, ...]],
            bool | None,
        ],
        on_connection: Callable[[int, HerdrConnectionStatus], None],
        on_refresh: Callable[[], None],
        on_resolved_path: Callable[[str, int, str | None], None],
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self.setting = setting
        self.generation = generation
        self.command_client = command_client
        self.control_path = control_path
        self.process_factory = process_factory
        self.is_current = is_current
        self.reset_control_path = reset_control_path
        self.commit_statuses = commit_statuses
        self.on_connection = on_connection
        self.on_refresh = on_refresh
        self.on_resolved_path = on_resolved_path
        self.monotonic = monotonic
        self.reducer = HerdrStatusReducer(setting.remote_id, setting.name)
        self.stop_event = threading.Event()
        self.thread: threading.Thread | None = None
        self.grace_thread: threading.Thread | None = None
        self.process = None
        self.process_lock = threading.Lock()
        self.last_authoritative_at = self.monotonic()
        self.grace_cleared = False
        self.grace_lock = threading.RLock()
        self.incompatible_rediscovery_attempted = False

    def start(self) -> None:
        if self.thread is not None and self.thread.is_alive():
            return
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.grace_thread = threading.Thread(
            target=self._watch_grace,
            daemon=True,
        )
        self.thread.start()
        self.grace_thread.start()

    def stop(self, *, wait: bool = True) -> None:
        self.stop_event.set()
        with self.process_lock:
            process = self.process
        if process is not None:
            if wait:
                _terminate_process(process)
            elif process.poll() is None:
                try:
                    process.terminate()
                except ProcessLookupError:
                    pass
        if (
            wait
            and self.thread is not None
            and self.thread is not threading.current_thread()
        ):
            self.thread.join()
        if (
            wait
            and self.grace_thread is not None
            and self.grace_thread is not threading.current_thread()
        ):
            self.grace_thread.join()

    def update_display_name(self, name: str) -> None:
        with self.grace_lock:
            self.setting = replace(self.setting, name=name)
            reduction = self.reducer.update_display_name(name)
            committed = self.commit_statuses(
                self.setting.remote_id,
                self.generation,
                reduction.statuses,
            )
        if committed is not None and reduction.refresh_needed:
            self.on_refresh()

    def _run(self) -> None:
        retry_index = 0
        while not self.stop_event.is_set() and self._is_current():
            self._rearm_baseline(preserve_published=True)
            self._publish_connection(HerdrConnectionState.CONNECTING)
            monitoring = False
            try:
                result = self.command_client.test_remote(
                    self.setting,
                    use_cached_path=True,
                    control_path=self.control_path,
                    cancel_event=self.stop_event,
                    process_observer=self._observe_process,
                )
                with self.grace_lock:
                    self.setting = replace(
                        result.setting,
                        name=self.setting.name,
                    )
                if (
                    not self.setting.herdr_path_override
                    and self.setting.resolved_herdr_path
                ):
                    self._publish_resolved_path(
                        self.setting.remote_id,
                        self.setting.resolved_herdr_path,
                    )
                if not self._is_current():
                    return
                self._accept_test_result(result)
                path = (
                    self.setting.herdr_path_override
                    or self.setting.resolved_herdr_path
                )
                if path is None:
                    raise HerdrNotInstalled("Herdr path was not resolved")
                retry_index = 0
                monitoring = True
                self._monitor_connection(path)
            except HerdrAuthenticationRequired as exc:
                self._publish_connection(
                    HerdrConnectionState.AUTHENTICATION_REQUIRED,
                    str(exc),
                )
                return
            except HerdrUnsupportedPlatform as exc:
                self._publish_connection(
                    HerdrConnectionState.UNSUPPORTED_PLATFORM,
                    str(exc),
                )
                return
            except HerdrNotInstalled as exc:
                self._publish_connection(
                    HerdrConnectionState.HERDR_NOT_INSTALLED,
                    str(exc),
                )
                return
            except HerdrInvalidPathOverride as exc:
                self._publish_connection(
                    HerdrConnectionState.INVALID_PATH_OVERRIDE,
                    str(exc),
                )
                return
            except HerdrIncompatibleResponse as exc:
                if (
                    monitoring
                    and not self.setting.herdr_path_override
                    and self.setting.resolved_herdr_path
                    and not self.incompatible_rediscovery_attempted
                ):
                    self.incompatible_rediscovery_attempted = True
                    with self.grace_lock:
                        self.setting = self.setting.with_resolved_path(None)
                    self._publish_resolved_path(
                        self.setting.remote_id,
                        None,
                    )
                    continue
                self._publish_connection(
                    HerdrConnectionState.INCOMPATIBLE_RESPONSE,
                    str(exc),
                )
                return
            except HerdrTransportError as exc:
                if self.stop_event.is_set():
                    return
                replacement_control_path = self.reset_control_path(
                    self.setting.remote_id,
                    self.generation,
                    self.setting,
                    self.control_path,
                )
                if replacement_control_path is None:
                    return
                self.control_path = replacement_control_path
                self._publish_connection(
                    HerdrConnectionState.SSH_HOST_UNAVAILABLE,
                    str(exc),
                )
                delay = HERDR_RETRY_DELAYS_SECONDS[
                    min(retry_index, len(HERDR_RETRY_DELAYS_SECONDS) - 1)
                ]
                retry_index += 1
                if self._wait_with_grace(delay):
                    return
            except Exception as exc:
                self._publish_connection(
                    HerdrConnectionState.INCOMPATIBLE_RESPONSE,
                    str(exc),
                )
                return

    def _accept_test_result(self, result: HerdrRemoteTestResult) -> None:
        snapshot = result.snapshot
        if snapshot is None:
            self._publish_connection(
                result.connection.state,
                result.connection.message,
                last_success_at=result.connection.last_success_at,
            )
            return

        observed_at = result.connection.last_success_at or datetime.now(timezone.utc)
        reduction = self._apply_authoritative_snapshot(
            snapshot,
            observed_at=observed_at,
            observed_monotonic=self.monotonic(),
        )
        if reduction is None:
            return
        self._publish_connection(
            HerdrConnectionState.CONNECTED,
            last_success_at=observed_at,
        )
        if reduction.refresh_needed:
            self.on_refresh()

    def _monitor_connection(self, path: str) -> None:
        diagnostics = _BoundedDiagnosticBuffer()
        invalid_output = _BoundedDiagnosticBuffer()
        events: queue.Queue[_LineEvent] = queue.Queue(
            maxsize=HERDR_MAX_PENDING_RECORDS
        )
        connection_stop_event = threading.Event()
        try:
            process = self.process_factory(
                build_ssh_args(
                    self.setting.ssh_target,
                    wrap_remote_script(
                        build_poll_script(path, self.setting.session)
                    ),
                    ssh_binary=self.command_client.ssh_binary,
                    control_path=self.control_path,
                ),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except OSError as exc:
            raise HerdrTransportError(f"Could not start SSH: {exc}") from exc
        self._observe_process(process)
        if process.stdout is None or process.stderr is None:
            _terminate_process(process)
            self._observe_process(None)
            raise HerdrTransportError("SSH process did not expose output pipes")

        stdout_thread = threading.Thread(
            target=_read_bounded_lines,
            args=(
                process.stdout,
                events,
                HERDR_MAX_RECORD_BYTES,
                connection_stop_event,
            ),
            daemon=True,
        )
        stderr_thread = threading.Thread(
            target=_drain_stderr,
            args=(process.stderr, diagnostics),
            daemon=True,
        )
        stdout_thread.start()
        stderr_thread.start()

        started_at = self.monotonic()
        last_output_at = started_at
        last_valid_at = started_at
        saw_invalid = False

        def raise_if_sustained_invalid(
            now: float,
            message: str = "Remote output did not contain a valid Herdr response",
        ) -> None:
            if (
                now - last_valid_at
                < HERDR_INCOMPATIBLE_TIMEOUT_SECONDS
            ):
                return
            detail = invalid_output.text().strip()
            raise HerdrIncompatibleResponse(
                message + (f": {detail}" if detail else "")
            )

        try:
            while not self.stop_event.is_set() and self._is_current():
                try:
                    event = events.get(timeout=0.25)
                except queue.Empty:
                    now = self.monotonic()
                    if process.poll() is not None:
                        break
                    if (
                        saw_invalid
                    ):
                        raise_if_sustained_invalid(now)
                    if now - last_output_at >= HERDR_NO_OUTPUT_TIMEOUT_SECONDS:
                        raise HerdrTransportError("Remote Herdr poll produced no output")
                    continue

                now = self.monotonic()
                if event.eof:
                    break
                last_output_at = now
                if event.oversized:
                    saw_invalid = True
                    invalid_output.append(b"<oversized record>")
                    raise_if_sustained_invalid(
                        now,
                        "Remote Herdr response exceeded the record limit",
                    )
                    continue
                if event.line is None or not event.line.strip():
                    saw_invalid = True
                    invalid_output.append(b"<blank record>\n")
                    raise_if_sustained_invalid(now)
                    continue
                try:
                    record = parse_herdr_record(event.line)
                except HerdrResponseError:
                    saw_invalid = True
                    invalid_output.append(event.line + b"\n")
                    raise_if_sustained_invalid(now)
                    continue

                last_valid_at = now
                saw_invalid = False
                invalid_output.clear()
                if isinstance(record, HerdrErrorEnvelope):
                    connection = connection_for_herdr_error(
                        self.setting.remote_id,
                        record,
                    )
                    self.incompatible_rediscovery_attempted = False
                    self._publish_connection(
                        connection.state,
                        connection.message,
                    )
                    continue

                observed_at = datetime.now(timezone.utc)
                reduction = self._apply_authoritative_snapshot(
                    record,
                    observed_at=observed_at,
                    observed_monotonic=now,
                )
                if reduction is None:
                    return
                self.incompatible_rediscovery_attempted = False
                self._publish_connection(
                    HerdrConnectionState.CONNECTED,
                    last_success_at=observed_at,
                )
                if reduction.refresh_needed:
                    self.on_refresh()
        finally:
            connection_stop_event.set()
            _terminate_process(process)
            self._observe_process(None)
            stdout_thread.join(timeout=1)
            stderr_thread.join(timeout=1)

        if self.stop_event.is_set() or not self._is_current():
            return
        returncode = process.poll()
        stderr_text = diagnostics.text().strip()
        if returncode == 127:
            if self.setting.herdr_path_override:
                raise HerdrInvalidPathOverride(
                    f"Herdr path override is no longer executable: "
                    f"{self.setting.herdr_path_override}"
                )
            with self.grace_lock:
                self.setting = self.setting.with_resolved_path(None)
            self._publish_resolved_path(self.setting.remote_id, None)
            return
        if returncode == 255 and any(
            marker in stderr_text.lower() for marker in _AUTH_FAILURE_MARKERS
        ):
            raise HerdrAuthenticationRequired(
                stderr_text or "SSH authentication is required"
            )
        raise HerdrTransportError(stderr_text or "Remote SSH process exited")

    def _wait_with_grace(self, delay: float) -> bool:
        deadline = self.monotonic() + delay
        while not self.stop_event.is_set() and self._is_current():
            now = self.monotonic()
            remaining = deadline - now
            if remaining <= 0:
                return False
            self.stop_event.wait(min(0.25, remaining))
        return True

    def _watch_grace(self) -> None:
        while not self.stop_event.is_set() and self._is_current():
            self._expire_grace(self.monotonic())
            self.stop_event.wait(0.25)

    def _rearm_baseline(self, *, preserve_published: bool) -> None:
        with self.grace_lock:
            self.reducer.rearm_baseline(preserve_published=preserve_published)

    def _apply_authoritative_snapshot(
        self,
        snapshot: HerdrAgentSnapshot,
        *,
        observed_at: datetime,
        observed_monotonic: float,
    ) -> HerdrReduction | None:
        with self.grace_lock:
            expired_refresh = False
            if (
                not self.grace_cleared
                and observed_monotonic - self.last_authoritative_at
                >= HERDR_GRACE_SECONDS
            ):
                expired = self.reducer.rearm_baseline(
                    preserve_published=False,
                )
                expired_refresh = expired.refresh_needed
                self.grace_cleared = True
            reduction = self.reducer.apply(
                snapshot,
                observed_at=observed_at,
            )
            committed = self.commit_statuses(
                self.setting.remote_id,
                self.generation,
                reduction.statuses,
            )
            if committed is None:
                return None
            self.last_authoritative_at = observed_monotonic
            self.grace_cleared = False
            return HerdrReduction(
                statuses=reduction.statuses,
                refresh_needed=expired_refresh or reduction.refresh_needed,
            )

    def _expire_grace(self, now: float) -> None:
        with self.grace_lock:
            if self.grace_cleared:
                return
            if now - self.last_authoritative_at < HERDR_GRACE_SECONDS:
                return
            reduction = self.reducer.rearm_baseline(preserve_published=False)
            committed = self.commit_statuses(
                self.setting.remote_id,
                self.generation,
                (),
            )
            self.grace_cleared = True
        if committed is not None and reduction.refresh_needed:
            self.on_refresh()

    def _publish_connection(
        self,
        state: HerdrConnectionState,
        message: str = "",
        *,
        last_success_at: datetime | None = None,
    ) -> None:
        self.on_connection(
            self.generation,
            HerdrConnectionStatus(
                remote_id=self.setting.remote_id,
                state=state,
                message=message,
                last_success_at=last_success_at,
            )
        )

    def _publish_resolved_path(
        self,
        remote_id: str,
        path: str | None,
    ) -> None:
        self.on_resolved_path(remote_id, self.generation, path)

    def _observe_process(self, process: object | None) -> None:
        with self.process_lock:
            self.process = process

    def _is_current(self) -> bool:
        return self.is_current(self.setting.remote_id, self.generation)


class HerdrRemoteManager:
    def __init__(
        self,
        monitor: LiveAgentMonitor,
        *,
        command_client: HerdrCommandClient | None = None,
        process_factory: Callable[..., object] = subprocess.Popen,
        worker_factory: Callable[..., HerdrRemoteWorker] = HerdrRemoteWorker,
        on_refresh: Callable[[], None] | None = None,
        on_resolved_path: Callable[[str, int, str | None], None] | None = None,
    ) -> None:
        self.monitor = monitor
        self.command_client = command_client or HerdrCommandClient(
            process_factory=process_factory
        )
        self.process_factory = process_factory
        self.worker_factory = worker_factory
        self.on_refresh = on_refresh or (lambda: None)
        self.on_resolved_path = on_resolved_path or (
            lambda _remote_id, _generation, _path: None
        )
        self.lock = threading.RLock()
        self.settings_by_id: dict[str, HerdrRemoteSetting] = {}
        self.workers_by_id: dict[str, HerdrRemoteWorker] = {}
        self.generations: dict[str, int] = {}
        self.connections: dict[str, HerdrConnectionStatus] = {}
        self.control_paths_by_endpoint: dict[tuple[str, str], Path] = {}
        self.control_path_nonces_by_endpoint: dict[tuple[str, str], str] = {}
        self.pending_cleanup_threads: set[threading.Thread] = set()
        self.pending_cleanup_errors: list[Exception] = []

    def apply_settings(self, settings: Iterable[HerdrRemoteSetting]) -> None:
        incoming = {setting.remote_id: setting for setting in settings}
        with self.lock:
            previous = dict(self.settings_by_id)

        for remote_id in set(previous) - set(incoming):
            self._teardown(
                remote_id,
                remove_setting=True,
                close_control_master=True,
            )

        for remote_id, setting in incoming.items():
            old = previous.get(remote_id)
            if old is None:
                with self.lock:
                    self.settings_by_id[remote_id] = setting
                if setting.enabled:
                    self._start(setting)
                else:
                    self._set_connection(
                        HerdrConnectionStatus(
                            remote_id,
                            HerdrConnectionState.DISABLED,
                        )
                    )
                continue

            if self._endpoint_signature(old) != self._endpoint_signature(setting):
                close_control_master = (
                    old.ssh_target != setting.ssh_target
                    or (old.enabled and not setting.enabled)
                )
                self._teardown(
                    remote_id,
                    remove_setting=False,
                    clear_connection=True,
                    close_control_master=close_control_master,
                )
                with self.lock:
                    self.settings_by_id[remote_id] = setting
                if setting.enabled:
                    self._start(setting)
                else:
                    self._set_connection(
                        HerdrConnectionStatus(
                            remote_id,
                            HerdrConnectionState.DISABLED,
                        )
                    )
                continue

            with self.lock:
                self.settings_by_id[remote_id] = setting
                worker = self.workers_by_id.get(remote_id)
            if old.name != setting.name and worker is not None:
                worker.update_display_name(setting.name)
            if setting.enabled and worker is None:
                self._start(setting)

    def stop(
        self,
        *,
        close_control_masters: bool = True,
        wait: bool = True,
    ) -> None:
        with self.lock:
            remote_ids = tuple(self.settings_by_id)
        first_error: Exception | None = None
        for remote_id in remote_ids:
            try:
                self._teardown(
                    remote_id,
                    remove_setting=False,
                    close_control_master=close_control_masters,
                    wait=wait,
                )
            except Exception as exc:
                if first_error is None:
                    first_error = exc
        if wait:
            try:
                self._drain_pending_cleanup()
            except Exception as exc:
                if first_error is None:
                    first_error = exc
        if first_error is not None:
            raise first_error

    def retry(self, remote_id: str) -> None:
        with self.lock:
            setting = self.settings_by_id.get(remote_id)
        if setting is None or not setting.enabled:
            return
        self._teardown(
            remote_id,
            remove_setting=False,
            clear_connection=True,
        )
        self._start(setting)

    def restart(
        self,
        monitor: LiveAgentMonitor,
        settings: Iterable[HerdrRemoteSetting],
    ) -> None:
        self.stop(close_control_masters=False, wait=False)
        with self.lock:
            self.monitor = monitor
            self.settings_by_id = {}
            self.connections = {}
        self.apply_settings(settings)

    def test_remote(
        self,
        setting: HerdrRemoteSetting,
        *,
        control_path: str | Path | None = None,
        cancel_event: threading.Event | None = None,
        process_observer: Callable[[object | None], None] | None = None,
    ) -> HerdrRemoteTestResult:
        return self.command_client.test_remote(
            setting,
            use_cached_path=False,
            control_path=control_path or self.control_path_for(setting),
            cancel_event=cancel_event,
            process_observer=process_observer,
        )

    def control_path_for(self, setting: HerdrRemoteSetting) -> Path:
        with self.lock:
            return self._control_path_locked(setting)

    def adopt_control_path(
        self,
        setting: HerdrRemoteSetting,
        control_path: str | Path,
    ) -> Path | None:
        path = Path(control_path)
        with self.lock:
            key = self._control_path_key(setting)
            existing = self.control_paths_by_endpoint.get(key)
            previous = existing if existing is not None and existing != path else None
            self.control_paths_by_endpoint[key] = path
            self.control_path_nonces_by_endpoint.pop(key, None)
        return previous

    def close_control_master(
        self,
        setting: HerdrRemoteSetting,
        *,
        control_path: str | Path | None = None,
        wait: bool = False,
    ) -> None:
        effective_control_path = Path(
            control_path or self.control_path_for(setting)
        )
        with self.lock:
            key = self._control_path_key(setting)
            if self.control_paths_by_endpoint.get(key) == effective_control_path:
                self._retire_control_path_locked(setting)
        if wait:
            self.command_client.close_control_master(
                setting,
                control_path=effective_control_path,
            )
            return
        self._schedule_cleanup(
            lambda: self.command_client.close_control_master(
                setting,
                control_path=effective_control_path,
            )
        )

    def connection_status(
        self,
        remote_id: str,
    ) -> HerdrConnectionStatus | None:
        with self.lock:
            return self.connections.get(remote_id)

    def _start(self, setting: HerdrRemoteSetting) -> None:
        try:
            validated = validate_remote_setting(setting)
            with self.lock:
                control_path = self._control_path_locked(validated)
                generation = self.generations.get(validated.remote_id, 0) + 1
                self.generations[validated.remote_id] = generation
                self.settings_by_id[validated.remote_id] = validated
                worker = self.worker_factory(
                    validated,
                    generation,
                    command_client=self.command_client,
                    control_path=control_path,
                    process_factory=self.process_factory,
                    is_current=self._is_current,
                    reset_control_path=self._reset_worker_control_path,
                    commit_statuses=self._commit_statuses,
                    on_connection=self._set_worker_connection,
                    on_refresh=self.on_refresh,
                    on_resolved_path=self._resolved_path,
                )
                self.workers_by_id[validated.remote_id] = worker
        except HerdrInvalidPathOverride as exc:
            self._set_connection(
                HerdrConnectionStatus(
                    setting.remote_id,
                    HerdrConnectionState.INVALID_PATH_OVERRIDE,
                    str(exc),
                )
            )
            return
        except HerdrTransportError as exc:
            self._set_connection(
                HerdrConnectionStatus(
                    setting.remote_id,
                    HerdrConnectionState.SSH_HOST_UNAVAILABLE,
                    str(exc),
                )
            )
            return
        except ValueError as exc:
            self._set_connection(
                HerdrConnectionStatus(
                    setting.remote_id,
                    HerdrConnectionState.INCOMPATIBLE_RESPONSE,
                    f"Invalid remote configuration: {exc}",
                )
            )
            return

        self._set_connection(
            HerdrConnectionStatus(
                validated.remote_id,
                HerdrConnectionState.CONNECTING,
            ),
            generation=generation,
        )
        worker.start()

    def _teardown(
        self,
        remote_id: str,
        *,
        remove_setting: bool,
        clear_connection: bool = False,
        close_control_master: bool = False,
        wait: bool = False,
    ) -> None:
        with self.lock:
            setting = self.settings_by_id.get(remote_id)
            control_path = None
            if close_control_master and setting is not None:
                control_path = self._retire_control_path_locked(setting)
            self.generations[remote_id] = self.generations.get(remote_id, 0) + 1
            worker = self.workers_by_id.pop(remote_id, None)
            if remove_setting:
                self.settings_by_id.pop(remote_id, None)
                self.control_paths_by_endpoint = {
                    key: path
                    for key, path in self.control_paths_by_endpoint.items()
                    if key[0] != remote_id
                }
                self.control_path_nonces_by_endpoint = {
                    key: nonce
                    for key, nonce in self.control_path_nonces_by_endpoint.items()
                    if key[0] != remote_id
                }
            if remove_setting or clear_connection:
                self.connections.pop(remote_id, None)
            removed = self.monitor.remove_source(
                SOURCE_KIND_HERDR_REMOTE,
                remote_id,
            )
        if removed or remove_setting:
            self.on_refresh()

        def cleanup() -> None:
            try:
                if worker is not None:
                    worker.stop(wait=True)
            finally:
                if (
                    close_control_master
                    and setting is not None
                    and control_path is not None
                ):
                    self.command_client.close_control_master(
                        setting,
                        control_path=control_path,
                    )

        if wait:
            cleanup()
            return
        if worker is not None:
            worker.stop(wait=False)
        if worker is not None or (
            close_control_master and control_path is not None
        ):
            self._schedule_cleanup(cleanup)

    def _control_path_locked(self, setting: HerdrRemoteSetting) -> Path:
        key = self._control_path_key(setting)
        existing = self.control_paths_by_endpoint.get(key)
        if existing is not None:
            return existing
        nonce = self.control_path_nonces_by_endpoint.get(key, "default")
        control_path = herdr_ssh_control_path(
            setting.remote_id,
            setting.ssh_target,
            nonce,
        )
        self.control_paths_by_endpoint[key] = control_path
        self.control_path_nonces_by_endpoint.pop(key, None)
        return control_path

    def _retire_control_path_locked(
        self,
        setting: HerdrRemoteSetting,
    ) -> Path | None:
        key = self._control_path_key(setting)
        control_path = self.control_paths_by_endpoint.pop(key, None)
        self.control_path_nonces_by_endpoint[key] = uuid.uuid4().hex
        return control_path

    def _schedule_cleanup(self, cleanup: Callable[[], None]) -> None:
        def run_cleanup() -> None:
            try:
                cleanup()
            except Exception as exc:
                with self.lock:
                    self.pending_cleanup_errors.append(exc)
            finally:
                with self.lock:
                    self.pending_cleanup_threads.discard(
                        threading.current_thread()
                    )

        thread = threading.Thread(target=run_cleanup, daemon=True)
        with self.lock:
            self.pending_cleanup_threads.add(thread)
            try:
                thread.start()
            except Exception:
                self.pending_cleanup_threads.discard(thread)
                raise

    def _drain_pending_cleanup(self) -> None:
        while True:
            with self.lock:
                threads = tuple(
                    thread
                    for thread in self.pending_cleanup_threads
                    if thread is not threading.current_thread()
                )
                if not threads:
                    errors = tuple(self.pending_cleanup_errors)
                    self.pending_cleanup_errors.clear()
                    break
            for thread in threads:
                thread.join()
        if errors:
            raise errors[0]

    @staticmethod
    def _control_path_key(setting: HerdrRemoteSetting) -> tuple[str, str]:
        return (setting.remote_id, setting.ssh_target)

    def _is_current(self, remote_id: str, generation: int) -> bool:
        with self.lock:
            return self._is_current_locked(remote_id, generation)

    def _is_current_locked(self, remote_id: str, generation: int) -> bool:
        return (
            self.generations.get(remote_id) == generation
            and remote_id in self.workers_by_id
        )

    def _reset_worker_control_path(
        self,
        remote_id: str,
        generation: int,
        setting: HerdrRemoteSetting,
        control_path: Path,
    ) -> Path | None:
        with self.lock:
            if not self._is_current_locked(remote_id, generation):
                return None
            worker = self.workers_by_id.get(remote_id)
            current_setting = self.settings_by_id.get(remote_id)
            if (
                worker is None
                or current_setting is None
                or current_setting.ssh_target != setting.ssh_target
                or worker.control_path != control_path
                or self.control_paths_by_endpoint.get(
                    self._control_path_key(current_setting)
                )
                != control_path
            ):
                return None
            retired = self._retire_control_path_locked(current_setting)
            replacement = self._control_path_locked(current_setting)
            worker.control_path = replacement

        if retired is not None:
            self.command_client.close_control_master(
                setting,
                control_path=retired,
            )

        with self.lock:
            if not self._is_current_locked(remote_id, generation):
                return None
        return replacement

    def _commit_statuses(
        self,
        remote_id: str,
        generation: int,
        statuses: tuple[AgentStatus, ...],
    ) -> bool | None:
        with self.lock:
            if not self._is_current_locked(remote_id, generation):
                return None
            return self.monitor.reconcile_source(
                SOURCE_KIND_HERDR_REMOTE,
                remote_id,
                statuses,
            )

    def _set_worker_connection(
        self,
        generation: int,
        connection: HerdrConnectionStatus,
    ) -> None:
        self._set_connection(connection, generation=generation)

    def _set_connection(
        self,
        connection: HerdrConnectionStatus,
        *,
        generation: int | None = None,
    ) -> None:
        with self.lock:
            if generation is not None and not self._is_current_locked(
                connection.remote_id,
                generation,
            ):
                return
            previous = self.connections.get(connection.remote_id)
            if (
                previous is not None
                and connection.last_success_at is None
                and previous.last_success_at is not None
            ):
                connection = replace(
                    connection,
                    last_success_at=previous.last_success_at,
                )
            self.connections[connection.remote_id] = connection
        if (
            previous is None
            or previous.state != connection.state
            or previous.message != connection.message
        ):
            self.on_refresh()

    def _resolved_path(
        self,
        remote_id: str,
        generation: int,
        path: str | None,
    ) -> None:
        with self.lock:
            if not self._is_current_locked(remote_id, generation):
                return
            setting = self.settings_by_id.get(remote_id)
            if setting is None or setting.herdr_path_override:
                return
            updated = setting.with_resolved_path(path)
            self.settings_by_id[remote_id] = updated
        self.on_resolved_path(remote_id, generation, path)

    def resolved_path_is_current(
        self,
        remote_id: str,
        generation: int,
        path: str | None,
    ) -> bool:
        with self.lock:
            setting = self.settings_by_id.get(remote_id)
            return (
                self._is_current_locked(remote_id, generation)
                and setting is not None
                and not setting.herdr_path_override
                and setting.resolved_herdr_path == path
            )

    @staticmethod
    def _endpoint_signature(setting: HerdrRemoteSetting) -> tuple[object, ...]:
        return (
            setting.ssh_target,
            setting.session,
            setting.enabled,
            setting.herdr_path_override,
            setting.herdr_path_override or setting.resolved_herdr_path,
        )
