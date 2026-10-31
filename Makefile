# auto-dj — everything lives in mise tasks: the go archetype (build, golangci-lint,
# govulncheck, gotestsum, goreleaser) and the common tasks (license, prose,
# workflow, container and shell lint) come from the shared toolchain submodule
# at .mise/, selected in the root mise.toml, which also carries the CLI tasks
# (status, features, evaluate, plan, review, apply, set). This Makefile is only
# the thin forwarding shim — `make <task>` == `mise run <task>`.
include .mise/archetypes/go/include.mk
