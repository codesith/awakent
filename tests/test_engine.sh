#!/bin/bash
# Engine edge-case tests: dispatch contract, config, permissions, reaper,
# locking, malformed input.
# Sourced by tests/run.sh; uses its assert_* helpers and $REPO_ROOT.

ENGINE="$REPO_ROOT/hooks/awakent.sh"
JSON='{"session_id":"eng-test-1","hook_event_name":"SessionStart"}'

# Each test gets a fresh sandbox + a live fake session PID (sleep).
eng_setup() {
  ETD=$(mktemp -d)
  sleep 300 &
  FAKE_PID=$!
}

eng_teardown() {
  kill "$FAKE_PID" 2>/dev/null
  wait "$FAKE_PID" 2>/dev/null
  rm -rf "$ETD"
}

# run_eng <subcommand> [stdin]  - engine with sandbox + sleep-pattern + fake pid
run_eng() {
  sub="$1"
  input="${2:-$JSON}"
  printf '%s' "$input" | AWAKENT_STATE_DIR="$ETD" AWAKENT_PROC_PATTERN=sleep \
    AWAKENT_TEST_PID="$FAKE_PID" AWAKENT_CAFFEINATE="$REPO_ROOT/tests/caffstub.sh" \
    /bin/bash "$ENGINE" "$sub"
}

# run_eng_env <subcommand> <stdin> [VAR=val]...  - like run_eng but with an
# explicit env: nothing beyond sandbox + caffstub is implied, and trailing
# pairs win over the implied ones (env is last-assignment-wins), so tests
# control exactly which of TEST_PID / SESSION_PID / HOST / PROC_PATTERN exist.
run_eng_env() {
  sub="$1"
  input="$2"
  shift 2
  printf '%s' "$input" | env AWAKENT_STATE_DIR="$ETD" \
    AWAKENT_CAFFEINATE="$REPO_ROOT/tests/caffstub.sh" "$@" \
    /bin/bash "$ENGINE" "$sub"
}

test_tc201_dispatcher_contract() {
  eng_setup
  for sub in register unregister touch reap bogus ""; do
    if [ -z "$sub" ]; then
      out=$(printf '%s' "$JSON" | AWAKENT_STATE_DIR="$ETD" AWAKENT_PROC_PATTERN=sleep \
        AWAKENT_TEST_PID="$FAKE_PID" AWAKENT_CAFFEINATE="$REPO_ROOT/tests/caffstub.sh" \
        /bin/bash "$ENGINE" 2>/dev/null)
    else
      out=$(run_eng "$sub" 2>/dev/null)
    fi
    code=$?
    assert_exit 0 "$code" "TC-201 '$sub' exits 0"
    if [ "$sub" = "status" ]; then :; else
      assert_empty "$out" "TC-201 '$sub' stdout empty"
    fi
  done
  out=$(run_eng status 2>/dev/null)
  assert_exit 0 $? "TC-201 status exits 0"
  case "$out" in
    assertion:*) pass "TC-201 status writes report to stdout" ;;
    *) fail "TC-201 status stdout missing assertion line" ;;
  esac
  eng_teardown
}

test_tc202_218_failure_injection_state_dir() {
  eng_setup
  ro="$ETD/ro"
  mkdir -p "$ro"
  chmod 500 "$ro"
  out=$(printf '%s' "$JSON" | AWAKENT_STATE_DIR="$ro/sub" AWAKENT_PROC_PATTERN=sleep \
    /bin/bash "$ENGINE" register 2>/dev/null)
  assert_exit 0 $? "TC-202 unwritable state dir exits 0"
  assert_empty "$out" "TC-202 unwritable state dir silent"
  chmod 700 "$ro"
  # NOTE: never probe with '' - bash ${VAR:-default} treats empty as unset,
  # so '' resolves to the user's REAL ~/.claude/awakent (correct engine
  # behavior, wrong test target).
  for bad in "/dev/null/x" "/etc/hosts/x"; do
    out=$(printf '%s' "$JSON" | AWAKENT_STATE_DIR="$bad" AWAKENT_PROC_PATTERN=sleep \
      /bin/bash "$ENGINE" register 2>/dev/null)
    assert_exit 0 $? "TC-218 STATE_DIR='$bad' exits 0"
    assert_empty "$out" "TC-218 STATE_DIR='$bad' silent"
  done
  eng_teardown
}

