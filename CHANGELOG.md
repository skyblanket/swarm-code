# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - 2026-06-01

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
