// emitted by ticketwright install v3.6.1 — do not hand-edit; re-run `ticketwright install --runtime opencode` to update.
// ticketwright — OpenCode tool gate: db_write_requires_approval, presented as an OpenCode plugin.
//
// OpenCode has no ask tier (`permission.ask` exists in the SDK types but never fires — open
// upstream issue), so the kit's guard is presented through the one documented deny mechanism:
// "throwing an error prevents the tool from executing" (tool.execute.before). The classification
// itself lives in bin/sql_scan.py behind bin/hook_shim.py --runtime opencode, which speaks the
// exit-code protocol: 0 passes, 2 denies with the message (deny-with-escape — the message names
// the one-shot re-approval, since a flat refusal with no escalation path trains people to turn
// the guard off).
//
// Installed by `ticketwright install --runtime opencode` into .opencode/plugins/ (plugins
// auto-load from there — plugins doc re-checked 2026-08-19). Requires the kit vendored in the
// repo (bin/tw present) — the installer checks that and says so.
//
// Failure posture, deliberately CLOSED: if the shim cannot be spawned at all (bin/tw missing,
// python3 missing, timeout), this wrapper throws — a guard that cannot run never guesses allow,
// and throwing is OpenCode's own documented posture for a hook error. `policies:
// db_write_requires_approval: off` disables the guard explicitly (the shim reads it and passes).

import { spawnSync } from "node:child_process"

const SHELLISH = ["bash", "shell", "terminal", "exec", "cmd", "run_command", "run_terminal_cmd",
  "execute_command"]

export const TicketwrightDbWriteGuard = async ({ directory }) => {
  const root = directory || process.cwd()
  return {
    "tool.execute.before": async (input, output) => {
      const tool = String((input && input.tool) || "")
      const shellish = SHELLISH.some((s) => tool.toLowerCase().includes(s))
      const command =
        (output && output.args && typeof output.args.command === "string" && output.args.command) ||
        (input && input.args && typeof input.args.command === "string" && input.args.command) ||
        null
      if (command === null && !shellish) return // not a shell call: outside the guard's jurisdiction
      const payload = JSON.stringify({
        tool_name: "Bash",
        // A shell-like call whose command we cannot see is forwarded WITHOUT a command: the shim
        // treats unreadable input as gated, never as allowed.
        tool_input: command === null ? {} : { command },
        cwd: root,
      })
      const res = spawnSync("bash", ["bin/tw", "hook_shim.py", "--runtime", "opencode",
        "--hook", "db_write_guard"], { input: payload, cwd: root, encoding: "utf8", timeout: 20000 })
      if (!res.error && res.status === 0) return // pass: OpenCode's own permission flow proceeds
      const detail = (((res.stdout || "") + "\n" + (res.stderr || "")).trim())
      throw new Error(detail ||
        "ticketwright db_write_guard: denied — the guard shim could not run (is the kit vendored? " +
        "bin/tw + bin/hook_shim.py). A guard that cannot run never guesses allow; set " +
        "policies.db_write_requires_approval: off in .claude/config/stack.yaml to disable it explicitly.")
    },
  }
}
