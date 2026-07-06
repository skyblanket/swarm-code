module Agent

# ============================================================
# Agent — REPL loop + tool dispatch (structured tool_calls)
# ============================================================
#
# The interactive loop:
#   1. Read a line from stdin (prompt "> ")
#   2. Append a %{role:'user', content: line} message
#   3. Call LLM.chat → %{content, tool_calls, reasoning}:
#        - Append %{role:'assistant', content, tool_calls, reasoning}
#        - If tool_calls is non-empty, execute each in order, append
#          one %{role:'tool', tool_call_id, content: result} per call
#        - Loop: re-call LLM with the updated history
#      Stop when the assistant emits no tool_calls.
#   4. Back to (1).
#
# Structured rule (matches Claude Code's pattern, see
# /Users/sky/claude-code/src/services/api/claude.ts:2201-2238):
# tool calls are STRUCTURED content peers to text — they live as a
# separate `tool_calls` field on the assistant message, all the way
# through history and back to the API on subsequent turns. No
# parse → stringify → re-parse cycle, no risk that the model echoing
# the format in prose gets mis-dispatched as a real tool call.

import LLM
import Tools
import Config
import UI
import Reader
import Log
import Mcp
import Skills
import SessionSearch
import Vision
import Scheduler
import ToolRegistry
import Trajectory
import Util
import ToolGuardrails
import Plan
import Flows
import ToolExecutor

export [run, run_headless, subagent_blocked, SUBAGENT_BLOCKED_TOOLS,
        drop_to_last_clean_user, trailing_turn_incomplete, trim_incomplete,
        looks_like_slash_command, is_known_slash_command, bg_normalize_id,
        get_session_mode, set_session_mode, next_mode, resolve_permission,
        show_expand, handle_bg_command, route_input]

# Maximum tool-call rounds per user turn.
fun max_steps() { 200 }

# ------------------------------------------------------------
# Context budget — token-based, sourced from server usage
# ------------------------------------------------------------
fun max_tokens_env()      { parse_env_int("SWARM_CODE_MAX_TOKENS",      262144) }
fun output_reserve_env()  { parse_env_int("SWARM_CODE_OUTPUT_RESERVE",   16384) }
fun compact_buffer_env()  { parse_env_int("SWARM_CODE_COMPACT_BUFFER",   52000) }

fun context_budget_tokens() {
    max_tokens_env() - output_reserve_env() - compact_buffer_env()
}

# When a compaction fires (over context_budget_tokens), trim/summarize down to
# THIS lower level — not just barely under the trigger — so the next several tool
# steps can add output without immediately re-crossing the budget. This is the
# hysteresis margin (~70% of budget) that stops the per-step trim churn that
# reads as "compacting on every turn". Mirrors how claude-code's post-compaction
# summary lands far below the threshold so it won't re-fire for many turns.
fun compact_target_tokens() { context_budget_tokens() * 70 / 100 }

fun context_budget_chars_fallback() {
    context_budget_tokens() * 4
}

fun parse_env_int(name, fallback) {
    env = getenv(name)
    if (env == nil) { fallback }
    else {
        parsed = parse_budget_env(env, 0, 0, 'false')
        if (parsed < 0) { fallback } else { parsed }
    }
}

fun parse_budget_env(s, i, acc, saw_digit) {
    if (i >= string_length(s)) {
        if (saw_digit == 'true') { acc } else { 0 - 1 }
    } else {
        ch = string_sub(s, i, 1)
        d = if (ch == "0") { 0 } else { if (ch == "1") { 1 }
            else { if (ch == "2") { 2 } else { if (ch == "3") { 3 }
            else { if (ch == "4") { 4 } else { if (ch == "5") { 5 }
            else { if (ch == "6") { 6 } else { if (ch == "7") { 7 }
            else { if (ch == "8") { 8 } else { if (ch == "9") { 9 }
            else { 0 - 1 }}}}}}}}}}
        if (d < 0) {
            if (saw_digit == 'true') { acc } else { 0 - 1 }
        } else {
            parse_budget_env(s, i + 1, acc * 10 + d, 'true')
        }
    }
}

fun session_dir() { getenv("HOME") ++ "/.swarm-code/sessions" }

# ============================================================
# Crash-recovery journal
# ============================================================
# Layout (~/.swarm-code/sessions/):
#   journal-<ts>.jsonl  — one JSON object per line, the message map
#   .active             — pointer file holding the live session's
#                         journal path. Deleted on a clean /quit.
#
# The system prompt is NOT journaled. Format v2 writes objects
# {role, content, tool_calls?, tool_call_id?, reasoning?}; v1 wrote
# 2-element arrays ["role", "content"] — replay_journal accepts both.
fun journal_active_ptr() { session_dir() ++ "/.active" }

# Serialize history (minus the system message) to JSONL text.
fun encode_journal(history) {
    encode_journal_loop(history, "")
}

fun encode_journal_loop(msgs, acc) {
    if (length(msgs) == 0) { acc }
    else {
        msg = hd(msgs)
        role = map_get(msg, 'role')
        if (role == 'system') {
            encode_journal_loop(tl(msgs), acc)
        } else {
            line = json_encode(msg_for_journal(msg)) ++ "\n"
            encode_journal_loop(tl(msgs), acc ++ line)
        }
    }
}

# Convert an in-memory message map to its on-disk JSON shape.
# Atom role becomes a string; nil/missing optional fields are omitted.
fun msg_for_journal(msg) {
    role = map_get(msg, 'role')
    base = %{
        role: to_string(role),
        content: to_string(map_get(msg, 'content'))
    }
    tcs = map_get(msg, 'tool_calls')
    out1 = if (tcs == nil || length(tcs) == 0) { base }
           else { map_put(base, 'tool_calls', tcs) }
    tcid = map_get(msg, 'tool_call_id')
    out2 = if (tcid == nil) { out1 }
           else { map_put(out1, 'tool_call_id', to_string(tcid)) }
    reasoning = map_get(msg, 'reasoning')
    if (reasoning == nil) { out2 }
    else { map_put(out2, 'reasoning', to_string(reasoning)) }
}

# Atomically rewrite the journal to match current in-memory history.
fun journal_sync(opts, history) {
    jp = map_get(opts, 'journal_path')
    if (jp == nil) { 'ok' }
    else {
        # Direct write — the original code did file_write(tmp) + shell(mv)
        # for crash-atomicity, but swarmrt's shell() builtin polls every
        # 1s, making each journal sync (and we sync after every turn) feel
        # awful. The replay_journal parser already tolerates corrupt /
        # truncated lines (json_decode of a partial line returns nil and
        # is skipped), so a torn write at most loses the last turn — same
        # as the rename approach would on a power-cut anyway.
        file_write(jp, encode_journal(history))
        'ok'
    }
}

# Replay a journal file into a message list (no system message).
fun replay_journal(path) {
    content = file_read(path)
    if (content == nil) { [] }
    else { replay_lines(string_split(content, "\n"), []) }
}

fun replay_lines(lines, acc) {
    if (length(lines) == 0) { acc }
    else {
        ln = string_trim(hd(lines))
        if (string_length(ln) == 0) {
            replay_lines(tl(lines), acc)
        } else {
            parsed = json_decode(ln)
            if (parsed == nil) { replay_lines(tl(lines), acc) }
            else {
                msg = replay_one(parsed)
                if (msg == nil) { replay_lines(tl(lines), acc) }
                else { replay_lines(tl(lines), list_append(acc, msg)) }
            }
        }
    }
}

# Convert a journal-parsed value back into a message map. Accepts
# both v1 ([role, content] arrays) and v2 ({role, content, ...} maps).
fun replay_one(parsed) {
    if (is_list(parsed) == 'true') {
        # v1 legacy: 2-element array.
        if (length(parsed) < 2) { nil }
        else {
            role = string_to_role(to_string(hd(parsed)))
            body = hd(tl(parsed))
            %{role: role, content: to_string(body)}
        }
    }
    else { if (is_map(parsed) == 'true') {
        role_str = map_get(parsed, 'role')
        content_v = map_get(parsed, 'content')
        role_a = string_to_role(to_string(role_str))
        base = %{
            role: role_a,
            content: if (content_v == nil) { "" } else { to_string(content_v) }
        }
        tcs = map_get(parsed, 'tool_calls')
        out1 = if (tcs == nil) { base } else { map_put(base, 'tool_calls', tcs) }
        tcid = map_get(parsed, 'tool_call_id')
        out2 = if (tcid == nil) { out1 }
               else { map_put(out1, 'tool_call_id', to_string(tcid)) }
        reasoning = map_get(parsed, 'reasoning')
        if (reasoning == nil) { out2 }
        else { map_put(out2, 'reasoning', to_string(reasoning)) }
    } else { nil }}
}

# Drop a trailing assistant message that has unresolved tool_calls —
# the prior turn crashed before the tool results were journaled, so
# the next request would carry orphan tool_calls and the API would
# reject it (or worse, re-dispatch on the model's next echo).
#
# F2: also handles two more crash artefacts:
#   - a trailing assistant whose tool_calls[].arguments fail json_decode
#     (a turn that died mid-stream with a truncated/malformed tool call —
#     re-sending it would 400 / re-poison). The has_tcs branch already
#     drops ANY trailing assistant with tool_calls, so malformed args are
#     covered too; trailing_tools_incomplete handles the case where a
#     PARTIAL set of tool results was journaled after it.
#   - a trailing unanswered tool_use: the last record(s) are role:'tool'
#     answering only SOME of the preceding assistant's tool_calls (or that
#     assistant's calls are malformed). Drop the whole incomplete turn so
#     resume restarts from the last clean point.
fun trim_incomplete(msgs) {
    if (length(msgs) == 0) { msgs }
    else {
        last = hd(take_last(msgs, 1))
        role = map_get(last, 'role')
        if (role == 'assistant') {
            tcs = map_get(last, 'tool_calls')
            if (tcs == nil || length(tcs) == 0) { msgs }
            else { drop_last(msgs, 1) }
        }
        else { if (role == 'tool') {
            # Trailing tool result(s). Find the assistant that opened this
            # tool-call turn; if its calls aren't all answered, or its args
            # are malformed, drop the assistant + all its trailing tools.
            if (trailing_turn_incomplete(msgs) == 'true') {
                drop_trailing_tool_turn(msgs)
            } else { msgs }
        } else { msgs }}
    }
}

# True when the trailing run of role:'tool' messages does NOT cleanly answer
# the assistant tool_calls that opened the turn (partial set, or the calls'
# arguments don't parse — both mean the turn never completed cleanly).
fun trailing_turn_incomplete(msgs) {
    n = length(msgs)
    tools_run = count_trailing_tools(msgs, n - 1, 0)
    asst_idx = n - 1 - tools_run
    if (asst_idx < 0) { 'true' }
    else {
        asst = nth_at(msgs, asst_idx)
        if (map_get(asst, 'role') != 'assistant') { 'true' }
        else {
            tcs = map_get(asst, 'tool_calls')
            if (tcs == nil || length(tcs) == 0) { 'false' }
            else {
                if (tcs_args_malformed(tcs) == 'true') { 'true' }
                else { if (tools_run < length(tcs)) { 'true' } else { 'false' } }
            }
        }
    }
}

fun count_trailing_tools(msgs, i, acc) {
    if (i < 0) { acc }
    else {
        m = nth_at(msgs, i)
        if (map_get(m, 'role') == 'tool') { count_trailing_tools(msgs, i - 1, acc + 1) }
        else { acc }
    }
}

# Drop the trailing run of tool messages AND the assistant that opened them.
fun drop_trailing_tool_turn(msgs) {
    n = length(msgs)
    tools_run = count_trailing_tools(msgs, n - 1, 0)
    drop_last(msgs, tools_run + 1)
}

# True when any tool_call carries a non-empty arguments blob that fails to
# json_decode (truncated mid-string) — the turn is poisoned and unsendable.
fun tcs_args_malformed(tcs) {
    if (length(tcs) == 0) { 'false' }
    else {
        tc = hd(tcs)
        raw = to_string(map_get(tc, 'arguments'))
        trimmed = string_trim(raw)
        bad = if (trimmed == "" || trimmed == "{}" || trimmed == "null") { 'false' }
              else { if (json_decode(raw) == nil) { 'true' } else { 'false' } }
        if (bad == 'true') { 'true' } else { tcs_args_malformed(tl(tcs)) }
    }
}

fun nth_at(lst, i) {
    if (i == 0) { hd(lst) }
    else { nth_at(tl(lst), i - 1) }
}

# ------------------------------------------------------------
# F2 — poison / clean-exit markers beside .active
# ------------------------------------------------------------
# A turn that ends on an UNRECOVERED llm error writes .poison (holding the
# journal path) so the next launch knows the recorded session died mid-turn
# and trims the failing turn back to the last clean user message instead of
# replaying the poisoned tool_call. A clean /quit writes .clean_exit. Both
# are cleared when a fresh session starts.
fun journal_poison_ptr()      { session_dir() ++ "/.poison" }
fun journal_clean_exit_ptr()  { session_dir() ++ "/.clean_exit" }

fun mark_poison(opts) {
    jp = map_get(opts, 'journal_path')
    if (jp == nil) { 'ok' }
    else {
        file_write(journal_poison_ptr(), to_string(jp))
        'ok'
    }
}

fun clear_poison() {
    p = journal_poison_ptr()
    if (file_exists(p) == 'true') { file_delete(p) }
    'ok'
}

fun clear_clean_exit() {
    p = journal_clean_exit_ptr()
    if (file_exists(p) == 'true') { file_delete(p) }
    'ok'
}

# Is the named journal path flagged poisoned (died on an llm error)?
fun journal_is_poisoned(journal_path) {
    p = journal_poison_ptr()
    if (file_exists(p) == 'false') { 'false' }
    else {
        recorded = file_read(p)
        if (recorded == nil) { 'false' }
        else {
            if (string_trim(recorded) == string_trim(to_string(journal_path))) { 'true' }
            else { 'false' }
        }
    }
}

# Drop trailing assistant/tool records back to (and including) the last
# role:'user' message — the last clean point. Used on resume of a poisoned
# session so the failing turn never re-fires. Keeps system + everything up
# to and including the last user message.
fun drop_to_last_clean_user(msgs) {
    idx = last_user_index(msgs, length(msgs) - 1)
    if (idx < 0) { msgs }
    else { take_first(msgs, idx + 1, []) }
}

fun last_user_index(msgs, i) {
    if (i < 0) { 0 - 1 }
    else {
        m = nth_at(msgs, i)
        if (map_get(m, 'role') == 'user') { i }
        else { last_user_index(msgs, i - 1) }
    }
}

fun journal_clean(opts) {
    ap = journal_active_ptr()
    if (file_exists(ap) == 'true') { file_delete(ap) }
    # F2: a clean /quit clears any poison flag and records a clean-exit
    # marker so the next launch knows the prior session ended deliberately.
    clear_poison()
    file_write(journal_clean_exit_ptr(), to_string(timestamp()))
    'ok'
}

# ------------------------------------------------------------
# Entry point — called from Main.main once config is ready.
# ------------------------------------------------------------
fun run(opts, system_prompt_text) {
    register('main_agent', self())

    # Crash-recovery journal: set up / resume.
    # file_mkdir is a direct mkdir() syscall — was shell("mkdir -p") which
    # cost a full second per session start because swarmrt's shell() polls
    # every 1s.
    jdir = session_dir()
    file_mkdir(jdir)
    ap = journal_active_ptr()
    prev_ptr = if (file_exists(ap) == 'true') { file_read(ap) } else { nil }
    prev_path = if (prev_ptr == nil) { "" } else { string_trim(prev_ptr) }
    # F2: was the recorded session flagged poisoned (died on an llm error)?
    prev_poisoned = if (string_length(prev_path) > 0) { journal_is_poisoned(prev_path) }
                    else { 'false' }
    resumed_raw = if (prev_ptr == nil) { [] }
                  else {
                      if (string_length(prev_path) > 0 && file_exists(prev_path) == 'true') {
                          replay_journal(prev_path)
                      } else { [] }
                  }
    # F2: on a poisoned session, trim the failing turn back to the last clean
    # user message (drop the poisoned tool_call) BEFORE the usual incomplete
    # trim, so resume never re-fires the call that killed the prior session.
    resumed_clean = if (prev_poisoned == 'true') { drop_to_last_clean_user(resumed_raw) }
                    else { resumed_raw }
    resumed = trim_incomplete(resumed_clean)

    journal_path = if (length(resumed) > 0) {
        prev_path
    } else {
        jp_new = jdir ++ "/journal-" ++ to_string(timestamp()) ++ ".jsonl"
        file_write(jp_new, "")
        jp_new
    }
    file_write(ap, journal_path)
    # Fresh working session — clear the prior poison/clean-exit markers; a new
    # failure or a new clean /quit will re-stamp them.
    clear_poison()
    clear_clean_exit()
    opts_journal = map_put(opts, 'journal_path', journal_path)

    history = if (length(resumed) > 0) {
        print("")
        if (prev_poisoned == 'true') {
            print(UI.grey_text() ++ "  ⏺ previous session ended on an error — trimmed the " ++
                  "failing turn; resumed " ++ to_string(length(resumed)) ++ " messages" ++ UI.reset())
        } else {
            print(UI.grey_text() ++ "  ⏺ resumed crashed session — " ++
                  to_string(length(resumed)) ++ " messages recovered" ++ UI.reset())
        }
        prepend([LLM.new_message_system(system_prompt_text)], resumed)
    } else {
        [LLM.new_message_system(system_prompt_text)]
    }
    journal_sync(opts_journal, history)

    reader_pid = Reader.start()
    print("")
    opts_with_reader = map_put(opts_journal, 'reader_pid', reader_pid)
    # Terminal title (gated by SW_NO_TITLE) + the enriched footer BEFORE the
    # first prompt, so cwd/branch/mode show from turn zero instead of only
    # after the first user turn (Wave-4 item 4/8).
    UI.set_title_cwd(to_string(map_get(opts_with_reader, 'cwd')))
    if (reader_pid != nil) {
        draw_footer(history, opts_with_reader)
        send(reader_pid, {'draw_and_read'})
    }
    main_loop(history, opts_with_reader)
}

