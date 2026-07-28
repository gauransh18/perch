# Perch

Your coding agents, in the notch.

Perch is a native macOS menu-bar app that puts every running AI coding agent into
the Dynamic Island — what each one is doing right now, what it changed, how much
it cost, and a one-click jump back to the exact terminal tab it lives in. On Macs
without a notch it draws the same island as a floating bar in the menu bar.

Built with Swift + SwiftUI. No Electron, no account, no cloud, no telemetry.

---

## What it does

**Watch** — every Claude Code session shows up the moment it starts. Live tool
feed: `Read`, `Edit`, `Bash`, `Grep`, subagents, with per-session `+lines/−lines`.

**Approve** — optional. Turn it on and tool calls surface in the notch with a
real diff preview; `⌘Y` allows, `⌘N` denies, `esc` hands the decision back to
Claude's own prompt. Read-only tools can auto-allow so you are only asked about
things that actually change something.

**Jump** — one click puts you back in the precise tab, split, or tmux pane the
agent is running in. Scripted support for iTerm2, Terminal.app, tmux, WezTerm and
kitty; app activation for Ghostty, Warp, Hyper, Alacritty, VS Code and Cursor.

**Cost** — reads the session transcript and shows tokens and dollars per session
and in total, so a runaway loop is visible before the bill is.

**Everything else** — chiptune alerts synthesised at runtime (no audio files),
process discovery for agents with no hook support, external-monitor aware,
follows you across Spaces and full-screen apps.

## Build

```bash
./build.sh release
```

Produces `dist/Perch.app` (ad-hoc signed). Then:

```bash
open dist/Perch.app
```

Requirements: macOS 14+, Swift 6 toolchain (Xcode 16+).

## How it works

Perch runs a loopback-only HTTP listener on an ephemeral port. On first launch it
writes `~/.perch/hook.sh` and registers it in `~/.claude/settings.json` for
`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`,
`Stop`, `SubagentStop`, `PreCompact` and `SessionEnd`. The shim pipes the hook's
JSON straight to the app along with terminal identity (`TERM_PROGRAM`, tty,
`ITERM_SESSION_ID`, `TMUX_PANE`, …) so the jump-back is exact.

The installer merges — your existing hooks are preserved, and your previous
settings file is copied to `~/.claude/settings.json.perch-backup` before writing.

**The shim fails open.** If Perch is not running, the port file is missing, or
curl errors, it exits 0 with no stdout and your agent behaves exactly as it would
without Perch installed. Quitting Perch is always a safe escape hatch.

### Other agents

Anything can report in — POST to the endpoint and it appears in the notch:

```bash
curl -H "X-Perch-Token: $(cat ~/.perch/token)" \
     -H "Content-Type: application/json" \
     -d '{"session_id":"my-agent-1","agent":"codex","cwd":"'"$PWD"'",
          "tool_name":"Bash","tool_input":{"command":"pytest"}}' \
     "http://127.0.0.1:$(cat ~/.perch/port)/hook/PreToolUse"
```

Agents that do not report are still detected by name from the process list
(codex, gemini, aider, opencode, amp, droid, goose, qwen, crush) and listed
read-only.

## Approval mode, honestly

Off by default, and it is worth understanding before turning it on.

When enabled, Perch answers Claude Code's `PreToolUse` hook with `allow` or
`deny`. An `allow` from Perch **bypasses the permission rules you configured in
Claude Code** — that is what makes it fast, and it is also the risk. Anything
Perch does not decide (timeout, `esc`, Perch not running) falls through to
Claude's normal prompt, never to a silent yes.

`⌘Y`/`⌘N` from another app need Accessibility permission; Settings shows the
state and asks for it only when you turn approvals on. Without it the shortcuts
work when the panel itself has focus, and the buttons always work.

## Privacy

- Listener is bound to the loopback interface and gated by a 0600 token file.
- Requests carrying `Origin` or `Sec-Fetch-Mode` are refused, so a web page
  cannot reach it.
- Session content, transcripts and metadata never leave the machine. There is no
  network code other than the loopback listener.

Cost figures use approximate list prices. Override them with `~/.perch/pricing.json`:

```json
{ "sonnet": { "in": 3, "out": 15, "cw": 3.75, "cr": 0.3 } }
```

## Files

```
Sources/Perch/
  App/          entry point, menu bar, prefs, global hotkeys
  Model/        sessions, activities, tool-input summarisation, pricing
  Server/       loopback HTTP listener, hook shim, event router
  Integration/  Claude Code installer, terminal jumper, process scan, transcripts
  Notch/        island geometry, panel window, SwiftUI views
  Settings/     settings window
  Sound/        runtime chiptune synth
```

## Uninstall

Settings › Claude Code › Remove, then quit. Or by hand:

```bash
rm -rf ~/.perch
```

and delete the `$HOME/.perch/hook.sh` entries from `~/.claude/settings.json`.
