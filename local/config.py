#!/usr/bin/env python3
"""Non-executable configuration resolver shared by the local commands."""

import argparse
import ipaddress
import math
import os
import re
import stat
import sys
from pathlib import Path
from typing import Callable, Dict, Iterable, Mapping, Optional, Sequence, Tuple
from urllib.parse import urlsplit


class ConfigError(ValueError):
    """A configuration error safe to present to a command-line user."""


Validator = Callable[[str, str], str]
Default = Callable[[Mapping[str, str], Path, Mapping[str, str]], str]


def _text(name: str, value: str) -> str:
    if "\0" in value:
        raise ConfigError(f"{name} must not contain NUL characters.")
    return value


def _single_line(name: str, value: str) -> str:
    _text(name, value)
    if any(character in value for character in "\r\n"):
        raise ConfigError(f"{name} must fit on one line.")
    return value


def _nonempty(name: str, value: str) -> str:
    _single_line(name, value)
    if not value:
        raise ConfigError(f"{name} must not be empty.")
    return value


def _integer(minimum: int, maximum: int) -> Validator:
    def validate(name: str, value: str) -> str:
        if not re.fullmatch(r"[0-9]+", value):
            raise ConfigError(f"{name} must be an integer between {minimum} and {maximum}.")
        number = int(value, 10)
        if not minimum <= number <= maximum:
            raise ConfigError(f"{name} must be between {minimum} and {maximum}.")
        return value

    return validate


def _number(minimum: float, maximum: float) -> Validator:
    def validate(name: str, value: str) -> str:
        _single_line(name, value)
        try:
            number = float(value)
        except ValueError:
            raise ConfigError(f"{name} must be a number between {minimum:g} and {maximum:g}.")
        if not math.isfinite(number) or not minimum <= number <= maximum:
            raise ConfigError(f"{name} must be between {minimum:g} and {maximum:g}.")
        return value

    return validate


def _absolute_path(name: str, value: str) -> str:
    _single_line(name, value)
    if not Path(value).is_absolute() or any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ConfigError(f"{name} must be an absolute path without control characters.")
    return value


def _pricing_path(name: str, value: str) -> str:
    _absolute_path(name, value)
    path = Path(value)
    if path.is_symlink() or not path.is_file() or not os.access(path, os.R_OK):
        raise ConfigError(f"{name} must be a readable regular file, not a symbolic link.")
    return value


def _database_path(name: str, value: str) -> str:
    _absolute_path(name, value)
    if Path(value).is_symlink():
        raise ConfigError(f"{name} must not be a symbolic link.")
    return value


def _thresholds(name: str, value: str) -> str:
    _single_line(name, value)
    parts = value.split(",")
    if not parts or any(not part.strip() or not re.fullmatch(r"[0-9]+", part.strip()) for part in parts):
        raise ConfigError(f"{name} must be a comma-separated list of integers from 0 to 100.")
    if any(not 0 <= int(part.strip(), 10) <= 100 for part in parts):
        raise ConfigError(f"{name} values must be between 0 and 100.")
    return value


def _token_sources(name: str, value: str) -> str:
    if value not in ("auto", "none"):
        parts = value.split(",")
        if not parts or any(part not in ("codex", "opencode", "hermes") for part in parts):
            raise ConfigError(
                f"{name} must be auto, none, or a comma-separated list of codex,opencode,hermes."
            )
    return value


def _http_url(name: str, value: str) -> str:
    _single_line(name, value)
    error = f"{name} must be an HTTPS base URL, except HTTP is allowed for explicit loopback hosts."
    if not value or "\\" in value or any(ord(character) <= 32 or ord(character) == 127 for character in value):
        raise ConfigError(error)
    try:
        parsed = urlsplit(value)
        hostname = parsed.hostname
        port = parsed.port
    except ValueError as exc:
        raise ConfigError(error) from exc
    if (
        parsed.scheme not in ("http", "https")
        or not parsed.netloc
        or hostname is None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or (port is not None and not 1 <= port <= 65535)
    ):
        raise ConfigError(error)
    try:
        address = ipaddress.ip_address(hostname)
    except ValueError:
        address = None
        labels = hostname.split(".")
        if any(
            not label
            or len(label) > 63
            or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?", label)
            for label in labels
        ):
            raise ConfigError(error)
    is_loopback = hostname.lower() == "localhost" or (address is not None and address.is_loopback)
    if parsed.scheme != "https" and not is_loopback:
        raise ConfigError(error)
    return value


