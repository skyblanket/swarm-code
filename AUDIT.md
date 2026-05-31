# swarm-code — Full Audit (2026-06-01)

Multi-agent audit of the current `main` tree (~13.5K LOC, 24 `sw` modules) on the swarmrt
runtime. Each dimension was swept by an independent finder, and **every finding was then
adversarially re-verified** by a second agent (instructed to refute, default-refute on doubt,
and to correct severity). Findings below are the survivors.

- **Confirmed: 39** · Uncertain: 1 · Refuted: 11 (false alarms killed by verification)
- Method: 3 fan-out workflows (`swarm-code-audit`, `-gapfill`, `-tools-safety`) → find → adversarial verify → synthesize.
- Scope note: the prior `REVIEW.md` P0/P1 items (hardline blocks, path-traversal write validation,
  sudo refusal, tool guardrails, subagent restriction, `repair_history`, jittered backoff, scheduler
  ms-units) are **already implemented** per `CHANGELOG.md`. This audit reports what is *not* yet fixed,
  plus places where an "already-fixed" item is incomplete (with proof).

Severity: **P0** data loss / crash / security · **P1** wrong behavior users hit regularly ·
**P2** edge-case wrong / UX glitch · **P3** polish / cleanup.

---

## P1 — fix first

| # | Area | Issue | File | Fix |
|---|------|-------|------|-----|
| 1 | tools/schema | **Entire long-tail toolset is unreachable in native mode (the DEFAULT config).** `git_commit`, `code_search`, `background`, `bg_*`, `sys_stats`, `heartbeat_status`, `log_wait`, `file_watch`, `forget` have handlers + prose but **no native schema** in `all_schemas()`. Native mode (Moonshot/Kimi default + every cloud provider) only executes structured `tool_calls`; the prose-discovery comment is false. So the default user cannot commit, search code, run background jobs, etc. | `ToolSchemas.sw:22-32` | Drive `all_schemas()` from the tool registry (membership ⇒ schema), or add the missing `*_s()` schemas. Delete the false "discover from prose" comment. |
| 2 | markdown | **`render_table` ignores its `width` arg** → wide tables overflow; printed via raw `print()` (not the column-aware emitter) so the terminal hard-wraps mid-cell / mid-`│`, destroying alignment. | `markdown.sw:357-376` | Clamp total width to `width`; shrink widest columns; truncate **raw** cell text (pre-ANSI) by display-width; clamp the divider too. |
| 3 | streaming | **Streamed `\uXXXX` corruption.** swarmrt's SSE decoder only handles `\n\t\r\"\\/`; `\u` falls to `default:` → literal `uXXXX`. The sw-side `fix_json_unicode_escapes` only patches 8 ASCII codepoints, so em-dashes/accents/CJK/emoji land as literal `u2014`/`ud83d…` in both the visible stream **and** stored history. `reasoning_content` gets no patch at all. | `swarmrt_builtins_studio.h:2013-2027, 2076-2091` + `llm.sw:544-553` | Add `case 'u'` (with surrogate-pair handling, mirroring `_json_parse_string`) to **both** SSE escape loops; widen the per-token guard to `-4`. Do **not** generalize the sw byte-heuristic. |
| 4 | streaming / agent | **`repair_history` doesn't fix *partial* trailing tool-result sets.** Crash mid-`execute_all` (results journaled one at a time) leaves `assistant(tool_calls=[a,b]) + tool(a)`. Neither `trim_incomplete` nor `drop_trailing_unmatched_calls` (last msg is `tool`) repairs it → **API 400 on every turn until `/reset`**. (Reported independently by two dimensions.) | `llm.sw:222-237` + `agent.sw:223-234` | In `repair_history`, for every assistant w/ `tool_calls`, synthesize stub `tool` results (`"[interrupted before completion]"`) for unanswered ids. |
| 5 | agent / security | **Permission picker 30s timeout desyncs with the Reader.** No correlation token: if the user takes >30s, main times out (deny) while the Reader is still blocked; the late "Yes" is consumed by the *next* permission prompt → a stale Yes auto-approves a different, later tool without prompting. | `agent.sw:1832-1858` + `reader.sw:42-56` | Thread a per-prompt token through `{'picker_ask',…,token}`/`{'picker_answer',token,idx}` and match it (drop stale), like `mcp_await_result`; or drop the timeout entirely (Reader is sole stdin owner). |
| 6 | scheduler | **Scheduled jobs fire immediately on creation.** `add()` seeds `last_run: 0`; `compute_next_fire` then returns a 1970 timestamp `< now`, so the next 2s heartbeat dispatches the job ~immediately instead of after the interval (and a past-slot `daily HH:MM` fires now). Correct only *after* the first spurious fire. | `scheduler.sw:99,170-211` | Seed `last_run: timestamp()` in `add()`. |

