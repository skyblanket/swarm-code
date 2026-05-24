# swarm-code Self-Improvement Document

> A living guide to the codebase's technical debt, known limitations, and improvement opportunities.
> Last updated: 2025-05-23

## Architecture

### What's Solid

- **Module boundaries are clean.** `main.sw` orchestrates, `agent.sw` runs the REPL, `llm.sw` handles wire formats, `tools.sw` dispatches, `agents.sw` manages the studio. Dependencies are acyclic (Mcp imports nothing; Tools imports Mcp but not vice versa).
- **Zero external runtime deps.** Single ~3MB binary. No Node, no Python, no Electron.
- **Process model is correct.** One process per subagent, mailbox-based communication, ETS for shared state. This mirrors Erlang/OTP and is the right abstraction for the swarmrt runtime.
- **Crash recovery journal** is the only way to survive a C-level VM fault. JSONL append-only, atomic `.active` pointer. Correctly implemented.
- **Token-aware compaction** uses real `prompt_tokens` from server `usage`, not char estimates.
- **Dual tool-calling formats** (native vs inband) with a clean transcoding layer. The rest of the agent only sees one format.
- **MCP client architecture** — one owner process per server, serializing concurrent calls onto a single stdio pipe. Exactly an Erlang port. Zero-cost when unused.
- **Reader process pattern** prevents stdin races between permission prompts and user input.

### What's Brittle

**1. The `opts` map is a god object**

`main.sw` builds it with ~15 chained `map_put` calls. It gets passed into almost every function. There's no protocol or behavior abstraction for tools — just a giant `if/else` chain in `Tools.exec` with 40+ branches.

Adding a tool means touching **at least 3 files**: `tools.sw` (handler), `prompts.sw` (prose description), `ToolSchemas.sw` (JSON schema). This is error-prone and doesn't scale past ~50 tools.

**Possible direction:** Define a `Tool` record/behavior that carries its own schema, description, handler, and permission check. Register tools into a table at boot. `Tools.exec` becomes a table lookup instead of a 40-branch `if/else`.

**2. Error handling is ad-hoc**

Some functions return `"error: ..."` strings, some return `nil`, some return atoms (`'ok'`, `'noop'`), some just print and continue. There's no consistent result type.

Examples:
- `Tools.exec` returns a string, which may start with `"error:"` or `"ok:"` or be raw output
- `Browser.cdp_call` returns `nil` on timeout, `"error: ..."` on CDP error, or a map on success
- `Mcp.call_tool` returns whatever the MCP server returns — no wrapping

**Possible direction:** A standard `Result` type — `{'ok', Value}` or `{'error', Reason}` — used consistently across all tool boundaries. The agent loop can then pattern-match on results instead of string-prefix checking.

**3. ETS shared state has no concurrency controls**

ETS tables are shared mutable state across processes with no locking semantics. If two subagents write the same todo ID concurrently, behavior is undefined. The todo table, background task table, and browser table are all vulnerable.

**Possible direction:** For tables that need atomic updates (todos, background state), either:
- Serialize all writes through a single owner process (like MCP does)
- Or add an `ets_compare_and_swap` builtin to swarmrt for atomic CAS

**4. Background task pid reading uses a race condition**

```sw
shell(detach_cmd)
ets_put(table, task_id ++ "/status", 'pending')
# ...
sleep(20)  # <-- race
pid_content = file_read(pid_file)
```

Comment admits it: "tiny race but ok." The correct fix is to have the shell wrapper write the pid to a known fd or use a blocking read with timeout.

---

## Language Limitations (sw)

`sw` lacks pattern matching, records, and sum types. The codebase pays for this everywhere.

**The hex_digit problem:**

```sw
fun hex_byte(hex, i) {
    c = string_sub(hex, i, 1)
    if (c == "0") { 0 } else {
    if (c == "1") { 1 } else {
    ...
    if (c == "f") { 15 } else { 0 }}}}}}}}}}}}}}}}
}
}
```

Same pattern in `parse_budget_env`, `string_to_perm`, `capitalize_first`, `digits_only`, `char_to_digit`, `rarity_stars`, `rarity_color`, `hex_byte`. These are 3-line functions in any modern language; here they're page-long ladders.

**Impact:**
- Harder to read
- Harder to modify (add one case → reindent 15 levels)
- More bug-prone (easy to mismatch braces)

**Mitigation (until sw improves):**
- Extract helper functions aggressively. `hex_byte` could call `char_to_hex_digit(c)` which is still a ladder but at least isolated.
- Use maps for lookup tables where possible instead of nested if/else.
- Consider generating some of this boilerplate from a small script at build time.

---

## Testing

**Current state:** 18 unit tests covering ~10K LOC. Good regression tests for specific crash bugs, but coverage is too thin.

