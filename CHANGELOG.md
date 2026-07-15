# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-07-15

The responsiveness release: the agent never blocks the terminal and the
terminal never lies about what the agent is doing. Everything here was
hardened against real field sessions — every headline fix below was
found in live use and shipped with a regression test. Suite 105 → 160.

### Added

- **Bash auto-backgrounding.** Long-running commands no longer block the
  agent: in interactive sessions a bash call still running after 15s
  (`background_after_ms`, 0 disables) is handed off to a detached
  process group with its log streamed to disk from t=0, and the agent
  wakes on completion (`bg_done`). `run_in_background: true` detaches
  immediately. ESC during the foreground wait kills the whole process
  group. A one-shot `bg_stalled` wake fires when a task's log goes
  silent for 45s and the tail looks like an interactive prompt.
- **Incremental streamed markdown.** The LLM call runs off the main
  loop and each markdown block renders once at its boundary — raw
  markdown never appears on screen, and the old stream-then-repaint
  flicker and tall-response scrollback duplication are gone entirely.
- **Live, phase-aware stream ticker**: `◐ 12s · 176 tok · esc to
  interrupt`, with honest phases — `waiting for first token · 361 KB
  sent · slow/queued?` before the first byte, `thinking · 2.1k` during
  reasoning, `2.1k think · 176 tok` once content flows.
- **LLM request timeout** (`llm_timeout_ms`, default 300s inactivity):
  a stalled connection is killed and retried transparently, with an
  explicit "no first token in 300s — server stalled/queued" diagnostic,
  and ESC now kills the underlying connection in milliseconds.
- **Input that survives turns**: type-ahead during a running turn seeds
  the next prompt (editable) instead of being eaten; mid-turn pastes
  survive; prompt history persists to `~/.swarm-code/history`.
- **Markdown engine completeness**: italic/`__bold__`/strikethrough/
  escapes, `~~~` fences with language labels, bordered + keyword-
  highlighted code blocks with wrap continuation, indented code blocks,
  nested blockquotes, table cell wrapping with real alignment and
  CJK/emoji-aware widths, OSC-8 hyperlinks.
- **Real diffs**: line-level LCS diffs with context and hunk headers
  for `edit`/`multi_edit` — and for `write` overwrites.
- **New surfaces**: `/bg` (list/tail/kill background tasks), `/expand`
  (full output of the last capped tool result), `/mode` cycling with
  auto-accept-edits, unknown-slash feedback, plan-confirm ESC=cancel,
  footer with cwd + git branch, terminal title, COLORTERM 256-color
  fallback, once-per-session `/compact` hint on 300KB+ turns.
- **web_search resilience**: five-tier engine cascade (DDG html → DDG
  lite → Bing → Startpage → Wikipedia) with per-tier diagnostics — a
  bot-walled engine now reports "(no results — ddg: bot-blocked; …)"
  plus a `web_fetch` hint instead of silently returning nothing.

### Fixed

- **The 152-second crash**: self-tail-calls in `receive … after` bodies
  are now TCO'd by the swarmrt compiler, so long tool waits no longer
  overflow the fiber stack (SIGBUS). Stack overflow in general is now a
  recoverable per-process panic — supervised restart instead of binary
  death — and `SW_PROC_STACK` can raise the fiber stack per-binary.
- **The heartbeat freeze**: `shell()` had a hidden 1-second minimum per
  call (now 3–5ms) and scheduler housekeeping ran per-tick on the main
  fiber — during long turns the tick backlog outgrew the drain rate and
  input froze indefinitely. Ticks now coalesce and pruning is
  cadence-gated.
- **Line editor**: multi-line paste + continued typing no longer
  overlaps stale rows (row-accurate repaint with a single render/measure
  walk); sub-1KB pastes are no longer misparsed; the caret no longer
  parks 15 columns right of the typing spot (prompt color codes were
  counted as visible width).
- Requires swarmrt ≥ 1.0.0 (ships the runtime side of all of the
  above: `shell_detached`/`pid_kill_group`, the stdin pending-input
  ring, `rl_history_*`, routed-stream kill, and the line-editor
  rewrite).

## [1.0.0] - 2026-07-03

First production release. The 1.0 cut hardens the TUI (markdown list
rendering, edit diffs, NO_COLOR), adds the dragonfly identity, and closes the
audit items from `docs/HARNESS_REVIEW_2026-07.md`. Verified by a full
compile + 96/98 test suite on linux-arm64 (2 failures are sandbox-$HOME
artifacts, pre-existing at the same count on the previous commit).

### Added

