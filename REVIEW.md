# swarm-code vs. Hermes Agent — Comprehensive Code Review

**Date:** 2026-06-01  
**swarm-code:** ~12,188 LOC (24 `.sw` modules)  
**Hermes Agent:** ~142,333 LOC (5,985 `.py` files)

---

## 1. Executive Summary

swarm-code is a **minimalist, runtime-native agent** built on the custom `sw` language and `swarmrt` scheduler. It achieves remarkable density—every module has a clear single responsibility, and the entire agent loop fits in ~1,950 lines. Hermes is a **maximalist, production-hardened Python agent** with deep safety, observability, and multi-platform features.

**The gap is not a bug count—it's a maturity gradient.** swarm-code has the bones of a great agent but lacks the defensive layers that Hermes has accumulated through real-world abuse. The good news: most of those layers are small, self-contained, and can be ported incrementally.

---

## 2. Architecture Comparison

| Dimension | swarm-code | Hermes |
|-----------|-----------|--------|
| **Language** | `sw` (functional, custom) | Python 3.11 |
| **Runtime** | swarmrt (Erlang-style processes, ETS, 10 schedulers) | CPython + asyncio + threading |
| **Process model** | spawn/send/receive mailboxes, cooperative scheduling | ThreadPoolExecutor + async event loops |
| **Session storage** | JSON files (`.active` journal + `session-*.json`) | SQLite + FTS5 (`~/.hermes/state.db`) |
| **Memory** | Markdown crumbs (`~/.swarm-code/memory/*.md`) | SQLite + pluggable memory providers |
| **Config** | `settings.json` + `SWARM.md`/`CLAUDE.md` | `config.yaml` + env vars + secret store |
| **Tool registry** | Static list in `ToolRegistry.sw` + MCP dynamic | Self-registering modules via AST discovery |
| **LLM transport** | Single OpenAI-compatible HTTP client | Multi-provider (OpenAI, Anthropic, Bedrock, Gemini, Codex) |
| **Retry/failover** | 3 retries with fixed delays (1s, 2s, 4s) | Jittered backoff + credential pool rotation + fallback model |
| **Security** | Basic dangerous-command regex + permission hooks | Hardline blocks + smart approval + YOLO freeze + path security + tool guardrails |
| **Subagents** | `task` tool spawns isolated LLM loop (max 15 steps) | `delegate_task` with blocked toolsets, depth limits, interrupt propagation |
| **Browser** | Native CDP over WebSocket (zero Node/Python deps) | Playwright/CDP via Node wrapper |
| **Testing** | 22 in-process unit tests | 50+ gateway tests, stress tests, property fuzzing, E2E |
| **Plugins** | None | Pre/post hooks for tool calls, LLM calls, subagent stop |
| **Cron/scheduler** | Simple interval scheduler with back-pressure | Full cron scheduler with gateway integration |

---

## 3. What swarm-code Does Better

### 3.1 Zero-dependency browser automation
`browser.sw` speaks CDP directly over WebSocket via swarmrt builtins (`chrome_launch`, `wsc_*`). No Node, no Playwright, no Python wrapper. This is genuinely unique—Hermes needs ~300 MB of Node dependencies.

### 3.2 Process-native concurrency
The `spawn`/`send`/`receive` model in `agent.sw` (subagent dispatch) and `test_runner.sw` is elegant. Subagents are real isolated processes, not threads sharing GIL state. The mailbox serialization pattern for MCP (`mcp.sw`) is exactly how Erlang ports work—battle-tested design.

### 3.3 Transparent memory storage
Markdown crumbs in `~/.swarm-code/memory/` are human-readable, git-diffable, and atomically writable. Hermes buries memories in SQLite blobs. The crumbs approach is better for power users who `cat` or `grep` their agent's brain.

### 3.4 Density and readability
At 12K LOC, a single developer can hold the entire codebase in working memory. Hermes at 142K LOC requires team specialization. swarm-code's functional style (tail-recursive loops, pattern matching in `receive`) makes data flow explicit.

### 3.5 Build-time safety
No runtime dependency installation—`make` produces a single native binary. Hermes needs `pip install`, Node for browser, post-install bootstrapping, etc.

---

## 4. Critical Issues & Improvement Opportunities

