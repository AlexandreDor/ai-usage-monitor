import os
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
import sys

sys.path.insert(0, str(ROOT / "local"))
from config import ConfigError, load_config, parse_env_file, validate_config


class ConfigModuleTests(unittest.TestCase):
    def test_precedence_is_cli_environment_file_then_default(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env_file = root / ".env"
            env_file.write_text(
                "LOOP_INTERVAL=60\nTOKEN_PRICING_FILE=/from-file\n",
                encoding="utf-8",
            )
            values, _warnings = load_config(
                env_file,
                base_dir=ROOT / "local",
                environ={"LOOP_INTERVAL": "120", "HOME": str(root)},
                cli={"LOOP_INTERVAL": "30"},
            )
            self.assertEqual(values["LOOP_INTERVAL"], "30")
            self.assertEqual(values["TOKEN_PRICING_FILE"], "/from-file")
            self.assertEqual(values["CODEX_BIN"], "codex")

    def test_dotenv_is_data_and_does_not_execute_shell_syntax(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "executed"
            env_file = root / ".env"
            env_file.write_text(
                f"CODEX_BIN=$(touch {marker})\nMALICIOUS=$(touch {marker})\n",
                encoding="utf-8",
            )
            values, warnings = parse_env_file(env_file)
            self.assertEqual(values["CODEX_BIN"], f"$(touch {marker})")
            self.assertTrue(any("MALICIOUS" in warning for warning in warnings))
            self.assertFalse(marker.exists())

    def test_validation_reports_invalid_values_without_traceback(self) -> None:
        values, _warnings = load_config(
            ROOT / "local" / ".env.missing",
            base_dir=ROOT / "local",
            environ={"HOME": str(ROOT), "LOOP_INTERVAL": "0"},
        )
        with self.assertRaisesRegex(ConfigError, "LOOP_INTERVAL"):
            validate_config(values, check_paths=False)


if __name__ == "__main__":
    unittest.main()
