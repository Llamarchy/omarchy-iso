#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DASHBOARD="$ROOT/configs/airootfs/usr/local/bin/omarchy-install-dashboard"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

assert_phase() {
  local expected=$1
  local json=$2
  local actual

  printf '%s\n' "$json" >"$TMPDIR/state.json"
  actual=$(bash "$DASHBOARD" --read-progress-state "$TMPDIR/state.json" | head -1)
  if [[ $actual == $expected ]]; then
    return 0
  else
    echo "Expected phase '$expected', got '$actual' for: $json" >&2
    exit 1
  fi
}

assert_phase "Installing Arch + Omarchy" '{"current_phase":"Installing Arch + Omarchy"}'
assert_phase "Installing Arch + Omarchy" '{"phase":"Installing Arch + Omarchy"}'
assert_phase "Starting installation" '{}'

echo "dashboard state tests passed"
