#!/usr/bin/env python3
"""Dependency-free business helpers used by monitor.sh."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import tempfile
from typing import Any, BinaryIO, TextIO
from zoneinfo import ZoneInfo


def validate_number(name: str, raw: str, minimum: str, maximum: str) -> None:
    try:
        value = float(raw)
    except ValueError as error:
        raise ValueError(
            f"{name} must be a number between {minimum} and {maximum}."
        ) from error
    if not math.isfinite(value) or not float(minimum) <= value <= float(maximum):
        raise ValueError(f"{name} must be between {minimum} and {maximum}.")


def parse_thresholds(raw: str, *, strict: bool) -> list[int]:
    parts = raw.split(",")
    if strict and (not parts or any(not part.strip() for part in parts)):
        raise ValueError(
            "ALERT_THRESHOLDS must be a comma-separated list of integers from 0 to 100."
        )
    values = []
    for part in parts:
        part = part.strip()
        if not part:
            continue
        try:
            value = int(part)
        except ValueError as error:
            if strict:
                raise ValueError("ALERT_THRESHOLDS must contain integers only.") from error
            continue
        if not 0 <= value <= 100:
            if strict:
                raise ValueError("ALERT_THRESHOLDS values must be between 0 and 100.")
            continue
        values.append(value)
    return values if strict else sorted(set(values), reverse=True)


def action_id(path: str, event: str) -> str:
    return hashlib.sha256((path + "\0" + event).encode()).hexdigest()[:24]


def check_tzdata() -> bool:
    if sys.version_info < (3, 9):
        return False
    try:
        ZoneInfo("Europe/Paris")
    except Exception:
        return False
    return True


def json_get_field(raw: str, field: str) -> Any:
    value = json.loads(raw).get(field, "")
    if value is None:
        return ""
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return value


def timestamp_to_epoch(timestamp: str) -> int:
    value = dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    return int(value.timestamp())


def gist_payload(snapshot: str, history: str) -> str:
    return json.dumps(
        {
            "files": {
                "data.json": {"content": snapshot},
                "history.json": {"content": history},
            }
        }
    )


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(
        path,
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0),
    )
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_write_from_stream(path: Path, source: BinaryIO) -> None:
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            descriptor = -1
            while chunk := source.read(1024 * 1024):
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        temporary = ""
        _fsync_directory(path.parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def _write_file_as_json_string(path: Path, output: TextIO) -> None:
    with path.open("r", encoding="utf-8") as source:
        output.write('"')
        while chunk := source.read(1024 * 1024):
            output.write(json.dumps(chunk, ensure_ascii=True)[1:-1])
        output.write('"')


def write_gist_payload(snapshot_path: Path, history_path: Path, output_path: Path) -> None:
    for path in (snapshot_path, history_path):
        if path.is_symlink() or not path.is_file():
            raise OSError(f"Gist source must be a regular file: {path}")

    descriptor, temporary = tempfile.mkstemp(
        dir=output_path.parent, prefix=f".{output_path.name}."
    )
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            descriptor = -1
            output.write('{"files":{"data.json":{"content":')
            _write_file_as_json_string(snapshot_path, output)
            output.write('},"history.json":{"content":')
            _write_file_as_json_string(history_path, output)
            output.write("}}}\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, output_path)
        temporary = ""
        _fsync_directory(output_path.parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def discord_payload(message: str) -> str:
    return json.dumps({"content": message})


def weekly_pace(weekly_pct: str, weekly_reset_at: str, scraped_at_epoch: str) -> str:
    try:
        actual = float(weekly_pct)
        reset_at = int(weekly_reset_at)
        sampled_at = int(scraped_at_epoch)
    except (TypeError, ValueError):
        return ""
    weekly_window = 7 * 24 * 60 * 60
    remaining = reset_at - sampled_at
    if not 0 <= actual <= 100 or not 0 <= remaining <= weekly_window:
        return ""
    ideal = round(100 * remaining / weekly_window, 1)
    difference = round(actual - ideal, 1)
    direction = "on pace" if difference == 0 else "above" if difference > 0 else "below"
    sign = "+" if difference > 0 else ""
    if ideal > 0:
        relative = round(abs(actual - ideal) / ideal * 100, 1)
        return f"{sign}{difference:.1f} pts · {relative:.1f}% {direction}"
    return f"{sign}{difference:.1f} pts"


def percentage_below_full(raw: str) -> bool:
    try:
        value = float(raw)
    except ValueError:
        return False
    return math.isfinite(value) and 0 <= value < 100


def threshold_crossed(
    current: str, previous: str, threshold: str, notified_csv: str = ""
) -> bool:
    current_value, previous_value, threshold_value = map(
        float, (current, previous, threshold)
    )
    notified = {item for item in notified_csv.split(",") if item}
    return (
        current_value <= threshold_value < previous_value
        and str(int(threshold_value)) not in notified
    )


def threshold_between(previous: str, critical: str, threshold: str) -> bool:
    return float(critical) <= float(threshold) < float(previous)


def update_health(path: Path, result: str, detail: str, duration: int) -> None:
    try:
        health = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    except (OSError, ValueError):
        health = {}
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    health["last_cycle"] = now
    health["last_cycle_duration_ms"] = duration
    health["last_cycle_result"] = result
    if result == "success":
        health["last_success"] = now
        health["consecutive_failures"] = 0
    else:
        health["last_error"] = {"at": now, "message": detail[:500]}
        health["consecutive_failures"] = int(health.get("consecutive_failures", 0)) + 1

    descriptor, temporary = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", text=True
    )
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(health, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    for command, count in (
        ("validate-number", 4),
        ("action-id", 2),
        ("json-get-field", 2),
        ("timestamp-to-epoch", 1),
        ("gist-payload", 2),
        ("discord-payload", 1),
        ("weekly-pace", 3),
        ("percentage-below-full", 1),
        ("threshold-between", 3),
    ):
        subparser = commands.add_parser(command)
        for index in range(count):
            subparser.add_argument(f"value{index + 1}")
    thresholds = commands.add_parser("validate-thresholds")
    thresholds.add_argument("raw")
    load = commands.add_parser("load-thresholds")
    load.add_argument("raw")
    commands.add_parser("check-tzdata")
    crossed = commands.add_parser("threshold-crossed")
    crossed.add_argument("current")
    crossed.add_argument("previous")
    crossed.add_argument("threshold")
    crossed.add_argument("notified", nargs="?", default="")
    health = commands.add_parser("update-health")
    health.add_argument("path", type=Path)
    health.add_argument("result")
    health.add_argument("detail")
    health.add_argument("duration", type=int)
    atomic_write = commands.add_parser("atomic-write")
    atomic_write.add_argument("path", type=Path)
    gist_files = commands.add_parser("gist-payload-files")
    gist_files.add_argument("snapshot", type=Path)
    gist_files.add_argument("history", type=Path)
    gist_files.add_argument("output", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    values = [
        getattr(arguments, f"value{index}")
        for index in range(1, 5)
        if hasattr(arguments, f"value{index}")
    ]
    try:
        if arguments.command == "validate-number":
            validate_number(*values)
        elif arguments.command == "validate-thresholds":
            parse_thresholds(arguments.raw, strict=True)
        elif arguments.command == "load-thresholds":
            print(*parse_thresholds(arguments.raw, strict=False), sep="\n")
        elif arguments.command == "action-id":
            print(action_id(*values))
        elif arguments.command == "check-tzdata":
            return 0 if check_tzdata() else 1
        elif arguments.command == "json-get-field":
            print(json_get_field(*values))
        elif arguments.command == "timestamp-to-epoch":
            print(timestamp_to_epoch(*values))
        elif arguments.command == "gist-payload":
            print(gist_payload(*values))
        elif arguments.command == "discord-payload":
            print(discord_payload(*values))
        elif arguments.command == "weekly-pace":
            result = weekly_pace(*values)
            if result:
                print(result)
        elif arguments.command == "percentage-below-full":
            return 0 if percentage_below_full(*values) else 1
        elif arguments.command == "threshold-crossed":
            return 0 if threshold_crossed(
                arguments.current,
                arguments.previous,
                arguments.threshold,
                arguments.notified,
            ) else 1
        elif arguments.command == "threshold-between":
            return 0 if threshold_between(*values) else 1
        elif arguments.command == "update-health":
            update_health(arguments.path, arguments.result, arguments.detail, arguments.duration)
        elif arguments.command == "atomic-write":
            atomic_write_from_stream(arguments.path, sys.stdin.buffer)
        elif arguments.command == "gist-payload-files":
            write_gist_payload(arguments.snapshot, arguments.history, arguments.output)
        return 0
    except (OSError, OverflowError, TypeError, ValueError, json.JSONDecodeError) as error:
        if arguments.command in ("validate-number", "validate-thresholds"):
            sys.stderr.write(f"[ERROR] {error}\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
