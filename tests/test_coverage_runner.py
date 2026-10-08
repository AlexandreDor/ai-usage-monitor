#!/usr/bin/env python3
"""Verify subprocess measurement and failure handling in an isolated suite."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(importlib.util.find_spec("coverage"), "coverage is a CI dependency")
class CoverageRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "fixture"
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "tests").mkdir()
        shutil.copy(ROOT / "scripts/test-coverage.sh", self.root / "scripts")
        shutil.copytree(ROOT / "tests/coverage_bootstrap", self.root / "tests/coverage_bootstrap")
        (self.root / "local").mkdir()
        for module in (ROOT / "local").glob("*.py"):
            shutil.copy(module, self.root / "local")
        # This deliberately tiny fixture measures instrumentation, not the full
        # application's threshold. The production config retains its 60% gate.
        config = (ROOT / ".coveragerc").read_text().replace("fail_under = 60", "fail_under = 0")
        (self.root / ".coveragerc").write_text(config)
        (self.root / "tests/test_fixture.py").write_text(
            "import os, unittest\n"
            "class FixtureTests(unittest.TestCase):\n"
            "    def test_unit_phase(self):\n"
            "        self.assertNotEqual(os.environ.get('FAIL_UNIT'), '1')\n"
        )
        (self.root / "tests/run.sh").write_text(
            "#!/usr/bin/env bash\nset -eu\n"
            "test \"${SKIP_PYTHON_TESTS:-0}\" = 1\n"
            "(cd local && python3 -c 'import os; assert os.path.basename(os.getcwd()) == \"local\"')\n"
            "for module in analytics archive token_usage; do\n"
            "  (cd local && python3 \"$module.py\" --help >/dev/null)\n"
            "done\n"
            "(cd tests && python3 ../local/analytics.py --help >/dev/null)\n"
            "printf 'functional phase completed\\n'\n"
            "exit \"${SHELL_EXIT:-0}\"\n"
        )

    def run_fixture(self, **overrides):
        environment = os.environ.copy()
        for name in ("COVERAGE_PROCESS_START", "COVERAGE_RCFILE", "COVERAGE_FILE", "FAIL_UNIT", "SHELL_EXIT"):
            environment.pop(name, None)
        environment.update(overrides)
        return subprocess.run(
            ["bash", str(self.root / "scripts/test-coverage.sh")],
            cwd=self.temp.name, env=environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60,
        )

    def assert_cli_measured(self):
        data = json.loads((self.root / "coverage/coverage.json").read_text())
        self.assertTrue(all(name.startswith("local/") for name in data["files"]), data["files"].keys())
        for module in ("analytics", "archive", "token_usage"):
            filename = f"local/{module}.py"
            self.assertIn(filename, data["files"])
            measured = data["files"][filename]["executed_lines"]
            self.assertTrue(measured, filename)
            # Reaching the real CLI entry point distinguishes shell subprocess
            # measurement from imports by the unit-test parent.
            lines = (self.root / filename).read_text().splitlines()
            entry = next(index for index, line in enumerate(lines, 1) if line.startswith('if __name__ =='))
            self.assertIn(entry + 1, measured, filename)
            first_import = next(index for index, line in enumerate(lines, 1) if line.startswith('import '))
            self.assertIn(first_import, measured, filename)
        self.assertTrue((self.root / "coverage/coverage.xml").is_file())
        self.assertTrue((self.root / "coverage/report.txt").is_file())
        self.assertTrue((self.root / "coverage/.coverage").is_file())

    def test_shell_cli_processes_are_measured_without_stale_data(self):
        original = b"existing user measurement\n"
        (self.root / ".coverage").write_bytes(original)
        result = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Ran 1 test", result.stdout)
        self.assert_cli_measured()
        self.assertEqual((self.root / ".coverage").read_bytes(), original)
        self.assertEqual(list((self.root / "coverage").glob(".run.*")), [])

    def test_shell_failure_is_preserved_and_reports_are_generated(self):
        result = self.run_fixture(SHELL_EXIT="23")
        self.assertEqual(result.returncode, 23, result.stdout)
        self.assert_cli_measured()

    def test_unit_failure_still_measures_functional_phase(self):
        result = self.run_fixture(FAIL_UNIT="1")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("functional phase completed", result.stdout)
        self.assert_cli_measured()

    def test_coverage_gate_failure_is_preserved(self):
        config = self.root / ".coveragerc"
        config.write_text(config.read_text().replace("fail_under = 0", "fail_under = 100"))
        result = self.run_fixture()
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("Coverage failure", result.stdout)
        self.assert_cli_measured()

    def test_inline_and_spec_imports_start_measurement_but_fixture_helpers_do_not(self):
        import coverage
        data_directory = self.root / 'measurements'
        data_directory.mkdir()
        environment = os.environ.copy()
        environment.update(
            COVERAGE_PROCESS_START=str(self.root / '.coveragerc'),
            COVERAGE_RCFILE=str(self.root / '.coveragerc'),
            COVERAGE_FILE=str(data_directory / '.coverage'),
            PYTHONPATH=str(self.root / 'tests/coverage_bootstrap'),
        )
        def child(code):
            subprocess.run([sys.executable, '-c', code], cwd=self.root / 'tests',
                           env=environment, check=True, capture_output=True, text=True)
        child('import json; assert json.loads("{\\\"value\\\": 1}")["value"] == 1')
        self.assertEqual(list(data_directory.iterdir()), [])
        child('import sys; sys.path.insert(0, "../local"); import archive')
        child('import importlib.util; '
              'spec = importlib.util.spec_from_file_location("fixture_operations", "../local/operations.py"); '
              'module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)')
        measured = {}
        for filename in data_directory.iterdir():
            data = coverage.CoverageData(basename=str(filename))
            data.read()
            for source in data.measured_files():
                measured.setdefault(source, set()).update(data.lines(source) or [])
        for filename in ('local/archive.py', 'local/operations.py'):
            lines = (self.root / filename).read_text().splitlines()
            first_import = next(index for index, line in enumerate(lines, 1) if line.startswith('import '))
            self.assertIn(first_import, measured[filename])


if __name__ == "__main__":
    unittest.main()