**Missing tests:**
- `Browser` module — CDP is complex and easy to break. No tests for `cdp_call`, `navigate`, `click`, `evaluate`, screenshot handling.
- `UI` module — all ANSI rendering is unverified. No tests for `tool_header`, `tool_result`, `stream_chunk_render`, wrapping logic.
- `Markdown` edge cases — nested formatting, long tables, code fences with language hints, empty input, Unicode.
- `Mcp` — handshake logic, `tools/list` parsing, error recovery when server crashes.
- Integration test for the full agent loop — mock LLM endpoint, send one user message, verify the tool call round-trip.
- Heartbeat/background polling interaction — verify `bg_done` message is delivered when a task finishes mid-tick.
- `LLM.build_request_body` with various history shapes — system-only, assistant-with-tools, user-with-images (future).

**Possible direction:**
- Add a mock LLM endpoint for integration tests (a small Python or shell script that speaks SSE)
- Add property-based tests for `string_split`, `json_encode`/`json_decode` round-trips
- Add visual regression tests for UI output (capture ANSI strings, compare to golden files)

---

## Module-Specific Notes

### `agent.sw` (1814 lines) — The REPL Loop

**Good:** Crash recovery journal, token budgeting, compaction, permission prompts, subagent message handling, stream rendering. A lot of complex logic in one place and it's mostly correct.

**Not good:** Too long. `run()` is the entry point but the file also contains:
- Journal read/write/encoding
- Token budgeting and compaction logic
- Permission prompt handling
- Subagent message dispatch
- Stream chunk rendering coordination
- History management helpers

**Possible direction:** Split into `journal.sw`, `budget.sw`, `permissions.sw`. Keep `agent.sw` focused on the REPL loop only.

### `tools.sw` (1423 lines) — Tool Dispatch

**Good:** Every tool is wrapped with timeout, output truncation, and consistent formatting. The `with_timeout()` Perl alarm guard is elegant and zero-dependency.

**Not good:** The `exec` function is a 40-branch nested `if/else` chain. Adding a tool requires editing this central chokepoint. No dynamic registration.

**Not good:** Some tools do too much inline. `do_bash` is 100+ lines handling timeout override, working directory, spinner, exit code formatting. Could be cleaner.

### `llm.sw` (869 lines) — LLM Client

**Good:** Dual format support (native/inband), streaming SSE parsing, usage tracking, history reconstruction for native mode.

**Not good:** `messages_to_maps_native` is complex and undertested. The history walker rebuilds structured `tool_calls[]` from inband text every request. A bug here causes infinite loops or dropped tool context.

**Not good:** No retry logic for transient HTTP failures. If the server returns 502 or times out, the agent just surfaces the error and stops.

### `agents.sw` (716 lines) — Subagent Studio

**Good:** Real process model, mailbox-based ask/tell/kill, registry with status tracking, token accounting.

**Not good:** `agent_message_loop` is long and handles history, LLM calls, tool dispatch, and status updates all in one function.

**Not good:** Subagents can't spawn their own subagents (no recursive forking). Documented limitation but worth revisiting.

### `mcp.sw` (623 lines) — MCP Client

**Good:** Clean architecture — owner process per server, serializes concurrent calls, stderr redirected to log files.

**Not good:** No tests. Handshake timeout is 30s which may not be enough for first `npx` runs on slow networks.

**Not good:** If an MCP server crashes mid-session, the owner process dies but there's no auto-restart. The tool just starts returning errors.

### `ui.sw` (702 lines) — Terminal Rendering

**Good:** Claude Code-inspired rendering, ANSI color handling, soft word-wrap, stream chunk merging.

**Not good:** `repeat_char` uses recursion which will stack-overflow on very wide terminals (>10000 cols). Should use the shell or a loop.

**Not good:** No tests for any rendering function. Adding a new render mode (e.g., markdown table formatting) is risky.

### `markdown.sw` (714 lines) — Markdown Parser

**Good:** Handles headers, bullets, blockquotes, code fences, horizontal rules, tables, inline bold/code.

**Not good:** No italic handling (acknowledged limitation). Tables are collected but rendered as-is, not as aligned grids.

**Not good:** Soft word-wrap logic is complex and undertested. Edge cases with very long words, ANSI codes in input, mixed CJK text.

### `browser.sw` (369 lines) — CDP Browser Control

**Good:** Zero foreign-runtime deps. Direct WebSocket to Chrome.

**Not good:** `cdp_call` drops async CDP events on the floor. No event buffer or pubsub. This means:
- `Page.loadEventFired` is lost if it arrives during another call
- JavaScript exceptions in the page are not surfaced
- Network events are invisible

**Not good:** `navigate` calls `cdp_call` with `Page.navigate` but doesn't wait for `Page.loadEventFired`. It just returns `'ok'` immediately. The page may not be loaded when the next tool runs.

