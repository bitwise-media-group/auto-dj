#!/bin/sh
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
#
# Xcode Cloud runs this once per build, straight after cloning. It runs the
# AutoDJKit tests (synthetic tracks and checked-in fixtures, no Rekordbox)
# first, so a broken cue rule, set planner or recording split fails the build
# before anything is archived. Xcode Cloud has no mise, so this uses Xcode's
# own Swift.
set -eu

cd "$CI_PRIMARY_REPOSITORY_PATH"
xcrun swift --version
xcrun swift test
