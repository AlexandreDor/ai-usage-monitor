#!/usr/bin/env python3
"""Shared, non-executable configuration for the monitor and dashboard server.

This module intentionally has no third-party dependencies.  The public
``parse_env_file`` and ``resolve_config`` functions are useful to tests and to
small integrations; the command line interface is the literal transport used
by the two shell entry points.
"""

from __future__ import annotations

import argparse
import base64
import errno
import hashlib
import ipaddress
import math
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any, Mapping


class ConfigurationError(ValueError):
    """An expected, user-actionable configuration error."""


KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
SCRIPT_KEY_RE = re.compile(r"^ALERT_SCRIPT_([1-9]|[1-9][0-9])(?:_EVENTS)?$")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
URL_RE = re.compile(r"^https?://[A-Za-z0-9._:/-]+$")
DISCORD_RE = re.compile(r"^https://(?:discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9._-]+$")
TELEGRAM_TOKEN_RE = re.compile(r"^[0-9]+:[A-Za-z0-9_-]+$")
CHAT_ID_RE = re.compile(r"^-?[1-9][0-9]*$")

MONITOR_KEYS = (
    "ALERTS_ENABLED", "ALERT_THRESHOLDS", "ALERT_SCRIPT_TIMEOUT_SECONDS",
    "ARCHIVE_RETENTION_DAYS", "CODEX_BIN", "CODEX_DATA_DIR",
    "CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD", "CODEX_FORECAST_6H_HIGHLIGHT_THRESHOLD",
    "CODEX_FORECAST_ENABLED", "CODEX_STATUS_TIMEOUT_SECONDS", "CURL_CONNECT_TIMEOUT_SECONDS",
    "CURL_MAX_TIME_SECONDS", "CURL_RETRIES", "CURL_RETRY_DELAY_SECONDS",
    "DASHBOARD_ACTIVE_INTERVAL_SECONDS", "DISCORD_WEBHOOK", "GITHUB_API_URL",
    "GITHUB_GIST_ID", "GITHUB_PAT", "HERMES_DB_PATH", "HISTORY_RETENTION_HOURS",
    "LOOP_INTERVAL", "MONITOR_DEBUG", "OPENCODE_DB_PATH", "TELEGRAM_API_URL",
    "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "TOKEN_PRICING_FILE", "TOKEN_USAGE_SOURCES",
)
SERVE_KEYS = ("TOKEN_PRICING_FILE", "DASHBOARD_ACTIVE_INTERVAL_SECONDS")
PROCESS_ONLY_KEYS = (
    "DASHBOARD_ANALYTICS_DATABASE", "DASHBOARD_PRICING_FILE", "CODEX_BIN_OVERRIDE",
)
SCRIPT_KEYS = frozenset(MONITOR_KEYS)


def _default_paths(script_dir: Path, environ: Mapping[str, str]) -> dict[str, str]:
    home = environ.get("HOME") or str(Path.home())
    xdg = environ.get("XDG_DATA_HOME") or str(Path(home) / ".local" / "share")
    return {
        "TOKEN_PRICING_FILE": str(script_dir / "pricing.json"),
        "CODEX_DATA_DIR": str(Path(home) / ".codex"),
        "OPENCODE_DB_PATH": str(Path(xdg) / "opencode" / "opencode.db"),
        "HERMES_DB_PATH": str(Path(home) / ".hermes" / "state.db"),
    }


DEFAULTS = {
    "ALERTS_ENABLED": "1", "ALERT_THRESHOLDS": "75,50,25,10,5",
    "ALERT_SCRIPT_TIMEOUT_SECONDS": "30", "ARCHIVE_RETENTION_DAYS": "365",
    "CODEX_BIN": "codex", "CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD": "50",
    "CODEX_FORECAST_6H_HIGHLIGHT_THRESHOLD": "25", "CODEX_FORECAST_ENABLED": "1",
    "CODEX_STATUS_TIMEOUT_SECONDS": "20", "CURL_CONNECT_TIMEOUT_SECONDS": "5",
    "CURL_MAX_TIME_SECONDS": "20", "CURL_RETRIES": "2", "CURL_RETRY_DELAY_SECONDS": "1",
    "DASHBOARD_ACTIVE_INTERVAL_SECONDS": "300", "DISCORD_WEBHOOK": "",
    "GITHUB_API_URL": "https://api.github.com", "GITHUB_GIST_ID": "", "GITHUB_PAT": "",
    "HISTORY_RETENTION_HOURS": "192", "LOOP_INTERVAL": "900", "MONITOR_DEBUG": "0",
    "TELEGRAM_API_URL": "https://api.telegram.org", "TELEGRAM_BOT_TOKEN": "",
    "TELEGRAM_CHAT_ID": "", "TOKEN_USAGE_SOURCES": "auto",
}

