#!/bin/sh
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
#
# macos-only.sh <name> <command...>: run the command on macOS, and skip with a
# message anywhere else. AutoDJKit needs Apple frameworks (AVFoundation,
# Accelerate, CommonCrypto), so the reusable CI's ubuntu build and test jobs
# pass through here; Xcode Cloud builds the app and runs the tests on macOS.
set -eu

name=${1:?usage: macos-only.sh <name> <command...>}
shift

if [ "$(uname -s)" != Darwin ]; then
  echo "$name: AutoDJKit needs macOS; skipping on $(uname -s) (Xcode Cloud runs it)"
  exit 0
fi

exec "$@"
