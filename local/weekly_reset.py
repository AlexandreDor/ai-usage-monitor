"""Conservative evidence for weekly cycles observed while quota is full."""

from __future__ import annotations

import argparse
import base64
import json
import math
from typing import Any


MIN_ADVANCE_SECONDS = 1800
CONFIRMATION_TOLERANCE_SECONDS = 60
CONFIRMED_EVENT_KEY_PREFIX = "full_weekly_reset_confirmed:"


def _number(value: Any) -> bool:
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value))


def _load(encoded: str) -> dict[str, Any]:
    try:
        if not isinstance(encoded, str) or len(encoded) > 4096:
            return {}
        state = json.loads(base64.b64decode(encoded + "=" * (-len(encoded) % 4), validate=True))
        if not isinstance(state, dict):
            return {}
        if not all(isinstance(state.get(key), int) and not isinstance(state[key], bool)
                   and state[key] > 0 for key in ("epoch", "reset", "interval")):
            return {}
        if not isinstance(state.get("owner"), str):
            return {}
        candidate = state.get("candidate")
        if candidate is not None and not all(
                isinstance(candidate, dict) and isinstance(candidate.get(key), int)
                and not isinstance(candidate[key], bool) and candidate[key] > 0
                for key in ("epoch", "reset")):
            return {}
        if candidate is not None and (candidate["epoch"] != state["epoch"]
                                      or candidate["reset"] != state["reset"]):
            return {}
        return state
    except (ValueError, TypeError, UnicodeError):
        return {}


def observe_full_weekly_reset(encoded: str, *, epoch: Any, pct: Any,
                              reset_at: Any, owner: Any,
                              interval: Any = 900) -> tuple[str, int, bool]:
    """Return durable state, confirmed first observation, and pending status.

    A 100 -> 100 deadline advance is provisional until another fresh sample
    confirms the deadline (also when quota was consumed since the candidate).
    Missing data, owner changes and long gaps break the chain. A stable replay
    cannot confirm itself. State contains only the opaque owner and timestamps.
    """
    if (not _number(epoch) or epoch <= 0 or not _number(pct) or not 0 <= pct <= 100
            or not _number(reset_at) or not epoch < reset_at <= epoch + 8 * 86400
            or not isinstance(owner, str) or not owner or owner == "__unknown__"):
        return "", 0, False
    epoch, reset_at = int(epoch), int(reset_at)
    interval = int(interval) if _number(interval) and interval > 0 else 900
    previous = _load(encoded)
    if previous.get("owner") != owner:
        previous = {}
    if previous and epoch <= previous["epoch"]:
        return encoded, 0, bool(previous.get("candidate"))
    gap_limit = max(3600, 2 * max(interval, previous.get("interval", interval)))
    if previous and epoch - previous["epoch"] > gap_limit:
        previous = {}
    candidate = previous.get("candidate")
    confirmed_at = 0
    if candidate and abs(reset_at - candidate["reset"]) <= CONFIRMATION_TOLERANCE_SECONDS:
        confirmed_at = candidate["epoch"]
        candidate = None
    elif (pct == 100 and previous and previous["reset"] > epoch
          and reset_at >= previous["reset"] + MIN_ADVANCE_SECONDS):
        candidate = {"epoch": epoch, "reset": reset_at}
    else:
        candidate = None
    if pct != 100:
        return "", confirmed_at, False
    state = {"epoch": epoch, "reset": reset_at, "interval": interval,
             "owner": owner, "candidate": candidate}
    # The shell state reader uses '=' as its delimiter, so omit base64 padding.
    encoded = base64.b64encode(json.dumps(state, separators=(",", ":")).encode()).decode().rstrip("=")
    return encoded, confirmed_at, candidate is not None


def observe_and_record_full_weekly_reset(connection, encoded: str,
                                         **observation: Any) -> tuple[str, int, bool]:
    """Persist a confirmed proof in the caller's detector transaction.

    These small metadata records are independent of downsampled snapshots and
    include the candidate and its confirming observation. A live poll records
    the same evidence without adding a quota snapshot. Canceled candidates
    never become evidence, even if a later compaction removes their partials.
    """
    result = observe_full_weekly_reset(encoded, **observation)
    confirmed_at = result[1]
    if confirmed_at:
        connection.execute(
            "INSERT OR IGNORE INTO metadata(key, value) VALUES (?, ?)",
            (f"{CONFIRMED_EVENT_KEY_PREFIX}{confirmed_at}",
             json.dumps({"state": encoded, "observation": observation}, separators=(",", ":"))),
        )
        connection.execute(
            """INSERT INTO reset_events (
                window, reset_at_epoch, observed_at_epoch,
                before_pct, after_pct, detection_method
            ) VALUES ('weekly', ?, ?, 100, 100, 'full_observed')
            ON CONFLICT(window, reset_at_epoch) DO UPDATE SET
                observed_at_epoch = excluded.observed_at_epoch,
                before_pct = 100, after_pct = 100, detection_method = 'full_observed'
            WHERE reset_events.detection_method != 'full_observed'""",
            (confirmed_at, int(observation["epoch"])),
        )
    return result


