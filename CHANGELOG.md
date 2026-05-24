# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
