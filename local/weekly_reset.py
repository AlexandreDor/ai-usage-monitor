"""Conservative evidence for weekly cycles observed while quota is full."""

from __future__ import annotations

import argparse
import base64
import json
import math
from typing import Any, NamedTuple


MIN_ADVANCE_SECONDS = 1800
CONFIRMATION_TOLERANCE_SECONDS = 60
CONFIRMED_EVENT_KEY_PREFIX = "full_weekly_reset_confirmed:"
OBSERVED_EVENT_KEY_PREFIX = "weekly_reset_observed:"
WEEKLY_EVIDENCE_START_KEY = "weekly_reset_evidence_start"
WEEKLY_HISTORY_STATE_KEY = "weekly_reset_history_state"
RANDOM_WEEKLY_RESET_MIN_CHANGE_PCT = 20.0
RANDOM_WEEKLY_RESET_FULL_REFILL_PCT = 98.0
RANDOM_WEEKLY_RESET_MIN_DEADLINE_ADVANCE_SECONDS = MIN_ADVANCE_SECONDS


class FullWeeklyResetProof(NamedTuple):
    first_at: int
    confirmed_at: int
    owner: str
    deadline: int
    interval: int


class WeeklyResetEvent(NamedTuple):
    first_at: int
    observed_at: int
    owner: str
    before_pct: float
    after_pct: float
    method: str


def is_weekly_refill(previous_pct, current_pct, previous_reset, current_reset) -> bool:
    if previous_reset is None or current_reset is None:
        return False
    change = current_pct - previous_pct
    return (current_reset >= previous_reset + RANDOM_WEEKLY_RESET_MIN_DEADLINE_ADVANCE_SECONDS
            and change > 0 and (change >= RANDOM_WEEKLY_RESET_MIN_CHANGE_PCT
                                or current_pct >= RANDOM_WEEKLY_RESET_FULL_REFILL_PCT))


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


def saved_full_weekly_resets(connection) -> list[FullWeeklyResetProof]:
    """Return validated proofs, including the confirmed cycle's deadline."""
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
                interval = observation.get("interval", 900)
                interval = int(interval) if _number(interval) and interval > 0 else 900
                events.append(FullWeeklyResetProof(
                    confirmed_at, int(observation["epoch"]), observation["owner"],
                    int(observation["reset_at"]), interval,
                ))
        except (KeyError, TypeError, ValueError, OverflowError):
            continue
    return sorted(events)


def _observed_weekly_event(previous, current) -> WeeklyResetEvent | None:
    """Validate an actual adjacent detector pair, never a synthetic baseline."""
    for sample in (previous, current):
        if (not all(_number(sample.get(key)) for key in ("epoch", "pct", "reset_at", "interval"))
                or sample["epoch"] <= 0 or not 0 <= sample["pct"] <= 100
                or sample["reset_at"] <= 0 or sample["interval"] <= 0):
            return None
    owner = current.get("owner")
    if (not isinstance(owner, str) or not owner or owner == "__unknown__"
            or previous.get("owner") != owner or current["epoch"] <= previous["epoch"]
            or not current["epoch"] < current["reset_at"] <= current["epoch"] + 8 * 86400):
        return None
    scheduled = (
        previous["epoch"] < previous["reset_at"] <= current["epoch"]
        and current["reset_at"] > previous["reset_at"]
        and current["epoch"] - previous["epoch"]
        <= max(3600, 2 * max(previous["interval"], current["interval"]))
    )
    if scheduled:
        first_at, method = int(previous["reset_at"]), "scheduled_crossing"
    elif is_weekly_refill(previous["pct"], current["pct"], previous["reset_at"], current["reset_at"]):
        first_at, method = int(current["epoch"]), "random_observed"
    else:
        return None
    return WeeklyResetEvent(first_at, int(current["epoch"]), owner,
                            previous["pct"], current["pct"], method)


