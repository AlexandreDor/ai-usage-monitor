from __future__ import annotations

import json
import os
from pathlib import Path
import sys


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "local"))

from storage import connect_database
from token_usage import collect_codex


class _ReplacingReader:
    def __init__(self, source, path: Path, replacement: Path) -> None:
        self._source = source
        self._path = path
        self._replacement = replacement
        self._replaced = False

    def __enter__(self):
        self._source.__enter__()
        return self

    def __exit__(self, *args):
        return self._source.__exit__(*args)

    def readline(self, *args):
        line = self._source.readline(*args)
        if not self._replaced:
            os.replace(self._replacement, self._path)
            self._replaced = True
        return line

    def __getattr__(self, name):
        return getattr(self._source, name)


def _line(timestamp: str, event_type: str, payload: dict) -> str:
    return json.dumps({"timestamp": timestamp, "type": event_type, "payload": payload})


def test_atomic_codex_replacement_during_read_is_replayed(tmp_path, monkeypatch):
    data_dir = tmp_path / "codex"
    rollout = data_dir / "sessions" / "rollout-00000000-0000-0000-0000-000000000001.jsonl"
    replacement = tmp_path / "replacement.jsonl"
    data_dir.joinpath("sessions").mkdir(parents=True)

    prefix = [
        _line(
            "1970-01-01T00:10:00Z",
            "session_meta",
            {"id": "00000000-0000-0000-0000-000000000001", "model_provider": "openai"},
        ),
        _line("1970-01-01T00:10:01Z", "turn_context", {"model": "gpt-test"}),
        _line(
            "1970-01-01T00:10:02Z",
            "event_msg",
            {
                "type": "token_count",
                "info": {
                    "total_token_usage": {
                        "input_tokens": 100,
                        "cached_input_tokens": 0,
                        "cache_write_input_tokens": 0,
                        "output_tokens": 10,
                        "reasoning_output_tokens": 2,
                    }
                },
            },
        ),
    ]
    suffix = _line(
        "1970-01-01T00:10:03Z",
        "event_msg",
        {
            "type": "token_count",
            "info": {
                "total_token_usage": {
                    "input_tokens": 160,
                    "cached_input_tokens": 0,
                    "cache_write_input_tokens": 0,
                    "output_tokens": 20,
                    "reasoning_output_tokens": 4,
                }
            },
        },
    )
    rollout.write_text("\n".join(prefix) + "\n", encoding="utf-8")
    replacement.write_text("\n".join(prefix + [suffix]) + "\n", encoding="utf-8")

    original_open = Path.open
    replacement_scheduled = False

    def open_with_replacement(path, *args, **kwargs):
        nonlocal replacement_scheduled
        source = original_open(path, *args, **kwargs)
        if path == rollout and not replacement_scheduled:
            replacement_scheduled = True
            return _ReplacingReader(source, rollout, replacement)
        return source

    monkeypatch.setattr(Path, "open", open_with_replacement)

    database = tmp_path / "usage.sqlite3"
    with connect_database(database) as connection:
        collect_codex(connection, data_dir, cutoff=1, now=2_000)
        connection.commit()
        collect_codex(connection, data_dir, cutoff=1, now=2_001)

        rows = connection.execute(
            """
            SELECT occurred_at_epoch, input_tokens, output_tokens
            FROM token_usage_events
            ORDER BY occurred_at_epoch
            """
        ).fetchall()

    assert rows == [(602, 100, 10), (603, 60, 10)]
