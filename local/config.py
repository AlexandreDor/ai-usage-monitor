#!/usr/bin/env python3
"""Safe, typed configuration loading shared by the monitor and HTTP server.

The configuration file is deliberately parsed as data.  It is never imported,
evaluated, or passed to a shell.  Consumers can use :func:`load_config` from
Python or the small CLI at the bottom of this module.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
from typing import Mapping
from urllib.parse import urlsplit


KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
SCRIPT_KEY_RE = re.compile(r"^ALERT_SCRIPT_(?:[1-9]|[1-9][0-9])(?:_EVENTS)?$")
SUPPORTED_KEYS = frozenset(
    {
        "ALERT_THRESHOLDS",
        "ALERT_SCRIPT_TIMEOUT_SECONDS",
        "ARCHIVE_RETENTION_DAYS",
        "CODEX_BIN",
        "CODEX_DATA_DIR",
        "CODEX_STATUS_TIMEOUT_SECONDS",
        "CURL_CONNECT_TIMEOUT_SECONDS",
        "CURL_MAX_TIME_SECONDS",
        "CURL_RETRIES",
        "CURL_RETRY_DELAY_SECONDS",
        "DISCORD_WEBHOOK",
        "GITHUB_API_URL",
        "GITHUB_GIST_ID",
        "GITHUB_PAT",
        "HERMES_DB_PATH",
        "HISTORY_RETENTION_HOURS",
        "LOOP_INTERVAL",
        "MONITOR_DEBUG",
        "OPENCODE_DB_PATH",
        "TELEGRAM_API_URL",
        "TELEGRAM_BOT_TOKEN",
        "TELEGRAM_CHAT_ID",
        "TOKEN_PRICING_FILE",
        "TOKEN_USAGE_SOURCES",
        "DASHBOARD_ANALYTICS_DATABASE",
        "DASHBOARD_PRICING_FILE",
    }
)


class ConfigError(ValueError):
    """A configuration file or value cannot be used safely."""


def _is_supported(key: str) -> bool:
    return key in SUPPORTED_KEYS or bool(SCRIPT_KEY_RE.fullmatch(key))


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _validate_env_file(path: Path) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        raise ConfigError(f"cannot inspect configuration file: {exc}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise ConfigError(".env must be a regular file owned by the current user")
    if hasattr(os, "getuid") and info.st_uid != os.getuid():
        raise ConfigError(".env must be a regular file owned by the current user")
    # The configuration may contain credentials.  Tighten permissions when
    # possible instead of silently reading a world-readable secret file.
    if info.st_mode & 0o077:
        try:
            os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
        except OSError as exc:
            raise ConfigError(".env permissions must be restricted to the owner") from exc


def parse_env_file(path: Path | str) -> tuple[dict[str, str], list[str]]:
    """Parse a dotenv-like file without shell expansion or code execution."""

    env_path = Path(path)
    _validate_env_file(env_path)
    if not env_path.exists():
        return {}, []
    try:
        raw_lines = env_path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise ConfigError(f"cannot read .env: {exc}") from exc

    values: dict[str, str] = {}
    warnings: list[str] = []
    for line_number, raw_line in enumerate(raw_lines, 1):
        line = raw_line.rstrip("\r")
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in line:
            warnings.append(f"Ignoring malformed configuration line {line_number}.")
            continue
        key, raw_value = line.split("=", 1)
        key = key.strip()
        if not KEY_RE.fullmatch(key):
            warnings.append(f"Ignoring invalid configuration key on line {line_number}.")
            continue
        if not _is_supported(key):
            warnings.append(f"Ignoring unsupported configuration key: {key}")
            continue
        value = _unquote(raw_value)
        if any(ord(char) < 32 for char in value):
            warnings.append(f"Ignoring control characters in configuration value for {key}.")
            continue
        values[key] = value
    return values, warnings


def default_values(base_dir: Path | str, environ: Mapping[str, str] | None = None) -> dict[str, str]:
    """Return defaults anchored to the caller's project directory."""

    env = os.environ if environ is None else environ
    home = Path(env.get("HOME", str(Path.home())))
    xdg_data = Path(env.get("XDG_DATA_HOME", str(home / ".local" / "share")))
    root = Path(base_dir).resolve()
    return {
        "ALERT_THRESHOLDS": "75,50,25,10,5",
        "ALERT_SCRIPT_TIMEOUT_SECONDS": "30",
        "ARCHIVE_RETENTION_DAYS": "365",
        "CODEX_BIN": "codex",
        "CODEX_DATA_DIR": str(home / ".codex"),
        "CODEX_STATUS_TIMEOUT_SECONDS": "20",
        "CURL_CONNECT_TIMEOUT_SECONDS": "5",
        "CURL_MAX_TIME_SECONDS": "20",
        "CURL_RETRIES": "2",
        "CURL_RETRY_DELAY_SECONDS": "1",
        "DISCORD_WEBHOOK": "",
        "GITHUB_API_URL": "https://api.github.com",
        "GITHUB_GIST_ID": "",
        "GITHUB_PAT": "",
        "HERMES_DB_PATH": str(home / ".hermes" / "state.db"),
        "HISTORY_RETENTION_HOURS": "192",
        "LOOP_INTERVAL": "900",
        "MONITOR_DEBUG": "0",
        "OPENCODE_DB_PATH": str(xdg_data / "opencode" / "opencode.db"),
        "TELEGRAM_API_URL": "https://api.telegram.org",
        "TELEGRAM_BOT_TOKEN": "",
        "TELEGRAM_CHAT_ID": "",
        "TOKEN_PRICING_FILE": str(root / "pricing.json"),
        "TOKEN_USAGE_SOURCES": "auto",
        "DASHBOARD_ANALYTICS_DATABASE": str(root / "runtime" / "usage-history.sqlite3"),
        "DASHBOARD_PRICING_FILE": "",
    }


