# swarm-code — Positioning Brief (July 2026)

Synthesized from: landscape research (15 players, measured binaries), workflow-field research (13 searches), ranked developer-pain analysis, repo audit with receipts, and three judge verdicts (Switcher, Skeptic, Spread). All three judges converged on the same lead; the Switcher wanted the economics angle promoted into it, so the wedge below carries both.

**Number discipline (non-negotiable):** the binary is **1.9 MB** (1,919,720 bytes, measured 2026-07-03) — never say "~3MB". Tool count is **46** in the registry (say "45+" or "46") — never 47. Hostile commenters will count; under-claiming is itself quotable.

---

## 1. THE WEDGE

**The parallel-agent stack people duct-tape out of four tools — harness, orchestrator, viewer, tmux — collapsed into one 1.9 MB MIT binary you point at any model.**

Why this call: all three judges ranked the fused stack-collapse claim (C) first or second; the Skeptic showed it's the only conjunction no incumbent can neutralize with one release (Claude Code has workflows but is 221 MB and Anthropic-only; OpenCode is MIT+BYOM but a 41 MB Bun app with no runtime-level orchestration; Crush is small but FSL with no multi-agent). The Switcher's amendment — that the *action-driving* hook is "parallel agents at your price" — is honored by making BYOM economics the first pillar under the wedge, not a separate message.

---

## 2. THE LADDER

**Lead line:** *Real multi-agent workflows you can actually watch — in one 1.9 MB binary, on any model, at your price.*

### Pillar 1 — Workflows you can commit to git
Declarative, replayable orchestration: `/flows` runs JSON-defined workflows (or a one-line inline form) with sequential phases and parallel tasks, each task a **real detached OS subprocess** — not a thread, not an async task in one Node process — with per-task model override, watched live in a built-in 3-panel TUI with no tmux dependency. A task erroring does not kill the flow; the phase cascades when every task resolves. Contrast is deterministic-vs-dynamic: Claude Code's Dynamic Workflows are model-generated JS you must trust at runtime; a swarm-code flow is 14 lines of JSON you diff, review, and commit.
**Receipts:** `src/Flows.sw` (phase cascade :263-278; per-task `SWARM_CODE_MODEL` :210-232; inline form :9-17, 639-656), `src/Background.sw:61-85` (nohup-detached subprocesses with pid/exit/log files), `src/FlowsRender.sw` (3-panel alt-screen TUI), `examples/flows/review.json` (ships, runs as-is), hardened children via `SWARM_CODE_DENY_DANGEROUS=1`.

### Pillar 2 — Parallel agents at your price
Every incumbent's multi-agent story multiplies a vendor bill — the loudest documented pain of 2026 ($500–2,000/eng/mo, "5-hour session drained in 19 minutes", budget blowouts). swarm-code is BYOM to any OpenAI-compatible endpoint, so a three-agent fan-out on a local Qwen/GLM endpoint costs $0, and one flow can mix three different models across tasks. No OAuth hostage-taking — the field watched Anthropic ban third-party harnesses twice in H1 2026.
**Receipts:** README.md:76 (endpoint is one env var), per-task model override (Flows.sw:210-232), verified cost-pain corpus (morphllm, CloudZero, HN 47936579).

### Pillar 3 — The light harness (the verifiable number)
1.9 MB single native binary. No Node, no Python, no Electron, no npm, no postinstall scripts — nothing to compromise (the Cline 2.3.0 supply-chain attack made this visceral; OpenAI conceded the direction by rewriting Codex in Rust). 10–120x smaller than every named player: Claude Code 221 MB/version (856 MB on disk), Codex 94 MB, OpenCode 41 MB with an embedded Bun it can't patch, Crush ~25 MB and not open source. 46 built-in tools, one fail-closed policy chokepoint for every execution context, MIT.
**Receipts:** `bin/swarm-code` = 1,919,720 bytes (measured); `src/ToolRegistry.sw:33-99` (46 tools), :139-161 (single policy chokepoint); LICENSE (MIT); competitor sizes measured from release assets.

This is the sentence a skeptic can verify with `ls -la` before deciding whether to believe the rest — which is why the byte count belongs in the first paragraph of everything.

---

## 3. WHAT WE DON'T LEAD WITH

