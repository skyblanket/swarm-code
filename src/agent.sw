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

export [run, run_headless]

# Maximum tool-call rounds per user turn.
fun max_steps() { 200 }

# Auto-compaction threshold (message count).
fun compact_threshold() { 120 }

# ------------------------------------------------------------
# Context budget — token-based, sourced from server usage
# ------------------------------------------------------------
fun max_tokens_env()      { parse_env_int("SWARM_CODE_MAX_TOKENS",      262144) }
fun output_reserve_env()  { parse_env_int("SWARM_CODE_OUTPUT_RESERVE",   16384) }
fun compact_buffer_env()  { parse_env_int("SWARM_CODE_COMPACT_BUFFER",   52000) }

fun context_budget_tokens() {
    max_tokens_env() - output_reserve_env() - compact_buffer_env()
}

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
fun trim_incomplete(msgs) {
    if (length(msgs) == 0) { msgs }
    else {
        last = hd(take_last(msgs, 1))
        role = map_get(last, 'role')
        if (role == 'assistant') {
            tcs = map_get(last, 'tool_calls')
            if (tcs == nil || length(tcs) == 0) { msgs }
            else { drop_last(msgs, 1) }
        } else { msgs }
    }
}

fun journal_clean(opts) {
    ap = journal_active_ptr()
    if (file_exists(ap) == 'true') { file_delete(ap) }
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
    file_write(ap, journal_path)
    opts_journal = map_put(opts, 'journal_path', journal_path)

    history = if (length(resumed) > 0) {
        print("")
        print(UI.grey_text() ++ "  ⏺ resumed crashed session — " ++
              to_string(length(resumed)) ++ " messages recovered" ++ UI.reset())
        prepend([LLM.new_message_system(system_prompt_text)], resumed)
    } else {
        [LLM.new_message_system(system_prompt_text)]
    }
    journal_sync(opts_journal, history)

    reader_pid = Reader.start()
    print("")
    if (reader_pid != nil) {
        send(reader_pid, {'draw_and_read'})
    }
    opts_with_reader = map_put(opts_journal, 'reader_pid', reader_pid)
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
    file_write(ap, journal_path)
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
    UI.input_box_bottom_full(to_string(map_get(opts, 'model')),
        display_tokens(history, opts), context_budget_tokens())
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
        else {
            Config.run_hooks("UserPromptSubmit", 'user', line, opts)
            # Auto-detect image paths in the user's message and queue
            # them for attachment before sending. Mirrors claude-code's
            # drag-drop / path-paste pattern — no read_image call needed.
            attached = Vision.auto_attach(opts, line)
            print_attachment_summary(attached)
            new_hist = list_append(history, LLM.new_message_user(line))
            pre_turn_hist = if (length(new_hist) > compact_threshold()) {
                print("\e[2m[auto-compacting " ++ to_string(length(new_hist)) ++ " messages]\e[0m")
                compact_history(new_hist, opts)
            } else { new_hist }
            run_turn(pre_turn_hist, opts, 0)
        }}}}
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
    wake_opts = map_put(opts, 'in_wake_chain', 'true')
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
            print("")
            print("\e[2m[daemon pulse — acting autonomously]\e[0m")
            with_pulse = list_append(history, LLM.new_message_user(pulse_msg))
            # chat_silent returns a string; pulse may have emitted inband
            # tool markers. Parse them once via LLM.parse_inband_tool_calls.
            parsed = LLM.parse_inband_tool_calls(trimmed)
            pulse_prose = to_string(map_get(parsed, 'content'))
            pulse_tcs = map_get(parsed, 'tool_calls')
            with_response = list_append(with_pulse,
                LLM.new_message_assistant(pulse_prose, pulse_tcs, nil))
            if (length(pulse_tcs) == 0) {
                print("  " ++ UI.grey_text() ++ pulse_prose ++ UI.reset())
                print("")
                with_response
            } else {
                execute_all(pulse_tcs, with_response, wake_opts)
            }
        }
    }
}

