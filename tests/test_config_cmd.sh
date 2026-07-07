#!/bin/bash
# /awakent:config command pins, plus engine parsing of the file shapes the
# command produces. Sourced by tests/run.sh.

CFG_CMD="$REPO_ROOT/commands/config.md"
CFG_README="$REPO_ROOT/README.md"
CFG_ENGINE="$REPO_ROOT/hooks/awakent.sh"

test_tc401_command_body_pins() {
  if [ -f "$CFG_CMD" ]; then pass "TC-401 commands/config.md exists"; else fail "TC-401 file missing"; return; fi
  head -n 1 "$CFG_CMD" | grep -q '^---$'
  assert_exit 0 $? "TC-401 frontmatter opens"
  sed -n '2p' "$CFG_CMD" | grep -q '^description: .'
  assert_exit 0 $? "TC-401 one-line description present"
  grep -qF '"${CLAUDE_PLUGIN_ROOT}/hooks/awakent.sh" status' "$CFG_CMD"
  assert_exit 0 $? "TC-401 exact engine invocation"
  # shellcheck disable=SC2088  # literal doc-text search target, not a path
  grep -qF '~/.claude/awakent/config' "$CFG_CMD"
  assert_exit 0 $? "TC-401 config path present"
  grep -q '5-1440\|5-1440\|from 5 to 1440' "$CFG_CMD"
  assert_exit 0 $? "TC-401 bounds 5-1440 present"
  grep -q '`0`, `1`, `true`, `false`' "$CFG_CMD"
  assert_exit 0 $? "TC-401 boolean value set present"
  grep -qi 'refuse the entire request' "$CFG_CMD"
  assert_exit 0 $? "TC-401 atomic-reject statement"
  grep -qi 'no file other than' "$CFG_CMD"
  assert_exit 0 $? "TC-401 write-scope prohibition"
  grep -qi 'no command other than' "$CFG_CMD"
  assert_exit 0 $? "TC-401 no-other-commands prohibition"
  grep -qi 'never source, execute, or evaluate' "$CFG_CMD"
  assert_exit 0 $? "TC-401 never-execute statement"
  grep -qi 'next restart event' "$CFG_CMD"
  assert_exit 0 $? "TC-401 TTL-effect-timing note"
}

test_tc402_engine_parses_command_shaped_files() {
  d=$(mktemp -d)
  # fresh file, exactly as the command would create it
  printf 'ttl_minutes=10\n' > "$d/config"
  out=$(AWAKENT_STATE_DIR="$d" /bin/bash "$CFG_ENGINE" status < /dev/null 2>/dev/null)
  case "$out" in *"ttl_minutes=10"*) pass "TC-402 fresh file parsed" ;; *) fail "TC-402 fresh: $out" ;; esac
  # updated-in-place: existing key rewritten; comment + unrelated key preserved
  printf '%s\n' '# my note' 'debug=1' 'ttl_minutes=30' > "$d/config"
  /usr/bin/sed -i '' 's|^ttl_minutes=.*|ttl_minutes=120|' "$d/config"   # the command's replace semantics
  out=$(AWAKENT_STATE_DIR="$d" /bin/bash "$CFG_ENGINE" status < /dev/null 2>/dev/null)
  case "$out" in *"ttl_minutes=120"*debug=1*) pass "TC-402 updated-in-place parsed, unrelated key intact" ;; *) fail "TC-402 update: $out" ;; esac
  grep -q '# my note' "$d/config"
  assert_exit 0 $? "TC-402 comment preserved"
  # appended after preserved garbage line
  printf '%s\n' 'garbage line !!' 'lid_closed_mode=true' >> "$d/config"
  out=$(AWAKENT_STATE_DIR="$d" /bin/bash "$CFG_ENGINE" status < /dev/null 2>/dev/null)
  case "$out" in *"lid_closed_mode=1"*) pass "TC-402 appended key parsed despite garbage neighbor" ;; *) fail "TC-402 append: $out" ;; esac
  rm -rf "$d"
}

test_tc403_readme_pins() {
  grep -qF '/awakent:config' "$CFG_README"
  assert_exit 0 $? "TC-403 command usage documented"
  grep -q '/awakent:config ttl_minutes=' "$CFG_README"
  assert_exit 0 $? "TC-403 example key=value invocation"
  # shellcheck disable=SC2088  # literal doc-text search target, not a path
  grep -qF '~/.claude/awakent/config' "$CFG_README"
  assert_exit 0 $? "TC-403 file-edit path retained"
  grep -qi 'single source of truth' "$CFG_README"
  assert_exit 0 $? "TC-403 source-of-truth statement"
  grep -q '5-1440\|5-1440' "$CFG_README"
  assert_exit 0 $? "TC-403 bounds shown in README (BR-3)"
}
