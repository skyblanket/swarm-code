# swarm-code harness review — July 2026

Full review of the harness (v0.4.0, ~21k lines sw) with emphasis on TUI/UX and markdown rendering. File:line refs against current main.

---

## Verdict

The core harness is stronger than the presentation layer. Agent loop, context management, crash recovery, and the safety stack are near state-of-the-art for a local agent. The TUI is where it lags: the markdown renderer misses constructs LLMs emit constantly (numbered lists, nested lists, italic), the stream-then-repaint architecture causes flicker and scrollback duplication, input handling drops type-ahead, and edits show no diffs.

---

## The Good

**Core loop (agent.sw, llm.sw)**
- Structured tool calls end-to-end — no stringify/re-parse round-trips (llm.sw:18-24).
- Two-tier context management: mechanical trim first, LLM compaction second, with hysteresis to 70% of budget so compaction doesn't churn every step (agent.sw:1709-1795).
- Fatal vs transient LLM error classification with backoff + Retry-After (llm.sw:1100-1138); fatal errors poison the journal so resume drops the bad turn (agent.sw:325-395).
- Isolated tool workers — a panicking tool can't kill the REPL; dispatch tokens prevent late-reply mis-attribution after ESC (agent.sw:2133-2207).
- Multi-provider failover chain preserving user work (llm.sw:827-860).
- Adaptive TTFT wait hint that learns observed model speed (llm.sw:1219-1254).

**Safety stack**
- PathGuard normalizes via `realpath -m` before validation — kills `../../` tricks (PathGuard.sw:31-34).
- Two-tier bash blocklist: dangerous (bypassable) vs hardline (never), with word-boundary matching to avoid false positives (config.sw).
- `shell_q()` POSIX escaping applied consistently; no templating injection surface (util.sw:7-17).
- Process-group SIGKILL on timeout/ESC — no grandchild leaks (tools.sw:138-212).
- Five-layer secret redaction in logs with sensible exemptions for git SHAs (log.sw:250-450).
- Single ToolExecutor chokepoint for agent/subagent/MCP contexts, fail-closed (ToolExecutor.sw).
- Per-tool output caps with head+tail truncation (test failures at the end survive).

**TUI — what already works**
- CC-style visual language (⏺ headers, ⎿ elbows, ▌ gutters) is coherent; colored per-agent blocks for subagents is genuinely nice (ui.sw:566-706).
- Token meter tints warn/error at 60%/85% of budget (ui.sw:262-267).
- Single-reader stdin discipline via the Reader process — fixed a real class of prompt races (reader.sw:30-36).
- Table renderer handles width clamping + proportional shrink correctly (markdown.sw:513-581).
- ANSI-aware `display_width` with correct CSI terminator handling (markdown.sw:776-809).

---

## The Bad

### Markdown renderer (markdown.sw) — biggest visible quality gap

1. **No ordered lists.** `1. foo` falls into the paragraph branch and consecutive numbered lines are space-merged into ONE wrapped line (walk_blocks:117-128). LLMs emit numbered lists constantly; this is the single most damaging rendering bug.
2. **Indentation destroyed.** `string_trim` on paragraph merge (:123) and bullet detection (:153) flattens nested bullets to one level and turns 4-space-indented code into paragraph soup.
3. **Repaint architecture is inherently janky** (repaint_streamed_prose:838-890): stream raw → cursor-up wipe → re-render. Consequences: visible flicker; responses taller than the screen leave the raw text AND a "─── rendered ───" duplicate permanently in scrollback (:869-876); row math breaks if the terminal is resized mid-stream; `count_terminal_rows` counts bytes, not display columns (:944-957).
4. **No italic** (`*x*`/`_x_`), no `__bold__`, no `~~strike~~`, no task lists `- [ ]`, no `+ ` bullets, no nested blockquotes, no escaped chars (`\*`), no `~~~` fences, no indented code blocks.
5. **Code blocks are just grey text** (render_code:329-343): no syntax highlighting, no language label, no background/border, and long lines hard-wrap at the terminal edge mid-token, breaking alignment.
6. **Color overload:** brand red is simultaneously h1/h2 heading color, inline-code color (:637), and the tool bullet. Everything important reads "red"; inline code needs its own hue/background.
7. **Tables:** cells truncate with `…` instead of wrapping; header row isn't bolded; alignment markers (`:---:`) parsed then ignored; `display_width` counts CJK/emoji as width 1 so those tables misalign.
8. **`has_markdown` misses** numbered lists, tables at string start (only checks `\n|`), and links — those responses never get the render pass at all (:895-906).
9. **Links** render as `label (url)` — no OSC 8 clickable hyperlinks.

### TUI / input UX

