#!/usr/bin/env python3
"""Durable per-channel delivery journal for monitor network alerts."""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import email.utils
import hashlib
import json
import math
import os
import pathlib
import re
import stat
import sys
import tempfile
from typing import Any, Iterable


SCHEMA_VERSION = 2
LEGACY_SCHEMA_VERSION = 1
LIMIT_ID_CONTRACT_VERSION = 1
MAX_BYTES = 16 * 1024 * 1024
RETENTION_SECONDS = 30 * 24 * 60 * 60
MAX_RECONCILED_TERMINAL = 500
MAX_RETRY_DELAY = 24 * 60 * 60

KINDS = {"threshold", "reset", "anomaly"}
WINDOWS = {"5h", "weekly"}
ANOMALY_TYPES = {
    "quota_increase", "reset_shift", "reset_in_past", "reset_missing",
    "reset_oscillation",
}
CHANNELS = {"discord", "telegram"}
CHANNEL_STATUSES = {"pending", "delivered", "failed"}
ALERT_STATUSES = CHANNEL_STATUSES
ERROR_CLASSES = {
    "client_error", "rate_limited", "server_error", "timeout",
    "transport_error", "invalid_response", "channel_unconfigured",
    "superseded", "expired_after_reset", "owner_interrupted", "local_observed",
}
TERMINAL_REASONS = {
    "delivered", "permanent_failure", "superseded",
    "expired_after_reset", "channel_unconfigured", "owner_interrupted",
    "local_observed",
}
OPAQUE_LIMIT_ID_RE = re.compile(r"limit-[0-9a-f]{64}\Z")
LEGACY_NAMESPACE_RE = re.compile(r"legacy-v[0-9]+\Z")


class JournalError(ValueError):
    pass


def opaque_limit_id_from_raw(value: Any) -> str | None:
    """Hash one legacy protocol identifier at the journal trust boundary."""

    if not isinstance(value, str) or not value:
        return None
    digest = hashlib.sha256(value.encode("utf-8", "surrogatepass")).hexdigest()
    return f"limit-{digest}"


def canonicalize_limit_id(value: Any) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    if OPAQUE_LIMIT_ID_RE.fullmatch(value):
        return value
    return opaque_limit_id_from_raw(value)


def _is_int(value: Any, minimum: int = 0) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def alert_id(kind: str, window: str, selector: str, cycle_key: str,
             namespace: str = "alert-v1") -> str:
    material = "\0".join((namespace, kind, window, selector, cycle_key))
    return hashlib.sha256(material.encode("utf-8")).hexdigest()[:24]


def _namespace_for_cycle(cycle_key: str) -> str:
    prefix = cycle_key.split("|", 1)[0]
    return prefix if LEGACY_NAMESPACE_RE.fullmatch(prefix) else "alert-v1"


def _limit_segment_index(cycle_key: str, limit_id: str) -> int:
    """Return the sole exact limit segment belonging to an alert event."""

    if (not isinstance(cycle_key, str) or not isinstance(limit_id, str)
            or not limit_id or "|" in limit_id):
        raise JournalError("cycle key does not contain exactly one event limit ID")
    segments = cycle_key.split("|")
    limit_indexes = [index for index, segment in enumerate(segments)
                     if segment.startswith("limit:")]
    expected = f"limit:{limit_id}"
    matching = [index for index in limit_indexes if segments[index] == expected]
    if len(limit_indexes) != 1 or len(matching) != 1:
        raise JournalError("cycle key does not contain exactly one event limit ID")
    return matching[0]


def _replace_limit_segment(cycle_key: str, old_limit_id: str,
                           new_limit_id: str) -> str:
    """Replace one exact ``limit:<id>`` segment without substring matches."""

    if (not isinstance(new_limit_id, str) or not new_limit_id
            or "|" in new_limit_id):
        raise JournalError("cycle key replacement has an invalid event limit ID")
    segments = cycle_key.split("|")
    index = _limit_segment_index(cycle_key, old_limit_id)
    segments[index] = f"limit:{new_limit_id}"
    return "|".join(segments)


def empty_journal(source_version: int, completed_at: int) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "limit_id_contract_version": LIMIT_ID_CONTRACT_VERSION,
        "legacy_migration": {
            "source_state_version": source_version,
            "completed_at": completed_at,
        },
        "alerts": [],
    }


def _validate_channel(name: str, channel: Any) -> None:
    if name not in CHANNELS or not isinstance(channel, dict):
        raise JournalError("invalid channel entry")
    required = {
        "status", "attempt_count", "last_attempt_at", "next_attempt_at",
        "last_http_status", "last_curl_code", "error_class",
    }
    if set(channel) != required or channel["status"] not in CHANNEL_STATUSES:
        raise JournalError("invalid channel state")
    for key in ("attempt_count", "last_attempt_at", "next_attempt_at"):
        if not _is_int(channel[key]):
            raise JournalError(f"invalid channel {key}")
    for key in ("last_http_status", "last_curl_code"):
        if channel[key] is not None and not _is_int(channel[key]):
            raise JournalError(f"invalid channel {key}")
    if channel["last_http_status"] is not None and channel["last_http_status"] > 599:
        raise JournalError("invalid HTTP status")
    if channel["last_curl_code"] is not None and channel["last_curl_code"] > 255:
        raise JournalError("invalid curl code")
    if channel["error_class"] is not None and channel["error_class"] not in ERROR_CLASSES:
        raise JournalError("invalid channel error_class")
    if channel["status"] == "delivered" and channel["error_class"] is not None:
        raise JournalError("delivered channel has an error")


