#!/usr/bin/env bash

# Defensive extraction bounds. Backup limits remain intentionally high enough
# for multi-year local SQLite archives while still rejecting unbounded tar bombs.
# shellcheck disable=SC2034 # This file is sourced by the builder and installer.
RELEASE_ARCHIVE_MAX_BYTES=$((128 * 1024 * 1024))
RELEASE_ARCHIVE_MAX_MEMBERS=10000
RELEASE_ARCHIVE_MAX_MEMBER_BYTES=$((64 * 1024 * 1024))
RELEASE_ARCHIVE_MAX_TOTAL_BYTES=$((256 * 1024 * 1024))

BACKUP_ARCHIVE_MAX_BYTES=$((8 * 1024 * 1024 * 1024))
BACKUP_ARCHIVE_MAX_MEMBERS=100000
BACKUP_ARCHIVE_MAX_MEMBER_BYTES=$((8 * 1024 * 1024 * 1024))
BACKUP_ARCHIVE_MAX_TOTAL_BYTES=$((32 * 1024 * 1024 * 1024))

CHECKSUM_FILE_MAX_BYTES=$((1024 * 1024))
