#!/bin/bash
# awakent test suite entry point.
# bash 3.2 compatible. Run as: /bin/bash tests/run.sh
# Discovers tests/test_*.sh, runs each test_* function, reports to stderr,
# exits non-zero if any assertion fails.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export REPO_ROOT

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""

log() {
  echo "$@" >&2
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  log "FAIL  $CURRENT_TEST: $*"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  log "ok    $CURRENT_TEST: $*"
}

# assert_eq <expected> <actual> <label>
assert_eq() {
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3 (expected '$1', got '$2')"
  fi
}

# assert_empty <value> <label>
assert_empty() {
  if [ -z "$1" ]; then
    pass "$2"
  else
    fail "$2 (expected empty, got '$1')"
  fi
}

# assert_exit <expected_code> <actual_code> <label>
assert_exit() {
  assert_eq "$1" "$2" "$3"
}

# assert_nonzero <actual_code> <label>
assert_nonzero() {
  if [ "$1" -ne 0 ]; then
    pass "$2"
  else
    fail "$2 (expected non-zero exit, got 0)"
  fi
}

run_test_file() {
  test_file="$1"
  # shellcheck source=/dev/null
  . "$test_file"
  # Enumerate and run every function named test_* defined by the file.
  # Process substitution keeps the loop in this shell so counters persist.
  while read -r fn <&9; do
    [ -n "$fn" ] || continue
    CURRENT_TEST="$(basename "$test_file"):$fn"
    # /dev/null stdin: a test invoking the engine without its own stdin
    # redirect must never consume this loop's function-list stream (fd 9).
    "$fn" < /dev/null
    unset -f "$fn"
  done 9< <(declare -F | awk '{print $3}' | grep '^test_')
}

FILE_COUNT=0
for f in "$TESTS_DIR"/test_*.sh; do
  [ -e "$f" ] || continue
  FILE_COUNT=$((FILE_COUNT + 1))
  run_test_file "$f"
done

log "----"
log "awakent tests: $PASS_COUNT passed, $FAIL_COUNT failed across $FILE_COUNT file(s)"

if [ "$FAIL_COUNT" -ne 0 ] || [ "$FILE_COUNT" -eq 0 ]; then
  exit 1
fi
exit 0