- Markdown: ordered lists (`1.` / `1)`) render one item per line with hanging
  indents — previously they fell into the paragraph branch and were space-merged
  into a single line. Nested bullets keep their depth (• ◦ ▪ ▫ markers), task
  lists (`- [ ]` / `- [x]`) render as checkboxes, `+ `-bullets are recognized,
  and table header rows are bold.
- Ink-brush dragonfly startup banner (skipped under 64 cols) with a hanko-style
  `sw` seal, after the Otonomy insect artwork.
- Colored ± diff preview under successful `edit`/`multi_edit` results — the
  user sees what changed, not just "ok: edited path". Display-only (never
  journaled, costs zero context) and suppressed in headless mode.
- `NO_COLOR` support (no-color.org): any non-empty value disables all color
  emission from the UI palette; bold/dim formatting survives.
- Soft max-steps ceiling: at 90% of the per-turn tool-step cap the model gets a
  one-shot ephemeral nudge to wrap up, instead of discovering the hard cap
  after being cut off.
- `glob` now says when results were capped at 100 (fetches 101, shows 100 +
  notice) instead of silently truncating; schema descriptions for `glob`/`grep`
  document their caps.
- Markdown regression tests: ordered-list line-splitting, nested-bullet
  markers, task-list checkboxes, `has_markdown` ordered-list detection.
- Live wait-feedback on every blocking operation: a pre-flight model/throughput
  hint plus a live `tok/s` counter during LLM calls, and a "still running (Ns)"
  heartbeat for long bash/tool, browser (CDP), MCP-server boot, and
  `/memory reindex` waits — all suppressed in headless, subagent, and
  MCP-server contexts so they never pollute a result or the JSON-RPC stream.
- `SECURITY.md` documenting the fail-closed model and responsible disclosure.

### Changed

- Telemetry `tool_call` arg preview widened 400 → 2000 chars — 400 clipped most
  write/multi_edit args and blinded the audit trail. `event()` still redacts
  the full encoded line, so masking is unchanged.
- `has_markdown` also fires on numbered lists, leading-`|` tables, and
  `[label](url)` links, so those replies get the post-stream render pass.
- Added `ToolExecutor.sw` as the shared execution-policy boundary for Agent,
  subagent, and MCP server calls. Context allow-lists, argument-rewriting
  hooks, guardrails, permissions, and post hooks now follow one path.
- Centralized MCP server and subagent tool-context policy in `ToolRegistry.sw`.
- MCP client and server metadata now use the generated single-source version.
- Added `make check` as the production verification gate and wired CI/release
  jobs to run unit, smoke, integration, and focused module checks.
- Switched the built-in and installer-seeded default model to Kimi K2.7 Code
  (`kimi-k2.7-code`).
- Added an experimental bounded council runner with read-only panel and
  no-tools judge execution contexts.
- Added integration coverage proving council panel children cannot execute
  shell commands.

### Fixed

- MCP server tool calls can no longer bypass hardline command policy.
- Hook-rewritten arguments are checked by guardrails and permissions before
  raw handlers execute.
- Tool execution now fails closed when its execution context is missing or
  unknown.
- MCP server now conforms to JSON-RPC 2.0: notifications get no `id:null` reply
  and run no side-effects; malformed/batch/missing-method requests return
  `-32600`; `isError` is determined structurally rather than by string matching.
- Headless (`-p`/`--json`), subagent, and MCP-server output no longer leak
  feedback or diagnostic text onto the result or the JSON-RPC stream — kept on
  stderr or suppressed.

### Documentation

- Replaced the stale comparison review with a current maintainability roadmap.
- Updated README architecture, source size, and MCP server capability.
- Rewrote the README (badges, quickstart, configuration, security) and moved
  internal working notes (`AUDIT`, `REVIEW`, `UPGRADE_PLAN`) under `docs/`.

## [0.4.0] - 2026-06-10

### Added — launch sweep

- **`/flows` — multi-agent parallel workflow orchestrator.** JSON workflow
  definitions or inline task pairs fan out as headless swarm-code children
  with a live 3-panel TUI. Children run with `SWARM_CODE_DENY_DANGEROUS=1`
  so dangerous bash hard-denies instead of headless auto-approving;
  `Background.launch` clears stale `/tmp` exit/pid/log files so a previous
  session can never instantly mark a fresh task done.
- **Secret redaction** (`Log.redact`) applied to every `events.jsonl` write
  and both trajectory-export paths. Live env keys, known token prefixes
  (word-boundary checked), Bearer tokens, key/value shapes, and a long-blob
  heuristic tuned to skip git SHAs and file paths.
