#!/usr/bin/env python3
"""Read usage limits from the Codex app-server over its stdio protocol."""

import argparse
import datetime
import json
import math
import os
import select
import subprocess
import sys
import time
from zoneinfo import ZoneInfo


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex-bin", default="codex", help="Codex executable")
    parser.add_argument("--timeout", type=int, default=20, help="App-server timeout in seconds")
    parser.add_argument("--interval", type=int, default=900, help="Sampling interval in seconds")
    parser.add_argument(
        "--history-window-hours",
        type=float,
        default=192,
        help="History window retained by the monitor",
    )
    parser.add_argument("--debug", action="store_true", help="Include cleaned Codex diagnostics on failure")
    return parser.parse_args(argv)


def clean_diagnostic(raw):
    text = raw.decode("utf-8", "replace")
    return "".join(char if char in "\n\t" or ord(char) >= 32 else "?" for char in text).strip()[:4096]


def finite_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def classify_windows(snapshot):
    short = weekly = None
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


def remaining_percent(window):
    if not window:
        return None
    used = window.get("usedPercent")
    if not finite_number(used) or not 0 <= used <= 100:
        return None
    remaining = 100 - used
    return int(remaining) if float(remaining).is_integer() else remaining


def reset_time(window, paris_timezone):
    if not window:
        return "unknown"
    timestamp = window.get("resetsAt")
    if not finite_number(timestamp):
        return "unknown"
    try:
        reset = datetime.datetime.fromtimestamp(timestamp, paris_timezone)
    except (OverflowError, OSError, ValueError):
        return "unknown"
    return reset.strftime("%d/%m/%Y %H:%M")


def reset_timestamp(window):
    if not window:
        return None
    timestamp = window.get("resetsAt")
    if not finite_number(timestamp) or timestamp <= 0:
        return None
    return int(timestamp)


def read_rate_limits(codex_cmd, timeout_seconds, debug):
    # Do not pass notification or storage credentials to the Codex subprocess.
    codex_environment = os.environ.copy()
    for secret_name in ("DISCORD_WEBHOOK", "GITHUB_PAT", "TELEGRAM_BOT_TOKEN"):
        codex_environment.pop(secret_name, None)

    process = subprocess.Popen(
        [codex_cmd, "app-server", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        close_fds=True,
        env=codex_environment,
    )

    def send(message):
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()

    def stop_process():
        if process.poll() is not None:
            return
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)

    send(
        {
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {"name": "codex-usage-monitor", "version": "1.0.0"},
                "capabilities": {"experimentalApi": True},
            },
        }
    )

    deadline = time.monotonic() + timeout_seconds
    result = None
    rate_limit_requested = False
    diagnostic = bytearray()

    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([process.stdout, process.stderr], [], [], 0.5)
            if not ready:
                if process.poll() is not None:
                    break
                continue

            if process.stderr in ready:
                chunk = os.read(process.stderr.fileno(), 1024)
                if len(diagnostic) < 4096:
                    diagnostic.extend(chunk[: 4096 - len(diagnostic)])
                ready.remove(process.stderr)
            if process.stdout not in ready:
                continue
            line = process.stdout.readline()
            if not line:
                break
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue

            if message.get("id") == 1 and not rate_limit_requested:
                if message.get("error"):
                    break
                send({"method": "initialized"})
                send({"id": 2, "method": "account/rateLimits/read", "params": None})
                rate_limit_requested = True
            elif message.get("id") == 2:
                result = message.get("result")
                break
    finally:
        stop_process()

    if not isinstance(result, dict):
        sys.stderr.write("[ERROR] Codex app-server did not return usage limits.\n")
        if debug and diagnostic:
            sys.stderr.write(f"[DEBUG] Codex diagnostic: {clean_diagnostic(diagnostic)}\n")
        raise SystemExit(1)
    return result, diagnostic


def build_payload(result, interval_seconds, history_window_hours, debug=False, diagnostic=b""):
    snapshots_by_id = result.get("rateLimitsByLimitId")
    if isinstance(snapshots_by_id, dict) and snapshots_by_id:
        snapshots = [(str(limit_id), snapshot) for limit_id, snapshot in snapshots_by_id.items()]
    else:
        flat = result.get("rateLimits")
        snapshots = [(str(flat.get("limitId", "default")), flat)] if isinstance(flat, dict) else []

    # Select one coherent limit group; never combine windows from different IDs.
    candidates = []
    for limit_id, snapshot in snapshots:
        if isinstance(snapshot, dict):
            short, weekly = classify_windows(snapshot)
            if short is not None or weekly is not None:
                candidates.append((int(short is not None) + int(weekly is not None), limit_id, short, weekly))

    if not candidates:
        sys.stderr.write("[ERROR] Codex returned no valid recognized usage window.\n")
        if debug and diagnostic:
            sys.stderr.write(f"[DEBUG] Codex diagnostic: {clean_diagnostic(diagnostic)}\n")
        raise SystemExit(1)

    candidates.sort(key=lambda item: item[0], reverse=True)
    _, selected_limit_id, five_hour_window, weekly_window = candidates[0]
    if five_hour_window is None or weekly_window is None:
        missing = "short" if five_hour_window is None else "weekly"
        sys.stderr.write(
            f"[WARN] Codex returned a partial limit group '{selected_limit_id}'; "
            f"the {missing} usage window is unavailable.\n"
        )

    paris_timezone = ZoneInfo("Europe/Paris")
    return {
        "five_h_pct": remaining_percent(five_hour_window),
        "five_h_reset": reset_time(five_hour_window, paris_timezone),
        "five_h_reset_at": reset_timestamp(five_hour_window),
        "weekly_pct": remaining_percent(weekly_window),
        "weekly_reset": reset_time(weekly_window, paris_timezone),
        "weekly_reset_at": reset_timestamp(weekly_window),
        "limit_id": selected_limit_id,
        "scraped_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sample_interval_seconds": interval_seconds,
        "history_window_hours": history_window_hours,
    }


def main(argv=None):
    args = parse_args(argv)
    timeout_seconds = max(5, args.timeout)
    interval_seconds = max(1, args.interval)
    result, diagnostic = read_rate_limits(args.codex_bin, timeout_seconds, args.debug)
    payload = build_payload(result, interval_seconds, args.history_window_hours, args.debug, diagnostic)
    print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    main()