## P2 — high value

| # | Area | Issue | File | Fix |
|---|------|-------|------|-----|
| 7 | markdown | Post-stream repaint `count_terminal_rows` counts **bytes** and assumes full-width lines, but the C emitter word-wraps at `w-4` and skips UTF-8 continuation bytes → `clear_rows_up` leaves raw text *or* eats lines above (incl. the reasoning block). | `markdown.sw:791-804` | Expose an authoritative content-row count from the C emitter (`stream_content_rows()`); use it for both the clear and the 25-row threshold. |
| 8 | markdown | Long responses (>25 rows) print raw **and** rendered → full duplication. | `markdown.sw:737-743` | With the accurate row count + a `term_rows()` builtin, clear & re-render when it fits on screen; only fall back (no dup) when taller than the viewport. |
| 9 | markdown | `render_inline` doesn't handle `[label](url)` → raw link syntax shown. | `markdown.sw:520-551` | Add a link arm (label rendered, dimmed ` (url)`), graceful fall-through on no-match. |
| 10 | streaming | `finish_reason:"length"` recovery is **dead code** — the synthesized stream response never emits `finish_reason`, and the marker is already appended to content (so the empty-trim guard also fails). | `llm.sw:906-912` | Detect the `[Response truncated at max_tokens` marker substring; surface reasoning when content is just the marker. |
| 11 | streaming | `tok_budget` divide-by-zero **panic** when `MAX_TOKENS - reserve - buffer == 0` (degenerate env); negative budget prints nonsense %. | `llm.sw:460-473` | Clamp `tok_budget` to floor 1; clamp `tok_used_pct` ≥ 0. |
| 12 | streaming | Inband prose-strip splits on literal `"\ncall:"` but `parse_gemma_calls` accepts `.call:`/` call:` (GLM-5.1) → raw marker leaks into stored content and **duplicates** on the next request. | `llm.sw:1057-1066` | Cut at the first `call:` preceded by a non-word char (reuse the C `is_word` boundary, ideally via a shared builtin). |
| 13 | agent (daemon) | `cognitive_pulse` uses `chat_silent` (no tools array, strips `tool_calls`) → in native mode the daemon **physically cannot invoke tools**; and it never feeds tool results back to the model (truncated autonomous turn). | `agent.sw:496-523` | Use a native-aware silent path returning structured `tool_calls`; after `execute_all`, run a bounded follow-up turn. |
| 14 | MCP | Servers that finish handshake **after the 75s boot deadline** become invisible orphans (absent from `all_servers` → no schema, no `/mcp`, leaked child on quit). Pagination reuses a fresh 30s budget per page, blowing the deadline. | `mcp.sw:110,144-159,272-297,705-722` | Pre-register all configured names as `pending` in `init()`; thread one cumulative pagination deadline + page cap; track raw handles for shutdown. |
| 15 | MCP | No reconnect path: a transient failure marks a server `failed` **permanently** (whole toolset dark until process restart); owner loop parked on dead handle. | `mcp.sw:262-268,484-527` | `/mcp reconnect [server]`; require N consecutive failures before `failed`; add a `{'mcp_shutdown'}` owner clause. |
| 16 | MCP | Timed-out `tools/call` leaves its late response buffered; the next call drains it on its own deadline (budget theft / cascade). A single timeout flips the server permanently `failed`. | `mcp.sw:360-403` | Bounded drain-on-timeout; require N failures (keep "connection lost" immediate). |
| 17 | tools/safety | **Hardline blocklist substring-matches** `halt`/`reboot`/`shutdown`/`poweroff` inside ordinary words/paths (`asphalt`, `shutdown_handler.py`) — unbypassable false denial (fires before any env override). | `config.sw:227-232` | Tokenize the command; match whole command-words (basename-aware), splitting on `; && || |` + newline. Covers all halt-family tokens + `init 0/6`. |
| 18 | tools/schema | `forget` (memory CRUD) has handler + prose but no schema → uncallable in native mode while `remember/recall/memory_list` are callable. (Subset of #1.) | `ToolSchemas.sw:26` | Add `forget_s()` (required `slug`), include in `all_schemas()`. |
| 19 | tools/schema | `web_fetch` schema **lies**: required `prompt`, claims small-model extraction; impl ignores `prompt` and returns raw HTML-stripped text. Three sources disagree. | `ToolSchemas.sw:173-182` | Drop `prompt` from required; description = "Fetch a URL and return its text (HTML stripped)"; fix the stale `tools.sw` comment. |
| 20 | config | `max_tokens` from profile/settings.json is passed to the body **without int coercion** — a quoted `"8192"` becomes `max_tokens:"8192"` → 400 every turn (env path is sanitized; config path isn't). | `main.sw:471-477` | Type-aware coerce (`is_string` ⇒ parse) for `mt_prof`/`mt_set`, mirroring the env path (route via `parse_max_tokens_env` for the floor). |
| 21 | search | `session_search`/`/search` passes raw query into FTS5 `MATCH` → special chars (`"`, `C++`, `obj-c:`, bare `AND`) silently return **zero hits** (step error swallowed). | `SessionSearch.sw:171-180` | Escape into a safe phrase: per-token `"…"` with doubled inner quotes; optionally surface "unparseable query". |
| 22 | vision | `Vision.supports` defaults **ON** for every profile, contradicting the docstring's "profiles without the flag get a refusal" — text-only profiles silently send (and pay for) failing multimodal requests. | `vision.sw:28-31,113-154` | Pick one: restore opt-in default-OFF, or update the docstring to match default-on (and short-circuit clearly text-only profiles). |
| 23 | scheduler | Back-pressure can **permanently wedge** a job via PID reuse: `pid_alive` (`kill(pid,0)`, true on EPERM) on a recycled PID → `skipped_busy` forever; `maybe_fire` still bumps `last_run` so the skip is silent. | `scheduler.sw:283-315` | Store `pid:starttime` and re-verify, or have the child `rm` its pidfile on exit (subshell-wrapped); don't bump `last_run` on `skipped_busy`. |

## P3 — polish / cleanup

| # | Area | Issue | File |
|---|------|-------|------|
| 24 | markdown | `has_markdown` false-fires on `C#`/single backtick → unnecessary repaint frame. | `markdown.sw:763-779` |
| 25 | markdown | `display_width`'s ANSI-terminator allowlist is incomplete vs the C `0x40–0x7E` range → latent width miscount. | `markdown.sw:675-683` |
| 26 | markdown | `find_close` greedy `**` / `***` / empty-bold mis-render (uncertain — real but narrower than first claimed). | `markdown.sw:537-545` |
| 27 | streaming | `record_usage(nil)` wipes cached `prompt_tokens` when a stream omits usage → budget falls back to the crude estimate. | `llm.sw:1288-1307` |
| 28 | streaming | Dead `"interrupted"` fail-reason branch — never set; suppression works only incidentally. | `llm.sw:798-817` |
| 29 | streaming | Retry jitter uses `timestamp()` low bits (deterministic within a ms) though `random_int` exists → lockstep cross-process retries. | `llm.sw:775-794` |
| 30 | agent | Subagents can clobber the main todo list (`todo_write` shares one ETS key, not in `SUBAGENT_BLOCKED_TOOLS`). | `agent.sw:1715-1722` + `tools.sw:1417-1434` |
| 31 | background | Bg poll can resurrect a user-killed task as done/error (read-then-write race on status). | `background.sw:149-169,229-264` |
| 32 | scheduler | Scheduled job output files (`scheduled-<id>-<ts>.out`) accumulate unbounded — no retention. | `scheduler.sw:39-40,290` |
| 33 | tools | Dead `context_meter` tool definitions (schema + prose + handler) after replacement by `inject_context_status`. | `ToolSchemas.sw:357-365` + `prompts.sw:317` + `tools.sw:901` |
| 34 | quality | Duplicated atom-vs-string map-key helper across `config.sw` and `main.sw` (drifting nil-handling). | `main.sw:558-574` + `config.sw:283-303` |
| 35 | quality | `run_doctor` continues with nil `$HOME`, reporting a misleading relative path and inspecting the wrong location. | `main.sw:826-839` |

> #36–39 (MCP studio scope note + remaining mcp lifecycle items) and the `tools-safety` deep-dive
> are folded into the sections above; the per-finding verifier reasoning + fix assessments live in the
> workflow transcripts under `…/tasks/`.

---

## Status — fixed in this pass

**26 of 39 fixed** (all 6 P1s, all named UI/markdown items, and the cheap/safe P2–P3s).
Build green; `make test` 38 → **43** with new regression guards; diff re-reviewed by an adversarial workflow.
See `CHANGELOG.md` for the per-fix detail.

| Fixed | Findings |
|-------|----------|
| **P1** | #1 long-tail native schemas · #2 `render_table` width clamp · #3 `\uXXXX` SSE decode (swarmrt) · #4 `repair_history` partial-tool-result backfill · #5 picker correlation token (security) · #6 scheduler immediate-fire |
| **P2** | #7 authoritative repaint row count (`stream_content_rows()`) · #8 viewport-aware threshold (`term_rows()`) · #9 markdown links · #10 `finish_reason` recovery via marker · #11 `tok_budget` divide-by-zero clamp · #12 inband marker alignment · #17 hardline word-boundary · #18 `forget` schema · #19 `web_fetch` schema · #20 `max_tokens` int coercion · #21 FTS5 escaping · #22 vision docstring |
| **P3** | #24 `has_markdown` tightening · #25 `display_width` CSI range · #26 bold flanking guard · #27 `record_usage` no-wipe · #28 dead `"interrupted"` branch · #29 retry jitter `random_int` · #30 subagent `todo_write` block · #31 background `ets_cas` race · #33 (partial — dead `context_meter` schema removed) |

### Remaining (follow-up — feature-shaped or low-impact, deliberately deferred)

| # | Sev | Why deferred |
|---|-----|--------------|
| 13 | P2 | Daemon `cognitive_pulse` native tool-calls — needs a new native-aware silent chat path (the naive swap breaks `chat_silent`'s string contract); daemon-mode-only, off by default. |
| 14 / 15 / 16 | P2 | MCP lifecycle (pre-register late servers, `/mcp reconnect`, drain-on-timeout) — genuine features, not one-line fixes; only bites configured-MCP users on a transient failure. |
| 23 | P2 | Scheduler PID-reuse wedge — needs `pid:starttime` re-verification or child-side pidfile cleanup + not bumping `last_run` on `skipped_busy`; rare trigger (PID recycle within one interval). |
| 32 | P3 | Scheduled-output retention sweep — slow disk growth only for long-lived frequent jobs. |
| 33 | P3 | Remove the two remaining dead `context_meter` defs (`prompts.sw`, `tools.sw`); the native-mode-relevant schema is already gone. |
| 35 | P3 | `run_doctor` nil-`$HOME` graceful exit — needs control-flow restructure (`sw` has no `return`); diagnostics-only, rare env. |