# ------------------------------------------------------------
# Headless entry — `swarm -p "<prompt>"`.
# ------------------------------------------------------------
fun run_headless(opts, system_prompt_text, prompt, json_mode) {
    register('main_agent', self())

    jdir = session_dir()
    file_mkdir(jdir)
    ap = journal_active_ptr()
    # --no-resume (or SWARM_CODE_NO_RESUME=1): skip the journal-replay path
    # entirely. Used by parallel headless agents that would otherwise all
    # race on the same .active pointer and trigger compaction storms.
    no_resume = if (map_get(opts, 'no_resume') == 'true') { 'true' }
                else { if (getenv("SWARM_CODE_NO_RESUME") == "1") { 'true' }
                else { 'false' }}
    prev_ptr = if (no_resume == 'true') { nil }
               else { if (file_exists(ap) == 'true') { file_read(ap) } else { nil }}
    resumed_raw = if (prev_ptr == nil) { [] }
                  else {
                      prev_path = string_trim(prev_ptr)
                      if (string_length(prev_path) > 0 && file_exists(prev_path) == 'true') {
                          replay_journal(prev_path)
                      } else { [] }
                  }
    resumed = trim_incomplete(resumed_raw)

    journal_path = if (length(resumed) > 0) {
        string_trim(prev_ptr)
    } else {
        jp_new = jdir ++ "/journal-" ++ to_string(timestamp()) ++ ".jsonl"
        file_write(jp_new, "")
        jp_new
    }
    # Only update .active when this session is resumable. With --no-resume
    # we're explicitly ephemeral (cron child, headless one-shot); writing
    # our path to .active would mean the next interactive launch resumes
    # US, polluting future sessions. This was the swarm-bomb root cause.
    if (no_resume == 'false') { file_write(ap, journal_path) }
    else { 'skip_active_pointer' }
    opts_journal = map_put(opts, 'journal_path', journal_path)

    history = if (length(resumed) > 0) {
        prepend([LLM.new_message_system(system_prompt_text)], resumed)
    } else {
        [LLM.new_message_system(system_prompt_text)]
    }
    journal_sync(opts_journal, history)

    # Auto-accept permissions in headless.
    opts_h = map_put(opts_journal, 'headless', 'true')

    final_history = route_input(prompt, history, opts_h)
    journal_sync(opts_h, final_history)

    last_text = last_assistant_text(final_history)
    ok = if (string_length(last_text) > 0) { 'true' } else { 'false' }
    if (json_mode == 'true') {
        status = if (ok == 'true') { "ok" } else { "error" }
        print(json_encode(%{status: status, summary: last_text}))
    } else { "" }
    if (ok == 'true') { "" } else { sys_exit(1) }
}

fun last_assistant_text(history) {
    last_assistant_loop(history, "")
}

fun last_assistant_loop(msgs, acc) {
    if (length(msgs) == 0) { acc }
    else {
        msg = hd(msgs)
        role = map_get(msg, 'role')
        na = if (role == 'assistant') { to_string(map_get(msg, 'content')) } else { acc }
        last_assistant_loop(tl(msgs), na)
    }
}

# ------------------------------------------------------------
# The continuous loop.
# ------------------------------------------------------------
fun main_loop(history, opts) {
    next_state = receive {
        {'user_input', line} ->
            handle_user_input_msg(line, history, opts)
        {'heartbeat_tick', count} ->
            on_heartbeat_tick(count, history, opts)
        {'bg_done', task_id, exit_code, label} ->
            on_bg_done(task_id, exit_code, label, history, opts)
        {'bg_stalled', task_id, label, tail} ->
            on_bg_stalled(task_id, label, tail, history, opts)
        {'eof'} ->
            handle_eof(history, opts)
        _other ->
            history
        after 15000 {
            on_idle(history, opts)
        }
    }
    if (length(next_state) != length(history)) {
        journal_sync(opts, next_state)
    }
    main_loop(next_state, opts)
}

fun handle_user_input_msg(line, history, opts) {
    Log.user_input(line)
    # Per-turn terminal title suffix (gated by SW_NO_TITLE) + enriched footer
    # (model · cwd (branch) · [mode chip] · tokens) above the prompt.
    UI.set_title_turn(to_string(map_get(opts, 'cwd')), line)
    draw_footer(history, opts)
    post_input_history = route_input(line, history, opts)
    print("")
    reader_pid = map_get(opts, 'reader_pid')
    if (reader_pid != nil) {
        send(reader_pid, {'draw_and_read'})
    }
    post_input_history
}

fun route_input(line, history, opts) {
    trimmed = string_trim(line)
    if (string_length(trimmed) == 0) { history }
    else {
        if (trimmed == "/quit") { handle_eof(history, opts) }
        else { if (trimmed == "/exit") { handle_eof(history, opts) }
        else { if (trimmed == "/reset") {
            print("\e[2m[history reset]\e[0m")
            [hd(history)]
        }
        # Only dispatch as a slash command if the first token matches a
        # known command — that way pasted Unix paths like /Users/sky/foo.png
        # or /tmp/bar fall through to the chat path instead of getting
        # rejected as "unknown command".
        else { if (string_starts_with(trimmed, "/") == 'true' &&
                   is_known_slash_command(first_token(trimmed)) == 'true') {
            slash_dispatch(trimmed, history, opts)
        }
        # A command-shaped leading slash — /[a-z_-]+ only, no further slash,
        # dot, or uppercase — that ISN'T a known command is a typo, not chat.
        # Tell the user instead of quietly sending "/halp" to the LLM.
        # Filesystem paths (/Users/…, /tmp/x, ./a.png) fail the command-shape
        # test (they contain "/", ".", or uppercase after the first char) and
        # fall through to the chat path unchanged. Returning history with no
        # LLM turn; handle_user_input_msg redraws the prompt afterwards.
        # Extra guard: bare all-lowercase top-level paths (/tmp, /etc, /usr,
        # /var, /opt, /bin, /srv …) are command-shaped too — "/tmp got full"
        # must reach the LLM, not die as "unknown command: /tmp". Anything
        # that exists on disk is a path, not a typo'd command.
        else { if (looks_like_slash_command(first_token(trimmed)) == 'true' &&
                   file_exists(first_token(trimmed)) != 'true') {
            print(UI.warn_text("unknown command: " ++ first_token(trimmed)) ++
                  " \e[2m— type /help\e[0m")
            history
        }
        else {
            Config.run_hooks("UserPromptSubmit", 'user', line, opts)
            # Reset per-turn guardrail counters — fresh user message
            # = fresh budget for loops, no-progress, and failure streaks.
            ToolGuardrails.reset(opts)
            # Auto-detect image paths in the user's message and queue
            # them for attachment before sending. Mirrors claude-code's
            # drag-drop / path-paste pattern — no read_image call needed.
            attached = Vision.auto_attach(opts, line)
            print_attachment_summary(attached)
            # Plan mode: optionally generate and confirm a step-by-step plan
            # before calling the LLM with tools. Delegated to plan_gate/3
            # which returns either a ready history (user msg + plan injected)
            # or the sentinel atom 'cancelled' when the user declines.
            gated = plan_gate(line, history, opts)
            if (gated == 'cancelled') {
                history
            } else {
                # Compaction is TOKEN-threshold-based and handled inside run_turn
                # (the F3a budget gate at step 0 = this turn's pre-flight check),
                # matching claude-code: history grows verbatim until it nears the
                # context budget, then ONE compaction fires. We deliberately do
                # NOT compact on a message COUNT here — at a 193k-token budget,
                # 120 messages is only ~30k tokens, so a count trigger summarized
                # at ~16% of the real limit and fired every ~60 tool calls
                # ("compacting on every turn"). Token-gated = compact rarely, late.
                run_turn(gated, opts, 0)
            }
        }}}}}
    }
}

# Plan gate — generates, displays, and confirms a plan before execution.
# Returns the ready history (user message + plan assistant msg appended)
# or the atom 'cancelled' when the user declines.
# Uses Plan.is_active/2 to decide whether to trigger.
fun plan_gate(line, history, opts) {
    # Add the user message to history first — plan confirmation comes after.
    with_user = list_append(history, LLM.new_message_user(line))
    headless = map_get(opts, 'headless')
    is_sub = map_get(opts, 'is_subagent')
    # Never run plan mode in headless or subagent contexts.
    active = if (headless == 'true' || is_sub == 'true') { 'false' }
             else { Plan.is_active(line, opts) }
    if (active != 'true') {
        with_user
    } else {
        print("\e[2m[plan: generating…]\e[0m")
        plan_text = Plan.generate(line, history, opts)
        if (plan_text == nil) {
            print("\e[2m[plan: skipped — no plan generated]\e[0m")
            with_user
        } else {
            Plan.display(plan_text)
            confirm_result = Plan.confirm(opts)
            if (confirm_result == 'no') {
                'cancelled'
            } else {
                revised = if (confirm_result == 'yes') { plan_text }
                          else { elem(confirm_result, 1) }
                Plan.inject_into_history(with_user, revised, line)
            }
        }
    }
}

# Heartbeat tick handler — silent unless daemon mode.
fun pulse_interval() { 30 }

fun on_heartbeat_tick(count, history, opts) {
    # Every tick, give the scheduler a chance to dispatch any due
    # recurring jobs. Cheap — it's a JSON read + a few timestamp
    # comparisons unless something is due. Fire-and-forget, no
    # blocking, output goes to telemetry/ files.
    Scheduler.tick(opts)

    daemon = map_get(opts, 'daemon')
    if (daemon != 'true') { history }
    else {
        interval = pulse_interval()
        remainder = count - ((count / interval) * interval)
        if (remainder != 0) { history }
        else {
            in_wake = map_get(opts, 'in_wake_chain')
            if (in_wake == 'true') { history }
            else { cognitive_pulse(count, history, opts) }
        }
    }
}

fun cognitive_pulse(tick_count, history, opts) {
    bg_table = map_get(opts, 'bg_table')
    pending_bg = if (bg_table == nil) { "none" }
                 else { Background.list_all(bg_table) }
    hb_table = map_get(opts, 'heartbeat_table')
    uptime = if (hb_table == nil) { "?" }
             else { to_string((timestamp() - ets_get(hb_table, 'start_ms')) / 1000) ++ "s" }

    pulse_msg =
        "<daemon_pulse tick=\"" ++ to_string(tick_count) ++ "\" uptime=\"" ++ uptime ++ "\">\n" ++
        "Background tasks: " ++ to_string(pending_bg) ++ "\n" ++
        "Pending todos: " ++ Tools.todo_read_json(opts) ++ "\n" ++
        "</daemon_pulse>\n\n" ++
        "This is an autonomous daemon pulse, NOT a user message. " ++
        "Assess whether any action is needed based on the state above " ++
        "and the conversation history. Options:\n" ++
        "1. If nothing needs attention, respond with just: idle\n" ++
        "2. If a background task needs follow-up, act on it.\n" ++
        "3. If you notice something worth proactively doing (a pending " ++
        "todo, a file to check, a test to run), do it.\n" ++
        "Keep any output VERY brief (1 sentence). Do NOT start major " ++
        "work without user approval."

    pulse_msgs = list_append(history, LLM.new_message_user(pulse_msg))
    wake_opts0 = map_put(opts, 'in_wake_chain', 'true')
    # 'wake_turn': the pulse fires while the Reader is pinned in
    # read_line — any streaming/diag output must go above the prompt
    # (chat_silent itself is non-streaming, but tools the pulse fires
    # inherit these opts).
    wake_opts = map_put(wake_opts0, 'wake_turn', 'true')
    response = LLM.chat_silent(pulse_msgs, wake_opts)

    if (response == nil) { history }
    else {
        trimmed = string_trim(to_string(response))
        lower = string_lower(trimmed)
        is_idle = if (lower == "idle") { 'true' }
                  else { if (lower == "idle.") { 'true' }
                  else { 'false' }}
        if (is_idle == 'true') { history }
        else {
            # print_above throughout — the Reader is pinned in read_line
            # and plain prints would land on top of the prompt.
            print_above("")
            print_above("\e[2m[daemon pulse — acting autonomously]\e[0m")
            with_pulse = list_append(history, LLM.new_message_user(pulse_msg))
            # chat_silent returns a string; pulse may have emitted inband
            # tool markers. Parse them once via LLM.parse_inband_tool_calls.
            parsed = LLM.parse_inband_tool_calls(trimmed)
            pulse_prose = to_string(map_get(parsed, 'content'))
            pulse_tcs = map_get(parsed, 'tool_calls')
            with_response = list_append(with_pulse,
                LLM.new_message_assistant(pulse_prose, pulse_tcs, nil))
            if (length(pulse_tcs) == 0) {
                print_above("  " ++ UI.grey_text() ++ pulse_prose ++ UI.reset())
                print_above("")
                with_response
            } else {
                post_pulse = execute_all(pulse_tcs, with_response, wake_opts)
                # In-place prompt redraw after the pulse's tool output.
                print_above("")
                post_pulse
            }
        }
    }
}

# Background task completion handler.
fun on_bg_done(task_id, exit_code, label, history, opts) {
    Log.bg_done(task_id, exit_code, label)
    color = if (exit_code == 0) { UI.brand_color() } else { UI.err_color() }
    print_above("")
    print_above(color ++ "⏺" ++ UI.reset() ++ " \e[1mbg_done\e[0m " ++ task_id ++
          "  \e[2mexit " ++ to_string(exit_code) ++ " · " ++ label ++ "\e[0m")
    print_above("")

    autonomy = map_get(opts, 'autonomy')
    in_wake = map_get(opts, 'in_wake_chain')
    if (autonomy == 'true' && in_wake != 'true') {
        bg_table = map_get(opts, 'bg_table')
        preview = if (bg_table == nil) { "(no log)" }
                  else {
                      tail = Background.tail_log(bg_table, task_id, 15)
                      if (string_length(tail) > 800) {
                          string_sub(tail, 0, 800) ++ "... (truncated)"
                      } else { tail }
                  }
        wake_msg =
            "<wake_event source=\"bg_done\">\n" ++
            "Task " ++ task_id ++ " (" ++ label ++ ") finished with exit " ++
            to_string(exit_code) ++ ".\n" ++
            "Log tail:\n" ++ preview ++ "\n" ++
            "</wake_event>\n\n" ++
            "This is an autonomous wake-up, NOT a user message. Briefly (1-2 " ++
            "sentences max) acknowledge what happened. If the output implies " ++
            "an obvious next step, suggest it or call the right tool. If " ++
            "there's nothing to do, just say something short like \"ok, done.\" " ++
            "Do NOT start new long-running work without user approval."

        print_above("\e[2m[autonomy: reacting to bg_done...]\e[0m")
        with_wake = list_append(history, LLM.new_message_user(wake_msg))
        wake_opts0 = map_put(opts, 'in_wake_chain', 'true')
        # Wake turns run while the Reader is pinned in read_line.
        # 'wake_turn' makes llm.sw stream silently (self-routed 5-arg
        # call, nothing painted mid-stream) and emit the final rendered
        # output via print_above — so the turn never scribbles over the
        # pinned prompt (autonomy/stream collision fix, Wave-1A).
        wake_opts = map_put(wake_opts0, 'wake_turn', 'true')
        post_wake = run_turn(with_wake, wake_opts, 0)
        # Clean prompt redraw under anything the turn printed. NOT a
        # {'draw_and_read'} re-send: the reader never left read_line —
        # a queued draw_and_read would fire a spurious second prompt +
        # read after the user submits the current line. print_above("")
        # wipes and redraws the live input line in place instead.
        print_above("")
        post_wake
    } else {
        # print_above like the sibling header lines: the Reader is pinned in
        # read_line, a plain print here landed on the live input line.
        print_above("  " ++ UI.grey_border() ++ "⎿" ++ UI.reset() ++ "  " ++
              UI.dim_text("/bg tail " ++ task_id ++ " to see output"))
        print_above("")
        history
    }
}