def _validate_alert(item: Any, *, require_opaque_limit_id: bool = False) -> None:
    if not isinstance(item, dict):
        raise JournalError("alert must be an object")
    required = {
        "alert_id", "kind", "window", "selector", "cycle_key", "message",
        "event_data", "created_at", "expires_at", "status", "terminal_reason",
        "replacement_alert_id", "channels", "completed_at",
        "detector_acknowledged_at",
    }
    if set(item) != required:
        raise JournalError("invalid alert fields")
    if not isinstance(item["alert_id"], str) or not re.fullmatch(r"[a-f0-9]{24}", item["alert_id"]):
        raise JournalError("invalid alert_id")
    if item["kind"] not in KINDS or item["window"] not in WINDOWS:
        raise JournalError("invalid alert kind or window")
    if not isinstance(item["selector"], str) or not item["selector"]:
        raise JournalError("invalid selector")
    if item["kind"] == "reset" and item["selector"] != "reset":
        raise JournalError("invalid reset selector")
    if item["kind"] == "threshold":
        try:
            threshold = int(item["selector"])
        except (TypeError, ValueError):
            raise JournalError("invalid threshold selector") from None
        if not 0 <= threshold <= 100 or str(threshold) != item["selector"]:
            raise JournalError("invalid threshold selector")
    if (not isinstance(item["cycle_key"], str) or not item["cycle_key"]
            or any(ord(character) < 32 for character in item["cycle_key"])):
        raise JournalError("invalid cycle_key")
    if not isinstance(item["message"], str) or not item["message"]:
        raise JournalError("invalid message")
    if not isinstance(item["event_data"], dict):
        raise JournalError("invalid event_data")
    event = item["event_data"]
    if (not isinstance(event.get("limit_id"), str)
            or not event["limit_id"]
            or any(ord(character) < 32 for character in event["limit_id"])):
        raise JournalError("invalid event limit_id")
    if require_opaque_limit_id and not OPAQUE_LIMIT_ID_RE.fullmatch(event["limit_id"]):
        raise JournalError("event limit_id is not an opaque identifier")
    if not _is_int(event.get("reset_epoch")):
        raise JournalError("invalid event reset_epoch")
    if item["kind"] == "threshold":
        if set(event) != {"limit_id", "remaining_pct", "reset_epoch", "covered_thresholds"}:
            raise JournalError("invalid threshold event_data")
        remaining = event["remaining_pct"]
        if (not isinstance(remaining, (int, float)) or isinstance(remaining, bool)
                or not math.isfinite(remaining) or not 0 <= remaining <= 100):
            raise JournalError("invalid remaining_pct")
        covered = event["covered_thresholds"]
        if (not isinstance(covered, list) or len(set(covered)) != len(covered)
                or any(not _is_int(value) or value > 100 for value in covered)):
            raise JournalError("invalid covered_thresholds")
    elif item["kind"] == "reset":
        if set(event) != {"limit_id", "reset_epoch"}:
            raise JournalError("invalid reset event_data")
    else:
        if item["selector"] not in ANOMALY_TYPES:
            raise JournalError("invalid anomaly selector")
        if set(event) != {
            "limit_id", "reset_epoch", "before_pct", "after_pct",
            "before_reset_at", "after_reset_at", "detected_at_epoch",
        }:
            raise JournalError("invalid anomaly event_data")
        for key in ("before_pct", "after_pct"):
            value = event[key]
            if (not isinstance(value, (int, float)) or isinstance(value, bool)
                    or not math.isfinite(value) or not 0 <= value <= 100):
                raise JournalError(f"invalid anomaly {key}")
        for key in ("before_reset_at", "after_reset_at", "detected_at_epoch"):
            if not _is_int(event[key]):
                raise JournalError(f"invalid anomaly {key}")
    _limit_segment_index(item["cycle_key"], event["limit_id"])
    namespace = _namespace_for_cycle(item["cycle_key"])
    if item["alert_id"] != alert_id(
            item["kind"], item["window"], item["selector"],
            item["cycle_key"], namespace):
        raise JournalError("alert_id is inconsistent with alert identity")
    if not _is_int(item["created_at"]) or not _is_int(item["expires_at"]):
        raise JournalError("invalid alert timestamps")
    if item["expires_at"] and item["expires_at"] < item["created_at"]:
        raise JournalError("expires_at predates created_at")
    if item["status"] not in ALERT_STATUSES:
        raise JournalError("invalid aggregate status")
    if item["terminal_reason"] is not None and item["terminal_reason"] not in TERMINAL_REASONS:
        raise JournalError("invalid terminal_reason")
    replacement = item["replacement_alert_id"]
    if replacement is not None and (not isinstance(replacement, str) or not re.fullmatch(r"[a-f0-9]{24}", replacement)):
        raise JournalError("invalid replacement_alert_id")
    if not isinstance(item["channels"], dict) or not item["channels"]:
        raise JournalError("alert must have at least one channel")
    for name, channel in item["channels"].items():
        _validate_channel(name, channel)
    for key in ("completed_at", "detector_acknowledged_at"):
        if item[key] is not None and not _is_int(item[key]):
            raise JournalError(f"invalid {key}")
    statuses = {channel["status"] for channel in item["channels"].values()}
    expected = "pending" if "pending" in statuses else ("failed" if "failed" in statuses else "delivered")
    if item["status"] != expected:
        raise JournalError("aggregate status does not match channels")
    if item["status"] == "pending":
        if item["completed_at"] is not None or item["terminal_reason"] is not None:
            raise JournalError("pending alert is terminal")
    elif item["completed_at"] is None or item["terminal_reason"] is None:
        raise JournalError("terminal alert lacks completion metadata")


def validate_document(document: Any, *, allow_legacy: bool = True) -> dict[str, Any]:
    if not isinstance(document, dict) or "schema_version" not in document:
        raise JournalError("invalid journal document")
    version = document["schema_version"]
    if not _is_int(version):
        raise JournalError("invalid schema_version")
    if version > SCHEMA_VERSION:
        raise JournalError(f"unsupported future journal schema version {version}")
    if version != SCHEMA_VERSION and (version != LEGACY_SCHEMA_VERSION or not allow_legacy):
        raise JournalError(f"unsupported journal schema version {version}")
    expected_fields = (
        {"schema_version", "legacy_migration", "alerts"}
        if version == LEGACY_SCHEMA_VERSION
        else {"schema_version", "limit_id_contract_version", "legacy_migration", "alerts"}
    )
    if set(document) != expected_fields:
        raise JournalError("invalid journal document")
    if version == SCHEMA_VERSION and (
            not _is_int(document["limit_id_contract_version"])
            or document["limit_id_contract_version"] != LIMIT_ID_CONTRACT_VERSION):
        raise JournalError("unsupported limit ID contract version")
    migration = document["legacy_migration"]
    if not isinstance(migration, dict) or set(migration) != {"source_state_version", "completed_at"}:
        raise JournalError("invalid legacy migration metadata")
    if not _is_int(migration["source_state_version"], 1) or not _is_int(migration["completed_at"]):
        raise JournalError("invalid legacy migration metadata")
    if not isinstance(document["alerts"], list):
        raise JournalError("alerts must be an array")
    seen: set[str] = set()
    for item in document["alerts"]:
        _validate_alert(item, require_opaque_limit_id=version == SCHEMA_VERSION)
        if item["alert_id"] in seen:
            raise JournalError("duplicate alert_id")
        seen.add(item["alert_id"])
    return document


