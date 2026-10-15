#!/usr/bin/env python3
"""Regression coverage for weekly renewals with no visible quota increase."""

import datetime as dt
import pathlib
import json
import os
import sqlite3
import subprocess
import time
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "local"))
import analytics
import anomalies
import archive
import storage
from weekly_reset import observe_full_weekly_reset
import weekly_window_start


class FullWeeklyResetTests(unittest.TestCase):
    def sample(self, epoch, deadline, pct=100, owner="group-a"):
        return {
            "schema_version": 1,
            "scraped_at_epoch": epoch,
            "scraped_at": dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "five_h_pct": 50, "five_h_reset": "later", "five_h_reset_at": 2_000_000_000,
            "weekly_pct": pct, "weekly_reset": "later", "weekly_reset_at": deadline,
            "sample_interval_seconds": 900, "history_window_hours": 192,
            "limit_id": storage.canonicalize_limit_id(owner) if owner else None,
        }

    def observe(self, state, epoch, deadline, pct=100, owner="group-a"):
        return observe_full_weekly_reset(state, epoch=epoch, pct=pct,
                                        reset_at=deadline, owner=owner, interval=900)

    def test_confirmation_tolerates_drift_and_consumption_and_deduplicates(self):
        state, event, pending = self.observe("", 100, 10_000)
        state, event, pending = self.observe(state, 1000, 13_000)
        self.assertEqual((0, True), (event, pending))
        replay = self.observe(state, 1000, 13_000)
        self.assertEqual((state, 0, True), replay)
        state, event, pending = self.observe(state, 1900, 13_010, pct=99)
        self.assertEqual((1000, False), (event, pending))
        self.assertEqual(0, self.observe(state, 2800, 13_010, pct=99)[1])

    def test_small_backward_and_nonfull_movements_are_not_candidates(self):
        for before, after, first_pct in ((10_000, 10_010, 100),
                                         (10_000, 9000, 100),
                                         (10_000, 13_000, 99)):
            with self.subTest(before=before, after=after, pct=first_pct):
                state = self.observe("", 100, before, pct=first_pct)[0]
                state, event, pending = self.observe(state, 1000, after)
                self.assertEqual((0, False), (event, pending))

    def test_candidate_cannot_survive_stale_partial_or_foreign_samples(self):
        for epoch, deadline, pct, owner in ((5000, 13_000, 100, "group-a"),
                                           (1900, None, 100, "group-a"),
                                           (1900, 13_000, None, "group-a"),
                                           (1900, 13_000, 100, "group-b"),
                                           (1900, 13_000, 100, None)):
            with self.subTest(epoch=epoch, pct=pct, owner=owner):
                state = self.observe("", 100, 10_000)[0]
                state = self.observe(state, 1000, 13_000)[0]
                state, event, pending = self.observe(state, epoch, deadline, pct, owner)
                self.assertEqual((0, False), (event, pending))

    def test_reverted_candidate_is_not_confirmed(self):
        state = self.observe("", 100, 10_000)[0]
        state = self.observe(state, 1000, 13_000)[0]
        self.assertEqual((0, False), self.observe(state, 1900, 10_000)[1:])

    def test_incident_agrees_across_anomalies_archive_and_analytics(self):
        with tempfile.TemporaryDirectory() as directory:
            c = storage.connect_database(pathlib.Path(directory) / "archive.sqlite3")
            c.row_factory = sqlite3.Row
            try:
                for epoch, deadline in ((1792044001, 1792473311),
                                        (1792044901, 1792649701),
                                        (1792045801, 1792649711)):
                    sample = self.sample(epoch, deadline)
                    with c:
                        anomalies.process_snapshot(c, sample)
                        archive.insert_snapshot(c, sample)
                        archive.rebuild_reset_events(c)
                    if epoch == 1792044901:
                        self.assertEqual(0, c.execute("SELECT count(*) FROM reset_events WHERE window='weekly'").fetchone()[0])
                self.assertEqual(0, c.execute("SELECT count(*) FROM quota_anomalies WHERE window='weekly'").fetchone()[0])
                row = c.execute("SELECT * FROM reset_events WHERE window='weekly'").fetchone()
                self.assertEqual((1792044901, 1792045801, "full_observed"),
                                 (row["reset_at_epoch"], row["observed_at_epoch"], row["detection_method"]))
                payload = analytics.reset_history(c, 1792000000, 1792100000, "weekly", 0, 50)
                self.assertEqual("random", payload["items"][0]["category"])
                self.assertEqual(0, payload["items"][0]["unused_pct_points"])
                self.assertEqual(0, payload["weekly_summary"]["end_of_week"]["count"])
                self.assertEqual(1, payload["weekly_summary"]["random"]["count"])
                self.assertEqual(0, payload["weekly_summary"]["random"]["net_vs_ideal_pct_points"])
            finally:
                c.close()

    def test_invalid_state_is_a_new_baseline(self):
        for state in ("bad", "W10=", "e30=", None):
            with self.subTest(state=state):
                self.assertEqual((0, False), self.observe(state, 100, 10_000)[1:])

    def test_confirmation_after_old_deadline_has_one_archive_event(self):
        with tempfile.TemporaryDirectory() as directory:
            c = storage.connect_database(pathlib.Path(directory) / "archive.sqlite3")
            try:
                for epoch, deadline, pct in ((10000, 14000, 99), (10900, 14000, 100),
                                             (13600, 20000, 100), (14500, 20010, 100),
                                             (15400, 20011, 100)):
                    archive.insert_snapshot(c, self.sample(epoch, deadline, pct))
                archive.rebuild_reset_events(c)
                self.assertEqual([(13600, 14500, "full_observed")], c.execute(
                    "SELECT reset_at_epoch, observed_at_epoch, detection_method "
                    "FROM reset_events WHERE window='weekly'"
                ).fetchall())
            finally:
                c.close()

    def test_rejected_candidates_release_the_original_anomaly_once_after_restart(self):
        interruptions = ((1900, 13061, 100, "group-a"),  # Drift beyond confirmation tolerance.
                         (1900, 13000, None, "group-a"),
                         (1900, None, 100, "group-a"),
                         (5000, 13000, 100, "group-a"),
                         (1900, 13000, 100, "group-b"),
                         (1900, 10000, 100, "group-a"))
        for interruption in interruptions:
            with self.subTest(interruption=interruption), tempfile.TemporaryDirectory() as directory:
                database = pathlib.Path(directory) / "archive.sqlite3"
                c = storage.connect_database(database)
                try:
                    for epoch, deadline in ((100, 10000), (1000, 13000)):
                        sample = self.sample(epoch, deadline)
                        anomalies.process_snapshot(c, sample)
                        archive.insert_snapshot(c, sample)
                    self.assertEqual(0, c.execute("SELECT count(*) FROM quota_anomalies").fetchone()[0])
                    c.commit()
                finally:
                    c.close()
                c = storage.connect_database(database)
                try:
                    sample = self.sample(*interruption)
                    anomalies.process_snapshot(c, sample)
                    anomalies.process_snapshot(c, sample)  # Replayed collection is idempotent.
                    archive.insert_snapshot(c, sample)
                    archive.rebuild_reset_events(c)
                    self.assertEqual([(1000, storage.canonicalize_limit_id("group-a"))], c.execute(
                        "SELECT detected_at_epoch, limit_id FROM quota_anomalies "
                        "WHERE window='weekly' AND anomaly_type='reset_shift' "
                        "AND before_reset_at=10000 AND after_reset_at=13000"
                    ).fetchall())
                    self.assertEqual(0, c.execute(
                        "SELECT count(*) FROM reset_events WHERE window='weekly'"
                    ).fetchone()[0])
                finally:
                    c.close()

    def test_replaced_candidate_releases_only_the_unconfirmed_shift(self):
        with tempfile.TemporaryDirectory() as directory:
            c = storage.connect_database(pathlib.Path(directory) / "archive.sqlite3")
            try:
                for epoch, deadline in ((100, 10000), (1000, 13000),
                                        (1900, 16000), (2800, 16010)):
                    anomalies.process_snapshot(c, self.sample(epoch, deadline))
                self.assertEqual([(10000, 13000)], c.execute(
                    "SELECT before_reset_at, after_reset_at FROM quota_anomalies WHERE window='weekly'"
                ).fetchall())
            finally:
                c.close()

    def test_legacy_detector_migrates_only_an_absent_complete_baseline(self):
        for baseline in ("legacy", "canceled", "partial", "pct_missing", "both_missing",
                         "owner_return", "no_history"):
            with self.subTest(baseline=baseline), tempfile.TemporaryDirectory() as directory:
                c = storage.connect_database(pathlib.Path(directory) / "archive.sqlite3")
                try:
                    sample = self.sample(100, 10000)
                    anomalies.process_snapshot(c, sample)
                    if baseline != "no_history":
                        archive.insert_snapshot(c, sample)
                    if baseline == "owner_return":
                        sample = self.sample(300, 10000, owner="group-b")
                        anomalies.process_snapshot(c, sample)
                        archive.insert_snapshot(c, sample)
                    if baseline in {"partial", "pct_missing", "both_missing", "owner_return"}:
                        sample = self.sample(500, None, pct=100 if baseline == "partial" else None)
                        if baseline in {"both_missing", "owner_return"}:
                            sample["five_h_pct"] = None
                            sample["five_h_reset_at"] = None
                        anomalies.process_snapshot(c, sample)
                        archive.insert_snapshot(c, sample)
                    row = c.execute(
                        "SELECT state_json FROM anomaly_detector_state WHERE window='weekly' AND limit_id=?",
                        (storage.canonicalize_limit_id("group-a"),),
                    ).fetchone()
                    state = json.loads(row[0])
                    if baseline == "canceled":
                        state["full_weekly_reset_state"] = ""
                    else:
                        state.pop("full_weekly_reset_state")
                    c.execute("UPDATE anomaly_detector_state SET state_json=?, updated_at_epoch=? "
                              "WHERE window='weekly' AND limit_id=?",
                              (json.dumps(state), state["last_epoch"], storage.canonicalize_limit_id("group-a")))
                    c.commit()
                    for epoch, deadline in ((1000, 13000), (1900, 13010)):
                        sample = self.sample(epoch, deadline)
                        anomalies.process_snapshot(c, sample)
                        archive.insert_snapshot(c, sample)
                    archive.rebuild_reset_events(c)
                    self.assertEqual(0 if baseline == "legacy" else 1, c.execute(
                        "SELECT count(*) FROM quota_anomalies WHERE window='weekly' AND anomaly_type='reset_shift'"
                    ).fetchone()[0])
                    if baseline == "legacy":
                        self.assertEqual([(1000, 1900, "full_observed")], c.execute(
                            "SELECT reset_at_epoch, observed_at_epoch, detection_method "
                            "FROM reset_events WHERE window='weekly'"
                        ).fetchall())
                    elif baseline != "canceled":
                        self.assertEqual(0, c.execute(
                            "SELECT count(*) FROM reset_events WHERE window='weekly'"
                        ).fetchone()[0])
                finally:
                    c.close()

    def test_legacy_cli_requires_consistent_retained_observations(self):
        cases = {"archive": True, "history": True, "both": True, "prior_data": True,
                 "partial_archive": False, "partial_history": False,
                 "corrupt_history": False, "missing": False}
        for case, eligible in cases.items():
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                database, history = root / "archive.sqlite3", root / "history.json"
                if case in {"archive", "both", "partial_archive"}:
                    c = storage.connect_database(database)
                    try:
                        archive.insert_snapshot(c, self.sample(100, 10000))
                        if case == "partial_archive":
                            archive.insert_snapshot(c, self.sample(500, None, pct=None))
                        c.commit()
                    finally:
                        c.close()
                if case in {"history", "both", "partial_history", "partial_archive"}:
                    rows = [self.sample(100, 10000)]
                    if case == "partial_history":
                        rows.append(self.sample(500, None, pct=None))
                    history.write_text(json.dumps(rows))
                if case == "corrupt_history":
                    history.write_text("invalid JSON")
                prior = self.observe("", 100, 10000,
                                     owner=storage.canonicalize_limit_id("group-a"))[0]
                result = subprocess.run([
                    sys.executable, str(pathlib.Path(weekly_window_start.__file__).with_name("weekly_reset.py")),
                    "", "100", "100", "10000", storage.canonicalize_limit_id("group-a"), "900",
                    "--legacy-archive", str(database), "--legacy-history", str(history),
                    "--legacy-observation", "" if case == "missing" else prior,
                    "--before-epoch", "1000",
                ], check=True, capture_output=True, text=True)
                state = result.stdout.splitlines()[0]
                self.assertEqual(eligible, bool(state))
                state, _event, _pending = self.observe(state, 1000, 13000,
                                                       owner=storage.canonicalize_limit_id("group-a"))
                self.assertEqual(1000 if eligible else 0, self.observe(
                    state, 1900, 13010, owner=storage.canonicalize_limit_id("group-a"),
                )[1])

    def test_legacy_live_proof_is_shared_with_anomalies_without_an_archive_baseline(self):
        for prior_complete in (True, False):
            with self.subTest(prior_complete=prior_complete), tempfile.TemporaryDirectory() as directory:
                c = storage.connect_database(pathlib.Path(directory) / "archive.sqlite3")
                try:
                    anomalies.process_snapshot(c, self.sample(100, 10000))
                    row = c.execute("SELECT state_json FROM anomaly_detector_state WHERE window='weekly'").fetchone()
                    state = json.loads(row[0])
                    state.pop("full_weekly_reset_state")
                    c.execute("UPDATE anomaly_detector_state SET state_json=? WHERE window='weekly'", (json.dumps(state),))
                    proof = self.observe("", 100, 10000,
                                         owner=storage.canonicalize_limit_id("group-a"))[0] if prior_complete else ""
                    for epoch, deadline in ((1000, 13000), (1900, 13010)):
                        anomalies.process_snapshot(c, self.sample(epoch, deadline), legacy_weekly_state=proof)
                    self.assertEqual(0 if prior_complete else 1, c.execute(
                        "SELECT count(*) FROM quota_anomalies WHERE window='weekly' AND anomaly_type='reset_shift'"
                    ).fetchone()[0])
                finally:
                    c.close()


