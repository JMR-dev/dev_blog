#!/usr/bin/env bash
#
# Runs a command and prints a heartbeat line every 15s until it exits, then
# exits with the command's status.
#
# Why: on the GKE runners' kubernetes backend (`runs-on: ubuntu-*` / `heavy`),
# each step runs over an exec stream from the runner to the job pod, and that
# stream is dropped after roughly 90 seconds without output -- the step then
# fails with "exec in pod ... ended without an exit status ... EOF" while the
# command itself was still running fine. Compiling pulumi-gcp is that quiet.
#
# Usage: scripts/ci-keepalive.sh <command> [args...]
set -euo pipefail

( while sleep 15; do echo "[keepalive] $(date -u +%T) still running: $1"; done ) &
beat=$!
trap 'kill "${beat}" 2>/dev/null || true' EXIT

"$@"
