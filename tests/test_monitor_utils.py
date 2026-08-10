#!/usr/bin/env python3

import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / "local"
sys.path.insert(0, str(LOCAL))
import monitor_utils


class MonitorUtilsTests(unittest.TestCase):
    def test_number_and_threshold_validation_messages(self):
        monitor_utils.validate_number("VALUE", "1.25", "0.25", "2")
        with self.assertRaisesRegex(ValueError, "must be a number between"):
            monitor_utils.validate_number("VALUE", "no", "0.25", "2")
        with self.assertRaisesRegex(ValueError, "must be between"):
            monitor_utils.validate_number("VALUE", "inf", "0.25", "2")

        self.assertEqual([75, 50, 50, 0], monitor_utils.parse_thresholds("75, 50,50,0", strict=True))
        self.assertEqual([75, 50, 0], monitor_utils.parse_thresholds("50,bad,75,,0,50", strict=False))
        with self.assertRaisesRegex(ValueError, "comma-separated list"):
            monitor_utils.parse_thresholds("75,,50", strict=True)
        with self.assertRaisesRegex(ValueError, "integers only"):
            monitor_utils.parse_thresholds("75,bad", strict=True)
        with self.assertRaisesRegex(ValueError, "between 0 and 100"):
            monitor_utils.parse_thresholds("101", strict=True)

    def test_action_json_timestamp_and_payload_helpers(self):
        expected = hashlib.sha256(b"/tmp/hook\0weekly:reset").hexdigest()[:24]
        self.assertEqual(expected, monitor_utils.action_id("/tmp/hook", "weekly:reset"))
        self.assertEqual(7, monitor_utils.json_get_field('{"value": 7.0}', "value"))
        self.assertEqual("", monitor_utils.json_get_field('{"value": null}', "value"))
        self.assertEqual(0, monitor_utils.timestamp_to_epoch("1970-01-01T00:00:00Z"))
        self.assertEqual(
            {"content": "line\ntext"},
            json.loads(monitor_utils.discord_payload("line\ntext")),
        )
        gist = json.loads(monitor_utils.gist_payload("snapshot", "history"))
        self.assertEqual("snapshot", gist["files"]["data.json"]["content"])
        self.assertEqual("history", gist["files"]["history.json"]["content"])

    def test_pace_and_threshold_comparisons_match_shell_contract(self):
        week = 7 * 24 * 60 * 60
        self.assertEqual(
            "+10.0 pts · 20.0% above",
            monitor_utils.weekly_pace("60", str(1000 + week // 2), "1000"),
        )
        self.assertEqual("", monitor_utils.weekly_pace("unknown", "", "1000"))
        self.assertTrue(monitor_utils.percentage_below_full("79.75"))
        self.assertFalse(monitor_utils.percentage_below_full("100"))
        self.assertTrue(monitor_utils.threshold_crossed("49.5", "80", "50"))
        self.assertFalse(monitor_utils.threshold_crossed("49.5", "80", "50", "75,50"))
        self.assertTrue(monitor_utils.threshold_between("80", "25", "50"))
        self.assertFalse(monitor_utils.threshold_between("80", "25", "10"))

    def test_health_is_updated_atomically_with_bounded_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "health.json"
            monitor_utils.update_health(path, "failure", "x" * 600, 12)
            failed = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual("failure", failed["last_cycle_result"])
            self.assertEqual(1, failed["consecutive_failures"])
            self.assertEqual(500, len(failed["last_error"]["message"]))
            self.assertEqual(0o600, path.stat().st_mode & 0o777)
            self.assertEqual([], list(path.parent.glob(".health.json.*")))

            monitor_utils.update_health(path, "success", "", 7)
            succeeded = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual("success", succeeded["last_cycle_result"])
            self.assertEqual(0, succeeded["consecutive_failures"])
            self.assertIn("last_success", succeeded)

    def test_atomic_state_write_fsyncs_file_and_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "alerts.state"
            with mock.patch.object(
                monitor_utils.os, "fsync", wraps=monitor_utils.os.fsync
            ) as fsync:
                monitor_utils.atomic_write_from_stream(path, io.BytesIO(b"state_version=4\n"))
            self.assertEqual(b"state_version=4\n", path.read_bytes())
            self.assertEqual(0o600, path.stat().st_mode & 0o777)
            self.assertGreaterEqual(fsync.call_count, 2)

    def test_cli_preserves_validation_exit_codes_and_errors(self):
        command = [sys.executable, str(LOCAL / "monitor_utils.py")]
        valid = subprocess.run(
            command + ["validate-thresholds", "75,50"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertEqual(0, valid.returncode)
        invalid = subprocess.run(
            command + ["validate-thresholds", "75,bad"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertEqual(1, invalid.returncode)
        self.assertEqual(
            "[ERROR] ALERT_THRESHOLDS must contain integers only.\n",
            invalid.stderr,
        )
        self.assertNotIn("Traceback", invalid.stderr)

    def test_alert_hook_open_rejects_invalid_final_file_permissions_and_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            hook = root / "hook.sh"
            hook.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            hook.chmod(0o700)

            hook.chmod(0o600)
            with self.assertRaises(monitor_utils.HookValidationError):
                monitor_utils.run_alert_hook(hook, 1, [])
            hook.chmod(0o720)
            with self.assertRaises(monitor_utils.HookValidationError):
                monitor_utils.run_alert_hook(hook, 1, [])
            hook.chmod(0o700)

            link = root / "hook-link.sh"
            link.symlink_to(hook)
            with self.assertRaises(OSError):
                monitor_utils.run_alert_hook(link, 1, [])

            with mock.patch.object(monitor_utils.os, "getuid", return_value=os.getuid() + 1):
                with self.assertRaises(monitor_utils.HookValidationError):
                    monitor_utils.run_alert_hook(hook, 1, [])

    def test_alert_hook_executes_the_inode_opened_before_path_replacement(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            hook = root / "hook.sh"
            replacement = root / "replacement.sh"
            hook.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            replacement.write_text("#!/bin/sh\nexit 7\n", encoding="utf-8")
            hook.chmod(0o700)
            replacement.chmod(0o700)
            original_inode = hook.stat().st_ino
            observed = {}

            def fake_run(command, **kwargs):
                observed["command"] = command
                observed["inode"] = os.fstat(kwargs["pass_fds"][0]).st_ino
                observed["environment"] = kwargs["env"]
                os.replace(replacement, hook)
                return subprocess.CompletedProcess(command, 0)

            with mock.patch.dict(
                monitor_utils.os.environ,
                {
                    "DISCORD_WEBHOOK": "secret",
                    "GITHUB_PAT": "secret",
                },
                clear=False,
            ), mock.patch.object(monitor_utils.subprocess, "run", side_effect=fake_run):
                self.assertEqual(
                    0,
                    monitor_utils.run_alert_hook(
                        hook, 1, ["CODEX_ALERT_EVENT=threshold"]
                    ),
                )

            self.assertEqual(original_inode, observed["inode"])
            self.assertEqual([observed["command"][0]], observed["command"])
            self.assertEqual("threshold", observed["environment"]["CODEX_ALERT_EVENT"])
            self.assertNotIn("DISCORD_WEBHOOK", observed["environment"])
            self.assertNotIn("GITHUB_PAT", observed["environment"])


if __name__ == "__main__":
    unittest.main()
