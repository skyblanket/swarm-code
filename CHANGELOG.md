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
