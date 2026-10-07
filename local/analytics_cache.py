"""Bounded, process-local analytics memoization with concurrent miss coalescing."""

from __future__ import annotations

from collections import OrderedDict
from concurrent.futures import Future
from copy import deepcopy
from pathlib import Path
import secrets
import sqlite3
from threading import Lock
from typing import Any, Callable


def archive_revision(database: Path) -> tuple:
    """Fingerprint both SQLite files; WAL commits and atomic replacements matter.

    Used alongside a persistent observer's data_version in SnapshotRevisions;
    equal file fingerprints alone do not establish snapshot identity.
    """
    result = [str(database.resolve())]
    for path in (database, Path(str(database) + "-wal")):
        try:
            value = path.stat()
            result.append((value.st_dev, value.st_ino, value.st_size,
                           value.st_mtime_ns, value.st_ctime_ns))
        except FileNotFoundError:
            result.append(None)
    return tuple(result)


class SnapshotRevisions:
    """Name pinned snapshots using a persistent observer's commit counter.

    File timestamps alone cannot detect the interval between writing a WAL
    commit frame and publishing it to readers. A persistent connection's
    data_version changes when that publication actually becomes visible.
    Observers never keep read transactions open or write archive content.
    Observation starts before the request connection opens, including schema
    checks and any migration into an in-memory copy. Naming an already opened
    connection from the pathname alone can otherwise misidentify a replaced
    file or an older migrated copy as the current archive.
    """

    def __init__(self, max_archives=8):
        self.max_archives = max_archives
        self._observers = OrderedDict()
        self._lock = Lock()

    def _observe_locked(self, database: Path) -> tuple | None:
        before = archive_revision(database)
        name = before[0]
        identity = before[1][:2] if before[1] is not None else None
        observer = self._observers.get(name)
        if observer is not None and observer[0] != identity:
            observer[1].close()
            del self._observers[name]
            observer = None
        if observer is None:
            reader = sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True,
                                     check_same_thread=False, isolation_level=None, timeout=0.25)
            observer = (identity, reader, secrets.token_hex(16))
            self._observers[name] = observer
            while len(self._observers) > self.max_archives:
                _name, old = self._observers.popitem(last=False)
                old[1].close()
        self._observers.move_to_end(name)
        reader = observer[1]
        version_before = reader.execute("PRAGMA data_version").fetchone()[0]
        observed = archive_revision(database)
        version_after = reader.execute("PRAGMA data_version").fetchone()[0]
        after = archive_revision(database)
        after_identity = after[1][:2] if after[1] is not None else None
        # Opening the observer may create an empty WAL. That is safe when its
        # file identity matches and the resulting observation is stable. A
        # replacement during observer opening must never name the wrong file.
        if identity == after_identity and observed == after and version_before == version_after:
            return (after, observer[2], version_after)
        return None

    def observe(self, database: Path) -> tuple | None:
        """Capture the required observation before opening a request connection."""
        with self._lock:
            return self._observe_locked(database)

    def pin(self, connection: sqlite3.Connection, database: Path, *, expected: tuple | None) -> tuple | None:
        """Pin a read snapshot; cache it only if the pre-open observation survived.

        Callers that cannot observe before opening must pass expected=None;
        their coherent read still works, but cannot populate shared caches.
        """
        with self._lock:
            before = self._observe_locked(database)
            connection.execute("BEGIN")
            connection.execute("SELECT value FROM metadata LIMIT 1").fetchone()
            after = self._observe_locked(database)
            if expected is not None and expected == before == after:
                return after
            return None


class AnalyticsCache:
    def __init__(self, max_entries: int = 256, max_bytes: int = 16 * 1024 * 1024):
        self.max_entries = max_entries
        self.max_bytes = max_bytes
        self._values = OrderedDict()
        self._pending = {}
        self._bytes = 0
        self._lock = Lock()

    def get_or_compute(self, key: tuple, compute: Callable[[], Any]) -> Any:
        with self._lock:
            if key in self._values:
                value, _size = self._values[key]
                self._values.move_to_end(key)
                return deepcopy(value)
            future = self._pending.get(key)
            owner = future is None
            if owner:
                future = Future()
                self._pending[key] = future
        if not owner:
            return deepcopy(future.result())
        try:
            value = compute()
            # Serialize only for bounded storage accounting; values remain native.
            import json
            size = len(json.dumps(value, separators=(",", ":")).encode("utf-8"))
            stored = deepcopy(value)
            with self._lock:
                if size <= self.max_bytes and self.max_entries > 0:
                    self._values[key] = (stored, size)
                    self._bytes += size
                    while len(self._values) > self.max_entries or self._bytes > self.max_bytes:
                        _key, (_value, removed_size) = self._values.popitem(last=False)
                        self._bytes -= removed_size
                self._pending.pop(key, None)
                future.set_result(stored)
            return value
        except BaseException as exc:
            with self._lock:
                self._pending.pop(key, None)
                future.set_exception(exc)
            raise


WEEKLY_CACHE = AnalyticsCache(max_entries=16)
REGRESSION_CACHE = AnalyticsCache(max_entries=2048, max_bytes=8 * 1024 * 1024)
SNAPSHOT_REVISIONS = SnapshotRevisions()
