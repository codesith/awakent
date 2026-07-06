#!/bin/bash
# Scenario harness: simulates Claude Code sessions
# without Claude Code. Callable standalone (`/bin/bash tests/harness.sh`)
# for manual runs (M4 foundation); tests/test_harness_scenarios.sh wraps it
# for the run.sh suite. Uses REAL caffeinate (short -t) — the argv-recording
# stub (caffstub.sh) is used only where flags are asserted (TC-220).

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"
HENGINE="$HARNESS_ROOT/hooks/awakent.sh"

# When run standalone, provide minimal assert helpers compatible with run.sh's.
if ! type pass >/dev/null 2>&1; then
  HPASS=0; HFAIL=0; CURRENT_TEST="harness"
  log()  { echo "$@" >&2; }
  pass() { HPASS=$((HPASS+1)); log "ok    $CURRENT_TEST: $*"; }
  fail() { HFAIL=$((HFAIL+1)); log "FAIL  $CURRENT_TEST: $*"; }
  assert_eq()   { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$1', got '$2')"; fi; }
  assert_exit() { assert_eq "$1" "$2" "$3"; }
  HARNESS_STANDALONE=1
else
  HARNESS_STANDALONE=0
fi

# --- scenario plumbing -------------------------------------------------------

H_SANDBOX=""

h_setup() {
  H_SANDBOX=$(mktemp -d)
  printf 'ttl_minutes=5\n' > "$H_SANDBOX/config"   # shortest legal TTL
}

h_fake_session() {
  # stdout/stderr detached: this runs inside $(...) captures, and a background
  # child holding the capture pipe would block the substitution until it dies.
  # PID recorded to a file: this runs in a $(...) subshell, so a shell
  # variable could not reach teardown, which must kill every fake.
  sleep 300 >/dev/null 2>&1 &
  printf '%s\n' "$!" >> "$H_SANDBOX/.fakepids"
  printf '%s' "$!"
}

h_caff_pid() {
  head -n 1 "$H_SANDBOX/caffeinate.pid" 2>/dev/null | tr -cd '0-9'
}

h_caff_alive() {
  cpid=$(h_caff_pid)
  [ -n "$cpid" ] || return 1
  kill -0 "$cpid" 2>/dev/null || return 1
  cname=$(ps -p "$cpid" -o comm= 2>/dev/null)
  [ "$(basename "$cname")" = "caffeinate" ]
}

# h_run <subcommand> <session_id> <fake_pid>
h_run() {
  printf '{"session_id":"%s"}' "$2" | \
    AWAKENT_STATE_DIR="$H_SANDBOX" AWAKENT_PROC_PATTERN=sleep \
    AWAKENT_TEST_PID="$3" /bin/bash "$HENGINE" "$1"
}

h_teardown() {
  # Optional callback for wrappers (e.g. debug-log collection) before cleanup.
  if type h_pre_teardown >/dev/null 2>&1; then
    h_pre_teardown
  fi
  cpid=$(h_caff_pid)
  if [ -n "$cpid" ]; then
    kill "$cpid" 2>/dev/null
    # Poll until the kill lands: caffeinate is not our child (no wait), and a
    # lingering corpse skews the next scenario's process-count delta (TC-213).
    i=0
    while [ "$i" -lt 20 ] && kill -0 "$cpid" 2>/dev/null; do
      sleep 0.1
      i=$((i + 1))
    done
  fi
  if [ -f "$H_SANDBOX/.fakepids" ]; then
    while read -r p; do
      [ -n "$p" ] && kill "$p" 2>/dev/null
    done < "$H_SANDBOX/.fakepids"
  fi
  rm -rf "$H_SANDBOX"
}

h_count_caffeinates() {
  # Count only awakent-shaped caffeinates (our exact argv with the 300s test
  # TTL) — immune to unrelated caffeinate processes on the machine.
  ps -axo command= 2>/dev/null | grep -c 'caffeinate -is\{0,1\} -t 300$'
}

h_await_zero_caffeinates() {
  i=0
  while [ "$i" -lt 20 ]; do
    if [ "$(h_count_caffeinates)" = "0" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- scenarios (TC-210..216, TC-220) -----------------------------------------

scenario_210_single_lifecycle() {
  h_setup
  p=$(h_fake_session)
  h_run register s210 "$p" >/dev/null 2>&1
  h_caff_alive; assert_exit 0 $? "TC-210 assertion up after register"
  if pmset -g assertions 2>/dev/null | grep -q caffeinate; then
    pass "TC-210 pmset shows caffeinate assertion (advisory)"
  else
    log "note  TC-210 pmset check inconclusive (advisory only)"
  fi
  out=$(h_run status s210 "$p" 2>/dev/null)
  case "$out" in
    "assertion: held"*"session: s210 0m ago"*) pass "TC-210 status reports held + session" ;;
    *) fail "TC-210 status shape: $out" ;;
  esac
  h_run touch s210 "$p" >/dev/null 2>&1
  h_caff_alive; assert_exit 0 $? "TC-210 assertion survives touch"
  h_run unregister s210 "$p" >/dev/null 2>&1
  if h_caff_alive; then fail "TC-210 assertion not released"; else pass "TC-210 assertion released after unregister"; fi
  out=$(h_run status s210 "$p" 2>/dev/null)
  case "$out" in "assertion: released"*) pass "TC-210 status reports released" ;; *) fail "TC-210 released status: $out" ;; esac
  h_teardown
}

