#!/bin/bash
# Plugin integration checks: hook wiring, command files, README contracts.
# Sourced by tests/run.sh; uses its assert_* helpers and $REPO_ROOT.

HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
M3_README="$REPO_ROOT/README.md"
M3_CMD="$REPO_ROOT/commands/status.md"
M3_ENGINE="$REPO_ROOT/hooks/awakent.sh"

test_tc301_hooks_json_wiring() {
  python3 - "$HOOKS_JSON" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
hooks = d["hooks"]
want = {"SessionStart": "register", "SessionEnd": "unregister",
        "UserPromptSubmit": "touch", "PostToolUse": "touch", "Stop": "touch"}
assert set(hooks) == set(want), f"events {sorted(hooks)} != {sorted(want)}"
for ev, sub in want.items():
    entries = hooks[ev]
    assert len(entries) == 1, f"{ev}: {len(entries)} matcher groups"
    hs = entries[0]["hooks"]
    assert len(hs) == 1, f"{ev}: {len(hs)} hooks"
    h = hs[0]
    assert h["type"] == "command", f"{ev}: type {h['type']}"
    assert h["timeout"] == 10, f"{ev}: timeout {h.get('timeout')}"
    assert "${CLAUDE_PLUGIN_ROOT}/hooks/awakent.sh" in h["command"], f"{ev}: {h['command']}"
    assert h["command"].rstrip().endswith(sub), f"{ev}: expected subcommand {sub}: {h['command']}"
PYEOF
  assert_exit 0 $? "TC-301 hooks.json wires five events, 10s timeouts, plugin-root paths"
}

test_tc307_marketplace_json() {
  # .claude-plugin/marketplace.json makes the repo installable via
  # `claude plugin marketplace add` (CLI/VS Code path) - discovered required
  # during first real install; README §Install documents this path.
  python3 - "$REPO_ROOT/.claude-plugin/marketplace.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["name"] == "awakent"
assert d["plugins"][0]["name"] == "awakent"
assert d["plugins"][0]["source"] == "./"
PYEOF
  assert_exit 0 $? "TC-307 marketplace.json valid: awakent plugin at repo root"
  grep -q 'claude plugin marketplace add' "$M3_README"
  assert_exit 0 $? "TC-307 README documents the CLI install path"
}

test_tc302_hook_paths_exist() {
  missing=0
  while read -r cmdpath; do
    rel="${cmdpath#\$\{CLAUDE_PLUGIN_ROOT\}/}"
    if [ ! -f "$REPO_ROOT/$rel" ]; then
      missing=$((missing + 1))
    fi
  done < <(grep -o '\${CLAUDE_PLUGIN_ROOT}[^"\\ ]*' "$HOOKS_JSON" | sort -u)
  assert_eq "0" "$missing" "TC-302 every hook-referenced path exists in repo"
}

test_tc303_status_log_line() {
  d=$(mktemp -d)
  out=$(AWAKENT_STATE_DIR="$d" AWAKENT_DEBUG=1 /bin/bash "$M3_ENGINE" status < /dev/null 2>/dev/null)
  case "$out" in
    *"log: $d/awakent.log"*) pass "TC-303 log: line present with debug on" ;;
    *) fail "TC-303 log: line missing with debug on: $out" ;;
  esac
  # AWAKENT_DEBUG=0 pinned: the M2 scenario wrapper exports AWAKENT_DEBUG=1
  # suite-wide, and "unset" is not reachable from inside the suite.
  out=$(AWAKENT_STATE_DIR="$d" AWAKENT_DEBUG=0 /bin/bash "$M3_ENGINE" status < /dev/null 2>/dev/null)
  case "$out" in
    *"log:"*) fail "TC-303 log: line present with debug off" ;;
    *) pass "TC-303 no log: line with debug off" ;;
  esac
  rm -rf "$d"
}

