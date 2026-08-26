#!/usr/bin/env python3
"""Unit and process-boundary tests for the Codex app-server client."""

from __future__ import annotations

import io
import json
import errno
from pathlib import Path
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / "local"
sys.path.insert(0, str(LOCAL))

import codex_client  # noqa: E402


FIXTURE = ROOT / "tests" / "fixtures" / "fake-codex.sh"
MULTI_ID = ROOT / "tests" / "fixtures" / "codex" / "multi-id.json"
PARTIAL = ROOT / "tests" / "fixtures" / "codex" / "partial.json"
UNKNOWN = ROOT / "tests" / "fixtures" / "codex" / "unknown.json"


class CodexClientTests(unittest.TestCase):
    def run_client(self, fixture: Path, *extra: str, env: dict[str, str] | None = None):
        child_env = os.environ.copy()
        child_env["FAKE_CODEX_FIXTURE"] = str(fixture)
        if env:
            child_env.update(env)
        return subprocess.run(
            [
                sys.executable,
                str(LOCAL / "codex_client.py"),
                "--codex-bin",
                str(FIXTURE),
                "--interval",
                "900",
                "--history-window-hours",
                "192",
                *extra,
            ],
            env=child_env,
            text=True,
            capture_output=True,
            check=False,
        )

    def run_protocol_server(self, body: str, *, debug: bool = False):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "protocol.sh"
            script.write_text(
                "#!/usr/bin/env bash\nset -euo pipefail\n"
                + body
                + "\n",
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | stat.S_IXUSR)
            command = [
                sys.executable,
                str(LOCAL / "codex_client.py"),
                "--codex-bin",
                str(script),
                "--timeout",
                "2",
            ]
            if debug:
                command.append("--debug")
            return subprocess.run(command, text=True, capture_output=True, check=False)

    def test_complete_group_is_normalized_with_v1_contract(self):
        process = self.run_client(MULTI_ID)
        self.assertEqual(0, process.returncode, process.stderr)
        value = json.loads(process.stdout)
        self.assertEqual(1, value["schema_version"])
        self.assertEqual(
            codex_client.snapshot_contract.sanitize_limit_id("coherent"),
            value["limit_id"],
        )
        self.assertEqual(79.75, value["five_h_pct"])
        self.assertEqual(4.5, value["weekly_pct"])
        self.assertEqual(900, value["sample_interval_seconds"])
        self.assertEqual(192, value["history_window_hours"])

    def test_partial_group_is_explicit_and_does_not_fabricate_data(self):
        process = self.run_client(PARTIAL)
        self.assertEqual(0, process.returncode, process.stderr)
        value = json.loads(process.stdout)
        self.assertEqual(87.5, value["five_h_pct"])
        self.assertIsNone(value["weekly_pct"])
        self.assertIn("partial limit group", process.stderr)

    def test_unknown_windows_and_invalid_handshake_fail_without_traceback(self):
        process = self.run_client(UNKNOWN)
        self.assertEqual(1, process.returncode)
        self.assertIn("recognized usage window", process.stderr)
        self.assertNotIn("Traceback", process.stderr)

    def test_notifications_and_invalid_noise_do_not_hide_valid_result(self):
        body = textwrap.dedent(
            """\
            IFS= read -r initialize
            printf '%s\\n' '{"method":"server/notification"}' 'not-json' '{"id":1,"result":{}}'
            IFS= read -r initialized
            IFS= read -r request
            printf '%s\\n' '{"id":2,"result":{"rateLimits":{"limitId":"default","primary":{"windowDurationMins":300,"usedPercent":20}}}}'
            """
        )
        process = self.run_protocol_server(body)
        self.assertEqual(0, process.returncode, process.stderr)
        self.assertEqual(80, json.loads(process.stdout)["five_h_pct"])

    def test_handshake_error_and_invalid_only_response_are_explicit(self):
        handshake = self.run_protocol_server(
            "IFS= read -r initialize\nprintf '%s\\n' '{\"id\":1,\"error\":{\"code\":-32600}}'"
        )
        self.assertEqual(1, handshake.returncode)
        self.assertIn("initialization failed", handshake.stderr)
        self.assertNotIn("Traceback", handshake.stderr)

        invalid = self.run_protocol_server(
            "IFS= read -r initialize\nprintf '%s\\n' 'not-json'"
        )
        self.assertEqual(1, invalid.returncode)
        self.assertIn("invalid JSON", invalid.stderr)
        self.assertNotIn("Traceback", invalid.stderr)

        giant = self.run_protocol_server(
            "IFS= read -r initialize\nhead -c 1048577 /dev/zero | tr '\\0' x"
        )
        self.assertEqual(1, giant.returncode)
        self.assertIn("1 MiB protocol line limit", giant.stderr)
        self.assertNotIn("Traceback", giant.stderr)

        huge_number = self.run_protocol_server(
            "IFS= read -r initialize\n"
            "printf '%s' '{\"id\":1,\"result\":{}}\\n'\n"
            "IFS= read -r initialized\n"
            "IFS= read -r request\n"
            "printf '%s' '{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":{\"windowDurationMins\":300,\"usedPercent\":'\n"
            "head -c 5000 /dev/zero | tr '\\0' 9\n"
            "printf '%s\\n' '}}}}}'"
        )
        self.assertEqual(1, huge_number.returncode)
        self.assertIn("invalid JSON", huge_number.stderr)
        self.assertNotIn("Traceback", huge_number.stderr)

    def test_debug_diagnostic_is_printable_redacted_and_bounded(self):
        body = textwrap.dedent(
            """\
            IFS= read -r initialize
            head -c 10000 /dev/zero | tr '\\0' x >&2
            printf '%s\\n' '{"id":1,"error":{}}'
            """
        )
        process = self.run_protocol_server(body, debug=True)
        self.assertEqual(1, process.returncode)
        self.assertIn("[DEBUG] Codex diagnostic:", process.stderr)
        self.assertLessEqual(len(process.stderr), 4300)

    def test_secret_environment_values_are_not_passed_or_printed(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "secret-check.sh"
            script.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    echo "DISCORD=$DISCORD_WEBHOOK PAT=$GITHUB_PAT TELEGRAM=$TELEGRAM_BOT_TOKEN CHAT=$TELEGRAM_CHAT_ID GIST=$GITHUB_GIST_ID" >&2
                    exec "__FIXTURE__" "$@"
                    """
                ).replace("__FIXTURE__", str(FIXTURE)),
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | stat.S_IXUSR)
            env = {
                "DISCORD_WEBHOOK": "discord-secret-value",
                "GITHUB_PAT": "github-secret-value",
                "TELEGRAM_BOT_TOKEN": "telegram-secret-value",
                "TELEGRAM_CHAT_ID": "telegram-chat-id",
                "GITHUB_GIST_ID": "gist-account-id",
            }
            child_env = os.environ.copy()
            child_env["FAKE_CODEX_FIXTURE"] = str(MULTI_ID)
            child_env.update(env)
            process = subprocess.run(
                [
                    sys.executable,
                    str(LOCAL / "codex_client.py"),
                    "--codex-bin",
                    str(script),
                    "--debug",
                ],
                env=child_env,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(0, process.returncode, process.stderr)
            for secret in env.values():
                self.assertNotIn(secret, process.stderr)

    def test_server_limit_id_is_redacted_from_success_diagnostics(self):
        raw_id = "server-secret-/workspace/private"
        process = self.run_protocol_server(
            textwrap.dedent(
                """\
                IFS= read -r initialize
                printf '%s\\n' '{"id":1,"result":{}}'
                IFS= read -r initialized
                IFS= read -r request
                """
            )
            + f"printf '%s\\n' '{{\"id\":2,\"result\":{{\"rateLimits\":{{\"limitId\":\"{raw_id}\",\"primary\":{{\"windowDurationMins\":300,\"usedPercent\":20}}}}}}}}'\n"
            + f"echo '{raw_id}' >&2\n",
            debug=True,
        )
        self.assertEqual(0, process.returncode, process.stderr)
        self.assertNotIn(raw_id, process.stderr)

    def test_timeout_is_bounded_and_has_adapted_exit_code(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "hang.sh"
            script.write_text("#!/usr/bin/env bash\nsleep 10\n", encoding="utf-8")
            script.chmod(script.stat().st_mode | stat.S_IXUSR)
            process = subprocess.run(
                [
                    sys.executable,
                    str(LOCAL / "codex_client.py"),
                    "--codex-bin",
                    str(script),
                    "--timeout",
                    "0.1",
                ],
                text=True,
                capture_output=True,
                check=False,
                timeout=8,
            )
            self.assertEqual(1, process.returncode)
            self.assertIn("Timed out", process.stderr)
            self.assertNotIn("Traceback", process.stderr)

    def test_timeout_kills_app_server_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "spawn-child.sh"
            pid_file = Path(directory) / "child.pid"
            script.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)' & child=$!\n"
                "echo \"$child\" > \"$DESCENDANT_PID_FILE\"\n"
                # Exit the leader immediately.  Cleanup must still use the
                # captured PID/PGID; getpgid() would race and fail here.
                "exit 0\n",
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | stat.S_IXUSR)
            child_env = os.environ.copy()
            child_env["DESCENDANT_PID_FILE"] = str(pid_file)
            process = subprocess.run(
                [
                    sys.executable,
                    str(LOCAL / "codex_client.py"),
                    "--codex-bin",
                    str(script),
                    "--timeout",
                    "0.1",
                ],
                env=child_env,
                text=True,
                capture_output=True,
                check=False,
                timeout=8,
            )
            self.assertEqual(1, process.returncode)
            child_pid = int(pid_file.read_text(encoding="utf-8"))
            for _ in range(20):
                try:
                    process_state = Path(f"/proc/{child_pid}/stat").read_text(encoding="utf-8").split(") ", 1)[1][0]
                    if process_state == "Z":
                        break
                except (FileNotFoundError, IndexError):
                    break
                try:
                    os.kill(child_pid, 0)
                except OSError as exc:
                    if exc.errno == errno.ESRCH:
                        break
                time.sleep(0.05)
            else:
                self.fail("Codex timeout left a descendant process running")

    def test_direct_protocol_parser_handles_fragmentation_and_diagnostics(self):
        class Stream:
            def __init__(self, name):
                self.name = name

            def fileno(self):
                return 101 if self.name == "stdout" else 102

        class Process:
            def __init__(self):
                self.stdin = io.BytesIO()
                self.stdout = Stream("stdout")
                self.stderr = Stream("stderr")
                self.pid = 12345

            def poll(self):
                return None

        process = Process()
        stdout_chunks = [
            b'{"method":"notification"}\n{"id":1,"re',
            b'sult":{}}\n',
            b'{"id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300,'
            b'"usedPercent":12.5}}}}',
        ]
        stderr_chunks = [b"diagnostic /etc/codex/account_acct_123\n"]

        def read_available(stream, *, limit):
            queue = stderr_chunks if stream is process.stderr else stdout_chunks
            if not queue:
                return b""
            return queue.pop(0)

        def select_ready(readable, _writable, _exceptional, _timeout):
            if process.stdout in readable and stdout_chunks:
                return [process.stdout], [], []
            if process.stderr in readable and stderr_chunks:
                return [process.stderr], [], []
            return [], [], []

        with patch.object(codex_client, "_read_available", side_effect=read_available), patch.object(
            codex_client.select, "select", side_effect=select_ready
        ):
            result, diagnostic, invalid = codex_client._read_result(
                process,
                timeout_seconds=1,
                environment={"GITHUB_PAT": "secret"},
                debug=False,
            )
        self.assertEqual(12.5, result["rateLimits"]["primary"]["usedPercent"])
        self.assertFalse(invalid)
        self.assertIn("[PATH]", diagnostic)
        self.assertNotIn("acct_123", diagnostic)

    def test_direct_contract_helpers_cover_large_numbers_and_safe_partial_id(self):
        huge = 10**10_000
        self.assertFalse(codex_client.finite_number(huge))
        self.assertFalse(codex_client.finite_number(10**10_000))
        self.assertEqual(7, codex_client.reset_timestamp({"resetsAt": 7.9}))
        with self.assertRaises(codex_client.CodexProtocolError):
            codex_client.reset_timestamp({"resetsAt": 1e308})
        giant_id = "secret/path\n" + "x" * 5000
        with patch("sys.stderr", new_callable=io.StringIO) as stderr:
            snapshot = codex_client.build_snapshot(
                {
                    "rateLimitsByLimitId": {
                        giant_id: {
                            "primary": {"windowDurationMins": 300, "usedPercent": 20}
                        }
                    }
                },
                sample_interval_seconds=900,
                history_window_hours=192,
            )
        opaque_id = codex_client.snapshot_contract.sanitize_limit_id(giant_id)
        self.assertEqual(opaque_id, snapshot.get("limit_id"))
        self.assertEqual(opaque_id, codex_client.snapshot_contract.sanitize_limit_id(opaque_id))
        warning = stderr.getvalue()
        self.assertIn(opaque_id, warning)
        self.assertNotIn(giant_id, warning)
        self.assertNotIn("\x1b", warning)
        with patch.dict(os.environ, {"GITHUB_PAT": "limit-secret"}, clear=False), patch(
            "sys.stderr", new_callable=io.StringIO
        ) as secret_stderr:
            codex_client.build_snapshot(
                {
                    "rateLimitsByLimitId": {
                        "limit-secret": {
                            "primary": {"windowDurationMins": 300, "usedPercent": 20}
                        }
                    }
                },
                sample_interval_seconds=900,
                history_window_hours=192,
            )
        self.assertNotIn("limit-secret", secret_stderr.getvalue())
        diagnostic = codex_client.clean_diagnostic(
            "https://api.example.test/v1 /tmp/path with spaces/secret"
            "\nfile:/etc/codex/config\nfile:///opt/private/secret\n/workspace/project/private"
        )
        self.assertIn("https://api.example.test/v1", diagnostic)
        self.assertNotIn("/tmp/path", diagnostic)
        self.assertNotIn("spaces/secret", diagnostic)
        self.assertNotIn("file:/etc", diagnostic)
        self.assertNotIn("file:///opt", diagnostic)
        self.assertNotIn("/workspace/project/private", diagnostic)
        self.assertGreaterEqual(diagnostic.count("[PATH]"), 3)

    def test_protocol_digest_shaped_id_is_hashed_again_but_persisted_is_idempotent(self):
        raw_id = "limit-" + "a" * 64
        snapshot = codex_client.build_snapshot(
            {
                "rateLimits": {
                    "limitId": raw_id,
                    "primary": {"windowDurationMins": 300, "usedPercent": 20},
                    "secondary": {"windowDurationMins": 10080, "usedPercent": 30},
                }
            },
            sample_interval_seconds=900,
            history_window_hours=192,
        )
        expected = codex_client.snapshot_contract.opaque_limit_id_from_raw(raw_id)
        self.assertEqual(expected, snapshot["limit_id"])
        self.assertNotEqual(raw_id, snapshot["limit_id"])
        self.assertEqual(raw_id, codex_client.snapshot_contract.canonicalize_limit_id(raw_id))
        self.assertEqual(expected, codex_client.snapshot_contract.canonicalize_limit_id(expected))

    def test_fetch_status_factory_contract_and_group_cleanup(self):
        calls = []

        class Process:
            stdin = io.BytesIO()
            stdout = io.BytesIO()
            stderr = io.BytesIO()
            pid = 999

        process = Process()

        def factory(*args, **kwargs):
            calls.append((args, kwargs))
            return process

        with patch.object(
            codex_client,
            "_read_result",
            return_value=(
                {
                    "rateLimits": {
                        "primary": {"windowDurationMins": 300, "usedPercent": 10},
                        "secondary": {"windowDurationMins": 10080, "usedPercent": 20},
                    }
                },
                "",
                False,
            ),
        ), patch.object(codex_client, "stop_process") as stop:
            value = codex_client.fetch_status(
                "/custom/codex",
                timeout_seconds=3,
                sample_interval_seconds=120,
                history_window_hours=24,
                environment={"GITHUB_GIST_ID": "gist", "GITHUB_PAT": "pat"},
                popen_factory=factory,
            )
        self.assertEqual(90, value["five_h_pct"])
        self.assertTrue(calls[0][1]["start_new_session"])
        self.assertNotIn("GITHUB_GIST_ID", calls[0][1]["env"])
        self.assertNotIn("GITHUB_PAT", calls[0][1]["env"])
        stop.assert_called_once_with(process, process_group=999)

        with self.assertRaises(codex_client.CodexClientError):
            codex_client.fetch_status(
                "codex", timeout_seconds=0, popen_factory=factory
            )
        with self.assertRaises(codex_client.CodexClientError):
            codex_client.fetch_status(
                "codex", popen_factory=lambda *_args, **_kwargs: (_ for _ in ()).throw(OSError("no"))
            )


if __name__ == "__main__":
    unittest.main()
