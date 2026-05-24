# swarm-code Headless Mode — Design Plan

## What Claude Code Does (The Benchmark)

Claude Code's headless mode (`-p` / `--print`) is a **completely separate execution path** that bypasses the entire React/Ink TUI. Key characteristics:

### 1. **Dual Architecture**
- **Interactive**: React/Ink TUI with keyboard input, live rendering, permission dialogs
- **Headless**: Direct `runHeadless()` function in `src/cli/print.ts` (~212KB) — no UI, no stdin reader, just structured I/O

### 2. **Structured I/O Protocol**
- `StructuredIO` class manages inbound/outbound message queues
- Output is **streamed NDJSON** (`stream-json` format) or plain text
- Messages are typed: `system`, `assistant`, `tool_use`, `tool_result`, `status`, `permission_request`
- Supports **async bidirectional control** via SDK transport

### 3. **State Management**
- Headless uses a **headlessStore** (plain JS object, not React state)
- Same `AppState` shape as interactive mode — tools, MCPs, permissions, settings all work
- Settings sync, plugin installs, MCP discovery all happen headlessly

### 4. **SDK/Bridge Surface**
- `agentSdkTypes.ts` — public API: `query()`, `createSession()`, `prompt()`
- `controlSchemas.ts` — JSON-RPC control protocol for live sessions
- Transports: stdio, HTTP, WebSocket (for remote connections)
- Direct Connect server for external apps to attach (`createDirectConnectSession.ts`)

### 5. **Key Insight**
> Headless isn't "TUI without rendering." It's a **completely different entrypoint** that shares the core engine (tool dispatch, LLM calls, message history) but replaces ALL user interaction with a message protocol.

---

## swarm-code Current Architecture Assessment

### What's GOOD (and would make headless easier)

| Strength | Why It Helps |
|----------|-------------|
| **swarmrt process model** | Message-passing between processes already works. Headless = replace stdin reader with a message pipe |
| **Reader abstraction** | `reader.sw` already decouples input from the main loop. Easy to swap |
| **Agent.run() is a pure loop** | `main_loop()` is just `receive { ... }` — no UI entanglement in the core logic |
| **ETS tables for state** | Session state is already in ETS (not UI state). Headless store is mostly there |
| **Journal persistence** | Crash-recovery journal already exists. Headless sessions are naturally persistent |
| **Tool dispatch is clean** | `Tools.exec()` takes args + opts, returns string. Pure function interface |
| **No React / no Ink** | There's no massive UI framework to strip. UI is just ANSI print functions in `ui.sw` |
| **Background tasks** | Already has `background.sw` with heartbeat polling. Daemon mode exists (`SWARM_CODE_DAEMON`) |
| **Multi-agent swarm** | `agents.sw` already spawns subagents. Headless can spawn agents just as easily |
| **MCP support** | Already discovers and calls MCP servers headlessly |
| **Memory crumbs** | `memory.sw` stores facts as files — works in any mode |

### What's NOT GOOD (needs work)

| Weakness | Impact |
|----------|--------|
| **UI tightly coupled to main loop** | `agent.sw` calls `UI.*` functions inline. Headless mode needs all prints to become optional/no-ops or messages |
| **No structured output protocol** | Everything prints to stdout via `print()`. No NDJSON, no message types, no stream events |
| **No session API / no SDK** | Other apps can't connect. No `query()`, no `createSession()`, no control protocol |
| **No streaming output for headless** | LLM streaming is consumed by UI. Need to emit structured chunks |
| **Permission system is interactive** | `check_permission` returns 'ask' but the prompt logic is inline. Need async permission hooks |
| **No input queue / no async input** | `Reader` reads stdin synchronously. Headless needs a message queue that accepts external input |
| **Config is env-var heavy** | No headless-specific config file. Need a programmatic API for settings |
| **No HTTP / no transport layer** | Only stdin/stdout. Need at minimum a Unix socket or HTTP server for external connections |
| **Daemon mode is primitive** | `SWARM_CODE_DAEMON=1` self-prompts periodically but has no external control surface |
| **No versioning / no sessions endpoint** | Can't list sessions, resume by ID, or query session state |

---

## Recommended Design: "swarm-code daemon"

