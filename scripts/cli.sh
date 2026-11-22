#!/bin/sh
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
#
# Build the release auto-dj CLI from this checkout, then run it with the given
# arguments in the caller's directory (the mise CLI tasks in tasks.toml). The
# build is incremental, so a repeat run starts at once.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$root" --configuration release --product auto-dj >&2
bin="$(swift build --package-path "$root" --configuration release --show-bin-path)"
exec "$bin/auto-dj" "$@"
