#!/usr/bin/env python3
"""Validate release and backup tar archives before extraction."""

import argparse
import pathlib
import sys
import tarfile


def fail(message):
    raise ValueError(message)


def validate_common(path, maximum_bytes, maximum_members, maximum_member_bytes, maximum_total_bytes):
    if path.is_symlink() or not path.is_file():
        fail(f"archive is not a regular non-symlink file: {path}")
    if path.stat().st_size > maximum_bytes:
        fail(f"compressed archive exceeds {maximum_bytes} bytes")
    stream = tarfile.open(path, "r:gz")
    members = []
    total = 0
    seen = set()
    try:
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
    except Exception:
        stream.close()
        raise
    return stream, members, seen


def validate_release(path, limits):
    stream, members, _ = validate_common(path, *limits)
    try:
        roots = {pathlib.PurePosixPath(member.name).parts[0] for member in members}
        if len(roots) != 1:
            fail("release archive must contain exactly one top-level directory")
        root = next(iter(roots))
        if not any(len(pathlib.PurePosixPath(member.name).parts) > 1 for member in members):
            fail("release archive contains no files below its top-level directory")
        return root
    finally:
        stream.close()


def validate_backup(path, limits):
    stream, members, seen = validate_common(path, *limits)
    try:
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
    finally:
        stream.close()


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