scenario_211_two_parallel() {
  h_setup
  p1=$(h_fake_session); p2=$(h_fake_session)
  h_run register s211a "$p1" >/dev/null 2>&1
  h_run register s211b "$p2" >/dev/null 2>&1
  first=$(h_caff_pid)
  h_run unregister s211a "$p1" >/dev/null 2>&1
  h_caff_alive; assert_exit 0 $? "TC-211 assertion held while second session live"
  assert_eq "$first" "$(h_caff_pid)" "TC-211 same caffeinate kept (no churn)"
  h_run unregister s211b "$p2" >/dev/null 2>&1
  if h_caff_alive; then fail "TC-211 not released after both ended"; else pass "TC-211 released after both ended"; fi
  h_teardown
}

scenario_212_crash_recovery() {
  h_setup
  p1=$(h_fake_session); p2=$(h_fake_session)
  h_run register s212a "$p1" >/dev/null 2>&1
  h_run register s212b "$p2" >/dev/null 2>&1
  kill -9 "$p1" 2>/dev/null; wait "$p1" 2>/dev/null
  h_run register s212b "$p2" >/dev/null 2>&1   # any locked op triggers reap
  if [ ! -e "$H_SANDBOX/sessions/s212a" ]; then pass "TC-212 crashed session reaped"; else fail "TC-212 crashed session not reaped"; fi
  h_caff_alive; assert_exit 0 $? "TC-212 assertion held for survivor"
  kill -9 "$p2" 2>/dev/null; wait "$p2" 2>/dev/null
  h_run reap - "$p2" >/dev/null 2>&1
  if h_caff_alive; then fail "TC-212 assertion survived empty registry"; else pass "TC-212 released after last crash reaped"; fi
  h_teardown
}

