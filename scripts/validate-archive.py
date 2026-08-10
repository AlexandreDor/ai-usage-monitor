#!/usr/bin/env python3
"""Validate release and backup tar archives before extraction."""

import argparse
import gzip
import pathlib
import sys
import tarfile


_ARCHIVE_BLOCK_BYTES = 512
_MAX_ARCHIVE_OVERHEAD_BYTES = 64 * 1024 * 1024


class BoundedReader:
    """Expose at most a bounded amount of decompressed archive data."""

    def __init__(self, source, maximum_bytes):
        self._source = source
        self._maximum_bytes = maximum_bytes
        self._read_bytes = 0
        self._closed = False

    def __enter__(self):
        return self

    def __exit__(self, _exception_type, _exception, _traceback):
        self.close()

    def close(self):
        if not self._closed:
            self._closed = True
            self._source.close()

    def tell(self):
        return self._read_bytes

    def read(self, size=-1):
        if self._closed:
            raise ValueError("I/O operation on closed archive stream")
        if size == 0:
            return b""
        if size is None or size < 0:
            size = self._maximum_bytes - self._read_bytes
        else:
            size = min(size, self._maximum_bytes - self._read_bytes)
        if size <= 0:
            # Probe one byte so a truncated-looking stream cannot hide data
            # beyond the defensive budget.
            if self._source.read(1):
                raise tarfile.ReadError("decompressed archive exceeds stream budget")
            return b""
        data = self._source.read(size)
        self._read_bytes += len(data)
        return data


def _stream_budget(maximum_members, maximum_total_bytes):
    if maximum_members < 0 or maximum_total_bytes < 0:
        fail("archive limits must not be negative")
    # Reserve headers, padding, and one bounded extension block per possible
    # member. PAX and GNU metadata share this reserve; it cannot grow with a
    # metadata size declared inside an archive header.
    structural_overhead = (maximum_members + 2) * _ARCHIVE_BLOCK_BYTES * 4
    overhead = min(structural_overhead, _MAX_ARCHIVE_OVERHEAD_BYTES)
    return maximum_total_bytes + overhead


def fail(message):
    raise ValueError(message)


def validate_common(path, maximum_bytes, maximum_members, maximum_member_bytes, maximum_total_bytes):
    if path.is_symlink() or not path.is_file():
        fail(f"archive is not a regular non-symlink file: {path}")
    if path.stat().st_size > maximum_bytes:
        fail(f"compressed archive exceeds {maximum_bytes} bytes")
    members = []
    total = 0
    seen = set()
    stream_budget = _stream_budget(maximum_members, maximum_total_bytes)
    with path.open("rb") as compressed:
        with gzip.GzipFile(fileobj=compressed, mode="rb") as decompressed:
            with BoundedReader(decompressed, stream_budget) as bounded:
                with tarfile.open(fileobj=bounded, mode="r|") as stream:
                    for member in stream:
                        if len(members) >= maximum_members:
                            fail(f"archive contains more than {maximum_members} members")
                        members.append(member)
                        member_path = pathlib.PurePosixPath(member.name)
                        if (
                            member_path.is_absolute()
                            or not member_path.parts
                            or any(part in ("", ".", "..") for part in member_path.parts)
                        ):
                            fail(f"unsafe archive path: {member.name}")
                        normalized = str(member_path)
                        if normalized in seen:
                            fail(f"duplicate archive path: {member.name}")
                        seen.add(normalized)
                        if not (member.isdir() or member.isreg()):
                            fail(f"archive contains a link or special file: {member.name}")
                        if member.isreg():
                            if member.size < 0 or member.size > maximum_member_bytes:
                                fail(f"archive member exceeds {maximum_member_bytes} bytes: {member.name}")
                            total += member.size
                            if total > maximum_total_bytes:
                                fail(f"archive payload exceeds {maximum_total_bytes} bytes")
                    if not members:
                        fail("archive is empty")
    return members, seen


def validate_release(path, limits):
    members, _ = validate_common(path, *limits)
    roots = {pathlib.PurePosixPath(member.name).parts[0] for member in members}
    if len(roots) != 1:
        fail("release archive must contain exactly one top-level directory")
    root = next(iter(roots))
    if not any(len(pathlib.PurePosixPath(member.name).parts) > 1 for member in members):
        fail("release archive contains no files below its top-level directory")
    return root


def validate_backup(path, limits):
    members, seen = validate_common(path, *limits)
    roots = set()
    for member in members:
        member_path = pathlib.PurePosixPath(member.name)
        if member_path.parts[0] not in ("config", "state"):
            fail(f"backup path is outside config/state: {member.name}")
        roots.add(member_path.parts[0])
        if len(member_path.parts) == 1 and not member.isdir():
            fail(f"backup root must be a directory: {member.name}")
    if roots != {"config", "state"} or not {"config", "state"}.issubset(seen):
        fail("backup must contain only config and state trees")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=("release", "backup"))
    parser.add_argument("archive", type=pathlib.Path)
    parser.add_argument("maximum_bytes", type=int)
    parser.add_argument("maximum_members", type=int)
    parser.add_argument("maximum_member_bytes", type=int)
    parser.add_argument("maximum_total_bytes", type=int)
    arguments = parser.parse_args()
    limits = (
        arguments.maximum_bytes,
        arguments.maximum_members,
        arguments.maximum_member_bytes,
        arguments.maximum_total_bytes,
    )
    try:
        if arguments.kind == "release":
            print(validate_release(arguments.archive, limits))
        else:
            validate_backup(arguments.archive, limits)
    except (OSError, tarfile.TarError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
