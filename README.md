<p align="center">
  <img src="docs/assets/swarm.gif" alt="swarm-code — a swarm of agents in your terminal" width="100%">
</p>

# swarm-code

[![CI](https://github.com/skyblanket/swarm-code/actions/workflows/ci.yml/badge.svg)](https://github.com/skyblanket/swarm-code/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![release](https://img.shields.io/github/v/release/skyblanket/swarm-code?display_name=tag&sort=semver)](https://github.com/skyblanket/swarm-code/releases)

A terminal coding agent written in [`sw`](https://github.com/skyblanket/swarmrt) on the swarmrt runtime. Bring your own OpenAI-compatible endpoint — local (llama.cpp / vLLM) or hosted — and get structured tool calls, real subagents, vision, session search, skills, cron, and MCP in one headless or interactive REPL. Single native binary, no Python or Node.

- [Quickstart](#quickstart) · [Configuration](#configuration) · [Features](#features) · [Multi-agent](#multi-agent) · [Security](#security) · [Architecture](#architecture)

## Demo

```
$ swarm
> /paste                    # PNG from clipboard → LLM multimodal block
ok: attached /tmp/swarm_paste_175324.png
> what's wrong with this button?

> /search "docker compose"  # FTS5 across every past conversation turn
search: docker compose  (3 hits)
  [session-175300.jsonl  assistant]
    "docker compose up -d" builds the …

> recall_skill deploy-mally-otp   # pull full playbook from ~/.swarm-code/skills/
SKILL.md loaded. Building burrito binary …

> /schedule add 1h "review open PRs"   # heartbeat-driven cron
job 3 added (every 1h)
```

## Quickstart

swarm-code builds against the [swarmrt](https://github.com/skyblanket/swarmrt) runtime, cloned alongside it:

```bash
git clone https://github.com/skyblanket/swarmrt   ../swarmrt
git clone https://github.com/skyblanket/swarm-code
cd ../swarmrt    && make swc libswarmrt
cd ../swarm-code && make
./bin/swarm-code
```

Or grab a prebuilt binary (macOS / Linux, arm64 + x86_64):

```bash
curl -fsSL https://raw.githubusercontent.com/skyblanket/swarm-code/main/scripts/install.sh | sh
```

Run a one-shot headless query (pipe-friendly for scripts and CI):

```bash
swarm-code -p "summarize the open TODOs in this repo"
swarm-code -p --json "list the test files" | jq .
```

## Configuration

Point it at any OpenAI-compatible endpoint via `~/.swarm-code/settings.json`. Profiles let you switch models/providers per task:

```json
{
  "endpoint": "http://localhost:8000",
  "model": "your-model",
  "profiles": {
    "local":  { "vision": "true" },
    "hosted": { "endpoint": "https://api.example.com/v1/chat/completions",
                "model": "your-hosted-model", "api_key": "...", "vision": "true" }
  }
}
```

Remote endpoints are opt-in — set `SWARM_CODE_ALLOW_REMOTE=1` (local-network-only by default). Optional semantic memory recall uses `SWARM_CODE_EMBED_ENDPOINT`.

## Features

| Capability | Support |
|---|---|
| Profiles / BYOM | JSON profiles, any OpenAI-compatible endpoint |
| Tools | bash, read/write/edit, glob, grep, web fetch/search, git, browser automation, background jobs, todos, code search |
| Reusable skills | `SKILL.md` playbooks, recalled on demand |
| Vision | Clipboard paste and image paths |
| Session search | SQLite FTS5 across every past conversation |
| Scheduling | Heartbeat-driven interval and daily jobs |
| MCP | Client and stdio server |
| Multi-agent | Real subagents and `/flows` parallel workflows |
| Council | Bounded read-only panel plus judge synthesis (experimental) |
| Memory | Persistent journal with optional semantic embedding |
| Trajectory export | Fine-tuning JSONL |
| Modes | Interactive REPL and headless `-p` / `--json` |
| Distribution | Single native binary |

## Multi-agent

Subagents are **real isolated swarmrt processes** linked to their parent — not threads or coroutines — each running under its own tool-execution policy. `/flows` runs multiple agents in parallel from a JSON workflow definition with a live TUI.

The experimental **council** runs several repository-reading agents in parallel, then synthesizes their independent findings with a no-tools judge:

```bash
scripts/council.sh "What are the highest-risk production gaps in this repository?"

SWARM_COUNCIL_PROFILES=local,hosted \
SWARM_COUNCIL_PANEL_TIMEOUT=60 \
scripts/council.sh "Review the current architecture"
```

Panel agents run under the fail-closed `council_panel` context: they may inspect repository files and diffs, but cannot use shell, write, background, browser, memory-mutation, or nested-agent tools. (Tool-level read-only isolation, not yet a filesystem sandbox.) See [`docs/FUSION.md`](docs/FUSION.md) for the pipeline and findings. Ready-made starting points — a sample skill and a parallel-review flow — live in [`examples/`](examples/).

## Security

swarm-code runs shell commands, reads and writes files, and can reach the network — so it is built fail-closed:

- **Local-network-only by default**; remote endpoints require an explicit `SWARM_CODE_ALLOW_REMOTE=1`.
- Every tool runs through one **`ToolExecutor` policy boundary** — context allow-lists, argument-rewriting hooks, guardrails, and permissions — *before* any raw handler executes, and **fails closed** on a missing or unknown execution context.
- A **hardline command blocklist** (`rm -rf /`, `mkfs`, `dd`, fork bombs, …) cannot be bypassed by environment overrides.
- Subagents, MCP, and council contexts run under restricted (often read-only) policies.
- Secrets are redacted from session logs and trajectory exports.

See [SECURITY.md](SECURITY.md) for the model and how to report a vulnerability.

## Architecture

A single `sw` program compiled by `swc` and linked against `libswarmrt`. The agent loop (`Agent.run`) reads stdin, calls the LLM (`LLM.chat`), and routes structured `tool_calls` through the shared `ToolExecutor` boundary before raw handlers run. State lives in in-memory ETS tables and `~/.swarm-code/` (persistent). The runtime is BEAM-shaped: subagents are isolated, linked processes, so a crashing tool or subagent never takes the session down.

Key modules:

- `src/main.sw` — CLI flags, headless mode, local-network gate, heartbeat spawn
- `src/agent.sw` — REPL loop, context compaction, session save/resume, permissions
- `src/ToolExecutor.sw` — shared context, hook, guardrail, and permission boundary
- `src/ToolRegistry.sw` — tool identity and execution-context policy
- `src/tools.sw` — raw tool handlers (shell, file, http) over swarmrt builtins
- `src/llm.sw` — OpenAI wire format, streaming parse, structured tool_calls, multimodal
- `src/Scheduler.sw` — heartbeat-driven cron jobs that shell out `swarm-code -p`

Plus `Vision.sw`, `SessionSearch.sw` (FTS5), `Skills.sw`, `Trajectory.sw`, and `Mcp.sw`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the project layout, build commands, how to add a tool, and coding conventions. `make check` runs the full verification gate (unit, smoke, integration, module checks).

## Acknowledgements

- [claude-code](https://github.com/anthropics/claude-code) — the structured tool_call pattern, permission tiers, and REPL UX this agent emulates.
- [Hermes 3 / NousResearch](https://github.com/NousResearch/Hermes-Function-Calling) — the skill / function-calling playbook format and agent-recallable procedures.

MIT — see [LICENSE](LICENSE).
