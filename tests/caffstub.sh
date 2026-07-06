#!/bin/bash
# Test-only caffeinate stand-in: records argv (for flag assertions) and
# lives briefly so PID checks have something to look at. Never used in
# production; selected only via AWAKENT_CAFFEINATE.
if [ -n "${CAFFSTUB_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$CAFFSTUB_LOG" 2>/dev/null
fi
sleep 3