def _legacy_namespace(cycle_key: str) -> str:
    return _namespace_for_cycle(cycle_key)


def _migrate_cycle_key(cycle_key: str, old_limit_id: str, new_limit_id: str) -> str:
    return _replace_limit_segment(cycle_key, old_limit_id, new_limit_id)


def migrate_document(document: dict[str, Any], completed_at: int) -> dict[str, Any]:
    """Upgrade a legacy journal in memory, preserving delivery state.

    The v1 format has no way to distinguish a raw identifier from one that
    merely looks opaque.  It is therefore hashed unconditionally.  The v2
    contract marker makes the operation idempotent on retries.
    """

    validate_document(document, allow_legacy=True)
    if document["schema_version"] == SCHEMA_VERSION:
        return document
    if not _is_int(completed_at):
        raise JournalError("invalid migration completion time")

    migrated_alerts: list[dict[str, Any]] = []
    id_map: dict[str, str] = {}
    seen_ids: set[str] = set()
    for original in document["alerts"]:
        item = copy.deepcopy(original)
        old_alert_id = item["alert_id"]
        old_limit_id = item["event_data"]["limit_id"]
        new_limit_id = opaque_limit_id_from_raw(old_limit_id)
        if new_limit_id is None:
            raise JournalError("legacy alert has an empty event limit ID")
        namespace = _legacy_namespace(item["cycle_key"])
        expected_old_alert_id = alert_id(
            item["kind"], item["window"], item["selector"], item["cycle_key"], namespace
        )
        if old_alert_id != expected_old_alert_id:
            raise JournalError("legacy alert_id is inconsistent with its cycle key")
        item["event_data"]["limit_id"] = new_limit_id
        item["cycle_key"] = _migrate_cycle_key(
            item["cycle_key"], old_limit_id, new_limit_id
        )
        item["alert_id"] = alert_id(
            item["kind"], item["window"], item["selector"], item["cycle_key"], namespace
        )
        if item["alert_id"] in seen_ids:
            raise JournalError("legacy alert migration produced an alert_id collision")
        seen_ids.add(item["alert_id"])
        id_map[old_alert_id] = item["alert_id"]
        migrated_alerts.append(item)

    for item in migrated_alerts:
        replacement = item["replacement_alert_id"]
        if replacement is not None and replacement in id_map:
            item["replacement_alert_id"] = id_map[replacement]

    migrated = {
        "schema_version": SCHEMA_VERSION,
        "limit_id_contract_version": LIMIT_ID_CONTRACT_VERSION,
        "legacy_migration": {
            "source_state_version": document["legacy_migration"]["source_state_version"],
            "completed_at": completed_at,
        },
        "alerts": migrated_alerts,
    }
    validate_document(migrated, allow_legacy=False)
    return migrated


def load(path: pathlib.Path, *, allow_legacy: bool = True) -> dict[str, Any]:
    try:
        size = path.stat().st_size
        if size > MAX_BYTES:
            raise JournalError("journal exceeds 16 MiB")
        document = json.loads(path.read_text(encoding="utf-8"))
    except JournalError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise JournalError(f"cannot read journal: {exc}") from None
    return validate_document(document, allow_legacy=allow_legacy)