def load_config(
    env_file: Path | str,
    *,
    base_dir: Path | str | None = None,
    environ: Mapping[str, str] | None = None,
    cli: Mapping[str, str] | None = None,
    keys: set[str] | frozenset[str] | None = None,
) -> tuple[dict[str, str], list[str]]:
    """Resolve ``CLI > environment > .env > defaults`` values."""

    env = os.environ if environ is None else environ
    root = Path(base_dir) if base_dir is not None else Path(env_file).resolve().parent
    file_values, warnings = parse_env_file(env_file)
    values = default_values(root, env)
    values.update(file_values)
    values.update({key: str(value) for key, value in env.items() if _is_supported(key)})
    if cli:
        values.update({key: str(value) for key, value in cli.items() if _is_supported(key)})
    if keys is not None:
        values = {key: values.get(key, "") for key in keys}
    return values, warnings


def _integer(values: Mapping[str, str], name: str, minimum: int, maximum: int) -> int:
    raw = values.get(name, "")
    if not re.fullmatch(r"[0-9]+", raw):
        raise ConfigError(f"{name} must be an integer between {minimum} and {maximum}.")
    value = int(raw)
    if not minimum <= value <= maximum:
        raise ConfigError(f"{name} must be between {minimum} and {maximum}.")
    return value


def _number(values: Mapping[str, str], name: str, minimum: float, maximum: float) -> float:
    raw = values.get(name, "")
    try:
        value = float(raw)
    except (TypeError, ValueError) as exc:
        raise ConfigError(f"{name} must be a number between {minimum:g} and {maximum:g}.") from exc
    if not math.isfinite(value) or not minimum <= value <= maximum:
        raise ConfigError(f"{name} must be between {minimum:g} and {maximum:g}.")
    return value


