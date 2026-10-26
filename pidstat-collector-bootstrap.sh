#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log() {
  printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

: "${PIDSTAT_VENV_DIR:=/opt/lintap/pidstat-collector/.venv}"
: "${PIDSTAT_BOOTSTRAP_PYTHON:=3.12}"
: "${PIDSTAT_DUCKDB_SPEC:=duckdb==1.5.6}"

require_command uv

mkdir -p "$(dirname "$PIDSTAT_VENV_DIR")"

log "creating pidstat collector venv at $PIDSTAT_VENV_DIR with $PIDSTAT_BOOTSTRAP_PYTHON"
uv venv --python "$PIDSTAT_BOOTSTRAP_PYTHON" "$PIDSTAT_VENV_DIR"

log "installing $PIDSTAT_DUCKDB_SPEC into $PIDSTAT_VENV_DIR"
uv pip install --python "$PIDSTAT_VENV_DIR/bin/python" "$PIDSTAT_DUCKDB_SPEC"

log "pidstat collector environment ready: $PIDSTAT_VENV_DIR/bin/python"
log "run with: PIDSTAT_VENV_DIR=$PIDSTAT_VENV_DIR $SCRIPT_DIR/pidstat-collector-launch.sh"
