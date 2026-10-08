"""Start coverage in test subprocesses without modifying the Python install."""

import os
import sys

if os.environ.get("COVERAGE_PROCESS_START"):
    config_directory = os.path.dirname(os.path.realpath(os.environ["COVERAGE_PROCESS_START"]))
    source_directory = os.path.realpath(os.path.join(config_directory, "local")) + os.sep
    measurement_started = False

    def start_for_project_code(event, arguments):
        global measurement_started
        if measurement_started or event != "exec":
            return
        filename = arguments[0].co_filename
        if filename.startswith("<") or not os.path.realpath(filename).startswith(source_directory):
            return
        # CPython raises exec before executing the code object, including CLI
        # scripts and importlib loaders. Start before the first project line,
        # while pure JSON fixture helpers avoid importing the coverage engine.
        measurement_started = True
        working_directory = os.getcwd()
        try:
            os.chdir(config_directory)
            import coverage
            coverage.process_startup()
        finally:
            os.chdir(working_directory)

    sys.addaudithook(start_for_project_code)
