#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$TEST_DIR/test_storage.py"
printf 'PASS: storage migration, WAL contention and integrity tests\n'
