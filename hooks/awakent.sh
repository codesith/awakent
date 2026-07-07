#!/bin/bash
# awakent - keeps the Mac awake exactly while agent sessions are active
# (Claude Code, and via adapters: Codex CLI, Cursor, Copilot, pi).
#
# Contract: mutating subcommands never write stdout and always exit 0, even
# on internal failure. `status` is the sole subcommand permitted stdout.
# A broken awakent must never break the host agent.
#
# bash 3.2 only (macOS /bin/bash): no associative arrays, no ${var,,},
# no mapfile, no flock. Zero dependencies beyond OS built-ins.

umask 077

# ---------------------------------------------------------------------------
# State paths. AWAKENT_STATE_DIR is a documented test-only override;
# nonsense values fail closed via the containment wrapper.
# ---------------------------------------------------------------------------
STATE_DIR="${AWAKENT_STATE_DIR:-$HOME/.claude/awakent}"
SESS_DIR="$STATE_DIR/sessions"
LOCK_DIR="$STATE_DIR/.lock"
REFRESH_MARK="$STATE_DIR/.refresh"
CAFF_PIDFILE="$STATE_DIR/caffeinate.pid"
CONFIG_FILE="$STATE_DIR/config"
LOG_FILE="$STATE_DIR/awakent.log"

CAFF_BIN="${AWAKENT_CAFFEINATE:-caffeinate}"
# Global fallback pattern, used for legacy one-line session files that predate
# the per-session pattern (file line 2). New registrations record their own.
PROC_PATTERN="${AWAKENT_PROC_PATTERN:-claude|node}"

# Config effective values (defaults; overridden by load_config below).
TTL_MINUTES=60
LID_CLOSED_MODE=0
DEBUG_ON=0
CONFIG_WARNINGS=""

now_epoch() {
  date +%s
}

file_mtime() {
  # stat is the only extra subprocess the hot path pays for age checks.
  stat -f %m "$1" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# Config. Parsed, never sourced: the file is data, and sourcing user-owned
# files from a hook would be an arbitrary-code-execution hole.
# Accepted keys: ttl_minutes (5-1440), lid_closed_mode, debug (1|true / 0|false).
# ---------------------------------------------------------------------------
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        ttl_minutes=*)
          val="${line#ttl_minutes=}"
          case "$val" in
            ''|*[!0-9]*)
              CONFIG_WARNINGS="$CONFIG_WARNINGS ttl_minutes-invalid"
              ;;
            *)
              if [ "$val" -ge 5 ] && [ "$val" -le 1440 ]; then
                TTL_MINUTES="$val"
              else
                CONFIG_WARNINGS="$CONFIG_WARNINGS ttl_minutes-out-of-bounds"
              fi
              ;;
          esac
          ;;
        lid_closed_mode=*)
          val="${line#lid_closed_mode=}"
          case "$val" in
            1|true)  LID_CLOSED_MODE=1 ;;
            0|false) LID_CLOSED_MODE=0 ;;
            *)       CONFIG_WARNINGS="$CONFIG_WARNINGS lid_closed_mode-invalid" ;;
          esac
          ;;
        debug=*)
          val="${line#debug=}"
          case "$val" in
            1|true)  DEBUG_ON=1 ;;
            0|false) DEBUG_ON=0 ;;
            *)       CONFIG_WARNINGS="$CONFIG_WARNINGS debug-invalid" ;;
          esac
          ;;
        ''|\#*) : ;;  # blank lines and comments ignored
        *) : ;;        # unknown keys ignored
      esac
    done < "$CONFIG_FILE"
  fi
  if [ "${AWAKENT_DEBUG:-0}" = "1" ]; then
    DEBUG_ON=1
  fi
  TTL_SECONDS=$((TTL_MINUTES * 60))
  # Refresh interval: ttl/4 with a 60s floor, so bursts of activity
  # can't churn caffeinate restarts.
  REFRESH_SECONDS=$((TTL_SECONDS / 4))
  if [ "$REFRESH_SECONDS" -lt 60 ]; then
    REFRESH_SECONDS=60
  fi
  if [ -n "$CONFIG_WARNINGS" ]; then
    warn_joined="${CONFIG_WARNINGS# }"
    # comma-joined: log line vocabulary allows no spaces inside fields
    warn_joined="${warn_joined// /,}"
    dbg "config" "-" "-" "warn:$warn_joined" "-"
  fi
}

