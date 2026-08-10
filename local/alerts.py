#!/usr/bin/env python3
"""Small, dependency-free helpers for alert delivery state and HTTP retries."""

from __future__ import annotations

import argparse
import datetime as dt
import email.utils
import hashlib
import json
import pathlib
import sys
import time


def stable_alert_id(kind: str, window: str, selector: str, occurrence: str) -> str:
    value = "\0".join((kind, window, selector, occurrence))
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:24]


def is_transient(curl_code: int, http_status: int) -> bool:
    if http_status in (408, 429) or 500 <= http_status <= 599:
        return True
    if 400 <= http_status <= 499:
        return False
    return curl_code != 0


def retry_after_seconds(path: pathlib.Path, now: float) -> int | None:
    try:
        lines = path.read_text(encoding="iso-8859-1", errors="replace").splitlines()
    except OSError:
        return None

    values = [line.split(":", 1)[1].strip() for line in lines if line.lower().startswith("retry-after:")]
    if not values:
        return None
    value = values[-1]
    if value.isdigit():
        return int(value)
    try:
        parsed = email.utils.parsedate_to_datetime(value)
    except (TypeError, ValueError, OverflowError):
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return max(0, int((parsed.timestamp() - now) + 0.999999))


def bounded_retry_delay(
    attempt: int,
    base_delay: int,
    maximum: int,
    headers: pathlib.Path,
    now: float,
) -> int:
    retry_after = retry_after_seconds(headers, now)
    delay = base_delay * (2 ** max(0, attempt - 1))
    if retry_after is not None:
        delay = retry_after
    return min(maximum, max(0, delay))


def telegram_delivered(path: pathlib.Path) -> bool:
    try:
        response = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return isinstance(response, dict) and response.get("ok") is True


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    id_parser = subparsers.add_parser("id")
    id_parser.add_argument("kind")
    id_parser.add_argument("window")
    id_parser.add_argument("selector")
    id_parser.add_argument("occurrence")

    retry_parser = subparsers.add_parser("retry")
    retry_parser.add_argument("curl_code", type=int)
    retry_parser.add_argument("http_status", type=int)
    retry_parser.add_argument("attempt", type=int)
    retry_parser.add_argument("base_delay", type=int)
    retry_parser.add_argument("maximum", type=int)
    retry_parser.add_argument("headers", type=pathlib.Path)
    retry_parser.add_argument("--now", type=float, default=None)

    telegram_parser = subparsers.add_parser("telegram-delivered")
    telegram_parser.add_argument("response", type=pathlib.Path)

    arguments = parser.parse_args()
    if arguments.command == "id":
        print(stable_alert_id(arguments.kind, arguments.window, arguments.selector, arguments.occurrence))
        return 0
    if arguments.command == "retry":
        transient = is_transient(arguments.curl_code, arguments.http_status)
        now = time.time() if arguments.now is None else arguments.now
        delay = bounded_retry_delay(
            arguments.attempt,
            arguments.base_delay,
            arguments.maximum,
            arguments.headers,
            now,
        )
        print(f"{'transient' if transient else 'permanent'} {delay if transient else 0}")
        return 0
    if arguments.command == "telegram-delivered":
        return 0 if telegram_delivered(arguments.response) else 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