def _discord(name: str, value: str) -> str:
    _single_line(name, value)
    if value and not re.fullmatch(
        r"https://(?:discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9._-]+", value
    ):
        raise ConfigError(f"{name} must be an official Discord HTTPS webhook URL.")
    return value


def _telegram_token(name: str, value: str) -> str:
    _single_line(name, value)
    if value and not re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]+", value):
        raise ConfigError(f"{name} has an invalid format.")
    return value


def _chat_id(name: str, value: str) -> str:
    _single_line(name, value)
    if value and not re.fullmatch(r"-?[1-9][0-9]*", value):
        raise ConfigError(f"{name} must be a non-zero numeric chat ID.")
    return value


def _gist_id(name: str, value: str) -> str:
    _single_line(name, value)
    if value and not re.fullmatch(r"[A-Fa-f0-9]+", value):
        raise ConfigError(f"{name} has an invalid format.")
    return value


def _alert_events(name: str, value: str) -> str:
    events = value.split(",")
    if not events or any(not event.strip() for event in events):
        raise ConfigError(f"{name} must contain at least one event.")
    for raw_event in events:
        event = raw_event.strip()
        match = re.fullmatch(r"(5h|weekly):(reset|[0-9]+)", event)
        if not match or (match.group(2) != "reset" and int(match.group(2), 10) > 100):
            raise ConfigError(f"{name} contains an invalid event.")
    return value


def _alert_path(name: str, value: str) -> str:
    _absolute_path(name, value)
    path = Path(value)
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise ConfigError(
            f"{name} must be an executable, user-owned regular file that is not a symlink or group/world-writable."
        ) from exc
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or not os.access(path, os.X_OK)
        or (hasattr(os, "getuid") and metadata.st_uid != os.getuid())
        or stat.S_IMODE(metadata.st_mode) & 0o022
    ):
        raise ConfigError(
            f"{name} must be an executable, user-owned regular file that is not a symlink or group/world-writable."
        )
    return value


def _literal(value: str) -> Default:
    return lambda _resolved, _base_dir, _environment: value


def _home_path(suffix: str) -> Default:
    def get_default(_resolved: Mapping[str, str], _base_dir: Path, environment: Mapping[str, str]) -> str:
        home = environment.get("HOME")
        if not home:
            raise ConfigError("HOME must be set to resolve default paths.")
        return str(Path(home) / suffix)

    return get_default


def _state_default(_resolved: Mapping[str, str], base_dir: Path, environment: Mapping[str, str]) -> str:
    if (base_dir.parent / ".git").exists():
        return str(base_dir / "runtime")
    home = environment.get("HOME")
    if not home:
        raise ConfigError("HOME must be set to resolve the state directory.")
    state_home = Path(environment.get("XDG_STATE_HOME", str(Path(home) / ".local" / "state")))
    return str(state_home / "codex-usage-monitor")


def _database_default(
    resolved: Mapping[str, str], _base_dir: Path, _environment: Mapping[str, str]
) -> str:
    return str(Path(resolved["STATE_DIR"]) / "usage-history.sqlite3")


def _opencode_default(
    _resolved: Mapping[str, str], _base_dir: Path, environment: Mapping[str, str]
) -> str:
    home = environment.get("HOME")
    if not home:
        raise ConfigError("HOME must be set to resolve default paths.")
    data_home = Path(environment.get("XDG_DATA_HOME", str(Path(home) / ".local" / "share")))
    return str(data_home / "opencode" / "opencode.db")