def atomic_write(path: pathlib.Path, document: dict[str, Any]) -> None:
    validate_document(document, allow_legacy=False)
    encoded = (json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")
    if len(encoded) > MAX_BYTES:
        raise JournalError("journal exceeds 16 MiB")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, stat.S_IRUSR | stat.S_IWUSR)
        with os.fdopen(fd, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        try:
            directory_fd = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except OSError:
            pass
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def _channel_state() -> dict[str, Any]:
    return {
        "status": "pending", "attempt_count": 0, "last_attempt_at": 0,
        "next_attempt_at": 0, "last_http_status": None,
        "last_curl_code": None, "error_class": None,
    }


def _request_alert(request: dict[str, Any]) -> dict[str, Any]:
    kind = request.get("kind")
    window = request.get("window")
    selector = str(request.get("selector", ""))
    cycle_key = request.get("cycle_key")
    channels = request.get("channels")
    if kind not in KINDS or window not in WINDOWS or not isinstance(cycle_key, str):
        raise JournalError("invalid registration request")
    if not isinstance(channels, list) or not channels or any(channel not in CHANNELS for channel in channels):
        raise JournalError("registration requires configured channels")
    if len(set(channels)) != len(channels):
        raise JournalError("duplicate registration channel")
    event_data = copy.deepcopy(request.get("event_data", {}))
    raw_limit_id = event_data.get("limit_id") if isinstance(event_data, dict) else None
    limit_id = canonicalize_limit_id(raw_limit_id)
    if isinstance(event_data, dict) and limit_id is not None:
        event_data["limit_id"] = limit_id
    if isinstance(cycle_key, str) and isinstance(raw_limit_id, str) and limit_id is not None:
        cycle_key = _replace_limit_segment(cycle_key, raw_limit_id, limit_id)
    namespace = _namespace_for_cycle(cycle_key)
    requested_namespace = request.get("id_namespace")
    if requested_namespace is not None and requested_namespace != namespace:
        raise JournalError("id namespace does not match cycle key")
    item = {
        "alert_id": alert_id(kind, window, selector, cycle_key, namespace),
        "kind": kind,
        "window": window,
        "selector": selector,
        "cycle_key": cycle_key,
        "message": request.get("message"),
        "event_data": event_data,
        "created_at": request.get("created_at"),
        "expires_at": request.get("expires_at", 0),
        "status": "pending",
        "terminal_reason": None,
        "replacement_alert_id": None,
        "channels": {channel: _channel_state() for channel in channels},
        "completed_at": None,
        "detector_acknowledged_at": None,
    }
    _validate_alert(item, require_opaque_limit_id=True)
    return item


def _same_registration(existing: dict[str, Any], incoming: dict[str, Any]) -> bool:
    immutable = ("alert_id", "kind", "window", "selector", "cycle_key", "message", "event_data", "created_at", "expires_at")
    return all(existing[key] == incoming[key] for key in immutable) and set(existing["channels"]) == set(incoming["channels"])


def _register_or_reuse_observed_reset(document: dict[str, Any],
                                      request: dict[str, Any]) -> dict[str, Any]:
    """Register a weekly observed-reset request without rebuilding retries.

    The detector can reconstruct an observed weekly reset after the first
    delivery attempt has failed.  Its current poll time and configured
    channels are not immutable event data, so feeding a freshly-built request
    to ``register`` would look like an alert-id collision.  Reuse an existing
    reset occurrence only when its owner, window, cycle, selector and reset
    epoch are identical; all other identity collisions remain errors.
    """

    incoming = _request_alert(request)
    for existing in document["alerts"]:
        if existing["alert_id"] != incoming["alert_id"]:
            continue
        if _same_registration(existing, incoming):
            return existing
        if (existing["kind"] == "reset"
                and existing["window"] == incoming["window"]
                and existing["selector"] == "reset"
                and existing["cycle_key"] == incoming["cycle_key"]
                and existing["event_data"] == incoming["event_data"]):
            # Preserve channel retry state, message, creation time and
            # expiry.  A terminal row is authoritative and must not be
            # resurrected by a later recovery poll.
            return existing
        raise JournalError("alert_id collision with different content")
    document["alerts"].append(incoming)
    return incoming


def _terminate(item: dict[str, Any], reason: str, now: int,
               error_class: str, replacement: str | None = None) -> None:
    for channel in item["channels"].values():
        if channel["status"] == "pending":
            channel["status"] = "failed"
            channel["error_class"] = error_class
            channel["next_attempt_at"] = 0
    item["status"] = "failed"
    item["terminal_reason"] = reason
    item["replacement_alert_id"] = replacement
    item["completed_at"] = now


def _same_cycle(existing: str, requested: str) -> bool:
    return existing == requested or (
        existing.startswith("legacy-v") and "|" in existing
        and existing.split("|", 1)[1] == requested
    )


def _unarmed_cycle(cycle_key: str, limit_id: str) -> bool:
    if cycle_key.startswith("legacy-v") and "|" in cycle_key:
        cycle_key = cycle_key.split("|", 1)[1]
    return cycle_key == f"limit:{limit_id}|unarmed"


def expire_pending_thresholds(document: dict[str, Any], window: str,
                              cycle_key: str, limit_id: str, now: int,
                              raw_limit_id: str | None = None) -> int:
    """Terminalize pending thresholds invalidated by a reset.

    Reset evidence and reset notification registration are deliberately
    separate operations.  Callers can therefore invalidate stale threshold
    occurrences even when the reset is local-only (for example, an observed
    5-hour refill).  The matching limit is checked on both the cycle key and
    event data so an old cycle from another limit group cannot be touched.
    """

    if window not in WINDOWS:
        raise JournalError("expiration window is invalid")
    if (not isinstance(cycle_key, str) or not cycle_key
            or not isinstance(limit_id, str) or not limit_id
            or not _is_int(now)):
        raise JournalError("invalid threshold expiration request")

    canonical_limit_id = canonicalize_limit_id(limit_id)
    if canonical_limit_id is None:
        raise JournalError("threshold expiration limit ID is invalid")
    # A monitor caller normally passes an already canonical cycle.  Register's
    # legacy migration path may still pass a raw identifier, so normalize that
    # exact segment without permitting substring or duplicate matches.
    if raw_limit_id is not None and raw_limit_id != canonical_limit_id:
        cycle_key = _replace_limit_segment(cycle_key, raw_limit_id, canonical_limit_id)
    else:
        try:
            _limit_segment_index(cycle_key, canonical_limit_id)
        except JournalError:
            # Public callers may provide the raw protocol identifier as the
            # limit argument while retaining it in the cycle key.
            if limit_id == canonical_limit_id:
                raise
            cycle_key = _replace_limit_segment(cycle_key, limit_id, canonical_limit_id)

    expired = 0
    for existing in document["alerts"]:
        if (existing["kind"] != "threshold"
                or existing["window"] != window
                or existing["status"] != "pending"
                or existing["event_data"].get("limit_id") != canonical_limit_id):
            continue
        cycle_matches = _same_cycle(existing["cycle_key"], cycle_key) or _unarmed_cycle(
            existing["cycle_key"], canonical_limit_id
        )
        if cycle_matches:
            _terminate(existing, "expired_after_reset", now, "expired_after_reset")
            expired += 1
    return expired


def expire_pending_thresholds_for_owner(document: dict[str, Any], window: str,
                                        limit_id: str, now: int) -> int:
    """Terminalize every pending threshold for one owner and window.

    An observed refill is evidence that the detector's pre-reset cycle has
    ended, but a restored arm/deadline may no longer identify that cycle.  In
    that case the journal's durable event owner is the authority, so expire
    all pending thresholds for the current owner in the affected window.  Do
    not broaden this to resets, anomalies, or another owner.
    """

    if (window not in WINDOWS or not isinstance(limit_id, str)
            or not limit_id or not _is_int(now)):
        raise JournalError("invalid owner threshold expiration request")
    canonical_limit_id = canonicalize_limit_id(limit_id)
    if canonical_limit_id is None:
        raise JournalError("owner threshold expiration limit ID is invalid")

    expired = 0
    for existing in document["alerts"]:
        if (existing["kind"] == "threshold"
                and existing["window"] == window
                and existing["status"] == "pending"
                and existing["event_data"].get("limit_id") == canonical_limit_id):
            _terminate(existing, "expired_after_reset", now, "expired_after_reset")
            expired += 1
    return expired


def interrupt_pending_owner(document: dict[str, Any], limit_id: str, now: int) -> int:
    """Terminalize pending threshold/reset occurrences for an interrupted owner.

    This is deliberately broader than reset-threshold expiration: a partial
    sample from another limit group invalidates every pending detector event
    from the old owner in both windows.  Anomalies and other owners remain
    untouched, and repeating the operation is a no-op after the first write.
    """

    if not isinstance(limit_id, str) or not limit_id or not _is_int(now):
        raise JournalError("invalid owner interruption request")
    canonical_limit_id = canonicalize_limit_id(limit_id)
    if canonical_limit_id is None:
        raise JournalError("owner interruption limit ID is invalid")

    interrupted = 0
    for item in document["alerts"]:
        if (item["kind"] not in {"threshold", "reset"}
                or item["status"] != "pending"
                or item["event_data"].get("limit_id") != canonical_limit_id):
            continue
        _terminate(item, "owner_interrupted", now, "owner_interrupted")
        interrupted += 1
    return interrupted


def interrupt_pending_other_owners(document: dict[str, Any], current_limit_id: str,
                                   now: int) -> int:
    """Terminalize pending detector events owned by any other limit group.

    The comparison and all terminal transitions happen against one loaded
    journal before it is atomically written by the CLI.  This closes the gap
    where a journal can contain an older owner's pending event while the
    detector state has lost that owner's identity.  Anomalies are deliberately
    excluded: their durable detector has independent ownership semantics.
    """

    if (not isinstance(current_limit_id, str) or not current_limit_id
            or not _is_int(now)):
        raise JournalError("invalid current owner interruption request")
    canonical_current_limit_id = canonicalize_limit_id(current_limit_id)
    if canonical_current_limit_id is None:
        raise JournalError("current owner interruption limit ID is invalid")

    interrupted = 0
    for item in document["alerts"]:
        if (item["kind"] not in {"threshold", "reset"}
                or item["status"] != "pending"
                or item["event_data"].get("limit_id") == canonical_current_limit_id):
            continue
        _terminate(item, "owner_interrupted", now, "owner_interrupted")
        interrupted += 1
    return interrupted


def suppress_local_reset_cycle(document: dict[str, Any], window: str,
                               limit_id: str, reset_epoch: int, now: int,
                               reason: str = "local_observed") -> int:
    """Durably suppress one scheduled reset superseded by observed evidence.

    The terminal journal row is a write-ahead tombstone for a local-only
    observed 5-hour refill.  It is intentionally terminal from creation, so
    ``due`` can never select it, even when alerts are disabled or no channel is
    configured.  If a pending occurrence for the same owner/cycle already
    exists, terminalize it in place; otherwise append an idempotent marker.
    """

    if (window not in WINDOWS or reason not in {"local_observed", "owner_interrupted"}
            or not isinstance(limit_id, str) or not limit_id
            or not _is_int(reset_epoch) or not _is_int(now)):
        raise JournalError("invalid reset cycle suppression request")
    canonical_limit_id = canonicalize_limit_id(limit_id)
    if canonical_limit_id is None:
        raise JournalError("reset cycle suppression limit ID is invalid")
    cycle_key = f"limit:{canonical_limit_id}|reset:{reset_epoch}"
    validity = 5 * 60 * 60 if window == "5h" else 7 * 24 * 60 * 60
    message = (
        "Observed local reset; scheduled notification suppressed."
        if reason == "local_observed"
        else "Limit owner interrupted; scheduled notification suppressed."
    )
    changed = 0
    matched = False
    for existing in document["alerts"]:
        if (existing["kind"] != "reset" or existing["window"] != window
                or existing["selector"] != "reset"
                or existing["event_data"].get("limit_id") != canonical_limit_id
                or not _same_cycle(existing["cycle_key"], cycle_key)):
            continue
        matched = True
        if existing["status"] == "pending":
            _terminate(existing, reason, now, reason)
            changed += 1
        elif reason == "owner_interrupted" and existing["terminal_reason"] == "local_observed":
            # An owner interruption is stronger than an earlier local-only
            # classification for the same cycle.  A crash can leave the local
            # tombstone behind while the detector arm is restored under the
            # interrupted owner; promote only this specific collision so the
            # return path cannot execute a local hook.  Delivered/permanent
            # terminal events are intentionally immutable.
            for channel in existing["channels"].values():
                if (channel["status"] == "failed"
                        and channel["error_class"] == "local_observed"):
                    channel["error_class"] = "owner_interrupted"
            existing["message"] = message
            existing["terminal_reason"] = "owner_interrupted"
            existing["completed_at"] = now
            existing["replacement_alert_id"] = None
            changed += 1
    if matched:
        return changed

    tombstone = _request_alert({
        "kind": "reset",
        "window": window,
        "selector": "reset",
        "cycle_key": cycle_key,
        "message": message,
        "event_data": {
            "limit_id": canonical_limit_id,
            "reset_epoch": reset_epoch,
        },
        "created_at": now,
        "expires_at": max(now, reset_epoch + validity),
        # Terminal markers use the complete known channel set and are never
        # passed to due; this keeps the schema independent of configuration.
        "channels": sorted(CHANNELS),
    })
    _terminate(tombstone, reason, now, reason)
    document["alerts"].append(tombstone)
    return 1


def expire_owner_thresholds_and_suppress_reset(document: dict[str, Any],
                                               window: str, limit_id: str,
                                               reset_epoch: int, now: int) -> int:
    """Atomically expire an owner's thresholds and suppress its reset cycle.

    The caller writes the resulting document once.  A zero ``reset_epoch``
    means that no reset tombstone is needed (for example an observed reset
    with no durable arm), while threshold invalidation remains part of the
    same journal transaction.
    """

    if not _is_int(reset_epoch):
        raise JournalError("invalid atomic reset epoch")
    changed = expire_pending_thresholds_for_owner(document, window, limit_id, now)
    if reset_epoch:
        changed += suppress_local_reset_cycle(
            document, window, limit_id, reset_epoch, now,
        )
    return changed


def expire_observed_owner_cycle(document: dict[str, Any], window: str,
                                limit_id: str, now: int,
                                superseded_reset_epoch: int = 0,
                                preserve_cycle: str | None = None,
                                new_reset_request: dict[str, Any] | None = None) -> int:
    """Close stale owner events and optionally publish a new reset atomically.

    Observed evidence consumes the detector's prior cycle.  Thresholds and
    pending reset rows for that owner/window must therefore be terminalized in
    the same journal transaction.  ``preserve_cycle`` is used by weekly
    observed refills: the new reset occurrence is created in this transaction
    and is the only pending reset row retained for the owner.  A 5h observed
    refill passes the superseded arm epoch instead and gets a local-only
    tombstone when no matching reset row already exists.
    """

    if (window not in WINDOWS or not isinstance(limit_id, str)
            or not limit_id or not _is_int(now)
            or not _is_int(superseded_reset_epoch)):
        raise JournalError("invalid observed owner cycle request")
    canonical_limit_id = canonicalize_limit_id(limit_id)
    if canonical_limit_id is None:
        raise JournalError("observed owner cycle limit ID is invalid")
    if preserve_cycle is not None:
        if not isinstance(preserve_cycle, str) or not preserve_cycle:
            raise JournalError("observed owner preserve cycle is invalid")
        try:
            _limit_segment_index(preserve_cycle, canonical_limit_id)
        except JournalError:
            raise JournalError("observed owner preserve cycle has wrong owner") from None
    if new_reset_request is not None:
        if (new_reset_request.get("kind") != "reset"
                or new_reset_request.get("window") != window
                or new_reset_request.get("event_data", {}).get("limit_id")
                != canonical_limit_id):
            raise JournalError("observed owner reset request has wrong owner")
        if preserve_cycle is None or not _same_cycle(
                new_reset_request.get("cycle_key", ""), preserve_cycle):
            raise JournalError("observed owner reset request is not preserved")

    changed = expire_pending_thresholds_for_owner(
        document, window, canonical_limit_id, now,
    )
    for existing in document["alerts"]:
        if (existing["kind"] != "reset" or existing["window"] != window
                or existing["status"] != "pending"
                or existing["event_data"].get("limit_id") != canonical_limit_id):
            continue
        if preserve_cycle is not None and _same_cycle(
                existing["cycle_key"], preserve_cycle):
            continue
        _terminate(existing, "local_observed", now, "local_observed")
        changed += 1

    if superseded_reset_epoch:
        changed += suppress_local_reset_cycle(
            document, window, canonical_limit_id, superseded_reset_epoch, now,
        )
    if new_reset_request is not None:
        before = len(document["alerts"])
        _register_or_reuse_observed_reset(document, new_reset_request)
        changed += len(document["alerts"]) > before
    return int(changed)


def interrupt_reset_cycle(document: dict[str, Any], window: str,
                          limit_id: str, reset_epoch: int, now: int) -> int:
    """Durably suppress a reset cycle interrupted by another owner."""

    return suppress_local_reset_cycle(
        document, window, limit_id, reset_epoch, now, "owner_interrupted",
    )


def register(document: dict[str, Any], request: dict[str, Any]) -> dict[str, Any]:
    incoming = _request_alert(request)
    expire_cycle = request.get("expire_threshold_cycle")
    if expire_cycle is not None:
        if not isinstance(expire_cycle, str):
            raise JournalError("expiration cycle key is invalid")
        event_data = request.get("event_data")
        raw_limit_id = event_data.get("limit_id") if isinstance(event_data, dict) else None
        canonical_limit_id = incoming["event_data"].get("limit_id")
        if not isinstance(raw_limit_id, str) or not isinstance(canonical_limit_id, str):
            raise JournalError("expiration cycle key does not contain its limit ID")
        expire_pending_thresholds(
            document, incoming["window"], expire_cycle, canonical_limit_id,
            incoming["created_at"], raw_limit_id=raw_limit_id,
        )
    for existing in document["alerts"]:
        if existing["alert_id"] == incoming["alert_id"]:
            if not _same_registration(existing, incoming):
                raise JournalError("alert_id collision with different content")
            return existing
    now = incoming["created_at"]
    if request.get("replace_pending_thresholds"):
        for existing in document["alerts"]:
            if (existing["kind"] == "threshold" and existing["window"] == incoming["window"]
                    and _same_cycle(existing["cycle_key"], incoming["cycle_key"])
                    and existing["status"] == "pending"):
                _terminate(existing, "superseded", now, "superseded", incoming["alert_id"])
    document["alerts"].append(incoming)
    return incoming


def _read_stdin(default: Any = None) -> Any:
    raw = sys.stdin.read()
    if not raw.strip():
        return default
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise JournalError(f"invalid stdin JSON: {exc.msg}") from None


def _configured_channels(payload: Any) -> set[str]:
    if payload is None:
        return set(CHANNELS)
    if isinstance(payload, list):
        values = payload
    elif isinstance(payload, dict):
        values = payload.get("configured_channels", payload.get("channels", []))
    else:
        raise JournalError("invalid configured channels")
    if not isinstance(values, list) or any(value not in CHANNELS for value in values):
        raise JournalError("invalid configured channels")
    return set(values)


def _recompute(item: dict[str, Any], now: int) -> None:
    statuses = {channel["status"] for channel in item["channels"].values()}
    if "pending" in statuses:
        item["status"] = "pending"
        item["terminal_reason"] = None
        item["completed_at"] = None
    elif "failed" in statuses:
        item["status"] = "failed"
        errors = {channel["error_class"] for channel in item["channels"].values() if channel["status"] == "failed"}
        item["terminal_reason"] = "channel_unconfigured" if errors == {"channel_unconfigured"} else "permanent_failure"
        item["completed_at"] = now
    else:
        item["status"] = "delivered"
        item["terminal_reason"] = "delivered"
        item["completed_at"] = now


def parse_retry_after(headers_path: pathlib.Path, now: int) -> int | None:
    try:
        text = headers_path.read_text(encoding="iso-8859-1")
    except OSError:
        return None
    value = None
    # The last response block wins after proxies/redirect handshakes.
    for line in text.splitlines():
        if line.lower().startswith("retry-after:"):
            value = line.split(":", 1)[1].strip()
    if value is None:
        return None
    if value.isdigit():
        return min(int(value), MAX_RETRY_DELAY)
    try:
        parsed = email.utils.parsedate_to_datetime(value)
        if parsed is None:
            return None
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return min(max(0, int(parsed.timestamp()) - now), MAX_RETRY_DELAY)
    except (TypeError, ValueError, OverflowError):
        return None


def classify(curl_code: int, http_status: int, attempt: int, base_delay: int,
             headers_path: pathlib.Path, now: int) -> dict[str, Any]:
    if min(curl_code, http_status, attempt, base_delay, now) < 0 or attempt < 1:
        raise JournalError("invalid classification arguments")
    retry_after = parse_retry_after(headers_path, now)
    if curl_code:
        error_class = "timeout" if curl_code == 28 else "transport_error"
        retryable = True
    elif http_status == 408:
        error_class, retryable = "client_error", True
    elif http_status == 429:
        error_class, retryable = "rate_limited", True
    elif 500 <= http_status <= 599:
        error_class, retryable = "server_error", True
    elif 200 <= http_status <= 299:
        return {"outcome": "delivered", "error_class": None, "retryable": False,
                "retry_delay": 0, "next_attempt_at": 0, "used_retry_after": False}
    else:
        error_class, retryable = "client_error", False
    if retryable:
        delay = retry_after if retry_after is not None else base_delay * (2 ** (attempt - 1))
        delay = min(delay, MAX_RETRY_DELAY)
        return {"outcome": "pending", "error_class": error_class, "retryable": True,
                "retry_delay": delay, "next_attempt_at": now + delay,
                "used_retry_after": retry_after is not None}
    return {"outcome": "failed", "error_class": error_class, "retryable": False,
            "retry_delay": 0, "next_attempt_at": 0, "used_retry_after": False}


def emit_json_lines(items: Iterable[dict[str, Any]]) -> None:
    for item in items:
        print(json.dumps(item, separators=(",", ":"), ensure_ascii=False))


def command(args: argparse.Namespace) -> None:
    path = pathlib.Path(args.journal)
    if args.action == "validate":
        load(path, allow_legacy=False)
        return
    if args.action == "migrate":
        document = load(path)
        migrated = migrate_document(document, args.at)
        if migrated is not document:
            atomic_write(path, migrated)
        return
    if args.action == "init":
        if path.exists():
            document = load(path)
            migrated = migrate_document(document, int(dt.datetime.now(dt.timezone.utc).timestamp()))
            if migrated is not document:
                atomic_write(path, migrated)
            return
        payload = _read_stdin({})
        if not isinstance(payload, dict):
            raise JournalError("init payload must be an object")
        completed_at = payload.get("completed_at", int(dt.datetime.now(dt.timezone.utc).timestamp()))
        document = empty_journal(args.source_state_version, completed_at)
        for request in payload.get("alerts", []):
            register(document, request)
        atomic_write(path, document)
        return

    document = load(path)
    if args.action == "register":
        item = register(document, _read_stdin())
        atomic_write(path, document)
        print(json.dumps(item, separators=(",", ":"), ensure_ascii=False))
    elif args.action in {"expire-thresholds", "expire-threshold"}:
        migrated = migrate_document(document, args.now)
        expired = expire_pending_thresholds(
            migrated, args.window, args.cycle_key, args.limit_id, args.now,
        )
        if migrated is not document or expired:
            atomic_write(path, migrated)
    elif args.action in {"expire-owner-thresholds", "expire-thresholds-owner"}:
        migrated = migrate_document(document, args.now)
        expired = expire_pending_thresholds_for_owner(
            migrated, args.window, args.limit_id, args.now,
        )
        if migrated is not document or expired:
            atomic_write(path, migrated)
    elif args.action in {
        "expire-owner-thresholds-and-reset",
        "expire-thresholds-and-local-reset",
    }:
        migrated = migrate_document(document, args.now)
        changed = expire_owner_thresholds_and_suppress_reset(
            migrated, args.window, args.limit_id, args.reset_epoch, args.now,
        )
        if migrated is not document or changed:
            atomic_write(path, migrated)
    elif args.action in {"expire-observed-owner", "expire-owner-observed-cycle"}:
        migrated = migrate_document(document, args.now)
        request = _read_stdin({})
        if request is not None and not isinstance(request, dict):
            raise JournalError("observed owner reset request must be an object")
        changed = expire_observed_owner_cycle(
            migrated, args.window, args.limit_id, args.now,
            args.superseded_reset_epoch, args.preserve_cycle, request or None,
        )
        if migrated is not document or changed:
            atomic_write(path, migrated)
    elif args.action in {"interrupt-owner", "interrupt-pending-owner"}:
        migrated = migrate_document(document, args.now)
        interrupted = interrupt_pending_owner(migrated, args.limit_id, args.now)
        if migrated is not document or interrupted:
            atomic_write(path, migrated)
    elif args.action in {"interrupt-other-owners", "interrupt-pending-other-owners"}:
        migrated = migrate_document(document, args.now)
        interrupted = interrupt_pending_other_owners(
            migrated, args.current_limit_id, args.now,
        )
        if migrated is not document or interrupted:
            atomic_write(path, migrated)
    elif args.action in {"suppress-local-reset", "tombstone-local-reset"}:
        migrated = migrate_document(document, args.now)
        changed = suppress_local_reset_cycle(
            migrated, args.window, args.limit_id, args.reset_epoch, args.now,
        )
        if migrated is not document or changed:
            atomic_write(path, migrated)
    elif args.action in {"interrupt-reset-cycle", "tombstone-owner-reset"}:
        migrated = migrate_document(document, args.now)
        changed = interrupt_reset_cycle(
            migrated, args.window, args.limit_id, args.reset_epoch, args.now,
        )
        if migrated is not document or changed:
            atomic_write(path, migrated)
    elif args.action == "due":
        configured = _configured_channels(_read_stdin(None))
        changed = False
        due = []
        for item in document["alerts"]:
            if item["status"] != "pending":
                continue
            for name, channel in item["channels"].items():
                if channel["status"] != "pending":
                    continue
                if name not in configured:
                    channel["status"] = "failed"
                    channel["error_class"] = "channel_unconfigured"
                    channel["next_attempt_at"] = 0
                    changed = True
                    continue
                if channel["next_attempt_at"] <= args.now:
                    due.append({
                        "alert_id": item["alert_id"], "channel": name,
                        "message": item["message"], "attempt_count": channel["attempt_count"],
                    })
            _recompute(item, args.now)
        if changed:
            atomic_write(path, document)
        order = {"discord": 0, "telegram": 1}
        due.sort(key=lambda row: (next(x["created_at"] for x in document["alerts"] if x["alert_id"] == row["alert_id"]), row["alert_id"], order[row["channel"]]))
        emit_json_lines(due)
    elif args.action == "record":
        payload = _read_stdin()
        if not isinstance(payload, dict):
            raise JournalError("record payload must be an object")
        item = next((entry for entry in document["alerts"] if entry["alert_id"] == payload.get("alert_id")), None)
        if item is None or payload.get("channel") not in item["channels"]:
            raise JournalError("unknown alert channel")
        channel = item["channels"][payload["channel"]]
        if channel["status"] != "pending":
            raise JournalError("cannot record a terminal channel")
        outcome = payload.get("status", payload.get("outcome"))
        error_class = payload.get("error_class")
        if outcome not in CHANNEL_STATUSES or (error_class is not None and error_class not in ERROR_CLASSES):
            raise JournalError("invalid record result")
        channel["attempt_count"] += 1
        channel["last_attempt_at"] = payload.get("attempted_at", payload.get("last_attempt_at"))
        channel["next_attempt_at"] = payload.get("next_attempt_at", 0) if outcome == "pending" else 0
        channel["last_http_status"] = payload.get("http_status", payload.get("last_http_status"))
        channel["last_curl_code"] = payload.get("curl_code", payload.get("last_curl_code"))
        channel["error_class"] = None if outcome == "delivered" else error_class
        channel["status"] = outcome
        _validate_channel(payload["channel"], channel)
        _recompute(item, channel["last_attempt_at"])
        atomic_write(path, document)
        print(json.dumps(item, separators=(",", ":"), ensure_ascii=False))
    elif args.action == "terminal-unacknowledged":
        emit_json_lines(item for item in document["alerts"] if item["status"] != "pending" and item["detector_acknowledged_at"] is None)
    elif args.action == "acknowledge":
        item = next((entry for entry in document["alerts"] if entry["alert_id"] == args.alert_id), None)
        if item is None or item["status"] == "pending":
            raise JournalError("cannot acknowledge unknown or pending alert")
        if item["detector_acknowledged_at"] is None:
            item["detector_acknowledged_at"] = args.at
            atomic_write(path, document)
    elif args.action == "expire":
        changed = False
        for item in document["alerts"]:
            if item["status"] == "pending" and item["expires_at"] and args.now > item["expires_at"]:
                _terminate(item, "expired_after_reset", args.now, "expired_after_reset")
                changed = True
        if changed:
            atomic_write(path, document)
    elif args.action == "prune":
        terminal = [item for item in document["alerts"] if item["status"] != "pending" and item["detector_acknowledged_at"] is not None]
        newest = {item["alert_id"] for item in sorted(terminal, key=lambda item: (item["completed_at"], item["alert_id"]), reverse=True)[:MAX_RECONCILED_TERMINAL]}
        kept = []
        for item in document["alerts"]:
            removable = (item in terminal and item["alert_id"] not in newest) or (
                item in terminal and item["completed_at"] < args.now - RETENTION_SECONDS)
            if not removable:
                kept.append(item)
        if len(kept) != len(document["alerts"]):
            document["alerts"] = kept
            atomic_write(path, document)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    sub = result.add_subparsers(dest="action", required=True)
    for name in ("validate", "register", "terminal-unacknowledged"):
        command_parser = sub.add_parser(name)
        command_parser.add_argument("journal")
    expire_thresholds_parser = sub.add_parser(
        "expire-thresholds", aliases=["expire-threshold"]
    )
    expire_thresholds_parser.add_argument("journal")
    expire_thresholds_parser.add_argument("window", choices=sorted(WINDOWS))
    expire_thresholds_parser.add_argument("cycle_key")
    expire_thresholds_parser.add_argument("limit_id")
    expire_thresholds_parser.add_argument("--now", type=int, required=True)
    expire_owner_thresholds_parser = sub.add_parser(
        "expire-owner-thresholds", aliases=["expire-thresholds-owner"],
    )
    expire_owner_thresholds_parser.add_argument("journal")
    expire_owner_thresholds_parser.add_argument("window", choices=sorted(WINDOWS))
    expire_owner_thresholds_parser.add_argument("limit_id")
    expire_owner_thresholds_parser.add_argument("--now", type=int, required=True)
    expire_owner_atomic_parser = sub.add_parser(
        "expire-owner-thresholds-and-reset",
        aliases=["expire-thresholds-and-local-reset"],
    )
    expire_owner_atomic_parser.add_argument("journal")
    expire_owner_atomic_parser.add_argument("window", choices=sorted(WINDOWS))
    expire_owner_atomic_parser.add_argument("limit_id")
    expire_owner_atomic_parser.add_argument("reset_epoch", type=int)
    expire_owner_atomic_parser.add_argument("--now", type=int, required=True)
    expire_observed_parser = sub.add_parser(
        "expire-observed-owner", aliases=["expire-owner-observed-cycle"],
    )
    expire_observed_parser.add_argument("journal")
    expire_observed_parser.add_argument("window", choices=sorted(WINDOWS))
    expire_observed_parser.add_argument("limit_id")
    expire_observed_parser.add_argument("--superseded-reset-epoch", type=int, default=0)
    expire_observed_parser.add_argument("--preserve-cycle")
    expire_observed_parser.add_argument("--now", type=int, required=True)
    interrupt_owner_parser = sub.add_parser(
        "interrupt-owner", aliases=["interrupt-pending-owner"],
    )
    interrupt_owner_parser.add_argument("journal")
    interrupt_owner_parser.add_argument("limit_id")
    interrupt_owner_parser.add_argument("--now", type=int, required=True)
    interrupt_other_parser = sub.add_parser(
        "interrupt-other-owners", aliases=["interrupt-pending-other-owners"],
    )
    interrupt_other_parser.add_argument("journal")
    interrupt_other_parser.add_argument("current_limit_id")
    interrupt_other_parser.add_argument("--now", type=int, required=True)
    local_reset_parser = sub.add_parser(
        "suppress-local-reset", aliases=["tombstone-local-reset"],
    )
    local_reset_parser.add_argument("journal")
    local_reset_parser.add_argument("window", choices=sorted(WINDOWS))
    local_reset_parser.add_argument("limit_id")
    local_reset_parser.add_argument("reset_epoch", type=int)
    local_reset_parser.add_argument("--now", type=int, required=True)
    interrupt_reset_parser = sub.add_parser(
        "interrupt-reset-cycle", aliases=["tombstone-owner-reset"],
    )
    interrupt_reset_parser.add_argument("journal")
    interrupt_reset_parser.add_argument("window", choices=sorted(WINDOWS))
    interrupt_reset_parser.add_argument("limit_id")
    interrupt_reset_parser.add_argument("reset_epoch", type=int)
    interrupt_reset_parser.add_argument("--now", type=int, required=True)
    migrate_parser = sub.add_parser("migrate")
    migrate_parser.add_argument("journal")
    migrate_parser.add_argument("--at", type=int, required=True)
    init_parser = sub.add_parser("init")
    init_parser.add_argument("journal")
    init_parser.add_argument("--source-state-version", type=int, required=True)
    for name in ("due", "expire", "prune"):
        command_parser = sub.add_parser(name)
        command_parser.add_argument("journal")
        command_parser.add_argument("--now", type=int, required=True)
    record_parser = sub.add_parser("record")
    record_parser.add_argument("journal")
    ack_parser = sub.add_parser("acknowledge")
    ack_parser.add_argument("journal")
    ack_parser.add_argument("alert_id")
    ack_parser.add_argument("--at", type=int, required=True)
    classify_parser = sub.add_parser("classify")
    classify_parser.add_argument("curl_code", type=int)
    classify_parser.add_argument("http_status", type=int)
    classify_parser.add_argument("attempt", type=int)
    classify_parser.add_argument("base_delay", type=int)
    classify_parser.add_argument("headers_file")
    classify_parser.add_argument("--now", type=int, required=True)
    telegram = sub.add_parser("telegram-delivered")
    telegram.add_argument("response_file")
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.action == "classify":
            print(json.dumps(classify(args.curl_code, args.http_status, args.attempt,
                                      args.base_delay, pathlib.Path(args.headers_file), args.now),
                             separators=(",", ":")))
        elif args.action == "telegram-delivered":
            try:
                response = json.loads(pathlib.Path(args.response_file).read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError):
                return 1
            return 0 if isinstance(response, dict) and response.get("ok") is True else 1
        else:
            command(args)
        return 0
    except (JournalError, OSError) as exc:
        sys.stderr.write(f"alerts: {exc}\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