# ---------------------------------------------------------------------------
# Debug log. Session ids, PIDs, timestamps, and fixed engine vocabulary
# only - never prompt content or user-project paths.
# ---------------------------------------------------------------------------
dbg() {
  [ "$DEBUG_ON" = "1" ] || return 0
  size=$(stat -f %z "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$size" -gt 1048576 ]; then
    tmp="$LOG_FILE.tmp.$$"
    if tail -n 200 "$LOG_FILE" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$LOG_FILE" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  fi
  printf '%s event=%s sid=%s n=%s decision=%s caff=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$5" \
    >> "$LOG_FILE" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# mkdir mutex (macOS has no flock): 10 x 100ms bounded wait,
# stale break at >30s, proceed-unlocked on exhaustion. Never wraps
# caffeinate's lifetime - only the reap-and-decide critical section.
# ---------------------------------------------------------------------------
LOCK_HELD=0

lock_acquire() {
  attempt=0
  while [ "$attempt" -lt 10 ]; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_HELD=1
      return 0
    fi
    lock_age=$(( $(now_epoch) - $(file_mtime "$LOCK_DIR") ))
    if [ "$lock_age" -gt 30 ]; then
      rmdir "$LOCK_DIR" 2>/dev/null
      dbg "lock" "-" "-" "stale-break" "-"
      continue
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  dbg "lock" "-" "-" "unlocked" "-"
  return 1
}

lock_release() {
  # Only ever remove a lock this invocation acquired - an unlocked-proceed
  # invocation must not free another process's mutex.
  if [ "$LOCK_HELD" = "1" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null
    LOCK_HELD=0
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Reaper. Removes session files whose PID is dead or whose last activity is
# older than the TTL. A live PID must also pass a process-name check before
# we trust it: PIDs get recycled, and a recycled PID must neither keep the
# machine awake nor ever be signaled. Ages clamp at zero so a backward clock
# step can't extend a hold. Tolerates files vanishing mid-scan (a concurrent
# reaper won); an absent or empty directory is a no-op.
# Each session file records the pattern its own host was registered under
# (line 2); the reaper judges every file by that recorded pattern, so a reap
# triggered from one host can never misjudge another host's PIDs. Files
# without a line 2 (pre-multi-host format) fall back to the global
# PROC_PATTERN. PID 0 is the documented sentinel for hosts that expose no
# usable PID (e.g. Cursor): no liveness check exists, TTL expiry alone
# governs, and 0 is never passed to kill or ps.
# ---------------------------------------------------------------------------
pid_name_matches() {
  # $1 = pid, $2 = extended regex for the process basename
  comm=$(ps -p "$1" -o comm= 2>/dev/null) || return 1
  base=$(basename "$comm" 2>/dev/null)
  # -e: a pattern starting with '-' must never parse as a grep flag.
  printf '%s' "$base" | grep -Eq -e "$2"
}

session_pattern() {
  # $1 = session file. Line 2 is data fed to grep -E: constrain its charset
  # or fall back rather than evaluate an arbitrary regex.
  pat=$(sed -n '2p' "$1" 2>/dev/null)
  # NB: the bracket's | must be backslash-escaped - an unescaped | splits the
  # case pattern into alternatives even inside [...].
  case "$pat" in
    ''|*[!A-Za-z0-9_.^\$\|-]*) pat="$PROC_PATTERN" ;;
  esac
  printf '%s' "$pat"
}

session_host() {
  # $1 = session file. Line 3 is the host recorded at registration -
  # display-only (never parsed from the filename: a bare uuid's first
  # segment is indistinguishable from a prefix). Empty for files written
  # by older engines; callers omit the host in that case.
  h=$(sed -n '3p' "$1" 2>/dev/null)
  case "$h" in
    *[!a-z0-9]*) h="" ;;
  esac
  if [ "${#h}" -gt 16 ]; then
    h=""
  fi
  printf '%s' "$h"
}

reap_sessions() {
  [ -d "$SESS_DIR" ] || return 0
  now=$(now_epoch)
  for f in "$SESS_DIR"/*; do
    [ -e "$f" ] || continue   # empty dir: glob stays literal
    pid=$(head -n 1 "$f" 2>/dev/null | tr -cd '0-9')
    sid=$(basename "$f")
    if [ -z "$pid" ]; then
      rm -f "$f"
      dbg "reap" "$sid" "-" "no-pid" "-"
      continue
    fi
    # Sentinel 0 first: kill -0 0 signals our own process group (always
    # succeeds), so it must never reach the liveness checks below.
    if [ "$pid" = "0" ]; then
      :
    # Our own process tree is never treated as a dead session.
    elif [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ]; then
      :
    elif ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$f"
      dbg "reap" "$sid" "-" "dead-pid" "-"
      continue
    elif ! pid_name_matches "$pid" "$(session_pattern "$f")"; then
      # Live but wrong name: recycled PID. Remove the file; never signal it.
      rm -f "$f"
      dbg "reap" "$sid" "-" "recycled-pid" "-"
      continue
    fi
    mtime=$(file_mtime "$f")
    [ "$mtime" = "0" ] && continue   # vanished mid-scan
    age=$((now - mtime))
    [ "$age" -lt 0 ] && age=0        # backward clock step: treat as fresh
    if [ "$age" -gt "$TTL_SECONDS" ]; then
      rm -f "$f"
      dbg "reap" "$sid" "-" "ttl-expired" "-"
    fi
  done
  return 0
}

count_sessions() {
  n=0
  if [ -d "$SESS_DIR" ]; then
    for f in "$SESS_DIR"/*; do
      [ -e "$f" ] || continue
      n=$((n + 1))
    done
  fi
  printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# caffeinate lifecycle. Exactly one verified caffeinate; adopt orphans;
# never trust or kill a name-mismatched PID.
# ---------------------------------------------------------------------------
caff_expected_name() {
  basename "$CAFF_BIN"
}

caffeinate_alive() {
  # Sets CAFF_PID on success.
  CAFF_PID=""
  [ -f "$CAFF_PIDFILE" ] || return 1
  pid=$(head -n 1 "$CAFF_PIDFILE" 2>/dev/null | tr -cd '0-9')
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  pid_name_matches "$pid" "^$(caff_expected_name)$" || return 1
  CAFF_PID="$pid"
  return 0
}

spawn_caffeinate() {
  if [ "$LID_CLOSED_MODE" = "1" ]; then
    flags="-is"
  else
    flags="-i"
  fi
  nohup "$CAFF_BIN" "$flags" -t "$TTL_SECONDS" >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$CAFF_PIDFILE"
}

# decide: call ONLY while holding (or having consciously failed to hold) the
# lock. Registry non-empty -> ensure exactly one caffeinate; empty -> kill it.
decide() {
  event="$1"
  sid="$2"
  n=$(count_sessions)
  if [ "$n" -gt 0 ]; then
    if caffeinate_alive; then
      dbg "$event" "$sid" "$n" "adopt" "$CAFF_PID"
    else
      spawn_caffeinate
      dbg "$event" "$sid" "$n" "spawn" "$(head -n 1 "$CAFF_PIDFILE" 2>/dev/null)"
    fi
  else
    if caffeinate_alive; then
      kill "$CAFF_PID" 2>/dev/null
      rm -f "$CAFF_PIDFILE"
      dbg "$event" "$sid" "0" "kill" "$CAFF_PID"
    else
      rm -f "$CAFF_PIDFILE"
      dbg "$event" "$sid" "0" "none" "-"
    fi
  fi
}

# Shared locked tail for register/unregister/reap.
reap_and_decide() {
  if lock_acquire; then
    reap_sessions
    decide "$1" "$2"
    lock_release
  else
    # Bounded-wait exhaustion: proceed unlocked rather than hang a hook.
    reap_sessions
    decide "$1" "$2"
  fi
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
# Resolution: AWAKENT_TEST_PID (test-only) > AWAKENT_SESSION_PID (adapters
# that know the agent PID, e.g. pi's process.pid) > $PPID (the hook's parent,
# i.e. the host process under Claude Code). AWAKENT_SESSION_PID set but
# invalid resolves to sentinel 0 (TTL-only) - fail closed, never fall through
# to an unrelated $PPID.
session_pid() {
  if [ -n "${AWAKENT_TEST_PID:-}" ]; then
    printf '%s' "$AWAKENT_TEST_PID"
  elif [ "${AWAKENT_SESSION_PID+set}" = "set" ]; then
    p=$(printf '%s' "$AWAKENT_SESSION_PID" | tr -cd '0-9')
    printf '%s' "${p:-0}"
  else
    printf '%s' "$PPID"
  fi
}

# Pattern recorded at registration (session file line 2): explicit env
# override wins, else the known process names for the registering host. For
# the default (claude/unset) host the observed parent-process name is
# recorded instead when it passes the charset check - so a Claude-hooks-
# compatible host reusing our manifest without AWAKENT_HOST still gets a
# correct liveness guard rather than being misjudged against claude|node.
host_proc_pattern() {
  if [ -n "${AWAKENT_PROC_PATTERN:-}" ]; then
    printf '%s' "$AWAKENT_PROC_PATTERN"
    return 0
  fi
  case "$HOST" in
    codex)   printf 'codex|node' ;;
    cursor)  printf 'cursor|node' ;;
    copilot) printf 'copilot|node' ;;
    pi)      printf 'node|bun|pi' ;;
    *)
      pid=$(session_pid)
      if [ "$pid" != "0" ]; then
        comm=$(ps -p "$pid" -o comm= 2>/dev/null)
        base=$(basename "$comm" 2>/dev/null)
        case "$base" in
          ''|*[!A-Za-z0-9_.-]*) : ;;
          *) printf '%s' "$base"; return 0 ;;
        esac
      fi
      printf 'claude|node'
      ;;
  esac
}

# Session file format: line 1 = PID (0 = ttl-only sentinel), line 2 = proc
# pattern for the reaper, line 3 = host tag for display.
write_session_file() {
  printf '%s\n%s\n%s\n' "$(session_pid)" "$(host_proc_pattern)" "$HOST" \
    > "$SESS_DIR/$SESSION_KEY" 2>/dev/null
}

# The file write happens under the same lock as reap-and-decide so a
# concurrent reaper can never read a session file mid-truncation.
do_register() {
  [ -n "$SESSION_ID" ] || return 0
  mkdir -p "$SESS_DIR" 2>/dev/null || return 0
  if lock_acquire; then
    write_session_file
    reap_sessions
    decide "register" "$SESSION_KEY"
    lock_release
  else
    # Bounded-wait exhaustion: proceed unlocked rather than hang a hook.
    write_session_file
    reap_sessions
    decide "register" "$SESSION_KEY"
  fi
}

do_unregister() {
  [ -n "$SESSION_ID" ] || return 0
  rm -f "$SESS_DIR/$SESSION_KEY" 2>/dev/null
  reap_and_decide "unregister" "$SESSION_KEY"
}

do_reap() {
  reap_and_decide "reap" "-"
}

do_touch() {
  [ -n "$SESSION_ID" ] || return 0
  f="$SESS_DIR/$SESSION_KEY"
  if [ -f "$f" ]; then
    touch "$f" 2>/dev/null
    # Throttled -t refresh: locked, and at most once per interval.
    mark_age=$(( $(now_epoch) - $(file_mtime "$REFRESH_MARK") ))
    if [ ! -f "$REFRESH_MARK" ] || [ "$mark_age" -gt "$REFRESH_SECONDS" ]; then
      if lock_acquire; then
        touch "$REFRESH_MARK" 2>/dev/null
        if caffeinate_alive; then
          kill "$CAFF_PID" 2>/dev/null
          rm -f "$CAFF_PIDFILE"
        fi
        decide "touch-refresh" "$SESSION_KEY"
        lock_release
      fi
    fi
  else
    # Self-heal: a live session whose file was reaped (e.g. after a forward
    # clock step) re-registers on its next activity.
    do_register
  fi
}

do_status() {
  # Strictly read-only: the reaper's liveness/expiry predicates are applied
  # as display filters. Nothing is deleted and no lock is taken.
  now=$(now_epoch)
  if caffeinate_alive; then
    printf 'assertion: held (caffeinate pid %s)\n' "$CAFF_PID"
  else
    printf 'assertion: released\n'
  fi
  max_age=-1
  if [ -d "$SESS_DIR" ]; then
    for f in "$SESS_DIR"/*; do
      [ -e "$f" ] || continue
      sid=$(basename "$f")
      pid=$(head -n 1 "$f" 2>/dev/null | tr -cd '0-9')
      mtime=$(file_mtime "$f")
      age=$((now - mtime))
      [ "$age" -lt 0 ] && age=0
      live=1
      ttl_only=0
      if [ -z "$pid" ]; then
        live=0
      elif [ "$pid" = "0" ]; then
        ttl_only=1   # sentinel: no PID to check, freshness alone decides
      elif [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ]; then
        if ! kill -0 "$pid" 2>/dev/null; then
          live=0
        elif ! pid_name_matches "$pid" "$(session_pattern "$f")"; then
          live=0
        fi
      fi
      if [ "$age" -gt "$TTL_SECONDS" ]; then
        live=0
      fi
      host_disp=$(session_host "$f")
      [ -n "$host_disp" ] && host_disp=" host=$host_disp"
      if [ "$live" = "1" ]; then
        if [ "$ttl_only" = "1" ]; then
          printf 'session: %s%s %sm ago (ttl-only)\n' "$sid" "$host_disp" "$((age / 60))"
        else
          printf 'session: %s%s %sm ago\n' "$sid" "$host_disp" "$((age / 60))"
        fi
        if [ "$age" -gt "$max_age" ]; then
          max_age="$age"
        fi
      else
        printf 'session: %s%s (stale)\n' "$sid" "$host_disp"
      fi
    done
  fi
  if [ "$max_age" -ge 0 ]; then
    printf 'release-in: %sm\n' "$(( (TTL_SECONDS - max_age) / 60 ))"
  else
    printf 'release-in: -\n'
  fi
  printf 'config: ttl_minutes=%s lid_closed_mode=%s debug=%s\n' \
    "$TTL_MINUTES" "$LID_CLOSED_MODE" "$DEBUG_ON"
  if [ "$DEBUG_ON" = "1" ]; then
    printf 'log: %s\n' "$LOG_FILE"
  fi
  if [ -n "$CONFIG_WARNINGS" ]; then
    printf 'config-warning:%s\n' "$CONFIG_WARNINGS"
  fi
}

# ---------------------------------------------------------------------------
# Entry: drain stdin (bounded; hooks always pipe - a TTY means a human),
# extract the session id (constrained on purpose: known keys, tight charset,
# not a JSON parser),
# dispatch inside a containment subshell so no internal failure can leak
# output or a nonzero exit back into the host agent.
# ---------------------------------------------------------------------------
STDIN_DATA=""
if [ ! -t 0 ]; then
  STDIN_DATA=$(head -c 65536 2>/dev/null)
fi

# No caffeinate (non-macOS machine sharing a cross-platform hooks config):
# full no-op, zero state written. Also keeps BSD-stat arithmetic from ever
# running on GNU systems.
if ! command -v "$CAFF_BIN" >/dev/null 2>&1; then
  if [ "$1" = "status" ]; then
    printf 'assertion: unsupported (caffeinate not found)\n'
  fi
  exit 0
fi

# Session id: hosts name the key differently - session_id (Claude Code,
# Codex, Cursor sessionStart), conversation_id (Cursor's other events),
# sessionId (Copilot CLI). Later seds run only on earlier misses.
extract_id() {
  printf '%s' "$STDIN_DATA" \
    | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]\{1,\}\)".*/\1/p' \
    | head -n 1
}
SESSION_ID=$(extract_id session_id)
[ -n "$SESSION_ID" ] || SESSION_ID=$(extract_id conversation_id)
[ -n "$SESSION_ID" ] || SESSION_ID=$(extract_id sessionId)

# Host tag: adapters set AWAKENT_HOST; lowercase alnum, <=16 chars, anything
# else falls back to claude. Non-claude session files are "<host>-<id>";
# claude files stay bare (pre-multi-host format). The filename is an opaque
# key - the host is never parsed back out of it.
HOST=claude
case "${AWAKENT_HOST:-}" in
  ''|claude|*[!a-z0-9]*) : ;;
  *) [ "${#AWAKENT_HOST}" -le 16 ] && HOST="$AWAKENT_HOST" ;;
esac
if [ "$HOST" = "claude" ]; then
  SESSION_KEY="$SESSION_ID"
else
  SESSION_KEY="$HOST-$SESSION_ID"
fi

load_config

case "$1" in
  register)   ( exec >/dev/null 2>/dev/null; trap 'lock_release' EXIT; do_register )   ;;
  unregister) ( exec >/dev/null 2>/dev/null; trap 'lock_release' EXIT; do_unregister ) ;;
  touch)      ( exec >/dev/null 2>/dev/null; trap 'lock_release' EXIT; do_touch )      ;;
  reap)       ( exec >/dev/null 2>/dev/null; trap 'lock_release' EXIT; do_reap )       ;;
  status)     ( do_status ) 2>/dev/null ;;
  *)          : ;;  # unknown/missing subcommand: silent no-op
esac

exit 0