- **Integration test suite** (`make integration`): mock OpenAI SSE endpoint
  + the real binary under an isolated `HOME` — prompt round-trip, tool_call
  round-trip, read/write tools, hardline-block refusal, journal resume.
- **Single-source version**: `VERSION` file → generated `src/Version.sw` at
  build time; the binary reports the real release version.

### Fixed — launch sweep

- **MCP lifecycle (audit #14/#15/#16)**: configured servers pre-register as
  `starting` so late handshakes attach instead of orphaning; failed servers
  lazily auto-reconnect on next use (60s cooldown) with a 2-strike timeout
  policy; response-id matching via `to_string` (numeric-vs-string id echo no
  longer times out every call); pagination under one cumulative deadline.
- **Scheduler PID-reuse wedge (audit #23)**: pidfile records PID + process
  start-time and liveness re-verifies `lstart`, so a recycled PID can no
  longer wedge a job in `skipped_busy`; `skipped_busy` no longer bumps
  `last_run`; retention off-by-one (keeps the documented 10 newest).

### Fixed — UI/markdown + full multi-agent audit (39 verified findings, see docs/AUDIT.md)

**UI / markdown rendering**
- **`render_table` now clamps to the terminal width** (P1) — wide tables overflowed and the terminal hard-wrapped mid-cell, destroying alignment. Column widths are scaled to fit and over-wide cells are truncated on the *raw* text (before ANSI is added, so no escape is ever split) with an ellipsis.
- **Post-stream repaint now clears the exact prose region** (P2). New swarmrt builtin `stream_content_rows()` reports the physical rows the C stream emitter actually produced for the assistant's content (soft-wrap + UTF-8 width accounted for) — replacing the byte-based `count_terminal_rows` estimate that under/over-counted (leftover raw markdown, or clearing into the reasoning block above). Falls back to the estimate if unavailable.
- **Repaint clear threshold is now viewport-aware** via the new `term_rows()` builtin (was a fixed 25), so normal long answers re-render cleanly instead of being duplicated raw-then-rendered.
- **Markdown links** `[label](url)` now render (label + dimmed url) instead of raw syntax.
- `has_markdown` no longer false-fires on `C#`/a lone backtick (needs a balanced pair or a line-start heading) → no spurious repaint frame.
- `display_width` accepts any ASCII-letter CSI terminator (was a partial hand-list that swallowed text on unlisted finals).
- Bold inline guards against empty (`****`) and space-flanked (`a ** b ** c`) false emphasis.

**Streaming / LLM**
- **`\uXXXX` decode in the streaming SSE path** (P1, swarmrt) — both the content and reasoning escape loops now decode `\u` escapes (with surrogate pairs) to UTF-8. Em-dashes, accents, CJK, and emoji from `\u`-escaping servers no longer arrive as literal `u2014`/`ud83d…` in the stream and stored history.
- **`repair_history` backfills partial tool-result sets** (P1) — a crash mid-`execute_all` left `assistant(tool_calls=[a,b]) + tool(a)`, which 400'd the API on every reload until `/reset`. Missing ids now get a synthesized stub result.
- **`finish_reason:"length"` recovery actually fires** (P2) — it was dead (the stream never emits the field). Detects the truncation marker instead and surfaces the model's reasoning on a reasoning-only truncated turn.
- **`tok_budget` divide-by-zero guard** (P2) — a degenerate `MAX_TOKENS`/reserve/buffer combo panicked on the first turn; clamped to a floor.
- **Inband marker strip aligned with `parse_gemma_calls`** (P2) — `.call:`/` call:` (GLM-5.1) markers no longer leak into stored content + duplicate on the next request.
- Retry jitter uses `random_int` (true entropy) instead of timestamp low-bits (which collided for same-ms restarts); `record_usage(nil)` retains the last-known token counts instead of wiping them; removed the dead `"interrupted"` retry branch.

**Tools / safety / config**
- **Long-tail tools are reachable in native mode** (P1) — `git_*`, `code_search`, `background`, `bg_*`, `sys_stats`, `heartbeat_status`, `log_wait`, `file_watch`, and `forget` had handlers + prose but **no native schema**, so the default (Kimi/native) user couldn't call them. Added typed schemas (arg names matched to the handlers).
- **Hardline blocklist matches whole command words** (P2) — `shutdown`/`reboot`/`halt`/`poweroff`/`init 0|6` were bare substrings, so `cat asphalt_survey.csv` / `vim shutdown_handler.py` were unbypassably blocked. Now boundary-matched (over-blocks rather than under-blocks — never weakens the floor).
- `web_fetch` schema corrected to match the implementation (no fake required `prompt` / "small-model extraction"); `forget` schema added; dead `context_meter` schema removed.
- `max_tokens` from a profile/settings.json is coerced to int (a quoted `"8192"` previously 400'd every turn).
- `todo_write` added to the subagent block-list (subagents shared the main agent's todo ETS key).

**Sessions / scheduler / background**
- **Session search escapes FTS5 special chars** (P2) — `C++`, `obj-c:`, partial quotes etc. silently returned zero hits; now quoted per-token.
- **Scheduled jobs no longer fire immediately on creation** (P1) — `last_run` seeded to now instead of epoch.
- Background poll/kill status transitions use `ets_cas` (compare-and-swap from `pending`), so a killed task can't be resurrected as done/error by a racing poll.

**Tests** — suite grew 38 → 43: partial-tool-result backfill, hardline word-boundary, `has_markdown` tightening, markdown link render, table width clamp.

### Added — production hardening from the parity audit

**Safety (P0)**
- **Hardline command blocks** in `config.sw` — `mkfs`, `mkswap`, `dd if=... of=/dev/{sd,nvme,disk,rdisk}`, `shutdown`, `reboot`, `halt`, `poweroff`, `init 0`, `init 6`, `chmod 000 /`, `chown -R 0:0 /`, the literal fork bomb, and `rm -rf /*`. Unbypassable — `SWARM_CODE_ALLOW_DANGEROUS` does NOT disable them.
- **Path traversal validation** on write tools (`do_write`, `do_edit`, `do_multi_edit`) — blocks writes to `.ssh/`, `/etc/`, `.aws/`, GH and git credential files, and `~/.swarm-code/settings.json`. Read-only tools stay unrestricted. Bypass via `SWARM_CODE_UNSAFE_WRITES=1`.
- **Sudo refusal** in `do_bash` — sudo commands are rejected unless `SWARM_CODE_ALLOW_SUDO=1` is set, since the model has no way to enter a password safely.
- **Tool-call guardrails** (new `ToolGuardrails.sw` module) — detects 5 consecutive identical calls, 8 consecutive failures of the same tool, and 5 consecutive idempotent reads without any mutating action. Halts the turn before runaway API costs accrue.
- **Subagent toolset restriction** — subagents can no longer call `task`, `remember`, `forget`, `learn_skill`, `forget_skill`, `bg_server`, `browser_launch`, or `git_commit`. Each blocked call returns a refusal `tool_result`.
- **Secret hygiene** — `~/.swarm-code/.gitignore` is auto-written on first interactive launch, excluding `settings.json`, `.profile_override`, session journals, telemetry, exports, schedule.json, and MCP server logs.

**Reliability (P1)**
- **`finish_reason: length` recovery** — when the server returns empty `content` but populated `reasoning_content` plus `finish_reason: "length"`, the reasoning is surfaced as the prose with a `[truncated due to length]` marker. Kimi K2 in thinking-mode and other reasoning models no longer hand the user a blank turn.
- **Jittered exponential backoff** — `retry_delay_ms` replaces fixed 1/2/4s delays with `min(base * 2^attempt, 30s) * (1 + jitter)` where jitter is 0–50% from timestamp's low 10 bits. Avoids thundering-herd if many agents restart simultaneously.
- **Message alternation repair** — new `LLM.repair_history` runs before every API call. Drops orphan `role:'tool'` messages, drops trailing `assistant` messages with unmatched `tool_calls`, collapses consecutive `user` messages. Turns API 400s into degraded-but-valid requests.

### Fixed

**Scheduler** (4 bugs found during the parity review)
- **Unit mismatch** — `parse_interval`/`parse_expr` returned seconds while `timestamp()` returns milliseconds, so `"1h"` was actually firing every ~3.6 seconds (only PID back-pressure was masking it). Everything now ms-aligned end-to-end. Pre-existing jobs heal automatically on next tick.
- **`daily HH:MM` previously unimplemented** — the form parsed as the 24h-interval branch and discarded the time. New `daily_time_ms` parses `HH:MM` to ms-since-midnight; `compute_next_fire` schedules wallclock-aligned fires (UTC).
- **Hardcoded binary path** — `swarm_binary_path()` fell back to `/Users/sky/swarm-code/bin/swarm-code`. Replaced with: `SWARM_CODE_BIN` env → `os_args()[0]` (when path-like and exists) → `~/.local/bin/swarm` → PATH lookup → `swarm`.
- **`save_all` on every tick** — `tick_loop` unconditionally rebuilt a same-length list, so `length(updated) > 0` was always true and `schedule.json` got rewritten every 2s. Now dirty-flagged: only saved when a job actually fired.

**Hygiene**
- `apply_override` no longer panics when `getenv("HOME")` returns nil (same guard the 26-swarm audit applied elsewhere).
- `Skills.forget` success check tightened — only `rc == 'ok'` counts; previously `nil` was treated as success, masking silent `file_delete` failures.
- `Vision.paste_from_clipboard` wraps `osascript || xclip` in a perl-alarm guard (8s) so a wedged X server can't hang the REPL.

### Tests
Suite grew from 22 to 38 checks. New regression guards:
- Scheduler: ms units, daily-HH:MM parsing, daily rejection of garbage, compute_next_fire ms math
- Security: hardline patterns unbypassable, write-path traversal blocked, sudo refused
- Reliability: repair_history drops orphan tool / trailing unmatched / collapses users / preserves matched pair
- Guardrails: identical-call block, idempotent-streak block, mutation reset, same-tool failure halt
- Subagent: task/remember blocked, read/bash allowed

---

## [0.2.0] - 2026-05-24

### Added

**Profiles, skills, and search**
- Per-profile settings with `/profile` swap mid-session and slash commands
- Skills framework with auto-injected `SKILLS.md` index and CRUD tools
- Session search via SQLite FTS5 over journals with `/search` command
- Trajectory export to OpenAI fine-tuning JSONL via `/export-trajectory`
- Cron scheduler (`/schedule`, `/schedules`, `/unschedule`) fired by heartbeat

**Vision**
- `read_image` tool encoding images as base64 `image_url` blocks
- Auto-attach image paths from user input with unescaped-space handling
- Clipboard paste (`/paste`) for macOS and Linux

### Changed

**Profiles, skills, and search**
- Bash output truncation keeps 40% head + 60% tail with elision marker
- Skill activation rule promoted to mandatory `recall_skill` first

**Vision**
- Vision defaults to ON (was opt-in per profile)

**Refactor**
- Tool dispatch: 47-case if/else ladder replaced by function registry
- `ToolRegistry.sw` centralizing schema-driven name-to-atom mapping
- Native mode `tool_calls` are structured end-to-end; removed text transcoding (-455 LoC, journal v2)

### Fixed

**Profiles, skills, and search**
- `chat_completions_url()` no longer doubles `/v1` on `/v1` endpoints
- `browser_*` tools recognized in inband mode (added missing `string_to_atom` cases)
- Scheduler cron syntax error: dispatch now wrapped in `bash -c`

**Vision**
- Slash dispatcher no longer rejects Unix paths as unknown commands
- `/profile` swap now propagates `vision` flag to `opts.vision`

### Performance
- Replaced `shell()` calls with `file_*` builtins on startup paths, cutting warm boot ~14 s → ~5.7 s
- Applied 7 headless-audit fixes (`file_mkdir`, flat `events.jsonl`, `file_list`), cutting warm boot ~5.7 s → ~0.6 s

### Security & correctness — applied from the 26-swarm self-audit
- **Liveness**: `receive` blocks in `agent.collect_tool_result`, `ask_via_reader`, and `run_subagent_loop` now have deadlines — a hung tool/reader/subagent can no longer freeze the REPL forever
- **Race**: `browser.next_msg_id` uses a randomised ID range instead of a non-atomic read-modify-write ETS counter
- **Shell injection**: `tools.do_web_search`/`do_log_wait`/`do_file_watch`, `memory.migrate_legacy`, `log.summarize` now wrap previously-unquoted args with `Util.shell_q`
- **Path traversal**: `mcp.mcp_log_path` sanitises server name from user config before interpolating into the log path
- **Nil-deref crash sites**: `llm.extract_content_impl`, `main.manifesto_path`, `arthopod.generate_soul` now guard `getenv("HOME")` / `choices` / `content` against nil
- **Markdown rendering**: code spans now have precedence over bold — `` `**text**` `` renders as code, not bold
- **MCP boot race**: boot deadline bumped past handshake timeout so slow servers actually land in `all_servers`
- **TOCTOU**: `/tmp/swarm-code-last-body.json` uses an `mktemp`-style path to avoid the world-writable symlink race

### Engineering practice — dogfooded experiments
- Parallel 26-swarm bug audit: see `docs/internal/audit-2026-05-24.md`
- Parallel 24-swarm test generation: 8 module tests landed in `tests/`, runnable via `make test-all` (writeup at `docs/internal/test-gen-2026-05-24.md`)
- Parallel 23-swarm patch drafting from the audit: 17 of 23 patches applied cleanly (writeup at `docs/internal/patch-2026-05-24.md`, per-patch proposals under `docs/internal/applied-patches/`)
