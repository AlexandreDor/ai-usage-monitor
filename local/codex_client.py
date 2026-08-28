#!/usr/bin/env python3
"""Read quota limits from the local Codex app-server.

The monitor invokes this module as a small command-line adapter.  Keeping the
JSON-RPC transport here makes the protocol independently testable while the
shell script remains responsible for configuration and orchestration.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import re
import select
import signal
import subprocess
import sys
import time
from typing import Any, Callable, Mapping, Sequence
from zoneinfo import ZoneInfo

try:  # Script execution from local/ and imports from the test suite.
    import history as snapshot_contract
except ImportError:  # pragma: no cover - only relevant to unusual import paths
    from . import history as snapshot_contract


DEFAULT_TIMEOUT_SECONDS = 20
MAX_DIAGNOSTIC_BYTES = 4096
PROCESS_STOP_TIMEOUT_SECONDS = 2
PARIS = ZoneInfo("Europe/Paris")
try:
    from config import SENSITIVE_KEYS as CONFIG_SENSITIVE_KEYS
except ImportError:  # pragma: no cover - only unusual package import paths
    CONFIG_SENSITIVE_KEYS = frozenset()

SECRET_ENVIRONMENT_NAMES = tuple(
    sorted(
        set(CONFIG_SENSITIVE_KEYS)
        | {
            # These are public config metadata today, but are credentials or
            # account selectors from the child process' point of view.
            "GITHUB_GIST_ID",
        }
    )
)
MAX_PROTOCOL_LINE_BYTES = 1 * 1024 * 1024


class CodexClientError(RuntimeError):
    """A safe, user-facing failure while talking to Codex."""


class CodexTimeoutError(CodexClientError):
    """The app-server did not answer before the configured deadline."""


class CodexProtocolError(CodexClientError):
    """The app-server handshake or response was not usable."""


def finite_number(value: Any) -> bool:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value)
    except (OverflowError, ValueError):
        return False


def normal_number(value: int | float) -> int | float:
    try:
        numeric = float(value)
    except (OverflowError, ValueError) as exc:
        raise CodexProtocolError("Codex returned a number outside the supported range.") from exc
    return int(numeric) if numeric.is_integer() else numeric


def _redaction_values(environment: Mapping[str, str] | None = None) -> list[str]:
    values: list[str] = []
    source = os.environ if environment is None else environment
    for name in SECRET_ENVIRONMENT_NAMES:
        value = source.get(name)
        if value:
            values.append(value)
    return sorted(set(values), key=len, reverse=True)


def clean_diagnostic(
    raw: bytes | str,
    *,
    secrets: Sequence[str] = (),
    maximum_bytes: int = MAX_DIAGNOSTIC_BYTES,
) -> str:
    """Return bounded, printable diagnostics without configured secret values."""

    if isinstance(raw, bytes):
        text = raw.decode("utf-8", "replace")
    else:
        text = raw
    for secret in secrets:
        if secret:
            text = text.replace(secret, "[REDACTED]")

    # Keep diagnostics useful while avoiding control sequences and terminal
    # escapes.  Absolute local paths are not useful in a public monitor error.
    # Preserve network URLs where possible, but redact an entire diagnostic
    # line containing a local path so spaces and trailing secret components
    # cannot leak through an incomplete token match.
    urls: list[str] = []

    def protect_url(match: re.Match[str]) -> str:
        urls.append(match.group(0))
        return f"\x00URL{len(urls) - 1}\x00"

    text = re.sub(r"https?://[^\s<>\"']+", protect_url, text, flags=re.I)
    path_start = re.compile(r"(?<![A-Za-z0-9_])(?:file:|/(?!/))", re.I)
    redacted_lines: list[str] = []
    for line in text.splitlines(keepends=True):
        segments = re.split(r"(\x00URL\d+\x00)", line)
        for index, segment in enumerate(segments):
            if not segment.startswith("\x00URL") and path_start.search(segment):
                segments[index] = "[PATH]"
        redacted_lines.append("".join(segments))
    text = "".join(redacted_lines)
    for index, url in enumerate(urls):
        text = text.replace(f"\x00URL{index}\x00", url)
    text = re.sub(
        r"\b(?:acct|account|user|org)(?:[_ -]?id)?\s*[:=]\s*[A-Za-z0-9._:-]+",
        "[ACCOUNT]",
        text,
        flags=re.I,
    )
    text = re.sub(r"\b(?:acct|account)[_-][A-Za-z0-9._:-]+", "[ACCOUNT]", text, flags=re.I)
    text = "".join(
        char if char in "\n\t" or ord(char) >= 32 else "?" for char in text
    ).strip()
    encoded = text.encode("utf-8", "replace")[:maximum_bytes]
    return encoded.decode("utf-8", "ignore")


def environment_without_secrets(
    environment: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Copy an environment while withholding outbound monitor credentials."""

    child_environment = dict(os.environ if environment is None else environment)
    for secret_name in SECRET_ENVIRONMENT_NAMES:
        child_environment.pop(secret_name, None)
    return child_environment