### Core Philosophy
> Don't bolt headless onto the existing CLI. Create a **new entrypoint** `swarm-daemon` (or `swarm --daemon`) that shares `agent.sw`, `llm.sw`, `tools.sw` but replaces `main.sw` + `reader.sw` + `ui.sw` with a protocol handler.

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    swarm-daemon (sw process)                 │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────────┐ │
│  │ Transport   │  │ Protocol     │  │ Session Manager     │ │
│  │ (HTTP/WS/   │──│ Handler      │──│ (ETS tables +       │ │
│  │  Unix Sock) │  │ (JSON-RPC)   │  │  journal files)     │ │
│  └─────────────┘  └──────────────┘  └─────────────────────┘ │
│           │                │                  │              │
│           ▼                ▼                  ▼              │
│  ┌─────────────────────────────────────────────────────────┐│
│  │              Core Engine (reused from swarm-code)        ││
│  │   agent.sw · llm.sw · tools.sw · agents.sw · mcp.sw     ││
│  │   config.sw · memory.sw · background.sw · heartbeat.sw  ││
│  └─────────────────────────────────────────────────────────┘│
│                         │                                   │
│                         ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐│
│  │              Swarm Scheduler (swarmrt)                   ││
│  │   Subagents · Background tasks · Heartbeat · Reader     ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

### Three Execution Modes

| Mode | Flag | Use Case |
|------|------|----------|
| **Interactive** | `swarm` (default) | Current TUI mode. Human types, sees ANSI output |
| **One-shot** | `swarm -p "prompt"` | Single prompt, prints result, exits. Like `claude -p` |
| **Daemon** | `swarm --daemon` | Persistent server. Accepts HTTP/WebSocket connections. Self-maintains |

### 1. One-Shot Mode (`swarm -p`)

**Minimal change.** Add `--print <prompt>` flag to main.sw:

```bash
swarm -p "find all TODO comments and fix them"
# → runs one turn, prints assistant response + tool results to stdout
# → exits 0 on success, non-zero on error
```

Implementation:
- Skip `Reader.start()`, `UI.banner()`
- Build system prompt, history
- Call `Agent.run_turn()` directly (extract from main_loop)
- Print final assistant text to stdout
- Exit

### 2. Daemon Mode (`swarm --daemon`)

**The real work.** A persistent server with these capabilities:

#### A. Transport Layer (pick one to start)

**Option 1: Unix Domain Socket** (simplest, local only)
```
~/.swarm-code/daemon.sock
```
Other apps connect via the socket, send JSON-RPC, get NDJSON stream back.

**Option 2: HTTP + SSE** (allows remote, needs auth)
```
POST /v1/sessions          → create session
GET  /v1/sessions/:id      → get session state
POST /v1/sessions/:id/msg  → send message
GET  /v1/sessions/:id/stream → SSE of events
```

**Option 3: WebSocket** (bidirectional, best for real-time)
```
WS /v1/sessions/:id/ws
```

> **Recommendation**: Start with Unix socket (zero auth complexity), add HTTP later.

#### B. Protocol (JSON-RPC 2.0 inspired)

```json
// Client → Daemon
{"jsonrpc":"2.0","id":1,"method":"create_session","params":{"cwd":"/project","model":"kimi-k2.6"}}
{"jsonrpc":"2.0","id":2,"method":"send_message","params":{"session_id":"sess-abc","role":"user","content":"fix the bug"}}
{"jsonrpc":"2.0","id":3,"method":"list_agents","params":{"session_id":"sess-abc"}}
{"jsonrpc":"2.0","id":4,"method":"spawn_agent","params":{"session_id":"sess-abc","name":"bug-hunter","role":"bug hunter","goal":"find the crash"}}

// Daemon → Client (async events, NDJSON stream)
{"event":"assistant_chunk","session_id":"sess-abc","content":"Looking at the code..."}
{"event":"tool_use","session_id":"sess-abc","tool":"bash","args":{"command":"grep -r crash src/"}}
{"event":"tool_result","session_id":"sess-abc","tool":"bash","result":"src/main.sw:42: panic..."}
{"event":"agent_spawned","session_id":"sess-abc","agent":"bug-hunter"}
{"event":"agent_reply","session_id":"sess-abc","agent":"bug-hunter","content":"Found it at line 42"}
{"event":"done","session_id":"sess-abc"}
```

#### C. Session Manager

Each session is an isolated `Agent.run()` loop in its own sw process:

```sw
fun session_loop(session_id, opts, system_prompt) {
    register(session_id, self())
    # Replace Reader with a message queue from the transport layer
    # Replace UI calls with event sends to transport
    main_loop(history, opts_headless)
}
```

Sessions persist to the same journal files. On daemon restart, replay all active journals.

#### D. Self-Maintaining Features

The daemon mode should be **alive**, not just a request handler:

| Feature | Mechanism |
|---------|-----------|
| **Heartbeat health checks** | Every 30s, ping each session process. Dead sessions marked, clients notified |
| **Auto-compaction** | Same as interactive — triggered by token budget |
| **Background task polling** | Already in `heartbeat.sw`. Extend to notify connected clients |
| **Autonomy** | `SWARM_CODE_AUTONOMY=1` already exists — model reacts to bg_done without user input |
| **Cron-style triggers** | New feature: schedule periodic tasks (e.g., "check for PRs every hour") |
| **Memory pruning** | Auto-forget old memories based on age or relevance |
| **Log rotation** | Daemon logs grow. Rotate at 10MB |