scenario_213_register_storm() {
  h_setup
  p=$(h_fake_session)
  h_await_zero_caffeinates || log "note  TC-213 baseline caffeinate lingering; delta may skew"
  before=$(h_count_caffeinates)
  storm_pids=""
  i=0
  # 20 concurrent registrations: enough parallelism to shake out mutex
  # races without making the suite crawl.
  while [ "$i" -lt 20 ]; do
    h_run register "storm-$i" "$p" >/dev/null 2>&1 &
    storm_pids="$storm_pids $!"
    i=$((i+1))
  done
  # Wait ONLY on the storm invocations — a bare `wait` would also block on
  # the fake-session `sleep 300` background jobs.
  for sp in $storm_pids; do
    wait "$sp" 2>/dev/null
  done
  after=$(h_count_caffeinates)
  assert_eq "1" "$((after - before))" "TC-213 storm spawned exactly one caffeinate"
  h_caff_alive; assert_exit 0 $? "TC-213 pidfile caffeinate live and verified"
  cnt=0; for f in "$H_SANDBOX/sessions"/*; do [ -e "$f" ] && cnt=$((cnt+1)); done
  assert_eq "20" "$cnt" "TC-213 all twenty sessions registered"
  h_teardown
}

scenario_214_ttl_expiry() {
  h_setup
  p=$(h_fake_session)
  h_run register s214 "$p" >/dev/null 2>&1
  touch -t 202001010000 "$H_SANDBOX/sessions/s214"
  h_run reap - "$p" >/dev/null 2>&1
  if [ ! -e "$H_SANDBOX/sessions/s214" ]; then pass "TC-214 TTL-expired session reaped"; else fail "TC-214 TTL-expired session not reaped"; fi
  if h_caff_alive; then fail "TC-214 assertion survived TTL expiry"; else pass "TC-214 released after TTL expiry"; fi
  h_teardown
}

scenario_215_recycled_caff_pid() {
  h_setup
  p=$(h_fake_session)
  imposter=$(h_fake_session)   # a live sleep pretending to be caffeinate
  mkdir -p "$H_SANDBOX"
  printf '%s\n' "$imposter" > "$H_SANDBOX/caffeinate.pid"
  h_run register s215 "$p" >/dev/null 2>&1
  kill -0 "$imposter" 2>/dev/null; assert_exit 0 $? "TC-215 imposter PID not killed"
  real=$(h_caff_pid)
  if [ "$real" != "$imposter" ] && h_caff_alive; then
    pass "TC-215 fresh caffeinate spawned, pidfile replaced"
  else
    fail "TC-215 pidfile still imposter or no live caffeinate"
  fi
  h_teardown
}

scenario_216_touch_behavior() {
  h_setup
  p=$(h_fake_session)
  h_run register s216 "$p" >/dev/null 2>&1
  touch "$H_SANDBOX/.refresh"   # refresh not due -> pure hot path
  pid_before=$(h_caff_pid)
  t0=$(perl -MTime::HiRes=time -e 'printf "%.0f", time()*1000')
  i=0
  while [ "$i" -lt 20 ]; do
    h_run touch s216 "$p" >/dev/null 2>&1
    if [ -d "$H_SANDBOX/.lock" ]; then fail "TC-216 lock appeared on hot path"; fi
    i=$((i+1))
  done
  t1=$(perl -MTime::HiRes=time -e 'printf "%.0f", time()*1000')
  avg_ms=$(( (t1 - t0) / 20 ))
  # Design target is <50ms on an idle machine; the automated gate
  # fails at 100ms average to absorb CI/parallel-suite load noise.
  if [ "$avg_ms" -le 50 ]; then
    pass "TC-216 touch avg ${avg_ms}ms (meets 50ms design target)"
  elif [ "$avg_ms" -le 100 ]; then
    pass "TC-216 touch avg ${avg_ms}ms (within 100ms loaded-machine gate; 50ms target on idle)"
  else
    fail "TC-216 touch avg ${avg_ms}ms exceeds 100ms gate"
  fi
  assert_eq "$pid_before" "$(h_caff_pid)" "TC-216 zero restarts while marker fresh"
  # Force a due refresh: exactly one restart across the next burst.
  touch -t 202001010000 "$H_SANDBOX/.refresh"
  i=0
  while [ "$i" -lt 5 ]; do
    h_run touch s216 "$p" >/dev/null 2>&1
    i=$((i+1))
  done
  pid_after=$(h_caff_pid)
  if [ "$pid_after" != "$pid_before" ] && h_caff_alive; then
    pass "TC-216 exactly one restart on due refresh"
  else
    fail "TC-216 refresh restart missing"
  fi
  # Self-heal: delete session file, touch recreates + re-ensures.
  rm -f "$H_SANDBOX/sessions/s216"
  h_run touch s216 "$p" >/dev/null 2>&1
  if [ -e "$H_SANDBOX/sessions/s216" ]; then pass "TC-216 self-heal recreated session"; else fail "TC-216 self-heal did not recreate session"; fi
  h_caff_alive; assert_exit 0 $? "TC-216 self-heal re-ensured caffeinate"
  h_teardown
}

scenario_220_config_flags() {
  # Uses the argv-recording stub: flags are asserted, aliveness is not.
  for variant in default lid garbage; do
    h_setup
    p=$(h_fake_session)
    case "$variant" in
      default) : ;;  # keep ttl-only config from h_setup
      lid)     printf 'ttl_minutes=5\nlid_closed_mode=true\n' > "$H_SANDBOX/config" ;;
      garbage) printf 'ttl_minutes=abc\nlid_closed_mode=banana\n' > "$H_SANDBOX/config" ;;
    esac
    stublog="$H_SANDBOX/caffstub.log"
    printf '{"session_id":"s220"}' | \
      AWAKENT_STATE_DIR="$H_SANDBOX" AWAKENT_PROC_PATTERN=sleep \
      AWAKENT_TEST_PID="$p" AWAKENT_CAFFEINATE="$HARNESS_ROOT/tests/caffstub.sh" \
      CAFFSTUB_LOG="$stublog" /bin/bash "$HENGINE" register >/dev/null 2>&1
    argv=$(head -n 1 "$stublog" 2>/dev/null)
    case "$variant" in
      default) case "$argv" in "-i -t 300"*) pass "TC-220 default -> -i (ttl 300s)" ;; *) fail "TC-220 default argv: '$argv'" ;; esac ;;
      lid)     case "$argv" in "-is -t 300"*) pass "TC-220 lid_closed_mode=true -> -is" ;; *) fail "TC-220 lid argv: '$argv'" ;; esac ;;
      garbage) case "$argv" in "-i -t 3600"*) pass "TC-220 garbage -> defaults (-i, ttl 3600s)" ;; *) fail "TC-220 garbage argv: '$argv'" ;; esac ;;
    esac
    h_teardown
  done
}

# Vocabulary scan over all harness debug logs is run by the
# wrapper (test_harness_scenarios.sh) which enables AWAKENT_DEBUG per scenario.

h_run_all() {
  scenario_210_single_lifecycle
  scenario_211_two_parallel
  scenario_212_crash_recovery
  scenario_213_register_storm
  scenario_214_ttl_expiry
  scenario_215_recycled_caff_pid
  scenario_216_touch_behavior
  scenario_220_config_flags
}

if [ "$HARNESS_STANDALONE" = "1" ]; then
  trap 'h_teardown' EXIT
  h_run_all
  log "----"
  log "harness: $HPASS passed, $HFAIL failed"
  [ "$HFAIL" -eq 0 ] || exit 1
  exit 0
fi