def _send(process: subprocess.Popen[bytes], message: Mapping[str, Any]) -> None:
    if process.stdin is None:
        raise CodexProtocolError("Codex app-server input is unavailable.")
    try:
        process.stdin.write((json.dumps(message, separators=(",", ":")) + "\n").encode())
        process.stdin.flush()
    except (BrokenPipeError, OSError) as exc:
        raise CodexProtocolError("Codex app-server closed the protocol input.") from exc


def stop_process(
    process: subprocess.Popen[Any],
    *,
    process_group: int | None = None,
    timeout_seconds: float = PROCESS_STOP_TIMEOUT_SECONDS,
) -> None:
    """Terminate a child with bounded waits, escalating to kill if needed."""

    group = process_group
    if group is None:
        try:
            group = os.getpgid(process.pid)
        except (AttributeError, OSError, ProcessLookupError, PermissionError):
            group = None

    group_term_sent = False
    try:
        if group is not None:
            try:
                os.killpg(group, signal.SIGTERM)
                group_term_sent = True
            except (AttributeError, OSError, ProcessLookupError, PermissionError):
                group_term_sent = False
        if not group_term_sent and process.poll() is None:
            try:
                process.terminate()
            except (AttributeError, OSError):
                pass
        if process.poll() is None:
            try:
                process.wait(timeout=timeout_seconds)
            except (OSError, subprocess.TimeoutExpired):
                pass

        # The leader may have exited after TERM while a descendant that ignores
        # TERM remains in the same process group.  Escalate the captured group
        # independently of the leader's state.
        if group is not None:
            try:
                os.killpg(group, signal.SIGKILL)
            except (AttributeError, OSError, ProcessLookupError, PermissionError):
                pass
        elif process.poll() is None:
            try:
                process.kill()
            except OSError:
                pass

        # Reap only with a bounded wait.  A SIGKILLed group should make this
        # immediate, but a mock or unusual platform must not stall a cycle.
        if process.poll() is None:
            try:
                process.wait(timeout=timeout_seconds)
            except (OSError, subprocess.TimeoutExpired):
                pass
    finally:
        # Closing a BufferedWriter whose child already exited can otherwise
        # emit an ``Exception ignored ... BrokenPipeError`` traceback during
        # interpreter shutdown.
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass


def _read_available(
    stream: Any,
    *,
    limit: int,
) -> bytes:
    try:
        return os.read(stream.fileno(), limit)
    except (OSError, ValueError):
        return b""


def _drain_diagnostic(stream: Any, current: bytearray) -> None:
    if stream is None:
        return
    while len(current) < MAX_DIAGNOSTIC_BYTES:
        try:
            ready, _, _ = select.select([stream], [], [], 0)
        except (OSError, ValueError):
            break
        if stream not in ready:
            break
        chunk = _read_available(stream, limit=MAX_DIAGNOSTIC_BYTES - len(current))
        if not chunk:
            break
        current.extend(chunk)


