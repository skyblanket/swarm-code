# swarm-code

⚡ Terminal coding agent written in `sw` on the [swarmrt](https://github.com/skyblanket/swarmrt) BEAM-shaped C runtime. ~3K LoC, single native binary (~3 MB), BYOM via JSON profiles. Bring your own OpenAI-compatible endpoint — local llama.cpp/vLLM or a hosted provider — and get structured tool calls, subagents, vision, session search, skills, cron scheduling, and MCP in one headless/interactive REPL.

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
  "model": "kimi-k2.6",
  "profiles": {
    "kimi": { "vision": "true" },
    "glm":  { "endpoint": "https://api.z.ai/api/paas/v4/chat/completions",
              "model": "glm-5.1", "api_key": "...", "vision": "true" }
  }
}
```

## Feature matrix

|                        | swarm-code | claude-code | hermes-agent |
|------------------------|------------|-------------|--------------|
| Profiles (BYOM)        | yes        | no          | no           |
| Reusable skills        | yes        | no          | yes          |
| Vision (paste / path)  | yes        | yes         | no           |
| FTS session search     | yes        | no          | no           |
| Cron scheduling        | yes        | no          | no           |
| MCP client             | yes        | yes         | no           |
| MCP server             | no         | no          | no           |
| Trajectory export      | yes        | no          | no           |
| Local-only network     | default    | no          | n/a          |
| Boot time              | ~600 ms     | ~2 s        | ~1 s         |

## Architecture

The runtime is a single `sw` program compiled by `swc` and linked against `libswarmrt`. The agent loop (`Agent.run`) reads stdin, calls the LLM (`LLM.chat`), and dispatches structured `tool_calls` through `Tools.exec`. State lives in ETS tables (in-memory) and `~/.swarm-code/` (persistent). Subagents are real OS processes spawned via `swarmrt` links/monitors, not threads.

Critical modules:
- `src/main.sw:1` — CLI flags, headless mode, local-network gate, heartbeat spawn
- `src/agent.sw:1` — REPL loop, context compaction, session save/resume, permission model
- `src/tools.sw:1` — tool registry dispatch; wraps swarmrt builtins (shell, file, http)
- `src/llm.sw:1` — OpenAI wire format, streaming parse, structured tool_calls, multimodal
- `src/Scheduler.sw:1` — heartbeat-driven cron jobs that shell out `swarm-code -p`

Also: `Vision.sw` (multimodal attachments), `SessionSearch.sw` (SQLite FTS5), `Skills.sw` (Hermes-style playbooks), `Trajectory.sw` (fine-tuning JSONL export), `Mcp.sw` (MCP client over stdio JSON-RPC).

## Acknowledgements

- [claude-code](https://github.com/anthropics/claude-code) — the structured tool_call pattern, permission tiers, and REPL UX that this agent emulates.
- [Hermes 3 / NousResearch](https://github.com/NousResearch/Hermes-Function-Calling) — the skill / function-calling playbook format and the idea of agent-recallable procedures.

MIT — see [LICENSE](LICENSE).