class WeeklyHookTests(unittest.TestCase):
    def run_statuses(self, samples, *, repeat=False):
        clock = {"now": 100, "sample": 0}
        commands = []

        def status(_codex, **kwargs):
            index = clock["sample"]
            pct, reset, owner = samples[min(index, len(samples) - 1)]
            clock["now"] = 100 + index
            clock["sample"] += 1
            self.assertEqual(5, kwargs["timeout_seconds"])
            return dict(scraped_at=dt.datetime.fromtimestamp(clock["now"], dt.timezone.utc).isoformat(),
                        weekly_pct=pct, weekly_reset_at=reset, limit_id=owner)

        def run(command, **kwargs):
            commands.append(command)
            return subprocess.CompletedProcess(command, 0, '{"type":"turn.completed","usage":{"input_tokens":10}}', "")

        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "hook.log"
            environment = {"CODEX_ALERT_EVENT": "reset", "CODEX_ALERT_WINDOW": "weekly",
                           "WEEKLY_START_MAX_ATTEMPTS": "2", "WEEKLY_START_WAIT_SECONDS": "0",
                           "CODEX_ALERT_RESET_AT": "100",
                           "WEEKLY_START_RETRY_WINDOW_SECONDS": "60", "WEEKLY_START_LOG_FILE": str(path)}
            with mock.patch.dict(os.environ, environment, clear=True), \
                    mock.patch.object(weekly_window_start, "run_bounded", side_effect=run), \
                    mock.patch.object(weekly_window_start, "fetch_status", side_effect=status), \
                    mock.patch.object(weekly_window_start.time, "time", side_effect=lambda: clock["now"]), \
                    mock.patch.object(weekly_window_start.time, "sleep"):
                result = weekly_window_start.run_hook()
                if repeat:
                    self.assertEqual(result, weekly_window_start.run_hook())
            return result, path.read_text(), commands

    def test_successful_codex_request_and_future_date_do_not_prove_start(self):
        result, log, commands = self.run_statuses([(100, 10_000, "owner")] * 3, repeat=True)
        self.assertEqual(1, result)
        self.assertIn("unverified", log)
        self.assertEqual(2, sum("exec" in command for command in commands))
        self.assertTrue(all("gpt-6.1-sol" in command for command in commands if "exec" in command))

    def test_packaged_hook_uses_external_runtime_and_retains_budget_across_upgrades(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            runtime, requests = root / "runtime", root / "requests.jsonl"
            codex = root / "fake-codex"
            codex.write_text(
                f"#!{sys.executable}\n"
                "import json,os,pathlib,sys\n"
                "if '--skip-git-repo-check' not in sys.argv: sys.exit(3)\n"
                "cwd=pathlib.Path(sys.argv[sys.argv.index('-C')+1])\n"
                "assert not (cwd/'.git').exists()\n"
                "with open(os.environ['WEEKLY_START_TEST_REQUESTS'],'a') as f: "
                "f.write(json.dumps(sys.argv)+'\\n')\n"
                "print('{\"type\":\"turn.completed\"}')\n"
            )
            codex.chmod(0o700)
            environment = {"CODEX_ALERT_EVENT": "reset", "CODEX_ALERT_WINDOW": "weekly",
                           "CODEX_ALERT_RESET_AT": "100", "CODEX_ALERT_CODEX_BIN": str(codex),
                           "CODEX_MONITOR_RUNTIME_DIR": str(runtime),
                           "WEEKLY_START_MAX_ATTEMPTS": "1", "WEEKLY_START_WAIT_SECONDS": "0",
                           "WEEKLY_START_RETRY_WINDOW_SECONDS": "60",
                           "WEEKLY_START_TEST_REQUESTS": str(requests)}

            def status(*_args, **_kwargs):
                return {"scraped_at": dt.datetime.fromtimestamp(int(time.time()), dt.timezone.utc).isoformat(),
                        "weekly_pct": 100, "weekly_reset_at": int(time.time()) + 10000,
                        "limit_id": "owner"}

            with mock.patch.dict(os.environ, environment, clear=True), \
                    mock.patch.object(weekly_window_start, "fetch_status", side_effect=status):
                for version in ("v1", "v2"):
                    local = root / version / "local"
                    local.mkdir(parents=True)
                    module = local / "weekly_window_start.py"
                    module.touch()
                    local.chmod(0o555)
                    try:
                        with mock.patch.object(weekly_window_start, "__file__", str(module)):
                            self.assertEqual(1, weekly_window_start.run_hook())
                        self.assertFalse((local / "runtime").exists())
                    finally:
                        local.chmod(0o755)
            # The second release retries the same occurrence with the same
            # durable budget, rather than issuing another request.
            commands = [json.loads(line) for line in requests.read_text().splitlines()]
            self.assertEqual(1, len(commands))
            self.assertEqual(str(root / "v1"), commands[0][commands[0].index("-C") + 1])
            log = runtime / "weekly-window-start.log"
            self.assertIn("Codex exit=0", log.read_text())
            self.assertEqual(0o700, runtime.stat().st_mode & 0o777)
            self.assertEqual(0o600, log.stat().st_mode & 0o777)
            receipts = list(runtime.glob(".weekly-window-start-budget-*.json"))
            self.assertEqual(1, len(receipts))
            self.assertEqual(1, json.loads(receipts[0].read_text())["attempts"])

    def test_timeout_reaps_descendant_holding_output_pipes(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_path = pathlib.Path(directory) / "child.pid"
            code = ("import subprocess,sys,time; "
                    "child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); "
                    f"open({str(pid_path)!r},'w').write(str(child.pid)); time.sleep(60)")
            started = time.monotonic()
            with self.assertRaises(subprocess.TimeoutExpired):
                weekly_window_start.run_bounded([sys.executable, "-c", code], timeout=0.5)
            self.assertLess(time.monotonic() - started, 4)
            child = int(pid_path.read_text())
            # A reparented child can briefly remain as a zombie until init
            # reaps it; it must no longer execute or hold the output pipe.
            proc_status = pathlib.Path(f"/proc/{child}/stat")
            if proc_status.exists():
                self.assertEqual("Z", proc_status.read_text().split()[2])

    def test_terminating_hook_reaps_its_separate_request_group(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_path = pathlib.Path(directory) / "child.pid"
            child_code = f"import os,time; open({str(pid_path)!r},'w').write(str(os.getpid())); time.sleep(60)"
            parent_code = ("import sys; sys.path.insert(0, 'local'); "
                           "import weekly_window_start as hook; hook.install_signal_handlers(); "
                           f"hook.run_bounded([sys.executable, '-c', {child_code!r}], timeout=60)")
            root = pathlib.Path(__file__).resolve().parents[1]
            parent = subprocess.Popen([sys.executable, "-c", parent_code], cwd=root,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 4
                while not pid_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(pid_path.exists())
                parent.terminate()
                parent.communicate(timeout=4)
                self.assertEqual(143, parent.returncode)
                child = int(pid_path.read_text())
                proc_status = pathlib.Path(f"/proc/{child}/stat")
                if proc_status.exists():
                    self.assertEqual("Z", proc_status.read_text().split()[2])
            finally:
                if parent.poll() is None:
                    parent.kill()
                    parent.communicate(timeout=2)

    def test_consumption_confirms_active_cycle(self):
        result, log, _ = self.run_statuses([(100, 10_000, "owner"), (99, 10_000, "owner")])
        self.assertEqual(0, result)
        self.assertIn("quota consumption observed", log)

    def test_full_deadline_requires_another_observation(self):
        result, log, _ = self.run_statuses([(100, 10_000, "owner"),
                                           (100, 13_000, "owner"), (100, 13_010, "owner")])
        self.assertEqual(0, result)
        self.assertIn("quota consumption remains unverified", log)

    def test_owner_change_does_not_acknowledge_start(self):
        result, log, _ = self.run_statuses([(100, 10_000, "a"), (99, 13_000, "b")])
        self.assertEqual(1, result)
        self.assertIn("owner changed", log)

    def test_stale_partial_and_nonfinite_evidence_is_rejected(self):
        baseline = {"scraped_at": "1970-01-01T00:01:40Z", "weekly_pct": 100,
                    "weekly_reset_at": 10_000, "limit_id": "a"}
        for changes in ({"weekly_pct": None}, {"weekly_pct": float("nan")},
                        {"weekly_reset_at": True}, {"limit_id": None},
                        {"scraped_at": "1970-01-01T00:00:01Z"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                weekly_window_start.status_evidence({**baseline, **changes}, 100)


if __name__ == "__main__":
    unittest.main()