10. **Type-ahead is eaten.** While a non-shell tool runs, watch_loop reads stdin and drops every key except ESC/Ctrl-C (reader.sw:62-78). Users who type during a turn lose input silently. No message queuing (CC queues mid-turn input).
11. **No bracketed paste:** pasting a multiline snippet submits each line as a separate user turn.
12. **No input history / multiline editing** visible anywhere in the repo (up-arrow recall, ctrl-j newline, @file completion, slash-command completion). Some may belong in swarmrt's `read_line`, but the product lacks them either way.
13. **No diff rendering.** edit/write/multi_edit return `"ok: edited path"` (tools.sw:605-618). No colored ± hunks like CC — the user can't see what the agent changed without re-opening the file. Top-3 UX win.
14. **Tool results hard-capped at 8 lines** (ui.sw:170-179) with no expand affordance (no ctrl-o transcript mode, no /verbose).
15. **Colors are unconditional truecolor** — no NO_COLOR respect, no $COLORTERM detection, no 256-color fallback, no light-background theme (ui.sw:50-64).
16. **Spinner is static** — `spinner_start` prints one ◐ frame (ui.sw:361-363). No animated frames, no live "elapsed · tokens · esc to interrupt" ticker during streaming.
17. Permission prompts are plain `  > ` line reads (reader.sw:110-116) while an arrow-key picker (`read_choice`) already exists — inconsistent; allow/deny/always should be a picker.
18. Minor: `char_ord` folds uppercase to 0 so agent name colors collide (ui.sw:532-548); `agents_table` truncates names without ellipsis; `repeat_char`/padding are O(n) recursion per call.

### Core loop

19. **No timeout on the LLM request itself** — `http_post_stream` can hang forever; the 600s deadline covers tools only (llm.sw:1281-1303 vs agent.sw:2165).
20. **Sequential tool execution** — no parallel dispatch for independent calls (agent.sw:2412-2500).
21. Token estimate fallback is chars/4 — optimistic for code; risks first-turn overstuffing (agent.sw:1418-1420).
22. Mechanical trim skips multimodal blocks, so megabyte base64 images survive trimming and re-trigger compaction each turn (agent.sw:1738-1750).
23. Malformed tool-call args silently downgrade to `{}` instead of asking the model to reissue (agent.sw:2429).
24. Deterministic "jitter" (`attempt*7919+3571 % 401`) — concurrent agents thundering-herd (llm.sw:918-919).
25. Poison-marker file is global, races across concurrent headless sessions (agent.sw:333-345).
26. `max_steps()`=200 hits as a hard stop with no advance warning injected to the model (agent.sw:49, 1752-1755).

### Tools / safety / tests

27. TOCTOU window: symlink can be swapped between `realpath` resolution and the actual read/write (PathGuard.sw:31-34, tools.sw:357-390). Contained by the sensitive-path blocklist but real.
28. Glob silently truncates at 100 files with no `[truncated]` marker (tools.sw:760-762); grep schema doesn't document its caps.
29. Telemetry truncates tool args at 400 chars — audit trail incomplete (log.sw:85-93).
30. **tests/*.sw are all 8-line stubs** ("no pure tests"). Real coverage is concentrated in src/test_runner.sw; no security-regression tests (hardline bash, PathGuard, redaction) visibly gated in CI.

---

## What to build / change

### P0 — daily visible pain
1. **Markdown: ordered + nested lists.** Add `ordered` block kind (regex `^\d+[.)] `), preserve leading indent for nesting, stop trimming in paragraph merge. Small change, biggest visual payoff.
2. **Replace repaint with incremental block streaming.** Buffer the in-flight block; render each block through `Markdown.render` the moment its boundary arrives (blank line / fence close). Only the current block is ever raw on screen. Deletes the cursor-math, flicker, scrollback-duplication class of bugs entirely.
3. **Diff view for edit/write/multi_edit** — green/red ± lines, ~4 context lines, capped preview. Reuse the tool_result elbow layout.
4. **Stop eating type-ahead:** buffer non-ESC keys in watch_loop into a pending-input queue submitted as the next user turn; add bracketed-paste mode (ESC[200~) so pastes become one message.
5. **LLM request timeout** (config `llm_timeout_ms`, default ~120s) wired into http_post_stream.

### P1 — polish to parity
6. Code blocks: language label, dim border/background, wrap long lines with a `↪` continuation, and a tiny keyword-set highlighter for the top ~6 languages.
7. Input history: persist to `~/.swarm-code/history`, up/down recall (needs swarmrt read_line support); slash-command + @file completion.
8. Expandable tool results: keep full output in memory, ctrl-o or `/expand` to show the last one.
9. Color capability detection: honor NO_COLOR, fall back to 256-color when COLORTERM lacks truecolor; give inline code its own color; light-theme palette.
10. Table cell wrapping + wcwidth-aware `display_width` (CJK/emoji width 2).
11. Parallel tool execution for independent calls (infra — dispatch tokens — already exists).
12. Live stream status line: `✳ 12s · 1.4k tokens · esc to interrupt`, animated frames.
13. OSC 8 hyperlinks for links and file paths.
14. Picker-based permission prompts (allow once / always / deny) via existing read_choice.

### P2 — hardening
15. Populate tests/: markdown golden-file tests (fixture .md → expected ANSI), security regressions (hardline bash, PathGuard symlinks, redaction) wired into CI.
16. TOCTOU: O_NOFOLLOW-style open or combined stat+read in one shell step.
17. Session-scoped poison markers; real RNG jitter; image-block elision in mechanical trim; telemetry arg cap → 2000; glob/grep truncation markers.
18. max_steps: inject a "wrap up and report" message at ~90% of the cap; fix empty-retry flag to reset per response.
19. Themes config (`theme = dark|light|custom accent`).

---

*Method: direct line-by-line review of ui.sw, markdown.sw, reader.sw; two parallel deep-review passes over the core loop (agent/llm/main/executor) and the tool/safety/persistence layer; spot-verification of test stubs, diff rendering absence, NO_COLOR absence, and slash/help surfaces.*
