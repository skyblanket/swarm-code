# swarm-code TUI/UX review — 2026-07-06

Six-dimension review of v1.0.0 + auto-backgrounding (main @ 83f73c3): closure verification of [HARNESS_REVIEW_2026-07.md](HARNESS_REVIEW_2026-07.md), streaming/repaint deep-dive, input UX, rendering, feedback loops, and Claude Code parity (mined from the extracted CC v2.1.88 source + autopsy docs). ~95 findings, every one verified against current source with file:line. Method: 6 parallel reviewers + adversarial probes (compiled markdown probes, suite runs).

---

## Verdict

v1.0.0's audit closures are real — 18 prior findings verified fixed in code, not just claimed (ordered/nested/task lists, edit diffs, NO_COLOR pipeline, permission picker, max-steps nudge, CI-gated markdown+security tests, and — via the swarmrt runtime — bracketed paste at idle, in-session history, and full emacs line editing, which the prior review didn't know existed).

What remains is concentrated in **one architectural root cause**: the LLM call runs *synchronously inside main_loop* (agent.sw:1845), and the C runtime paints raw tokens directly to the terminal. Everything downstream follows from this — the stream-then-repaint flicker, tall-response scrollback duplication, the impossibility of a live ticker or esc-hint, type-ahead being eaten, and autonomous wake turns colliding with the pinned input line.

**The key discovery:** the fix infrastructure already exists, unused. `http_post_stream` has a 5-arg form that routes `{'stream_chunk', name, c}` / `{'stream_reason', name, c}` / `{'stream_done', name}` to any pid instead of painting (llm.sw:1727, built for `chat_for_subagent`), and `stream_chunk_render` + `stream_state_table` (ui.sw:748-782, main.sw:186) are wired but have zero callers. The streaming rewrite is therefore **wiring, not construction**.

---

## Verified closed in v1.0.0 (no action)

Ordered lists (markdown.sw:104,191-225) · nested bullet depth (:173-185) · task checkboxes (:404-422) · `+` bullets (:161) · bold table headers (:595) · has_markdown detection (:1036-1056) · edit/multi_edit ± diff (agent.sw:2515, ui.sw:264) · NO_COLOR palette gate (ui.sw:53-75) · permission arrow-picker (agent.sw:2567-2606) · malformed-args reissue (:2469) · max-steps 90% nudge (:1838) · empty-retry per-response reset · telemetry cap 400→2000 (log.sw:127) · glob cap notice (tools.sw:916) · markdown+security tests CI-gated via `make check` (105/105) · **runtime**: bracketed paste at idle prompt, in-session up/down history, emacs editing (swarmrt read_line, studio.h:7320-7790).

Narrower-than-claimed: diff covers edit/multi_edit but **not write**; NO_COLOR covers the palette pipeline but **~52 raw ANSI diagnostic prints** bypass it (agent.sw 36, llm.sw 11, main.sw 4, tools.sw 1); nested-list indent preserved but 4-space **indented code still merges into paragraph soup** (probe-confirmed).

---

## Wave 1 — the streaming rewrite (flagship; one coherent project)

Root cause + four dependents, one design. Est. 2-3 focused days.