FIELDS: Dict[str, Tuple[Default, Validator, Tuple[str, ...]]] = {
    "STATE_DIR": (_state_default, _absolute_path, ("CODEX_USAGE_MONITOR_STATE_DIR", "STATE_DIR")),
    "INVALID_ALERT_SCRIPT_CONFIG": (_literal("0"), _integer(0, 1), ("INVALID_ALERT_SCRIPT_CONFIG",)),
    "ALERT_THRESHOLDS": (_literal("75,50,25,10,5"), _thresholds, ("ALERT_THRESHOLDS",)),
    "ALERT_SCRIPT_TIMEOUT_SECONDS": (_literal("30"), _integer(1, 1800), ("ALERT_SCRIPT_TIMEOUT_SECONDS",)),
    "ARCHIVE_RETENTION_DAYS": (_literal("365"), _integer(0, 36500), ("ARCHIVE_RETENTION_DAYS",)),
    "HISTORY_RETENTION_HOURS": (_literal("192"), _number(0.25, 8760), ("HISTORY_RETENTION_HOURS",)),
    "LOOP_INTERVAL": (_literal("900"), _integer(1, 86400), ("LOOP_INTERVAL",)),
    "CODEX_BIN": (_literal("codex"), _nonempty, ("CODEX_BIN",)),
    "CODEX_STATUS_TIMEOUT_SECONDS": (_literal("20"), _integer(5, 300), ("CODEX_STATUS_TIMEOUT_SECONDS",)),
    "CURL_CONNECT_TIMEOUT_SECONDS": (_literal("5"), _integer(1, 60), ("CURL_CONNECT_TIMEOUT_SECONDS",)),
    "CURL_MAX_TIME_SECONDS": (_literal("20"), _integer(1, 600), ("CURL_MAX_TIME_SECONDS",)),
    "CURL_RETRIES": (_literal("2"), _integer(0, 5), ("CURL_RETRIES",)),
    "CURL_RETRY_DELAY_SECONDS": (_literal("1"), _integer(0, 60), ("CURL_RETRY_DELAY_SECONDS",)),
    "MONITOR_DEBUG": (_literal("0"), _integer(0, 1), ("MONITOR_DEBUG",)),
    "DISCORD_WEBHOOK": (_literal(""), _discord, ("DISCORD_WEBHOOK",)),
    "TELEGRAM_BOT_TOKEN": (_literal(""), _telegram_token, ("TELEGRAM_BOT_TOKEN",)),
    "TELEGRAM_CHAT_ID": (_literal(""), _chat_id, ("TELEGRAM_CHAT_ID",)),
    "GITHUB_PAT": (_literal(""), _single_line, ("GITHUB_PAT",)),
    "GITHUB_GIST_ID": (_literal(""), _gist_id, ("GITHUB_GIST_ID",)),
    "GITHUB_API_URL": (_literal("https://api.github.com"), _http_url, ("GITHUB_API_URL",)),
    "TELEGRAM_API_URL": (_literal("https://api.telegram.org"), _http_url, ("TELEGRAM_API_URL",)),
    "TOKEN_USAGE_SOURCES": (_literal("auto"), _token_sources, ("TOKEN_USAGE_SOURCES",)),
    "TOKEN_PRICING_FILE": (
        lambda _resolved, base_dir, _environment: str(base_dir / "pricing.json"),
        _pricing_path,
        ("TOKEN_PRICING_FILE",),
    ),
    "CODEX_DATA_DIR": (_home_path(".codex"), _absolute_path, ("CODEX_DATA_DIR",)),
    "OPENCODE_DB_PATH": (
        _opencode_default,
        _absolute_path,
        ("OPENCODE_DB_PATH",),
    ),
    "HERMES_DB_PATH": (_home_path(".hermes/state.db"), _absolute_path, ("HERMES_DB_PATH",)),
    "DASHBOARD_ANALYTICS_DATABASE": (
        _database_default,
        _database_path,
        ("DASHBOARD_ANALYTICS_DATABASE",),
    ),
}

MONITOR_KEYS = (
    "STATE_DIR",
    "ALERT_THRESHOLDS",
    "ALERT_SCRIPT_TIMEOUT_SECONDS",
    "ARCHIVE_RETENTION_DAYS",
    "HISTORY_RETENTION_HOURS",
    "LOOP_INTERVAL",
    "CODEX_BIN",
    "CODEX_STATUS_TIMEOUT_SECONDS",
    "CURL_CONNECT_TIMEOUT_SECONDS",
    "CURL_MAX_TIME_SECONDS",
    "CURL_RETRIES",
    "CURL_RETRY_DELAY_SECONDS",
    "MONITOR_DEBUG",
    "DISCORD_WEBHOOK",
    "TELEGRAM_BOT_TOKEN",
    "TELEGRAM_CHAT_ID",
    "GITHUB_PAT",
    "GITHUB_GIST_ID",
    "GITHUB_API_URL",
    "TELEGRAM_API_URL",
    "TOKEN_USAGE_SOURCES",
    "TOKEN_PRICING_FILE",
    "CODEX_DATA_DIR",
    "OPENCODE_DB_PATH",
    "HERMES_DB_PATH",
)
SERVE_KEYS = ("STATE_DIR", "DASHBOARD_ANALYTICS_DATABASE", "TOKEN_PRICING_FILE")
STATUS_KEYS = (
    "CODEX_BIN",
    "CODEX_STATUS_TIMEOUT_SECONDS",
    "MONITOR_DEBUG",
    "LOOP_INTERVAL",
    "HISTORY_RETENTION_HOURS",
)


def _absolute_without_symlinks(path: Path) -> Path:
    raw = str(path)
    if any(ord(character) < 32 or ord(character) == 127 for character in raw):
        raise ConfigError("Configuration file paths must not contain control characters.")
    return Path(os.path.abspath(os.path.expanduser(raw)))