def _url(values: Mapping[str, str], name: str) -> None:
    value = values.get(name, "")
    parsed = urlsplit(value)
    if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.query or parsed.fragment or parsed.username or parsed.password:
        raise ConfigError(f"{name} is not a valid HTTP(S) base URL.")


def _absolute_paths(values: Mapping[str, str]) -> None:
    for name in ("TOKEN_PRICING_FILE", "CODEX_DATA_DIR", "OPENCODE_DB_PATH", "HERMES_DB_PATH"):
        value = values.get(name, "")
        if not value.startswith("/") or any(ord(char) < 32 for char in value):
            raise ConfigError("Token analytics paths must be absolute and contain no control characters.")
    pricing = Path(values["TOKEN_PRICING_FILE"])
    if pricing.is_symlink() or not pricing.is_file() or not os.access(pricing, os.R_OK):
        raise ConfigError("TOKEN_PRICING_FILE must be a readable regular file, not a symbolic link.")


def validate_config(values: Mapping[str, str], *, check_paths: bool = True) -> None:
    """Validate monitor values and raise one readable :class:`ConfigError`."""

    _integer(values, "LOOP_INTERVAL", 1, 86400)
    _integer(values, "CODEX_STATUS_TIMEOUT_SECONDS", 5, 300)
    _integer(values, "ARCHIVE_RETENTION_DAYS", 0, 36500)
    _number(values, "HISTORY_RETENTION_HOURS", 0.25, 8760)
    _integer(values, "CURL_CONNECT_TIMEOUT_SECONDS", 1, 60)
    _integer(values, "CURL_MAX_TIME_SECONDS", 1, 600)
    _integer(values, "CURL_RETRIES", 0, 5)
    _integer(values, "CURL_RETRY_DELAY_SECONDS", 0, 60)
    _integer(values, "ALERT_SCRIPT_TIMEOUT_SECONDS", 1, 1800)
    if int(values["CURL_CONNECT_TIMEOUT_SECONDS"]) > int(values["CURL_MAX_TIME_SECONDS"]):
        raise ConfigError("CURL_CONNECT_TIMEOUT_SECONDS cannot exceed CURL_MAX_TIME_SECONDS.")

    thresholds = values.get("ALERT_THRESHOLDS", "").split(",")
    if not thresholds or any(not item.strip() or not re.fullmatch(r"[0-9]+", item.strip()) or not 0 <= int(item.strip()) <= 100 for item in thresholds):
        raise ConfigError("ALERT_THRESHOLDS must be a comma-separated list of integers from 0 to 100.")
    if values.get("MONITOR_DEBUG") not in ("0", "1"):
        raise ConfigError("MONITOR_DEBUG must be 0 or 1.")
    if values.get("TOKEN_USAGE_SOURCES") != "auto" and values.get("TOKEN_USAGE_SOURCES") != "none":
        requested = values.get("TOKEN_USAGE_SOURCES", "").split(",")
        if not requested or any(item not in {"codex", "opencode", "hermes"} for item in requested):
            raise ConfigError("TOKEN_USAGE_SOURCES must be auto, none, or a comma-separated list of codex,opencode,hermes.")

    for name in ("GITHUB_PAT", "DISCORD_WEBHOOK", "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID"):
        if any(ord(char) < 32 for char in values.get(name, "")):
            raise ConfigError("Credentials and channel identifiers must not contain control characters.")
    if bool(values.get("GITHUB_PAT")) != bool(values.get("GITHUB_GIST_ID")):
        raise ConfigError("GITHUB_PAT and GITHUB_GIST_ID must either both be set or both be empty.")
    if bool(values.get("TELEGRAM_BOT_TOKEN")) != bool(values.get("TELEGRAM_CHAT_ID")):
        raise ConfigError("TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must either both be set or both be empty.")
    if values.get("GITHUB_GIST_ID") and not re.fullmatch(r"[A-Fa-f0-9]+", values["GITHUB_GIST_ID"]):
        raise ConfigError("GITHUB_GIST_ID has an invalid format.")
    if values.get("DISCORD_WEBHOOK") and not re.fullmatch(r"https://(?:discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9._-]+", values["DISCORD_WEBHOOK"]):
        raise ConfigError("DISCORD_WEBHOOK must be an official Discord HTTPS webhook URL.")
    if values.get("TELEGRAM_BOT_TOKEN") and not re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]+", values["TELEGRAM_BOT_TOKEN"]):
        raise ConfigError("TELEGRAM_BOT_TOKEN has an invalid format.")
    if values.get("TELEGRAM_CHAT_ID") and not re.fullmatch(r"-?[1-9][0-9]*", values["TELEGRAM_CHAT_ID"]):
        raise ConfigError("TELEGRAM_CHAT_ID must be a non-zero numeric chat ID.")
    _url(values, "GITHUB_API_URL")
    _url(values, "TELEGRAM_API_URL")
    if check_paths:
        _absolute_paths(values)

    for key, path in values.items():
        match = re.fullmatch(r"ALERT_SCRIPT_([1-9]|[1-9][0-9])", key)
        if not match:
            continue
        events_key = f"{key}_EVENTS"
        events = values.get(events_key, "")
        if bool(path) != bool(events):
            raise ConfigError(f"{key} and {events_key} must either both be set or both be empty.")
        if path and (not path.startswith("/") or any(ord(char) < 32 for char in path) or not os.path.isfile(path) or not os.access(path, os.X_OK)):
            raise ConfigError(f"{key} must be an absolute path to an executable regular file.")
        for event in (part.strip() for part in events.split(",")):
            if not re.fullmatch(r"(?:5h|weekly):(?:reset|[0-9]+)", event or ""):
                raise ConfigError(f"{events_key} contains an invalid event: {event or '<empty>'}.")
            selector = event.split(":", 1)[1]
            if selector != "reset" and not 0 <= int(selector) <= 100:
                raise ConfigError(f"{events_key} threshold must be between 0 and 100.")