# Background task completion handler.
fun on_bg_done(task_id, exit_code, label, history, opts) {
    Log.bg_done(task_id, exit_code, label)
    color = if (exit_code == 0) { UI.brand_color() } else { "\e[31m" }
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

        print("\e[2m[autonomy: reacting to bg_done...]\e[0m")
        with_wake = list_append(history, LLM.new_message_user(wake_msg))
        wake_opts = map_put(opts, 'in_wake_chain', 'true')
        run_turn(with_wake, wake_opts, 0)
    } else {
        print("  \e[38;5;240m⎿\e[0m  \e[38;5;244muse bg_result " ++ task_id ++ " to see output\e[0m")
        print("")
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
    else { if (string_starts_with(cmd, "/search ") == 'true') {
        query = string_trim(string_sub(cmd, 8, string_length(cmd) - 8))
        if (string_length(query) == 0) {
            print("\e[33musage: /search QUERY\e[0m")
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
            print("\e[33musage: /schedule \"EXPR\" \"PROMPT\"  " ++
                  "(EXPR is 30s/5m/2h/1d or 'hourly'/'daily HH:MM')\e[0m")
        } else {
            expr = hd(parsed)
            prompt = hd(tl(parsed))
            id = Scheduler.add(expr, prompt)
            if (id == nil) {
                print("\e[33minvalid EXPR — try 30s, 5m, 2h, 1d, hourly, daily 09:00\e[0m")
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
            print("\e[33mno job with id " ++ id ++ "\e[0m")
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
            print("\e[33m(clipboard has no image — copy a screenshot first)\e[0m")
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
            print("\e[33mno session to resume\e[0m")
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
    else {
        print("\e[33munknown command: " ++ cmd ++ "\e[0m  (type /help)")
        history
    }}}}}}}}}}}}}}}}}}}}}}}}}}}}}}
}

fun show_help() {
    print("\e[1mcommands\e[0m")
    print("  /help                 show this help")
    print("  /status               session info")
    print("  /tools                list available tools")
    print("  /todos                show todo list")
    print("  /mcp                  list MCP servers and their tools")
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
    print("  /clear                clear screen")
    print("  /reset                clear conversation history")
    print("  /compact              summarize history to save context")
    print("  /save                 save current session")
    print("  /resume               resume latest saved session")
    print("  /sessions             list recent sessions")
    print("  /daemon               show daemon mode (cognitive pulse)")
    print("  /autonomy             show autonomy mode (bg_done wake)")
    print("  /reflect              trigger one-shot reflection")
    print("  /quit /exit           exit")
}

