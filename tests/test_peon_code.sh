#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# Syntax-check the scripts under test before running any case file.
for script in "$ROOT/peon-code.sh" "$ROOT/peon-code-web.sh" "$ROOT/install.sh" "$ROOT"/lib/*.sh; do
  bash -n "$script"
done

# Each tests/cases/*.sh file is a standalone run of one topic group. Run them
# all, keep going past a failure, and pass only if every one passed.
status=0
for case_file in "$ROOT"/tests/cases/*.sh; do
  if ! bash "$case_file"; then
    echo "FAIL: $case_file" >&2
    status=1
  fi
done
[ "$status" -eq 0 ] || exit 1
echo "tests: PASS"
