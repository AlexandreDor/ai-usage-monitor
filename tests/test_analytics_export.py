import csv
import io
import pathlib
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "local"))
from analytics import AnalyticsError, AnalyticsUnavailableError
from analytics_export import build_csv, safe_cell


class AnalyticsExportTests(unittest.TestCase):
    def test_export_removes_pagination_and_preserves_full_precision_and_filters(self):
        payload = {"tokens": {"breakdown": [{"model": "=SUM(1,2)", "provider": "test", "source": "codex", "input_tokens": 123456789, "estimated_cost_usd": 0.12345678}]}}
        with patch("analytics_export.build_payload", return_value=payload) as build:
            body = build_csv(pathlib.Path("db"), pathlib.Path("prices"), {"range": "7d", "models": "=SUM(1,2)", "breakdown_offset": "50"}, "breakdown", now=2000)
        query = build.call_args.args[2]
        self.assertNotIn("breakdown_offset", query)
        self.assertEqual(query["models"], "=SUM(1,2)")
        row = next(csv.DictReader(io.StringIO(body.decode("utf-8-sig"))))
        self.assertEqual(row["model"], "'=SUM(1,2)")
        self.assertEqual(row["input_tokens"], "123456789")
        self.assertEqual(row["estimated_cost_usd"], "0.12345678")

    def test_all_reset_pages_are_exported_from_one_revision(self):
        pages = [{"revision": "same", "resets": {"total": 205, "items": [{"window": "weekly", "reset_at": str(i)} for i in range(begin, end)]}} for begin, end in [(0, 100), (100, 200), (200, 205)]]
        with patch("analytics_export.build_payload", side_effect=pages) as build:
            body = build_csv(pathlib.Path("db"), pathlib.Path("prices"), {}, "resets", now=2000)
        self.assertEqual(len(list(csv.DictReader(io.StringIO(body.decode("utf-8-sig"))))), 205)
        self.assertEqual([call.kwargs["now"] for call in build.call_args_list], [2000, 2000, 2000])

    def test_reset_revision_change_aborts_export(self):
        pages = [{"revision": "a", "resets": {"total": 2, "items": [{"window": "weekly"}]}}, {"revision": "b", "resets": {"total": 2, "items": [{"window": "weekly"}]}}]
        with patch("analytics_export.build_payload", side_effect=pages):
            with self.assertRaises(AnalyticsUnavailableError):
                build_csv(pathlib.Path("db"), pathlib.Path("prices"), {}, "resets", now=2000)

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
        with patch("analytics_export.build_payload", return_value={"tokens": {"breakdown": [{}] * 10001}}):
            with self.assertRaises(AnalyticsError):
                build_csv(pathlib.Path("db"), pathlib.Path("prices"), {}, "breakdown")

    def test_formula_neutralization_does_not_alter_numbers(self):
        for value in ["=1", "+1", "-1", "@test", "\t=cmd", "  +cmd"]:
            self.assertEqual(safe_cell(value), "'" + value)
        self.assertEqual(safe_cell(-12.5), -12.5)
        self.assertEqual(safe_cell("ordinary"), "ordinary")


if __name__ == "__main__":
    unittest.main()