- **Air-gapped / local-only / network isolation** — **dropped as a wedge.** It isn't strictly true as stated (remote is one env var away — README.md:76), it filters out cloud-model users in the headline, and its real audience (defense, regulated enterprise) buys through procurement, not retweets. **Where it lands:** exactly one README checkbox line — "network isolation is a checkable property: no telemetry, no auto-updater, remote endpoint is one env var" — for the day someone greps for it. The supply-chain fragment (no npm, no postinstall) survives inside Pillar 3.
- **BYOM as headline** — commoditized (OpenCode: 75+ providers, 150K stars). Leading with it makes swarm-code "a smaller OpenCode". It rides shotgun inside Pillar 2, never alone.
- **"Swarm" orchestration hype** — radioactive post-claude-flow ("99% theater" audit). Only small verifiable claims; never cite agent counts we can't demo in a 60-second recording; demo, don't promise.
- **Council** — experimental, tool-level read-only, not a filesystem sandbox. Mention in the feature list, never in copy.
- **Terminal-UX parity** — open gaps (no LLM-request timeout, no input history, no syntax highlighting, sequential tool execution per turn). Don't claim CC-parity terminal polish.
- **Claims that are simply not true today (never say them):** live streaming transcripts in the flows TUI (OUTPUT panel shows status only); abort kills children (it doesn't — detached processes keep running); "pipelines" or data flow between phases (handoff is filesystem-convention only — say "phases"); precise token stats (regex-scraped, may read 0); "47 tools".

---

## 4. PROOF ASSETS

Three runnable demos (from the repo audit), mapped to pillars. Demo hygiene: fast local endpoint so tasks finish on camera; never zoom the STATS token column unless verified non-zero; end on the `⏺ flows complete: N/N tasks done in Xs` summary line.

**A. "Three reviewers, one diff" → Pillar 1 (zero setup).**
In any dirty repo: `swarm-code` → `/flows examples/flows/review.json`. Three agents (bugs / security / simplify) fan out over `git diff`; TUI shows 3 spinners → 3 checks → summary. The JSON is 14 lines — show it on screen before running: that *is* the "workflows you commit to git" argument.

**B. "One line, no JSON" → the wedge itself (primary spread artifact / 10-second GIF).**
`/flows tests: run make test and report failures; todos: grep the repo for TODO and FIXME and rank the top 5; deps: read the Makefile and list every external dependency` — one REPL line erupts into the live 3-panel TUI. Caption with the binary size. This is the demo-as-tweet.

**C. "Recon → Synthesize" bug-hunt → Pillars 1 + 2 (the money shot).**
Two-phase flow: three Recon tasks review different source files and write findings to `/tmp/hunt-*.md`; one Synthesize task merges them into a ranked `BUGS.md`. The left panel ticks Recon 0/3 → 3/3, then Synthesize auto-spawns — the phase-cascade frame. Pillar-2 flex: give each Recon task a different `"model"` — three models hunting simultaneously on a local endpoint, bill $0. (This is the Switcher's stated conversion demo.)

---

## 5. ONE-LINERS

1. the parallel-agent stack you've been duct-taping out of four tools — harness, orchestrator, viewer, tmux — is one 1.9mb binary now
2. claude code is 221mb per version, 856mb on my disk. swarm-code is 1.9mb, runs real parallel agents, and it's mit
3. ran a three-agent code review fan-out on a local qwen endpoint last night. total bill: $0
4. subagents here aren't threads in a node process. each flow task is a real detached os process. one errors out, the flow keeps going
5. my workflows are 14 lines of json committed to git. not javascript a model wrote for me at runtime
6. no node. no npm. no postinstall scripts. nothing to supply-chain. one binary
7. typed one line — `/flows tests: run make test; todos: rank the top fixmes; deps: list everything in the makefile` — and watched three agents work in a live tui. no tmux
8. not a vc-subsidized loss leader. just an mit binary that points at any openai-compatible endpoint and runs agents

---

## 6. FILM COPY — 8 chapters (serif, classy, silent)

Each chapter: display line (one *italic* word) + whispered monospace sub-line. Sequence follows the ladder: stack-collapse → number → purity → substrate → determinism → visibility → economics → license.

| # | Chapter line (serif) | Whispered sub-line (mono) |
|---|---|---|
| 1 | Four tools became *one*. | `harness + orchestrator + viewer + tmux → 1 binary` |
| 2 | One point *nine* megabytes. | `1,919,720 bytes. measured.` |
| 3 | Nothing to *install*. | `no node. no npm. no postinstall.` |
| 4 | Agents as *processes*. | `isolated. detached. one fails, the flow lives.` |
| 5 | Workflows you can *commit*. | `14 lines of json. diffable. replayable.` |
| 6 | Watch it all, *live*. | `three panels. no tmux.` |
| 7 | Any model. Your *price*. | `point it at your own endpoint. fan out for free.` |
| 8 | MIT. Entirely *yours*. | `github.com/skyblanket/swarm-code` |

---

*Sources: docs/HARNESS_REVIEW_2026-07.md, src/Flows.sw, src/FlowsRender.sw, src/Background.sw, src/ToolRegistry.sw, examples/flows/review.json, CHANGELOG.md; external evidence corpus cited in the July 2026 research rounds (landscape, workflows field, developer pain).*
