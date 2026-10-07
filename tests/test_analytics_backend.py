#!/usr/bin/env python3
"""Behavior and invalidation checks for selective analytics and reusable work."""
import concurrent.futures
from copy import deepcopy
from contextlib import closing, contextmanager
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'local'))
import analytics
import analytics_cache
from analytics_cache import AnalyticsCache, SnapshotRevisions, archive_revision
from storage import connect_database
from storage import PUBLIC_LIMIT_ID_CONTRACT_VERSION_KEY

ROOT = Path(__file__).resolve().parents[1]


class AnalyticsBackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.db = Path(self.temp.name) / 'archive.sqlite3'
        self.pricing = Path(self.temp.name) / 'pricing.json'
        self.pricing.write_bytes((ROOT / 'local/pricing.json').read_bytes())
        self.base = 1700000000
        self.now = self.base + 86400 + 1
        with closing(connect_database(self.db)) as connection, connection:
            for index in range(3):
                at = self.base + index * 43200
                connection.execute('INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                                   (at, analytics.iso_utc(at), 80, None, None, 100-index*2,
                                    None, self.base+604800, 900, 192, 'limit-a'))
            for index in range(2):
                connection.execute('''INSERT INTO token_usage_events
                    (occurred_at_epoch, source, provider, model, input_tokens, external_id)
                    VALUES (?, 'codex', 'openai', 'gpt-5.6-sol', 300000, ?)''',
                                   (self.base+index*43200+21600, str(index)))

    def payload(self, params=None, now=None):
        return analytics.build_payload(self.db, self.pricing, params or {'range': 'all'},
                                       now=self.now if now is None else now)

    @contextmanager
    def isolated_snapshot_caches(self):
        monitor = SnapshotRevisions()
        with patch.object(analytics, 'SNAPSHOT_REVISIONS', monitor), \
             patch.object(analytics, 'WEEKLY_CACHE', AnalyticsCache()), \
             patch.object(analytics, 'REGRESSION_CACHE', AnalyticsCache()):
            try:
                yield monitor
            finally:
                for observer in monitor._observers.values():
                    observer[1].close()

    def prepare_replacement(self):
        replacement = self.db.with_name('replacement.sqlite3')
        with closing(sqlite3.connect(self.db)) as original, closing(sqlite3.connect(replacement)) as new:
            original.execute('PRAGMA journal_mode=DELETE')
            original.backup(new)
            new.execute('UPDATE token_usage_events SET input_tokens=input_tokens*3')
            new.commit()
            new.execute('PRAGMA journal_mode=DELETE')
        return replacement

    def assert_replacement_is_current_and_cached(self, raced):
        params = {'range': 'all', 'sections': 'weekly'}
        fresh = self.payload(params)
        self.assertNotEqual(raced['revision'], fresh['revision'])
        self.assertEqual(fresh['weekly_limit_value']['series'][-1]['observed_cost_usd'], 4.5)
        with patch.object(analytics, 'weekly_limit_value', side_effect=AssertionError('warm request recomputed')):
            self.assertEqual(self.payload(params), fresh)

    def test_replacement_after_open_cannot_poison_new_archive_caches(self):
        replacement = self.prepare_replacement()
        original_connect = analytics.connect_database
        def opened_then_replaced(path, **kwargs):
            connection = original_connect(path, **kwargs)
            os.replace(replacement, self.db)
            return connection
        with self.isolated_snapshot_caches():
            with patch.object(analytics, 'connect_database', side_effect=opened_then_replaced):
                old = self.payload({'range': 'all', 'sections': 'weekly'})
            self.assertEqual(old['weekly_limit_value']['series'][-1]['observed_cost_usd'], 1.5)
            self.assertFalse(analytics.WEEKLY_CACHE._values)
            self.assertFalse(analytics.REGRESSION_CACHE._values)
            self.assert_replacement_is_current_and_cached(old)

    def test_replacement_before_open_refuses_preopen_identity(self):
        replacement = self.prepare_replacement()
        original_connect = analytics.connect_database
        def replaced_then_opened(path, **kwargs):
            os.replace(replacement, self.db)
            return original_connect(path, **kwargs)
        with self.isolated_snapshot_caches():
            with patch.object(analytics, 'connect_database', side_effect=replaced_then_opened):
                raced = self.payload({'range': 'all', 'sections': 'weekly'})
            self.assertEqual(raced['weekly_limit_value']['series'][-1]['observed_cost_usd'], 4.5)
            self.assertFalse(analytics.WEEKLY_CACHE._values)
            self.assertFalse(analytics.REGRESSION_CACHE._values)
            self.assert_replacement_is_current_and_cached(raced)

    def test_replacement_during_observer_open_refuses_wrong_file_identity(self):
        replacement = self.prepare_replacement()
        original_connect = sqlite3.connect
        def observer_opened_then_replaced(*args, **kwargs):
            connection = original_connect(*args, **kwargs)
            os.replace(replacement, self.db)
            return connection
        with self.isolated_snapshot_caches() as monitor:
            with patch.object(analytics_cache.sqlite3, 'connect', side_effect=observer_opened_then_replaced):
                self.assertIsNone(monitor.observe(self.db))
            self.assertIsNotNone(monitor.observe(self.db))
            current = self.payload({'range': 'all', 'sections': 'weekly'})
            self.assertEqual(current['weekly_limit_value']['series'][-1]['observed_cost_usd'], 4.5)

    def test_migrated_snapshot_commit_before_pin_cannot_poison_current_archive(self):
        with closing(sqlite3.connect(self.db)) as writer:
            writer.execute('DELETE FROM metadata WHERE key=?', (PUBLIC_LIMIT_ID_CONTRACT_VERSION_KEY,))
            writer.commit()
            original_connect = analytics.connect_database
            def migrated_then_committed(path, **kwargs):
                connection = original_connect(path, **kwargs)
                self.assertEqual(connection.execute('PRAGMA database_list').fetchone()[2], '')
                writer.execute('UPDATE token_usage_events SET input_tokens=input_tokens*3')
                writer.commit()
                return connection
            with self.isolated_snapshot_caches():
                # Keep the file fingerprint unchanged to isolate the commit
                # publication signal from filesystem-based invalidation.
                stamp = archive_revision(self.db)
                with patch.object(analytics_cache, 'archive_revision', return_value=stamp):
                    with patch.object(analytics, 'connect_database', side_effect=migrated_then_committed):
                        old = self.payload({'range': 'all', 'sections': 'weekly'})
                    self.assertEqual(old['weekly_limit_value']['series'][-1]['observed_cost_usd'], 1.5)
                    self.assertFalse(analytics.WEEKLY_CACHE._values)
                    self.assertFalse(analytics.REGRESSION_CACHE._values)
                    self.assert_replacement_is_current_and_cached(old)

    def test_sections_match_full_and_skip_expensive_work(self):
        full = self.payload()
        with patch.object(analytics, 'weekly_limit_value', side_effect=AssertionError('weekly work')):
            with patch.object(analytics, 'weekly_reset_cycle_metrics', side_effect=AssertionError('reset work')):
                base = self.payload({'range': 'all', 'sections': 'base'})
        self.assertEqual(base['tokens'], full['tokens'])
        self.assertEqual(base['limits'], full['limits'])
        self.assertEqual(base['pending_sections'], ['weekly', 'resets'])
        self.assertNotIn('weekly_limit_value', base)
        for section, field in [('weekly', 'weekly_limit_value'), ('resets', 'resets'), ('breakdown', 'tokens')]:
            with patch.object(analytics, 'limit_series', side_effect=AssertionError('unrequested limits')):
                partial = self.payload({'range': 'all', 'sections': section})
            self.assertEqual(partial[field], full[field])
            self.assertEqual(partial['revision'], full['revision'])
            self.assertNotIn('limits', partial)

    def test_anchor_freezes_membership_and_freshness_tracks_actual_time(self):
        params = {'range': '24h', 'sections': 'weekly', 'at': str(self.now)}
        fresh = self.payload(params)
        stale = self.payload(params, now=self.now+1800)
        self.assertEqual(fresh['period'], stale['period'])
        self.assertEqual(fresh['revision'], stale['revision'])
        self.assertEqual(fresh['weekly_limit_value']['current_status'], 'available')
        self.assertEqual(stale['weekly_limit_value']['current_status'], 'stale_data')
        self.assertEqual(stale['freshness']['limits_age_seconds'], 1801)
        self.assertEqual(stale['weekly_limit_value']['series'][-1]['reason'], 'stale_data')

    def test_cache_invalidation_for_in_place_archive_and_pricing_changes(self):
        params = {'range': 'all', 'sections': 'weekly'}
        original = self.payload(params)
        original_cost = original['weekly_limit_value']['series'][-1]['observed_cost_usd']
        with closing(connect_database(self.db)) as writer, writer:
            before = archive_revision(self.db)
            writer.execute('UPDATE token_usage_events SET input_tokens = input_tokens * 2')
            writer.commit()
            self.assertNotEqual(before, archive_revision(self.db))
            changed = self.payload(params)
        self.assertNotEqual(original['revision'], changed['revision'])
        self.assertEqual(changed['weekly_limit_value']['series'][-1]['observed_cost_usd'], original_cost*2)
        catalog = json.loads(self.pricing.read_text())
        for entry in catalog['entries']:
            for period in entry.get('periods', [entry]):
                period['input_per_million'] *= 2
        self.pricing.write_text(json.dumps(catalog))
        repriced = self.payload(params)
        self.assertNotEqual(changed['revision'], repriced['revision'])
        self.assertEqual(repriced['weekly_limit_value']['series'][-1]['observed_cost_usd'], original_cost*4)

    def test_caches_do_not_share_mutable_payloads(self):
        params = {'range': 'all', 'sections': 'weekly'}
        first = self.payload(params)
        original = deepcopy(first)
        first['weekly_limit_value']['series'].clear()
        self.assertEqual(self.payload(params), original)

    def test_causal_regression_reused_for_moving_display_windows(self):
        with closing(connect_database(self.db)) as connection, connection:
            connection.execute('DELETE FROM snapshots')
            connection.execute('DELETE FROM token_usage_events')
            for index in range(128):
                at = self.base+index*900
                connection.execute('INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                                   (at, analytics.iso_utc(at), 80, None, None, 100-index*0.5,
                                    None, self.base+604800, 900, 192, 'limit-a'))
                for model in ['gpt-5.6-sol', 'gpt-5.6-terra']:
                    connection.execute('''INSERT INTO token_usage_events
                        (occurred_at_epoch, source, provider, model, input_tokens, external_id)
                        VALUES (?, 'codex', 'openai', ?, ?, ?)''',
                                       (at-450, model, 100000+index%3*10000, f'{index}/{model}'))
        now = self.base+127*900+1
        with patch.object(analytics, '_mixed_training_fit', wraps=analytics._mixed_training_fit) as fits:
            self.payload({'range': '24h', 'sections': 'weekly'}, now=now)
            first_calls = fits.call_count
            self.assertGreater(first_calls, 0)
            self.payload({'range': '24h', 'sections': 'weekly'}, now=now+1)
            self.assertEqual(fits.call_count, first_calls)

    def test_snapshot_publication_race_is_not_cached_even_if_file_stamp_matches(self):
        monitor = SnapshotRevisions()
        self.addCleanup(lambda: [value[1].close() for value in monitor._observers.values()])
        with closing(connect_database(self.db)) as writer, writer:
            expected = monitor.observe(self.db)
            self.assertIsNotNone(expected)
            with closing(connect_database(self.db, read_only=True)) as reader:
                class RacingRead:
                    def execute(inner, query):
                        result = reader.execute(query)
                        if query.startswith('SELECT'):
                            writer.execute('UPDATE token_usage_events SET input_tokens=input_tokens+1')
                            writer.commit()
                        return result
                stamp = archive_revision(self.db)
                with patch.object(analytics_cache, 'archive_revision', return_value=stamp):
                    self.assertEqual(monitor.observe(self.db), expected)
                    self.assertIsNone(monitor.pin(RacingRead(), self.db, expected=expected))
            # Prove an unchanged observation can name a snapshot, so the
            # racing assertion does not pass merely by disabling all caching.
            expected = monitor.observe(self.db)
            with closing(connect_database(self.db, read_only=True)) as reader:
                self.assertEqual(monitor.pin(reader, self.db, expected=expected), expected)

    def test_unobserved_open_connection_reads_without_cache_identity(self):
        with self.isolated_snapshot_caches() as monitor:
            with closing(connect_database(self.db, read_only=True)) as reader:
                self.assertIsNone(monitor.pin(reader, self.db, expected=None))
                self.assertTrue(reader.in_transaction)
                self.assertEqual(reader.execute('SELECT COUNT(*) FROM snapshots').fetchone()[0], 3)

    def test_evicted_preopen_observer_does_not_name_snapshot(self):
        other = self.db.with_name('other.sqlite3')
        with closing(connect_database(other)):
            pass
        monitor = SnapshotRevisions(max_archives=1)
        self.addCleanup(lambda: [value[1].close() for value in monitor._observers.values()])
        expected = monitor.observe(self.db)
        self.assertIsNotNone(expected)
        with closing(connect_database(self.db, read_only=True)) as reader:
            self.assertIsNotNone(monitor.observe(other))
            self.assertIsNone(monitor.pin(reader, self.db, expected=expected))

    def test_timezone_dst_and_previous_comparison(self):
        result = self.payload({'from_date': '2026-03-08', 'to_date': '2026-03-08',
                               'timezone': 'America/New_York', 'sections': 'base'})
        self.assertEqual(result['period']['from'], '2026-03-08T05:00:00Z')
        self.assertEqual(result['period']['to'], '2026-03-09T04:00:00Z')
        result = self.payload({'range': '24h', 'sections': 'base', 'compare': 'previous', 'source': 'codex'}, now=self.base+129600+1)
        self.assertEqual(result['comparison']['period']['to'], result['period']['from'])
        self.assertEqual(result['comparison']['tokens']['summary']['input_tokens'], 300000)

    def test_invalid_parameters(self):
        for params in [{'sections': 'bad'}, {'compare': 'bad'}, {'timezone': 'Nowhere/Invalid'},
                       {'timezone': '/etc/passwd'}, {'at': '0'}, {'at': '1.2'}, {'at': str(self.now+1)}]:
            with self.subTest(params=params), self.assertRaises(analytics.AnalyticsError):
                self.payload(params)

    def test_unit_projection_preserves_sensitivity_bounds(self):
        samples = [{'fraction': 0.01*(index+1)+0.02*(index%3+1),
                    'costs': {'a': float(index+1), 'b': float(index%3+1)}} for index in range(12)]
        fit = analytics._fit_mixed_regression(samples, {'a', 'b'})
        self.assertTrue(fit['ok'])
        matrix = [[sample['costs'][identity] for identity in ['a', 'b']] for sample in samples]
        _rank, _condition, q, r = analytics._mixed_matrix_rank_and_qr(matrix)
        for column, identity in enumerate(['a', 'b']):
            scale = sum(row[column]**2 for row in matrix)**0.5
            sensitivity = 0.0
            for index in range(len(samples)):
                unit = [0.0]*len(samples)
                unit[index] = 1.0
                influence = analytics._mixed_qr_solve(q, r, unit)
                sensitivity += abs(influence[column]/scale)
            self.assertEqual(fit['coefficient_error_bounds'][identity], sensitivity*0.01)