test_tc304_status_boundaries() {
  d=$(mktemp -d)
  # zero sessions
  out=$(AWAKENT_STATE_DIR="$d" /bin/bash "$M3_ENGINE" status < /dev/null 2>/dev/null)
  case "$out" in
    "assertion: released"*) pass "TC-304 zero-session: released" ;;
    *) fail "TC-304 zero-session: $out" ;;
  esac
  case "$out" in
    *"session:"*) fail "TC-304 zero-session: unexpected session line" ;;
    *) pass "TC-304 zero-session: no session lines" ;;
  esac
  case "$out" in
    *"release-in: -"*) pass "TC-304 zero-session: release-in -" ;;
    *) fail "TC-304 zero-session: release-in wrong: $out" ;;
  esac
  # one live + one dead -> stale rendering + count exclusion
  sleep 300 >/dev/null 2>&1 &
  live=$!
  sleep 300 >/dev/null 2>&1 &
  deadpid=$!
  kill -9 "$deadpid" 2>/dev/null; wait "$deadpid" 2>/dev/null
  mkdir -p "$d/sessions"
  printf '%s\n' "$live" > "$d/sessions/live-one"
  printf '%s\n' "$deadpid" > "$d/sessions/dead-one"
  out=$(AWAKENT_STATE_DIR="$d" AWAKENT_PROC_PATTERN=sleep /bin/bash "$M3_ENGINE" status < /dev/null 2>/dev/null)
  case "$out" in
    *"session: live-one 0m ago"*) pass "TC-304 live session rendered with age" ;;
    *) fail "TC-304 live session missing: $out" ;;
  esac
  case "$out" in
    *"session: dead-one (stale)"*) pass "TC-304 dead session rendered (stale)" ;;
    *) fail "TC-304 stale annotation missing: $out" ;;
  esac
  case "$out" in
    *"release-in: -"*) fail "TC-304 release-in ignored the live session" ;;
    *"release-in:"*) pass "TC-304 release-in computed from live session only" ;;
    *) fail "TC-304 release-in line missing" ;;
  esac
  kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
  rm -rf "$d"
}

test_tc305_readme_snippet_equivalence() {
  python3 - "$M3_README" "$HOOKS_JSON" <<'PYEOF'
import json, re, sys
readme = open(sys.argv[1]).read()
m = re.search(r"```json\n(.*?)```", readme, re.S)
assert m, "no fenced json block in README"
snippet = json.loads(m.group(1))
plugin = json.load(open(sys.argv[2]))
sh, ph = snippet["hooks"], plugin["hooks"]
assert set(sh) == set(ph), f"event sets differ: {sorted(sh)} vs {sorted(ph)}"
for ev in ph:
    s, p = sh[ev][0]["hooks"][0], ph[ev][0]["hooks"][0]
    assert s["type"] == p["type"] == "command"
    assert s["timeout"] == p["timeout"] == 10, f"{ev} timeout"
    ssub, psub = s["command"].split()[-1], p["command"].split()[-1]
    assert ssub == psub, f"{ev}: {ssub} vs {psub}"
    assert ".claude/hooks/awakent.sh" in s["command"], f"{ev} snippet path: {s['command']}"
PYEOF
  assert_exit 0 $? "TC-305 snippet is valid JSON, equivalent wiring, ~/.claude/hooks path"
  grep -qi "merge" "$M3_README"
  assert_exit 0 $? "TC-305 merge warning present"
  grep -q 'bash ~/.claude/hooks/awakent.sh status' "$M3_README"
  assert_exit 0 $? "TC-305 status substitute documented"
}

test_tc306_readme_uninstall_and_command_body() {
  grep -q 'ttl_minutes' "$M3_README" && grep -qE 'self.expir' "$M3_README"
  assert_exit 0 $? "TC-306 TTL self-expiry bound documented"
  grep -q 'pkill caffeinate' "$M3_README"
  assert_exit 0 $? "TC-306 pkill one-liner present"
  grep -q 'rm -rf ~/.claude/awakent' "$M3_README"
  assert_exit 0 $? "TC-306 complete state removal documented"
  grep -q 'no uninstall hook' "$M3_README"
  assert_exit 0 $? "TC-306 no-uninstall-hook statement present"
  grep -qF '"${CLAUDE_PLUGIN_ROOT}/hooks/awakent.sh" status' "$M3_CMD"
  assert_exit 0 $? "TC-306 command body invokes engine status"
}
