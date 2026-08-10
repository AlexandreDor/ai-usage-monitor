#!/usr/bin/env python3
"""Read Codex usage limits through the app-server stdio protocol."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import time
from typing import Any, Mapping
from zoneinfo import ZoneInfo


DIAGNOSTIC_LIMIT = 4096
STDOUT_BUFFER_LIMIT = 64 * 1024
SECRET_NAMES = (
    "DISCORD_WEBHOOK",
    "GITHUB_PAT",
    "GITHUB_GIST_ID",
    "TELEGRAM_BOT_TOKEN",
    "TELEGRAM_CHAT_ID",
)
CLIENT_VERSION = (Path(__file__).resolve().parent.parent / "VERSION").read_text(
    encoding="utf-8"
).strip()
REDACTION_PATTERNS = (
    re.compile(r"https://(?:discord\.com|discordapp\.com)/api/webhooks/[^\s]+"),
    re.compile(r"\b(?:github_pat_|gh[pousr]_)[A-Za-z0-9_]{16,}\b"),
    re.compile(r"\b[0-9]{5,}:[A-Za-z0-9_-]{16,}\b"),
)


class CodexStatusError(Exception):
    """An app-server response cannot produce a usage snapshot."""

    def __init__(
        self,
        message: str,
        diagnostic: bytes = b"",
        secret_values: tuple[str, ...] = (),
    ) -> None:
        super().__init__(message)
        self.diagnostic = diagnostic
        self.secret_values = secret_values


def finite_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def classify_windows(snapshot: Mapping[str, Any]) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    short = None
    weekly = None
    for name in ("primary", "secondary"):
        window = snapshot.get(name)
        if not isinstance(window, dict):
            continue
        duration = window.get("windowDurationMins")
        used = window.get("usedPercent")
        if not finite_number(duration) or duration <= 0:
            continue
        if not finite_number(used) or not 0 <= used <= 100:
            continue
        if 1 <= duration <= 360 and short is None:
            short = window
        elif 7 * 24 * 60 <= duration <= 8 * 24 * 60 and weekly is None:
            weekly = window
    return short, weekly


def _remaining_percent(window: Mapping[str, Any] | None) -> int | float | None:
    if not window:
        return None
    used = window.get("usedPercent")
    if not finite_number(used) or not 0 <= used <= 100:
        return None
    remaining = 100 - used
    return int(remaining) if float(remaining).is_integer() else remaining


def _reset_time(window: Mapping[str, Any] | None, timezone: ZoneInfo) -> str:
    if not window:
        return "unknown"
    timestamp = window.get("resetsAt")
    if not finite_number(timestamp):
        return "unknown"
    try:
        reset = dt.datetime.fromtimestamp(timestamp, timezone)
    except (OverflowError, OSError, ValueError):
        return "unknown"
    return reset.strftime("%d/%m/%Y %H:%M")


def _reset_timestamp(window: Mapping[str, Any] | None) -> int | None:
    if not window:
        return None
    timestamp = window.get("resetsAt")
    if not finite_number(timestamp) or timestamp <= 0:
        return None
    return int(timestamp)


def build_payload(
    result: Mapping[str, Any],
    interval_seconds: int,
    history_window_hours: float,
    *,
    now: dt.datetime | None = None,
) -> tuple[dict[str, Any], str | None]:
    snapshots_by_id = result.get("rateLimitsByLimitId")
    if isinstance(snapshots_by_id, dict) and snapshots_by_id:
        snapshots = [(str(limit_id), snapshot) for limit_id, snapshot in snapshots_by_id.items()]
    else:
        flat = result.get("rateLimits")
        snapshots = (
            [(str(flat.get("limitId", "default")), flat)]
            if isinstance(flat, dict)
            else []
        )

    candidates = []
    for limit_id, snapshot in snapshots:
        if isinstance(snapshot, dict):
            short, weekly = classify_windows(snapshot)
            if short is not None or weekly is not None:
                candidates.append(
                    (int(short is not None) + int(weekly is not None), limit_id, short, weekly)
                )
    if not candidates:
        raise CodexStatusError("Codex returned no valid recognized usage window.")

    candidates.sort(key=lambda item: item[0], reverse=True)
    _, selected_limit_id, five_hour_window, weekly_window = candidates[0]
    warning = None
    if five_hour_window is None or weekly_window is None:
        missing = "short" if five_hour_window is None else "weekly"
        warning = (
            f"Codex returned a partial limit group '{selected_limit_id}'; "
            f"the {missing} usage window is unavailable."
        )

    sampled_at = now or dt.datetime.now(dt.timezone.utc)
    paris_timezone = ZoneInfo("Europe/Paris")
    payload = {
        "five_h_pct": _remaining_percent(five_hour_window),
        "five_h_reset": _reset_time(five_hour_window, paris_timezone),
        "five_h_reset_at": _reset_timestamp(five_hour_window),
        "weekly_pct": _remaining_percent(weekly_window),
        "weekly_reset": _reset_time(weekly_window, paris_timezone),
        "weekly_reset_at": _reset_timestamp(weekly_window),
        "limit_id": selected_limit_id,
        "scraped_at": sampled_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sample_interval_seconds": interval_seconds,
        "history_window_hours": history_window_hours,
    }
    return payload, warning


def _send(process: subprocess.Popen[bytes], message: Mapping[str, Any]) -> None:
    if process.stdin is None:
        raise BrokenPipeError
    process.stdin.write(json.dumps(message).encode("utf-8") + b"\n")
    process.stdin.flush()


def _stop_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)


def read_rate_limits(
    codex_command: str,
    timeout_seconds: float,
    *,
    environ: Mapping[str, str] | None = None,
) -> tuple[dict[str, Any], bytes, tuple[str, ...]]:
    source_environment = dict(os.environ if environ is None else environ)
    secret_values = tuple(
        value for name in SECRET_NAMES if (value := source_environment.get(name))
    )
    codex_environment = source_environment.copy()
    for secret_name in SECRET_NAMES:
        codex_environment.pop(secret_name, None)

    try:
        process = subprocess.Popen(
            [codex_command, "app-server", "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            close_fds=True,
            env=codex_environment,
        )
    except OSError as error:
        raise CodexStatusError(
            "Codex app-server did not return usage limits.",
            secret_values=secret_values,
        ) from error

    diagnostic = bytearray()
    stdout_buffer = bytearray()
    result = None
    rate_limit_requested = False
    selector = selectors.DefaultSelector()

    def handle_message(raw_line: bytes) -> bool:
        nonlocal result, rate_limit_requested
        try:
            message = json.loads(raw_line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return False
        if not isinstance(message, dict):
            return False
        if message.get("id") == 1 and not rate_limit_requested:
            if message.get("error"):
                return True
            _send(process, {"method": "initialized"})
            _send(process, {"id": 2, "method": "account/rateLimits/read", "params": None})
            rate_limit_requested = True
        elif message.get("id") == 2:
            result = message.get("result")
            return True
        return False

    try:
        assert process.stdout is not None and process.stderr is not None
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        _send(
            process,
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "codex-usage-monitor",
                        "version": CLIENT_VERSION,
                    },
                    "capabilities": {"experimentalApi": True},
                },
            },
        )
        deadline = time.monotonic() + timeout_seconds
        finished = False
        while not finished:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            events = selector.select(min(0.5, remaining))
            if not events:
                continue
            for key, _ in sorted(events, key=lambda event: event[0].data == "stdout"):
                chunk = os.read(key.fileobj.fileno(), 4096)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                if key.data == "stderr":
                    if len(diagnostic) < DIAGNOSTIC_LIMIT:
                        diagnostic.extend(chunk[: DIAGNOSTIC_LIMIT - len(diagnostic)])
                    continue
                if len(stdout_buffer) + len(chunk) > STDOUT_BUFFER_LIMIT:
                    stdout_buffer.clear()
                    finished = True
                    break
                stdout_buffer.extend(chunk)
                while b"\n" in stdout_buffer:
                    raw_line, _, remainder = stdout_buffer.partition(b"\n")
                    stdout_buffer[:] = remainder
                    if handle_message(raw_line.rstrip(b"\r")):
                        finished = True
                        break
                if finished:
                    break
            if not selector.get_map():
                break
        if result is None and stdout_buffer:
            handle_message(bytes(stdout_buffer).rstrip(b"\r"))
    except (BrokenPipeError, OSError):
        pass
    finally:
        selector.close()
        _stop_process(process)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass

    if not isinstance(result, dict):
        raise CodexStatusError(
            "Codex app-server did not return usage limits.",
            bytes(diagnostic),
            secret_values,
        )
    return result, bytes(diagnostic), secret_values


def clean_diagnostic(raw: bytes, secret_values: tuple[str, ...]) -> str:
    text = raw.decode("utf-8", "replace")
    text = "".join(
        character if character in "\n\t" or ord(character) >= 32 else "?"
        for character in text
    )
    for secret in sorted(secret_values, key=len, reverse=True):
        text = text.replace(secret, "[REDACTED]")
    for pattern in REDACTION_PATTERNS:
        text = pattern.sub("[REDACTED]", text)
    return text.strip()[:DIAGNOSTIC_LIMIT]


def collect_status(
    codex_command: str,
    timeout_seconds: float,
    interval_seconds: int,
    history_window_hours: float,
    *,
    debug: bool = False,
    environ: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    diagnostic = b""
    secret_values: tuple[str, ...] = ()
    try:
        result, diagnostic, secret_values = read_rate_limits(
            codex_command, timeout_seconds, environ=environ
        )
        payload, warning = build_payload(result, interval_seconds, history_window_hours)
    except CodexStatusError as error:
        diagnostic = error.diagnostic or diagnostic
        secret_values = error.secret_values or secret_values
        sys.stderr.write(f"[ERROR] {error}\n")
        if debug and diagnostic:
            sys.stderr.write(
                f"[DEBUG] Codex diagnostic: {clean_diagnostic(diagnostic, secret_values)}\n"
            )
        raise
    if warning:
        sys.stderr.write(f"[WARN] {warning}\n")
    return payload


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex-bin", required=True)
    parser.add_argument("--timeout", required=True, type=int)
    parser.add_argument("--interval", required=True, type=int)
    parser.add_argument("--history-window-hours", required=True, type=float)
    parser.add_argument("--debug", action="store_true")
    arguments = parser.parse_args(argv)
    try:
        payload = collect_status(
            arguments.codex_bin,
            max(5, arguments.timeout),
            max(1, arguments.interval),
            arguments.history_window_hours,
            debug=arguments.debug,
        )
    except CodexStatusError:
        return 1
    print(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