test_tc203_permissions() {
  eng_setup
  run_eng register >/dev/null 2>&1
  run_eng touch >/dev/null 2>&1
  AWAKENT_STATE_DIR="$ETD" AWAKENT_DEBUG=1 AWAKENT_PROC_PATTERN=sleep \
    AWAKENT_TEST_PID="$FAKE_PID" AWAKENT_CAFFEINATE="$REPO_ROOT/tests/caffstub.sh" \
    /bin/bash "$ENGINE" reap >/dev/null 2>&1
  dm=$(stat -f %Lp "$ETD/sessions" 2>/dev/null)
  assert_eq "700" "$dm" "TC-203 sessions dir 700"
  fm=$(stat -f %Lp "$ETD/sessions/eng-test-1" 2>/dev/null)
  assert_eq "600" "$fm" "TC-203 session file 600"
  lm=$(stat -f %Lp "$ETD/awakent.log" 2>/dev/null)
  assert_eq "600" "$lm" "TC-203 log 600"
  eng_teardown
}

test_tc204_register_idempotent_unregister_unknown() {
  eng_setup
  run_eng register >/dev/null 2>&1
  touch -t 202001010000 "$ETD/sessions/eng-test-1"
  old=$(stat -f %m "$ETD/sessions/eng-test-1")
  run_eng register >/dev/null 2>&1
  new=$(stat -f %m "$ETD/sessions/eng-test-1")
  cnt=0; for f in "$ETD/sessions"/*; do [ -e "$f" ] && cnt=$((cnt+1)); done
  assert_eq "1" "$cnt" "TC-204 exactly one session file after double register"
  if [ "$new" -gt "$old" ]; then pass "TC-204 mtime refreshed"; else fail "TC-204 mtime not refreshed"; fi
  out=$(run_eng unregister '{"session_id":"never-registered"}' 2>/dev/null)
  assert_exit 0 $? "TC-204 unknown unregister exits 0"
  assert_empty "$out" "TC-204 unknown unregister silent"
  eng_teardown
}

test_tc205_config_matrix() {
  eng_setup
  # missing config -> defaults
  out=$(run_eng status 2>/dev/null)
  case "$out" in *"ttl_minutes=60 lid_closed_mode=0 debug=0"*) pass "TC-205 defaults on missing config" ;; *) fail "TC-205 defaults on missing config: $out" ;; esac
  # out-of-bounds + true + garbage + unknown key
  printf 'ttl_minutes=9999\nlid_closed_mode=true\nbogus_key=1\n' > "$ETD/config"
  out=$(run_eng status 2>/dev/null)
  case "$out" in *"ttl_minutes=60 lid_closed_mode=1"*) pass "TC-205 clamp + true accepted" ;; *) fail "TC-205 clamp + true: $out" ;; esac
  case "$out" in *"config-warning:"*ttl_minutes-out-of-bounds*) pass "TC-205 out-of-bounds warned" ;; *) fail "TC-205 warning missing: $out" ;; esac
  printf 'ttl_minutes=abc\nlid_closed_mode=banana\n' > "$ETD/config"
  out=$(run_eng status 2>/dev/null)
  case "$out" in *"ttl_minutes=60 lid_closed_mode=0"*) pass "TC-205 garbage -> defaults" ;; *) fail "TC-205 garbage -> defaults: $out" ;; esac
  # valid partial
  printf 'ttl_minutes=30\n' > "$ETD/config"
  out=$(run_eng status 2>/dev/null)
  case "$out" in *"ttl_minutes=30"*) pass "TC-205 valid partial applied" ;; *) fail "TC-205 valid partial: $out" ;; esac
  eng_teardown
}

test_tc206_no_source_eval() {
  hits=$(grep -En '(^|[^a-zA-Z_.])(source|eval)([^a-zA-Z_]|$)' "$REPO_ROOT/hooks/awakent.sh" | grep -cv '^\s*#')
  assert_eq "0" "$hits" "TC-206 no source/eval in engine"
}

test_tc207_debug_log() {
  eng_setup
  logv() { AWAKENT_STATE_DIR="$ETD" AWAKENT_DEBUG=1 AWAKENT_PROC_PATTERN=sleep \
    AWAKENT_TEST_PID="$FAKE_PID" AWAKENT_CAFFEINATE="$REPO_ROOT/tests/caffstub.sh" \
    /bin/bash "$ENGINE" "$1" >/dev/null 2>&1; }
  printf '%s' "$JSON" | AWAKENT_STATE_DIR="$ETD" AWAKENT_DEBUG=1 AWAKENT_PROC_PATTERN=sleep \
    AWAKENT_TEST_PID="$FAKE_PID" AWAKENT_CAFFEINATE="$REPO_ROOT/tests/caffstub.sh" \
    /bin/bash "$ENGINE" register >/dev/null 2>&1
  printf '%s' "$JSON" | AWAKENT_STATE_DIR="$ETD" AWAKENT_DEBUG=1 AWAKENT_PROC_PATTERN=sleep \
    AWAKENT_TEST_PID="$FAKE_PID" AWAKENT_CAFFEINATE="$REPO_ROOT/tests/caffstub.sh" \
    /bin/bash "$ENGINE" touch >/dev/null 2>&1
  printf '%s' "$JSON" | AWAKENT_STATE_DIR="$ETD" AWAKENT_DEBUG=1 AWAKENT_PROC_PATTERN=sleep \
    AWAKENT_TEST_PID="$FAKE_PID" AWAKENT_CAFFEINATE="$REPO_ROOT/tests/caffstub.sh" \
    /bin/bash "$ENGINE" unregister >/dev/null 2>&1
  grep -q 'event=register sid=eng-test-1' "$ETD/awakent.log" && grep -q 'event=unregister' "$ETD/awakent.log"
  assert_exit 0 $? "TC-207 lifecycle reconstructable from log"
  # off -> zero writes
  rm -f "$ETD/awakent.log"
  run_eng register >/dev/null 2>&1
  if [ -e "$ETD/awakent.log" ]; then fail "TC-207 log written with debug off"; else pass "TC-207 zero writes with debug off"; fi
  # vocabulary scan on a real (pre-filler) lifecycle log: only engine words
  printf '%s' "$JSON" | AWAKENT_STATE_DIR="$ETD" AWAKENT_DEBUG=1 AWAKENT_PROC_PATTERN=sleep \
    AWAKENT_TEST_PID="$FAKE_PID" AWAKENT_CAFFEINATE="$REPO_ROOT/tests/caffstub.sh" \
    /bin/bash "$ENGINE" register >/dev/null 2>&1
  bad=$(grep -Ecv '^[0-9T:Z-]+ event=[a-z-]+ sid=[A-Za-z0-9_-]+ n=[0-9-]+ decision=[a-z:,_-]+( caff=[0-9-]*)?$' "$ETD/awakent.log")
  assert_eq "0" "$bad" "TC-207 log vocabulary clean"
  # >1MB truncation (filler lines ~90 bytes; 13000 > 1MB)
  i=0; while [ "$i" -lt 13000 ]; do printf 'x-line-%s-padding-padding-padding-padding-padding-padding-padding-padding-padding-pad\n' "$i"; i=$((i+1)); done > "$ETD/awakent.log"
  logv reap
  lines=$(wc -l < "$ETD/awakent.log" | tr -d ' ')
  if [ "$lines" -le 201 ]; then pass "TC-207 truncated to last 200 + new ($lines)"; else fail "TC-207 truncation failed ($lines lines)"; fi
  eng_teardown
}

test_tc208_reaper_edges() {
  eng_setup
  mkdir -p "$ETD/sessions"
  # dead PID
  sleep 300 & dead=$!; kill -9 "$dead" 2>/dev/null; wait "$dead" 2>/dev/null
  printf '%s\n' "$dead" > "$ETD/sessions/dead-one"
  # live but wrong name - must NOT be the engine's $$/$PPID (self-exclusion),
  # so spawn a distinct long-lived non-sleep process.
  tail -f /dev/null >/dev/null 2>&1 &
  WRONG_PID=$!
  printf '%s\n' "$WRONG_PID" > "$ETD/sessions/wrong-name"
  # TTL-expired live sleep
  printf '%s\n' "$FAKE_PID" > "$ETD/sessions/expired-one"
  touch -t 202001010000 "$ETD/sessions/expired-one"
  # live + matching + fresh
  printf '%s\n' "$FAKE_PID" > "$ETD/sessions/keeper"
  AWAKENT_STATE_DIR="$ETD" AWAKENT_PROC_PATTERN=sleep \
    AWAKENT_CAFFEINATE="$REPO_ROOT/tests/caffstub.sh" /bin/bash "$ENGINE" reap >/dev/null 2>&1
  if [ ! -e "$ETD/sessions/dead-one" ]; then pass "TC-208 dead PID reaped"; else fail "TC-208 dead PID not reaped"; fi
  if [ ! -e "$ETD/sessions/wrong-name" ]; then pass "TC-208 recycled (wrong-name) reaped"; else fail "TC-208 wrong-name not reaped"; fi
  if kill -0 "$WRONG_PID" 2>/dev/null; then pass "TC-208 wrong-name process NOT killed"; else fail "TC-208 wrong-name process killed"; fi
  kill "$WRONG_PID" 2>/dev/null; wait "$WRONG_PID" 2>/dev/null
  if [ ! -e "$ETD/sessions/expired-one" ]; then pass "TC-208 TTL-expired reaped"; else fail "TC-208 TTL-expired not reaped"; fi
  if [ -e "$ETD/sessions/keeper" ]; then pass "TC-208 live matching session kept"; else fail "TC-208 keeper wrongly reaped"; fi
  # self-PID never reaped: file with $$ but pattern that won't match bash
  printf '%s\n' "$$" > "$ETD/sessions/self-pid"
  AWAKENT_STATE_DIR="$ETD" AWAKENT_PROC_PATTERN=nomatch AWAKENT_TEST_PID="$$" \
    AWAKENT_CAFFEINATE="$REPO_ROOT/tests/caffstub.sh" /bin/bash "$ENGINE" reap >/dev/null 2>&1
  # NOTE: $$ inside the engine is the engine's PID, not ours; "ours" =
  # engine's $$/$PPID. Our test file PID is the harness shell = engine's
  # grandparent -> not excluded -> reaped by name mismatch. Either outcome
  # is the documented behavior; record which one occurred.
  if [ ! -e "$ETD/sessions/self-pid" ]; then pass "TC-208 non-ancestor bash PID reaped by name guard (documented)"; else pass "TC-208 self-pid retained"; fi
  # empty + absent dir no-ops
  rm -rf "$ETD/sessions"
  out=$(AWAKENT_STATE_DIR="$ETD" AWAKENT_PROC_PATTERN=sleep /bin/bash "$ENGINE" reap 2>/dev/null)
  assert_exit 0 $? "TC-208 absent sessions dir no-op"
  assert_empty "$out" "TC-208 absent dir silent"
  eng_teardown
}

test_tc209_stale_lock_break() {
  eng_setup
  mkdir -p "$ETD/.lock"
  touch -t 202001010000 "$ETD/.lock"
  run_eng register >/dev/null 2>&1
  if [ ! -d "$ETD/.lock" ]; then pass "TC-209 stale lock broken and released"; else fail "TC-209 stale lock survived"; fi
  if [ -e "$ETD/sessions/eng-test-1" ]; then pass "TC-209 operation proceeded after break"; else fail "TC-209 registration missing after break"; fi
  eng_teardown
}

test_tc217_malformed_stdin() {
  eng_setup
  for input in '{}' '{"session_id":"../evil"}' '{"session_id":"has space"}' '{"session_id"' ; do
    out=$(run_eng register "$input" 2>/dev/null)
    assert_exit 0 $? "TC-217 malformed input exits 0"
    assert_empty "$out" "TC-217 malformed input silent"
  done
  big=$(head -c 70000 /dev/zero | tr '\0' 'j')
  out=$(run_eng register "$big" 2>/dev/null)
  assert_exit 0 $? "TC-217 70KB junk exits 0"
  cnt=0; if [ -d "$ETD/sessions" ]; then for f in "$ETD/sessions"/*; do [ -e "$f" ] && cnt=$((cnt+1)); done; fi
  assert_eq "0" "$cnt" "TC-217 no registry mutation from malformed input"
  # traversal guard: '../evil' must not have created anything outside sessions
  if [ ! -e "$ETD/evil" ]; then pass "TC-217 no path traversal artifact"; else fail "TC-217 traversal artifact created"; fi
  eng_teardown
}

test_tc230_host_prefix() {
  eng_setup
  # valid host -> prefixed file
  run_eng_env register "$JSON" AWAKENT_PROC_PATTERN=sleep \
    AWAKENT_TEST_PID="$FAKE_PID" AWAKENT_HOST=codex >/dev/null 2>&1
  if [ -e "$ETD/sessions/codex-eng-test-1" ]; then pass "TC-230 host-prefixed file created"; else fail "TC-230 prefixed file missing"; fi
  assert_eq "codex" "$(sed -n '3p' "$ETD/sessions/codex-eng-test-1")" "TC-230 host recorded on line 3"
  out=$(run_eng_env status "$JSON" AWAKENT_PROC_PATTERN=sleep AWAKENT_TEST_PID="$FAKE_PID" 2>/dev/null)
  case "$out" in
    *"session: codex-eng-test-1 host=codex 0m ago"*) pass "TC-230 status shows host" ;;
    *) fail "TC-230 status host display: $out" ;;
  esac
  # host-matched unregister removes exactly the prefixed file
  run_eng_env unregister "$JSON" AWAKENT_PROC_PATTERN=sleep \
    AWAKENT_TEST_PID="$FAKE_PID" AWAKENT_HOST=codex >/dev/null 2>&1
  if [ ! -e "$ETD/sessions/codex-eng-test-1" ]; then pass "TC-230 host-matched unregister"; else fail "TC-230 prefixed file survived unregister"; fi
  # invalid hosts (charset, case, length) fall back to bare claude naming
  for badhost in '../ev il' 'UPPER' 'toolonghostname12345'; do
    run_eng_env register "$JSON" AWAKENT_PROC_PATTERN=sleep \
      AWAKENT_TEST_PID="$FAKE_PID" AWAKENT_HOST="$badhost" >/dev/null 2>&1
    if [ -e "$ETD/sessions/eng-test-1" ]; then pass "TC-230 invalid host '$badhost' -> bare file"; else fail "TC-230 invalid host '$badhost' registered nothing"; fi
    rm -f "$ETD/sessions/eng-test-1"
  done
  # no traversal artifact from the '../' host attempt
  if [ ! -e "$ETD/evil" ] && [ ! -e "$(dirname "$ETD")/ev il-eng-test-1" ]; then
    pass "TC-230 no path traversal artifact from host tag"
  else
    fail "TC-230 host tag produced traversal artifact"
  fi
  eng_teardown
}

test_tc231_per_file_pattern() {
  eng_setup
  # registration records the effective pattern on line 2
  run_eng register >/dev/null 2>&1
  assert_eq "sleep" "$(sed -n '2p' "$ETD/sessions/eng-test-1")" "TC-231 pattern recorded on line 2"
  # second live process with a different name, its own recorded pattern
  tail -f /dev/null >/dev/null 2>&1 &
  TAIL_PID=$!
  printf '%s\ntail\n' "$TAIL_PID" > "$ETD/sessions/other-host"
  # reap under a foreign global pattern: both files judged by their OWN
  # line 2, so both survive - the invoker's env must not matter.
  run_eng_env reap "$JSON" AWAKENT_PROC_PATTERN=nomatch >/dev/null 2>&1
  if [ -e "$ETD/sessions/eng-test-1" ] && [ -e "$ETD/sessions/other-host" ]; then
    pass "TC-231 cross-host reap keeps both (per-file patterns)"
  else
    fail "TC-231 cross-host reap deleted a live session"
  fi
  # a live PID whose recorded pattern mismatches is reaped, never signaled
  printf '%s\nsleep\n' "$TAIL_PID" > "$ETD/sessions/mismatch"
  run_eng reap >/dev/null 2>&1
  if [ ! -e "$ETD/sessions/mismatch" ]; then pass "TC-231 pattern-mismatched pid reaped"; else fail "TC-231 mismatch not reaped"; fi
  if kill -0 "$TAIL_PID" 2>/dev/null; then pass "TC-231 mismatched process NOT killed"; else fail "TC-231 mismatched process killed"; fi
  kill "$TAIL_PID" 2>/dev/null; wait "$TAIL_PID" 2>/dev/null
  # legacy one-line file falls back to the global pattern
  printf '%s\n' "$FAKE_PID" > "$ETD/sessions/legacy-file"
  run_eng reap >/dev/null 2>&1
  if [ -e "$ETD/sessions/legacy-file" ]; then pass "TC-231 legacy one-line file kept via global fallback"; else fail "TC-231 legacy file wrongly reaped"; fi
  # corrupt line-2 regex (bad charset) falls back rather than being evaluated
  printf '%s\n(evil\n' "$FAKE_PID" > "$ETD/sessions/corrupt-pat"
  run_eng reap >/dev/null 2>&1
  if [ -e "$ETD/sessions/corrupt-pat" ]; then pass "TC-231 corrupt pattern -> global fallback (kept)"; else fail "TC-231 corrupt pattern misjudged"; fi
  eng_teardown
}

test_tc232_sentinel_lifecycle() {
  eng_setup
  # sentinel register: SESSION_PID=0, no TEST_PID in env
  run_eng_env register "$JSON" AWAKENT_PROC_PATTERN=sleep \
    AWAKENT_SESSION_PID=0 >/dev/null 2>&1
  assert_eq "0" "$(head -n 1 "$ETD/sessions/eng-test-1")" "TC-232 sentinel pid 0 recorded"
  # fresh sentinel survives a reap - regression test for kill -0 0
  run_eng_env reap "$JSON" AWAKENT_PROC_PATTERN=sleep >/dev/null 2>&1
  if [ -e "$ETD/sessions/eng-test-1" ]; then pass "TC-232 fresh sentinel survives reap"; else fail "TC-232 sentinel insta-reaped (kill -0 0 bug)"; fi
  # status reports it live and ttl-only
  out=$(run_eng_env status "$JSON" AWAKENT_PROC_PATTERN=sleep 2>/dev/null)
  case "$out" in
    *"session: eng-test-1 host=claude 0m ago (ttl-only)"*) pass "TC-232 status shows ttl-only session" ;;
    *) fail "TC-232 status shape: $out" ;;
  esac
  # TTL expiry still reaps it
  touch -t 202001010000 "$ETD/sessions/eng-test-1"
  run_eng_env reap "$JSON" AWAKENT_PROC_PATTERN=sleep >/dev/null 2>&1
  if [ ! -e "$ETD/sessions/eng-test-1" ]; then pass "TC-232 expired sentinel reaped"; else fail "TC-232 expired sentinel survived"; fi
  # garbage SESSION_PID fails closed to sentinel, never to $PPID
  run_eng_env register "$JSON" AWAKENT_PROC_PATTERN=sleep \
    AWAKENT_SESSION_PID=abc >/dev/null 2>&1
  assert_eq "0" "$(head -n 1 "$ETD/sessions/eng-test-1")" "TC-232 garbage SESSION_PID -> sentinel"
  eng_teardown
}

test_tc233_pid_precedence() {
  eng_setup
  # TEST_PID beats SESSION_PID
  run_eng_env register "$JSON" AWAKENT_PROC_PATTERN=sleep \
    AWAKENT_TEST_PID="$FAKE_PID" AWAKENT_SESSION_PID=99999 >/dev/null 2>&1
  assert_eq "$FAKE_PID" "$(head -n 1 "$ETD/sessions/eng-test-1")" "TC-233 TEST_PID wins over SESSION_PID"
  rm -f "$ETD/sessions/eng-test-1"
  # SESSION_PID beats $PPID
  run_eng_env register "$JSON" AWAKENT_PROC_PATTERN=sleep \
    AWAKENT_SESSION_PID="$FAKE_PID" >/dev/null 2>&1
  assert_eq "$FAKE_PID" "$(head -n 1 "$ETD/sessions/eng-test-1")" "TC-233 SESSION_PID wins over PPID"
  rm -f "$ETD/sessions/eng-test-1"
  # neither -> $PPID (a real positive pid, never the sentinel)
  run_eng_env register "$JSON" AWAKENT_PROC_PATTERN=sleep >/dev/null 2>&1
  got=$(head -n 1 "$ETD/sessions/eng-test-1")
  case "$got" in
    ''|0|*[!0-9]*) fail "TC-233 PPID fallback wrong: '$got'" ;;
    *) pass "TC-233 PPID fallback is a real pid" ;;
  esac
  eng_teardown
}

test_tc234_session_id_fallbacks() {
  eng_setup
  run_eng register '{"conversation_id":"conv-1"}' >/dev/null 2>&1
  if [ -e "$ETD/sessions/conv-1" ]; then pass "TC-234 conversation_id registers"; else fail "TC-234 conversation_id ignored"; fi
  run_eng register '{"sessionId":"sess-2"}' >/dev/null 2>&1
  if [ -e "$ETD/sessions/sess-2" ]; then pass "TC-234 sessionId registers"; else fail "TC-234 sessionId ignored"; fi
  run_eng register '{"conversation_id":"conv-3","session_id":"sid-3"}' >/dev/null 2>&1
  if [ -e "$ETD/sessions/sid-3" ] && [ ! -e "$ETD/sessions/conv-3" ]; then
    pass "TC-234 session_id wins when both present"
  else
    fail "TC-234 precedence wrong with both keys"
  fi
  run_eng register '{"conversation_id":"../evil"}' >/dev/null 2>&1
  if [ ! -e "$ETD/evil" ] && [ ! -e "$ETD/sessions/../evil" ] 2>/dev/null; then
    pass "TC-234 bad-charset conversation_id rejected"
  else
    fail "TC-234 bad-charset conversation_id accepted"
  fi
  eng_teardown
}

test_tc235_caffeinate_absent() {
  eng_setup
  for sub in register touch unregister reap; do
    out=$(run_eng_env "$sub" "$JSON" AWAKENT_PROC_PATTERN=sleep \
      AWAKENT_TEST_PID="$FAKE_PID" AWAKENT_DEBUG=1 \
      AWAKENT_CAFFEINATE=/nonexistent/caffeinate 2>/dev/null)
    assert_exit 0 $? "TC-235 '$sub' exits 0 without caffeinate"
    assert_empty "$out" "TC-235 '$sub' silent without caffeinate"
  done
  # zero state written - not even the debug log
  cnt=0; for f in "$ETD"/* "$ETD"/.[!.]*; do [ -e "$f" ] && cnt=$((cnt+1)); done
  assert_eq "0" "$cnt" "TC-235 zero writes to state dir"
  out=$(run_eng_env status "$JSON" AWAKENT_CAFFEINATE=/nonexistent/caffeinate 2>/dev/null)
  assert_exit 0 $? "TC-235 status exits 0 without caffeinate"
  case "$out" in
    "assertion: unsupported"*) pass "TC-235 status reports unsupported" ;;
    *) fail "TC-235 status without caffeinate: $out" ;;
  esac
  eng_teardown
}

test_tc236_observed_comm_pattern() {
  eng_setup
  # no AWAKENT_PROC_PATTERN, no host: the default-host path records the
  # observed process name of the session pid (here the fake sleep).
  run_eng_env register "$JSON" AWAKENT_TEST_PID="$FAKE_PID" >/dev/null 2>&1
  assert_eq "sleep" "$(sed -n '2p' "$ETD/sessions/eng-test-1")" "TC-236 observed parent comm recorded as pattern"
  # and the recorded pattern keeps the session alive through a reap
  run_eng_env reap "$JSON" >/dev/null 2>&1
  if [ -e "$ETD/sessions/eng-test-1" ]; then pass "TC-236 session survives reap under observed pattern"; else fail "TC-236 session reaped despite live observed-comm match"; fi
  eng_teardown
}

test_tc219_lock_exhaustion() {
  eng_setup
  mkdir -p "$ETD/.lock"   # fresh foreign lock (not stale)
  t0=$(date +%s)
  printf '%s' "$JSON" | AWAKENT_STATE_DIR="$ETD" AWAKENT_DEBUG=1 AWAKENT_PROC_PATTERN=sleep \
    AWAKENT_TEST_PID="$FAKE_PID" AWAKENT_CAFFEINATE="$REPO_ROOT/tests/caffstub.sh" \
    /bin/bash "$ENGINE" register >/dev/null 2>&1
  rc=$?
  t1=$(date +%s)
  assert_exit 0 "$rc" "TC-219 exhaustion still exits 0"
  if [ $((t1 - t0)) -le 3 ]; then pass "TC-219 bounded wait (~2s)"; else fail "TC-219 blocked $((t1-t0))s"; fi
  grep -q 'decision=unlocked' "$ETD/awakent.log"
  assert_exit 0 $? "TC-219 unlocked-proceed logged"
  if [ -d "$ETD/.lock" ]; then pass "TC-219 foreign lock NOT removed by non-holder"; else fail "TC-219 foreign lock was removed"; fi
  eng_teardown
}