# Background task stall handler — a still-pending task whose log hasn't
# grown for 45s and whose tail looks like an interactive prompt (it will
# hang forever on /dev/null stdin). Mirrors on_bg_done's structure but
# with a warning tint and a bg_stalled wake_event.
fun on_bg_stalled(task_id, label, tail, history, opts) {
    Log.bg_stalled(task_id, label, tail)
    print_above("")
    print_above(UI.warn_color() ++ "⏺" ++ UI.reset() ++ " \e[1mbg_stalled\e[0m " ++ task_id ++
          "  \e[2m(" ++ label ++ ") — no output for 45s; tail looks interactive\e[0m")
    print_above("  \e[2m/bg tail " ++ task_id ++ "  ·  /bg kill " ++ task_id ++ "\e[0m")
    print_above("")

    autonomy = map_get(opts, 'autonomy')
    in_wake = map_get(opts, 'in_wake_chain')
    if (autonomy == 'true' && in_wake != 'true') {
        wake_msg =
            "<wake_event source=\"bg_stalled\">\n" ++
            "Task " ++ task_id ++ " (" ++ label ++ ") has produced no output for " ++
            "45s and its log tail looks like an interactive prompt.\n" ++
            "Log tail:\n" ++ tail ++ "\n" ++
            "</wake_event>\n\n" ++
            "This background task may be waiting for interactive input. If the " ++
            "tail shows a prompt you can answer non-interactively, kill it with " ++
            "bg_kill and re-run the command with non-interactive flags (-y, " ++
            "--yes, </dev/null, DEBIAN_FRONTEND=noninteractive, etc.). If it is " ++
            "legitimately slow (compiles, downloads), leave it running."

        print_above("\e[2m[autonomy: reacting to bg_stalled...]\e[0m")
        with_wake = list_append(history, LLM.new_message_user(wake_msg))
        wake_opts0 = map_put(opts, 'in_wake_chain', 'true')
        # Same wake-turn discipline as on_bg_done — silent stream +
        # print_above render, then an in-place prompt redraw.
        wake_opts = map_put(wake_opts0, 'wake_turn', 'true')
        post_wake = run_turn(with_wake, wake_opts, 0)
        print_above("")
        post_wake
    } else {
        history
    }
}

# EOF / /quit handler.
fun handle_eof(history, opts) {
    Log.session_end("user_exit")
    Config.run_hooks("Stop", 'session', "{}", opts)
    Mcp.shutdown(map_get(opts, 'mcp_table'))
    journal_clean(opts)
    sys_exit(0)
    history
}

fun on_idle(history, opts) { history }

