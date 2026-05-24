# Improvement Delegation: swarmrt vs swarm-code

> Which improvements belong in the **runtime/language** (swarmrt) vs which belong in the **harness** (swarm-code).
> Based on swarmrt codebase audit: `case` expressions already exist, ETS has rwlock but no CAS, 100+ builtins available.

---

## swarmrt (Runtime / Language) — 6 Items

### 1. `case` Expression Adoption in swarm-code

**Status: ALREADY EXISTS in swarmrt.** The `case` keyword, parser, interpreter, and codegen are all implemented (Phase 13). The swarm-code codebase just doesn't use it.

```sw
# Current (tools.sw)
if (c == "0") { 0 } else {
if (c == "1") { 1 } else {
... 16 levels ...}}}}

# Runtime already supports this
hex_value(c) = case c {
    "0" -> 0
    "1" -> 1
    ...
    "f" -> 15
    _   -> 0
}
```

**Action:** Pure swarm-code change. Migrate `hex_byte`, `char_to_digit`, `parse_budget_env`, `string_to_perm`, `rarity_stars`, `rarity_color`, etc. to `case`.

---

### 2. ETS Atomic Operations (`ets_cas` / `ets_update`)

**Status: NOT in swarmrt.** Current ETS (`swarmrt_builtins_studio.h`) provides:
- `_builtin_ets_new` — create table
- `_builtin_ets_put` — write (exclusive wrlock)
- `_builtin_ets_get` — read (shared rdlock)
- `_builtin_ets_delete` — delete key
- `_builtin_ets_list` / `_builtin_ets_count` — metadata

**Missing:** Compare-and-swap or atomic update primitive. This causes two bugs in swarm-code:
1. **Todo concurrent writes** — two subagents updating same todo ID = race
2. **Background pid race** — `sleep(20)` hack because there's no atomic "write if not exists"

**Required runtime addition:**
```c
static sw_val_t *_builtin_ets_cas(sw_val_t **a, int n) {
    // args: table_id, key, expected_old_value, new_value
    // returns: {'ok', 'swapped'} | {'ok', 'unchanged', current_value}
}
```

Or simpler: `ets_update_counter` (Erlang-style atomic integer increment).

**Impact:** Fixes ETS concurrency gaps in swarm-code without serializing through owner processes.

---

### 3. `file_list` Builtin

**Status: NOT in swarmrt.** swarm-code shells out to `ls` and `find` in multiple places (`background.sw`, `memory.sw`, `tools.sw`). A pure sw directory listing builtin would eliminate these shell calls.

**Required runtime addition:**
```c
static sw_val_t *_builtin_file_list(sw_val_t **a, int n) {
    // arg: directory path
    // returns: list of filenames (strings) in the directory
}
```

**Impact:** Eliminates `ls -t` in `memory.sw` rebuild_index, `find` in `tools.sw` glob, shell dependency for directory traversal.

---

### 4. `string_repeat` Builtin

**Status: NOT in swarmrt.** `UI.repeat_char` uses recursion which stack-overflows on very wide terminals (>10000 cols).

**Required runtime addition:**
```c
static sw_val_t *_builtin_string_repeat(sw_val_t **a, int n) {
    // args: char, count
    // returns: string of char repeated count times
}
```

**Impact:** Fixes stack overflow risk. Eliminates a whole class of recursive string builders.

---

### 5. `subprocess_spawn_with_pid` or `subprocess_pid` Builtin

**Status: NOT in swarmrt.** Background tasks in swarm-code launch via `shell(detach_cmd)` then race to read a pid file. The runtime's `subprocess_spawn` returns a handle but no direct pid access from sw.

**Required runtime addition:** Either:
- `subprocess_pid(handle)` — return the OS pid as an integer
- Or make `subprocess_spawn` return a tuple `{handle, pid}`

**Impact:** Eliminates the `sleep(20)` race in `background.sw`.

---

### 6. Tail-Call Optimization in Codegen

**Status: NOT in swarmrt.** Many swarm-code functions are recursive by necessity (`repeat_char`, `string_split` helpers, list walkers). The C codegen generates regular recursive calls, not tail calls. This limits recursion depth to the C stack.

**Examples at risk:**
- `UI.repeat_char` — could overflow on wide terminals
- `Markdown.walk_blocks` — could overflow on very long markdown documents
- `Log.summarize` — recursive list processing

**Required runtime change:** The codegen (`swarmrt_codegen.c`) should detect tail calls and emit `goto` instead of recursive function calls.