---

## Implementation Roadmap

### Phase 1: One-Shot Mode (1-2 days)
- Extract `run_turn()` from `agent.sw`'s `main_loop` into a standalone function
- Add `--print <prompt>` flag to `main.sw`
- Skip UI/Reader, print plain text result, exit
- **Deliverable**: `swarm -p "prompt"` works for single-turn tasks

### Phase 2: UI Decoupling (2-3 days)
- Create `ui_console.sw` — wraps all `UI.*` calls, detects headless mode via `opts.headless`
- In headless mode: `UI.tool_header()` becomes `Log.event('tool_use', ...)`
- In headless mode: `UI.stream_chunk_render()` becomes `Log.event('assistant_chunk', ...)`
- Create `output_protocol.sw` — defines event types, serialization to NDJSON
- **Deliverable**: All UI calls go through a headless-aware abstraction

### Phase 3: Unix Socket Daemon (3-5 days)
- New module: `daemon.sw` — main entrypoint for `swarm --daemon`
- New module: `transport_unix.sw` — Unix socket server using swarmrt's `tcp_listen` or `socket_*` builtins
- New module: `session_manager.sw` — spawns session processes, routes messages
- New module: `protocol_jsonrpc.sw` — parse requests, validate, dispatch
- Wire session processes to send events back through the transport
- **Deliverable**: External app can connect to socket, create session, send message, receive events

### Phase 4: SDK / Client Library (2-3 days)
- Python client: `pip install swarm-code-client`
```python
from swarm_code import Client
client = Client()
session = client.create_session(cwd="/project")
for event in session.send("fix the bug"):
    print(event.type, event.content)
```
- Or simpler: `swarm-code-client` CLI wrapper
- **Deliverable**: Other apps can use swarm-code programmatically

### Phase 5: Persistent Self-Maintaining Daemon (3-5 days)
- Session resumption on daemon restart (replay journals)
- Multi-session management (list, kill, pause sessions)
- Scheduled tasks / cron integration
- Health monitoring dashboard (simple HTTP endpoint)
- **Deliverable**: `swarm --daemon` runs as a systemd service, survives reboots, auto-resumes

### Phase 6: HTTP + WebSocket Transport (optional, 3-5 days)
- REST API with OpenAPI spec
- WebSocket for real-time bidirectional
- Authentication (API keys, JWT)
- **Deliverable**: Remote connections, web dashboard, mobile apps can connect

---

## Files to Create / Modify

### New Files
```
src/daemon.sw              # Daemon entrypoint
src/daemon_main.sw         # New main() for daemon mode
src/transport_unix.sw      # Unix socket transport
src/transport_http.sw      # HTTP transport (Phase 6)
src/protocol_jsonrpc.sw    # JSON-RPC message handling
src/session_manager.sw     # Session lifecycle management
src/output_protocol.sw     # NDJSON event serialization
src/ui_console.sw          # Headless-aware UI wrapper
```

### Modified Files
```
src/main.sw                # Add --daemon, --print flags; branch entrypoint
src/agent.sw               # Extract run_turn(), make UI calls optional
src/reader.sw              # Add headless mode (skip stdin, read from queue)
src/ui.sw                  # Add headless no-op variants
src/heartbeat.sw           # Add session health pings
src/log.sw                 # Add structured event logging
```

---

## Open Questions

1. **Auth model for daemon?** Unix socket = file permissions (simple). HTTP = need tokens.
2. **Session isolation?** Each session in its own sw process (safer, more memory) or shared process with ETS namespaces (faster)?
3. **Streaming protocol?** NDJSON over socket (simple) or gRPC / WebSocket (more efficient)?
4. **Subagent visibility?** Should subagents spawned in a session send events to the client, or only the main agent?
5. **Tool permissions in headless?** Default-allow with dangerous-gate (current) or require explicit allowlist per session?

---

## Why This Is Worth Doing

| Capability | Before | After |
|-----------|--------|-------|
| CI/CD integration | ❌ | `swarm -p "run tests"` in GitHub Actions |
| IDE plugin | ❌ | VS Code extension talks to daemon socket |
| Persistent background agent | ❌ | Daemon runs 24/7, reacts to events |
| Multi-project orchestration | ❌ | One daemon, multiple sessions |
| Mobile/web UI | ❌ | HTTP API serves any frontend |
| Agent swarms as a service | ❌ | External apps spawn/query agents |
| Scheduled maintenance | ❌ | Cron + daemon = self-healing codebase |

---

*Plan authored by swarm-code analyzing its own codebase and Claude Code's headless implementation.*