def _protocol_error_detail(message: Mapping[str, Any]) -> str:
    error = message.get("error")
    if not isinstance(error, Mapping):
        return ""
    code = error.get("code")
    # The code is a stable protocol diagnostic; free-form server messages can
    # include paths, account IDs, or secrets, so do not expose them by default.
    return f" (code {code})" if isinstance(code, int) and not isinstance(code, bool) else ""


def _read_result(
    process: subprocess.Popen[bytes],
    *,
    timeout_seconds: float,
    environment: Mapping[str, str],
    debug: bool,
) -> tuple[dict[str, Any] | None, str, bool]:
    """Perform the initialize/read exchange and return result, diagnostics, bad-json flag."""

    if process.stdin is None or process.stdout is None or process.stderr is None:
        raise CodexProtocolError("Codex app-server did not expose stdio channels.")

    _send(
        process,
        {
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {"name": "codex-usage-monitor", "version": "1.0.0"},
                "capabilities": {"experimentalApi": True},
            },
        },
    )

    deadline = time.monotonic() + timeout_seconds
    stdout_buffer = bytearray()
    diagnostic = bytearray()
    initialize_complete = False
    request_sent = False
    result: dict[str, Any] | None = None
    invalid_json_seen = False
    stdout_closed = False
    stderr_closed = False

    def fail(message: str, error_type: type[CodexClientError] = CodexProtocolError) -> None:
        safe = clean_diagnostic(
            bytes(diagnostic),
            secrets=_redaction_values(environment),
        )
        if debug and safe:
            print(f"[DEBUG] Codex diagnostic: {safe}", file=sys.stderr)
        raise error_type(message)

    def handle_message(message: Any) -> None:
        nonlocal initialize_complete, request_sent, result, invalid_json_seen
        if not isinstance(message, Mapping):
            invalid_json_seen = True
            return
        message_id = message.get("id")
        if message_id == 1:
            if "error" in message and message.get("error") is not None:
                fail(
                    "Codex app-server initialization failed"
                    + _protocol_error_detail(message)
                    + "."
                )
            if initialize_complete:
                return
            _send(process, {"method": "initialized"})
            _send(
                process,
                {"id": 2, "method": "account/rateLimits/read", "params": None},
            )
            initialize_complete = True
            request_sent = True
        elif message_id == 2 and request_sent:
            if "error" in message and message.get("error") is not None:
                fail(
                    "Codex app-server rate-limit request failed"
                    + _protocol_error_detail(message)
                    + "."
                )
            candidate = message.get("result")
            if isinstance(candidate, Mapping):
                result = dict(candidate)
            else:
                invalid_json_seen = True
        # Notifications and responses for other request IDs are intentionally
        # ignored; the result ID is authoritative.

    def consume_stdout_buffer() -> None:
        nonlocal stdout_buffer, invalid_json_seen
        decoder = json.JSONDecoder()
        while stdout_buffer:
            newline_position = stdout_buffer.find(b"\n")
            if newline_position >= 0:
                raw_line = bytes(stdout_buffer[:newline_position])
                stdout_buffer = stdout_buffer[newline_position + 1 :]
                if not raw_line.strip():
                    continue
                try:
                    message = json.loads(raw_line.decode("utf-8"))
                except (UnicodeDecodeError, ValueError):
                    invalid_json_seen = True
                    continue
                handle_message(message)
                if result is not None:
                    return
                continue

            # A final frame is allowed to end at EOF.  raw_decode also lets us
            # consume a complete frame before a later fragmented frame arrives.
            try:
                text = bytes(stdout_buffer).decode("utf-8")
                leading = len(text) - len(text.lstrip())
                message, consumed = decoder.raw_decode(text.lstrip())
            except (UnicodeDecodeError, ValueError):
                return
            consumed += leading
            stdout_buffer = stdout_buffer[consumed:]
            handle_message(message)
            if result is not None:
                return

    while time.monotonic() < deadline:
        readable = []
        if not stdout_closed:
            readable.append(process.stdout)
        if not stderr_closed:
            readable.append(process.stderr)
        if not readable:
            break
        remaining = max(0.0, deadline - time.monotonic())
        try:
            ready, _, _ = select.select(readable, [], [], min(0.5, remaining))
        except (OSError, ValueError) as exc:
            raise CodexProtocolError("Unable to read Codex app-server output.") from exc

        if not ready:
            if process.poll() is not None:
                break
            continue

        if process.stderr in ready:
            chunk = _read_available(process.stderr, limit=8192)
            if chunk:
                if len(diagnostic) < MAX_DIAGNOSTIC_BYTES:
                    diagnostic.extend(
                        chunk[: MAX_DIAGNOSTIC_BYTES - len(diagnostic)]
                    )
            else:
                stderr_closed = True

        if process.stdout in ready:
            chunk = _read_available(process.stdout, limit=8192)
            if chunk:
                stdout_buffer.extend(chunk)
                if len(stdout_buffer) > MAX_PROTOCOL_LINE_BYTES:
                    fail(
                        "Codex app-server response exceeded the 1 MiB protocol line limit."
                    )
                consume_stdout_buffer()
                if result is not None:
                    break
            else:
                stdout_closed = True

        if process.poll() is not None and stdout_closed:
            break

    if stdout_buffer.strip():
        invalid_json_seen = True

    if result is None and time.monotonic() >= deadline:
        fail(
            "Timed out waiting for Codex app-server usage limits.",
            CodexTimeoutError,
        )

    if result is None:
        if invalid_json_seen:
            fail("Codex app-server returned invalid JSON.")
        fail("Codex app-server did not return usage limits.")

    _drain_diagnostic(process.stderr, diagnostic)
    safe_diagnostic = clean_diagnostic(
        bytes(diagnostic),
        secrets=_redaction_values(environment),
    )
    return result, safe_diagnostic, invalid_json_seen


