#!/usr/bin/env python3
"""Bounded weekly reset hook; never infer started usage from a date alone."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import time

from weekly_reset import observe_full_weekly_reset
from history import atomic_write
from codex_client import CodexClientError, fetch_status


def install_signal_handlers() -> None:
    def terminate(signum, _frame):
        # Unwind Python finally blocks so both the request group and the
        # status client's separately owned app-server are cleaned up.
        raise SystemExit(128 + signum)

    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, terminate)


def run_bounded(command: list[str], *, timeout: float, check: bool = False,
                env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    """Own and reap the command's group, including descendants holding pipes."""
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True, env=env)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        if check:
            result.check_returncode()
        return result
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=2)
        if process.stdout:
            process.stdout.close()
        if process.stderr:
            process.stderr.close()


def status_evidence(payload: dict, now: int) -> tuple[float, int, str]:
    """Validate fresh, coherent API evidence before it can acknowledge a hook."""
    pct, reset, owner = (payload.get(key) for key in
                         ("weekly_pct", "weekly_reset_at", "limit_id"))
    for value in (pct, reset):
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError("weekly status is incomplete")
    if not 0 <= pct <= 100 or not now < reset <= now + 7 * 86400:
        raise ValueError("weekly status is outside the expected window")
    if not isinstance(owner, str) or not owner:
        raise ValueError("weekly status has no limit owner")
    scraped = dt.datetime.fromisoformat(payload["scraped_at"].replace("Z", "+00:00"))
    if scraped.tzinfo is None or not 0 <= now - scraped.timestamp() <= 60:
        raise ValueError("weekly status is stale or future-dated")
    return float(pct), int(reset), owner


def run_hook() -> int:
    if (os.environ.get("CODEX_ALERT_EVENT") != "reset"
            or os.environ.get("CODEX_ALERT_WINDOW") != "weekly"):
        return 0
    local = Path(__file__).resolve().parent
    log_path = Path(os.environ.get("WEEKLY_START_LOG_FILE", local / "runtime" / "weekly-window-start.log"))
    log_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(log_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(descriptor, "a", encoding="utf-8") as output:
        def log(message: str) -> None:
            output.write(f"[{dt.datetime.now(dt.timezone.utc).isoformat()}] {message}\n")
            output.flush()

        try:
            attempts = int(os.environ.get("WEEKLY_START_MAX_ATTEMPTS", "10"))
            wait = int(os.environ.get("WEEKLY_START_WAIT_SECONDS", "120"))
            budget = int(os.environ.get("WEEKLY_START_RETRY_WINDOW_SECONDS", "1795"))
            if not 1 <= attempts <= 10 or not 0 <= wait <= 1800 or not 1 <= budget <= 1795:
                raise ValueError("invalid weekly hook retry limits")
        except ValueError as exc:
            log(f"ERROR: {exc}")
            return 2
        deadline = time.monotonic() + budget
        codex = os.environ.get("CODEX_ALERT_CODEX_BIN", "codex")
        state = ""
        original_owner = None

        def status() -> tuple[bool, str]:
            nonlocal state, original_owner
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("weekly hook budget exhausted")
            # Run the monitor's importable client in this process: its finally
            # always owns the detached app-server, including on hook SIGTERM.
            if remaining < 15:
                raise TimeoutError("insufficient budget for status cleanup")
            payload = fetch_status(codex, timeout_seconds=5, environment=os.environ)
            now = int(time.time())
            pct, reset, owner = status_evidence(payload, now)
            if original_owner is None:
                original_owner = owner
            if owner != original_owner:
                raise ValueError("limit owner changed during the weekly hook")
            state, confirmed, _pending = observe_full_weekly_reset(
                state, epoch=now, pct=pct, reset_at=reset, owner=owner,
                interval=payload.get("sample_interval_seconds", 900),
            )
            if pct < 100:
                return True, "cycle active: quota consumption observed"
            if confirmed:
                return True, "cycle deadline confirmed; quota consumption remains unverified"
            return False, "full quota: cycle start remains unverified"

        try:
            active, reason = status()
            log(f"Before request: {reason}")
            if active:
                return 0
            reset_identity = os.environ.get("CODEX_ALERT_RESET_AT", "")
            if not reset_identity.isdecimal() or int(reset_identity) <= 0:
                raise ValueError("weekly hook requires a reset occurrence identity")
            cycle = hashlib.sha256(json.dumps([
                original_owner, reset_identity, os.environ.get("CODEX_ALERT_ACTION_ID", ""),
            ]).encode()).hexdigest()
            receipt_path = log_path.with_name(f".weekly-window-start-budget-{cycle}.json")
            receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
            if not isinstance(receipt, dict):
                raise ValueError("invalid weekly hook budget receipt")
            if receipt.get("cycle") != cycle:
                receipt = {"cycle": cycle, "attempts": 0, "started_at": int(time.time())}
            if (not isinstance(receipt.get("attempts"), int)
                    or not 0 <= receipt["attempts"] <= 10
                    or not isinstance(receipt.get("started_at"), int)):
                raise ValueError("invalid weekly hook budget receipt")
            # The monitor retries failed hooks. Charge requests before launch
            # and retain the budget per occurrence so a retry/restart cannot
            # silently buy another ten requests or thirty minutes.
            remaining_cycle = max(0, receipt["started_at"] + budget - int(time.time()))
            deadline = min(deadline, time.monotonic() + remaining_cycle)
            for attempt in range(receipt["attempts"] + 1, attempts + 1):
                remaining = deadline - time.monotonic()
                if remaining <= 25:
                    break
                receipt["attempts"] = attempt
                atomic_write(receipt_path, (json.dumps(receipt) + "\n").encode())
                log(f"Attempt {attempt}/{attempts}: model=gpt-6.1-sol reasoning=medium")
                try:
                    result = run_bounded([
                        codex, "exec", "--ephemeral", "--model", "gpt-6.1-sol",
                        "--sandbox", "read-only", "-c", 'model_reasoning_effort="medium"',
                        "-c", 'approval_policy="never"', "--color", "never", "--json",
                        "-C", str(local.parent), "Salut",
                    ], timeout=min(120, remaining - 25))
                    # Preserve the local audit trail; exit status and token
                    # counts alone do not prove a weekly cycle was activated.
                    log(f"Codex exit={result.returncode}\n{result.stdout}\n{result.stderr}")
                except subprocess.TimeoutExpired:
                    log("Codex request timed out")
                remaining = deadline - time.monotonic()
                time.sleep(max(0, min(wait, remaining - 21)))
                active, reason = status()
                log(f"After request: {reason}")
                if active:
                    return 0
            log("WARNING: weekly start unverified; bounded retry budget exhausted")
            return 1
        except (ValueError, KeyError, TypeError, OSError, CodexClientError,
                subprocess.SubprocessError, TimeoutError) as exc:
            log(f"ERROR: weekly start unverified: {exc}")
            return 1


if __name__ == "__main__":
    install_signal_handlers()
    raise SystemExit(run_hook())
