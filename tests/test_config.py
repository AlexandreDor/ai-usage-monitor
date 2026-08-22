#!/usr/bin/env python3
"""Unit coverage for the shared monitor/server configuration contract."""

from __future__ import annotations

import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "local"))
import config  # noqa: E402


class SharedConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.local = self.root / "local"
        self.local.mkdir()
        self.pricing = self.local / "pricing.json"
        self.pricing.write_text(
            '{"entries":[{"provider":"openai","model":"demo",'
            '"input_per_million":1,"cache_read_per_million":1,'
            '"cache_write_per_million":1,"output_per_million":1}]}',
            encoding="utf-8",
        )
        self.env = self.local / ".env"

    def tearDown(self) -> None:
        self.directory.cleanup()

    def test_dotenv_is_data_and_preserves_metacharacters(self) -> None:
        self.env.write_text(
            "# comment\r\nLOOP_INTERVAL='$(touch SHOULD_NOT_EXIST) $HOME `x` \\\\ literal'\r\n"
            "UNKNOWN=secret-value\nBROKEN\n",
            encoding="utf-8",
        )
        values, warnings = config.parse_env_file(self.env)
        self.assertEqual(values["LOOP_INTERVAL"], "$(touch SHOULD_NOT_EXIST) $HOME `x` \\\\ literal")
        self.assertEqual(len(warnings), 2)
        self.assertFalse((self.root / "SHOULD_NOT_EXIST").exists())
        self.assertEqual(stat.S_IMODE(self.env.stat().st_mode), 0o600)
        self.assertNotIn("secret-value", " ".join(warnings))

    def test_cli_process_dotenv_default_precedence(self) -> None:
        self.env.write_text("LOOP_INTERVAL=100\n", encoding="utf-8")
        resolved = config.resolve_config(
            profile="monitor",
            env_file=self.env,
            environ={"HOME": str(self.root / "home"), "LOOP_INTERVAL": "200"},
            cli={"LOOP_INTERVAL": "300"},
            script_dir=self.local,
        )
        self.assertEqual(resolved["LOOP_INTERVAL"], "300")

        resolved = config.resolve_config(
            profile="monitor", env_file=self.env,
            environ={"HOME": str(self.root / "home"), "LOOP_INTERVAL": "200"},
            script_dir=self.local,
        )
        self.assertEqual(resolved["LOOP_INTERVAL"], "200")

        resolved = config.resolve_config(
            profile="monitor", env_file=self.env,
            environ={"HOME": str(self.root / "home")},
            cli={"LOOP_INTERVAL": "300"},
            script_dir=self.local,
        )
        self.assertEqual(resolved["LOOP_INTERVAL"], "300")

    def test_missing_env_uses_dynamic_defaults(self) -> None:
        resolved = config.resolve_config(
            profile="monitor", env_file=self.root / "missing.env",
            environ={"HOME": str(self.root / "home"), "XDG_DATA_HOME": str(self.root / "xdg")},
            script_dir=self.local,
        )
        self.assertEqual(resolved["LOOP_INTERVAL"], "900")
        self.assertEqual(resolved["DASHBOARD_ACTIVE_INTERVAL_SECONDS"], "300")
        self.assertEqual(resolved["TOKEN_PRICING_FILE"], str(self.pricing))
        self.assertEqual(resolved["OPENCODE_DB_PATH"], str(self.root / "xdg" / "opencode" / "opencode.db"))

    def test_process_override_for_codex_bin_wins(self) -> None:
        self.env.write_text("CODEX_BIN=dotenv-wrapper\n", encoding="utf-8")
        resolved = config.resolve_config(
            profile="monitor", env_file=self.env, script_dir=self.local,
            environ={"HOME": str(self.root), "CODEX_BIN": "process-wrapper", "CODEX_BIN_OVERRIDE": "override-wrapper"},
        )
        self.assertEqual(resolved["CODEX_BIN"], "override-wrapper")

    def test_explicit_empty_required_value_does_not_fall_back(self) -> None:
        self.env.write_text("DASHBOARD_ACTIVE_INTERVAL_SECONDS=\n", encoding="utf-8")
        with self.assertRaises(config.ConfigurationError):
            config.resolve_config(profile="monitor", env_file=self.env, script_dir=self.local, environ={"HOME": str(self.root)})

    def test_shared_server_aliases_and_cli_network_options(self) -> None:
        alternate = self.root / "alternate.json"
        alternate.write_text(self.pricing.read_text(encoding="utf-8"), encoding="utf-8")
        database = self.root / "analytics.sqlite3"
        self.env.write_text(
            f"TOKEN_PRICING_FILE={self.pricing}\nDASHBOARD_ACTIVE_INTERVAL_SECONDS=120\n",
            encoding="utf-8",
        )
        resolved = config.resolve_config(
            profile="serve", env_file=self.env, script_dir=self.local,
            environ={
                "HOME": str(self.root), "TOKEN_PRICING_FILE": str(self.pricing),
                "DASHBOARD_PRICING_FILE": str(alternate),
                "DASHBOARD_ANALYTICS_DATABASE": str(database),
                "DASHBOARD_ACTIVE_INTERVAL_SECONDS": "180",
            },
            cli={"bind": "127.0.0.1", "port": "9090"},
        )
        self.assertEqual(resolved["TOKEN_PRICING_FILE"], str(alternate))
        self.assertEqual(resolved["DASHBOARD_ACTIVE_INTERVAL_SECONDS"], "180")
        self.assertEqual(resolved["PORT"], "9090")
        self.assertEqual(resolved["BIND_ADDRESS"], "127.0.0.1")
        self.assertEqual(resolved["ANALYTICS_DATABASE_PATH"], str(database))

    def test_alert_rules_are_normalized_and_deduplicated(self) -> None:
        hook = self.root / "hook.sh"
        hook.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        hook.chmod(0o700)
        values = {
            "ALERT_SCRIPT_TIMEOUT_SECONDS": "30",
            "ALERT_SCRIPT_2": str(hook),
            "ALERT_SCRIPT_2_EVENTS": "5h:050, weekly:reset",
            "TOKEN_PRICING_FILE": str(self.pricing),
        }
        # The validator accepts a complete monitor mapping with explicit
        # defaults supplied by resolve_config; this also checks the same code
        # path used by both shell transport calls.
        base = config.resolve_config(profile="monitor", script_dir=self.local, environ={"HOME": str(self.root)})
        base.update(values)
        normalized, rules = config.validate_config(base, profile="monitor")
        self.assertEqual(normalized["ALERT_SCRIPT_2_EVENTS"], "5h:050, weekly:reset")
        self.assertEqual([rule["event"] for rule in rules], ["5h:50", "weekly:reset"])
        self.assertEqual(len(rules[0]["id"]), 24)

    def test_symlink_env_is_rejected(self) -> None:
        target = self.root / "real.env"
        target.write_text("LOOP_INTERVAL=10\n", encoding="utf-8")
        self.env.symlink_to(target)
        with self.assertRaises(config.ConfigurationError):
            config.resolve_config(profile="monitor", env_file=self.env, script_dir=self.local, environ={"HOME": str(self.root)})

    def test_invalid_utf8_and_wrong_owner_are_rejected_without_traceback(self) -> None:
        self.env.write_bytes(b"LOOP_INTERVAL=\xff\n")
        with self.assertRaises(config.ConfigurationError):
            config.resolve_config(profile="monitor", env_file=self.env, script_dir=self.local, environ={"HOME": str(self.root)})

        self.env.write_text("LOOP_INTERVAL=10\n", encoding="utf-8")
        with mock.patch.object(config.os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaises(config.ConfigurationError):
                config.resolve_config(profile="monitor", env_file=self.env, script_dir=self.local, environ={"HOME": str(self.root)})

    def test_shared_interval_rejection_is_identical_for_both_profiles(self) -> None:
        self.env.write_text("DASHBOARD_ACTIVE_INTERVAL_SECONDS=29\n", encoding="utf-8")
        for profile in ("monitor", "serve"):
            with self.assertRaises(config.ConfigurationError) as raised:
                config.resolve_config(
                    profile=profile, env_file=self.env, script_dir=self.local,
                    environ={"HOME": str(self.root)},
                    cli={"bind": "127.0.0.1", "port": "8080"} if profile == "serve" else None,
                )
            self.assertIn("DASHBOARD_ACTIVE_INTERVAL_SECONDS", str(raised.exception))

    def test_symlink_pricing_and_database_are_rejected(self) -> None:
        pricing_link = self.root / "pricing-link.json"
        pricing_link.symlink_to(self.pricing)
        self.env.write_text(f"TOKEN_PRICING_FILE={pricing_link}\n", encoding="utf-8")
        with self.assertRaises(config.ConfigurationError):
            config.resolve_config(profile="serve", env_file=self.env, script_dir=self.local, environ={"HOME": str(self.root)})

        database_target = self.root / "database.sqlite3"
        database_target.touch()
        database_link = self.root / "database-link.sqlite3"
        database_link.symlink_to(database_target)
        self.env.write_text(f"TOKEN_PRICING_FILE={self.pricing}\n", encoding="utf-8")
        with self.assertRaises(config.ConfigurationError):
            config.resolve_config(
                profile="serve", env_file=self.env, script_dir=self.local,
                environ={"HOME": str(self.root), "DASHBOARD_ANALYTICS_DATABASE": str(database_link)},
            )

    def test_partial_pairs_and_cli_boundary_are_actionable(self) -> None:
        self.env.write_text("GITHUB_PAT=not-a-secret-to-print\n", encoding="utf-8")
        with self.assertRaises(config.ConfigurationError):
            config.resolve_config(profile="monitor", env_file=self.env, script_dir=self.local, environ={"HOME": str(self.root)})

        completed = subprocess.run(
            [sys.executable, str(Path(config.__file__)), "--profile", "monitor", "--env-file", str(self.env), "--script-dir", str(self.local)],
            text=True, capture_output=True, check=False,
        )
        self.assertEqual(completed.returncode, 1)
        self.assertIn("[ERROR]", completed.stderr)
        self.assertNotIn("not-a-secret-to-print", completed.stderr)
        self.assertNotIn("Traceback", completed.stderr)


if __name__ == "__main__":
    unittest.main()