def classify_windows(snapshot: Mapping[str, Any]) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    """Identify the recognized short and weekly windows in one limit group."""

    short: dict[str, Any] | None = None
    weekly: dict[str, Any] | None = None
    for name in ("primary", "secondary"):
        raw_window = snapshot.get(name)
        if not isinstance(raw_window, Mapping):
            continue
        duration = raw_window.get("windowDurationMins")
        used = raw_window.get("usedPercent")
        if not finite_number(duration) or duration <= 0:
            continue
        if not finite_number(used) or not 0 <= float(used) <= 100:
            continue
        window = dict(raw_window)
        if 1 <= float(duration) <= 360 and short is None:
            short = window
        elif 7 * 24 * 60 <= float(duration) <= 8 * 24 * 60 and weekly is None:
            weekly = window
    return short, weekly


def _limit_groups(result: Mapping[str, Any]) -> list[tuple[str, Mapping[str, Any]]]:
    by_id = result.get("rateLimitsByLimitId")
    if isinstance(by_id, Mapping) and by_id:
        return [
            (str(limit_id), snapshot)
            for limit_id, snapshot in by_id.items()
            if isinstance(snapshot, Mapping)
        ]
    flat = result.get("rateLimits")
    if isinstance(flat, Mapping):
        return [(str(flat.get("limitId", "default")), flat)]
    return []


def _limit_id_values(result: Mapping[str, Any]) -> list[str]:
    """Collect server IDs only long enough to redact them from diagnostics."""

    values: list[str] = []
    by_id = result.get("rateLimitsByLimitId")
    if isinstance(by_id, Mapping):
        values.extend(str(limit_id) for limit_id in by_id)
    flat = result.get("rateLimits")
    if isinstance(flat, Mapping) and "limitId" in flat:
        values.append(str(flat.get("limitId")))
    return [value for value in values if value]