### 4.1 🚨 Security: No hardline blocks
**File:** `config.sw`  
**Issue:** `is_dangerous_bash()` uses a basic regex list (`rm -rf /`, `sudo`, `curl | sh`). There is **no hardline floor**—a `--yolo` equivalent doesn't exist, but if it did, nothing would stop `mkfs`, `shutdown`, or `dd if=/dev/zero of=/dev/sda`.

**Hermes reference:** `tools/approval.py` defines `HARDLINE_PATTERNS` that are **unconditional blocks** (not bypassable by YOLO). These include:
- `shutdown`, `reboot`, `halt`, `poweroff`
- `mkfs`, `mkswap`, `dd if=/dev/`
- `chmod 000 /`, `chown -R 0:0 /`

**Recommendation:** Add a `HARDLINE_PATTERNS` regex set in `config.sw` that runs **before** the permission system and can never be bypassed.

---

### 4.2 🚨 Security: No path traversal validation
**File:** `tools.sw`  
**Issue:** `do_read()`, `do_write()`, `do_edit()` accept arbitrary paths. A malicious or hallucinated model could write to `~/.ssh/authorized_keys`, `/etc/passwd`, or overwrite `~/.swarm-code/settings.json`.

**Hermes reference:** `tools/path_security.py` uses `Path.resolve()` + `relative_to()` to enforce a workspace root. All file operations are validated.

**Recommendation:** Add a `validate_path()` helper that:
1. Resolves the path (follows symlinks)
2. Ensures it stays within a configurable root (default: `getenv("PWD")` or `SWARM_CODE_ROOT`)
3. Blocks writes to `~/.ssh/`, `~/.swarm-code/`, `/etc/`, etc.

---

### 4.3 🚨 Security: Sudo password brute-force risk
**File:** `tools.sw`  
**Issue:** `do_bash()` passes commands straight to `shell()`. If a command includes `sudo -S`, the agent could repeatedly guess passwords via stdin.

**Hermes reference:** `tools/approval.py` has an explicit `sudo -S` guard that blocks when `SUDO_PASSWORD` is not configured.

**Recommendation:** Detect `sudo` usage in `do_bash()` and either block it or require explicit user confirmation with a one-time password prompt.

---

### 4.4 🚨 Reliability: No tool-call guardrails
**File:** `agent.sw`  
**Issue:** The agent loop (`run_conversation` equivalent) has no protection against:
- **Infinite loops:** Same tool call repeated with identical args
- **Failure spirals:** Tool keeps failing, agent keeps retrying it
- **No-progress loops:** Idempotent reads (e.g., `read`, `glob`) in a cycle without mutating actions

**Hermes reference:** `agent/tool_guardrails.py` tracks per-turn:
- Exact-failure counts (`exact_failure_block_after: 5`)
- Same-tool failure counts (`same_tool_failure_halt_after: 8`)
- No-progress idempotent repeats (`no_progress_block_after: 5`)

**swarm-code's current defense:** Only `max_steps() = 200`, which is a blunt instrument. A stuck agent burns 200 API calls and dollars.

**Recommendation:** Add a `ToolGuardrail` module (or inline in `agent.sw`) that:
1. Hashes each tool call signature (name + sorted args JSON)
2. Tracks consecutive identical failures
3. Tracks consecutive idempotent calls with no mutating actions between them
4. Injects a synthetic `tool` result: `"Guardrail: you have called read_file 5 times with the same path. Stop and ask the user."`

---

### 4.5 🚨 Reliability: Weak retry / no failover
**File:** `llm.sw`  
**Issue:** `chat_native_retry()` has 3 retries with fixed 1s/2s/4s delays. No:
- Jitter (thundering herd if multiple agents restart simultaneously)
- Credential rotation on 429/auth failures
- Fallback model when primary is down
- Context compression when token limit exceeded
- Special handling for `finish_reason: length` (we saw this with Kimi—empty `content` + truncated `reasoning_content`)

**Hermes reference:** `agent/retry_utils.py` (jittered backoff), `agent/credential_pool.py` (key rotation), `agent/error_classifier.py` (taxonomy of 10+ failure modes), `agent/context_compressor.py` (summarization with cheap auxiliary model).

**Recommendation:**
1. Replace fixed delays with jittered backoff: `delay = min(base * 2^attempt, max) * (1 + random * jitter_ratio)`
2. Add `finish_reason: length` handling in `extract_content_impl()`: when `content` is empty but `reasoning_content` exists, return the reasoning as content with a truncation notice.
3. Add a `SWARM_CODE_FALLBACK_ENDPOINT` / `SWARM_CODE_FALLBACK_MODEL` env var and failover logic.

