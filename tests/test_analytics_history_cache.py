"""Persistent historical reuse must preserve exact estimator evidence and outputs."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing, contextmanager
import json
import hashlib
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'local'))
import analytics
from analytics_cache import AnalyticsCache, SnapshotRevisions
from analytics_history_cache import ContentRanges, HistoricalFitCache
from storage import connect_database


class HistoricalAnalyticsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.database = Path(self.temp.name) / 'archive.sqlite3'
        self.pricing = Path(self.temp.name) / 'pricing.json'
        self.pricing.write_bytes((ROOT / 'local/pricing.json').read_bytes())
        self.base = 1700000000
        self.now = self.base + 127 * 900 + 1
        self.params = {'range': '24h', 'sections': 'weekly', 'at': str(self.now)}
        with closing(connect_database(self.database)) as writer, writer:
            for index in range(128):
                at = self.base + index * 900
                writer.execute('INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                    (at, analytics.iso_utc(at), 80, None, None, 100-index*0.5, None,
                     self.base+604800, 900, 192, 'limit-a'))
                for model in ('gpt-5.6-sol', 'gpt-5.6-terra'):
                    writer.execute('''INSERT INTO token_usage_events
                        (occurred_at_epoch, source, provider, model, input_tokens, external_id)
                        VALUES (?, 'codex', 'openai', ?, ?, ?)''',
                        (at-450, model, 100000+index%3*10000, f'{index}/{model}'))

    @contextmanager
    def fresh_caches(self):
        monitor = SnapshotRevisions()
        with patch.object(analytics, 'WEEKLY_CACHE', AnalyticsCache()), \
             patch.object(analytics, 'REGRESSION_CACHE', AnalyticsCache()), \
             patch.object(analytics, 'SNAPSHOT_REVISIONS', monitor):
            try:
                yield
            finally:
                for observer in monitor._observers.values():
                    observer[1].close()

    def payload(self):
        return analytics.build_payload(self.database, self.pricing, self.params, now=self.now)

    def uncached(self):
        with self.fresh_caches(), patch.object(analytics, 'HistoricalFitCache', return_value=None):
            return self.payload()

    def warm(self):
        with self.fresh_caches(), patch.object(analytics, '_mixed_training_fit', wraps=analytics._mixed_training_fit) as fit:
            value = self.payload()
            self.assertGreater(fit.call_count, 0)
            return value

    def assert_equal_except_revision(self, left, right):
        left, right = dict(left), dict(right)
        left.pop('revision')
        right.pop('revision')
        self.assertEqual(left, right)

    def test_append_outside_causal_horizon_and_fresh_process_reuse(self):
        original = self.warm()
        with closing(connect_database(self.database)) as writer, writer:
            writer.execute('''INSERT INTO token_usage_events
                (occurred_at_epoch, source, provider, model, input_tokens, external_id)
                VALUES (?, 'codex', 'openai', 'gpt-5.6-sol', 12345, 'append')''', (self.now-1,))
            writer.execute('''INSERT INTO snapshots SELECT scraped_at_epoch+900, scraped_at,
                five_h_pct, five_h_reset, five_h_reset_at, weekly_pct, weekly_reset, weekly_reset_at,
                sample_interval_seconds, history_window_hours, limit_id FROM snapshots
                WHERE scraped_at_epoch=?''', (self.now-1,))
        with self.fresh_caches(), patch.object(analytics, '_mixed_training_fit', side_effect=AssertionError('historical recomputation')), \
             patch.object(analytics, '_event_cost', wraps=analytics._event_cost) as prices:
            appended = self.payload()
            self.assertLessEqual(prices.call_count,16)
        self.assertNotEqual(original['revision'], appended['revision'])
        self.assert_equal_except_revision(appended, self.uncached())
        script = '''import json, sys
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, sys.argv[1])
import analytics
with patch.object(analytics, '_mixed_training_fit', side_effect=AssertionError('restart recomputation')), \\
     patch.object(analytics, '_event_cost', side_effect=AssertionError('restart repricing')):
    result = analytics.build_payload(Path(sys.argv[2]), Path(sys.argv[3]), json.loads(sys.argv[4]), now=int(sys.argv[5]))
print(json.dumps(result))
'''
        process = subprocess.run([sys.executable, '-c', script, str(ROOT/'local'), str(self.database),
            str(self.pricing), json.dumps(self.params), str(self.now)], capture_output=True, text=True, check=True)
        self.assert_equal_except_revision(json.loads(process.stdout), appended)

    def test_affected_inputs_invalidate_and_equal_uncached(self):
        changes = (
            "UPDATE token_usage_events SET input_tokens=input_tokens*2 WHERE occurred_at_epoch < %d" % (self.base+4500),
            "DELETE FROM token_usage_events WHERE occurred_at_epoch < %d" % (self.base+4500),
            "INSERT INTO token_usage_events (occurred_at_epoch,source,provider,model,input_tokens,external_id) VALUES (%d,'codex','openai','gpt-5.6-sol',750000,'backfill')" % (self.base+100),
            "UPDATE token_usage_events SET source='hermes', quality='polled_delta', reasoning_tokens=12 WHERE occurred_at_epoch < %d" % (self.base+4500),
            "UPDATE token_usage_events SET cache_read_tokens=1234,output_tokens=4321 WHERE occurred_at_epoch=%d" % (self.base+4950),
            "INSERT INTO token_usage_events (occurred_at_epoch,source,provider,model,input_tokens,external_id) VALUES (%d,'codex','openai','gpt-5.6-terra',1234,'same-epoch')" % (self.base+4950),
            "UPDATE snapshots SET weekly_pct=weekly_pct-0.1 WHERE scraped_at_epoch=%d" % (self.base+4500),
            "UPDATE snapshots SET weekly_reset_at=weekly_reset_at+3600 WHERE scraped_at_epoch=%d" % (self.base+4500),
            "UPDATE snapshots SET limit_id='limit-b' WHERE scraped_at_epoch=%d" % (self.base+4500),
            "INSERT INTO reset_events VALUES ('weekly',%d,%d,90,100,'scheduled_crossing')" % (self.base+4500,self.base+4500),
        )
        self.warm()
        for query in changes:
            with self.subTest(query=query):
                with closing(connect_database(self.database)) as writer, writer:
                    writer.execute(query)
                with self.fresh_caches(), patch.object(analytics, '_mixed_training_fit', wraps=analytics._mixed_training_fit) as fit:
                    changed = self.payload()
                    self.assertGreater(fit.call_count, 0)
                self.assert_equal_except_revision(changed, self.uncached())

    def test_price_and_policy_invalidate(self):
        self.warm()
        catalog = json.loads(self.pricing.read_text())
        for entry in catalog['entries']:
            for period in entry.get('periods', [entry]):
                period['input_per_million'] *= 2
        self.pricing.write_text(json.dumps(catalog))
        with self.fresh_caches(), patch.object(analytics, '_mixed_training_fit', wraps=analytics._mixed_training_fit) as fit:
            priced = self.payload()
            self.assertGreater(fit.call_count, 0)
        self.assert_equal_except_revision(priced, self.uncached())
        with patch.object(analytics, 'WEEKLY_VALUE_MIXED_MIN_SAMPLES', 9):
            with self.fresh_caches(), patch.object(analytics, '_mixed_training_fit', wraps=analytics._mixed_training_fit) as fit:
                policy = self.payload()
                self.assertGreater(fit.call_count, 0)
            self.assert_equal_except_revision(policy, self.uncached())

    def test_replaced_archive_cannot_reuse_changed_evidence(self):
        self.warm()
        replacement = self.database.with_name('replacement.sqlite3')
        with closing(sqlite3.connect(self.database)) as original, closing(sqlite3.connect(replacement)) as new:
            original.backup(new)
            new.execute('UPDATE token_usage_events SET input_tokens=input_tokens*3')
            new.commit()
        os.replace(replacement, self.database)
        with self.fresh_caches(), patch.object(analytics, '_mixed_training_fit', wraps=analytics._mixed_training_fit) as fit:
            changed = self.payload()
            self.assertGreater(fit.call_count, 0)
        self.assert_equal_except_revision(changed, self.uncached())

    def test_ranges_filters_and_partial_hour_blocks_equal_uncached(self):
        self.warm()
        for selected_range in ('24h','7d','30d','all'):
            for source in ('codex','hermes'):
                with self.subTest(range=selected_range,source=source):
                    self.params = {'range':selected_range,'sections':'weekly','at':str(self.now-137),
                                   'sources':source,'models':'gpt-5.6-sol'}
                    with self.fresh_caches():
                        cached = self.payload()
                    self.assert_equal_except_revision(cached,self.uncached())


class FitStorageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.archive = Path(self.temp.name)/'archive.sqlite3'

    def test_content_slices_are_stable_and_order_sensitive(self):
        small = ContentRanges([2, 2, 3], [(2,'a'), (2,'b'), (3,'c')])
        large = ContentRanges([1, 2, 2, 3, 4], [(1,'z'), (2,'a'), (2,'b'), (3,'c'), (4,'x')])
        self.assertEqual(small.digest(2,3), large.digest(2,3))
        self.assertNotEqual(small.digest(2,3), ContentRanges([2,2],[(2,'b'),(2,'a')]).digest(2,3))
        self.assertNotEqual(small.digest(2,3), small.digest(2,3,inclusive_end=True))
        small = ContentRanges([3601,3601,7202], [(3601,'a'),(3601,'b'),(7202,'c')])
        large = ContentRanges([0,3601,3601,7202,10805],
                             [(0,'z'),(3601,'a'),(3601,'b'),(7202,'c'),(10805,'x')])
        self.assertEqual(small.digest(3500,10800),large.digest(3500,10800))
        self.assertEqual(small.digest(3601,7202,inclusive_end=True),large.digest(3601,7202,inclusive_end=True))

    def test_persistence_corruption_permissions_and_bounds(self):
        cache = HistoricalFitCache(self.archive, max_entries=2, max_bytes=250)
        self.addCleanup(cache.close)
        for index in range(6):
            self.assertEqual(cache.get_or_compute((index,), lambda: {'ok':False,'reason':'cached','x':'x'*40}), {'ok':False,'reason':'cached','x':'x'*40})
        cache.flush()
        count, size = cache.connection.execute('SELECT COUNT(*),SUM(bytes) FROM fits').fetchone()
        self.assertLessEqual(count,2)
        self.assertLessEqual(size,250)
        self.assertEqual(cache.directory.stat().st_mode & 0o777,0o700)
        self.assertEqual(cache.path.stat().st_mode & 0o777,0o600)
        cache.close()
        again = HistoricalFitCache(self.archive)
        self.addCleanup(again.close)
        self.assertEqual(again.get_or_compute((5,),lambda: self.fail('disk hit missed'))['reason'],'cached')
        again.connection.execute("UPDATE fits SET value='broken'")
        again.connection.commit()
        self.assertEqual(again.get_or_compute((5,),lambda:{'ok':False,'reason':'new'}),{'ok':False,'reason':'new'})
        malformed = json.dumps({'ok':True,'identities':['x'],'coefficients':[]})
        again.connection.execute('UPDATE fits SET value=?,checksum=?',
            (malformed,hashlib.sha256(malformed.encode()).hexdigest()))
        again.connection.commit()
        self.assertEqual(again.get_or_compute((5,),lambda:{'ok':False,'reason':'schema'}),{'ok':False,'reason':'schema'})
        again.close()
        cache.path.write_bytes(b'corrupt SQLite')
        broken = HistoricalFitCache(self.archive)
        self.addCleanup(broken.close)
        self.assertEqual(broken.get_or_compute((5,),lambda:{'ok':False}),{'ok':False})

    def test_concurrent_misses_are_coalesced_and_process_writers_safe(self):
        memory = AnalyticsCache()
        calls = []
        def request():
            cache = HistoricalFitCache(self.archive)
            try:
                return memory.get_or_compute(('same',),lambda:cache.get_or_compute(('same',),lambda:calls.append(1) or {'ok':False,'reason':'cached'}))
            finally:
                cache.close()
        with ThreadPoolExecutor(max_workers=8) as executor:
            self.assertEqual(list(executor.map(lambda _:request(),range(16))),[{'ok':False,'reason':'cached'}]*16)
        self.assertEqual(len(calls),1)
        def independent(index):
            cache = HistoricalFitCache(self.archive,max_entries=4,max_bytes=1024)
            try:
                return cache.get_or_compute((index,),lambda:{'ok':False,'reason':'cached'})
            finally:
                cache.close()
        with ThreadPoolExecutor(max_workers=8) as executor:
            self.assertEqual(list(executor.map(independent,range(16))),[{'ok':False,'reason':'cached'}]*16)
        with closing(sqlite3.connect(HistoricalFitCache(self.archive).path)) as connection:
            self.assertLessEqual(connection.execute('SELECT COUNT(*) FROM fits').fetchone()[0],4)

    def test_lock_and_symlinks_fail_open(self):
        cache = HistoricalFitCache(self.archive)
        cache.get_or_compute(('a',),lambda:{'ok':False,'reason':'cached'})
        cache.close()
        with closing(sqlite3.connect(cache.path)) as lock:
            lock.execute('BEGIN EXCLUSIVE')
            busy = HistoricalFitCache(self.archive)
            self.addCleanup(busy.close)
            self.assertEqual(busy.get_or_compute(('a',),lambda:{'ok':False}),{'ok':False})
        cache.path.unlink()
        target = Path(self.temp.name)/'untouched'
        target.write_text('untouched')
        cache.path.symlink_to(target)
        redirected = HistoricalFitCache(self.archive)
        self.assertEqual(redirected.get_or_compute(('a',),lambda:{'ok':False}),{'ok':False})
        self.assertEqual(target.read_text(),'untouched')
        cache.path.unlink()
        cache.directory.rmdir()
        cache.directory.symlink_to(Path(self.temp.name),target_is_directory=True)
        directory = HistoricalFitCache(self.archive)
        self.assertEqual(directory.get_or_compute(('a',),lambda:{'ok':False}),{'ok':False})
        self.assertFalse((Path(self.temp.name)/'fits.sqlite3').exists())

    def test_missing_read_only_and_insecure_directories_fail_open(self):
        missing = HistoricalFitCache(Path(self.temp.name)/'missing'/'archive.sqlite3')
        self.assertEqual(missing.get_or_compute(('a',),lambda:{'ok':False,'reason':'computed'}),
                         {'ok':False,'reason':'computed'})
        denied = HistoricalFitCache(self.archive)
        with patch('analytics_history_cache.os.open',side_effect=PermissionError('read only')):
            self.assertEqual(denied.get_or_compute(('a',),lambda:{'ok':False,'reason':'computed'}),
                             {'ok':False,'reason':'computed'})
        denied.directory.chmod(0o755)
        insecure = HistoricalFitCache(self.archive)
        self.assertEqual(insecure.get_or_compute(('a',),lambda:{'ok':False,'reason':'computed'}),
                         {'ok':False,'reason':'computed'})
        self.assertFalse(insecure.path.exists())


if __name__ == '__main__':
    unittest.main()