def default_config_path(base_dir: Path, environ: Mapping[str, str]) -> Path:
    explicit = environ.get("CODEX_USAGE_MONITOR_CONFIG")
    if explicit:
        return _absolute_without_symlinks(Path(explicit))
    if (base_dir.parent / ".git").exists():
        return base_dir / ".env"
    home = environ.get("HOME")
    if not home:
        raise ConfigError("HOME must be set to resolve the configuration file.")
    config_home = Path(environ.get("XDG_CONFIG_HOME", str(Path(home) / ".config")))
    return config_home / "codex-usage-monitor" / ".env"


def _read_env_file(path: Path, required: bool) -> Dict[str, str]:
    try:
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        if required:
            raise ConfigError(f"Configuration file not found: {path}")
        return {}
    except OSError as error:
        raise ConfigError(f"Cannot open configuration file {path}: {error.strerror or error}")

    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ConfigError(f"Configuration file must be a regular file: {path}")
        if hasattr(os, "getuid") and metadata.st_uid != os.getuid():
            raise ConfigError(f"Configuration file must be owned by the current user: {path}")
        if stat.S_IMODE(metadata.st_mode) & 0o077:
            raise ConfigError(f"Configuration file permissions must be 600 or stricter: {path}")
        try:
            with os.fdopen(descriptor, "r", encoding="utf-8") as stream:
                descriptor = -1
                lines = stream.readlines()
        except OSError as error:
            raise ConfigError(f"Cannot read configuration file {path}: {error.strerror or error}")
    except UnicodeError:
        raise ConfigError(f"Configuration file is not valid UTF-8: {path}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)

    values: Dict[str, str] = {}
    for line_number, original in enumerate(lines, 1):
        line = original.rstrip("\n")
        if line.endswith("\r"):
            line = line[:-1]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if "=" not in line:
            raise ConfigError(f"Malformed configuration line {line_number} in {path}.")
        raw_key, raw_value = line.split("=", 1)
        key = raw_key.strip()
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise ConfigError(f"Invalid configuration key on line {line_number} in {path}.")
        value = raw_value.strip()
        if value[:1] in ("'", '"'):
            quote = value[0]
            if len(value) < 2 or value[-1] != quote:
                raise ConfigError(f"Unterminated quoted value on line {line_number} in {path}.")
            value = value[1:-1]
        if "\0" in value:
            raise ConfigError(f"NUL character on line {line_number} in {path} is not allowed.")
        values[key] = value
        if key.startswith("ALERT_SCRIPT_") and key != "ALERT_SCRIPT_TIMEOUT_SECONDS" and not re.fullmatch(
            r"ALERT_SCRIPT_([1-9]|[1-9][0-9])(?:_EVENTS)?", key
        ):
            values["INVALID_ALERT_SCRIPT_CONFIG"] = "1"
    return values


def _field_for(name: str) -> Tuple[Default, Validator, Tuple[str, ...]]:
    field = FIELDS.get(name)
    if field is not None:
        return field
    if re.fullmatch(r"ALERT_SCRIPT_([1-9]|[1-9][0-9])", name):
        return _literal(""), _alert_path, (name,)
    if re.fullmatch(r"ALERT_SCRIPT_([1-9]|[1-9][0-9])_EVENTS", name):
        return _literal(""), _alert_events, (name,)
    raise ConfigError(f"Unsupported configuration key: {name}")


def _profile_keys(profile: str, file_values: Mapping[str, str], environ: Mapping[str, str]) -> Sequence[str]:
    if profile == "serve":
        return SERVE_KEYS
    if profile == "status":
        return STATUS_KEYS
    keys = list(MONITOR_KEYS)
    if "INVALID_ALERT_SCRIPT_CONFIG" in file_values:
        keys.append("INVALID_ALERT_SCRIPT_CONFIG")
    dynamic = set(file_values).union(environ)
    keys.extend(
        sorted(
            name
            for name in dynamic
            if re.fullmatch(r"ALERT_SCRIPT_([1-9]|[1-9][0-9])(?:_EVENTS)?", name)
        )
    )
    return keys


def resolve_config(
    keys: Iterable[str],
    *,
    base_dir: Path,
    config_path: Optional[Path] = None,
    environ: Optional[Mapping[str, str]] = None,
    overrides: Optional[Mapping[str, str]] = None,
    config_required: bool = False,
    file_only: bool = False,
) -> Dict[str, str]:
    environment = dict(os.environ if environ is None else environ)
    base_dir = Path(base_dir).resolve()
    selected_path = _absolute_without_symlinks(config_path) if config_path else default_config_path(base_dir, environment)
    path_was_explicit = bool(environment.get("CODEX_USAGE_MONITOR_CONFIG"))
    file_values = _read_env_file(selected_path, config_required or path_was_explicit)
    requested = list(keys)
    resolved: Dict[str, str] = {}
    cli_values = dict(overrides or {})

    for name in requested:
        default, validator, environment_names = _field_for(name)
        if file_only:
            if name not in file_values:
                continue
            value = file_values[name]
        elif name in cli_values:
            value = cli_values[name]
        else:
            value = next((environment[key] for key in environment_names if key in environment), None)
            if value is None:
                value = file_values.get(name)
            if value is None:
                value = default(resolved, base_dir, environment)
        resolved[name] = validator(name, value)

    if "CURL_CONNECT_TIMEOUT_SECONDS" in resolved and "CURL_MAX_TIME_SECONDS" in resolved:
        if int(resolved["CURL_CONNECT_TIMEOUT_SECONDS"]) > int(resolved["CURL_MAX_TIME_SECONDS"]):
            raise ConfigError("CURL_CONNECT_TIMEOUT_SECONDS cannot exceed CURL_MAX_TIME_SECONDS.")
    for first, second in (("GITHUB_PAT", "GITHUB_GIST_ID"), ("TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID")):
        if first in resolved and second in resolved and bool(resolved[first]) != bool(resolved[second]):
            raise ConfigError(f"{first} and {second} must either both be set or both be empty.")
    for index in range(1, 100):
        path_name = f"ALERT_SCRIPT_{index}"
        events_name = f"{path_name}_EVENTS"
        if path_name in resolved or events_name in resolved:
            if not resolved.get(path_name) or not resolved.get(events_name):
                raise ConfigError(f"{path_name} and {events_name} must either both be set or both be empty.")
    return resolved


def resolve_profile(
    profile: str,
    *,
    base_dir: Path,
    config_path: Optional[Path] = None,
    environ: Optional[Mapping[str, str]] = None,
    overrides: Optional[Mapping[str, str]] = None,
    config_required: bool = False,
    file_only: bool = False,
) -> Dict[str, str]:
    environment = dict(os.environ if environ is None else environ)
    selected_path = (
        _absolute_without_symlinks(config_path)
        if config_path
        else default_config_path(Path(base_dir).resolve(), environment)
    )
    file_values = _read_env_file(
        selected_path,
        config_required or bool(environment.get("CODEX_USAGE_MONITOR_CONFIG")),
    )
    keys = _profile_keys(profile, file_values, environment)
    # resolve_config reopens the file securely so permission checks also cover
    # callers that use this function with a concurrently replaced file.
    return resolve_config(
        keys,
        base_dir=base_dir,
        config_path=selected_path,
        environ=environment,
        overrides=overrides,
        config_required=config_required,
        file_only=file_only,
    )


def _parse_assignment(raw: str) -> Tuple[str, str]:
    if "=" not in raw:
        raise ConfigError("CLI overrides must use KEY=VALUE.")
    key, value = raw.split("=", 1)
    _field_for(key)
    return key, value


def _emit_nul(values: Mapping[str, str]) -> None:
    output = sys.stdout.buffer
    for key, value in values.items():
        output.write(key.encode("utf-8") + b"\0" + value.encode("utf-8") + b"\0")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("monitor", "serve", "status"))
    parser.add_argument("--key", action="append", default=[])
    parser.add_argument("--base-dir", type=Path, required=True)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--config-required", action="store_true")
    parser.add_argument("--file-only", action="store_true")
    parser.add_argument("--set", dest="assignments", action="append", default=[])
    arguments = parser.parse_args(argv)
    if not arguments.profile and not arguments.key:
        parser.error("one of --profile or --key is required")

    try:
        overrides = dict(_parse_assignment(raw) for raw in arguments.assignments)
        if arguments.profile:
            values = resolve_profile(
                arguments.profile,
                base_dir=arguments.base_dir,
                config_path=arguments.config,
                overrides=overrides,
                config_required=arguments.config_required,
                file_only=arguments.file_only,
            )
        else:
            values = resolve_config(
                arguments.key,
                base_dir=arguments.base_dir,
                config_path=arguments.config,
                overrides=overrides,
                config_required=arguments.config_required,
                file_only=arguments.file_only,
            )
        _emit_nul(values)
    except (ConfigError, OSError, UnicodeError) as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
