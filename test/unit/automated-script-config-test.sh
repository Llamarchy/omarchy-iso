#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/configs/airootfs/root/.automated_script.sh"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

assert_auto_reboot() {
  local expected=$1
  local json=$2

  printf '%s\n' "$json" >"$TMPDIR/config.json"
  actual=$(bash "$SCRIPT" --read-auto-reboot "$TMPDIR/config.json")
  if [[ $actual == $expected ]]; then
    return 0
  else
    echo "Expected auto_reboot=$expected, got $actual for: $json" >&2
    exit 1
  fi
}

assert_auto_reboot false '{"omarchy_install":{"auto_reboot":false}}'
assert_auto_reboot true '{"omarchy_install":{"auto_reboot":true}}'
assert_auto_reboot true '{"omarchy_install":{}}'
assert_auto_reboot true '{}'
assert_auto_reboot true 'not-json'

echo "automated script configuration tests passed"
