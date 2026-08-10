#!/usr/bin/env python3

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "local" / "config.py"
SPEC = importlib.util.spec_from_file_location("local_config", CONFIG_PATH)
config = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(config)


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.base = self.root / "local"
        self.base.mkdir()
        self.pricing = self.base / "pricing.json"
        self.pricing.write_text("{}\n", encoding="utf-8")
        self.env_file = self.root / "settings.env"

    def tearDown(self):
        self.temporary.cleanup()

    def write_env(self, text, mode=0o600):
        self.env_file.write_text(text, encoding="utf-8")
        self.env_file.chmod(mode)

    def resolve(self, keys, *, environ=None, overrides=None):
        environment = dict(os.environ)
        environment.update(environ or {})
        return config.resolve_config(
            keys,
            base_dir=self.base,
            config_path=self.env_file,
            config_required=True,
            environ=environment,
            overrides=overrides,
        )

    def test_priority_cli_environment_file_default(self):
        self.write_env("LOOP_INTERVAL=30\n")
        self.assertEqual("30", self.resolve(["LOOP_INTERVAL"])["LOOP_INTERVAL"])
        self.assertEqual(
            "40",
            self.resolve(["LOOP_INTERVAL"], environ={"LOOP_INTERVAL": "40"})["LOOP_INTERVAL"],
        )
        self.assertEqual(
            "50",
            self.resolve(
                ["LOOP_INTERVAL"],
                environ={"LOOP_INTERVAL": "40"},
                overrides={"LOOP_INTERVAL": "50"},
            )["LOOP_INTERVAL"],
        )
        self.write_env("# empty\n")
        self.assertEqual("900", self.resolve(["LOOP_INTERVAL"])["LOOP_INTERVAL"])

    def test_malicious_text_is_not_executed_and_unrequested_values_are_ignored(self):
        marker = self.root / "executed"
        self.write_env(f"IGNORED=$(touch '{marker}')\nLOOP_INTERVAL=20\nMONITOR_DEBUG=not-a-number\n")
        self.assertEqual("20", self.resolve(["LOOP_INTERVAL"])["LOOP_INTERVAL"])
        self.assertFalse(marker.exists())

    def test_permissions_and_symlinks_are_rejected(self):
        self.write_env("LOOP_INTERVAL=20\n", mode=0o644)
        with self.assertRaisesRegex(config.ConfigError, "permissions"):
            self.resolve(["LOOP_INTERVAL"])

        target = self.root / "target.env"
        target.write_text("LOOP_INTERVAL=20\n", encoding="utf-8")
        target.chmod(0o600)
        self.env_file.unlink()
        self.env_file.symlink_to(target)
        with self.assertRaises(config.ConfigError):
            self.resolve(["LOOP_INTERVAL"])

    def test_nul_transport_preserves_spaces_and_errors_have_no_traceback(self):
        command_path = str(self.root / "bin with spaces" / "codex")
        self.write_env(f"CODEX_BIN='{command_path}'\n")
        result = subprocess.run(
            [
                "python3",
                str(CONFIG_PATH),
                "--base-dir",
                str(self.base),
                "--config",
                str(self.env_file),
                "--config-required",
                "--key",
                "CODEX_BIN",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual([b"CODEX_BIN", command_path.encode(), b""], result.stdout.split(b"\0"))

        environment = dict(os.environ)
        environment["CODEX_BIN"] = "line one\nline two"
        failure = subprocess.run(
            [
                "python3",
                str(CONFIG_PATH),
                "--base-dir",
                str(self.base),
                "--config",
                str(self.env_file),
                "--key",
                "CODEX_BIN",
            ],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertEqual(2, failure.returncode)
        self.assertIn("[ERROR] CODEX_BIN must fit on one line.", failure.stderr)
        self.assertNotIn("Traceback", failure.stderr)

    def test_monitor_and_server_resolve_the_same_pricing_catalog(self):
        custom_pricing = self.root / "catalog with spaces.json"
        custom_pricing.write_text("{}\n", encoding="utf-8")
        self.write_env(f"TOKEN_PRICING_FILE='{custom_pricing}'\n")
        environment = dict(os.environ)
        monitor = config.resolve_profile(
            "monitor",
            base_dir=self.base,
            config_path=self.env_file,
            environ=environment,
            config_required=True,
        )
        server = config.resolve_profile(
            "serve",
            base_dir=self.base,
            config_path=self.env_file,
            environ=environment,
            config_required=True,
        )
        self.assertEqual(str(custom_pricing), monitor["TOKEN_PRICING_FILE"])
        self.assertEqual(monitor["TOKEN_PRICING_FILE"], server["TOKEN_PRICING_FILE"])

    def test_installed_defaults_follow_xdg(self):
        self.write_env("# empty\n")
        state_home = self.root / "state home"
        data_home = self.root / "data home"
        environment = {
            "HOME": str(self.root / "isolated home"),
            "XDG_STATE_HOME": str(state_home),
            "XDG_DATA_HOME": str(data_home),
        }
        with mock.patch.dict(
            os.environ,
            {"HOME": str(self.root / "wrong home"), "XDG_STATE_HOME": str(self.root / "wrong state")},
            clear=True,
        ):
            values = config.resolve_config(
                ["STATE_DIR", "CODEX_DATA_DIR", "OPENCODE_DB_PATH", "HERMES_DB_PATH"],
                base_dir=self.base,
                config_path=self.env_file,
                config_required=True,
                environ=environment,
            )
        self.assertEqual(str(state_home / "codex-usage-monitor"), values["STATE_DIR"])
        self.assertEqual(str(Path(environment["HOME"]) / ".codex"), values["CODEX_DATA_DIR"])
        self.assertEqual(str(data_home / "opencode" / "opencode.db"), values["OPENCODE_DB_PATH"])
        self.assertEqual(str(Path(environment["HOME"]) / ".hermes" / "state.db"), values["HERMES_DB_PATH"])

    def test_api_urls_require_https_except_explicit_loopback(self):
        self.write_env("# empty\n")
        for value in (
            "https://api.example.com/v1",
            "http://localhost:8080",
            "http://127.0.0.1:8080",
            "http://[::1]:8080",
        ):
            self.assertEqual(
                value,
                self.resolve(["GITHUB_API_URL"], overrides={"GITHUB_API_URL": value})["GITHUB_API_URL"],
            )
        for value in (
            "http://api.example.com",
            "https://user@api.example.com",
            "https://api.example.com/path#fragment",
            "https://api.example.com/path?query=1",
            "https://api.example.com:99999",
            "https://api.example.com\\@attacker.invalid",
        ):
            with self.subTest(value=value), self.assertRaises(config.ConfigError):
                self.resolve(["GITHUB_API_URL"], overrides={"GITHUB_API_URL": value})

    def test_status_profile_ignores_unrelated_invalid_configuration(self):
        self.write_env(
            "ALERT_THRESHOLDS=invalid\n"
            "TOKEN_USAGE_SOURCES=invalid\n"
            "TOKEN_PRICING_FILE=/missing/catalog.json\n"
            "GITHUB_API_URL=http://example.com\n"
            "LOOP_INTERVAL=60\n"
        )
        values = config.resolve_profile(
            "status",
            base_dir=self.base,
            config_path=self.env_file,
            config_required=True,
            environ={"HOME": str(self.root / "home")},
        )
        self.assertEqual("60", values["LOOP_INTERVAL"])
        self.assertEqual(set(config.STATUS_KEYS), set(values))

    def test_alert_hook_rejects_symlink_permissions_and_wrong_owner(self):
        self.write_env("# empty\n")
        hook = self.root / "hook.sh"
        hook.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        hook.chmod(0o700)
        keys = ["ALERT_SCRIPT_1", "ALERT_SCRIPT_1_EVENTS"]
        overrides = {"ALERT_SCRIPT_1": str(hook), "ALERT_SCRIPT_1_EVENTS": "5h:50"}
        self.assertEqual(str(hook), self.resolve(keys, overrides=overrides)["ALERT_SCRIPT_1"])

        link = self.root / "hook-link.sh"
        link.symlink_to(hook)
        with self.assertRaises(config.ConfigError):
            self.resolve(keys, overrides={**overrides, "ALERT_SCRIPT_1": str(link)})

        hook.chmod(0o720)
        with self.assertRaises(config.ConfigError):
            self.resolve(keys, overrides=overrides)
        hook.chmod(0o700)
        with mock.patch.object(config.os, "getuid", return_value=hook.stat().st_uid + 1):
            with self.assertRaises(config.ConfigError):
                self.resolve(keys, overrides=overrides)


if __name__ == "__main__":
    unittest.main()
