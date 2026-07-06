#!/bin/bash
# Contract tests for the hook surface: silence, exit codes, gate mechanics.
# Sourced by tests/run.sh; uses its assert_* helpers and $REPO_ROOT.

STUB="$REPO_ROOT/hooks/awakent.sh"
SAMPLE_JSON='{"session_id":"test-session-123","hook_event_name":"SessionStart"}'

# Sandbox: the engine writes real state; keep these contract tests off the
# user's ~/.claude/awakent.
AWAKENT_STATE_DIR=$(mktemp -d)
export AWAKENT_STATE_DIR
# Fake-session PIDs are the test shell; pattern must not match it, so
# register invocations reap immediately and never spawn caffeinate here.
export AWAKENT_PROC_PATTERN='claude|node'

# --- TC-001 — stub silent + exit 0 for every invocation shape ---------------

check_stub_invocation() {
  arg="$1"
  label="$2"
  if [ -z "$arg" ]; then
    out=$(echo "$SAMPLE_JSON" | /bin/bash "$STUB" 2>/dev/null)
  else
    out=$(echo "$SAMPLE_JSON" | /bin/bash "$STUB" "$arg" 2>/dev/null)
  fi
  code=$?
  assert_exit 0 "$code" "TC-001 $label exits 0"
  assert_empty "$out" "TC-001 $label stdout empty"
}

test_stub_register()   { check_stub_invocation "register"   "register"; }
test_stub_unregister() { check_stub_invocation "unregister" "unregister"; }
test_stub_touch()      { check_stub_invocation "touch"      "touch"; }
test_stub_unknown()    { check_stub_invocation "bogus"      "unknown-arg"; }
test_stub_noarg()      { check_stub_invocation ""           "no-arg"; }

test_stub_status() {
  # status is the sole stdout-permitted subcommand; every other invocation
  # must stay silent.
  out=$(echo "$SAMPLE_JSON" | /bin/bash "$STUB" status 2>/dev/null)
  assert_exit 0 $? "TC-001 status exits 0"
  case "$out" in
    ''|assertion:*) pass "TC-001 status silent-or-report" ;;
    *) fail "TC-001 status unexpected stdout: $out" ;;
  esac
}

test_stub_large_stdin() {
  # 64KB+ payload must not block the caller or produce stdout.
  out=$(head -c 70000 /dev/zero | tr '\0' 'x' | /bin/bash "$STUB" register 2>/dev/null)
  code=$?
  assert_exit 0 "$code" "TC-001 64KB-stdin exits 0"
  assert_empty "$out" "TC-001 64KB-stdin stdout empty"
}

# --- TC-003 — bash 3.2 rejects 4.x constructs (gate mechanism) --------------

test_bash32_rejects_assoc_arrays() {
  /bin/bash -c 'declare -A m' 2>/dev/null
  assert_nonzero $? "TC-003 declare -A rejected"
}

test_bash32_rejects_lowercase_expansion() {
  # Note: bash 3.2's -n parse ACCEPTS ${v,,}; it fails only at runtime
  # ("bad substitution") — so this gate requires execution, not linting.
  # That is why Gate 2 runs the harness instead of bash -n.
  /bin/bash -c 'v=ABC; echo "${v,,}"' >/dev/null 2>&1
  assert_nonzero $? "TC-003 \${var,,} rejected at runtime"
}

test_bash32_rejects_mapfile() {
  /bin/bash -c 'mapfile -t arr < /dev/null' 2>/dev/null
  assert_nonzero $? "TC-003 mapfile rejected"
}

test_bash_is_major_version_3() {
  major=$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')
  assert_eq "3" "$major" "TC-003 /bin/bash is major version 3"
}

# --- TC-004 — network-primitive grep gate mechanism --------------------------

# Must byte-match the pattern in .github/workflows/ci.yml Gate 3 (anti-drift).
NET_PATTERN='curl|wget|(^|[^a-zA-Z])nc([^a-zA-Z]|$)|/dev/tcp|osascript.*URL'

test_net_grep_pattern_matches_workflow() {
  grep -qF "$NET_PATTERN" "$REPO_ROOT/.github/workflows/ci.yml"
  assert_exit 0 $? "TC-004 workflow Gate 3 uses this exact pattern"
}

test_net_grep_detects_planted_primitives() {
  fixture=$(mktemp -d)
  printf '%s\n' '#!/bin/bash' 'curl http://x' > "$fixture/bad1.sh"
  printf '%s\n' '#!/bin/bash' 'cat < /dev/tcp/h/80' > "$fixture/bad2.sh"
  printf '%s\n' '#!/bin/bash' 'nc host 80' > "$fixture/bad3.sh"
  hits=$(grep -rEl "$NET_PATTERN" "$fixture" | wc -l | tr -d ' ')
  rm -rf "$fixture"
  assert_eq "3" "$hits" "TC-004 all three planted primitives detected (incl. line-start nc)"
}

test_net_grep_no_false_positive_on_nc_substrings() {
  fixture=$(mktemp -d)
  printf '%s\n' '#!/bin/bash' 'sync' 'my_function_call' 'echo encoding' > "$fixture/ok.sh"
  if grep -rEq "$NET_PATTERN" "$fixture"; then rc=1; else rc=0; fi
  rm -rf "$fixture"
  assert_exit 0 "$rc" "TC-004 no false positive on sync/function/encoding"
}

test_net_grep_real_tree_clean() {
  if grep -rEq "$NET_PATTERN" "$REPO_ROOT/hooks" "$REPO_ROOT/commands"; then rc=1; else rc=0; fi
  assert_exit 0 "$rc" "TC-004 hooks/ and commands/ contain no network primitives"
}

# --- TC-005 — manifest parses with required fields ---------------------------

MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"

test_manifest_parses_and_has_fields() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "$MANIFEST" >/dev/null 2>&1
    assert_exit 0 $? "TC-005 manifest is valid JSON (python3)"
  else
    pass "TC-005 python3 absent — JSON parse skipped, grep fallback follows"
  fi
  grep -q '"name": "awakent"' "$MANIFEST"
  assert_exit 0 $? "TC-005 manifest name is awakent"
  grep -Eq '"version": "[0-9]+\.[0-9]+\.[0-9]+"' "$MANIFEST"
  assert_exit 0 $? "TC-005 manifest version is semver"
}

# --- TC-006 — workflow security posture --------------------------------------

WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"

test_workflow_permissions_read_only() {
  grep -A1 '^permissions:' "$WORKFLOW" | grep -q 'contents: read'
  assert_exit 0 $? "TC-006 permissions limited to contents: read"
}

test_workflow_uses_no_secrets() {
  if grep -q 'secrets\.' "$WORKFLOW"; then rc=1; else rc=0; fi
  assert_exit 0 "$rc" "TC-006 no secrets referenced"
}

test_workflow_action_allowlist() {
  bad=$(grep -E '^\s*uses:' "$WORKFLOW" | grep -v 'actions/checkout@v4' | wc -l | tr -d ' ')
  assert_eq "0" "$bad" "TC-006 only actions/checkout@v4 is used"
}
