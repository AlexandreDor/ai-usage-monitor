"""Start coverage in test subprocesses without modifying the Python install."""

import os
from pathlib import Path

if os.environ.get("COVERAGE_PROCESS_START"):
    import coverage

    # Interpret source=local and relative filenames against the repository,
    # even when a shell test launches a CLI from another working directory.
    working_directory = Path.cwd()
    config_directory = Path(os.environ["COVERAGE_PROCESS_START"]).resolve().parent
    try:
        os.chdir(config_directory)
        coverage.process_startup()
    finally:
        os.chdir(working_directory)