# A small explicit schema is kept alongside the resolver so additions cannot
# accidentally become dotenv-only or process-only by convention.  Validators
# remain centralized in ``validate_config`` below; the metadata is also useful
# to callers that need to redact diagnostics.
SENSITIVE_KEYS = frozenset({"DISCORD_WEBHOOK", "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "GITHUB_PAT"})
CONFIG_SCHEMA = {
    key: {
        "sources": ("default", "dotenv", "process", "cli"),
        "sensitive": key in SENSITIVE_KEYS,
        "default": DEFAULTS.get(key),
    }
    for key in MONITOR_KEYS
}
CONFIG_SCHEMA.update({
    key: {"sources": ("process",), "sensitive": False, "default": None}
    for key in PROCESS_ONLY_KEYS
})


def _warning(message: str, warnings: list[str]) -> None:
    warnings.append(f"[WARN] {message}")


def _read_env(path: Path) -> tuple[dict[str, str], set[str], list[str], bool]:
    """Read ``path`` as data, using a no-follow descriptor and private mode."""
    values: dict[str, str] = {}
    present: set[str] = set()
    warnings: list[str] = []
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    except FileNotFoundError:
        return values, present, warnings, False
    except OSError as error:
        if error.errno in (errno.ELOOP, errno.EMLINK):
            raise ConfigurationError("local/.env must be a regular file owned by the current user") from None
        raise ConfigurationError("local/.env cannot be opened safely") from None
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise ConfigurationError("local/.env must be a regular file owned by the current user")
        try:
            os.fchmod(descriptor, 0o600)
        except OSError:
            raise ConfigurationError("local/.env permissions cannot be secured") from None
        chunks: list[bytes] = []
        size = 0
        limit = 8 * 1024 * 1024
        try:
            while True:
                chunk = os.read(descriptor, min(1024 * 1024, limit + 1 - size))
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
                if size > limit:
                    raise ConfigurationError("local/.env is too large")
        except OSError:
            raise ConfigurationError("local/.env cannot be read safely") from None
        raw = b"".join(chunks)
    finally:
        os.close(descriptor)
    if len(raw) > 8 * 1024 * 1024:
        raise ConfigurationError("local/.env is too large")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise ConfigurationError("local/.env must be valid UTF-8") from None
    for line in text.splitlines():
        line = line[:-1] if line.endswith("\r") else line
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in line:
            _warning("Ignoring malformed configuration line", warnings)
            continue
        key, value = line.split("=", 1)
        if not KEY_RE.fullmatch(key):
            _warning("Ignoring invalid configuration key", warnings)
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key not in SCRIPT_KEYS and not SCRIPT_KEY_RE.fullmatch(key):
            _warning(f"Ignoring unsupported configuration key {key}", warnings)
            continue
        values[key] = value
        present.add(key)
    return values, present, warnings, True


def parse_env_file(path: str | os.PathLike[str], *, known_keys: set[str] | None = None) -> tuple[dict[str, str], list[str]]:
    """Return supported key/value pairs and safe warnings from a dotenv file."""
    values, _, warnings, _ = _read_env(Path(path))
    if known_keys is None:
        return values, warnings
    return {key: value for key, value in values.items() if key in known_keys or SCRIPT_KEY_RE.fullmatch(key)}, warnings


def _has_control(value: str) -> bool:
    return bool(CONTROL_RE.search(value))


def _integer(config: dict[str, str], key: str, minimum: int, maximum: int) -> str:
    value = config.get(key, "")
    if not re.fullmatch(r"[0-9]+", value):
        raise ConfigurationError(f"{key} must be an integer between {minimum} and {maximum}")
    try:
        number = int(value, 10)
    except ValueError:
        raise ConfigurationError(f"{key} must be between {minimum} and {maximum}") from None
    if not minimum <= number <= maximum:
        raise ConfigurationError(f"{key} must be between {minimum} and {maximum}")
    normalized = str(number)
    config[key] = normalized
    return normalized


def _number(config: dict[str, str], key: str, minimum: float, maximum: float) -> str:
    value = config.get(key, "")
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise ConfigurationError(f"{key} must be a number between {minimum:g} and {maximum:g}") from None
    if not math.isfinite(number) or not minimum <= number <= maximum:
        raise ConfigurationError(f"{key} must be between {minimum:g} and {maximum:g}")
    return value


def _validate_path(value: str, key: str, *, require_file: bool = False, executable: bool = False) -> None:
    if not value or not value.startswith("/") or _has_control(value):
        raise ConfigurationError(f"{key} must be an absolute path without control characters")
    path = Path(value)
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        if require_file:
            raise ConfigurationError(f"{key} must be a readable regular file, not a symbolic link") from None
        if executable:
            raise ConfigurationError(f"{key} must be an absolute path to an executable regular file") from None
        return
    except OSError:
        raise ConfigurationError(f"{key} cannot be inspected safely") from None
    if stat.S_ISLNK(metadata.st_mode):
        if executable:
            raise ConfigurationError(f"{key} must be an absolute path to an executable regular file")
        raise ConfigurationError(f"{key} must be a readable regular file, not a symbolic link")
    if require_file and not stat.S_ISREG(metadata.st_mode):
        raise ConfigurationError(f"{key} must be a readable regular file, not a symbolic link")
    if require_file:
        if not (metadata.st_mode & (stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)) or not os.access(path, os.R_OK) \
                or (executable and not (metadata.st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))) \
                or (executable and not os.access(path, os.X_OK)):
            raise ConfigurationError(f"{key} must be a readable regular file, not a symbolic link")
    elif executable and (not stat.S_ISREG(metadata.st_mode) or not os.access(path, os.X_OK)):
        raise ConfigurationError(f"{key} must be an absolute path to an executable regular file")


def _validate_pricing(path: str) -> None:
    _validate_path(path, "TOKEN_PRICING_FILE", require_file=True)


def _validate_scripts(config: Mapping[str, str]) -> list[dict[str, str]]:
    rules: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for index in range(1, 100):
        path_key, events_key = f"ALERT_SCRIPT_{index}", f"ALERT_SCRIPT_{index}_EVENTS"
        path, events = config.get(path_key, ""), config.get(events_key, "")
        if not path and not events:
            continue
        if not path or not events:
            raise ConfigurationError(f"{path_key} and {events_key} must either both be set or both be empty")
        _validate_path(path, path_key, executable=True)
        raw_events = events.split(",")
        if not raw_events or any(not item.strip() for item in raw_events):
            raise ConfigurationError(f"{events_key} must contain at least one event")
        for raw_event in raw_events:
            event = raw_event.strip()
            match = re.fullmatch(r"(5h|weekly):(reset|[0-9]+)", event)
            if not match:
                raise ConfigurationError(f"{events_key} contains an invalid event")
            window, selector = match.groups()
            if selector != "reset":
                value = int(selector, 10)
                if not 0 <= value <= 100:
                    raise ConfigurationError(f"{events_key} threshold must be between 0 and 100")
                event = f"{window}:{value}"
            pair = (path, event)
            if pair in seen:
                raise ConfigurationError("Duplicate alert script action")
            seen.add(pair)
            rules.append({
                "index": str(index), "path": path, "event": event,
                "id": hashlib.sha256((path + "\0" + event).encode("utf-8")).hexdigest()[:24],
            })
    # Invalid numbered names are rejected even when they arrived through the
    # process mapping (the dotenv parser already warns and ignores them).
    for key in config:
        if key.startswith("ALERT_SCRIPT_") and key not in {"ALERT_SCRIPT_TIMEOUT_SECONDS"} and not SCRIPT_KEY_RE.fullmatch(key):
            raise ConfigurationError("Alert script indices must be integers from 1 to 99")
    return rules


def validate_config(config: Mapping[str, str], *, profile: str = "monitor") -> tuple[dict[str, str], list[dict[str, str]]]:
    """Validate and normalize a resolved config, returning values and rules."""
    values = {str(key): str(value) for key, value in config.items()}
    keys = set(MONITOR_KEYS) if profile == "monitor" else set(SERVE_KEYS)
    if profile not in {"monitor", "serve"}:
        raise ConfigurationError("unknown configuration profile")
    for key in keys:
        values.setdefault(key, "")
    if profile == "monitor" and "CODEX_BIN" not in config:
        values["CODEX_BIN"] = "codex"
    if profile == "serve":
        _integer(values, "DASHBOARD_ACTIVE_INTERVAL_SECONDS", 30, 86400)
        _validate_pricing(values["TOKEN_PRICING_FILE"])
        return values, []

    for key in ("ALERTS_ENABLED", "CODEX_FORECAST_ENABLED", "MONITOR_DEBUG"):
        if values.get(key) not in {"0", "1"}:
            raise ConfigurationError(f"{key} must be 0 or 1")
    for key, low, high in (
        ("ALERT_SCRIPT_TIMEOUT_SECONDS", 1, 1800), ("LOOP_INTERVAL", 1, 86400),
        ("DASHBOARD_ACTIVE_INTERVAL_SECONDS", 30, 86400), ("CODEX_STATUS_TIMEOUT_SECONDS", 5, 300),
        ("ARCHIVE_RETENTION_DAYS", 0, 36500), ("CURL_CONNECT_TIMEOUT_SECONDS", 1, 60),
        ("CURL_MAX_TIME_SECONDS", 1, 600), ("CURL_RETRIES", 0, 5),
        ("CURL_RETRY_DELAY_SECONDS", 0, 60), ("CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD", 0, 100),
        ("CODEX_FORECAST_6H_HIGHLIGHT_THRESHOLD", 0, 100),
    ):
        _integer(values, key, low, high)
    _number(values, "HISTORY_RETENTION_HOURS", 0.25, 8760)
    if int(values["CURL_CONNECT_TIMEOUT_SECONDS"]) > int(values["CURL_MAX_TIME_SECONDS"]):
        raise ConfigurationError("CURL_CONNECT_TIMEOUT_SECONDS cannot exceed CURL_MAX_TIME_SECONDS")
    thresholds = values.get("ALERT_THRESHOLDS", "").split(",")
    if not thresholds or any(not item.strip() or not re.fullmatch(r"[0-9]+", item.strip()) for item in thresholds):
        raise ConfigurationError("ALERT_THRESHOLDS must be a comma-separated list of integers from 0 to 100")
    normalized_thresholds = []
    for item in thresholds:
        number = int(item.strip(), 10)
        if not 0 <= number <= 100:
            raise ConfigurationError("ALERT_THRESHOLDS values must be between 0 and 100")
        normalized_thresholds.append(str(number))
    values["ALERT_THRESHOLDS"] = ",".join(normalized_thresholds)
    if (values["GITHUB_PAT"] == "") != (values["GITHUB_GIST_ID"] == ""):
        raise ConfigurationError("GITHUB_PAT and GITHUB_GIST_ID must either both be set or both be empty")
    if values["GITHUB_GIST_ID"] and not re.fullmatch(r"[A-Fa-f0-9]+", values["GITHUB_GIST_ID"]):
        raise ConfigurationError("GITHUB_GIST_ID has an invalid format")
    if (values["TELEGRAM_BOT_TOKEN"] == "") != (values["TELEGRAM_CHAT_ID"] == ""):
        raise ConfigurationError("TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must either both be set or both be empty")
    if values["DISCORD_WEBHOOK"] and not DISCORD_RE.fullmatch(values["DISCORD_WEBHOOK"]):
        raise ConfigurationError("DISCORD_WEBHOOK must be an official Discord HTTPS webhook URL")
    if values["TELEGRAM_BOT_TOKEN"] and not TELEGRAM_TOKEN_RE.fullmatch(values["TELEGRAM_BOT_TOKEN"]):
        raise ConfigurationError("TELEGRAM_BOT_TOKEN has an invalid format")
    if values["TELEGRAM_CHAT_ID"] and not CHAT_ID_RE.fullmatch(values["TELEGRAM_CHAT_ID"]):
        raise ConfigurationError("TELEGRAM_CHAT_ID must be a non-zero numeric chat ID")
    for key in ("GITHUB_PAT", "DISCORD_WEBHOOK", "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "CODEX_BIN", "GITHUB_API_URL", "TELEGRAM_API_URL", "TOKEN_USAGE_SOURCES"):
        if _has_control(values[key]):
            raise ConfigurationError(f"{key} must not contain control characters")
    if not values["CODEX_BIN"]:
        raise ConfigurationError("CODEX_BIN must not be empty")
    if not URL_RE.fullmatch(values["GITHUB_API_URL"]):
        raise ConfigurationError("GITHUB_API_URL is not a valid HTTP(S) base URL")
    if not URL_RE.fullmatch(values["TELEGRAM_API_URL"]):
        raise ConfigurationError("TELEGRAM_API_URL is not a valid HTTP(S) base URL")
    if values["TOKEN_USAGE_SOURCES"] != "auto" and values["TOKEN_USAGE_SOURCES"] != "none" and not re.fullmatch(r"(?:codex|opencode|hermes)(?:,(?:codex|opencode|hermes))*", values["TOKEN_USAGE_SOURCES"]):
        raise ConfigurationError("TOKEN_USAGE_SOURCES must be auto, none, or a comma-separated list of codex,opencode,hermes")
    for key in ("TOKEN_PRICING_FILE", "CODEX_DATA_DIR", "OPENCODE_DB_PATH", "HERMES_DB_PATH"):
        _validate_path(values[key], key)
    _validate_pricing(values["TOKEN_PRICING_FILE"])
    rules = _validate_scripts(values)
    return values, rules


def resolve_config(
    *, profile: str = "monitor", env_file: str | os.PathLike[str] | None = None,
    environ: Mapping[str, str] | None = None, cli: Mapping[str, str] | None = None,
    script_dir: str | os.PathLike[str] | None = None,
) -> dict[str, Any]:
    """Resolve defaults, dotenv, process environment, and CLI in that order."""
    environ = dict(os.environ if environ is None else environ)
    root = Path(script_dir or Path(__file__).resolve().parent).resolve()
    defaults = dict(DEFAULTS)
    defaults.update(_default_paths(root, environ))
    if profile == "serve":
        defaults = {key: defaults[key] for key in SERVE_KEYS}
        dotenv_keys = set(SERVE_KEYS)
    elif profile == "monitor":
        dotenv_keys = set(MONITOR_KEYS)
    else:
        raise ConfigurationError("unknown configuration profile")
    dotenv: dict[str, str] = {}
    warnings: list[str] = []
    invalid_script_key = False
    if env_file is not None:
        parsed, _, warnings, _ = _read_env(Path(env_file))
        dotenv = {key: value for key, value in parsed.items() if key in dotenv_keys or SCRIPT_KEY_RE.fullmatch(key)}
        invalid_script_key = any("ALERT_SCRIPT_" in warning for warning in warnings)
    resolved = dict(defaults)
    process_values = {
        key: value for key, value in environ.items()
        if key in dotenv_keys or (profile == "monitor" and SCRIPT_KEY_RE.fullmatch(key))
    }
    if profile == "monitor":
        invalid_script_key = invalid_script_key or any(
            key.startswith("ALERT_SCRIPT_")
            and key != "ALERT_SCRIPT_TIMEOUT_SECONDS"
            and not SCRIPT_KEY_RE.fullmatch(key)
            for key in environ
        )
    for source in (dotenv, process_values, cli or {}):
        for key, value in source.items():
            if key in resolved or (profile == "monitor" and SCRIPT_KEY_RE.fullmatch(key)):
                resolved[key] = str(value)
    if profile == "monitor":
        if invalid_script_key:
            raise ConfigurationError("Alert script indices must be integers from 1 to 99")
        # Process-only CODEX_BIN_OVERRIDE is deliberately not accepted by .env.
        if "CODEX_BIN_OVERRIDE" in environ:
            resolved["CODEX_BIN"] = environ["CODEX_BIN_OVERRIDE"]
        values, rules = validate_config(resolved, profile=profile)
    else:
        pricing = environ.get("DASHBOARD_PRICING_FILE", environ.get("TOKEN_PRICING_FILE", resolved["TOKEN_PRICING_FILE"]))
        # The process-only pricing alias wins over every ordinary source.
        if "DASHBOARD_PRICING_FILE" in environ:
            pricing = environ["DASHBOARD_PRICING_FILE"]
        else:
            pricing = environ.get("TOKEN_PRICING_FILE", resolved["TOKEN_PRICING_FILE"])
        resolved["TOKEN_PRICING_FILE"] = pricing
        if "DASHBOARD_ACTIVE_INTERVAL_SECONDS" in environ:
            resolved["DASHBOARD_ACTIVE_INTERVAL_SECONDS"] = environ["DASHBOARD_ACTIVE_INTERVAL_SECONDS"]
        if cli and "bind" in cli:
            resolved["BIND_ADDRESS"] = str(cli["bind"])
        else:
            resolved["BIND_ADDRESS"] = "127.0.0.1"
        if cli and "port" in cli:
            resolved["PORT"] = str(cli["port"])
        else:
            resolved["PORT"] = "8080"
        database = environ.get("DASHBOARD_ANALYTICS_DATABASE", str(root / "runtime" / "usage-history.sqlite3"))
        resolved["ANALYTICS_DATABASE_PATH"] = database
        values, rules = validate_config(resolved, profile=profile)
        _validate_path(database, "DASHBOARD_ANALYTICS_DATABASE")
        if not re.fullmatch(r"[0-9]+", values["PORT"]) or not 1 <= int(values["PORT"]) <= 65535:
            raise ConfigurationError("Port must be an integer between 1 and 65535")
        try:
            ipaddress.ip_address(values["BIND_ADDRESS"])
        except ValueError:
            raise ConfigurationError("Bind address must be a valid IPv4 or IPv6 address") from None
        values.update({"BIND_ADDRESS": values["BIND_ADDRESS"], "PORT": values["PORT"], "ANALYTICS_DATABASE_PATH": database})
    values["_warnings"] = warnings
    values["_invalid_script_key"] = invalid_script_key
    values["_rules"] = rules
    return values


def _emit(values: Mapping[str, Any], *, profile: str) -> None:
    """Emit key/base64(value) NUL records; never emit shell syntax."""
    for key, value in values.items():
        if key.startswith("_") or not isinstance(value, str):
            continue
        encoded = base64.b64encode(value.encode("utf-8")).decode("ascii")
        sys.stdout.buffer.write(f"{key}\t{encoded}\0".encode("ascii"))
    for index, rule in enumerate(values.get("_rules", [])):
        for suffix in ("INDEX", "PATH", "EVENT", "ID"):
            key = f"ALERT_SCRIPT_RULE_{suffix}_{index}"
            value = rule[{"INDEX": "index", "PATH": "path", "EVENT": "event", "ID": "id"}[suffix]]
            encoded = base64.b64encode(value.encode("utf-8")).decode("ascii")
            sys.stdout.buffer.write(f"{key}\t{encoded}\0".encode("ascii"))


def _parse_values_nul(stream: Any) -> dict[str, str]:
    raw = stream.buffer.read() if hasattr(stream, "buffer") else stream.read()
    chunks = raw.split(b"\0")
    result: dict[str, str] = {}
    for chunk in chunks:
        if not chunk:
            continue
        try:
            key, encoded = chunk.split(b"\t", 1)
            result[key.decode("ascii")] = base64.b64decode(encoded, validate=True).decode("utf-8")
        except (ValueError, UnicodeError):
            raise ConfigurationError("invalid configuration transport") from None
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--profile", choices=("monitor", "serve"), required=True)
    parser.add_argument("--env-file")
    parser.add_argument("--script-dir", default=str(Path(__file__).resolve().parent))
    parser.add_argument("--loop")
    parser.add_argument("--bind")
    parser.add_argument("--port")
    parser.add_argument("--parse-env", action="store_true")
    parser.add_argument("--validate-nul", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.validate_nul:
            values = _parse_values_nul(sys.stdin)
            normalized, rules = validate_config(values, profile=args.profile)
            normalized["_rules"] = rules
            _emit(normalized, profile=args.profile)
            return 0
        if args.parse_env:
            parsed, _, warnings, _ = _read_env(Path(args.env_file))
            for warning in warnings:
                print(warning, file=sys.stderr)
            _emit({key: value for key, value in parsed.items()}, profile=args.profile)
            return 0
        cli: dict[str, str] = {}
        if args.loop is not None:
            cli["LOOP_INTERVAL"] = args.loop
        if args.bind is not None:
            cli["bind"] = args.bind
        if args.port is not None:
            cli["port"] = args.port
        values = resolve_config(profile=args.profile, env_file=args.env_file, cli=cli, script_dir=args.script_dir)
        for warning in values.get("_warnings", []):
            print(warning, file=sys.stderr)
        if values.get("_invalid_script_key"):
            print("[WARN] Ignoring invalid alert script key", file=sys.stderr)
        _emit(values, profile=args.profile)
        return 0
    except ConfigurationError as error:
        if "Alert script indices" in str(error):
            print("[WARN] Ignoring invalid alert script key", file=sys.stderr)
        print(f"[ERROR] {error}.", file=sys.stderr)
        return 1
    except OSError:
        print("[ERROR] Configuration could not be read safely.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
