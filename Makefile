# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
#
# auto-dj — everything lives in mise tasks: the common tasks (license, prose,
# workflow and shell lint) come from the shared toolchain submodule at .mise/,
# and tasks.toml adds the Swift build, test, fmt and lint, the Xcode gen /
# app-build / app-run and the auto-dj CLI tasks (status, features, evaluate,
# plan, review, apply, set, history, recording, demo, cue). This Makefile is
# only the thin forwarding shim — `make <task>` == `mise run <task>`.
MISE_TASKS += gen app-build app-run status features evaluate plan review apply set history recording demo cue
include .mise/common/include.mk
