#!/bin/bash
# Wrapper that runs the scenario harness inside the run.sh
# suite. Each scenario is exposed as a test_* function so failures report
# per-scenario. AWAKENT_DEBUG=1 so the final vocabulary scan
# covers harness-produced logs.

# shellcheck source=/dev/null
. "$REPO_ROOT/tests/harness.sh"

export AWAKENT_DEBUG=1

H_LOG_COLLECT=$(mktemp -d)

# harness.sh calls h_pre_teardown (if defined) before each sandbox cleanup.
h_pre_teardown() {
  if [ -f "$H_SANDBOX/awakent.log" ]; then
    cp "$H_SANDBOX/awakent.log" "$H_LOG_COLLECT/log.$$.$RANDOM" 2>/dev/null
  fi
}

test_s210() { scenario_210_single_lifecycle; }
test_s211() { scenario_211_two_parallel; }
test_s212() { scenario_212_crash_recovery; }
test_s213() { scenario_213_register_storm; }
test_s214() { scenario_214_ttl_expiry; }
test_s215() { scenario_215_recycled_caff_pid; }
test_s216() { scenario_216_touch_behavior; }
test_s220() { scenario_220_config_flags; }

test_s221_log_vocabulary_scan() {
  total=0; bad=0
  for lf in "$H_LOG_COLLECT"/log.*; do
    [ -e "$lf" ] || continue
    total=$((total + 1))
    b=$(grep -Ecv '^[0-9T:Z-]+ event=[a-z-]+ sid=[A-Za-z0-9_-]+ n=[0-9-]+ decision=[a-z:,_-]+( caff=[0-9-]*)?$' "$lf")
    bad=$((bad + b))
  done
  assert_eq "0" "$bad" "TC-221 harness logs vocabulary clean ($total logs scanned)"
  rm -rf "$H_LOG_COLLECT"
}
