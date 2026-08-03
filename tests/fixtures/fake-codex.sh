#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == app-server && "${2:-}" == --stdio ]] || exit 2
IFS= read -r _initialize
printf '{"id":1,"result":{}}\n'
IFS= read -r _initialized
IFS= read -r _request
python3 - "${FAKE_CODEX_FIXTURE:?}" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(json.dumps({"id": 2, "result": result}))
PY