**Impact:** Eliminates stack overflow risk for all recursive list/string processing in swarm-code.

---

## swarm-code (Harness) — 12 Items

### 1. Adopt `case` Expressions

**Owner:** swarm-code only.

Migrate all the `if/else` ladders that map one value to another:

| Function | File | Lines |
|----------|------|-------|
| `hex_byte` | `arthopod.sw` | ~20 |
| `char_to_digit` | `ui.sw` | ~15 |
| `parse_budget_env` | `agent.sw` | ~20 |
| `string_to_perm` | `config.sw` | ~5 |
| `rarity_stars` | `arthopod.sw` | ~7 |
| `rarity_color` | `arthopod.sw` | ~7 |
| `capitalize_first` | `ui.sw` | ~5 |

**Effort:** Low. Syntax already works. Just refactor.

---

### 2. Dynamic Tool Registry

**Owner:** swarm-code only.

Replace the 40-branch `if/else` chain in `Tools.exec` with a registration table.

```sw
# At boot: register tools into an ETS table
register_tool(tools_table, 'bash', bash_handler, bash_schema, bash_desc)
register_tool(tools_table, 'read', read_handler, read_schema, read_desc)
...

# exec becomes a lookup
exec(name, args, opts) {
    tool = ets_get(tools_table, name)
    if (tool == nil) { "error: unknown tool" }
    else { tool.handler(args, opts) }
}
```

**Effort:** Medium. Need to define a Tool record/shape. Requires refactoring `prompts.sw` to generate descriptions from registered tools instead of hardcoded functions.

---

### 3. Standard `Result` Type

**Owner:** swarm-code only.

Establish a convention (until swarmrt gets sum types):

```sw
# Convention: functions return either
#   {'ok', Value}    — success
#   {'error', Reason} — failure

fun tool_exec(name, args, opts) {
    # instead of: return "error: ..." or "ok: ..." or raw string
    # return: {'ok', result_string} or {'error', "reason"}
}
```

Add helper functions:
```sw
fun result_map(r, f) { ... }
fun result_flatten(r) { ... }
fun result_unwrap(r, default) { ... }
```

**Effort:** Medium. Requires touching every tool handler and the agent loop's dispatch logic.

---

### 4. Refactor `agent.sw` (1814 lines)

**Owner:** swarm-code only.

Split into smaller modules:
- `journal.sw` — crash recovery journal read/write/encoding
- `budget.sw` — token budgeting, compaction logic
- `permissions.sw` — permission check, prompt handling
- `agent.sw` — REPL loop only

**Effort:** Medium. Mostly moving code, no semantic changes.

---

### 5. Refactor `agents.sw` Agent Message Loop

**Owner:** swarm-code only.

`agent_message_loop` handles history, LLM calls, tool dispatch, and status updates. Split into:
- `agent_run_turn()` — one LLM call + tool extraction
- `agent_handle_tools()` — dispatch extracted tools
- `agent_update_history()` — append results

**Effort:** Medium.

---

### 6. Browser Event Buffer

**Owner:** swarm-code only.

`browser.sw` `cdp_call` drops async CDP events on the floor. Fix in pure sw:

```sw
# Spawn an event collector process at browser init
spawn(browser_event_loop(session))

# event_loop constantly wsc_recv and pushes events into an ETS buffer
fun browser_event_loop(session) {
    ws = ets_get(session, 'ws')
    raw = wsc_recv(ws, 1000)  # short timeout, non-blocking-ish
    if (raw != nil) {
        decoded = json_decode(raw)
        # push to event buffer ETS
        push_event(session, decoded)
    }
    browser_event_loop(session)
}

# cdp_call checks the buffer first before blocking
fun cdp_call(session, method, params) {
    # 1. check event buffer for matching response id
    # 2. if not found, send request and block
}
```

**Effort:** Medium. Requires careful handling of the event buffer lifecycle.

---

### 7. Browser Navigate Wait for Load

**Owner:** swarm-code only.

Once the event buffer exists, `navigate` can wait for `Page.loadEventFired`:

```sw
fun navigate(session, url) {
    cdp_call(session, "Page.navigate", %{url: url})
    # Wait for Page.loadEventFired event in the buffer
    wait_for_event(session, "Page.loadEventFired", 30000)
}
```

**Effort:** Low (depends on event buffer above).

---

### 8. LLM Retry Logic

**Owner:** swarm-code only.

Wrap `http_post_stream` with exponential backoff:

```sw
fun chat_with_retry(messages, opts, retries) {
    result = LLM.chat(messages, opts)
    if (is_transient_error(result) && retries > 0) {
        sleep(backoff_ms)
        chat_with_retry(messages, opts, retries - 1)
    } else { result }
}
```

**Effort:** Low.

---

### 9. MCP Server Auto-Restart

**Owner:** swarm-code only.

Use swarmrt's existing monitor/link primitives:

```sw
# When spawning an MCP owner, link to it
spawn(mcp_owner_loop(...))  # already links

# In a supervisor process, handle DOWN messages
receive {
    {'DOWN', ref, 'process', pid, reason} ->
        restart_mcp_server(name)
}
```

**Effort:** Medium. Need a lightweight supervisor for MCP servers.

---

### 10. Background Pid Race (sw-only fix)

**Owner:** swarm-code only.

Even without a runtime `subprocess_pid` builtin, can fix with a blocking read:

```sw
fun launch(table, command, label) {
    # ... spawn command that writes pid to pid_file ...
    # Instead of sleep(20), poll with backoff
    pid = wait_for_pid_file(pid_file, 5000)  # max 5s
    if (pid == nil) { "error: could not read pid" }
    else { ... }
}
```

**Effort:** Low.

---

### 11. Telemetry Locale-Independence

**Owner:** swarm-code only.

Replace brittle `vm_stat`/`free`/`uptime` parsing with direct `/proc` reads on Linux, and `sysctl` on macOS:

```sw
# Linux: read /proc/meminfo, /proc/loadavg directly
# macOS: use `sysctl hw.memsize` and `sysctl vm.loadavg`
```

**Effort:** Low. Eliminates awk/sed dependency.

---

### 12. Implement Hooks (PreToolUse / PostToolUse)

**Owner:** swarm-code only.

`config.sw` parses hooks from settings.json but nothing invokes them. Add hook firing in `Tools.exec`:

```sw
fun exec(name, args, opts) {
    run_hooks('PreToolUse', name, args, opts)
    result = actual_exec(name, args, opts)
    run_hooks('PostToolUse', name, args, result, opts)
    result
}
```

**Effort:** Low.

---

## Summary Table

| # | Improvement | Owner | Effort | Priority |
|---|-------------|-------|--------|----------|
| 1 | Adopt `case` expressions | swarm-code | Low | P1 |
| 2 | ETS atomic ops (CAS) | **swarmrt** | Medium | P0 |
| 3 | Dynamic tool registry | swarm-code | Medium | P1 |
| 4 | Standard `Result` type | swarm-code | Medium | P1 |
| 5 | Refactor `agent.sw` | swarm-code | Medium | P2 |
| 6 | Refactor `agents.sw` | swarm-code | Medium | P2 |
| 7 | Browser event buffer | swarm-code | Medium | P0 |
| 8 | Browser navigate wait | swarm-code | Low | P0 |
| 9 | LLM retry logic | swarm-code | Low | P1 |
| 10 | MCP auto-restart | swarm-code | Medium | P2 |
| 11 | Background pid race (sw fix) | swarm-code | Low | P1 |
| 12 | `file_list` builtin | **swarmrt** | Low | P2 |
| 13 | `string_repeat` builtin | **swarmrt** | Low | P2 |
| 14 | `subprocess_pid` builtin | **swarmrt** | Low | P1 |
| 15 | Telemetry locale fix | swarm-code | Low | P2 |
| 16 | Hooks implementation | swarm-code | Low | P2 |
| 17 | Tail-call optimization | **swarmrt** | High | P2 |

---

## Recommended Next Steps

### swarmrt (runtime) — in priority order:
1. **ETS CAS / atomic update** — unblocks swarm-code concurrency fixes
2. **`subprocess_pid` builtin** — unblocks background task reliability
3. **`file_list` builtin** — reduces shell dependency
4. **`string_repeat` builtin** — eliminates stack overflow risk
5. **Tail-call optimization** — long-term, high effort, high impact

### swarm-code (harness) — in priority order:
1. **Browser event buffer + navigate wait** — fixes real user-facing bug
2. **LLM retry logic** — fixes real user-facing bug (transient failures)
3. **Adopt `case` expressions** — reduces boilerplate, improves readability
4. **Background pid race fix** — simple, eliminates known race
5. **Dynamic tool registry** — enables scaling past 50 tools
6. **Standard `Result` type** — improves error handling consistency
7. **Refactor `agent.sw` / `agents.sw`** — improves maintainability
8. **MCP auto-restart** — improves reliability
9. **Hooks implementation** — enables user extensibility
10. **Telemetry locale fix** — improves portability