def select_limit_group(
    result: Mapping[str, Any],
) -> tuple[str, dict[str, Any] | None, dict[str, Any] | None]:
    """Select one group, preferring complete recognized windows and stable IDs."""

    candidates: list[tuple[int, str, dict[str, Any] | None, dict[str, Any] | None]] = []
    for limit_id, snapshot in _limit_groups(result):
        short, weekly = classify_windows(snapshot)
        if short is not None or weekly is not None:
            candidates.append((int(short is not None) + int(weekly is not None), limit_id, short, weekly))
    if not candidates:
        raise CodexProtocolError("Codex returned no valid recognized usage window.")
    # The ID tie-breaker keeps output stable when the server changes map order.
    candidates.sort(key=lambda item: (-item[0], item[1]))
    _, selected_limit_id, short, weekly = candidates[0]
    return selected_limit_id, short, weekly


def remaining_percent(window: Mapping[str, Any] | None) -> int | float | None:
    if not window:
        return None
    used = window.get("usedPercent")
    if not finite_number(used) or not 0 <= float(used) <= 100:
        return None
    return normal_number(100 - float(used))


def reset_timestamp(window: Mapping[str, Any] | None) -> int | None:
    if not window:
        return None
    timestamp = window.get("resetsAt")
    if isinstance(timestamp, int) and not isinstance(timestamp, bool) and timestamp > snapshot_contract.SQLITE_INTEGER_MAX:
        raise CodexProtocolError("Codex returned a reset epoch outside the supported range.")
    if not finite_number(timestamp):
        return None
    try:
        numeric = float(timestamp)
    except (OverflowError, ValueError) as exc:
        raise CodexProtocolError("Codex returned a reset epoch outside the supported range.") from exc
    if numeric <= 0:
        return None
    if numeric > snapshot_contract.SQLITE_INTEGER_MAX:
        raise CodexProtocolError("Codex returned a reset epoch outside the supported range.")
    # Codex emits Unix seconds.  The public alert/archive contract historically
    # used integer Unix timestamps, so truncate fractional values deliberately.
    return int(timestamp)


def reset_label(window: Mapping[str, Any] | None) -> str:
    timestamp = reset_timestamp(window)
    if timestamp is None:
        return "unknown"
    try:
        reset = dt.datetime.fromtimestamp(float(timestamp), PARIS)
    except (OverflowError, OSError, ValueError):
        return "unknown"
    return reset.strftime("%d/%m/%Y %H:%M")


def build_snapshot(
    result: Mapping[str, Any],
    *,
    sample_interval_seconds: int,
    history_window_hours: float,
    scraped_at: str | None = None,
) -> dict[str, Any]:
    selected_limit_id, short, weekly = select_limit_group(result)
    # This is the raw app-server trust boundary.  Even a server value that
    # happens to look like our canonical ``limit-<sha256>`` representation is
    # hashed again; idempotent normalization is reserved for persisted data.
    safe_limit_id = snapshot_contract.opaque_limit_id_from_raw(selected_limit_id)
    if short is None or weekly is None:
        missing = "short" if short is None else "weekly"
        displayed_limit_id = (
            clean_diagnostic(
                safe_limit_id,
                secrets=_redaction_values(),
                maximum_bytes=100,
            )
            if safe_limit_id is not None
            else "[invalid-limit-id]"
        )
        print(
            f"[WARN] Codex returned a partial limit group '{displayed_limit_id}'; "
            f"the {missing} usage window is unavailable.",
            file=sys.stderr,
        )

    if scraped_at is None:
        scraped_at = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    snapshot = {
        "schema_version": snapshot_contract.SCHEMA_VERSION,
        "five_h_pct": remaining_percent(short),
        "five_h_reset": reset_label(short),
        "five_h_reset_at": reset_timestamp(short),
        "weekly_pct": remaining_percent(weekly),
        "weekly_reset": reset_label(weekly),
        "weekly_reset_at": reset_timestamp(weekly),
        "limit_id": safe_limit_id,
        "scraped_at": scraped_at,
        "sample_interval_seconds": sample_interval_seconds,
        "history_window_hours": history_window_hours,
    }
    try:
        return snapshot_contract.validate_snapshot(snapshot)
    except snapshot_contract.HistoryError as exc:
        raise CodexProtocolError(f"Codex returned an invalid usage snapshot: {exc}") from exc


