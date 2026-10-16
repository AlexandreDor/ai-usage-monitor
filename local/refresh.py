"""Private dashboard refresh requests and post-reset collection scheduling."""

import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import time
import uuid
from datetime import datetime


def read_json(path):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(descriptor) as source:
            metadata = os.fstat(source.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
                return {}
            value = json.loads(source.read(65536))
            return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def write_json(path, value):
    descriptor, temporary = tempfile.mkstemp(prefix=".refresh-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as target:
            json.dump(value, target)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def request_refresh(runtime, timeout=60):
    """Wait for the separate monitor; the HTTP process never starts Codex."""
    identifier = uuid.uuid4().hex
    write_json(runtime / "dashboard-refresh.json", {"id": identifier, "expires_at": time.time() + timeout})
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = read_json(runtime / "dashboard-refresh-result.json")
        if result.get("id") == identifier:
            return bool(result.get("success"))
        time.sleep(0.2)
    raise TimeoutError("monitor did not complete the refresh")


def plan(runtime, now):
    state_path = runtime / "reset-refresh.json"
    state = read_json(state_path)
    previous = json.dumps(state, sort_keys=True)
    snapshot = read_json(runtime / "data.json")
    limit_id = snapshot.get("limit_id")
    if limit_id and state.get("limit_id") != limit_id:
        state = {"limit_id": limit_id}
    pending = state.setdefault("pending", {})
    completed = state.setdefault("completed", {})
    try:
        sampled = datetime.fromisoformat(snapshot["scraped_at"].replace("Z", "+00:00")).timestamp()
    except (KeyError, TypeError, ValueError, AttributeError):
        sampled = 0
    for window, horizon in (("five_h", 6 * 3600), ("weekly", 8 * 86400)):
        reset = snapshot.get(window + "_reset_at")
        if type(reset) is int and 0 < reset <= now + horizon and reset + 30 > sampled:
            key = f"{window}:{reset}"
            for previous_key in list(pending):
                previous_window, previous_reset = previous_key.split(":")
                if previous_window == window and previous_key != key and int(previous_reset) > now:
                    del pending[previous_key]
            if reset > completed.get(window, 0):
                pending[key] = reset + 30
    # A regular or manual collection after the grace period also satisfies a
    # scheduled check, including after a restart or a reset estimate advance.
    for key, due in list(pending.items()):
        if sampled >= due:
            window, reset = key.split(":")
            completed[window] = max(completed.get(window, 0), int(reset))
            del pending[key]
    due = min(pending.values(), default=now + 86400)
    delay = max(0, max(due, state.get("retry_at", 0)) - now)
    if json.dumps(state, sort_keys=True) != previous:
        write_json(state_path, state)
    request = read_json(runtime / "dashboard-refresh.json")
    result = read_json(runtime / "dashboard-refresh-result.json")
    identifier = request.get("id", "")
    valid_id = isinstance(identifier, str) and len(identifier) == 32 and all(c in "0123456789abcdef" for c in identifier)
    if not valid_id or request.get("expires_at", 0) <= now or result.get("id") == identifier:
        identifier = "-"
    return identifier, int(delay)


def pending_reset_checks(runtime):
    """Expose pending check times, never the private scheduler state."""
    state = read_json(runtime / "reset-refresh.json")
    pending = state.get("pending", {})
    if not isinstance(pending, dict):
        return []
    deadlines = [due for due in pending.values() if type(due) is int and due > 0]
    if not deadlines:
        return []
    retry_at = state.get("retry_at", 0)
    if type(retry_at) is not int:
        retry_at = 0
    return sorted({max(due, retry_at) for due in deadlines})


def complete(runtime, identifier, status, now, started_at=None):
    state_path = runtime / "reset-refresh.json"
    state = read_json(state_path)
    if status == 0:
        pending = state.get("pending", {})
        completed = state.setdefault("completed", {})
        for key, due in list(pending.items()):
            # A cycle that started before a deadline cannot satisfy it merely
            # because notification delivery finished after that deadline.
            if due <= (now if started_at is None else started_at):
                window, reset = key.split(":")
                completed[window] = max(completed.get(window, 0), int(reset))
                del pending[key]
        state.pop("retry_at", None)
    else:
        state["retry_at"] = now + (5 if status == 75 else 30)
    write_json(state_path, state)
    if identifier != "-" and status != 75:
        write_json(runtime / "dashboard-refresh-result.json", {"id": identifier, "success": status == 0})


if __name__ == "__main__":
    action, directory, *arguments = sys.argv[1:]
    if action == "plan":
        print(*plan(Path(directory), int(arguments[0])))
    elif action == "complete":
        complete(Path(directory), arguments[0], *map(int, arguments[1:]))
