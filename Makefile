# Makefile for Morbstack — COMPATIBILITY SHIM.
#
# The real build system now lives in mise.toml (`mise run <task>` /
# `mise <task>`). This file exists only so callers who still type
# `make build`, `make sign`, etc. keep working unchanged — same artefacts,
# same paths, same exit codes — while the codebase and its docs finish
# moving over to `mise run`. Every target below does nothing but forward to
# the equivalently-named mise task.
#
# New code, docs, CI, and scripts should call `mise run <task>` directly.
# See docs/build.md for the task list and mise.toml for the actual recipes.
# Once nothing references `make` anymore, this file can be deleted.

.PHONY: setup build build-mac build-guest cross-build-guest guest-image sign run-daemon test clean app app-icon run-app clean-app shots-live

setup:
	mise trust
	mise install

build:
	mise run build

build-mac:
	mise run build-mac

build-guest:
	mise run build-guest

cross-build-guest:
	mise run cross-build-guest

guest-image:
	mise run guest-image

sign:
	mise run sign

run-daemon:
	mise run run-daemon

test:
	mise run test

shots-live:
	mise run shots-live

app-icon:
	mise run app-icon

app:
	mise run app

run-app:
	mise run run-app

clean-app:
	mise run clean-app

clean:
	mise run clean
