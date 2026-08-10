#!/usr/bin/env python3

import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / "local"
sys.path.insert(0, str(LOCAL))

import analytics
import storage


class AnalyticsPricingReadRaceTests(unittest.TestCase):
    def test_hash_and_catalog_use_one_identical_read_during_replacement(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            database = root / "analytics.sqlite3"
            with storage.connect_database(database):
                pass

            initial = (LOCAL / "pricing.json").read_bytes()
            replacement_value = json.loads(initial.decode("utf-8"))
            replacement_value["as_of"] = "replacement-catalog"
            replacement = root / "pricing.replacement.json"
            replacement.write_text(json.dumps(replacement_value), encoding="utf-8")
            pricing = root / "pricing.json"
            pricing.write_bytes(initial)

            real_read_bytes = Path.read_bytes
            pricing_reads = 0

            def replacing_read(path):
                nonlocal pricing_reads
                raw = real_read_bytes(path)
                if path == pricing:
                    pricing_reads += 1
                    os.replace(replacement, pricing)
                return raw

            with mock.patch.object(Path, "read_bytes", new=replacing_read):
                payload = analytics.build_payload(database, pricing, {"range": "24h"}, now=2_000)

            self.assertEqual(1, pricing_reads)
            self.assertEqual(hashlib.sha256(initial).hexdigest(), payload["pricing"]["sha256"])
            self.assertNotEqual("replacement-catalog", payload["pricing"]["as_of"])
            self.assertEqual("replacement-catalog", json.loads(pricing.read_text(encoding="utf-8"))["as_of"])


if __name__ == "__main__":
    unittest.main()
