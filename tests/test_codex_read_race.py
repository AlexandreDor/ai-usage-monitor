#!/usr/bin/env python3

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / "local"
sys.path.insert(0, str(LOCAL))

import storage
import token_usage


SESSION_ID = "00000000-0000-0000-0000-000000000001"


def record(timestamp, item_type, payload):
    return json.dumps(
        {"timestamp": timestamp, "type": item_type, "payload": payload},
        separators=(",", ":"),
    ) + "\n"


def rollout(*, padded=False, include_final=False):
    metadata = {
        "id": SESSION_ID,
        "model_provider": "openai",
        "originator": "codex_cli",
    }
    if padded:
        metadata["ignored_padding"] = "x" * 2048
    content = (
        record("1970-01-01T00:10:00Z", "session_meta", metadata)
        + record("1970-01-01T00:10:01Z", "turn_context", {"model": "gpt-test"})
        + record(
            "1970-01-01T00:10:02Z",
            "event_msg",
            {
                "type": "token_count",
                "info": {
                    "total_token_usage": {
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "cache_write_input_tokens": 5,
                        "output_tokens": 10,
                        "reasoning_output_tokens": 2,
                    }
                },
            },
        )
    )
    if include_final:
        content += record(
            "1970-01-01T00:10:03Z",
            "event_msg",
            {
                "type": "token_count",
                "info": {
                    "total_token_usage": {
                        "input_tokens": 200,
                        "cached_input_tokens": 50,
                        "cache_write_input_tokens": 10,
                        "output_tokens": 40,
                        "reasoning_output_tokens": 8,
                    }
                },
            },
        )
    return content


class MutatingReader:
    """Apply one filesystem mutation after the collector's first readline."""

    def __init__(self, source, mutate):
        self.source = source
        self.mutate = mutate
        self.mutated = False

    def __enter__(self):
        self.source.__enter__()
        return self

    def __exit__(self, *args):
        return self.source.__exit__(*args)

    def __getattr__(self, name):
        return getattr(self.source, name)

    def readline(self, *args, **kwargs):
        line = self.source.readline(*args, **kwargs)
        if not self.mutated:
            self.mutated = True
            self.mutate()
        return line


class CodexReadRaceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.data_dir = self.root / "codex"
        sessions = self.data_dir / "sessions"
        sessions.mkdir(parents=True)
        self.path = sessions / f"rollout-{SESSION_ID}.jsonl"
        self.database = self.root / "usage.sqlite3"
        self.connection = storage.connect_database(self.database)

    def tearDown(self):
        self.connection.close()
        self.temporary.cleanup()

    def collect(self):
        token_usage.collect_codex(self.connection, self.data_dir, cutoff=0, now=2000)
        self.connection.commit()

    def collect_while(self, mutate):
        real_open = Path.open
        readers = []

        def synchronized_open(path, *args, **kwargs):
            source = real_open(path, *args, **kwargs)
            mode = args[0] if args else kwargs.get("mode", "r")
            if path == self.path and "r" in mode:
                reader = MutatingReader(source, mutate)
                readers.append(reader)
                return reader
            return source

        with mock.patch.object(Path, "open", new=synchronized_open):
            self.collect()
        self.assertEqual(1, len(readers))
        self.assertTrue(readers[0].mutated)

    def assert_complete_once_and_cursor_coherent(self):
        rows = self.connection.execute(
            """
            SELECT input_tokens, cache_read_tokens, cache_write_tokens,
                   output_tokens, reasoning_tokens
            FROM token_usage_events
            WHERE source = 'codex'
            ORDER BY occurred_at_epoch
            """
        ).fetchall()
        self.assertEqual([(75, 20, 5, 10, 2), (65, 30, 5, 30, 6)], rows)

        state_key = f"rollout:{token_usage.rollout_key(self.path)}"
        state = token_usage.read_state(self.connection, "codex", state_key)
        self.assertIsNotNone(state)
        current = self.path.stat()
        self.assertEqual(current.st_size, state["offset"])
        self.assertEqual(current.st_size, state["size"])
        self.assertEqual(current.st_ino, state["inode"])
        self.assertEqual(current.st_dev, state["device"])

    def run_mutation_case(self, mutation):
        initial = rollout(padded=mutation == "truncate")
        final = rollout(include_final=True)
        self.path.write_text(initial, encoding="utf-8")

        if mutation == "append":
            appended = final[len(rollout()):].encode("utf-8")

            def mutate():
                descriptor = os.open(self.path, os.O_WRONLY | os.O_APPEND)
                try:
                    os.write(descriptor, appended)
                finally:
                    os.close(descriptor)

        elif mutation == "truncate":
            encoded = final.encode("utf-8")

            def mutate():
                descriptor = os.open(self.path, os.O_WRONLY | os.O_TRUNC)
                try:
                    os.write(descriptor, encoded)
                finally:
                    os.close(descriptor)

        else:
            replacement = self.path.with_suffix(".replacement")
            replacement.write_text(final, encoding="utf-8")

            def mutate():
                os.replace(replacement, self.path)

        self.collect_while(mutate)

        # A follow-up observes the final identity/size and heals any cursor
        # based on the descriptor that was valid when the race began.
        self.collect()
        self.collect()
        self.assert_complete_once_and_cursor_coherent()

    def test_append_truncate_and_replace_during_read_converge_without_loss(self):
        for mutation in ("append", "truncate", "replace"):
            with self.subTest(mutation=mutation):
                if mutation != "append":
                    self.connection.close()
                    self.database.unlink(missing_ok=True)
                    for suffix in ("-shm", "-wal"):
                        Path(str(self.database) + suffix).unlink(missing_ok=True)
                    self.connection = storage.connect_database(self.database)
                self.run_mutation_case(mutation)


if __name__ == "__main__":
    unittest.main()