**Possible direction:** Add an event buffer process that collects all CDP events. `cdp_call` consults the buffer before blocking on a response. `navigate` listens for `Page.loadEventFired` explicitly.

### `config.sw` (301 lines) — Configuration

**Good:** Merged user-global + project-local settings. Dangerous-bash hard gate is correctly scoped.

**Not good:** `is_dangerous_bash` is a growing string-match function. Every new dangerous pattern requires editing it.

**Not good:** Hooks (PreToolUse, PostToolUse) are parsed but there's no evidence they're actually invoked anywhere.

### `background.sw` (307 lines) — Background Tasks

**Good:** OS-detached processes via nohup+disown. Heartbeat polling. Log tailing. Kill by PID.

**Not good:** The `sleep(20)` race for pid reading. Also, `bg_server` and `launch` are aliases but `bg_server` used to do something different — the comment says "Kept for tool compatibility" which suggests a migration that was never cleaned up.

### `telemetry.sw` (74 lines) — System Stats

**Not good:** Brittle shell parsing. `vm_stat` format varies by macOS version. `free` output varies by Linux distro and locale. Will break on non-English systems.

**Possible direction:** Use swarmrt builtins if available, or parse `/proc/meminfo` and `/proc/loadavg` directly on Linux.

### `memory.sw` (386 lines) — Long-term Memory

**Good:** Crumbs architecture (one file per memory). Filesystem-as-index. Transparent and resilient.

**Not good:** `rebuild_index` shells out to `ls -t` and `grep`. Could be pure sw using `file_list` or equivalent.

**Not good:** Frontmatter parsing is ad-hoc string matching. Will break on YAML that spans multiple lines or contains colons in values.

### `arthopod.sw` (424 lines) — Companion

**Good:** Fun. Deterministic bones from `$USER` hash. Soul persisted to JSON.

**Not good:** `shell_escape` is crude (strips quotes and newlines). Could break on exotic usernames.

**Not good:** `generate_soul` calls the LLM on first hatch with no timeout or retry. If the endpoint is down, the user waits indefinitely on session start.

### `reader.sw` (83 lines) — Stdin Reader

**Not good:** Very thin. Just forwards messages. The `handle_permission` and `handle_picker` logic is duplicated from `agent.sw` permission handling. Could be absorbed into `agent.sw` or expanded into a real input layer.

### `log.sw` (207 lines) — Telemetry Logging

**Good:** Append-only JSONL. Event constructors for every major action.

**Not good:** `summarize` shells out to multiple `grep -c` commands. Could be pure sw.

---

## Known Bugs / Limitations

1. **Browser event loss** — async CDP events are dropped. See `browser.sw` notes above.
2. **Navigate doesn't wait for load** — `browser_navigate` returns immediately. Page may not be ready.
3. **Background pid race** — `sleep(20)` in `background.sw` launch path.
4. **No LLM retry logic** — transient HTTP failures stop the agent.
5. **MCP server crash = permanent failure** — no auto-restart.
6. **Subagent recursive forking disabled** — documented but worth revisiting.
7. **Hooks not implemented** — `config.sw` parses them but nothing invokes them.
8. **Telemetry locale-dependent** — `vm_stat`/`free` parsing breaks on non-English systems.
9. **Table rendering** — `markdown.sw` collects tables but renders them unformatted.
10. **No italic in markdown** — false-positive risk acknowledged but limits rendering quality.

---

## Improvement Priorities

### P0 — Stability
- [ ] Add integration test with mock LLM endpoint
- [ ] Fix browser event loss (add event buffer)
- [ ] Fix `browser_navigate` to wait for `Page.loadEventFired`
- [ ] Add LLM retry logic for transient failures
- [ ] Fix background pid race

### P1 — Scalability
- [ ] Refactor `Tools.exec` into dynamic tool registry
- [ ] Extract `opts` god object into typed records/behaviors
- [ ] Standardize error handling with `Result` type
- [ ] Split `agent.sw` into smaller modules

### P2 — Completeness
- [ ] Implement hooks (PreToolUse, PostToolUse)
- [ ] Add MCP server auto-restart
- [ ] Add markdown table formatting
- [ ] Add markdown italic handling
- [ ] Make telemetry locale-independent

### P3 — Polish
- [ ] Arthopod `generate_soul` timeout/retry
- [ ] `reader.sw` — expand or absorb
- [ ] `repeat_char` stack overflow risk
- [ ] Frontmatter parser robustness

---

## How to Use This Doc

When you sit down to hack on swarm-code, read the section for the module you're touching. If you're adding a tool, read the `tools.sw` and `prompts.sw` notes. If you're touching the REPL loop, read the `agent.sw` notes.

If you fix one of the known bugs or limitations, update this doc. If you discover a new limitation, add it. This document should grow with the codebase.

---

*"Don't let the tools break again. Be direct, be concise, but keep the spark."*
