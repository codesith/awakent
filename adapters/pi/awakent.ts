/**
 * awakent adapter for pi (https://pi.dev) - keeps the Mac awake exactly
 * while pi sessions are active.
 *
 * pi has no shell-command hook config, so this ~60-line extension is the
 * bridge: it fire-and-forget spawns the unchanged awakent shell engine on
 * pi lifecycle events. Zero npm dependencies (Node built-ins only), never
 * awaited - a broken awakent must never block or break the agent loop.
 *
 * Engine discovery order:
 *   1. $AWAKENT_ENGINE (explicit path)
 *   2. ~/.claude/hooks/awakent.sh (awakent's manual-install location)
 * Install: copy this file to ~/.pi/agent/extensions/awakent.ts
 * (or `pi install` this repo as a pi package).
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

function enginePath(): string | undefined {
  const candidates = [
    process.env.AWAKENT_ENGINE,
    join(homedir(), ".claude", "hooks", "awakent.sh"),
  ];
  for (const p of candidates) {
    if (p && existsSync(p)) return p;
  }
  return undefined;
}

function run(subcommand: string, sessionId: string | undefined): void {
  const engine = enginePath();
  if (!engine || !sessionId) return;
  try {
    const child = spawn("/bin/bash", [engine, subcommand], {
      detached: true,
      stdio: ["pipe", "ignore", "ignore"],
      env: {
        ...process.env,
        AWAKENT_HOST: "pi",
        // Extensions run in-process: process.pid IS the agent PID.
        AWAKENT_SESSION_PID: String(process.pid),
      },
    });
    // The engine reads stdin to EOF (bounded head -c) - stdin must be
    // written AND closed, or engine processes linger on the open pipe.
    child.stdin?.end(JSON.stringify({ session_id: sessionId }));
    child.unref();
  } catch {
    // Containment: awakent failures are never surfaced to the host.
  }
}

export default function (pi: any) {
  const sid = (ctx: any): string | undefined =>
    ctx?.sessionManager?.getSessionId?.();

  pi.on("session_start", (_event: any, ctx: any) => run("register", sid(ctx)));
  pi.on("input", (_event: any, ctx: any) => run("touch", sid(ctx)));
  pi.on("turn_end", (_event: any, ctx: any) => run("touch", sid(ctx)));
  pi.on("agent_end", (_event: any, ctx: any) => run("touch", sid(ctx)));
  pi.on("session_shutdown", (_event: any, ctx: any) =>
    run("unregister", sid(ctx))
  );
}