1. **Worker-routed LLM call** (agent.sw:1845). Spawn a worker that calls the existing 5-arg `http_post_stream(url, hdrs, body, main_pid, "main")` and sends `{'llm_result', …}` when done; main_loop stays in receive. This unblocks everything below and gives a natural place for the still-missing **LLM request timeout** (prior #19: a hung connection currently blocks the turn forever — llm.sw:1303).
2. **Incremental block streaming** (markdown.sw:970-1107). `Markdown.stream_feed/stream_flush` buffer the in-flight block; render each block once via `Markdown.render` at its boundary (blank line / fence toggle / list-run end). Delete `repaint_streamed_prose`, `count_terminal_rows`, `clear_rows_up`. Kills in one stroke: flicker (prior #3), tall-response raw+rendered scrollback duplication (markdown.sw:1002-1007), byte-vs-column row math, the fragile ±1-row C-framing coupling (:1009), the plain-vs-markdown gutter inconsistency (:976), and the leftover wait_hint line per turn (llm.sw:1294).
3. **Live stream ticker**: `✳ 12s · 1.4k tok · esc to interrupt` on a `\r` line, ~1s tick process; blocks print via print_above so they never collide. Replaces the dead `spinner_start/stop` (ui.sw:437-443). ESC mid-stream via the existing reader `watch_interrupt` handshake (agent.sw:2188) — flush partial block, print `[interrupted]`, kill worker. Surfaces the esc affordance nowhere shown today.
4. **Autonomy/stream collision fix** (agent.sw:780, 818, 727-738): bg_done/bg_stalled/pulse reaction turns currently print over the pinned idle input line while the Reader is blocked in read_line — with auto-bg + autonomy both default-on this fires after every long build. Pause the reader (mirror watch handshake) before autonomous turns, redraw the prompt after.

## Wave 2 — input pipeline (runtime + harness; est. 1-2 days)

5. **Pending-input queue** (P0, the last big daily pain): keys typed mid-turn are discarded at three C sites (stream watcher studio.h:1490-1503, reader watch_loop reader.sw:62-77, auto-bg wait tools.sw:441-457). Add a shared C ring buffer + `stdin_take_pending()` builtin; all three sites deposit instead of discard; `handle_user_input_msg` drains it as a seed for the next read_line (CC-style queued input). Also fixes mid-turn paste loss and makes the post-interrupt `tcflush` preserve legitimate type-ahead; drain-loop the auto-bg `read_key` poll so a queued ESC isn't delayed 150ms per preceding byte.
6. **History persistence**: runtime `rl_history_load/append(path)` + `~/.swarm-code/history` (in-session recall already works; it just forgets on restart — studio.h:7320-7330).
7. Deferred (L, needs runtime Tab hook): slash/@file completion — Tab currently never reaches sw.

## Wave 3 — rendering polish (all sw-side, mostly S/M; est. 1-2 days)

8. Inline machine (markdown.sw:759-808): italic `*x*`/`_x_` (flanking heuristic like `**`), `__bold__`, `~~strike~~`, `\*` escapes, `~~~` fences (:149), 4-space indented-code block kind + stop trimming paragraph indent (:127).
9. Code blocks (:443-457): language label from fence info, dim border, wrap at width with `↪` continuation, small keyword highlighter.
10. De-red inline code (:769) — distinct hue/dim background; brand red reserved for headings + tool bullets (prior #6).
11. **Real diff**: LCS line-level diff with context + line numbers (current preview prints whole old block red / new block green — a 1-line change in a 6-line old_string can push the changed line past the 4-line cap); extend to `write` overwrites.
12. Tables (:619-631): wrap cells instead of `…`, apply parsed `:---:` alignment (parsed then discarded today), wcwidth-aware display_width (CJK/emoji width 2, :912-931).
13. OSC 8 hyperlinks for links + file:line refs (:799); OSC 2 terminal title per turn (`swarm-code — dir: prompt…`).
14. Fit-and-finish: `+`-bullet has_markdown gap (:1031); network-isolation warning printed before the banner (main.sw:106 vs :114); route the 52 raw ANSI diagnostic prints through paint(); char_ord uppercase collision (ui.sw:624).

## Wave 4 — surfaces & discoverability (S/M; est. 1 day)

15. **/bg user surface**: every bg notice tells the USER to run model-only tools (`bg_result bg-3` — not a slash command; agent.sw:785,800, tools.sw:419). Add `/bg` (list), `/bg tail N`, `/bg kill N` proxying Background fns; reword notices.
16. Unknown-slash feedback (agent.sw:597-600): `/halp` silently goes to the LLM; command-shaped unknown slashes should print `unknown command (type /help)`.
17. `/expand` (or ctrl-o) to reprint the last tool result in full (8-line cap has no affordance today — ui.sw:217).
18. Footer: add cwd basename + git branch; draw before the first prompt and after autonomous turns (currently only after user turns, one turn stale — ui.sw:331-347).
19. ESC=cancel at plan-confirm (plan.sw:600-608 — today ESC just clears the line; Enter-on-empty is the only reject). Delete dead `handle_permission` + `{'permission_ask'}` arm (reader.sw:110-116) and dead spinner exports.
20. shift+tab permission-mode cycling + auto-accept-edits mode + prompt mode chip (CC parity).
21. COLORTERM detection + 256-color fallback + light/daltonized theme config (only NO_COLOR today; palette is unconditional truecolor).

## Backlog (core-loop, non-TUI — tracked, not in these waves)

Parallel read-only tool dispatch (prior #20) · image-block elision in mechanical trim (#22 — code currently does the opposite) · real RNG retry jitter (#24) · session-scoped poison markers (#25) · PathGuard TOCTOU one-shot check (#27) · chars/4 token estimate (#21) · grep cap in schema docs · delete misleading 8-line tests/*.sw stubs.

---

*Full per-finding detail (95 findings with file:line + fix sketches): workflow wf_34e8fcd1-e4f, this repo's review session 2026-07-06.*
