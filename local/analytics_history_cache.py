"""Private, disposable historical fit storage; archive reads never depend on it."""
from __future__ import annotations

import bisect
from collections import OrderedDict
import hashlib
import json
import math
import os
from pathlib import Path
import sqlite3
import stat


FIT_CACHE_VERSION = 1  # Bump when fit implementation/serialization semantics change.


class ContentRanges:
    """Stable range fingerprints from fixed hourly blocks and exact edges.

    Hash each complete UTC-hour block once, then use an order-sensitive
    polynomial fingerprint of SHA-256 block hashes modulo 2**256 for interior
    blocks. Only the two partial edge blocks need hashing per horizon; repeated
    edges are memoized. Work is O(events + targets * events-per-hour), rather
    than O(targets * events). Full blocks and edges retain input row ordering,
    including events at equal timestamps. This is a disposable cache identity,
    never an authentication or archive integrity check.
    """
    _MASK = (1 << 256) - 1
    _BASE = 0x100000001B3
    _BLOCK = 3600

    def __init__(self, epochs, values):
        self.epochs = epochs
        self.values = list(values)
        self.blocks = []
        self.chunks = []
        self.prefix = [0]
        self.powers = [1]
        self.edges = {}
        left = 0
        while left < len(epochs):
            block = epochs[left] // self._BLOCK * self._BLOCK
            right = bisect.bisect_left(epochs, block + self._BLOCK, lo=left)
            self.blocks.append(block)
            digest = hashlib.sha256(repr(self.values[left:right]).encode()).digest()
            self.chunks.append((block, left, right, digest.hex()))
            leaf = int.from_bytes(digest, 'big')
            self.prefix.append((self.prefix[-1] * self._BASE + leaf) & self._MASK)
            self.powers.append((self.powers[-1] * self._BASE) & self._MASK)
            left = right

    def _edge(self, left, right):
        key = (left, right)
        if key not in self.edges:
            self.edges[key] = hashlib.sha256(repr(self.values[left:right]).encode()).hexdigest()
        return right-left, self.edges[key]

    def digest(self, start, end, *, inclusive_end=False):
        end += int(inclusive_end)
        left = bisect.bisect_left(self.epochs, start)
        right = bisect.bisect_left(self.epochs, end)
        full_start = -(-start // self._BLOCK) * self._BLOCK
        full_end = end // self._BLOCK * self._BLOCK
        if full_start >= full_end:
            return self._edge(left, right)
        first = bisect.bisect_left(self.blocks, full_start)
        last = bisect.bisect_left(self.blocks, full_end)
        length = last-first
        value = (self.prefix[last] - self.prefix[first] * self.powers[length]) & self._MASK
        edge_left = bisect.bisect_left(self.epochs, full_start)
        edge_right = bisect.bisect_left(self.epochs, full_end)
        return (self._edge(left, edge_left), (length, f"{value:064x}"),
                self._edge(edge_right, right))


class HistoricalFitCache:
    """Bounded SQLite sidecar in a 0700 directory, with fail-open operations.

    Each request owns its connection; independent writers coordinate through
    SQLite transactions. The process-local cache coalesces concurrent misses.
    No cache failure changes the calculation or escapes into the HTTP result.
    """
    def __init__(self, archive: Path, *, max_entries=2048, max_bytes=8 * 1024 * 1024):
        self.directory = archive.with_name('.' + archive.name + '.analytics-cache')
        self.path = self.directory / 'fits.sqlite3'
        self.max_entries = max_entries
        self.max_bytes = max_bytes
        self.connection = None
        self.disabled = False
        self._writes = OrderedDict()
        self._write_bytes = 0

    @staticmethod
    def _private(path, *, directory=False):
        info = path.lstat()
        return (info.st_uid == os.geteuid() and not info.st_mode & 0o077
                and (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)))

    def _open(self):
        if self.disabled:
            return None
        if self.connection is not None:
            return self.connection
        try:
            # Refuse redirected parents as well as redirected cache files.
            parent = self.directory.parent.lstat()
            if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.geteuid() or parent.st_mode & 0o022:
                raise OSError('unsafe cache parent')
            self.directory.mkdir(mode=0o700, exist_ok=True)
            if not self._private(self.directory, directory=True):
                raise OSError('unsafe cache directory')
            if not self.path.exists():
                fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
                os.close(fd)
            for path in (self.path, Path(str(self.path) + '-journal'),
                         Path(str(self.path) + '-wal'), Path(str(self.path) + '-shm')):
                if path.is_symlink() or (path.exists() and not self._private(path)):
                    raise OSError('unsafe cache file')
            if self.path.stat().st_size > 16 * 1024 * 1024:
                raise OSError('oversized cache file')
            connection = sqlite3.connect(self.path, timeout=0.025)
            self.connection = connection
            if connection.execute('PRAGMA page_size').fetchone()[0] != 4096:
                raise sqlite3.DatabaseError('unsupported cache page size')
            connection.execute('PRAGMA journal_mode=DELETE')
            connection.execute('PRAGMA max_page_count=4096')  # 16 MiB at the default 4 KiB page size.
            connection.execute('''CREATE TABLE IF NOT EXISTS fits (
                key TEXT PRIMARY KEY, value TEXT NOT NULL, checksum TEXT NOT NULL,
                bytes INTEGER NOT NULL, touched INTEGER NOT NULL)''')
            connection.commit()
            return connection
        except (OSError, sqlite3.Error):
            self.disabled = True
            self.close()
            return None

    @staticmethod
    def _key(key):
        return hashlib.sha256(json.dumps((FIT_CACHE_VERSION, key), separators=(",", ":")).encode()).hexdigest()

    @staticmethod
    def _valid_fit(value):
        if not isinstance(value, dict) or type(value.get('ok')) is not bool:
            return False
        numeric = ('sample_count', 'predictor_count', 'minimum_samples', 'rank',
                   'condition_number', 'rmse_fraction', 'relative_rmse',
                   'max_abs_residual_fraction', 'max_relative_coefficient_error',
                   'quantization_floor_pct_points', 'target_predicted_fraction',
                   'target_error_fraction', 'target_tolerance_fraction', 'regime_deadline')
        for field in numeric:
            if field in value and value[field] is not None and type(value[field]) not in (int, float):
                return False
        for field in ('identities', 'target_identities', 'unstable_identities'):
            if field in value and (not isinstance(value[field], list)
                                   or not all(isinstance(item, str) for item in value[field])):
                return False
        if not value['ok']:
            return isinstance(value.get('reason'), str)
        identities = value.get('identities')
        if not isinstance(identities, list) or not identities:
            return False
        for field in ('coefficients', 'coefficient_error_bounds', 'relative_coefficient_errors'):
            numbers = value.get(field)
            if not isinstance(numbers, dict) or set(numbers) != set(identities):
                return False
            if any(type(number) not in (int, float) or math.isnan(number) or number < 0
                   for number in numbers.values()):
                return False
        return (all(math.isfinite(number) and number > 0 for number in value['coefficients'].values())
                and all(field in value for field in ('sample_count', 'predictor_count',
                        'rank', 'condition_number', 'minimum_samples', 'rmse_fraction',
                        'relative_rmse', 'max_abs_residual_fraction',
                        'max_relative_coefficient_error', 'unstable_identities',
                        'quantization_floor_pct_points', 'target_predicted_fraction',
                        'target_error_fraction', 'target_tolerance_fraction')))

    def get_or_compute(self, key, compute, *, validator=None):
        digest = self._key(key)
        connection = self._open()
        if connection is not None:
            try:
                row = connection.execute('SELECT value, checksum FROM fits WHERE key=?', (digest,)).fetchone()
                if (row is not None and isinstance(row[0], str) and isinstance(row[1], str)
                        and hashlib.sha256(row[0].encode()).hexdigest() == row[1]):
                    value = json.loads(row[0])
                    if (validator or self._valid_fit)(value):
                        return value
            except (sqlite3.Error, ValueError, TypeError, UnicodeError, OverflowError, RecursionError):
                pass
        value = compute()
        if connection is not None:
            try:
                encoded = json.dumps(value, separators=(",", ":"))
                size = len(encoded.encode())
                if size <= self.max_bytes and self.max_entries > 0:
                    previous = self._writes.pop(digest, None)
                    if previous is not None:
                        self._write_bytes -= previous[2]
                    self._writes[digest] = (encoded, hashlib.sha256(encoded.encode()).hexdigest(), size)
                    self._write_bytes += size
                    while len(self._writes) > self.max_entries or self._write_bytes > self.max_bytes:
                        _key, (_value, _checksum, removed) = self._writes.popitem(last=False)
                        self._write_bytes -= removed
            except (ValueError, TypeError, UnicodeError):
                pass
        return value

    def cost_events(self, key, count, compute):
        """Reuse unaggregated priced events with exact JSON float round trips."""
        fields = ('epochs', 'costs', 'reasons', 'qualities')
        def valid(value):
            if not isinstance(value, dict) or set(value) != set(fields):
                return False
            if any(not isinstance(value[field], list) or len(value[field]) != count for field in fields):
                return False
            return (all(type(epoch) is int for epoch in value['epochs'])
                    and all(cost is None or type(cost) in (int, float) and math.isfinite(cost)
                            for cost in value['costs'])
                    and all(item is None or isinstance(item, str)
                            for field in ('reasons', 'qualities') for item in set(value[field])))
        def encoded():
            rows = compute()
            return {field: [row[index] for row in rows] for index, field in enumerate(fields)}
        # Parallel primitive arrays reduce JSON allocation; zip restores the
        # exact original tuple ordering, with no float sums or normalization.
        result = self.get_or_compute(('priced-events-v2', key), encoded, validator=valid)
        return list(zip(*(result[field] for field in fields)))

    def flush(self):
        """Commit a request's new fits together, amortizing journal/fsync work."""
        connection = self.connection
        if connection is None or not self._writes:
            return
        try:
            with connection:
                sequence = connection.execute('SELECT COALESCE(MAX(touched),0) FROM fits').fetchone()[0]
                connection.executemany('INSERT OR REPLACE INTO fits VALUES (?, ?, ?, ?, ?)',
                    ((key, value, checksum, size, sequence+index+1)
                     for index, (key, (value, checksum, size)) in enumerate(self._writes.items())))
                count, total = connection.execute('SELECT COUNT(*), COALESCE(SUM(bytes),0) FROM fits').fetchone()
                if count > self.max_entries or total > self.max_bytes:
                    for old_key, old_size in connection.execute('SELECT key, bytes FROM fits ORDER BY touched').fetchall():
                        if count <= self.max_entries and total <= self.max_bytes:
                            break
                        connection.execute('DELETE FROM fits WHERE key=?', (old_key,))
                        count -= 1
                        total -= old_size
        except (OSError, sqlite3.Error, ValueError, TypeError, UnicodeError):
            pass
        finally:
            self._writes.clear()
            self._write_bytes = 0

    def close(self):
        self.flush()
        if self.connection is not None:
            self.connection.close()
            self.connection = None
