"""Account reset-credit collection, publication, and historical semantics."""
from contextlib import closing
import csv
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'local'))
import analytics
import analytics_export
import archive
import codex_client
import history
import storage


class ResetCreditTests(unittest.TestCase):
    def summary(self, count, credits=None):
        return codex_client.reset_credits_summary({'rateLimitResetCredits': {'availableCount': count, 'credits': credits}})

    def credit(self, id, expiration):
        return {'id': id, 'status': 'available', 'expiresAt': expiration, 'title': 'private title'}

    def test_count_is_authoritative_and_shortest_expiration_is_selected(self):
        summary = self.summary(3, [self.credit('secret-a', 2000), self.credit('secret-b', None), self.credit('secret-c', 1000)])
        self.assertEqual({'available_count': 3, 'next_expiration_at': 1000, 'expiration_known': True}, summary)
        result = json.loads((ROOT / 'tests/fixtures/codex/multi-id.json').read_text())
        result['rateLimitResetCredits'] = {'availableCount': 3, 'credits': [self.credit('secret-a', 2000), self.credit('secret-b', None), self.credit('secret-c', 1000)]}
        snapshot = codex_client.build_snapshot(result, sample_interval_seconds=900, history_window_hours=192)
        self.assertEqual(summary, snapshot['reset_credits'])
        self.assertNotIn('secret-', json.dumps(history.validate_snapshot(snapshot)))
        self.assertNotIn('private title', json.dumps(snapshot))

    def test_absent_invalid_and_partial_data_remain_unknown(self):
        self.assertIsNone(codex_client.reset_credits_summary({}))
        for count in (-1, True, 1.5, '2', 1 << 63):
            with self.subTest(count=count):
                self.assertIsNone(self.summary(count))
        for credits in (None, [], [self.credit('a', 1000)],
                        [self.credit('a', 1000), self.credit('a', 1000)],
                        [self.credit('a', 1000), self.credit('b', False)],
                        [self.credit('a', 1000), {'id': 'b', 'status': 'redeemed', 'expiresAt': 2000}],
                        [self.credit('a', 1000), {'id': 'b', 'status': 'available'}]):
            with self.subTest(credits=credits):
                self.assertEqual({'available_count': 2, 'next_expiration_at': None, 'expiration_known': False}, self.summary(2, credits))

    def test_zero_and_non_expiring_credits_are_distinct(self):
        self.assertEqual({'available_count': 0, 'next_expiration_at': None, 'expiration_known': True}, self.summary(0))
        self.assertEqual({'available_count': 1, 'next_expiration_at': None, 'expiration_known': True}, self.summary(1, [self.credit('a', None)]))
        self.assertEqual({'available_count': 1, 'next_expiration_at': None, 'expiration_known': False}, history.sanitize_reset_credits({'available_count': 1, 'next_expiration_at': 'unsafe', 'expiration_known': True}))

    def test_history_archive_range_filters_and_csv_keep_observed_values(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'archive.sqlite3'
            base = 1700000123  # Not bucket aligned: remaining duration uses the observation.
            with closing(storage.connect_database(path)) as connection, connection:
                for offset, credits in ((0, self.summary(2, [self.credit('a', base + 3600), self.credit('b', None)])),
                                        (7200, self.summary(0)), (14400, None)):
                    public = history.validate_snapshot({'five_h_pct': 80, 'scraped_at': analytics.iso_utc(base + offset), 'reset_credits': credits})
                    normalized = archive.normalize_snapshot(public, strict=True)
                    archive.insert_snapshot(connection, normalized)
                connection.row_factory = sqlite3.Row
                result = analytics.limit_series(connection, base, base + 7200, 3600)
                first = result['series'][0]
                self.assertEqual(2, first['reset_credits_available'])
                self.assertEqual(3600, first['reset_credits_expiration_seconds'])
                self.assertEqual(analytics.iso_utc(base), first['reset_credits_observed_at'])
                # Current uses the newest snapshot, even outside the displayed period.
                self.assertIsNone(result['reset_credits_current']['available_count'])
                result = analytics.limit_series(connection, base + 7200, base + 14401, 3600)
                self.assertEqual(0, result['series'][0]['reset_credits_available'])
                self.assertIsNone(result['series'][1]['reset_credits_available'])
            body = analytics_export.build_csv(path, ROOT / 'local/pricing.json', {'range': 'all', 'sources': 'hermes', 'models': 'unrelated'}, 'limits', now=base + 14401)
            rows = list(csv.DictReader(io.StringIO(body.decode('utf-8-sig'))))
            self.assertEqual('2', rows[0]['reset_credits_available'])
            self.assertEqual('3600', rows[0]['reset_credits_expiration_seconds'])
            self.assertEqual('0', rows[1]['reset_credits_available'])
            self.assertEqual('', rows[2]['reset_credits_available'])
            with closing(storage.connect_database(path)) as connection, connection:
                # Replacing a timestamp with missing details must clear the previous summary.
                public = {'five_h_pct': 80, 'scraped_at': analytics.iso_utc(base)}
                archive.insert_snapshot(connection, archive.normalize_snapshot(public, strict=True))
                self.assertEqual(1, connection.execute('SELECT COUNT(*) FROM reset_credit_snapshots').fetchone()[0])
                # Credit rows follow the same retention/compaction as quota snapshots.
                public = {'five_h_pct': 80, 'scraped_at': analytics.iso_utc(base + 8 * 86400),
                          'reset_credits': self.summary(1, [self.credit('new', None)])}
                archive.insert_snapshot(connection, archive.normalize_snapshot(public, strict=True))
                archive.compact(connection, retention_days=1)
                self.assertEqual(1, connection.execute('SELECT COUNT(*) FROM reset_credit_snapshots').fetchone()[0])
                self.assertEqual(1, connection.execute('SELECT COUNT(*) FROM snapshots').fetchone()[0])
                connection.execute('DELETE FROM snapshots')
                self.assertEqual(0, connection.execute('SELECT COUNT(*) FROM reset_credit_snapshots').fetchone()[0])

    def test_v4_migration_preserves_rows_and_backs_up_before_adding_table(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'archive.sqlite3'
            with sqlite3.connect(path) as connection:
                for statement in storage._V4_SCHEMA_STATEMENTS:
                    connection.execute(statement)
                connection.execute('PRAGMA user_version = 4')
                connection.execute("INSERT INTO metadata VALUES ('schema_version', '4')")
                connection.execute("INSERT INTO snapshots (scraped_at_epoch, scraped_at, five_h_pct) VALUES (1000, '1970-01-01T00:16:40Z', 80)")
            with closing(storage.connect_database(path)) as connection:
                self.assertEqual(5, connection.execute('PRAGMA user_version').fetchone()[0])
                self.assertEqual(1, connection.execute('SELECT COUNT(*) FROM snapshots').fetchone()[0])
                self.assertEqual(0, connection.execute('SELECT COUNT(*) FROM reset_credit_snapshots').fetchone()[0])
            backups = list(path.parent.glob('archive.sqlite3.pre-migration.*'))
            self.assertEqual(1, len(backups))
            with sqlite3.connect(backups[0]) as connection:
                self.assertEqual(4, connection.execute('PRAGMA user_version').fetchone()[0])


if __name__ == '__main__':
    unittest.main()