---

### 4.6 🚨 Reliability: No message alternation repair
**File:** `agent.sw`, `llm.sw`  
**Issue:** The history is appended to directly. If a tool call fails to produce a result message, or if the model emits a malformed response, the history can break the `user → assistant → tool` alternation required by OpenAI. The API will then reject the request with a 400 error.

**Hermes reference:** `agent/conversation_loop.py` runs `_repair_message_sequence()` before **every** API call. It strips orphan tool calls, drops think-only turns, and enforces strict alternation.

**Recommendation:** Add a `repair_history(messages)` function in `llm.sw` that:
1. Ensures every `assistant` message with `tool_calls` is followed by one `tool` message per call
2. Removes `tool` messages without a preceding `assistant` tool_calls
3. Collapses consecutive `user` messages into one

---

### 4.7 ⚠️ Concurrency: Subagent toolset not restricted
**File:** `agent.sw` (~line 1604)  
**Issue:** Subagents spawned via `task` inherit the full toolset. A subagent can call `remember`, `write`, `edit`, and modify the parent's memory/files. It also has no depth limit beyond the binary `is_subagent` flag.

**Hermes reference:** `tools/delegate_tool.py` defines `DELEGATE_BLOCKED_TOOLS`:
```python
DELEGATE_BLOCKED_TOOLS = frozenset([
    "delegate_task",   # no recursion
    "clarify",         # no user interaction
    "memory",          # no shared MEMORY.md writes
    "send_message",    # no cross-platform side effects
    "execute_code",    # children reason step-by-step
])
```

**Recommendation:**
1. Create a `SUBAGENT_BLOCKED_TOOLS` list: `['task', 'remember', 'forget', 'bg_server', 'browser_launch']`
2. In `subagent_exec_all()`, skip blocked tools and return `"error: tool X is not available in subagents"`
3. Add a `max_spawn_depth` config (default 1) and pass it through `opts`.

---

### 4.8 ⚠️ Observability: No telemetry on tool dispatch
**File:** `tools.sw`  
**Issue:** Tool calls are dispatched with no timing, no success/failure logging, no latency metrics. When a slow `bash` command hangs, there's no visibility.

**Hermes reference:** `model_tools.py` measures `duration_ms` for every dispatch and fires `post_tool_call` plugin hooks. `agent/display.py` shows spinners.

**Recommendation:** Add a `Log.tool_call(name, duration_ms, success)` helper and wrap every `exec()` dispatch with timing.

---

### 4.9 ⚠️ Config: No secret storage
**File:** `config.sw`  
**Issue:** API keys live in `settings.json` as plaintext. No integration with macOS Keychain, Bitwarden, or env-file isolation.

**Hermes reference:** `hermes_cli/secrets.py` + Bitwarden Secrets Manager integration. `~/.hermes/.env` is gitignored by convention.

**Recommendation:** At minimum, support `SWARM_CODE_API_KEY` env var (already done) and document it as the preferred method. Add a `.gitignore` to `~/.swarm-code/`.

---

### 4.10 ⚠️ Testing: Minimal coverage
**File:** `test_runner.sw`  
**Issue:** 22 tests covering pure functions (split, JSON, markdown, slugify, spawn). No tests for:
- Agent loop behavior
- LLM response parsing edge cases (empty content, finish_reason length)
- Tool dispatch error paths
- Config permission logic
- Browser automation
- MCP handshake failure

**Hermes reference:** 50+ gateway tests, stress tests with ThreadPoolExecutor, property fuzzing, E2E subprocess tests.

**Recommendation:** Add integration tests that:
1. Mock LLM responses (inject fake `chat_native` return values)
2. Verify the agent loop stops after N tool-call rounds
3. Verify guardrails fire on repeated identical calls
4. Test `extract_content_impl` with `finish_reason: length` and empty content

---

### 4.11 ⚠️ Context management: No compression
**File:** `agent.sw`  
**Issue:** When history exceeds `compact_threshold()` (120 messages), the code auto-compacts by summarizing. But there's no mid-turn compression—if a single turn produces a massive tool output, the next API call may exceed context window and fail.

**Hermes reference:** `agent/context_compressor.py` uses a cheap auxiliary model to summarize overflowing context, with telemetry on token savings.

**Recommendation:** Add `compact_if_needed()` before every LLM call that checks estimated token count (rough heuristic: chars/4) and trims oldest non-system messages if over budget.

---

