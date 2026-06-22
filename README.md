# swarm-code

⚡ Terminal coding agent written in `sw` on the [swarmrt](https://github.com/skyblanket/swarmrt) BEAM-shaped C runtime. ~19K LoC, single native binary (~3 MB), BYOM via JSON profiles. Bring your own OpenAI-compatible endpoint — local llama.cpp/vLLM or a hosted provider — and get structured tool calls, subagents, vision, session search, skills, cron scheduling, and MCP in one headless/interactive REPL.

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

```bash
git clone https://github.com/skyblanket/swarmrt   ../swarmrt
git clone https://github.com/skyblanket/swarm-code
cd ../swarmrt   && make swc libswarmrt
cd ../swarm-code && make
./bin/swarm-code
```

Minimal `~/.swarm-code/settings.json`:

```json
{
  "endpoint": "http://localhost:8000",
  "model": "kimi-k2.7-code",
  "profiles": {
    "kimi": { "vision": "true" },
    "glm":  { "endpoint": "https://api.z.ai/api/paas/v4/chat/completions",
              "model": "glm-5.1", "api_key": "...", "vision": "true" }
  }
}
```

## Features

| Capability | Support |
|---|---|
| Profiles / BYOM | JSON profiles and OpenAI-compatible endpoints |
| Reusable skills | `SKILL.md` playbooks |
| Vision | Clipboard paste and image paths |
| Session search | SQLite FTS5 |
| Scheduling | Heartbeat-driven interval and daily jobs |
| MCP | Client and stdio server |
| Multi-agent work | Subagents and `/flows` parallel workflows |
| Experimental council | Bounded read-only panel plus judge synthesis |
| Trajectory export | Fine-tuning JSONL |
| Network policy | Local-only by default |
| Distribution | Single native binary |

## Experimental council

Run three repository-reading agents in parallel, then synthesize their
independent findings with a no-tools judge:

```bash
scripts/council.sh "What are the highest-risk production gaps in this repository?"
```

The default self-fusion panel uses the `kimi` profile for all perspectives.
Use diverse configured profiles and tighter budgets through environment
variables:

```bash
SWARM_COUNCIL_PROFILES=kimi,gemma-local,qwen \
SWARM_COUNCIL_JUDGE_PROFILE=kimi \
SWARM_COUNCIL_PANEL_TIMEOUT=60 \
scripts/council.sh "Review the current architecture"
```

Panel agents run under the fail-closed `council_panel` execution context:
they may inspect repository files and diffs, but cannot use shell, write,
background, browser, memory-mutation, or nested-agent tools.
This is tool-level read-only isolation, not yet a workspace filesystem
sandbox; panelists inherit the existing read tool's filesystem visibility.

See [`docs/FUSION.md`](docs/FUSION.md) for the researched OpenRouter pipeline,
prototype findings, and remaining production gaps.

## Architecture

The runtime is a single `sw` program compiled by `swc` and linked against `libswarmrt`. The agent loop (`Agent.run`) reads stdin, calls the LLM (`LLM.chat`), and sends structured `tool_calls` through the shared `ToolExecutor` policy boundary before raw handlers run. State lives in ETS tables (in-memory) and `~/.swarm-code/` (persistent). Subagents are real isolated swarmrt processes linked to their parent, not threads.

Critical modules:
- `src/main.sw:1` — CLI flags, headless mode, local-network gate, heartbeat spawn
- `src/agent.sw:1` — REPL loop, context compaction, session save/resume, permission model
- `src/ToolExecutor.sw:1` — shared context, hook, guardrail, and permission boundary
- `src/tools.sw:1` — raw tool handlers wrapping swarmrt builtins (shell, file, http)
- `src/ToolRegistry.sw:1` — tool identity and execution-context policy
- `src/llm.sw:1` — OpenAI wire format, streaming parse, structured tool_calls, multimodal
- `src/Scheduler.sw:1` — heartbeat-driven cron jobs that shell out `swarm-code -p`

Also: `Vision.sw` (multimodal attachments), `SessionSearch.sw` (SQLite FTS5), `Skills.sw` (Hermes-style playbooks), `Trajectory.sw` (fine-tuning JSONL export), `Mcp.sw` (MCP client over stdio JSON-RPC).

## Acknowledgements

- [claude-code](https://github.com/anthropics/claude-code) — the structured tool_call pattern, permission tiers, and REPL UX that this agent emulates.
- [Hermes 3 / NousResearch](https://github.com/NousResearch/Hermes-Function-Calling) — the skill / function-calling playbook format and the idea of agent-recallable procedures.

MIT — see [LICENSE](LICENSE).
