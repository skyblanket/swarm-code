# swarm-code Maintainability Review and Roadmap

- **Updated:** 2026-06-14
- **Current size:** ~19,304 LOC across 36 `.sw` modules
- **Verification:** 87 unit/regression checks, 8 focused module checks, 7 integration cases, and a headless smoke test

## Executive Summary

swarm-code has moved beyond the earlier "minimal trusted developer tool"
assessment. The major safety and reliability findings from the June 1 review
are implemented: hardline command blocks, guarded write paths, sudo controls,
tool-loop guardrails, history repair, retry jitter/fallbacks, subagent
restrictions, MCP lifecycle recovery, context compaction, secret redaction,
and real end-to-end tests.

The codebase's strongest long-term property is still its density: one native
binary, explicit process boundaries, and little dependency machinery. Its
main maintainability risk is now concentration rather than missing defenses.
`agent.sw`, `tools.sw`, `llm.sw`, and `main.sw` own too many concerns, and
several contracts are represented as loosely shaped `opts` maps.

## What Is Good

- **Small, inspectable runtime surface.** A maintainer can trace a tool call,
  LLM request, or session write without crossing framework layers.
- **Process-native isolation.** Tool workers, subagents, MCP owners, flows,
  background jobs, and heartbeat work use swarmrt processes and mailboxes.
- **Shared execution policy.** `ToolExecutor.sw` is now the boundary for
  context policy, hooks, guardrails, permissions, raw handlers, and post hooks.
- **Fail-closed non-interactive execution.** Subagents and MCP server calls
  cannot answer interactive permission prompts and cannot bypass hardline
  denies.
- **Human-readable persistence.** Session journals, memory crumbs, skills,
  config, and trajectories remain easy to inspect and repair.
- **Single-source release metadata.** `VERSION` generates `src/Version.sw`;
  CLI and MCP metadata report the same version.
- **Useful production gate.** `make check` runs the regression suite, smoke
  test, real-binary integration suite, and focused module checks.

## Cleared Findings

The following findings from the previous review are no longer open:

| Previous finding | Current implementation |
|---|---|
| No unconditional catastrophic-command floor | `Config.is_hardline_bash` plus unit and Agent/MCP integration coverage |
| No guarded write paths | `PathGuard.sw` protects sensitive destinations |
| Unsafe sudo execution | `Tools.do_bash` refuses sudo unless explicitly enabled |
| No tool-loop/failure guardrails | `ToolGuardrails.sw` blocks repeats and halts failure spirals |
| Weak retry and truncation handling | Jitter, fallback support, and length recovery in `llm.sw` |
| Broken message alternation after partial failures | `LLM.repair_history` repairs orphaned and partial tool calls |
| Unrestricted subagents | Tool context policy blocks nested/host-state operations |
| No MCP recovery | MCP startup state, reconnect, timeout, and pagination fixes |
| Minimal test coverage | Unit, smoke, mock-LLM integration, and MCP safety tests |
| Version drift | Generated `Version.sw` used by CLI, MCP client, and MCP server |
| Policy duplicated across execution paths | `ToolExecutor.sw` plus `ToolRegistry.allowed_in` |

## Remaining Production Work

### P0: Enforce a workspace sandbox

`PathGuard` protects known sensitive write locations, but swarm-code does not
yet provide an OS-level or workspace-root sandbox. A permitted shell command
can still read or mutate anything available to the user account.

**Target:** configurable workspace roots, read/write/network policy, and an
optional restricted process launcher for unattended flows and subagents.

### P0: Decompose the four largest ownership modules

The largest modules mix orchestration with domain behavior:

- `agent.sw`: REPL, sessions, slash commands, permissions, tool orchestration,
  subagents, and journaling
- `tools.sw`: handler registry plus every built-in handler
- `llm.sw`: provider configuration, request encoding, streaming, retry,
  history repair, and context accounting
- `main.sw`: CLI parsing, config assembly, startup, diagnostics, and UI boot

**Target:** extract one ownership boundary at a time while preserving public
entry points. Start with Agent session/journal code and LLM transport/retry.

### P1: Replace loosely shaped `opts` access with owned accessors

Cross-module behavior depends on string/atom keys in a shared map. Missing or
mistyped keys often degrade to `nil`, which makes contracts difficult to
review and test.

**Target:** introduce small accessor modules for session, execution, and LLM
options. Validate required fields at startup and at process boundaries.

### P1: Complete tool metadata consolidation

`ToolRegistry.sw` owns names and context policy, but handlers, schemas, and
prompt descriptions still live in separate lists. Adding a tool can still
produce drift.

**Target:** one declarative tool definition feeding identity, context policy,
schema, prompt text, and handler registration where the `sw` runtime permits.

### P1: Expand boundary and failure testing

Current tests cover the most important happy paths and safety regressions.
The largest remaining gaps are browser/CDP integration, MCP crash/reconnect
behavior, cancellation, malformed streaming payloads, and concurrent
session/background-job stress.

**Target:** add a regression case with every boundary fix and keep
`make check` below a practical local-development runtime.

### P2: Durable user recovery

There is no first-class checkpoint/undo flow for edits and no durable
thread-fork/rollback model.

**Target:** per-turn checkpoints for mutating file tools, explicit rollback,
and session forking without copying opaque state manually.

### P2: Secrets and cancellation

Environment variables are supported and persisted output is redacted, but
there is no OS keychain/secret-provider integration. Long LLM or tool
operations also lack consistent cooperative cancellation.

**Target:** secret references instead of plaintext values, plus cancellation
tokens propagated through LLM, browser, MCP, and tool workers.

## Maintenance Rules

1. All production tool execution goes through `ToolExecutor`; raw dispatch is
   limited to the shared boundary, Agent's isolated worker, and focused tests.
2. New execution contexts declare their tool policy in `ToolRegistry`.
3. New safety or lifecycle fixes include an integration regression where
   practical.
4. `VERSION` remains the only hand-edited product version.
5. `make check` is the required local, CI, and release verification command.
6. Split modules by ownership and contract, not only by line count.

## Recommended Sequence

1. Extract Agent session/journal ownership.
2. Add execution/session option accessors and startup validation.
3. Consolidate tool metadata and add a registry consistency test.
4. Add workspace sandbox policy for unattended execution.
5. Extract LLM transport/retry/provider concerns.
6. Add checkpoints, cancellation, and secret-provider integration.