def saved_full_weekly_resets(connection) -> list[tuple[int, int, str]]:
    """Return validated (first observation, confirmation, owner) proofs."""
    events = []
    for key, value in connection.execute(
            "SELECT key, value FROM metadata WHERE key GLOB ?",
            (CONFIRMED_EVENT_KEY_PREFIX + "*",)):
        try:
            proof = json.loads(value)
            observation = proof["observation"]
            _state, confirmed_at, _pending = observe_full_weekly_reset(
                proof["state"], **observation,
            )
            if confirmed_at and key == f"{CONFIRMED_EVENT_KEY_PREFIX}{confirmed_at}":
                events.append((confirmed_at, int(observation["epoch"]), observation["owner"]))
        except (KeyError, TypeError, ValueError, OverflowError):
            continue
    return sorted(events)


def prune_full_weekly_resets(connection, cutoff: int) -> None:
    """Apply archive retention to durable proofs as well as their events."""
    for first_at, _confirmed_at, _owner in saved_full_weekly_resets(connection):
        if first_at < cutoff:
            connection.execute("DELETE FROM metadata WHERE key = ?",
                               (f"{CONFIRMED_EVENT_KEY_PREFIX}{first_at}",))
    connection.execute(
        "DELETE FROM reset_events WHERE detection_method = 'full_observed' AND reset_at_epoch < ?",
        (cutoff,),
    )


def legacy_baseline_has_evidence(connection, *, epoch: int, pct: Any,
                                 reset_at: Any, owner: str, before_epoch: int,
                                 history_entries=(), prior_state: str | None = None) -> bool:
    """Require a retained baseline with no intervening, possibly partial poll.

    Legacy detector timestamps tracked complete windows only. Missing values
    or a departed owner can therefore be invisible in that state alone.
    Absence of corroborating history is insufficient evidence for migration.
    """
    observations = []
    if connection is not None:
        observations.extend(connection.execute(
            "SELECT scraped_at_epoch, weekly_pct, weekly_reset_at, limit_id "
            "FROM snapshots WHERE scraped_at_epoch >= ? AND scraped_at_epoch < ? "
            "ORDER BY scraped_at_epoch LIMIT 2", (epoch, before_epoch),
        ).fetchall())
    observations.extend(
        (entry.epoch_microseconds // 1_000_000, entry.public.get("weekly_pct"),
         entry.public.get("weekly_reset_at"), entry.public.get("limit_id"))
        for entry in history_entries
        if epoch * 1_000_000 <= entry.epoch_microseconds < before_epoch * 1_000_000
    )
    corroborated = bool(observations)
    if prior_state is not None:
        prior = _load(prior_state)
        if (pct != 100 or prior.get("epoch") != epoch or prior.get("reset") != reset_at
                or prior.get("owner") != owner or prior.get("candidate") is not None):
            return False
        corroborated = True
    return corroborated and all(
        tuple(row) == (epoch, pct, reset_at, owner) for row in observations
    )


def _legacy_cli_evidence(args, pct, reset) -> bool:
    from pathlib import Path
    import sqlite3
    from history import read_existing_history
    from storage import ArchiveCorruptionError, ArchiveSchemaError, connect_database

    connection = None
    try:
        if args.legacy_archive and Path(args.legacy_archive).exists():
            connection = connect_database(Path(args.legacy_archive), read_only=True)
        entries = ()
        if args.legacy_history:
            loaded = read_existing_history(Path(args.legacy_history))
            if loaded.corrupt:
                return False
            entries = loaded.entries
        return legacy_baseline_has_evidence(
            connection, epoch=args.epoch, pct=pct, reset_at=reset, owner=args.owner,
            before_epoch=args.before_epoch, history_entries=entries,
            prior_state=args.legacy_observation or "",
        )
    except (OSError, ValueError, sqlite3.DatabaseError, ArchiveCorruptionError, ArchiveSchemaError):
        return False
    finally:
        if connection is not None:
            connection.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("state")
    parser.add_argument("epoch", type=int)
    parser.add_argument("pct")
    parser.add_argument("reset")
    parser.add_argument("owner")
    parser.add_argument("interval", type=int)
    parser.add_argument("--legacy-archive")
    parser.add_argument("--legacy-history")
    parser.add_argument("--legacy-observation")
    parser.add_argument("--before-epoch", type=int)
    args = parser.parse_args()
    try:
        pct, reset = float(args.pct), float(args.reset)
    except ValueError:
        pct = reset = None
    if args.before_epoch is not None and not _legacy_cli_evidence(args, pct, reset):
        print("\n0\n0")
        return
    state, confirmed, pending = observe_full_weekly_reset(
        args.state, epoch=args.epoch, pct=pct, reset_at=reset,
        owner=args.owner, interval=args.interval,
    )
    print(state)
    print(confirmed)
    print(int(pending))


if __name__ == "__main__":
    main()