def fetch_status(
    codex_bin: str | os.PathLike[str] = "codex",
    *,
    timeout_seconds: int | float = DEFAULT_TIMEOUT_SECONDS,
    sample_interval_seconds: int | float = 900,
    history_window_hours: int | float = 192,
    debug: bool = False,
    environment: Mapping[str, str] | None = None,
    popen_factory: Callable[..., subprocess.Popen[bytes]] | None = None,
) -> dict[str, Any]:
    """Fetch and normalize one quota snapshot from Codex."""

    try:
        timeout = float(timeout_seconds)
        interval = float(sample_interval_seconds)
        window_hours = float(history_window_hours)
    except (TypeError, ValueError, OverflowError) as exc:
        raise CodexClientError("Codex client numeric options are invalid.") from exc
    if not math.isfinite(timeout) or timeout <= 0:
        raise CodexClientError("Codex client timeout must be positive.")
    if not math.isfinite(interval) or not interval.is_integer() or not 1 <= interval <= 86_400:
        raise CodexClientError("Collection interval must be an integer from 1 to 86400.")
    if not math.isfinite(window_hours) or not 0 <= window_hours <= 8_760:
        raise CodexClientError("History window must be a number from 0 to 8760.")

    child_environment = environment_without_secrets(environment)
    factory = subprocess.Popen if popen_factory is None else popen_factory
    try:
        process = factory(
            [os.fspath(codex_bin), "app-server", "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            close_fds=True,
            env=child_environment,
            start_new_session=True,
        )
    except (OSError, ValueError) as exc:
        raise CodexClientError("Unable to start the Codex app-server.") from exc

    # With start_new_session=True the child PID is also its PGID.  Do not call
    # getpgid here: a fast-exiting leader can disappear between Popen and that
    # lookup while its descendant remains alive in the private process group.
    process_group = process.pid

    safe_diagnostic = ""
    try:
        result, safe_diagnostic, _ = _read_result(
            process,
            timeout_seconds=timeout,
            environment=environment if environment is not None else os.environ,
            debug=debug,
        )
        safe_diagnostic = clean_diagnostic(
            safe_diagnostic,
            secrets=_limit_id_values(result or {}),
        )
        snapshot = build_snapshot(
            result or {},
            sample_interval_seconds=int(interval),
            history_window_hours=normal_number(window_hours),
        )
        if debug and safe_diagnostic:
            print(f"[DEBUG] Codex diagnostic: {safe_diagnostic}", file=sys.stderr)
        return snapshot
    except CodexClientError as exc:
        if debug and safe_diagnostic:
            print(f"[DEBUG] Codex diagnostic: {safe_diagnostic}", file=sys.stderr)
        raise
    finally:
        stop_process(process, process_group=process_group)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Read Codex quota limits as a JSON snapshot.")
    parser.add_argument("--codex-bin", default="codex")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS)
    parser.add_argument("--interval", type=float, default=900)
    parser.add_argument("--history-window-hours", type=float, default=192)
    parser.add_argument("--debug", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        snapshot = fetch_status(
            args.codex_bin,
            timeout_seconds=args.timeout,
            sample_interval_seconds=args.interval,
            history_window_hours=args.history_window_hours,
            debug=args.debug,
        )
    except CodexClientError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1
    except (OSError, ValueError, TypeError) as exc:
        # Keep a CLI failure free of Python tracebacks even for malformed local
        # inputs or an unusual process implementation.
        print(f"[ERROR] Codex client failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(snapshot, ensure_ascii=False, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
