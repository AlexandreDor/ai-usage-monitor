"""Private filesystem helpers for local operational tools."""

from __future__ import annotations

import os
import stat
from pathlib import Path


class UnsafePathError(OSError):
    """A path cannot be used safely by a local operational tool."""


def open_private_directory(path: Path, *, create: bool = False,
                           require_stable_path: bool = False) -> tuple[Path, int]:
    """Open an owned, non-writable-by-others directory without following links.

    Ancestors may be shared (for example /tmp), but every component must be
    an actual directory. Creation is limited to the final component and its
    parent must itself be private. Callers own the returned descriptor.
    Pathname-based consumers can additionally require ancestors that cannot
    be renamed by another user; trusted sticky directories such as /tmp work.
    """
    path = Path(path)
    if ".." in path.parts:
        raise UnsafePathError("unsafe path")
    absolute = path.absolute()
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    descriptor = os.open("/", flags)
    try:
        parts = absolute.parts[1:]
        for index, component in enumerate(parts):
            if require_stable_path:
                _check_stable_ancestor(os.fstat(descriptor))
            try:
                child = os.open(component, flags, dir_fd=descriptor)
            except FileNotFoundError:
                if not create or index != len(parts) - 1:
                    raise
                _check_private(os.fstat(descriptor))
                try:
                    os.mkdir(component, 0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
                child = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        _check_private(os.fstat(descriptor))
        return absolute, descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _check_private(metadata: os.stat_result) -> None:
    if (not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_mode & 0o022):
        raise UnsafePathError("unsafe directory")


def _check_stable_ancestor(metadata: os.stat_result) -> None:
    # A directory owner can change its permissions or rename its children.
    # Sticky shared parents protect entries only from users other than the
    # parent/entry owners, so both owners must be root or the current user.
    if (metadata.st_uid not in (0, os.geteuid())
            or metadata.st_mode & 0o022 and not metadata.st_mode & stat.S_ISVTX):
        raise UnsafePathError("unsafe ancestor")


def open_owned_regular(name: str, directory: int, *, flags: int = os.O_RDONLY) -> int:
    """Open a regular owned file without blocking on a FIFO or following links."""
    descriptor = os.open(
        name, flags | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
        0o600, dir_fd=directory,
    )
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.geteuid()
                or metadata.st_mode & 0o022):
            raise UnsafePathError("unsafe file")
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def validate_archive_path(path: Path, *, require_stable_path: bool = False) -> Path:
    path = Path(path)
    parent, directory = open_private_directory(path.parent, require_stable_path=require_stable_path)
    try:
        descriptor = open_owned_regular(path.name, directory)
        os.close(descriptor)
    finally:
        os.close(directory)
    return parent / path.name