def record_observed_weekly_reset(connection, previous, current) -> None:
    event = _observed_weekly_event(previous, current)
    if event is None:
        return
    connection.execute(
        "INSERT OR IGNORE INTO metadata(key, value) VALUES (?, ?)",
        (f"{OBSERVED_EVENT_KEY_PREFIX}{event.method}:{event.first_at}",
         json.dumps({"previous": previous, "observation": current}, separators=(",", ":"))),
    )
    connection.execute(
        """INSERT OR IGNORE INTO reset_events (
            window, reset_at_epoch, observed_at_epoch, before_pct, after_pct, detection_method
        ) VALUES ('weekly', ?, ?, ?, ?, ?)""",
        (event.first_at, event.observed_at, event.before_pct, event.after_pct, event.method),
    )


def saved_observed_weekly_resets(connection) -> list[WeeklyResetEvent]:
    events = []
    for key, value in connection.execute(
            "SELECT key, value FROM metadata WHERE key GLOB ?", (OBSERVED_EVENT_KEY_PREFIX + "*",)):
        try:
            proof = json.loads(value)
            event = _observed_weekly_event(proof["previous"], proof["observation"])
            if event and key == f"{OBSERVED_EVENT_KEY_PREFIX}{event.method}:{event.first_at}":
                events.append(event)
        except (AttributeError, KeyError, TypeError, ValueError, OverflowError):
            continue
    return sorted(events)


def observe_weekly_reset_history(connection, *, epoch, pct, reset_at, owner, interval,
                                 prior_observation_epoch=0, full_state="") -> None:
    """Classify events from a separate last complete, owner-scoped baseline.

    Anomaly state also tracks incomplete percentages and cannot serve as this
    baseline. Same-owner partials retain it; every foreign/unknown observation
    clears it, even if an owner returns through another partial observation.
    """
    row = connection.execute("SELECT value FROM metadata WHERE key=?", (WEEKLY_HISTORY_STATE_KEY,)).fetchone()
    try:
        state = json.loads(row[0]) if row else {}
        if (not isinstance(state, dict)
                or not _number(state.get("observed_at")) or state["observed_at"] <= 0):
            state = {}
    except (TypeError, ValueError):
        state = {}
    if epoch <= state.get("observed_at", prior_observation_epoch):
        return
    known_owner = isinstance(owner, str) and owner and owner != "__unknown__"
    baseline = state.get("baseline") if known_owner and state.get("owner") == owner else None
    interval = int(interval) if _number(interval) and interval > 0 else 900
    complete = (_number(pct) and 0 <= pct <= 100 and _number(reset_at)
                and epoch < reset_at <= epoch + 8 * 86400 and known_owner)
    if complete:
        current = {"epoch": epoch, "pct": pct, "reset_at": reset_at, "owner": owner, "interval": interval}
        if isinstance(baseline, dict):
            record_observed_weekly_reset(connection, baseline, current)
        if not connection.execute("SELECT 1 FROM metadata WHERE key=?", (WEEKLY_EVIDENCE_START_KEY,)).fetchone():
            pending = _load(full_state).get("candidate")
            confirmed = any(proof.confirmed_at == epoch for proof in saved_full_weekly_resets(connection))
            # Preserve the initial legacy transition only until a complete baseline
            # exists. A known full candidate/confirmation already has stronger
            # evidence and must not be reclassified by sparse legacy snapshots.
            start = epoch if baseline is not None or pending or confirmed else epoch + 1
            connection.execute("INSERT INTO metadata(key, value) VALUES (?, ?)",
                               (WEEKLY_EVIDENCE_START_KEY, str(start)))
        baseline = current
    connection.execute(
        "INSERT INTO metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (WEEKLY_HISTORY_STATE_KEY,
         json.dumps({"observed_at": epoch, "owner": owner, "baseline": baseline}, separators=(",", ":"))),
    )


def prune_weekly_reset_evidence(connection, cutoff: int) -> None:
    """Apply archive retention to durable proofs as well as their events."""
    for proof in saved_full_weekly_resets(connection):
        if proof.first_at < cutoff:
            connection.execute("DELETE FROM metadata WHERE key = ?",
                               (f"{CONFIRMED_EVENT_KEY_PREFIX}{proof.first_at}",))
    for event in saved_observed_weekly_resets(connection):
        if event.first_at < cutoff:
            connection.execute("DELETE FROM metadata WHERE key = ?",
                               (f"{OBSERVED_EVENT_KEY_PREFIX}{event.method}:{event.first_at}",))
    connection.execute(
        "DELETE FROM reset_events WHERE window = 'weekly' AND reset_at_epoch < ?",
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
