#!/usr/bin/env python3
"""Detect and persist implausible quota movements.

The detector deliberately keeps its small amount of rolling state in SQLite.
It can therefore be called by both the full archive cycle and a live cycle;
replaying the same observation is harmless and does not create snapshots.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import sqlite3
import sys
from typing import Any

from storage import ArchiveCorruptionError, canonicalize_limit_id, connect_database


# These are intentionally named and shared with archive.py/monitor.sh's
# weekly-reset classifier.  A movement accepted as a reset must never become
# an anomaly as well.
QUOTA_INCREASE_TOLERANCE_PCT = 5.0
RESET_SHIFT_TOLERANCE_SECONDS = 30 * 60
RESET_OSCILLATION_MIN_DELTA_SECONDS = 3 * 60
RESET_MISSING_CONFIRMATIONS = 2
RANDOM_WEEKLY_RESET_MIN_CHANGE_PCT = 20.0
RANDOM_WEEKLY_RESET_FULL_REFILL_PCT = 98.0
RANDOM_WEEKLY_RESET_MIN_DEADLINE_ADVANCE_SECONDS = 30 * 60
WINDOWS = (("5h", "five_h_pct", "five_h_reset_at"),
           ("weekly", "weekly_pct", "weekly_reset_at"))
ANOMALY_TYPES = (
    "quota_increase", "reset_shift", "reset_in_past", "reset_missing",
    "reset_oscillation",
)


def _format_reset_timestamp(timestamp: int) -> str:
    """Format anomaly timestamps as deterministic UTC wall-clock dates."""
    return dt.datetime.fromtimestamp(timestamp, dt.timezone.utc).strftime(
        "%d/%m/%Y - %H:%M"
    )


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = float(value)
    return value if math.isfinite(value) and 0 <= value <= 100 else None


def _epoch(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = int(value)
    return value if value > 0 else None


def _limit_id(value: Any) -> str:
    if isinstance(value, str) and value and all(ord(char) >= 32 for char in value):
        return canonicalize_limit_id(value) or "__unknown__"
    return "__unknown__"


def _state_default() -> dict[str, Any]:
    return {
        "last_epoch": 0,
        "last_pct": None,
        "last_reset_at": None,
        "last_available_reset_at": None,
        # The generic rolling baseline advances on a valid percentage even
        # when the reset deadline is temporarily absent.  Keep a second,
        # complete-only baseline for the 5h classifier so an A -> partial -> A
        # sequence cannot turn a planned crossing into a quota increase.
        "last_complete_epoch": 0,
        "last_complete_pct": None,
        "last_complete_reset_at": None,
        "missing_streak": 0,
        "missing_started_epoch": 0,
        "reset_history": [],
        "oscillation_signature": None,
        "oscillation_episode_started": 0,
        "stable_count": 0,
        "quota_increase_active": False,
        "reset_shift_signature": None,
        "reset_shift_episode_started": 0,
    }


def _load_state(connection: sqlite3.Connection, limit_id: str, window: str,
                current_epoch: int) -> tuple[dict[str, Any], bool]:
    row = connection.execute(
        "SELECT state_json FROM anomaly_detector_state WHERE limit_id = ? AND window = ?",
        (limit_id, window),
    ).fetchone()
    if row:
        try:
            value = json.loads(row[0])
            if isinstance(value, dict):
                state = _state_default()
                state.update(value)
                if window == "5h":
                    # States written before the complete-baseline fields can
                    # still be upgraded safely when their last generic sample
                    # was complete.  A missing reset deadline is deliberately
                    # not enough evidence to infer the complete sample time.
                    if not all(key in value for key in (
                            "last_complete_epoch", "last_complete_pct",
                            "last_complete_reset_at")):
                        old_epoch = _epoch(value.get("last_epoch"))
                        old_pct = _number(value.get("last_pct"))
                        old_reset = _epoch(value.get("last_reset_at"))
                        if old_epoch is not None and old_pct is not None and old_reset is not None:
                            state.update({
                                "last_complete_epoch": old_epoch,
                                "last_complete_pct": old_pct,
                                "last_complete_reset_at": old_reset,
                            })
                return state, True
        except (TypeError, ValueError, json.JSONDecodeError):
            pass

    # A v3 archive has useful observations but no detector state. Seed from the
    # most recent coherent row without comparing across limit groups.
    pct_column = "five_h_pct" if window == "5h" else "weekly_pct"
    reset_column = "five_h_reset_at" if window == "5h" else "weekly_reset_at"
    row = connection.execute(
        f"""SELECT scraped_at_epoch, {pct_column}, {reset_column}
              FROM snapshots
             WHERE scraped_at_epoch < ? AND limit_id IS ?
             ORDER BY scraped_at_epoch DESC LIMIT 1""",
        (current_epoch, None if limit_id == "__unknown__" else limit_id),
    ).fetchone()
    state = _state_default()
    if row and _number(row[1]) is not None:
        state.update({
            "last_epoch": int(row[0]), "last_pct": _number(row[1]),
            "last_reset_at": _epoch(row[2]),
            "last_available_reset_at": _epoch(row[2]),
        })
        if state["last_reset_at"] is not None:
            state.update({
                "last_complete_epoch": int(row[0]),
                "last_complete_pct": _number(row[1]),
                "last_complete_reset_at": state["last_reset_at"],
            })
            state["reset_history"] = [[int(row[0]), state["last_reset_at"]]]
    return state, False


def _save_state(connection: sqlite3.Connection, limit_id: str, window: str,
                state: dict[str, Any], epoch: int) -> None:
    connection.execute(
        """
        INSERT INTO anomaly_detector_state(limit_id, window, state_json, updated_at_epoch)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(limit_id, window) DO UPDATE SET
          state_json = excluded.state_json,
          updated_at_epoch = excluded.updated_at_epoch
        """,
        (limit_id, window, json.dumps(state, separators=(",", ":"), sort_keys=True), epoch),
    )


def _weekly_reset(previous_pct: float, current_pct: float,
                  previous_reset: int | None, current_reset: int | None) -> bool:
    if previous_reset is None or current_reset is None:
        return False
    change = current_pct - previous_pct
    return (
        current_reset >= previous_reset + RANDOM_WEEKLY_RESET_MIN_DEADLINE_ADVANCE_SECONDS
        and change > 0
        and (change >= RANDOM_WEEKLY_RESET_MIN_CHANGE_PCT
             or current_pct >= RANDOM_WEEKLY_RESET_FULL_REFILL_PCT)
    )


def _observed_five_hour_reset(previous_pct: float, current_pct: float,
                              previous_reset: int | None,
                              current_reset: int | None) -> bool:
    """Recognize a full 5-hour cycle whose quota stayed at 100%."""
    if previous_reset is None or current_reset is None:
        return False
    return (
        previous_pct == 100
        and current_pct == 100
        and current_reset > previous_reset
    )


def _five_hour_complete_baseline(state: dict[str, Any]) -> tuple[int, float, int] | None:
    previous_epoch = _epoch(state.get("last_complete_epoch"))
    previous_pct = _number(state.get("last_complete_pct"))
    previous_reset = _epoch(state.get("last_complete_reset_at"))
    if previous_epoch is None or previous_pct is None or previous_reset is None:
        return None
    return previous_epoch, previous_pct, previous_reset


def _scheduled_crossing(state: dict[str, Any], current_epoch: int,
                        window: str) -> bool:
    if window == "5h":
        baseline = _five_hour_complete_baseline(state)
        if baseline is None:
            return False
        previous_epoch, _, previous_reset = baseline
    else:
        previous_epoch = _epoch(state.get("last_epoch"))
        previous_reset = _epoch(state.get("last_reset_at"))
        if previous_reset is None:
            previous_reset = _epoch(state.get("last_available_reset_at"))
    return bool(
        previous_epoch is not None and previous_reset is not None
        and previous_epoch < previous_reset <= current_epoch
    )


def _dedupe_key(limit_id: str, window: str, anomaly_type: str, episode: str) -> str:
    return f"{limit_id}|{window}|{anomaly_type}|{episode}"


def _insert_anomaly(connection: sqlite3.Connection, *, limit_id: str, window: str,
                    anomaly_type: str, episode: str, detected_at: int,
                    before_pct: float | None, after_pct: float | None,
                    before_reset: int | None, after_reset: int | None,
                    message: str) -> None:
    dedupe = _dedupe_key(limit_id, window, anomaly_type, episode)
    anomaly_id = hashlib.sha256(("quota-anomaly-v1\0" + dedupe).encode()).hexdigest()[:24]
    connection.execute(
        """
        INSERT OR IGNORE INTO quota_anomalies(
            anomaly_id, dedupe_key, anomaly_type, window, limit_id,
            detected_at_epoch, before_pct, after_pct, before_reset_at,
            after_reset_at, message, journaled_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
        """,
        (anomaly_id, dedupe, anomaly_type, window, limit_id, detected_at,
         before_pct, after_pct, before_reset, after_reset, message),
    )


def _record_reset_history(state: dict[str, Any], epoch: int,
                          reset_at: int | None) -> None:
    history = state.get("reset_history")
    if not isinstance(history, list):
        history = []
    if reset_at is not None:
        history.append([epoch, reset_at])
        state["reset_history"] = history[-6:]
        previous = state.get("last_reset_at")
        if previous == reset_at:
            state["stable_count"] = int(state.get("stable_count", 0)) + 1
            if state["stable_count"] >= 2:
                state["oscillation_signature"] = None
        else:
            state["stable_count"] = 0


def _detect_window(connection: sqlite3.Connection, *, limit_id: str, window: str,
                   pct: Any, reset_at: Any, epoch: int,
                   force_baseline: bool) -> None:
    current_pct = _number(pct)
    current_reset = _epoch(reset_at)
    if current_pct is None:
        return
    state, state_exists = _load_state(connection, limit_id, window, epoch)
    # Switching the globally active group must not erase a durable baseline.
    # A group that returns after an interruption can resume its own segmented
    # state; only a genuinely unseen (or incomplete) group starts baseline.
    if (force_baseline and not state_exists) or _number(state.get("last_pct")) is None:
        state.update({
            "last_epoch": epoch, "last_pct": current_pct,
            "last_reset_at": current_reset,
            "last_available_reset_at": current_reset,
            "missing_streak": 0,
            "missing_started_epoch": 0, "reset_history": [],
            "oscillation_signature": None, "stable_count": 0,
            "oscillation_episode_started": 0,
            "reset_shift_episode_started": 0,
            "quota_increase_active": False, "reset_shift_signature": None,
        })
        if window == "5h":
            state.update({
                "last_complete_epoch": epoch if current_reset is not None else 0,
                "last_complete_pct": current_pct if current_reset is not None else None,
                "last_complete_reset_at": current_reset,
            })
        _record_reset_history(state, epoch, current_reset)
        _save_state(connection, limit_id, window, state, epoch)
        return

    previous_epoch = _epoch(state.get("last_epoch"))
    if previous_epoch is None or epoch <= previous_epoch:
        return
    generic_previous_reset = _epoch(state.get("last_reset_at"))
    if generic_previous_reset is None:
        generic_previous_reset = _epoch(state.get("last_available_reset_at"))
    complete_baseline = _five_hour_complete_baseline(state) if window == "5h" else None
    comparison_available = window != "5h" or complete_baseline is not None
    if complete_baseline is not None:
        _, previous_pct, previous_reset = complete_baseline
    else:
        previous_pct = float(state["last_pct"])
        previous_reset = generic_previous_reset
    scheduled_crossing = _scheduled_crossing(state, epoch, window)
    recognized_weekly = window == "weekly" and _weekly_reset(
        previous_pct, current_pct, previous_reset, current_reset
    )
    recognized_five_hour = window == "5h" and comparison_available and _observed_five_hour_reset(
        previous_pct, current_pct, previous_reset, current_reset
    )
    reset_in_past = current_reset is not None and current_reset <= epoch

    anomaly: tuple[str, str] | None = None
    if not scheduled_crossing and not recognized_weekly and not recognized_five_hour:
        # A deadline that has just crossed the sampling instant is a planned
        # reset, not a malformed movement.  A deadline already in the past on
        # both sides is also not a new movement.
        if comparison_available and reset_in_past and (
                previous_reset is None or current_reset < previous_reset):
            anomaly = (
                "reset_in_past",
                f"{window} reset date moved into the past ({current_reset}); "
                "quota did not show a recognized reset.",
            )
        elif comparison_available and previous_reset is not None and current_reset is not None:
            delta = current_reset - previous_reset
            if abs(delta) > RESET_SHIFT_TOLERANCE_SECONDS and not reset_in_past:
                anomaly = (
                    "reset_shift",
                    f"{window} reset date moved by {abs(delta) // 60} minutes "
                    "without a quota refill.",
                ) if current_pct <= previous_pct + QUOTA_INCREASE_TOLERANCE_PCT else None

        if anomaly is None and current_reset is None and previous_reset is not None:
            streak = int(state.get("missing_streak", 0)) + 1
            state["missing_streak"] = streak
            if not state.get("missing_started_epoch"):
                state["missing_started_epoch"] = epoch
            if streak >= RESET_MISSING_CONFIRMATIONS:
                anomaly = (
                    "reset_missing",
                    f"{window} reset date disappeared for {streak} consecutive "
                    "valid observations.",
                )
        elif current_reset is not None:
            state["missing_streak"] = 0
            state["missing_started_epoch"] = 0
            state["last_available_reset_at"] = current_reset
        # An A→B→A sequence is more useful as an oscillation episode than as
        # two independent reset-shift reports, even when the dates differ by
        # more than the shift tolerance.
        if current_reset is not None and (
            anomaly is None or anomaly[0] == "reset_shift"
        ):
            history = state.get("reset_history", [])
            if (len(history) >= 2 and history[-1][1] != current_reset
                    and history[-2][1] == current_reset):
                pair = sorted((int(history[-1][1]), int(current_reset)))
                signature = f"{pair[0]}:{pair[1]}"
                if (pair[1] - pair[0] >= RESET_OSCILLATION_MIN_DELTA_SECONDS
                        and state.get("oscillation_signature") != signature):
                    anomaly = (
                        "reset_oscillation",
                        f"{window} reset date oscillated repeatedly between "
                        f"{_format_reset_timestamp(pair[0])} and "
                        f"{_format_reset_timestamp(pair[1])}.",
                    )
                    state["oscillation_signature"] = signature
                    state["oscillation_episode_started"] = epoch
        if (anomaly is None and current_pct > previous_pct + QUOTA_INCREASE_TOLERANCE_PCT
                and (window != "5h" or (comparison_available and current_reset is not None))):
            anomaly = (
                "quota_increase",
                f"{window} remaining quota rose from {previous_pct:g}% to "
                f"{current_pct:g}% without a recognized reset.",
            )

    quota_jump = (
        current_pct > previous_pct + QUOTA_INCREASE_TOLERANCE_PCT
        and (window != "5h" or (comparison_available and current_reset is not None))
    )
    if not quota_jump:
        state["quota_increase_active"] = False
    if anomaly is not None and anomaly[0] == "quota_increase":
        if state.get("quota_increase_active"):
            anomaly = None
        else:
            state["quota_increase_active"] = True
    elif anomaly is not None and anomaly[0] == "reset_shift":
        signature = f"{previous_reset}:{current_reset}"
        if state.get("reset_shift_signature") == signature:
            anomaly = None
        else:
            state["reset_shift_signature"] = signature
            state["reset_shift_episode_started"] = epoch
    elif not (previous_reset is not None and current_reset is not None
              and abs(current_reset - previous_reset) > RESET_SHIFT_TOLERANCE_SECONDS):
        state["reset_shift_signature"] = None
        state["reset_shift_episode_started"] = 0

    if anomaly is not None:
        anomaly_type, message = anomaly
        episode = {
            "quota_increase": str(previous_epoch),
            "reset_shift": (
                f"{previous_reset}:{current_reset}:"
                f"{state.get('reset_shift_episode_started') or epoch}"
            ),
            "reset_in_past": str(current_reset),
            "reset_missing": str(state.get("missing_started_epoch") or epoch),
            "reset_oscillation": (
                f"{state.get('oscillation_signature') or 'episode'}:"
                f"{state.get('oscillation_episode_started') or epoch}"
            ),
        }[anomaly_type]
        _insert_anomaly(
            connection, limit_id=limit_id, window=window,
            anomaly_type=anomaly_type, episode=episode, detected_at=epoch,
            before_pct=previous_pct, after_pct=current_pct,
            before_reset=previous_reset, after_reset=current_reset,
            message=message,
        )

    # Keep one coherent baseline; an alert registration failure must not make
    # the next cycle compare against an older quota value forever.
    # Record stability against the previous reset before replacing it with the
    # current observation; this is what closes an oscillation episode only
    # after two genuinely stable samples.
    _record_reset_history(state, epoch, current_reset)
    state["last_epoch"] = epoch
    state["last_pct"] = current_pct
    state["last_reset_at"] = current_reset
    if current_reset is not None:
        state["last_available_reset_at"] = current_reset
        if window == "5h":
            state.update({
                "last_complete_epoch": epoch,
                "last_complete_pct": current_pct,
                "last_complete_reset_at": current_reset,
            })
    _save_state(connection, limit_id, window, state, epoch)


def process_snapshot(connection: sqlite3.Connection, snapshot: dict[str, Any]) -> None:
    """Process one normalized snapshot inside the caller's transaction."""
    epoch = _epoch(snapshot.get("scraped_at_epoch"))
    if epoch is None:
        return
    limit_id = _limit_id(snapshot.get("limit_id"))
    active = connection.execute(
        "SELECT value FROM metadata WHERE key = 'anomaly_active_limit_id'"
    ).fetchone()
    active_limit = active[0] if active else None
    force_baseline = active_limit != limit_id
    if force_baseline:
        connection.execute(
            """
            INSERT INTO metadata(key, value) VALUES('anomaly_active_limit_id', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, (limit_id,),
        )
    for window, pct_key, reset_key in WINDOWS:
        _detect_window(
            connection, limit_id=limit_id, window=window,
            pct=snapshot.get(pct_key), reset_at=snapshot.get(reset_key),
            epoch=epoch, force_baseline=force_baseline,
        )


def pending_anomalies(connection: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = connection.execute(
        """
        SELECT anomaly_id, anomaly_type, window, limit_id, detected_at_epoch,
               before_pct, after_pct, before_reset_at, after_reset_at, message
          FROM quota_anomalies
         WHERE journaled_at IS NULL
         ORDER BY detected_at_epoch, anomaly_id
        """
    ).fetchall()
    keys = ("anomaly_id", "anomaly_type", "window", "limit_id", "detected_at_epoch",
            "before_pct", "after_pct", "before_reset_at", "after_reset_at", "message")
    return [dict(zip(keys, row)) for row in rows]


def mark_journaled(connection: sqlite3.Connection, anomaly_id: str, at: int) -> bool:
    cursor = connection.execute(
        "UPDATE quota_anomalies SET journaled_at = ? WHERE anomaly_id = ? AND journaled_at IS NULL",
        (at, anomaly_id),
    )
    return cursor.rowcount == 1


def _parse_snapshot(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("snapshot must be an object")
    scraped = value.get("scraped_at_epoch")
    if scraped is not None:
        if isinstance(scraped, bool) or not isinstance(scraped, (int, float)) \
                or not math.isfinite(float(scraped)):
            raise ValueError("snapshot has an invalid scraped_at_epoch")
        scraped = int(scraped)
    else:
        text = value.get("scraped_at")
        if not isinstance(text, str):
            raise ValueError("snapshot has no timestamp")
        parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        scraped = int(parsed.timestamp())
    if scraped <= 0:
        raise ValueError("snapshot timestamp must be greater than zero")
    for key in ("five_h_pct", "weekly_pct"):
        if key in value and value[key] is not None and _number(value[key]) is None:
            raise ValueError(f"snapshot has an invalid {key}")
    for key in ("five_h_reset_at", "weekly_reset_at"):
        if key in value and value[key] is not None and _epoch(value[key]) is None:
            raise ValueError(f"snapshot has an invalid {key}")
    result = dict(value)
    result["scraped_at_epoch"] = int(scraped)
    return result


def command(args: argparse.Namespace) -> None:
    database = __import__("pathlib").Path(args.database)
    if args.action == "pending":
        connection = connect_database(database)
        try:
            for item in pending_anomalies(connection):
                print(json.dumps(item, separators=(",", ":"), ensure_ascii=False))
        finally:
            connection.close()
        return
    connection = connect_database(database)
    try:
        with connection:
            if args.action == "observe":
                value = json.load(sys.stdin)
                process_snapshot(connection, _parse_snapshot(value))
            elif args.action == "journal":
                if not mark_journaled(connection, args.anomaly_id, args.at):
                    raise ValueError("unknown or already journaled anomaly")
    finally:
        connection.close()


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    sub = result.add_subparsers(dest="action", required=True)
    for action in ("pending", "observe"):
        command_parser = sub.add_parser(action)
        command_parser.add_argument("--database", required=True)
    journal = sub.add_parser("journal")
    journal.add_argument("--database", required=True)
    journal.add_argument("anomaly_id")
    journal.add_argument("--at", type=int, required=True)
    return result


if __name__ == "__main__":
    try:
        command(parser().parse_args())
    except (ArchiveCorruptionError, OSError, sqlite3.DatabaseError,
            ValueError, OverflowError, TypeError, json.JSONDecodeError) as exc:
        print(f"anomalies: {exc}", file=sys.stderr)
        raise SystemExit(1)