def _cli_values(items: list[str]) -> dict[str, str]:
    values: dict[str, str] = {}
    for item in items:
        if "=" not in item:
            raise ConfigError("--set values must use KEY=VALUE")
        key, value = item.split("=", 1)
        if not _is_supported(key):
            raise ConfigError(f"unsupported configuration key: {key}")
        values[key] = value
    return values


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", default=None)
    parser.add_argument("--base-dir", default=None)
    parser.add_argument("--get", dest="get_key")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--lines", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--set", dest="sets", action="append", default=[], metavar="KEY=VALUE")
    args = parser.parse_args(argv)
    try:
        env_file = Path(args.env_file) if args.env_file else Path(args.base_dir or Path.cwd()) / ".env"
        base_dir = Path(args.base_dir) if args.base_dir else env_file.resolve().parent
        values, warnings = load_config(env_file, base_dir=base_dir, cli=_cli_values(args.sets))
        if args.validate:
            validate_config(values)
        if args.get_key:
            if not _is_supported(args.get_key):
                raise ConfigError(f"unsupported configuration key: {args.get_key}")
            print(values.get(args.get_key, ""))
        elif args.lines:
            if any(
                "unsupported configuration key: ALERT_SCRIPT_" in warning
                for warning in warnings
            ):
                # Keep the shell consumer free from a second dotenv parser
                # while allowing it to report out-of-range indexed hooks in
                # the same validation phase as legacy monitor callers.
                print("CONFIG_INVALID_ALERT_SCRIPT\t1")
            for key in sorted(values):
                print(f"{key}\t{values[key]}")
        elif args.json:
            print(json.dumps(values, sort_keys=True, separators=(",", ":")))
        elif args.validate:
            print("[OK] configuration is valid")
        else:
            parser.print_help()
        for warning in warnings:
            print(f"[WARN] {warning}", file=sys.stderr)
        return 0
    except ConfigError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