# Slash-command dispatch.
fun slash_dispatch(cmd, history, opts) {
    if (cmd == "/help") { show_help() ; history }
    else { if (cmd == "/tools") {
        print("available: bash, read, write, edit, multi_edit, glob, grep, todo_write, web_fetch, task, remember, recall, background, bg_status, bg_result, bg_server, bg_tail, bg_kill, sys_stats, heartbeat_status")
        print("browser: browser_launch, browser_navigate, browser_click, browser_type, browser_screenshot, browser_get_text, browser_get_html, browser_evaluate, browser_close")
        print(UI.grey_text() ++ "MCP tools (if any) are listed by /mcp" ++ UI.reset())
        history
    }
    else { if (cmd == "/status") { show_status(history, opts) ; history }
    else { if (cmd == "/clear") { print_inline("\e[2J\e[H") ; history }
    else { if (cmd == "/history") { show_history(history) ; history }
    else { if (cmd == "/tokens") {
        tok_count = approx_tokens(history)
        print("approx tokens in history: " ++ to_string(tok_count))
        history
    }
    else { if (cmd == "/model") { show_model_info(opts) ; history }
    else { if (string_starts_with(cmd, "/model ") == 'true') {
        new_model = string_trim(string_sub(cmd, 7, string_length(cmd) - 7))
        apply_model_override(new_model)
        history
    }
    else { if (cmd == "/profile") { show_active_profile() ; history }
    else { if (cmd == "/profiles") { list_profiles() ; history }
    else { if (string_starts_with(cmd, "/profile ") == 'true') {
        name = string_trim(string_sub(cmd, 9, string_length(cmd) - 9))
        apply_profile_override(name)
        history
    }
    else { if (cmd == "/profile-clear" || cmd == "/profile clear") {
        clear_profile_override()
        history
    }
    else { if (cmd == "/plan") { Plan.show_mode(opts) ; history }
    else { if (string_starts_with(cmd, "/plan ") == 'true') {
        plan_arg = string_trim(string_sub(cmd, 6, string_length(cmd) - 6))
        if (plan_arg == "on" || plan_arg == "off" || plan_arg == "auto") {
            p = Plan.plan_mode_override_path()
            if (p != nil) { file_write(p, plan_arg) }
            # Keep the /mode chip + resolve_permission in sync with the
            # override file: "/plan on" lights the plan chip; leaving via
            # "/plan off|auto" clears it (only if plan was the active mode —
            # never stomp auto-accept-edits).
            if (plan_arg == "on") { set_session_mode(opts, "plan") }
            else { if (get_session_mode(opts) == "plan") {
                set_session_mode(opts, "default")
            } else { 'ok' }}
            print(UI.brand_color() ++ "✓ plan mode set to " ++ plan_arg ++ UI.reset())
            print(UI.grey_text() ++ "  takes effect on next request. " ++
                  "Use /plan to check." ++ UI.reset())
        } else {
            print(UI.warn_text("usage: /plan [on | off | auto]"))
        }
        history
    }
    else { if (string_starts_with(cmd, "/search ") == 'true') {
        query = string_trim(string_sub(cmd, 8, string_length(cmd) - 8))
        if (string_length(query) == 0) {
            print(UI.warn_text("usage: /search QUERY"))
        } else {
            print(SessionSearch.search_render(query, 10))
        }
        history
    }
    else { if (cmd == "/schedules") {
        show_schedules()
        history
    }
    else { if (string_starts_with(cmd, "/schedule ") == 'true') {
        # /schedule "EXPR" "PROMPT"  — quoted args required
        rest = string_trim(string_sub(cmd, 10, string_length(cmd) - 10))
        parsed = parse_schedule_args(rest)
        if (parsed == nil) {
            print(UI.warn_text("usage: /schedule \"EXPR\" \"PROMPT\"  " ++
                  "(EXPR is 30s/5m/2h/1d or 'hourly'/'daily HH:MM')"))
        } else {
            expr = hd(parsed)
            prompt = hd(tl(parsed))
            id = Scheduler.add(expr, prompt)
            if (id == nil) {
                print(UI.warn_text("invalid EXPR — try 30s, 5m, 2h, 1d, hourly, daily 09:00"))
            } else {
                print(UI.brand_color() ++ "✓ scheduled job " ++ id ++
                      " (" ++ expr ++ "): " ++ prompt ++ UI.reset())
            }
        }
        history
    }
    else { if (string_starts_with(cmd, "/unschedule ") == 'true') {
        id = string_trim(string_sub(cmd, 12, string_length(cmd) - 12))
        if (Scheduler.remove(id) == 'true') {
            print("\e[2m✓ unscheduled " ++ id ++ "\e[0m")
        } else {
            print(UI.warn_text("no job with id " ++ id))
        }
        history
    }
    else { if (cmd == "/export-trajectory" || cmd == "/export-trajectories" ||
              string_starts_with(cmd, "/export-trajectory ") == 'true' ||
              string_starts_with(cmd, "/export-trajectories ") == 'true') {
        # Optional --current flag exports just this session.
        # Optional path arg overrides the default ~/.swarm-code/exports/...
        rest = string_trim(if (string_starts_with(cmd, "/export-trajectories ") == 'true') {
            string_sub(cmd, 21, string_length(cmd) - 21)
        } else { if (string_starts_with(cmd, "/export-trajectory ") == 'true') {
            string_sub(cmd, 19, string_length(cmd) - 19)
        } else { "" }})
        current_only = string_contains(rest, "--current") == 'true'
        path_arg = string_trim(string_replace(rest, "--current", ""))
        out_path = if (string_length(path_arg) == 0) { Trajectory.default_path() }
                   else { path_arg }
        result = if (current_only == 'true') {
            Trajectory.export_current(out_path, history)
        } else { Trajectory.export_all(out_path) }
        kept = map_get(result, 'kept')
        actual_path = map_get(result, 'path')
        print(UI.brand_color() ++ "✓ exported " ++ to_string(kept) ++
              " session(s) → " ++ to_string(actual_path) ++ UI.reset())
        history
    }
    else { if (cmd == "/paste" || string_starts_with(cmd, "/paste ") == 'true') {
        # Grab the clipboard image (osascript on macOS, xclip on linux),
        # attach via Vision.attach, then send the trailing prose (if any)
        # as the user message so the image rides the next request.
        prose = if (cmd == "/paste") { "what's in this?" }
                else { string_trim(string_sub(cmd, 7, string_length(cmd) - 7)) }
        msg = if (string_length(prose) == 0) { "what's in this?" } else { prose }
        tmp = Vision.paste_from_clipboard(opts)
        if (tmp == nil) {
            print(UI.warn_text("(clipboard has no image — copy a screenshot first)"))
            history
        } else {
            print(UI.grey_text() ++ "  📎 attached: " ++ tmp ++ UI.reset())
            new_hist = list_append(history, LLM.new_message_user(msg))
            run_turn(new_hist, opts, 0)
        }
    }
    else { if (cmd == "/compact") {
        compacted = compact_history(history, opts)
        print("\e[2m[history compacted: " ++ to_string(length(history)) ++
              " → " ++ to_string(length(compacted)) ++ " messages]\e[0m")
        compacted
    }
    else { if (cmd == "/save") {
        path = save_session(history, opts)
        print("\e[2m[session saved to " ++ path ++ "]\e[0m")
        history
    }
    else { if (cmd == "/resume") {
        restored = load_latest_session(opts)
        if (length(restored) == 0) {
            print(UI.warn_text("no session to resume"))
            history
        } else {
            print("\e[2m[resumed " ++ to_string(length(restored)) ++ " messages]\e[0m")
            restored
        }
    }
    else { if (cmd == "/sessions") { list_sessions() ; history }
    else { if (cmd == "/todos") {
        todos = Tools.todo_read(opts)
        if (todos == nil) {
            print(UI.grey_text() ++ "  (no tasks yet — the model creates them with todo_write)" ++ UI.reset())
        } else {
            print("")
            print(UI.todo_list_render(todos))
            print("")
        }
        history
    }
    else { if (cmd == "/cost") {
        approx = approx_tokens(history)
        print("messages: " ++ to_string(length(history)))
        print("approx tokens: " ++ to_string(approx))
        print("cost: $0.00  (local inference on sushi)")
        history
    }
    else { if (cmd == "/telemetry") { print(Log.tail_recent(30)) ; history }
    else { if (cmd == "/stats") { print(Log.summarize()) ; history }
    else { if (cmd == "/autonomy") {
        cur = map_get(opts, 'autonomy')
        if (cur == 'true') {
            print("autonomy is ON — swarm-code wakes the LLM on bg_done events")
        } else {
            print("autonomy is OFF — bg_done events are silent")
        }
        history
    }
    else { if (cmd == "/daemon") {
        daemon_cur = map_get(opts, 'daemon')
        if (daemon_cur == 'true') {
            print(UI.brand_color() ++ "daemon mode is ON" ++ UI.reset() ++
                  " — cognitive pulse every ~" ++ to_string(pulse_interval() * 2) ++ "s")
            print(UI.grey_text() ++ "  the model self-prompts periodically to check for work" ++ UI.reset())
            print(UI.grey_text() ++ "  toggle off: set SWARM_CODE_DAEMON=0" ++ UI.reset())
        } else {
            print("daemon mode is OFF — heartbeat ticks silently")
            print(UI.grey_text() ++ "  enable: set SWARM_CODE_DAEMON=1 before launch" ++ UI.reset())
        }
        history
    }
    else { if (cmd == "/reflect") {
        print("\e[2m[reflecting — this is a separate LLM call, will take a moment]\e[0m")
        reflect_msg =
            "REFLECTION REQUEST: Review the conversation so far. " ++
            "Briefly summarize: (1) what we've done, (2) what's still open, " ++
            "(3) one or two concrete next steps you'd suggest. Be terse. " ++
            "This is a self-review — no tool calls, just prose."
        with_reflect = list_append(history, LLM.new_message_user(reflect_msg))
        run_turn(with_reflect, opts, 0)
    }
    else { if (cmd == "/mcp") { print(Mcp.list_servers(map_get(opts, 'mcp_table'))) ; history }
    else { if (cmd == "/mcp reconnect") {
        Mcp.reconnect(map_get(opts, 'mcp_table'), 'all', map_get(opts, 'settings'))
        history
    }
    else { if (string_starts_with(cmd, "/mcp reconnect ") == 'true') {
        server_name = string_trim(string_sub(cmd, 15, string_length(cmd) - 15))
        Mcp.reconnect(map_get(opts, 'mcp_table'), server_name, map_get(opts, 'settings'))
        history
    }
    else { if (cmd == "/memory reindex") {
        ep = map_get(opts, 'embed_endpoint', nil)
        if (ep == nil) {
            print(UI.warn_text("reindex requires SWARM_CODE_EMBED_ENDPOINT to be configured"))
        } else {
            print("\e[2mreindexing memories...\e[0m")
            result = Memory.embed_missing(opts)
            print(to_string(result))
        }
        history
    }
    else { if (cmd == "/debug") { show_debug(history, opts) ; history }
    else { if (cmd == "/debug llm") { show_debug_llm() ; history }
    else { if (cmd == "/debug tools") { show_debug_tools() ; history }
    else { if (first_token(cmd) == "/bg") {
        handle_bg_command(cmd, opts)
        history
    }
    else { if (cmd == "/mode") {
        nxt = cycle_mode(opts)
        print(UI.brand_color() ++ "✓ mode: " ++ nxt ++ UI.reset())
        print(UI.grey_text() ++ "  default → auto-accept-edits → plan  (/mode to cycle)" ++ UI.reset())
        history
    }
    else { if (cmd == "/expand") {
        show_expand(opts)
        history
    }
    else { if (first_token(cmd) == "/flows") {
        path = string_sub(cmd, 7, string_length(cmd) - 7)
        if (string_length(path) == 0) {
            print(UI.warn_text("usage: /flows <workflow-definition.json>"))
            history
        } else {
            Flows.run_flows(string_trim(path), opts)
            history
        }
    }
    else {
        print(UI.warn_text("unknown command: " ++ cmd) ++ "  (type /help)")
        history
    }}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}
}

# /expand — reprint the most recent tool result in full (uncapped),
# through the normal ⎿-gutter result renderer. The full output was
# stashed in the expand_table ETS at render time (execute_all).
fun show_expand(opts) {
    et = map_get(opts, 'expand_table')
    stored = if (et == nil) { nil } else { ets_get(et, 'last_tool_output') }
    if (stored == nil) {
        print(UI.grey_text() ++ "  (nothing to expand — no tool output yet)" ++ UI.reset())
    } else {
        print("")
        UI.tool_result_full(to_string(stored))
    }
    'ok'
}

fun show_help() {
    print("\e[1mcommands\e[0m")
    print("  /help                 show this help")
    print("  /status               session info")
    print("  /tools                list available tools")
    print("  /todos                show todo list")
    print("  /mcp                  list MCP servers and their tools")
    print("  /mcp reconnect [NAME] reconnect all (or one) MCP server(s)")
    print("  /plan                 show plan mode (on/off/auto)")
    print("  /plan on|off|auto     set plan mode for this session")
    print("  /model                show active model")
    print("  /model NAME           swap model name for this session")
    print("  /profile              show active profile override (if any)")
    print("  /profiles             list profiles in settings.json")
    print("  /profile NAME         swap to a profile from settings.json")
    print("  /profile-clear        drop the override, revert to launch profile")
    print("  /search QUERY         FTS5 search across all session journals")
    print("  /paste [prompt]       attach clipboard image (Cmd+V from a screenshot)")
    print("  /schedule \"EXPR\" \"PROMPT\"  schedule a recurring agent run")
    print("  /schedules            list scheduled jobs")
    print("  /unschedule ID        remove a scheduled job")
    print("  /export-trajectory [--current] [path]  dump sessions as fine-tuning JSONL")
    print("  /history              print recent messages")
    print("  /tokens               approximate token count")
    print("  /cost                 session cost (local = $0)")
    print("  /telemetry            last 30 events (LLM, tools, errors)")
    print("  /stats                today's session summary")
    print("  /flows <workflow.json>  run a multi-agent workflow with live TUI")
    print("  /bg [tail|kill] [id]  list / tail / kill background tasks")
    print("  /expand               reprint the last tool result in full")
    print("  /mode                 cycle permission mode (default → auto-accept-edits → plan)")
    print("  /clear                clear screen")
    print("  /reset                clear conversation history")
    print("  /compact              summarize history to save context")
    print("  /save                 save current session")
    print("  /resume               resume latest saved session")
    print("  /sessions             list recent sessions")
    print("  /daemon               show daemon mode (cognitive pulse)")
    print("  /autonomy             show autonomy mode (bg_done wake)")
    print("  /reflect              trigger one-shot reflection")
    print("  /memory reindex       embed any un-vectorized memories (requires SWARM_CODE_EMBED_ENDPOINT)")
    print("  /debug                runtime diagnostics (model, tokens, bg tasks, MCP, schedules)")
    print("  /debug llm            last 3 LLM calls (model, latency, tokens)")
    print("  /debug tools          last 10 tool calls")
    print("  /quit /exit           exit")
}

fun show_status(history, opts) {
    print("\e[1mswarm-code status\e[0m")
    print("  model    : " ++ to_string(map_get(opts, 'model')))
    print("  endpoint : " ++ to_string(map_get(opts, 'endpoint')))
    print("  cwd      : " ++ to_string(map_get(opts, 'cwd')))
    print("  plan     : " ++ Plan.get_mode(opts))
    print("  messages : " ++ to_string(length(history)))
    print("  ~tokens  : " ++ to_string(approx_tokens(history)))
}

# Truncate string for inline preview.
fun preview_string(s, cap) {
    if (string_length(s) <= cap) { s }
    else { string_sub(s, 0, cap) ++ " ..." }
}

# String → atom for tool dispatch. Walks ToolRegistry; unknown names
# pass through as strings (MCP tools use mcp__* prefix, resolve in tools.sw).
fun string_to_atom(s) {
    ToolRegistry.atom_for(s)
}

fun show_debug(history, opts) {
    print("\e[1mdebug\e[0m")
    print("  model    : " ++ to_string(map_get(opts, 'model')))
    print("  endpoint : " ++ to_string(map_get(opts, 'endpoint')))
    print("  messages : " ++ to_string(length(history)))
    print("  ~tokens  : " ++ to_string(approx_tokens(history)))
    bg_table = map_get(opts, 'bg_table')
    bg_count = if (bg_table == nil) { "0" }
               else {
                   raw = ets_get(bg_table, 'next_id')
                   if (raw == nil) { "0" } else { to_string(raw) }
               }
    print("  bg tasks : " ++ bg_count)
    sched_jobs = Scheduler.list_all()
    print("  schedules: " ++ to_string(length(sched_jobs)))
    mcp_table = map_get(opts, 'mcp_table')
    mcp_info = if (mcp_table == nil) { "none" } else { Mcp.list_servers(mcp_table) }
    print("  mcp      :")
    print(mcp_info)
    print(UI.grey_text() ++ "  /debug llm   â last 3 LLM calls" ++ UI.reset())
    print(UI.grey_text() ++ "  /debug tools â last 10 tool calls" ++ UI.reset())
}

fun show_debug_llm() {
    p = Log.path()
    if (file_exists(p) == 'false') {
        print("(no telemetry log yet)")
    } else {
        print("\e[1mlast 3 LLM calls\e[0m")
        q = Util.shell_q(p)
        cmd = "grep 'llm_request\\|llm_response\\|llm_error' " ++ q ++
              " | tail -30 | python3 -c \"" ++
              "import sys,json;" ++
              "rows=[];" ++
              "[rows.append(json.loads(l)) for l in sys.stdin if l.strip()];" ++
              "reqs=[r for r in rows if r.get('type')=='llm_request'][-3:];" ++
              "resps=[r for r in rows if r.get('type')=='llm_response'][-3:];" ++
              "errs=[r for r in rows if r.get('type')=='llm_error'][-1:];" ++
              "[print('  req  model=' + str(r.get('model','?')) + ' msgs=' + str(r.get('msgs','?')) + ' chars=' + str(r.get('chars','?'))) for r in reqs];" ++
              "[print('  resp latency=' + str(r.get('latency_ms','?')) + 'ms chars=' + str(r.get('chars','?')) + ' tools=' + str(r.get('had_tools','?'))) for r in resps];" ++
              "[print('  ERR  reason=' + str(r.get('reason','?'))) for r in errs]" ++
              "\""
        r = shell_managed(cmd ++ " 2>&1", 10000)
        out = elem(r, 1)
        if (string_length(string_trim(out)) == 0) {
            print("  (no LLM calls recorded yet)")
        } else {
            print(out)
        }
    }
}

fun show_debug_tools() {
    p = Log.path()
    if (file_exists(p) == 'false') {
        print("(no telemetry log yet)")
    } else {
        print("\e[1mlast 10 tool calls\e[0m")
        q = Util.shell_q(p)
        cmd = "grep 'tool_call' " ++ q ++
              " | tail -10 | python3 -c \"" ++
              "import sys,json;" ++
              "rows=[];" ++
              "[rows.append(json.loads(l)) for l in sys.stdin if l.strip()];" ++
              "calls=[r for r in rows if r.get('type')=='tool_call'];" ++
              "[print('  ' + str(r.get('name','?')) + '  ' + str(r.get('args',''))[:60]) for r in calls]" ++
              "\""
        r = shell_managed(cmd ++ " 2>&1", 10000)
        out = elem(r, 1)
        if (string_length(string_trim(out)) == 0) {
            print("  (no tool calls recorded yet)")
        } else {
            print(out)
        }
    }
}

# ------------------------------------------------------------
# Profile / model swap — writes ~/.swarm-code/.profile_override which
# LLM.apply_override consults before every request. No opts threading
# required; the change takes effect on the next LLM call.
# ------------------------------------------------------------
fun profile_override_path() {
    getenv("HOME") ++ "/.swarm-code/.profile_override"
}

fun apply_profile_override(name) {
    if (string_length(name) == 0) {
        print(UI.warn_text("usage: /profile NAME  (try /profiles to list)"))
    }
    else {
        settings = Config.load()
        profiles = if (settings == nil) { nil } else { map_get(settings, 'profiles') }
        if (profiles == nil) {
            print(UI.warn_text("no 'profiles' map in ~/.swarm-code/settings.json"))
        }
        else {
            p = lookup_profile(profiles, name)
            if (p == nil) {
                print(UI.warn_text("no profile named '" ++ name ++ "' — try /profiles"))
            }
            else {
                ov = profile_to_override(p)
                file_write(profile_override_path(), json_encode(ov))
                print(UI.brand_color() ++ "✓ profile swapped to " ++ name ++ UI.reset())
                print(UI.grey_text() ++ "  model    : " ++ to_string(map_get(ov, 'model')) ++ UI.reset())
                print(UI.grey_text() ++ "  endpoint : " ++ to_string(map_get(ov, 'endpoint')) ++ UI.reset())
                print(UI.grey_text() ++ "  takes effect on next LLM call. /profile-clear to revert." ++ UI.reset())
            }
        }
    }
}

fun apply_model_override(model_name) {
    if (string_length(model_name) == 0) {
        print(UI.warn_text("usage: /model NAME"))
    }
    else {
        ov = %{ model: model_name }
        file_write(profile_override_path(), json_encode(ov))
        print(UI.brand_color() ++ "✓ model swapped to " ++ model_name ++ UI.reset())
        print(UI.grey_text() ++ "  endpoint/api_key unchanged. /profile-clear to revert." ++ UI.reset())
    }
}

fun clear_profile_override() {
    p = profile_override_path()
    if (file_exists(p) == 'true') {
        shell("rm -f " ++ Util.shell_q(p))
        print("\e[2m✓ override cleared — back to launch profile\e[0m")
    } else {
        print("\e[2m(no override active)\e[0m")
    }
}

fun show_active_profile() {
    p = profile_override_path()
    if (file_exists(p) == 'false') {
        print("\e[2m(no override active — using launch profile)\e[0m")
    } else {
        raw = file_read(p)
        ov = if (raw == nil) { nil } else { json_decode(raw) }
        if (ov == nil) {
            print(UI.warn_text("(override file present but unreadable: " ++ p ++ ")"))
        } else {
            print("\e[1mactive override\e[0m")
            show_override_field(ov, 'endpoint')
            show_override_field(ov, 'model')
            show_override_field(ov, 'api_key')
            show_override_field(ov, 'tool_format')
            print(UI.grey_text() ++ "  (use /profile-clear to revert)" ++ UI.reset())
        }
    }
}

fun show_override_field(ov, key) {
    v = map_get(ov, key)
    if (v == nil) { 'skip' }
    else {
        shown = if (key == 'api_key') { "(set)" } else { to_string(v) }
        print("  " ++ to_string(key) ++ " : " ++ shown)
    }
}

fun list_profiles() {
    settings = Config.load()
    profiles = if (settings == nil) { nil } else { map_get(settings, 'profiles') }
    if (profiles == nil) {
        print("\e[2mno profiles defined in ~/.swarm-code/settings.json\e[0m")
    } else {
        keys = map_keys(profiles)
        values = map_values(profiles)
        print("\e[1mprofiles\e[0m")
        list_profiles_loop(keys, values)
        print(UI.grey_text() ++ "  use: /profile NAME" ++ UI.reset())
    }
}

fun list_profiles_loop(keys, values) {
    if (length(keys) == 0) { 'done' }
    else {
        k = hd(keys)
        v = hd(values)
        model = if (v == nil) { "?" } else {
            mv = map_get(v, 'model')
            if (mv == nil) { "?" } else { to_string(mv) }
        }
        endpoint = if (v == nil) { "?" } else {
            ev = map_get(v, 'endpoint')
            if (ev == nil) { "?" } else { to_string(ev) }
        }
        print("  " ++ to_string(k) ++ "  " ++ UI.grey_text() ++ model ++ " @ " ++ endpoint ++ UI.reset())
        list_profiles_loop(tl(keys), tl(values))
    }
}

# Map-by-string-key lookup — JSON-decoded maps carry atom keys, so
# direct map_get(map, "name") misses entries saved as 'name'.
fun lookup_profile(profiles, name) {
    direct = map_get(profiles, name)
    if (direct != nil) { direct }
    else { lookup_profile_loop(map_keys(profiles), map_values(profiles), name) }
}

fun lookup_profile_loop(keys, values, name) {
    if (length(keys) == 0) { nil }
    else {
        if (to_string(hd(keys)) == name) { hd(values) }
        else { lookup_profile_loop(tl(keys), tl(values), name) }
    }
}

# Convert a settings.json profile entry into the override-file shape.
# Only includes fields actually present in the profile — `apply_override`
# will leave unset fields alone.
fun profile_to_override(p) {
    a = profile_field(map_new(), p, 'endpoint')
    b = profile_field(a, p, 'model')
    c = profile_field(b, p, 'api_key')
    d = profile_field(c, p, 'tool_format')
    e = profile_field(d, p, 'vision')
    e
}

fun profile_field(acc, p, key) {
    v = map_get(p, key)
    if (v == nil) { acc }
    else { map_put(acc, key, to_string(v)) }
}

fun show_model_info(opts) {
    endpoint = to_string(map_get(opts, 'endpoint'))
    configured = to_string(map_get(opts, 'model'))
    max_out = to_string(map_get(opts, 'max_tokens'))
    url = endpoint ++ "/v1/models"
    resp = http_get(url, [])

    print("\e[1mmodel\e[0m")
    print("  endpoint        : " ++ endpoint)
    print("  configured model: " ++ configured)
    print("  max_tokens (out): " ++ max_out)
    print("  context budget  : " ++ to_string(context_budget_tokens()) ++ " tokens" ++
          " (SWARM_CODE_MAX_TOKENS=" ++ to_string(max_tokens_env()) ++ ")")
    print("")
    if (resp == nil) {
        print("  " ++ UI.warn_text("server /v1/models: unreachable"))
    } else {
        print("\e[1m  server /v1/models response:\e[0m")
        decoded = json_decode(resp)
        if (decoded == nil) {
            print("  (unparseable — raw below)")
            print("  " ++ preview_string(resp, 400))
        } else {
            data = map_get(decoded, 'data')
            if (data == nil || length(data) == 0) {
                print("  (no models returned)")
            } else {
                print_model_entries(data)
            }
        }
    }
    print("")
    print("\e[2m  to change: export SWARM_CODE_MODEL=... / " ++
          "SWARM_CODE_MAX_OUTPUT_TOKENS=... / SWARM_CODE_MAX_TOKENS=...\e[0m")
}

fun print_model_entries(entries) {
    if (length(entries) == 0) { 'ok' }
    else {
        e = hd(entries)
        id = to_string(map_get(e, 'id'))
        owned = map_get(e, 'owned_by')
        owned_s = if (owned == nil) { "" } else { " (" ++ to_string(owned) ++ ")" }
        print("    - " ++ id ++ owned_s)
        print_model_entries(tl(entries))
    }
}

fun show_history(history) {
    print("\e[1m-- history (" ++ to_string(length(history)) ++ " messages) --\e[0m")
    print_msgs(history, 0)
}

fun print_msgs(msgs, i) {
    if (length(msgs) == 0) { 'ok' }
    else {
        msg = hd(msgs)
        role = map_get(msg, 'role')
        content = map_get(msg, 'content')
        truncated = preview_string(to_string(content), 200)
        tcs = map_get(msg, 'tool_calls')
        tcs_suffix = if (tcs == nil) { "" }
                     else { if (length(tcs) == 0) { "" }
                     else { " " ++ UI.dim_text("[+" ++ to_string(length(tcs)) ++ " tool_calls]") }}
        print("\e[2m[" ++ to_string(i) ++ "] " ++ to_string(role) ++ ":\e[0m " ++
              truncated ++ tcs_suffix)
        print_msgs(tl(msgs), i + 1)
    }
}

# Token count for footer display — prefers server-reported prompt_tokens.
fun display_tokens(history, opts) {
    last_pt = LLM.last_prompt_tokens(opts)
    if (last_pt != nil) { last_pt }
    else { approx_tokens(history) }
}

fun approx_tokens(history) {
    history_chars(history) / 4
}

fun sum_msg_chars(msgs, acc) { history_chars_loop(msgs, acc) }

# ------------------------------------------------------------
# Compaction — summarize oldest messages, keep system + last 16.
# ------------------------------------------------------------
fun compact_history(history, opts) {
    if (length(history) < 10) { history }
    else {
        sys_msg = hd(history)
        rest = tl(history)
        keep_tail = take_last(rest, 16)
        to_summarize = drop_last(rest, 16)

        summary_prompt =
            "Summarize the conversation below to save context. Output EXACTLY " ++
            "these four sections, each 1-3 sentences:\n\n" ++
            "**Current State**: What has been accomplished so far.\n" ++
            "**Working State**: Files modified, commands run, tools used.\n" ++
            "**Key Details**: Important technical decisions, paths, names, configs.\n" ++
            "**Pending**: What still needs to be done, open questions.\n\n" ++
            "Be dense and precise. Preserve exact file paths, function names, " ++
            "and error messages — they are needed for continuity. Under 500 words total.\n\n" ++
            format_for_summary(to_summarize, "")

        ask_msgs = [
            LLM.new_message_system("You are a concise summarizer."),
            LLM.new_message_user(summary_prompt)
        ]
        summary = LLM.chat_silent(ask_msgs, opts)
        summary_text = if (summary == nil) {
            "[compaction failed, messages elided]"
        } else { to_string(summary) }

        synth = LLM.new_message_assistant(
            "Summary of earlier conversation: " ++ summary_text,
            nil, nil)

        prepend([sys_msg, synth], keep_tail)
    }
}

fun take_last(lst, n) {
    if (length(lst) <= n) { lst }
    else { take_last(tl(lst), n) }
}

fun drop_last(lst, n) {
    keep_count = length(lst) - n
    take_first(lst, keep_count, [])
}

fun take_first(lst, n, acc) {
    if (n <= 0) { acc }
    else {
        if (length(lst) == 0) { acc }
        else { take_first(tl(lst), n - 1, list_append(acc, hd(lst))) }
    }
}

fun prepend(xs, ys) {
    if (length(xs) == 0) { ys }
    else { append_all(xs, ys, 0, []) }
}

fun append_all(xs, ys, i, acc) {
    if (i < length(xs)) {
        append_all(xs, ys, i + 1, list_append(acc, list_at(xs, i)))
    } else {
        append_all_ys(ys, 0, acc)
    }
}

fun append_all_ys(ys, i, acc) {
    if (i < length(ys)) {
        append_all_ys(ys, i + 1, list_append(acc, list_at(ys, i)))
    } else { acc }
}

fun list_at(lst, i) {
    if (i == 0) { hd(lst) }
    else { list_at(tl(lst), i - 1) }
}

fun format_for_summary(msgs, acc) {
    if (length(msgs) == 0) { acc }
    else {
        msg = hd(msgs)
        role = map_get(msg, 'role')
        content = map_get(msg, 'content')
        tcs = map_get(msg, 'tool_calls')
        tcs_note = if (tcs == nil) { "" }
                   else { if (length(tcs) == 0) { "" }
                   else { " (+" ++ to_string(length(tcs)) ++ " tool_calls)" }}
        line = "[" ++ to_string(role) ++ "] " ++
               preview_string(to_string(content), 500) ++ tcs_note ++ "\n"
        format_for_summary(tl(msgs), acc ++ line)
    }
}

# ------------------------------------------------------------
# Session persistence — /save and /resume
# Format: JSON list of message objects.
# ------------------------------------------------------------
fun save_session(history, opts) {
    dir = session_dir()
    file_mkdir(dir)
    ts = to_string(timestamp())
    path = dir ++ "/session-" ++ ts ++ ".json"
    file_write(path, encode_history(history))
    path
}

fun encode_history(history) {
    json_encode(history_to_objects(history, []))
}

fun history_to_objects(msgs, acc) {
    if (length(msgs) == 0) { acc }
    else {
        history_to_objects(tl(msgs), list_append(acc, msg_for_journal(hd(msgs))))
    }
}

fun load_latest_session(opts) {
    dir = session_dir()
    # file_list is an in-process readdir. session-*.json names embed a
    # unix timestamp, so reverse-lex sort is equivalent to newest-first
    # (same digit count, monotonic). Avoids the 1s-per-shell penalty
    # the old `ls -t` paid.
    names = file_list(dir)
    latest = latest_session_name(names, nil)
    if (latest == nil) { [] }
    else {
        content = file_read(dir ++ "/" ++ latest)
        if (content == nil) { [] }
        else { decode_history(content) }
    }
}

fun latest_session_name(names, best) {
    if (length(names) == 0) { best }
    else {
        n = hd(names)
        new_best = if (is_session_file(n) == 'true' &&
                       (best == nil || n > best)) { n }
                   else { best }
        latest_session_name(tl(names), new_best)
    }
}

fun is_session_file(n) {
    string_starts_with(n, "session-") == 'true' &&
    string_ends_with(n, ".json") == 'true'
}

fun decode_history(json_str) {
    parsed = json_decode(json_str)
    if (parsed == nil) { [] }
    else { decode_history_loop(parsed, []) }
}

fun decode_history_loop(items, acc) {
    if (length(items) == 0) { acc }
    else {
        msg = replay_one(hd(items))
        if (msg == nil) { decode_history_loop(tl(items), acc) }
        else { decode_history_loop(tl(items), list_append(acc, msg)) }
    }
}

fun string_to_role(s) {
    if (s == "system") { 'system' }
    else { if (s == "user") { 'user' }
    else { if (s == "assistant") { 'assistant' }
    else { if (s == "tool") { 'tool' }
    else { 'user' }}}}
}

fun list_sessions() {
    dir = session_dir()
    names = file_list(dir)
    sessions = collect_session_names(names, [])
    if (length(sessions) == 0) { print("(no sessions)") }
    else {
        # Reverse-lex sort = newest-first because filenames embed a
        # monotonic unix timestamp. Cap at 20 to match the old `head -20`.
        sorted = sort_desc(sessions)
        print_session_lines(sorted, dir, 0, 20)
    }
}

fun collect_session_names(names, acc) {
    if (length(names) == 0) { acc }
    else {
        n = hd(names)
        new_acc = if (is_session_file(n) == 'true') { list_append(acc, n) }
                  else { acc }
        collect_session_names(tl(names), new_acc)
    }
}

# Simple in-place-ish reverse-sort by string comparison. Fine for the
# session-list use case (typically <100 files).
fun sort_desc(lst) {
    if (length(lst) <= 1) { lst }
    else {
        pivot = hd(lst)
        rest = tl(lst)
        greater = filter_gt(rest, pivot, [])
        lesser = filter_le(rest, pivot, [])
        sort_desc(greater) ++ [pivot] ++ sort_desc(lesser)
    }
}

fun filter_gt(lst, p, acc) {
    if (length(lst) == 0) { acc }
    else {
        h = hd(lst)
        new_acc = if (h > p) { list_append(acc, h) } else { acc }
        filter_gt(tl(lst), p, new_acc)
    }
}

fun filter_le(lst, p, acc) {
    if (length(lst) == 0) { acc }
    else {
        h = hd(lst)
        new_acc = if (h > p) { acc } else { list_append(acc, h) }
        filter_le(tl(lst), p, new_acc)
    }
}

fun print_session_lines(names, dir, i, cap) {
    if (length(names) == 0 || i >= cap) { 'ok' }
    else {
        print(dir ++ "/" ++ hd(names))
        print_session_lines(tl(names), dir, i + 1, cap)
    }
}

# ------------------------------------------------------------
# One turn: call LLM, dispatch any tool_calls, recurse until no more
# tool_calls are emitted. Returns the updated history.
# ------------------------------------------------------------
fun opts_with_history(opts, history) {
    a = map_put(opts, 'history_len', length(history))
    b = map_put(a, 'history_chars', history_chars(history))
    c = map_put(b, 'context_budget', context_budget_tokens())
    c
}

fun history_chars(history) { history_chars_loop(history, 0) }

fun history_chars_loop(h, acc) {
    if (length(h) == 0) { acc }
    else {
        msg = hd(h)
        content = map_get(msg, 'content')
        c_chars = if (content == nil) { 0 } else { string_length(to_string(content)) }
        tcs = map_get(msg, 'tool_calls')
        t_chars = if (tcs == nil) { 0 } else { tcs_chars(tcs, 0) }
        history_chars_loop(tl(h), acc + c_chars + t_chars)
    }
}

# Approximate char count for serialized tool_calls (name + args + overhead).
fun tcs_chars(tcs, acc) {
    if (length(tcs) == 0) { acc }
    else {
        tc = hd(tcs)
        name_l = string_length(to_string(map_get(tc, 'name')))
        args_l = string_length(to_string(map_get(tc, 'arguments')))
        tcs_chars(tl(tcs), acc + name_l + args_l + 16)
    }
}

# ------------------------------------------------------------
# F3b — mechanical (non-LLM) trim tier
# ------------------------------------------------------------
# Pure-string context shrink, mirroring claude-code's applyToolResultBudget
# → snip before any LLM auto-compaction. Walk OLDEST-first; for each role:'tool'
# or role:'user' message whose content exceeds ~8KB, replace the body with a
# "[N chars elided]" stub. Stop as soon as approx_tokens(history) < budget.
# Never touches system, assistant prose, tool_calls, or the LAST message (the
# live user turn). Needs no network — works even when the LLM is unreachable.
fun MECH_TRIM_THRESHOLD_CHARS() { 8000 }

fun mechanical_trim(history, budget_t) {
    n = length(history)
    if (n == 0) { history }
    else { mech_trim_loop(history, 0, n, budget_t, []) }
}

fun mech_trim_loop(msgs, i, total, budget_t, acc) {
    if (length(msgs) == 0) { acc }
    else {
        m = hd(msgs)
        # Recompute the running estimate from (acc-so-far ++ remaining). Cheap
        # enough at our message counts and keeps the stop condition honest.
        already_ok = if (approx_tokens(acc ++ msgs) <= budget_t) { 'true' } else { 'false' }
        if (already_ok == 'true') {
            # Under budget — emit the rest unchanged.
            acc ++ msgs
        } else {
            role = map_get(m, 'role')
            is_last = if (i == total - 1) { 'true' } else { 'false' }
            stubbable = if (is_last == 'true') { 'false' }
                        else { if (role == 'tool' || role == 'user') { 'true' } else { 'false' }}
            new_m = if (stubbable == 'true') { stub_if_large(m) } else { m }
            mech_trim_loop(tl(msgs), i + 1, total, budget_t, list_append(acc, new_m))
        }
    }
}

# Replace an oversized string body with a stub; small or non-string (multimodal
# list) content is left untouched so image blocks never get mangled.
fun stub_if_large(m) {
    c = map_get(m, 'content')
    if (c == nil) { m }
    else { if (is_list(c) == 'true') { m }
    else {
        s = to_string(c)
        if (string_length(s) <= MECH_TRIM_THRESHOLD_CHARS()) { m }
        else {
            stub = "[" ++ to_string(string_length(s)) ++ " chars elided to fit context]"
            map_put(m, 'content', stub)
        }
    }}
}

fun run_turn(history, opts, step) {
    if (step >= max_steps()) {
        turn_print(opts, UI.warn_text("[warn] max tool steps reached"))
        history
    } else {
        # Fatal guardrail halt — set by ToolGuardrails.observe_after
        # when the same tool has failed 8 times in a row. Surface it
        # to the user, clear the flag so the next user turn isn't
        # blocked, and bail without another LLM call.
        guard_table = map_get(opts, 'guardrails_table')
        halt = if (guard_table == nil) { nil }
               else { ets_get(guard_table, 'halt_reason') }
        if (halt != nil) {
            turn_print(opts, UI.err_text("[guardrail halt] " ++ to_string(halt)))
            ets_put(guard_table, 'halt_reason', nil)
            history
        } else {
        # F3a: gate over_budget on the LARGER of the previous turn's server
        # count and a live char-based estimate of the CURRENT history. A single
        # fat turn (giant read, big write arg echoed back) leaves a small stale
        # last_pt; relying on it alone ships a bloated history that stalls in
        # prefill. max(last_pt, estimate) catches the in-turn blow-up.
        last_pt = LLM.last_prompt_tokens(opts)
        budget_t = context_budget_tokens()
        est = approx_tokens(history)
        effective = if (last_pt != nil) { if (last_pt > est) { last_pt } else { est } }
                    else { est }
        over_budget = if (effective > budget_t) { 'true' } else { 'false' }
        working_hist = if (over_budget == 'true') {
            turn_print(opts, "  " ++ UI.dim_text("(context at ~" ++ to_string(effective) ++ " / " ++
                  to_string(budget_t) ++ " tokens, compacting)"))
            # F3b: pure-string mechanical trim tier FIRST — oldest-first, stub
            # oversized tool/user content. No LLM call (compaction itself needs
            # a working call, which fails in the same prefill regime). Only fall
            # back to LLM compaction if mechanical trim can't reach budget.
            # Trim to compact_target_tokens() (~70% of budget), NOT just under the
            # trigger — that hysteresis margin lets the next several tool steps run
            # without re-crossing the budget, so we don't trim on every step.
            trimmed = mechanical_trim(history, compact_target_tokens())
            if (approx_tokens(trimmed) > budget_t) {
                turn_print(opts, "  " ++ UI.dim_text("(mechanical trim insufficient — summarizing)"))
                compact_history(trimmed, opts)
            } else { trimmed }
        } else { history }

        # Soft ceiling — one-shot nudge at 90% of max_steps so the model
        # wraps up gracefully instead of being cut off mid-flight at the
        # hard cap (which it otherwise only discovers after the fact).
        hist_send = if (step == (max_steps() * 9) / 10) {
            list_append(working_hist, LLM.new_message_user(
                "[system notice] You have used " ++ to_string(step) ++ " of " ++
                to_string(max_steps()) ++ " tool steps for this turn. Finish up now: " ++
                "complete the immediate action, then summarize progress and stop."))
        } else { working_hist }

        result = LLM.chat(hist_send, opts)
        debug_env = getenv("SWARM_CODE_DEBUG")
        if (debug_env == "1" && result != nil) {
            print("\e[2m[debug result map keys: " ++
                  to_string(map_keys(result)) ++ "]\e[0m")
        }
        if (result == nil) {
            # Headless stdout is the captured result — keep it clean; failure
            # is signalled by exit 1 / the --json status. (Transport detail is
            # on stderr via the runtime.) Interactive keeps the inline error.
            if (map_get(opts, 'headless') != 'true') { turn_print(opts, UI.err_text("[error] llm call failed")) }
            # F2/F1: distinguish a POISONED context from a TRANSIENT failure.
            #  - FATAL (a 4xx request rejection or an unparseable body — re-sending
            #    the identical bytes can't fix it): drop back to the last clean user
            #    message so the offending tool_call is never journaled/re-fired, and
            #    flag the journal poisoned so even an immediate resume trims it.
            #  - TRANSIENT (network blip / 5xx after the retry budget): the context
            #    is fine, the wire failed. KEEP all completed work; only trim a
            #    dangling unsendable tail. Do NOT poison — a later resume is valid.
            fatal = LLM.last_fail(opts)
            recovered = if (fatal == 'fatal') {
                mark_poison(opts)
                drop_to_last_clean_user(working_hist)
            } else {
                trim_incomplete(working_hist)
            }
            journal_sync(opts, recovered)
            recovered
        } else {
            content = to_string(map_get(result, 'content'))
            tool_calls_v = map_get(result, 'tool_calls')
            reasoning = map_get(result, 'reasoning')
            tool_calls = if (tool_calls_v == nil) { [] } else { tool_calls_v }

            asst_msg = LLM.new_message_assistant(content, tool_calls, reasoning)
            with_assistant = list_append(working_hist, asst_msg)
            journal_sync(opts, with_assistant)
            # F2: a turn completed cleanly — clear any poison flag a PRIOR turn in
            # this same session set. Otherwise a mid-session recovery followed by
            # good work then a hard kill (no clean /quit) would make the next
            # launch trim the journal back to that old recovery point, discarding
            # the good work. clear_poison() is a cheap stat+unlink, idempotent.
            clear_poison()

            # F4: length-truncation recovery (finish_reason=length / truncation
            # marker) — ONLY when the turn carried no tool_calls. A truncated turn
            # that still emitted tool_calls is actionable: fall through and execute
            # them normally (appending a user nudge after an assistant-with-open-
            # tool_calls would be an invalid native sequence and would skip the
            # work). Stage 0: retry ONCE with a raised per-turn max_tokens. Stage 1:
            # inject a "continue in smaller append-mode edits" user-message while
            # KEEPING the partial assistant output. Stage 2+: give up gracefully.
            # Guarded by the 'trunc_retry' counter so we never loop unbounded.
            truncated = map_get(result, 'truncated')
            if (truncated == 'true' && length(tool_calls) == 0) {
                handle_truncation(with_assistant, tool_calls, opts, step)
            } else {

            if (length(tool_calls) == 0) {
                visible = string_trim(content)
                if (string_length(visible) == 0) {
                    last_pt2 = LLM.last_prompt_tokens(opts)
                    if (last_pt2 != nil && last_pt2 > context_budget_tokens() - 2000) {
                        turn_print(opts, "  " ++ UI.dim_text("(empty response — context near budget at " ++
                              to_string(last_pt2) ++ " tokens. Try /reset or a tighter query.)"))
                        turn_print(opts, "")
                        with_assistant
                    } else {
                        prior_reasoning = LLM.last_reasoning(opts)
                        if (prior_reasoning != nil) {
                            # Model reasoned but said nothing. Surface that and
                            # leave it — auto-retry risks burning a long chain
                            # of "think harder" requests for no real gain.
                            r_chars = string_length(to_string(prior_reasoning))
                            turn_print(opts, "  " ++ UI.dim_text("(model reasoned " ++ to_string(r_chars) ++
                                  " chars but emitted no spoken content. " ++
                                  "Type 'continue' to nudge it, or rephrase.)"))
                            turn_print(opts, "")
                            with_assistant
                        } else {
                            # Truly empty (no content, no tools, no reasoning):
                            # Kimi quirk after a chain of file reads. Nudge once
                            # in-band. Guarded by 'empty_retry' flag so we never
                            # loop more than a single nudge per turn.
                            already_retried = map_get(opts, 'empty_retry')
                            if (already_retried == 'true') {
                                turn_print(opts, "  " ++ UI.dim_text("(still empty after nudge — try rephrasing)"))
                                turn_print(opts, "")
                                with_assistant
                            } else {
                                turn_print(opts, "  " ++ UI.dim_text("(empty response — nudging once…)"))
                                nudge = "Your previous turn was empty. Based on what you've " ++
                                        "read so far, please respond — either a short summary, " ++
                                        "a question, or your next tool call. Don't stay silent."
                                with_nudge = list_append(with_assistant, LLM.new_message_user(nudge))
                                retry_opts = map_put(opts, 'empty_retry', 'true')
                                run_turn(with_nudge, retry_opts, step + 1)
                            }
                        }
                    }
                } else {
                    turn_print(opts, "")
                    with_assistant
                }
            } else {
                meter_opts = opts_with_history(opts, with_assistant)
                post_exec = execute_all(tool_calls, with_assistant, meter_opts)
                run_turn(post_exec, meter_opts, step + 1)
            }
            }
        }
        }
    }
}

# ------------------------------------------------------------
# F4 — length-truncation recovery (escalate max_tokens → smaller-edits nudge)
# ------------------------------------------------------------
# `with_assistant` already contains the (partial) assistant output — we never
# discard it. Mirrors claude-code's max-output recovery: bump max_tokens and
# retry once, then inject a recovery user-message telling the model to continue
# in smaller append-mode edits, up to a small recovery cap.
fun trunc_retry_max() { 2 }

# Raised per-turn output budget — double the configured max_tokens, capped at
# a sane ceiling so we don't ask a server for an absurd window.
fun raised_max_tokens(opts) {
    cur = map_get(opts, 'max_tokens')
    base = if (cur == nil) { 16384 } else { cur }
    doubled = base * 2
    ceil = 131072
    if (doubled > ceil) { ceil } else { doubled }
}

fun handle_truncation(with_assistant, tool_calls, opts, step) {
    stage = map_get(opts, 'trunc_retry')
    stage_n = if (stage == nil) { 0 } else { stage }
    if (stage_n == 0) {
        # Stage 0: retry once with a raised per-turn max_tokens. Keep the partial
        # assistant output in history so the model can continue from it.
        raised = raised_max_tokens(opts)
        turn_print(opts, "  " ++ UI.dim_text("(output hit the length limit — retrying once with " ++
              "max_tokens=" ++ to_string(raised) ++ ")"))
        retry_opts0 = map_put(opts, 'max_tokens', raised)
        retry_opts = map_put(retry_opts0, 'trunc_retry', 1)
        cont = "Your previous response was cut off at the output token limit. " ++
               "Continue exactly where you left off."
        with_nudge = list_append(with_assistant, LLM.new_message_user(cont))
        journal_sync(opts, with_nudge)
        run_turn(with_nudge, retry_opts, step + 1)
    }
    else { if (stage_n < trunc_retry_max()) {
        # Stage 1: still truncated after the raise. Inject the smaller-edits
        # recovery message; KEEP the partial assistant output.
        turn_print(opts, "  " ++ UI.dim_text("(still hitting the output limit — switching to " ++
              "smaller append-mode edits)"))
        recovery = "Output token limit hit again. Stop trying to emit large " ++
                   "blocks in one turn. Continue in smaller, append-mode edits: " ++
                   "write a short stub first, then use `edit` with old_string=\"\" " ++
                   "to append the remaining content in pieces."
        with_recovery = list_append(with_assistant, LLM.new_message_user(recovery))
        retry_opts = map_put(opts, 'trunc_retry', stage_n + 1)
        journal_sync(opts, with_recovery)
        run_turn(with_recovery, retry_opts, step + 1)
    }
    else {
        # Stage 2+: give up gracefully — keep the partial output, stop the loop.
        turn_print(opts, "  " ++ UI.dim_text("(output still truncated after recovery attempts — " ++
              "keeping the partial result; ask me to continue.)"))
        turn_print(opts, "")
        with_assistant
    }}
}

# Per-tool user-facing args formatter — matches CC's renderToolUseMessage.
fun format_tool_args(name, args_map, args_raw) {
    if (name == 'bash') {
        b_cmd = map_get(args_map, 'command')
        if (b_cmd == nil) { preview_string(args_raw, 100) }
        else { preview_string(to_string(b_cmd), 100) }
    }
    else { if (name == 'read') {
        r_path = resolve_path_key(args_map)
        if (r_path == nil) { preview_string(args_raw, 100) } else { to_string(r_path) }
    }
    else { if (name == 'write') {
        w_path = resolve_path_key(args_map)
        w_content = map_get(args_map, 'content')
        w_len = if (w_content == nil) { 0 } else { string_length(to_string(w_content)) }
        if (w_path == nil) { preview_string(args_raw, 100) }
        else { to_string(w_path) ++ ", " ++ to_string(w_len) ++ " bytes" }
    }
    else { if (name == 'edit') {
        e_path = resolve_path_key(args_map)
        if (e_path == nil) { preview_string(args_raw, 100) } else { to_string(e_path) }
    }
    else { if (name == 'multi_edit') {
        m_path = resolve_path_key(args_map)
        m_edits = map_get(args_map, 'edits')
        m_count = if (m_edits == nil) { 0 } else { length(m_edits) }
        if (m_path == nil) { preview_string(args_raw, 100) }
        else { to_string(m_path) ++ ", " ++ to_string(m_count) ++ " edits" }
    }
    else { if (name == 'glob') {
        g_pat = map_get(args_map, 'pattern')
        if (g_pat == nil) { preview_string(args_raw, 100) } else { to_string(g_pat) }
    }
    else { if (name == 'grep') {
        gr_pat = map_get(args_map, 'pattern')
        if (gr_pat == nil) { preview_string(args_raw, 100) } else { to_string(gr_pat) }
    }
    else { if (name == 'todo_write') {
        td_list = map_get(args_map, 'todos')
        if (td_list == nil) { "0 items" } else { to_string(length(td_list)) ++ " items" }
    }
    else { if (name == 'web_fetch') {
        wf_url = map_get(args_map, 'url')
        if (wf_url == nil) { preview_string(args_raw, 100) } else { to_string(wf_url) }
    }
    else { if (name == 'task') {
        t_desc = map_get(args_map, 'description')
        t_type = map_get(args_map, 'subagent_type')
        t_d = if (t_desc == nil) { "task" } else { to_string(t_desc) }
        t_s = if (t_type == nil) { "general" } else { to_string(t_type) }
        t_d ++ " [" ++ t_s ++ "]"
    }
    else { if (name == 'web_search') {
        ws_q = map_get(args_map, 'query')
        if (ws_q == nil) { preview_string(args_raw, 100) } else { to_string(ws_q) }
    }
    else { if (name == 'code_search') {
        cs_q = map_get(args_map, 'query')
        cs_p = map_get(args_map, 'pattern')
        cs = if (cs_q != nil) { cs_q } else { cs_p }
        if (cs == nil) { preview_string(args_raw, 100) } else { to_string(cs) }
    }
    else { if (name == 'git_commit') {
        gc_msg = map_get(args_map, 'message')
        if (gc_msg == nil) { "" } else { preview_string(to_string(gc_msg), 80) }
    }
    else { if (name == 'git_status') { "" }
    else { if (name == 'git_diff') {
        gd_path = resolve_path_key(args_map)
        if (gd_path == nil) { "" } else { to_string(gd_path) }
    }
    else { if (name == 'background') {
        bg_cmd = map_get(args_map, 'command')
        bg_lbl = map_get(args_map, 'label')
        bg_main = if (bg_lbl != nil) { bg_lbl } else { bg_cmd }
        if (bg_main == nil) { preview_string(args_raw, 100) } else { preview_string(to_string(bg_main), 100) }
    }
    else { if (name == 'bg_status') {
        bs_id = map_get(args_map, 'task_id')
        if (bs_id == nil) { "" } else { to_string(bs_id) }
    }
    else { if (name == 'bg_result') {
        br_id = map_get(args_map, 'task_id')
        if (br_id == nil) { "" } else { to_string(br_id) }
    }
    else { if (name == 'bg_tail') {
        bt_id = map_get(args_map, 'task_id')
        if (bt_id == nil) { "" } else { to_string(bt_id) }
    }
    else { if (name == 'bg_kill') {
        bk_id = map_get(args_map, 'task_id')
        if (bk_id == nil) { "" } else { to_string(bk_id) }
    }
    else { if (name == 'remember') {
        rm_n = map_get(args_map, 'name')
        rm_k = if (rm_n != nil) { rm_n } else { map_get(args_map, 'key') }
        if (rm_k == nil) { preview_string(args_raw, 80) } else { to_string(rm_k) }
    }
    else { if (name == 'recall') {
        rc_n = map_get(args_map, 'name')
        rc_k = if (rc_n != nil) { rc_n } else { map_get(args_map, 'key') }
        if (rc_k == nil) { preview_string(args_raw, 80) } else { to_string(rc_k) }
    }
    else { if (name == 'forget') {
        fg_n = map_get(args_map, 'name')
        fg_k = if (fg_n != nil) { fg_n } else { map_get(args_map, 'key') }
        if (fg_k == nil) { preview_string(args_raw, 80) } else { to_string(fg_k) }
    }
    else { if (name == 'memory_list') { "" }
    else { if (name == 'heartbeat_status') { "" }
    else { if (name == 'sys_stats') { "" }
    else { if (name == 'file_watch') {
        fw_path = resolve_path_key(args_map)
        if (fw_path == nil) { preview_string(args_raw, 100) } else { to_string(fw_path) }
    }
    else { preview_string(args_raw, 100) }}}}}}}}}}}}}}}}}}}}}}}}}}}
}

fun resolve_path_key(args_map) {
    rp = map_get(args_map, 'path')
    if (rp != nil) { rp } else { map_get(args_map, 'file_path') }
}

# Dispatch a tool call. `task` runs synchronously in-process; browser
# tools run inline so their CDP/WS handles persist; everything else
# runs in an isolated linked worker so a panicking tool can't kill
# the REPL.
fun dispatch_tool(name, args, opts) {
    pre = ToolExecutor.preflight(name, args, opts)
    if (map_get(pre, 'ok') != 'true') {
        to_string(map_get(pre, 'error'))
    } else {
        effective_args = map_get(pre, 'args')
        dispatch_tool_prepared(name, effective_args, opts)
    }
}

fun dispatch_tool_prepared(name, args, opts) {
    result = dispatch_tool_raw(name, args, opts)
    ToolExecutor.postflight(name, args, result, opts)
    result
}

fun dispatch_tool_raw(name, args, opts) {
    if (name == 'task') {
        if (map_get(opts, 'is_subagent') == 'true') {
            "error: nested `task` is not allowed — a subagent can't spawn its own subagent"
        } else { handle_task_tool(args, opts) }
    }
    else {
        if (string_starts_with(to_string(name), "browser_") == 'true') {
            Tools.exec_raw(name, args, opts)
        } else {
            exec_tool_isolated(name, args, opts)
        }
    }
}

# ------------------------------------------------------------
# Isolated tool execution — short-lived linked worker process so a
# tool panic stays scoped to the worker.
# ------------------------------------------------------------
fun exec_tool_isolated(name, args, opts) {
    trap_exit('true')
    # Unique per-dispatch token so a previously-interrupted worker's late
    # {'tool_done'} can never be mis-attributed to THIS (or a later) tool.
    token = to_string(timestamp()) ++ "-" ++ to_string(random_int(1, 1000000000))
    watch = tool_needs_watcher(name, opts)
    reader_pid = map_get(opts, 'reader_pid')
    if (watch == 'true' && reader_pid != nil) { send(reader_pid, {'watch_interrupt', token}) }
    w = spawn(tool_worker(self(), name, args, opts, token))
    link(w)
    started = timestamp()
    r = collect_tool_result(name, nil, w, token, opts, started, 'false')
    if (watch == 'true' && reader_pid != nil) { send(reader_pid, {'stop_watch'}) }
    r
}

# Whether a long-tool-wait heartbeat line should be shown. No-op in
# headless/one-shot and subagent runs (no interactive terminal to refresh,
# and a subagent's line would interleave with the parent's output). Same
# gate llm.sw uses for wait_hint.
fun tool_progress_enabled(opts) {
    if (map_get(opts, 'headless') == 'true') { 'false' }
    else { if (map_get(opts, 'is_subagent') == 'true') { 'false' }
    # mcp_server mode reserves stdout for JSON-RPC — never print there.
    else { if (map_get(opts, 'execution_context') == "mcp_server") { 'false' } else { 'true' } } }
}

# How long a tool must run before we first surface a "still running" line.
fun TOOL_PROGRESS_THRESHOLD_MS() { 4000 }
# How often the line refreshes once shown.
fun TOOL_PROGRESS_TICK_MS() { 2000 }
# Hard ceiling — a worker that never replies is abandoned after this.
fun TOOL_WAIT_DEADLINE_MS() { 600000 }

# How long the next receive should block. Before any line is shown, sleep
# right up to the threshold so a sub-threshold (fast) tool is woken at most
# once and never draws. After the line is up, tick on the refresh interval.
# Either way, never block past the hard deadline.
fun tool_wait_tick_ms(started, shown) {
    elapsed = timestamp() - started
    base = if (shown == 'true') { TOOL_PROGRESS_TICK_MS() }
           else {
        rem = TOOL_PROGRESS_THRESHOLD_MS() - elapsed
        if (rem < 1) { TOOL_PROGRESS_TICK_MS() } else { rem }
    }
    to_deadline = TOOL_WAIT_DEADLINE_MS() - elapsed
    capped = if (to_deadline < 1) { 1 } else { to_deadline }
    if (base > capped) { capped } else { base }
}

# Which tools get the reader's ESC interrupt-watcher. ONLY tools whose blocking
# work is NOT a shell_managed call, interactive mode only. Most shelling tools
# (bash/log_wait/web_search/git_*/code_search/glob/grep/file_watch/read-probes)
# run through shell_managed, which SELF-watches stdin in C and killpg's its
# process group on ESC — `_sw_rl.saved_ok` is a shared global, so that self-watch
# is active even inside a worker. Having the reader ALSO watch those would split
# the ESC byte between two readers (and a worker that lost the race could orphan
# its child). The reader therefore watches only the tools that block in a
# NON-shell_managed builtin:
#   - mcp__*    : subprocess_recv_line (MCP stdio)
#   - web_fetch : its primary fetch is http_get (curl to a file), which is
#     --max-time-bounded but does NOT self-watch stdin. Its later HTML-strip step
#     DOES use shell_managed; the brief overlap is harmless (the strip is fast,
#     local, and either reader winning the ESC yields the same "interrupted").
# headless/subagent have no interactive stdin.
fun tool_needs_watcher(name, opts) {
    headless = map_get(opts, 'headless')
    is_sub = map_get(opts, 'is_subagent')
    if (headless == 'true' || is_sub == 'true') { 'false' }
    else {
        ns = to_string(name)
        if (string_starts_with(ns, "mcp__") == 'true') { 'true' }
        else { if (ns == "web_fetch") { 'true' } else { 'false' } }
    }
}

fun tool_worker(parent, name, args, opts, token) {
    result = Tools.exec_raw(name, args, opts)
    send(parent, {'tool_done', token, result})
}

# `started` is the dispatch timestamp; `shown` is 'true' once a "still
# running" line has been drawn (so we know to clear it on completion). The
# `after` arm is the heartbeat: it fires on a short tick, surfaces a dim
# progress line past the threshold, and enforces the absolute deadline. No
# spawned ticker and no dependence on Heartbeat — self-contained, so it can
# never swallow a {'heartbeat_tick'} that main_loop / Scheduler.tick needs.
fun collect_tool_result(name, pending, worker, token, opts, started, shown) {
    receive {
        {'tool_done', tok, result} ->
            # Match our dispatch token. A non-matching tool_done is a late reply
            # from an earlier INTERRUPTED worker — drop it and keep waiting for
            # ours (it must never be mis-attributed to this tool).
            if (tok == token) {
                if (shown == 'true') { UI.tool_progress_clear() }
                collect_tool_result(name, result, worker, token, opts, started, 'false')
            }
            else { collect_tool_result(name, pending, worker, token, opts, started, shown) }
        {'interrupt', itok} ->
            # User pressed ESC — the reader's watch_loop forwarded it tagged
            # with this dispatch's token. Act ONLY on our token; a stale
            # interrupt (a previous tool's watcher firing late, within the
            # ~150ms stop lag) carries a different token and is dropped so it
            # can't mis-fire on this tool. If the tool already finished, prefer
            # its real result; otherwise unlink the still-running worker (its
            # late {'tool_done'} carries the stale token and is dropped above)
            # and return an interrupted marker without blocking on it. (Shell
            # tools never reach here — shell_managed kills their group in C.)
            if (itok != token) { collect_tool_result(name, pending, worker, token, opts, started, shown) }
            else { if (pending == nil) {
                if (shown == 'true') { UI.tool_progress_clear() }
                unlink(worker)
                "[interrupted] tool '" ++ to_string(name) ++ "' was stopped by the user (ESC)."
            } else {
                pending
            } }
        {'EXIT', _, ex_reason} ->
            if (pending == nil) {
                if (shown == 'true') { UI.tool_progress_clear() }
                tool_crash_msg(name, ex_reason)
            }
            else { pending }
        after tool_wait_tick_ms(started, shown) {
            # Heartbeat tick (or, before the first result, a short poll). If the
            # result has ALREADY arrived (pending set, e.g. between tool_done and
            # the linked worker's EXIT) just keep waiting for EXIT — don't redraw.
            if (pending != nil) {
                collect_tool_result(name, pending, worker, token, opts, started, shown)
            } else {
                elapsed = timestamp() - started
                if (elapsed >= TOOL_WAIT_DEADLINE_MS()) {
                    if (shown == 'true') { UI.tool_progress_clear() }
                    "error: tool '" ++ to_string(name) ++ "' timed out (worker did not respond)"
                } else {
                    # Past the threshold and on an interactive terminal: surface a
                    # dim, self-overwriting "still running (Ns)" line. Otherwise a
                    # no-op — fast tools finish before the threshold and never draw.
                    next_shown = if (elapsed >= TOOL_PROGRESS_THRESHOLD_MS() &&
                                     tool_progress_enabled(opts) == 'true') {
                        UI.tool_progress(name, elapsed / 1000)
                        'true'
                    } else { shown }
                    collect_tool_result(name, pending, worker, token, opts, started, next_shown)
                }
            }
        }
    }
}

fun tool_crash_msg(name, reason) {
    "error: tool '" ++ to_string(name) ++ "' crashed: " ++ to_string(reason) ++
    "\n(a bug in the tool itself, not your input — try a different approach)"
}

# ------------------------------------------------------------
# Subagent via the Task tool — synchronous in-process loop.
# ------------------------------------------------------------
fun handle_task_tool(args, opts) {
    prompt = map_get(args, 'prompt')
    stype = map_get(args, 'subagent_type', "general")

    if (prompt == nil) {
        "error: task tool requires a 'prompt' argument"
    } else {
        sub_sys = subagent_system_prompt(stype)
        sub_history = [
            LLM.new_message_system(sub_sys),
            LLM.new_message_user(prompt)
        ]
        sub_opts0 = map_put(opts, 'is_subagent', 'true')
        sub_opts = map_put(sub_opts0, 'execution_context', "subagent")
        result = run_subagent_loop(sub_history, sub_opts, 0)
        "[subagent:" ++ stype ++ "]\n" ++ result
    }
}

fun subagent_max_steps() { 15 }

fun subagent_system_prompt(stype) {
    base = "You are a focused subagent spawned from swarm-code for a single " ++
           "task. Use tools as needed, then return a concise final answer."
    if (stype == "explore") {
        base ++ "\n\nAllowed tools: read, glob, grep. Do NOT call bash, write, " ++
                "edit, multi_edit, or web_fetch. Your job is to survey the " ++
                "codebase and report findings."
    }
    else { if (stype == "bash") {
        base ++ "\n\nAllowed tool: bash. Your job is to run shell commands and " ++
                "report their output."
    }
    else {
        base ++ "\n\nYou have the full swarm-code tool set. Be decisive and finish " ++
                "quickly — do not ask follow-up questions, just do the work."
    }}
}

fun subagent_llm_worker(token, parent, history, opts) {
    result = LLM.chat(history, opts)
    send(parent, {'llm_result', token, result})
}

fun subagent_await_llm(token, deadline) {
    wait = deadline - timestamp()
    if (wait <= 0) { nil }
    else {
        receive {
            {'llm_result', t, r} ->
                if (t == token) { r }
                else { subagent_await_llm(token, deadline) }
            after wait { nil }
        }
    }
}

fun run_subagent_loop(history, opts, step) {
    if (step >= subagent_max_steps()) {
        "[subagent hit max steps without final answer]"
    } else {
        token = to_string(timestamp())
        spawn(subagent_llm_worker(token, self(), history, opts))
        result = subagent_await_llm(token, timestamp() + 300000)
        if (result == nil) {
            "[subagent llm call failed]"
        } else {
            content = to_string(map_get(result, 'content'))
            tcs_v = map_get(result, 'tool_calls')
            reasoning = map_get(result, 'reasoning')
            tool_calls = if (tcs_v == nil) { [] } else { tcs_v }
            if (length(tool_calls) == 0) {
                content
            } else {
                asst = LLM.new_message_assistant(content, tool_calls, reasoning)
                with_assistant = list_append(history, asst)
                post_tools = subagent_exec_all(tool_calls, with_assistant, opts)
                run_subagent_loop(post_tools, opts, step + 1)
            }
        }
    }
}

# Tools the main agent can use but subagents cannot. Anything that
# affects long-lived host state (memory, skills, background servers,
# git commits, nested task spawns) is locked to the main agent so a
# subagent can't quietly mutate the user's environment.
fun SUBAGENT_BLOCKED_TOOLS() {
    ToolRegistry.subagent_blocked_tools()
}

fun subagent_blocked(name) {
    if (ToolRegistry.allowed_in("subagent", name) == 'true') { 'false' }
    else { 'true' }
}

fun subagent_exec_all(tool_calls, history, opts) {
    if (length(tool_calls) == 0) { history }
    else {
        tc = hd(tool_calls)
        id = to_string(map_get(tc, 'id'))
        name_str = to_string(map_get(tc, 'name'))
        if (subagent_blocked(name_str) == 'true') {
            blocked = "error: tool '" ++ name_str ++ "' is not available to subagents — only the main agent can use it"
            tool_msg = LLM.new_message_tool(id, blocked)
            new_hist = list_append(history, tool_msg)
            subagent_exec_all(tl(tool_calls), new_hist, opts)
        } else {
            name_atom = string_to_atom(name_str)
            args_raw = to_string(map_get(tc, 'arguments'))
            args_map = json_decode(args_raw)
            args_map_safe = if (args_map == nil) { map_new() } else { args_map }
            sub_result = dispatch_tool(name_atom, args_map_safe, opts)
            tool_msg = LLM.new_message_tool(id, sub_result)
            new_hist = list_append(history, tool_msg)
            subagent_exec_all(tl(tool_calls), new_hist, opts)
        }
    }
}

# ------------------------------------------------------------
# Wake-aware display sink. Wake turns (bg_done / bg_stalled / pulse
# reactions) run while the Reader is pinned in read_line — a plain
# print scribbles over the live input line (and _builtin_print's
# \r\e[K wipes only ONE physical row of a wrapped input). print_above
# does the full wipe/redraw dance. Multi-line strings are split: one
# print_above call renders one physical line.
# ------------------------------------------------------------
fun turn_print(opts, s) {
    if (map_get(opts, 'wake_turn') == 'true') {
        turn_print_above(string_split(to_string(s), "\n"))
    } else { print(s) }
}

fun turn_print_above(lines) {
    if (length(lines) == 0) { 'ok' }
    else {
        print_above(hd(lines))
        turn_print_above(tl(lines))
    }
}

# Execute each structured tool_call in sequence, appending a
# role:'tool' result message for each. opts carries session state.
# ALL display output goes through turn_print so wake turns (which
# inherit 'wake_turn' in opts) land above the pinned prompt instead of
# over it — Wave-1A only covered the prose path; tools scribbled.
fun execute_all(tool_calls, history, opts) {
    if (length(tool_calls) == 0) { history }
    else {
        tc = hd(tool_calls)
        id = to_string(map_get(tc, 'id'))
        name_str = to_string(map_get(tc, 'name'))
        name_atom = string_to_atom(name_str)
        args_raw = to_string(map_get(tc, 'arguments'))
        args_map = json_decode(args_raw)
        # F5: a NON-EMPTY args blob that fails to parse is a truncated/malformed
        # tool call. Don't silently dispatch with empty args (which yields a
        # confusing "missing X" for an arg the model DID supply) — tell it to reissue.
        args_trim = string_trim(args_raw)
        malformed = if (args_map == nil && args_trim != "" && args_trim != "{}" && args_trim != "null") { 'true' } else { 'false' }
        result = if (malformed == 'true') {
            turn_print(opts, "")
            turn_print(opts, UI.tool_header_str(name_atom, "(malformed / truncated arguments)"))
            Log.tool_call(name_atom, args_raw)
            "error: the arguments for '" ++ name_str ++ "' were not valid JSON (likely truncated mid-string). Reissue this single tool call with complete, valid JSON arguments. If the content is large, write it in smaller pieces (stub then append-edit)."
        } else {
            args_map_safe = if (args_map == nil) { map_new() } else { args_map }
            turn_print(opts, "")
            turn_print(opts, UI.tool_header_str(name_atom, format_tool_args(name_atom, args_map_safe, args_raw)))
            Log.tool_call(name_atom, args_raw)
            prepared = ToolExecutor.prepare(name_atom, args_map_safe, opts)
            if (map_get(prepared, 'ok') != 'true') {
                to_string(map_get(prepared, 'error'))
            } else {
                effective_args = map_get(prepared, 'args')
                decision = resolve_permission(name_atom, effective_args, opts)
                if (decision == 'deny') {
                    denial = "error: permission denied for tool '" ++ name_str ++ "'"
                    turn_print(opts, UI.err_text(denial))
                    denial
                } else {
                    dispatch_tool_prepared(name_atom, effective_args, opts)
                }
            }
        }

        turn_print(opts, UI.tool_result_str(result))
        # Stash the FULL, uncapped result so /expand can reprint it — the ⎿
        # view caps at 8 lines. Interactive only; nil table is a no-op.
        expand_tbl = map_get(opts, 'expand_table')
        if (expand_tbl != nil) { ets_put(expand_tbl, 'last_tool_output', result) }
        # Colored ± preview for successful content edits — display-only,
        # never added to history, so it costs the model zero tokens.
        show_edit_diff(name_atom, args_map, result, opts)
        had_err = if (string_starts_with(result, "error:") == 'true') { 'true' } else { 'false' }
        Log.tool_result(name_atom, string_length(result), had_err)
        hist_done = list_append(history, LLM.new_message_tool(id, result))
        journal_sync(opts, hist_done)
        execute_all(tl(tool_calls), hist_done, opts)
    }
}

# ------------------------------------------------------------
# Edit diff preview — for successful edit/multi_edit calls, show the
# old/new content as colored ± lines. Suppressed in headless mode so
# piped -p output stays clean.
# ------------------------------------------------------------
fun show_edit_diff(name, args, result, opts) {
    if (map_get(opts, 'headless') == 'true') { 'ok' }
    # Wake turns: the diff renderer prints many plain lines that would land
    # on the pinned input line (Reader is in read_line). The preview is
    # display-only sugar — skip it, exactly like headless does.
    else { if (map_get(opts, 'wake_turn') == 'true') { 'ok' }
    else { if (string_starts_with(to_string(result), "ok:") != 'true') { 'ok' }
    else { if (args == nil) { 'ok' }
    else {
        if (name == 'edit') {
            UI.edit_diff_render(map_get(args, 'old_string'), map_get(args, 'new_string'))
        } else { if (name == 'multi_edit') {
            edits = map_get(args, 'edits')
            if (edits == nil) { 'ok' } else { diff_edits_loop(edits, 0) }
        } else { if (name == 'write') {
            # Overwrite diff: do_write stashed the file's prior bytes in
            # write_diff_table (only when it existed and was <64KB). A
            # fresh create leaves no prior → nothing to diff.
            wd = map_get(opts, 'write_diff_table')
            key = resolve_path_key(args)
            prior = if (wd == nil || key == nil) { nil }
                    else { ets_get(wd, to_string(key)) }
            if (prior == nil) { 'ok' }
            else { UI.edit_diff_render(prior, map_get(args, 'content')) }
        } else { 'ok' }}}
    }}}}
}

fun diff_edits_loop(edits, shown) {
    if (length(edits) == 0) { 'ok' }
    else {
        if (shown >= 3) {
            print("     " ++ UI.grey_text() ++ "… " ++ to_string(length(edits)) ++
                  " more edits not shown" ++ UI.reset())
        } else {
            e = hd(edits)
            UI.edit_diff_render(map_get(e, 'old_string'), map_get(e, 'new_string'))
            diff_edits_loop(tl(edits), shown + 1)
        }
    }
}

# ------------------------------------------------------------
# Permission resolution. 'ask' is delegated to the Reader process —
# the sole owner of read_line, preventing stdin races.
# ------------------------------------------------------------
fun resolve_permission(name, args, opts) {
    raw = Config.check_permission(name, args, opts)
    if (raw == 'allow') { 'allow' }
    else { if (raw == 'deny') { 'deny' }
    else {
        headless = map_get(opts, 'headless')
        if (headless == 'true') { 'allow' }
        else {
            # Session answer cache FIRST: a user who explicitly said "No,
            # always deny X this session" must stay denied even after
            # cycling /mode into auto-accept-edits — the mode only skips
            # the ASK, it never overrides an explicit session decision.
            table = map_get(opts, 'perms_table')
            cache_key = to_string(name)
            cached = if (table == nil) { nil } else { ets_get(table, cache_key) }
            if (cached == 'allow_session') { 'allow' }
            else { if (cached == 'deny_session') { 'deny' }
            else {
                # auto-accept-edits session mode (/mode): silently approve ONLY the
                # three content-edit tools — same effect as the user picking "always
                # allow this session". Every other tool still prompts. This runs
                # AFTER Config.check_permission (so a hardline 'deny' already won
                # above) and PathGuard is enforced in ToolExecutor.prepare, so the
                # safety floor is untouched — this only skips the interactive ASK.
                mode = get_session_mode(opts)
                is_edit_tool = if (name == 'edit' || name == 'write' || name == 'multi_edit') { 'true' } else { 'false' }
                if (mode == "auto-accept-edits" && is_edit_tool == 'true') { 'allow' }
                else { if (map_get(opts, 'wake_turn') == 'true') {
                    # Wake turns run while the Reader is pinned in read_line:
                    # a picker_ask would sit unread in the reader's mailbox
                    # for up to the 600s backstop (blocking the wake turn),
                    # then deny anyway — and the prompt would fight the
                    # pinned input line. Deny immediately with a visible
                    # notice; the model is told not to start major work on
                    # wake turns anyway.
                    print_above("  " ++ UI.dim_text("(wake turn: '" ++ to_string(name) ++
                        "' needs permission — denied; ask again interactively)"))
                    'deny'
                } else {
                    ask_via_reader(name, opts, table, cache_key)
                }}
            }}
        }
    }}
}

fun ask_via_reader(name, opts, table, cache_key) {
    reader_pid = map_get(opts, 'reader_pid')
    if (reader_pid == nil) { 'deny' }
    else {
        header = "\n  " ++ UI.brand_color() ++ "⏺" ++ UI.reset() ++ " \e[1mPermission\e[0m " ++
                 UI.grey_text() ++ "— run " ++ UI.reset() ++ "\e[1m" ++ to_string(name) ++
                 "\e[0m" ++ UI.grey_text() ++ "?" ++ UI.reset()
        options = [
            "Yes",
            "Yes, and always allow " ++ to_string(name) ++ " this session",
            "No"
        ]
        # Correlation token: a permission prompt that the user takes a while
        # to answer must not have its (eventual) answer consumed by the NEXT
        # prompt — a stale "Yes" silently auto-approving a different, later
        # tool is a real security bug. Tag the request; await only OUR token.
        token = to_string(self()) ++ "/" ++ to_string(timestamp())
        send(reader_pid, {'picker_ask', header, options, self(), token})
        idx = await_picker(token)
        interpret_picker(idx, table, cache_key)
    }
}

# Wait for THIS prompt's answer; drop (and keep waiting through) any stale
# answer carrying a different token. The long deadline is only a dead-Reader
# backstop — a permission decision is a human action, so we don't impose a
# short timeout that would race the user (the old 30s timeout was the bug).
fun await_picker(token) {
    receive {
        {'picker_answer', t, i} -> if (t == token) { i } else { await_picker(token) }
        after 600000 { -1 }
    }
}

fun interpret_picker(idx, table, cache_key) {
    if (idx == 0) { 'allow' }
    else { if (idx == 1) {
        if (table != nil) { ets_put(table, cache_key, 'allow_session') }
        'allow'
    }
    else { 'deny' }}
}

# Convert tool-name string → atom. Used by execute_all when iterating
# structured tool_calls (which carry name as string) to dispatch into
# Tools.exec_raw / dispatch_tool (which compare against atoms).
# Unknown strings return the string as-is so MCP names (mcp__*) and
# any future tools still resolve.
# ---------- /schedule helpers --------------------------------

fun show_schedules() {
    jobs = Scheduler.list_all()
    if (length(jobs) == 0) {
        print("\e[2m(no scheduled jobs — see /help for /schedule usage)\e[0m")
    } else {
        print("\e[1mscheduled jobs\e[0m")
        show_schedule_loop(jobs)
    }
}

fun show_schedule_loop(jobs) {
    if (length(jobs) == 0) { 'ok' }
    else {
        j = hd(jobs)
        id = to_string(map_get(j, 'id'))
        expr = to_string(map_get(j, 'expr'))
        prompt = to_string(map_get(j, 'prompt'))
        runs = map_get(j, 'runs', 0)
        print("  [" ++ id ++ "] " ++ expr ++ "  →  " ++
              preview_string(prompt, 70) ++
              UI.grey_text() ++ "  (" ++ to_string(runs) ++ " runs)" ++ UI.reset())
        show_schedule_loop(tl(jobs))
    }
}

# Parse `"EXPR" "PROMPT"` — both must be double-quoted. Returns
# (expr, prompt) tuple or nil on parse error.
fun parse_schedule_args(s) {
    if (string_length(s) < 5) { nil }
    else { if (string_sub(s, 0, 1) != "\"") { nil }
    else {
        # Find closing quote of first arg.
        end1 = find_quote(s, 1)
        if (end1 < 0) { nil }
        else {
            expr = string_sub(s, 1, end1 - 1)
            rest = string_trim(string_sub(s, end1 + 1, string_length(s) - end1 - 1))
            if (string_length(rest) < 2 || string_sub(rest, 0, 1) != "\"") { nil }
            else {
                end2 = find_quote(rest, 1)
                if (end2 < 0) { nil }
                else {
                    prompt = string_sub(rest, 1, end2 - 1)
                    [expr, prompt]
                }
            }
        }
    }}
}

fun find_quote(s, from) {
    if (from >= string_length(s)) { 0 - 1 }
    else {
        if (string_sub(s, from, 1) == "\"") { from }
        else { find_quote(s, from + 1) }
    }
}

# Print a one-line confirmation per image auto-attached from user
# input. Quiet when nothing matched (no surprise output on normal
# chat). Quiet too when a path was found but the profile doesn't
# support vision — Vision.auto_attach already returned [].
fun print_attachment_summary(paths) {
    if (length(paths) == 0) { 'noop' }
    else { print_attachment_loop(paths) }
}

fun print_attachment_loop(paths) {
    if (length(paths) == 0) { 'ok' }
    else {
        p = hd(paths)
        print(UI.grey_text() ++ "  📎 attached: " ++ p ++ UI.reset())
        print_attachment_loop(tl(paths))
    }
}

# Return the first whitespace-separated token of `s` (or `s` itself
# if there's no whitespace). Used to extract the slash command name
# from a line like `/profile gemma-local`.
fun first_token(s) {
    parts = string_split(s, " ")
    if (length(parts) == 0) { s } else { hd(parts) }
}

# Does `token` LOOK like a slash command — a leading "/" followed only by
# lowercase letters, "-", or "_"? This is the shape test that separates a
# mistyped command (/halp, /statuss) from a pasted filesystem path
# (/Users/sky/x, /tmp/a.png) or a bare "/". Command-shaped-but-unknown gets
# a "did you mean /help" nudge; everything else falls through to chat.
fun looks_like_slash_command(token) {
    if (string_starts_with(token, "/") != 'true') { 'false' }
    else {
        rest = string_sub(token, 1, string_length(token) - 1)
        if (string_length(rest) == 0) { 'false' }
        else { all_cmd_chars(rest, 0) }
    }
}

fun all_cmd_chars(s, i) {
    if (i >= string_length(s)) { 'true' }
    else {
        if (is_cmd_char(string_sub(s, i, 1)) == 'true') { all_cmd_chars(s, i + 1) }
        else { 'false' }
    }
}

# a-z, '-', '_' only. ord() gives the codepoint; a-z is 97..122, '-'=45,
# '_'=95. Uppercase, digits, "/", ".", "~" all fail — so real paths never
# masquerade as commands.
fun is_cmd_char(ch) {
    c = ord(ch)
    if (c == 45) { 'true' }
    else { if (c == 95) { 'true' }
    else { if (c >= 97 && c <= 122) { 'true' }
    else { 'false' }}}
}

# ------------------------------------------------------------
# /bg surface — user-facing view of the Background task table. The
# model manages tasks with the bg_status / bg_result / bg_tail / bg_kill
# TOOLS; the user drives the same table with these slash commands.
#   /bg               list all tasks
#   /bg tail <id> [n] tail a task's log (default 40 lines)
#   /bg kill <id>     kill a task
# id may be given bare ("3") or full ("bg-3").
# ------------------------------------------------------------
fun handle_bg_command(cmd, opts) {
    bg_table = map_get(opts, 'bg_table')
    if (bg_table == nil) {
        print(UI.grey_text() ++ "  (background tasks unavailable in this context)" ++ UI.reset())
    } else {
        parts = string_split(string_trim(cmd), " ")
        args = bg_nonempty(tl(parts), [])
        if (length(args) == 0) {
            # bare /bg — list all
            print("")
            print(UI.grey_text() ++ Background.list_all(bg_table) ++ UI.reset())
            print(UI.grey_text() ++ "  /bg tail <id> [n]  ·  /bg kill <id>" ++ UI.reset())
        } else {
            sub = hd(args)
            rest = tl(args)
            if (sub == "tail") { bg_cmd_tail(bg_table, rest) }
            else { if (sub == "kill") { bg_cmd_kill(bg_table, rest) }
            else {
                print(UI.warn_text("usage: /bg  |  /bg tail <id> [n]  |  /bg kill <id>"))
            }}
        }
    }
    'ok'
}

# Drop empty tokens (collapses runs of spaces from string_split).
fun bg_nonempty(lst, acc) {
    if (length(lst) == 0) { acc }
    else {
        h = hd(lst)
        next_acc = if (string_length(h) == 0) { acc } else { list_append(acc, h) }
        bg_nonempty(tl(lst), next_acc)
    }
}

# Normalize a task id: "3" -> "bg-3", "bg-3" -> "bg-3".
fun bg_normalize_id(s) {
    if (string_starts_with(s, "bg-") == 'true') { s } else { "bg-" ++ s }
}

fun bg_cmd_tail(bg_table, rest) {
    if (length(rest) == 0) {
        print(UI.warn_text("usage: /bg tail <id> [n]"))
    } else {
        id = bg_normalize_id(hd(rest))
        n = if (length(tl(rest)) == 0) { 40 }
            else {
                parsed = parse_budget_env(hd(tl(rest)), 0, 0, 'false')
                if (parsed <= 0) { 40 } else { parsed }
            }
        print("")
        print(UI.grey_text() ++ Background.tail_log(bg_table, id, n) ++ UI.reset())
    }
    'ok'
}

fun bg_cmd_kill(bg_table, rest) {
    if (length(rest) == 0) {
        print(UI.warn_text("usage: /bg kill <id>"))
    } else {
        id = bg_normalize_id(hd(rest))
        print(UI.grey_text() ++ "  " ++ Background.kill_task(bg_table, id) ++ UI.reset())
    }
    'ok'
}

# ------------------------------------------------------------
# Session permission mode — default | auto-accept-edits | plan.
# Cycled by /mode (CC's shift+tab). Stored in the perms_table ETS so
# resolve_permission and the footer chip both read the same value.
#   default            every ask-prompt is presented
#   auto-accept-edits  edit/write/multi_edit auto-approved this session
#   plan               plan-before-execute on (also flips the plan override)
# ------------------------------------------------------------
fun get_session_mode(opts) {
    tbl = map_get(opts, 'perms_table')
    v = if (tbl == nil) { nil } else { ets_get(tbl, 'session_mode') }
    if (v == nil) { "default" } else { to_string(v) }
}

fun set_session_mode(opts, m) {
    tbl = map_get(opts, 'perms_table')
    if (tbl != nil) { ets_put(tbl, 'session_mode', m) }
    'ok'
}

# Pure next-mode step: default → auto-accept-edits → plan → default.
fun next_mode(cur) {
    if (cur == "default") { "auto-accept-edits" }
    else { if (cur == "auto-accept-edits") { "plan" }
    else { "default" }}
}

fun cycle_mode(opts) {
    cur = get_session_mode(opts)
    nxt = next_mode(cur)
    set_session_mode(opts, nxt)
    # Plan-override file sync — touched ONLY on the plan-mode edges.
    # Entering plan stashes the file's prior content so LEAVING plan
    # restores it; the old force-write of "off" on every cycle
    # persistently clobbered a user's "/plan auto" from one /mode press.
    # A stashed "on"/absent is not restored (that would leave plan
    # active while the chip reads default) — the file is deleted so the
    # session falls back to env/auto defaults.
    p = Plan.plan_mode_override_path()
    if (p != nil) {
        tbl = map_get(opts, 'perms_table')
        if (nxt == "plan") {
            prior = if (file_exists(p) == 'true') {
                r = file_read(p)
                if (r == nil) { "absent" } else { string_trim(r) }
            } else { "absent" }
            if (tbl != nil) { ets_put(tbl, 'plan_mode_prev', prior) }
            file_write(p, "on")
        } else { if (cur == "plan") {
            prev = if (tbl == nil) { nil } else { ets_get(tbl, 'plan_mode_prev') }
            if (prev == "auto" || prev == "off") { file_write(p, to_string(prev)) }
            else { file_delete(p) }
        } else { 'ok' }}
    }
    nxt
}

# A colored one-word chip for the footer. Blank for plain "default" so the
# common case stays calm; the two active modes light up.
fun mode_chip(mode) {
    if (mode == "auto-accept-edits") {
        UI.green() ++ "auto-edits" ++ UI.reset() ++ UI.grey_text() ++ "  ·  " ++ UI.reset()
    } else { if (mode == "plan") {
        UI.warn_color() ++ "plan" ++ UI.reset() ++ UI.grey_text() ++ "  ·  " ++ UI.reset()
    } else { "" }}
}

# ------------------------------------------------------------
# Footer — draw the enriched bottom line (model · cwd (branch) · [mode]
# · tokens) just above the input prompt. Called before the first prompt
# (run) and after each user turn (handle_user_input_msg).
# ------------------------------------------------------------
fun draw_footer(history, opts) {
    cwd_base = path_basename(to_string(map_get(opts, 'cwd')))
    branch = git_branch(opts)
    mode = get_session_mode(opts)
    UI.input_box_bottom_ctx(to_string(map_get(opts, 'model')),
        display_tokens(history, opts), context_budget_tokens(),
        cwd_base, branch, mode_chip(mode))
    'ok'
}

# Last path segment of an absolute cwd. "/Users/sky/swarm-code" -> "swarm-code".
fun path_basename(p) {
    parts = string_split(p, "/")
    tail_seg = last_nonempty(parts, "")
    if (string_length(tail_seg) == 0) { p } else { tail_seg }
}

fun last_nonempty(lst, acc) {
    if (length(lst) == 0) { acc }
    else {
        h = hd(lst)
        next_acc = if (string_length(h) == 0) { acc } else { h }
        last_nonempty(tl(lst), next_acc)
    }
}

# Current git branch for the footer, via .git/HEAD (no subprocess — swarmrt's
# shell() imposes a 1s poll that would stall every footer draw). Walks up from
# cwd to find a .git/HEAD, reads "ref: refs/heads/<branch>". Detached HEAD or
# no repo -> "". Result is cached per-turn in the stream_state_table ETS with a
# short TTL so repeated footer redraws don't re-walk the tree.
fun git_branch(opts) {
    tbl = map_get(opts, 'stream_state_table')
    now = timestamp()
    cached_ms = if (tbl == nil) { nil } else { ets_get(tbl, 'git_branch_ms') }
    fresh = if (cached_ms == nil) { 'false' }
            else { if (now - cached_ms < 2000) { 'true' } else { 'false' }}
    if (fresh == 'true') { to_string(ets_get(tbl, 'git_branch')) }
    else {
        b = git_branch_compute(to_string(map_get(opts, 'cwd')), 0)
        if (tbl != nil) {
            ets_put(tbl, 'git_branch', b)
            ets_put(tbl, 'git_branch_ms', now)
        }
        b
    }
}

fun git_branch_compute(dir, depth) {
    if (depth > 40 || string_length(dir) == 0) { "" }
    else {
        head = dir ++ "/.git/HEAD"
        if (file_exists(head) == 'true') { git_branch_from_head(head) }
        else {
            # Worktree / submodule: .git is a FILE containing
            # "gitdir: <path>" — resolve HEAD there instead of walking up
            # (which surfaced an ANCESTOR repo's branch in the footer).
            gitfile = dir ++ "/.git"
            if (file_exists(gitfile) == 'true') {
                git_branch_from_gitfile(gitfile, dir)
            } else {
                parent = path_parent(dir)
                if (parent == dir) { "" }
                else { git_branch_compute(parent, depth + 1) }
            }
        }
    }
}

# .git-file redirection: read "gitdir: <path>" (absolute or relative to
# the containing dir) and pull the branch from <path>/HEAD. Anything
# unreadable/odd -> "" (this IS the repo boundary; do not walk past it).
fun git_branch_from_gitfile(gitfile, dir) {
    c = file_read(gitfile)
    if (c == nil) { "" }
    else {
        t = string_trim(c)
        if (string_starts_with(t, "gitdir: ") == 'true') {
            gd = string_trim(string_sub(t, 8, string_length(t) - 8))
            gd_abs = if (string_starts_with(gd, "/") == 'true') { gd }
                     else { dir ++ "/" ++ gd }
            git_branch_from_head(gd_abs ++ "/HEAD")
        } else { "" }
    }
}

fun git_branch_from_head(head) {
    content = file_read(head)
    if (content == nil) { "" }
    else {
        t = string_trim(content)
        if (string_starts_with(t, "ref: refs/heads/") == 'true') {
            string_sub(t, 16, string_length(t) - 16)
        } else { "" }
    }
}

# Parent directory of an absolute path. "/a/b" -> "/a"; "/a" -> "/"; "/" -> "/".
fun path_parent(dir) {
    if (dir == "/") { "/" }
    else {
        idx = last_slash(dir, string_length(dir) - 1)
        if (idx <= 0) { "/" }
        else { string_sub(dir, 0, idx) }
    }
}

fun last_slash(s, i) {
    if (i < 0) { 0 - 1 }
    else { if (string_sub(s, i, 1) == "/") { i } else { last_slash(s, i - 1) }}
}

# Is `cmd` (with leading slash) a recognised slash-command name?
# Filesystem paths like `/Users/...` / `/tmp/...` / `/home/...` aren't
# in this list, so they fall through route_input to the chat path
# instead of getting eaten by the dispatcher.
fun is_known_slash_command(cmd) {
    if (cmd == "/help") { 'true' }
    else { if (cmd == "/tools") { 'true' }
    else { if (cmd == "/status") { 'true' }
    else { if (cmd == "/clear") { 'true' }
    else { if (cmd == "/history") { 'true' }
    else { if (cmd == "/tokens") { 'true' }
    else { if (cmd == "/model") { 'true' }
    else { if (cmd == "/profile") { 'true' }
    else { if (cmd == "/profiles") { 'true' }
    else { if (cmd == "/profile-clear") { 'true' }
    else { if (cmd == "/search") { 'true' }
    else { if (cmd == "/paste") { 'true' }
    else { if (cmd == "/schedule") { 'true' }
    else { if (cmd == "/schedules") { 'true' }
    else { if (cmd == "/unschedule") { 'true' }
    else { if (cmd == "/export-trajectory") { 'true' }
    else { if (cmd == "/export-trajectories") { 'true' }
    else { if (cmd == "/compact") { 'true' }
    else { if (cmd == "/save") { 'true' }
    else { if (cmd == "/resume") { 'true' }
    else { if (cmd == "/sessions") { 'true' }
    else { if (cmd == "/todos") { 'true' }
    else { if (cmd == "/cost") { 'true' }
    else { if (cmd == "/telemetry") { 'true' }
    else { if (cmd == "/stats") { 'true' }
    else { if (cmd == "/autonomy") { 'true' }
    else { if (cmd == "/daemon") { 'true' }
    else { if (cmd == "/reflect") { 'true' }
    else { if (cmd == "/mcp") { 'true' }
    else { if (cmd == "/mcp reconnect") { 'true' }
    else { if (string_starts_with(cmd, "/mcp reconnect ") == 'true') { 'true' }
    else { if (cmd == "/memory") { 'true' }
    else { if (cmd == "/plan") { 'true' }
    else { if (cmd == "/quit") { 'true' }
    else { if (cmd == "/exit") { 'true' }
    else { if (cmd == "/reset") { 'true' }
    else { if (cmd == "/debug") { 'true' }
    else { if (cmd == "/flows") { 'true' }
    else { if (cmd == "/bg") { 'true' }
    else { if (cmd == "/mode") { 'true' }
    else { if (cmd == "/expand") { 'true' }
    else { 'false' }}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}
}

# (preview_string and string_to_atom moved earlier — see below)