fun show_status(history, opts) {
    print("\e[1mswarm-code status\e[0m")
    print("  model    : " ++ to_string(map_get(opts, 'model')))
    print("  endpoint : " ++ to_string(map_get(opts, 'endpoint')))
    print("  cwd      : " ++ to_string(map_get(opts, 'cwd')))
    print("  messages : " ++ to_string(length(history)))
    print("  ~tokens  : " ++ to_string(approx_tokens(history)))
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
        print("\e[33musage: /profile NAME  (try /profiles to list)\e[0m")
    }
    else {
        settings = Config.load()
        profiles = if (settings == nil) { nil } else { map_get(settings, 'profiles') }
        if (profiles == nil) {
            print("\e[33mno 'profiles' map in ~/.swarm-code/settings.json\e[0m")
        }
        else {
            p = lookup_profile(profiles, name)
            if (p == nil) {
                print("\e[33mno profile named '" ++ name ++ "' — try /profiles\e[0m")
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
        print("\e[33musage: /model NAME\e[0m")
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
            print("\e[33m(override file present but unreadable: " ++ p ++ ")\e[0m")
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
        print("\e[33m  server /v1/models: unreachable\e[0m")
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
                     else { " \e[38;5;240m[+" ++ to_string(length(tcs)) ++ " tool_calls]\e[0m" }}
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

fun run_turn(history, opts, step) {
    if (step >= max_steps()) {
        print("\e[33m[warn] max tool steps reached\e[0m")
        history
    } else {
        last_pt = LLM.last_prompt_tokens(opts)
        budget_t = context_budget_tokens()
        over_budget = if (last_pt != nil) {
            if (last_pt > budget_t) { 'true' } else { 'false' }
        } else {
            if (history_chars(history) > context_budget_chars_fallback()) { 'true' } else { 'false' }
        }
        working_hist = if (over_budget == 'true') {
            shown = if (last_pt != nil) {
                "(context at " ++ to_string(last_pt) ++ " / " ++
                to_string(budget_t) ++ " tokens, compacting)"
            } else {
                "(context estimate over budget, compacting)"
            }
            print("  \e[38;5;240m" ++ shown ++ "\e[0m")
            compact_history(history, opts)
        } else { history }

        result = LLM.chat(working_hist, opts)
        debug_env = getenv("SWARM_CODE_DEBUG")
        if (debug_env == "1" && result != nil) {
            print("\e[2m[debug result map keys: " ++
                  to_string(map_keys(result)) ++ "]\e[0m")
        }
        if (result == nil) {
            print("\e[31m[error] llm call failed\e[0m")
            working_hist
        } else {
            content = to_string(map_get(result, 'content'))
            tool_calls_v = map_get(result, 'tool_calls')
            reasoning = map_get(result, 'reasoning')
            tool_calls = if (tool_calls_v == nil) { [] } else { tool_calls_v }

            asst_msg = LLM.new_message_assistant(content, tool_calls, reasoning)
            with_assistant = list_append(working_hist, asst_msg)
            journal_sync(opts, with_assistant)

            if (length(tool_calls) == 0) {
                visible = string_trim(content)
                if (string_length(visible) == 0) {
                    last_pt2 = LLM.last_prompt_tokens(opts)
                    if (last_pt2 != nil && last_pt2 > context_budget_tokens() - 2000) {
                        print("  \e[38;5;240m(empty response — context near budget at " ++
                              to_string(last_pt2) ++ " tokens. Try /reset or a tighter query.)\e[0m")
                    } else {
                        prior_reasoning = LLM.last_reasoning(opts)
                        if (prior_reasoning != nil) {
                            r_chars = string_length(to_string(prior_reasoning))
                            print("  \e[38;5;240m(model reasoned " ++ to_string(r_chars) ++
                                  " chars but emitted no spoken content. " ++
                                  "Type 'continue' to nudge it, or rephrase.)\e[0m")
                        } else {
                            print("  \e[38;5;240m(assistant returned empty response — try rephrasing)\e[0m")
                        }
                    }
                }
                print("")
                with_assistant
            } else {
                post_exec = execute_all(tool_calls, with_assistant, opts)
                run_turn(post_exec, opts, step + 1)
            }
        }
    }
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
    if (name == 'task') {
        if (map_get(opts, 'is_subagent') == 'true') {
            "error: nested `task` is not allowed — a subagent can't spawn its own subagent"
        } else { handle_task_tool(args, opts) }
    }
    else {
        if (string_starts_with(to_string(name), "browser_") == 'true') {
            Tools.exec(name, args, opts)
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
    w = spawn(tool_worker(self(), name, args, opts))
    link(w)
    collect_tool_result(name, nil)
}

fun tool_worker(parent, name, args, opts) {
    result = Tools.exec(name, args, opts)
    send(parent, {'tool_done', result})
}

fun collect_tool_result(name, pending) {
    receive {
        {'tool_done', result} -> collect_tool_result(name, result)
        {'EXIT', _, ex_reason} ->
            if (pending == nil) { tool_crash_msg(name, ex_reason) }
            else { pending }
        after 600000 {
            if (pending == nil) {
                "error: tool '" ++ to_string(name) ++ "' timed out (worker did not respond)"
            } else {
                pending
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
    subtype_opt = map_get(args, 'subagent_type')
    stype = if (subtype_opt == nil) { "general" } else { subtype_opt }

    if (prompt == nil) {
        "error: task tool requires a 'prompt' argument"
    } else {
        sub_sys = subagent_system_prompt(stype)
        sub_history = [
            LLM.new_message_system(sub_sys),
            LLM.new_message_user(prompt)
        ]
        sub_opts = map_put(opts, 'is_subagent', 'true')
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

fun subagent_exec_all(tool_calls, history, opts) {
    if (length(tool_calls) == 0) { history }
    else {
        tc = hd(tool_calls)
        id = to_string(map_get(tc, 'id'))
        name_str = to_string(map_get(tc, 'name'))
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

# Execute each structured tool_call in sequence, appending a
# role:'tool' result message for each. opts carries session state.
fun execute_all(tool_calls, history, opts) {
    if (length(tool_calls) == 0) { history }
    else {
        tc = hd(tool_calls)
        id = to_string(map_get(tc, 'id'))
        name_str = to_string(map_get(tc, 'name'))
        name_atom = string_to_atom(name_str)
        args_raw = to_string(map_get(tc, 'arguments'))
        args_map = json_decode(args_raw)
        args_map_safe = if (args_map == nil) { map_new() } else { args_map }

        UI.tool_header(name_atom, format_tool_args(name_atom, args_map_safe, args_raw))
        Log.tool_call(name_atom, args_raw)

        decision = resolve_permission(name_atom, args_map_safe, opts)
        if (decision == 'deny') {
            denial = "error: permission denied for tool '" ++ name_str ++ "'"
            print("\e[31m" ++ denial ++ "\e[0m")
            hist_denied = list_append(history, LLM.new_message_tool(id, denial))
            journal_sync(opts, hist_denied)
            execute_all(tl(tool_calls), hist_denied, opts)
        } else {
            pre = Config.run_hooks("PreToolUse", name_atom, args_raw, opts)
            if (pre == 'block') {
                blocked = "error: tool '" ++ name_str ++ "' blocked by PreToolUse hook"
                print("\e[31m" ++ blocked ++ "\e[0m")
                hist_blocked = list_append(history, LLM.new_message_tool(id, blocked))
                journal_sync(opts, hist_blocked)
                execute_all(tl(tool_calls), hist_blocked, opts)
            } else {
                result = dispatch_tool(name_atom, args_map_safe, opts)
                UI.tool_result(result)
                had_err = if (string_starts_with(result, "error:") == 'true') { 'true' } else { 'false' }
                Log.tool_result(name_atom, string_length(result), had_err)

                Config.run_hooks("PostToolUse", name_atom, args_raw, opts)

                hist_ok = list_append(history, LLM.new_message_tool(id, result))
                journal_sync(opts, hist_ok)
                execute_all(tl(tool_calls), hist_ok, opts)
            }
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
            table = map_get(opts, 'perms_table')
            cache_key = to_string(name)
            cached = if (table == nil) { nil } else { ets_get(table, cache_key) }
            if (cached == 'allow_session') { 'allow' }
            else { if (cached == 'deny_session') { 'deny' }
            else {
                ask_via_reader(name, opts, table, cache_key)
            }}
        }
    }}
}

fun ask_via_reader(name, opts, table, cache_key) {
    reader_pid = map_get(opts, 'reader_pid')
    if (reader_pid == nil) { 'deny' }
    else {
        header = "\n  \e[38;5;124m⏺\e[0m \e[1mPermission\e[0m \e[38;5;240m" ++
                 "— run \e[0m\e[1m" ++ to_string(name) ++ "\e[0m\e[38;5;240m?\e[0m"
        options = [
            "Yes",
            "Yes, and always allow " ++ to_string(name) ++ " this session",
            "No"
        ]
        send(reader_pid, {'picker_ask', header, options, self()})
        idx = receive {
            {'picker_answer', i} -> i
            after 30000 { -1 }
        }
        interpret_picker(idx, table, cache_key)
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
# Tools.exec / dispatch_tool (which compare against atoms).
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
        runs_v = map_get(j, 'runs')
        runs = if (runs_v == nil) { 0 } else { runs_v }
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
    else { if (cmd == "/quit") { 'true' }
    else { if (cmd == "/exit") { 'true' }
    else { if (cmd == "/reset") { 'true' }
    else { 'false' }}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}
}

# String → atom for tool dispatch. Was a ~50-case if/else; now a
# one-liner that walks the central ToolRegistry. Unknown names pass
# through as strings (MCP tools have the mcp__* prefix and resolve
# in tools.sw exec).
fun string_to_atom(s) {
    ToolRegistry.atom_for(s)
}

# Truncate string for inline preview.
fun preview_string(s, cap) {
    if (string_length(s) <= cap) { s }
    else { string_sub(s, 0, cap) ++ " ..." }
}