class CacheTests(unittest.TestCase):
    def test_coalescing_and_detached_results(self):
        cache = AnalyticsCache()
        started, release = threading.Event(), threading.Event()
        calls = []
        def compute():
            calls.append(1)
            started.set()
            self.assertTrue(release.wait(5))
            return {'values': [1]}
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            first = executor.submit(cache.get_or_compute, ('key',), compute)
            self.assertTrue(started.wait(5))
            others = [executor.submit(cache.get_or_compute, ('key',), compute) for _ in range(7)]
            release.set()
            results = [future.result(5) for future in [first, *others]]
        self.assertEqual(len(calls), 1)
        results[0]['values'].clear()
        self.assertEqual(cache.get_or_compute(('key',), compute), {'values': [1]})

    def test_limits_eviction_and_failed_computation_retry(self):
        cache = AnalyticsCache(max_entries=1, max_bytes=100)
        calls = []
        def compute():
            calls.append(1)
            return {'value': len(calls)}
        cache.get_or_compute(('a',), compute)
        cache.get_or_compute(('b',), compute)
        cache.get_or_compute(('a',), compute)
        self.assertEqual(len(calls), 3)
        cache.get_or_compute(('large',), lambda: {'value': 'x'*200})
        self.assertNotIn(('large',), cache._values)
        with self.assertRaises(ValueError):
            cache.get_or_compute(('fail',), lambda: (_ for _ in ()).throw(ValueError('failed')))
        self.assertEqual(cache.get_or_compute(('fail',), lambda: 42), 42)


if __name__ == '__main__':
    unittest.main()