### 4.12 ⚠️ MCP: No health checks or reconnection
**File:** `mcp.sw`  
**Issue:** MCP servers are spawned once at boot. If a server crashes, its tools become permanently unavailable until swarm-code restarts. No heartbeat or auto-restart.

**Hermes reference:** Gateway has health probes and restart policies.

**Recommendation:** Add a lightweight health check in the MCP owner loop: if `subprocess_recv_line` times out or returns EOF, mark the server as failed and optionally retry spawn once.

---

### 4.13 ⚠️ LLM: No streaming cancellation
**File:** `llm.sw`  
**Issue:** The HTTP request blocks until the full response arrives. There's no way for the user to cancel a long-running LLM call mid-stream (e.g., Ctrl+C).

**Hermes reference:** `agent/conversation_loop.py` handles interrupt requests and cancels in-flight streams.

**Recommendation:** This may require swarmrt HTTP client support for async cancellation. Document as a known limitation.

---

### 4.14 ⚠️ UI: No undo / checkpoint
**File:** `agent.sw`  
**Issue:** Every tool call is immediately executed. There's no checkpoint before mutating operations—if the model makes a bad edit, the user must manually revert.

**Hermes reference:** `agent/checkpoint_mgr.py` creates per-turn checkpoints and supports rollback.

**Recommendation:** Add a `/checkpoint` slash command and auto-checkpoint before `write`, `edit`, `multi_edit`, `git_commit`. Store diffs in `~/.swarm-code/checkpoints/`.

---

## 5. Code Quality Issues (Minor)

### 5.1 Magic numbers scattered
`max_steps() = 200`, `compact_threshold() = 120`, `max_output_bytes() = 6000`, `git_timeout_s() = 30` are hardcoded functions. Consider a single `settings.json` schema so users can tune them.

### 5.2 Error messages leak to model
When `shell()` returns a non-zero exit code, the raw stderr is passed back to the model. Some stderr content may contain sensitive paths or environment variables. Hermes scrubs stderr via `_sanitize_messages_non_ascii` and `_sanitize_structure_surrogates`.

### 5.3 No input validation on JSON schemas
`ToolSchemas.sw` defines schemas but doesn't validate outgoing tool calls against them. A model could emit a `write` call with a missing `content` field, which `do_write()` would handle with a nil check—but schema validation would catch it earlier.

### 5.4 `llm.sw` has duplicate JSON decode logic
`extract_content()`, `extract_reasoning()`, `extract_usage()` each call `json_decode()` independently. A single `decode_response(resp_body)` helper would be cleaner.

### 5.5 `agent.sw` is 1,946 lines
This is approaching the limit for a single-module cognitive load. Consider splitting:
- `session.sw` — save/resume/list sessions
- `subagent.sw` — task spawning and subagent loop
- `journal.sw` — journal encoding/decoding/replay

---

## 6. Recommended Priority Order

| Priority | Issue | Effort | Impact |
|----------|-------|--------|--------|
| **P0** | Hardline blocklist for catastrophic commands | 2h | Safety-critical |
| **P0** | Path traversal validation | 4h | Safety-critical |
| **P0** | Tool-call guardrails (loop detection) | 6h | Cost/reliability |
| **P1** | Fix `finish_reason: length` empty content | 2h | Reliability |
| **P1** | Jittered backoff + better retry taxonomy | 4h | Reliability |
| **P1** | Subagent tool restrictions | 3h | Safety |
| **P2** | Message alternation repair | 4h | API stability |
| **P2** | Context compression before API call | 6h | Cost/reliability |
| **P2** | Checkpoint / undo system | 8h | UX |
| **P3** | MCP health checks | 3h | Robustness |
| **P3** | Secret storage improvement | 2h | Security |
| **P3** | Expand test coverage | 8h | Maintainability |

---

## 7. Conclusion

swarm-code is an **impressive minimal agent** with architectural advantages (native CDP, process concurrency, transparent memory) that Hermes cannot easily replicate. Its core loop is correct and the codebase is exceptionally readable.

However, it currently sits at **"trusted developer tool"** maturity. To reach **"production agent that can run unsupervised"** maturity, it needs the defensive layers that Hermes has spent years building: hardline blocks, path security, tool guardrails, robust retries, and message sanitization.

**The shortest path to improvement:** Port the 4 P0 items above. They are small (combined ~16 hours), self-contained, and would eliminate the most dangerous failure modes. Everything else is polish.
