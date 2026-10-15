import csv
import io
import pathlib
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "local"))
import analytics
import analytics_export
from storage import connect_database
from analytics import AnalyticsError
from analytics_export import build_csv, safe_cell


class AnalyticsExportTests(unittest.TestCase):
    def test_export_removes_pagination_and_preserves_full_precision_and_filters(self):
        payload = {"tokens": {"breakdown": [{"model": "=SUM(1,2)", "provider": "test", "source": "codex", "input_tokens": 123456789, "estimated_cost_usd": 0.12345678}], "breakdown_pagination": {"total": 1, "offset": 0}}}
        with patch("analytics_export.read_snapshot") as snapshot:
            build = snapshot.return_value.__enter__.return_value
            build.return_value = payload
            body = build_csv(pathlib.Path("db"), pathlib.Path("prices"), {"range": "7d", "models": "=SUM(1,2)", "breakdown_offset": "50"}, "breakdown", now=2000)
        query = build.call_args.args[0]
        self.assertEqual("0", query["breakdown_offset"])
        self.assertEqual(query["models"], "=SUM(1,2)")
        row = next(csv.DictReader(io.StringIO(body.decode("utf-8-sig"))))
        self.assertEqual(row["model"], "'=SUM(1,2)")
        self.assertEqual(row["input_tokens"], "123456789")
        self.assertEqual(row["estimated_cost_usd"], "0.12345678")

    def test_limits_and_per_source_tokens_keep_units_and_unknown_values(self):
        fixtures = [("limits", {"limits": {"series": [{"at": "UTC", "weekly_pct": None, "five_h_pct": 99.125}]}}), ("tokens", {"tokens": {"series": [], "series_by_source": [{"at": "UTC", "source": "hermes", "total_tokens": 5, "estimated_cost_usd": 1.25}]}})]
        for dataset, payload in fixtures:
            with self.subTest(dataset=dataset), patch("analytics_export.build_payload", return_value=payload):
                rows = list(csv.DictReader(io.StringIO(build_csv(pathlib.Path("db"), pathlib.Path("prices"), {}, dataset, now=2000).decode("utf-8-sig"))))
                self.assertEqual(rows[0]["at"], "UTC")
                if dataset == "limits":
                    self.assertEqual(rows[0]["weekly_pct"], "")
                    self.assertEqual(rows[0]["five_h_pct"], "99.125")
                else:
                    self.assertEqual(rows[0]["source"], "hermes")
                    self.assertEqual(rows[0]["estimated_cost_usd"], "1.25")

    def test_weekly_export_includes_unavailable_and_carried_model_points(self):
        payload = {"weekly_limit_value": {"series": [{"at": "UTC", "value_usd": None, "reason": "missing_price"}], "by_model": [{"model": "gpt-6.1-sol", "providers": ["openai"], "series": [{"at": "UTC", "carried": True, "source_at": "earlier", "value_usd": 12.3456789, "value_upper_usd": None}]}]}}
        with patch("analytics_export.build_payload", return_value=payload):
            rows = list(csv.DictReader(io.StringIO(build_csv(pathlib.Path("db"), pathlib.Path("prices"), {}, "weekly_value", now=2000).decode("utf-8-sig"))))
        self.assertEqual(rows[0]["reason"], "missing_price")
        self.assertEqual(rows[1]["source_at"], "earlier")
        self.assertEqual(rows[1]["value_usd"], "12.3456789")

    def test_bounds_and_invalid_dataset_fail_explicitly(self):
        with self.assertRaises(AnalyticsError):
            build_csv(pathlib.Path("db"), pathlib.Path("prices"), {}, "secret")
        with patch("analytics_export.read_snapshot") as snapshot:
            snapshot.return_value.__enter__.return_value.return_value = {
                "tokens": {"breakdown": [], "breakdown_pagination": {"total": 10001, "offset": 0}}}
            with self.assertRaises(AnalyticsError):
                build_csv(pathlib.Path("db"), pathlib.Path("prices"), {}, "breakdown")

    def test_formula_neutralization_does_not_alter_numbers(self):
        for value in ["=1", "+1", "-1", "@test", "\t=cmd", "  +cmd"]:
            self.assertEqual(safe_cell(value), "'" + value)
        self.assertEqual(safe_cell(-12.5), -12.5)
        self.assertEqual(safe_cell("ordinary"), "ordinary")


class ResetExportSnapshotTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.database = pathlib.Path(temporary.name) / "archive.sqlite3"
        self.pricing = ROOT / "local/pricing.json"
        self.base = 1_700_000_000
        self.now = self.base + 300 * 900
        self.writer = connect_database(self.database)
        self.addCleanup(self.writer.close)
        with self.writer:
            self.writer.executemany("INSERT INTO reset_events VALUES (?, ?, ?, ?, ?, ?)", [
                ("5h", self.base + index * 900, self.base + index * 900, 20, 100, "scheduled_crossing")
                for index in range(205)
            ])

    def export(self):
        body = build_csv(self.database, self.pricing,
                         {"range": "all", "reset_type": "5h", "reset_offset": "50"},
                         "resets", now=self.now)
        return list(csv.DictReader(io.StringIO(body.decode("utf-8-sig"))))

    def assert_complete_snapshot(self, rows):
        self.assertEqual(len(rows), 205)
        self.assertEqual([row["reset_at"] for row in rows], [
            analytics.iso_utc(self.base + index * 900) for index in reversed(range(205))
        ])
        self.assertEqual({row["before_pct"] for row in rows}, {"20.0"})

    def test_all_pages_ignore_display_offset_and_preserve_the_snapshot(self):
        self.assert_complete_snapshot(self.export())

    def test_observer_failure_does_not_prevent_a_complete_export(self):
        with patch.object(analytics.SNAPSHOT_REVISIONS, "_read_observation_locked",
                          side_effect=sqlite3.OperationalError("disk I/O error")):
            self.assert_complete_snapshot(self.export())

    def test_concurrent_collection_cannot_change_later_export_pages(self):
        original = analytics.reset_history
        pages = []

        def read_then_collect(*args, **kwargs):
            result = original(*args, **kwargs)
            pages.append(result["offset"])
            if len(pages) == 1:
                with self.writer:
                    self.writer.execute("DELETE FROM reset_events WHERE reset_at_epoch=?", (self.base,))
                    self.writer.execute("UPDATE reset_events SET before_pct=80")
                    self.writer.execute("INSERT INTO reset_events VALUES (?, ?, ?, ?, ?, ?)",
                        ("5h", self.now - 1, self.now - 1, 80, 100, "scheduled_crossing"))
            return result

        with patch.object(analytics, "reset_history", side_effect=read_then_collect):
            self.assert_complete_snapshot(self.export())
        self.assertEqual(pages, [0, 100, 200])
        fresh = self.export()
        self.assertEqual(fresh[0]["reset_at"], analytics.iso_utc(self.now - 1))
        self.assertEqual({row["before_pct"] for row in fresh}, {"80.0"})

    def test_export_limit_still_rejects_oversized_snapshots(self):
        with patch.object(analytics_export, "MAX_EXPORT_ROWS", 200):
            with self.assertRaisesRegex(AnalyticsError, "exceeds 200 rows"):
                self.export()


class LargeAllocationExportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.database = pathlib.Path(temporary.name) / "archive.sqlite3"
        self.pricing = ROOT / "local/pricing.json"
        self.base = 1_700_000_000
        self.now = self.base + 100
        self.writer = connect_database(self.database)
        self.addCleanup(self.writer.close)
        with self.writer:
            self.writer.executemany("""INSERT INTO token_usage_events
                (occurred_at_epoch,source,provider,model,input_tokens,external_id)
                VALUES (?,?,?,?,?,?)""", [
                (self.base, source, provider, f"model-{index}", 1, f"{source}/{provider}/{index}")
                for source in ("codex", "opencode", "hermes")
                for provider in ("openai", "anthropic")
                for index in range(334)
            ])
            self.writer.execute("INSERT INTO snapshots (scraped_at_epoch,scraped_at,weekly_pct) VALUES (?,?,?)",
                                (self.base, analytics.iso_utc(self.base), 80))

    def export(self, dataset, params=None):
        body = build_csv(self.database, self.pricing,
                         {"range": "all", "breakdown_offset": "2000", **(params or {})},
                         dataset, now=self.now)
        return list(csv.DictReader(io.StringIO(body.decode("utf-8-sig"))))

    def test_allocation_export_covers_more_than_json_response_limit(self):
        visible = analytics.build_payload(self.database, self.pricing,
            {"range": "all", "sections": "base", "breakdown_offset": "0"}, now=self.now)
        self.assertEqual(2004, visible["tokens"]["breakdown_pagination"]["total"])
        rows = self.export("breakdown")
        self.assertEqual(2004, len(rows))
        self.assertEqual(2004, len({(row["source"], row["provider"], row["model"]) for row in rows}))
        self.assertEqual({"1"}, {row["input_tokens"] for row in rows})

    def test_token_and_limit_exports_do_not_depend_on_allocation_size(self):
        tokens = self.export("tokens")
        self.assertEqual(3, len(tokens))
        self.assertEqual({"668"}, {row["input_tokens"] for row in tokens})
        self.assertEqual(1, len(self.export("limits")))

    def test_allocation_export_preserves_filters_and_row_limit(self):
        rows = self.export("breakdown", {"sources": "codex", "models": "model-0"})
        self.assertEqual(2, len(rows))
        self.assertEqual({"codex"}, {row["source"] for row in rows})
        with patch.object(analytics_export, "MAX_EXPORT_ROWS", 2000):
            with self.assertRaisesRegex(AnalyticsError, "CSV export exceeds 2000 rows"):
                self.export("breakdown")

    def test_allocation_pages_keep_one_snapshot_during_collection_and_observer_failure(self):
        original = analytics.token_analytics
        pages = []

        def read_then_collect(*args, **kwargs):
            result = original(*args, **kwargs)
            pages.append(result[0]["breakdown_pagination"]["offset"])
            if len(pages) == 1:
                with self.writer:
                    self.writer.execute("DELETE FROM token_usage_events WHERE external_id='codex/openai/0'")
                    self.writer.execute("UPDATE token_usage_events SET input_tokens=9")
                    self.writer.execute("""INSERT INTO token_usage_events
                        (occurred_at_epoch,source,provider,model,input_tokens,external_id)
                        VALUES (?,'codex','openai','new-model',9,'new-event')""", (self.base,))
            return result

        with patch.object(analytics.SNAPSHOT_REVISIONS, "_read_observation_locked",
                          side_effect=sqlite3.OperationalError("observer unavailable")), \
             patch.object(analytics, "token_analytics", side_effect=read_then_collect):
            rows = self.export("breakdown")
        self.assertEqual(list(range(0, 2004, 50)), pages)
        self.assertEqual(2004, len(rows))
        self.assertEqual({"1"}, {row["input_tokens"] for row in rows})
        self.assertNotIn("new-model", {row["model"] for row in rows})


if __name__ == "__main__":
    unittest.main()
