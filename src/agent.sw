module Agent

# ============================================================
# Agent — REPL loop + tool-call extraction
# ============================================================
#
# The interactive loop:
#   1. Read a line from stdin (prompt "> ")
#   2. Append as a user message
#   3. Call the LLM; loop:
#        - extract <tool_call> blocks from the assistant response
#        - print rationale text + each tool invocation
#        - execute each tool via Tools.exec
#        - append <tool_result> as a user message
#        - call LLM again
#      Stop when the assistant response has no tool calls.
#   4. Back to (1).

import LLM
import Tools
import Config
import UI
import Arthopod
import Reader
import Log
import Agents
import Mcp

export [run, run_headless]

# Maximum tool-call rounds per user turn (prevents runaway loops).
fun max_steps() { 200 }

# Auto-compaction threshold (message count). Raised from 50 because a
# single turn with one tool call adds ~3 messages (user, assistant-with-
# tool, tool-result), so 50 fires after only ~16 turns which felt early.
fun compact_threshold() { 120 }

# ------------------------------------------------------------
# Context budget — token-based, sourced from server usage
# ------------------------------------------------------------
# We now budget compaction against REAL prompt_tokens returned by the
# server's `usage` field on every LLM response, not a char estimate.
# This matches Claude Code's approach and uses the exact number the
# model sees internally.
#
# Model context window: set via SWARM_CODE_MAX_TOKENS env var. Default
# 262144 (256K), matching Kimi K2.6's published context window. Override
# via env var when running against smaller models (Gemma 4 31B = 128000).
#
# Compaction trigger: prompt_tokens > (max_tokens - output_reserve -
# buffer). Claude Code uses a 20k output reserve + 13k buffer, so
# effective trigger ≈ 84% of max for a 200k model, 97% for 1M. We
# mirror that with configurable reserves.
#
# Env vars:
#   SWARM_CODE_MAX_TOKENS       — the model's context window (default 262144 = Kimi K2.6)
#   SWARM_CODE_OUTPUT_RESERVE   — tokens reserved for the response (default 16384 = K2.6 max output)
#   SWARM_CODE_COMPACT_BUFFER   — extra safety buffer (default 52000)
#
# Resulting default trigger: 262144 - 16384 - 52000 = 193760 tokens.
# Compaction kicks in at ~74% of K2.6's window — leaves headroom for
# the response plus safety margin against retrieval drift on long runs.
fun max_tokens_env()      { parse_env_int("SWARM_CODE_MAX_TOKENS",      262144) }
fun output_reserve_env()  { parse_env_int("SWARM_CODE_OUTPUT_RESERVE",   16384) }
fun compact_buffer_env()  { parse_env_int("SWARM_CODE_COMPACT_BUFFER",   52000) }

# Effective token budget — compact when prompt_tokens exceeds this.
fun context_budget_tokens() {
    max_tokens_env() - output_reserve_env() - compact_buffer_env()
}

# Legacy: char-based budget used ONLY as a fallback on the very first
# turn of a session before we've seen any usage from the server. Once
# we have a real prompt_tokens, char estimates are never used again.
fun context_budget_chars_fallback() {
    # Char budget roughly matches token budget at 4 chars/token.
    context_budget_tokens() * 4
}

# Minimal positive-integer env-var parser. Returns fallback if unset
# or unparseable.
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

# Session file path (for persistence).
fun session_dir() { getenv("HOME") ++ "/.swarm-code/sessions" }

# ============================================================
# Crash-recovery journal
# ============================================================
# swarm-code panics are exit(1) — uncatchable — and a C-level fault
# kills the whole VM. No in-process supervisor can save a crashed
# turn. The ONLY thing that survives is on-disk state, so we journal
# every message the instant history changes.
#
# Layout (~/.swarm-code/sessions/):
#   journal-<ts>.jsonl  — one ["role","content"] JSON array per line
#   .active             — pointer file holding the live session's
#                         journal path. Deleted on a clean /quit.
#                         If it still exists at startup, the last
#                         session crashed → we replay and resume.
#
# The system prompt is NOT journaled (rebuilt fresh every boot).
# The bin/swc-run supervisor relaunches the binary on abnormal exit;
# this journal is what lets the relaunched process pick up the thread.
fun journal_active_ptr() { session_dir() ++ "/.active" }

# Serialize history (minus the system message) to JSONL text.
fun encode_journal(history) {
    encode_journal_loop(history, "")
}

fun encode_journal_loop(msgs, acc) {
    if (length(msgs) == 0) { acc }
    else {
        entry = hd(msgs)
        role = elem(entry, 0)
        content = elem(entry, 1)
        if (role == 'system') {
            encode_journal_loop(tl(msgs), acc)
        } else {
            line = json_encode([to_string(role), content]) ++ "\n"
            encode_journal_loop(tl(msgs), acc ++ line)
        }
    }
}

# Atomically rewrite the journal to match the current in-memory
# history. Rewrite (not append) so /reset and /compact keep the
# journal in sync. temp + rename means a crash mid-write can never
# truncate the real journal — it's all-or-nothing.
fun journal_sync(opts, history) {
    jp = map_get(opts, 'journal_path')
    if (jp == nil) { 'ok' }
    else {
        tmp = jp ++ ".tmp"
        file_write(tmp, encode_journal(history))
        shell("mv " ++ tmp ++ " " ++ jp)
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
            pair = json_decode(ln)
            if (pair == nil) {
                replay_lines(tl(lines), acc)
            } else { if (length(pair) < 2) {
                replay_lines(tl(lines), acc)
            } else {
                role = string_to_role(to_string(hd(pair)))
                body = hd(tl(pair))
                replay_lines(tl(lines), list_append(acc, {role, body}))
            }}
        }
    }
}

# Drop a trailing assistant message that still carries unexecuted
# `call:` markers — the turn crashed before the tools ran, so the
# tool_calls have no matching results. Leaving it would desync the
# native-mode protocol on the next request.
fun trim_incomplete(msgs) {
    if (length(msgs) == 0) { msgs }
    else {
        last = hd(take_last(msgs, 1))
        role = elem(last, 0)
        content = to_string(elem(last, 1))
        if (role == 'assistant' && string_contains(content, "\ncall:") == 'true') {
            drop_last(msgs, 1)
        } else { msgs }
    }
}

# Mark the session cleanly ended — drop the .active pointer so the
# next launch doesn't think we crashed.
fun journal_clean(opts) {
    ap = journal_active_ptr()
    if (file_exists(ap) == 'true') { file_delete(ap) }
    'ok'
}

# ------------------------------------------------------------
# Entry point — called from Main.main once config is ready.
#
# This registers the current process as 'main_agent' so the
# heartbeat, background workers, and reader can all send messages
# here. Then it spawns the reader process (which forwards stdin as
# {'user_input', line} messages) and enters the receive-based
# continuous loop.
#
# opts: %{endpoint, model, api_key, cwd, memory_table, bg_table,
#         heartbeat_table, settings, buddy?, ...}
# system_prompt_text: assembled system prompt
# ------------------------------------------------------------
fun run(opts, system_prompt_text) {
    register('main_agent', self())

    # --- Crash-recovery journal: set up / resume ---
    jdir = session_dir()
    shell("mkdir -p " ++ jdir)
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
        # Crashed last run — keep appending to the same journal.
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
        prepend([{'system', system_prompt_text}], resumed)
    } else {
        [{'system', system_prompt_text}]
    }
    # Normalize the journal to the (possibly trimmed) resumed state.
    journal_sync(opts_journal, history)

    reader_pid = Reader.start()
    print("")
    # Kick off the first prompt — tells reader to draw the box and read.
    # Messages sent before the target runs `receive` queue in its mailbox.
    if (reader_pid != nil) {
        send(reader_pid, {'draw_and_read'})
    }
    opts_with_reader = map_put(opts_journal, 'reader_pid', reader_pid)
    main_loop(history, opts_with_reader)
}

# ------------------------------------------------------------
# Headless entry — `swarm -p "<prompt>"`.
#
# Runs ONE task to completion with no Reader, no input box, no
# banner, then exits. `route_input` -> `run_turn` already recurses
# through every tool step until the model emits no more tool calls,
# so this is a real agentic run to task completion, not one turn.
#
# Permissions auto-accept: opts.headless gates resolve_permission so
# an 'ask' tool isn't denied (there's no human/Reader to prompt). An
# explicit `-p` invocation IS the opt-in to autonomous execution.
#
# Journal resume still applies — the agent's prior session carries
# over across invocations. That's swarm-code's native persistence,
# and it makes `swarm -p` a drop-in persistent worker for an
# orchestrator with zero extra plumbing.
#
# json_mode 'true' -> emit one final {"status","summary"} line for
# programmatic callers; otherwise just the streamed work + a plain
# exit code.
# ------------------------------------------------------------
fun run_headless(opts, system_prompt_text, prompt, json_mode) {
    register('main_agent', self())

    jdir = session_dir()
    shell("mkdir -p " ++ jdir)
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
        prepend([{'system', system_prompt_text}], resumed)
    } else {
        [{'system', system_prompt_text}]
    }
    journal_sync(opts_journal, history)

    # Headless: auto-accept permissions, no reader_pid in opts.
    opts_h = map_put(opts_journal, 'headless', 'true')

    final_history = route_input(prompt, history, opts_h)
    journal_sync(opts_h, final_history)

    last_text = last_assistant_text(final_history)
    ok = if (string_length(last_text) > 0) { 'true' } else { 'false' }
    if (json_mode == 'true') {
        status = if (ok == 'true') { "ok" } else { "error" }
        print(json_encode(%{status: status, summary: last_text}))
    } else {
        ""
    }
    # main() returning exits 0; sys_exit(1) marks a failed run.
    if (ok == 'true') { "" } else { sys_exit(1) }
}

# Text of the last assistant message in history, or "" if none.
fun last_assistant_text(history) {
    last_assistant_loop(history, "")
}

fun last_assistant_loop(msgs, acc) {
    if (length(msgs) == 0) { acc }
    else {
        m = hd(msgs)
        na = if (elem(m, 0) == 'assistant') { to_string(elem(m, 1)) } else { acc }
        last_assistant_loop(tl(msgs), na)
    }
}

# ------------------------------------------------------------
# The continuous loop.
# ------------------------------------------------------------
# Instead of blocking on read_line, we `receive` messages from:
#   - Reader process:    {'user_input', line}   {'eof'}
#   - Heartbeat process: {'heartbeat_tick', count}
#   - Background workers:{'bg_done', task_id, exit_code, label}
#
# `after 15000` fires if nothing happens for 15 seconds — a quiet
# idle period where we can do background checks.
fun main_loop(history, opts) {
    next_state = receive {
        {'user_input', line} ->
            handle_user_input_msg(line, history, opts)
        {'heartbeat_tick', count} ->
            on_heartbeat_tick(count, history, opts)
        {'bg_done', task_id, exit_code, label} ->
            on_bg_done(task_id, exit_code, label, history, opts)
        {'agent_spawned', name} ->
            on_agent_spawned(name, history, opts)
        {'agent_emit', name, content} ->
            on_agent_emit(name, content, history, opts)
        {'agent_reply', name, content} ->
            on_agent_reply(name, content, history, opts)
        {'agent_died', name, reason} ->
            on_agent_died(name, reason, history, opts)
        {'stream_chunk', name, content} ->
            UI.stream_chunk_render(opts, to_string(name), to_string(content))
            history
        {'stream_reason', name, content} ->
            UI.stream_reason_render(opts, to_string(name), to_string(content))
            history
        {'stream_done', name} ->
            UI.stream_done_render(opts, to_string(name))
            history
        {'eof'} ->
            handle_eof(history, opts)
        _other ->
            history
        after 15000 {
            on_idle(history, opts)
        }
    }
    # Journal backstop: persist whenever the event changed history.
    # A length delta covers appends, compaction, and /reset. Idle
    # heartbeat ticks leave history untouched and skip the write.
    # Mid-turn durability is handled by run_turn / execute_all, which
    # journal after every assistant message and tool result.
    if (length(next_state) != length(history)) {
        journal_sync(opts, next_state)
    }
    main_loop(next_state, opts)
}

# ------------------------------------------------------------
# Swarm event handlers
# ------------------------------------------------------------
# These fire when a subagent says something main wasn't blocking on
# (the blocking case is handled inside Agents.ask_tool's selective
# receive). Each renders a one-line notice and returns history
# unchanged — the main agent's session isn't on the hook to respond.
# Subagent activity becomes visible in the user's stream alongside
# main's own output.

fun on_agent_spawned(name, history, opts) {
    UI.agent_emit_render(opts, to_string(name), "spawned")
    history
}

fun on_agent_emit(name, content, history, opts) {
    UI.agent_emit_render(opts, to_string(name), to_string(content))
    history
}

# A reply that arrives unprompted (i.e. main wasn't in ask_tool's
# selective receive) means an agent finished a `tell`'d task. Surface
# it the same way as an emit, with a subtle "[done]" prefix so the user
# sees it landed.
fun on_agent_reply(name, content, history, opts) {
    UI.agent_reply_render(opts, to_string(name), to_string(content))
    history
}

fun on_agent_died(name, reason, history, opts) {
    rs = to_string(reason)
    # `stopped` is the normal end-of-fanout teardown — parallel_tool
    # spawns N agents, gathers replies, then explicitly stops them.
    # Rendering that as "died (stopped)" reads like a crash. Show it
    # as completion. `killed` is a deliberate hard-kill — neutral, not
    # alarming. Any other reason (panic, error) stays loud so a real
    # anomaly is visible.
    if (rs == "stopped" || rs == "normal" || rs == "ok") {
        UI.agent_emit_render(opts, to_string(name), UI.green() ++ "✓ done" ++ UI.reset())
    } else { if (rs == "killed") {
        UI.agent_emit_render(opts, to_string(name), UI.grey_text() ++ "■ killed" ++ UI.reset())
    } else {
        UI.agent_emit_render(opts, to_string(name), UI.err_color() ++ "died" ++ UI.reset() ++ " (" ++ rs ++ ")")
    }}
    UI.agent_block_leave(opts)
    history
}

# Handle a user_input message: run the turn, return the new history.
fun handle_user_input_msg(line, history, opts) {
    Log.user_input(line)
    # A new user turn — close any subagent block left open from before.
    UI.agent_block_leave(opts)
    # Close the input box with the bottom border + footer, then run the turn.
    UI.input_box_bottom_full(to_string(map_get(opts, 'model')), display_tokens(history, opts), context_budget_tokens())
    post_input_history = route_input(line, history, opts)
    print("")
    # Tell reader to draw the next input box and start reading again.
    reader_pid = map_get(opts, 'reader_pid')
    if (reader_pid != nil) {
        send(reader_pid, {'draw_and_read'})
    }
    post_input_history
}

# Route input through slash-command handler or LLM turn.
fun route_input(line, history, opts) {
    trimmed = string_trim(line)
    if (string_length(trimmed) == 0) {
        history
    } else {
        if (trimmed == "/quit") {
            handle_eof(history, opts)
        } else {
            if (trimmed == "/exit") {
                handle_eof(history, opts)
            } else {
                if (trimmed == "/reset") {
                    print("\e[2m[history reset]\e[0m")
                    [hd(history)]
                } else {
                    if (string_starts_with(trimmed, "/") == 'true') {
                        slash_dispatch(trimmed, history, opts)
                    } else {
                        Config.run_hooks("UserPromptSubmit", 'user', line, opts)
                        user_buddy = map_get(opts, 'buddy')
                        if (user_buddy != nil) {
                            if (Arthopod.is_addressed(line, user_buddy) == 'true') {
                                bubble = Arthopod.address_response(user_buddy, line, opts)
                                Arthopod.render_with_bubble(user_buddy, bubble)
                            }
                        }
                        new_hist = list_append(history, {'user', line})
                        # Compact BEFORE the turn, not after, so the LLM call
                        # runs on a slim context instead of burning tokens on
                        # the bloated history we're about to discard anyway.
                        pre_turn_hist = if (length(new_hist) > compact_threshold()) {
                            print("\e[2m[auto-compacting " ++ to_string(length(new_hist)) ++ " messages]\e[0m")
                            compact_history(new_hist, opts)
                        } else {
                            new_hist
                        }
                        run_turn(pre_turn_hist, opts, 0)
                    }
                }
            }
        }
    }
}

# Heartbeat tick handler — silent by default. Could do proactive
# work: save state, check bg tasks, self-reflect.
# Cognitive pulse — the daemon's heartbeat.
#
# Every pulse_interval ticks, if daemon mode is on, we inject a short
# system-level prompt asking the model to assess whether action is needed.
# The model sees recent history + any pending state and decides:
#   - "idle" → go back to sleep (no cost, no output)
#   - take action → call tools, notify user
#
# This is NOT a CC Stop Hook (which fires after a turn). This is a
# timer-driven self-prompt that fires even when the user is AFK.
# The heartbeat ticks every 2s; we pulse every 30 ticks = ~60s.
fun pulse_interval() { 30 }

fun on_heartbeat_tick(count, history, opts) {
    daemon = map_get(opts, 'daemon')
    if (daemon != 'true') {
        history
    } else {
        # Only pulse every Nth tick
        interval = pulse_interval()
        remainder = count - ((count / interval) * interval)
        if (remainder != 0) {
            history
        } else {
            # Don't pulse if we're already inside a wake chain or a turn
            in_wake = map_get(opts, 'in_wake_chain')
            if (in_wake == 'true') { history }
            else {
                cognitive_pulse(count, history, opts)
            }
        }
    }
}

fun cognitive_pulse(tick_count, history, opts) {
    # Gather context for the pulse
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

    # Use chat_silent to avoid streaming pulse deliberation to the terminal.
    # We only show output if the model decides to act.
    pulse_msgs = list_append(history, {'user', pulse_msg})
    wake_opts = map_put(opts, 'in_wake_chain', 'true')
    response = LLM.chat_silent(pulse_msgs, wake_opts)

    if (response == nil) {
        history
    } else {
        trimmed = string_trim(to_string(response))
        # Require an exact "idle" (with optional trailing punctuation /
        # whitespace) instead of a `startsWith` prefix — otherwise a
        # legit response like "Idle servers detected; restarting now."
        # gets swallowed and the action never runs.
        lower = string_lower(trimmed)
        is_idle = if (lower == "idle") { 'true' }
                  else { if (lower == "idle.") { 'true' }
                  else { 'false' }}
        if (is_idle == 'true') {
            # Model says nothing to do — stay quiet
            history
        } else {
            # Model wants to act — show a subtle indicator and run the turn
            print("")
            print("\e[2m[daemon pulse — acting autonomously]\e[0m")
            with_pulse = list_append(history, {'user', pulse_msg})
            with_response = list_append(with_pulse, {'assistant', trimmed})
            # Check if response contains tool calls
            tool_calls = extract_tool_calls(trimmed)
            if (length(tool_calls) == 0) {
                # Just a message, show it
                print("  " ++ UI.grey_text() ++ trimmed ++ UI.reset())
                print("")
                with_response
            } else {
                # Has tool calls — execute them
                post_exec = execute_all(tool_calls, with_response, wake_opts)
                post_exec
            }
        }
    }
}

# Background task completion handler — visible notification.
fun on_bg_done(task_id, exit_code, label, history, opts) {
    Log.bg_done(task_id, exit_code, label)
    color = if (exit_code == 0) { UI.brand_color() } else { "\e[31m" }
    print_above("")
    print_above(color ++ "⏺" ++ UI.reset() ++ " \e[1mbg_done\e[0m " ++ task_id ++
          "  \e[2mexit " ++ to_string(exit_code) ++ " · " ++ label ++ "\e[0m")
    print_above("")

    # If autonomy is enabled AND we're not already inside a wake-up chain,
    # inject the event as a synthetic user message and invoke the LLM so
    # the model can acknowledge / react / take follow-up action. This is
    # what makes swarm-code actually autonomous — the model sees background
    # events and decides whether to speak or act without waiting for user.
    autonomy = map_get(opts, 'autonomy')
    in_wake = map_get(opts, 'in_wake_chain')
    if (autonomy == 'true' && in_wake != 'true') {
        # Pull a short log preview so the model has context for its decision.
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
        with_wake = list_append(history, {'user', wake_msg})
        # Mark we're in a wake chain so a response that triggers another
        # bg_done doesn't cascade infinitely.
        wake_opts = map_put(opts, 'in_wake_chain', 'true')
        after_wake = run_turn(with_wake, wake_opts, 0)
        after_wake
    } else {
        print("  \e[38;5;240m⎿\e[0m  \e[38;5;244muse bg_result " ++ task_id ++ " to see output\e[0m")
        print("")
        history
    }
}

# EOF / /quit handler — farewell and exit.
fun handle_eof(history, opts) {
    bye_b = map_get(opts, 'buddy')
    if (bye_b != nil) {
        Arthopod.render_with_bubble(bye_b, Arthopod.farewell_line(bye_b))
    }
    Log.session_end("user_exit")
    Config.run_hooks("Stop", 'session', "{}", opts)
    # Close MCP server subprocesses before exit — sys_exit(0) below
    # would otherwise orphan them (they'd reparent to init and linger).
    Mcp.shutdown(map_get(opts, 'mcp_table'))
    # Clean exit — drop the .active pointer so the next launch doesn't
    # mistake this for a crash and replay the journal.
    journal_clean(opts)
    sys_exit(0)
    history
}

# Idle handler — fires when no messages in `after` window. For v1 no
# visible work; future: summarize recent activity, commit memory.
fun on_idle(history, opts) {
    history
}

# Slash-command dispatch. Returns the new history (most commands return
# it unchanged; /reset, /compact, /resume change it).
fun slash_dispatch(cmd, history, opts) {
    if (cmd == "/help") {
        show_help()
        history
    }
    else { if (cmd == "/tools") {
        print("available: bash, read, write, edit, multi_edit, glob, grep, todo_write, web_fetch, task, remember, recall, background, bg_status, bg_result, bg_server, bg_tail, bg_kill, sys_stats, heartbeat_status")
        print("browser: browser_launch, browser_navigate, browser_click, browser_type, browser_screenshot, browser_get_text, browser_get_html, browser_evaluate, browser_close")
        print("swarm: spawn_agent, ask, tell, list_agents, kill, parallel")
        print(UI.grey_text() ++ "MCP tools (if any) are listed by /mcp" ++ UI.reset())
        history
    }
    else { if (cmd == "/status") {
        show_status(history, opts)
        history
    }
    else { if (cmd == "/clear") {
        print_inline("\e[2J\e[H")
        history
    }
    else { if (cmd == "/history") {
        show_history(history)
        history
    }
    else { if (cmd == "/tokens") {
        tok_count = approx_tokens(history)
        print("approx tokens in history: " ++ to_string(tok_count))
        history
    }
    else { if (cmd == "/model") {
        show_model_info(opts)
        history
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
    else { if (cmd == "/sessions") {
        list_sessions()
        history
    }
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
    else { if (cmd == "/telemetry") {
        print(Log.tail_recent(30))
        history
    }
    else { if (cmd == "/stats") {
        print(Log.summarize())
        history
    }
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
        # Manual trigger for low-frequency LLM reflection. Feeds recent
        # history + an instruction to review what happened and suggest
        # next steps. Adds the reflection as a fresh user message so the
        # next turn picks it up naturally.
        print("\e[2m[reflecting — this is a separate LLM call, will take a moment]\e[0m")
        reflect_msg =
            "REFLECTION REQUEST: Review the conversation so far. " ++
            "Briefly summarize: (1) what we've done, (2) what's still open, " ++
            "(3) one or two concrete next steps you'd suggest. Be terse. " ++
            "This is a self-review — no tool calls, just prose."
        with_reflect = list_append(history, {'user', reflect_msg})
        run_turn(with_reflect, opts, 0)
    }
    else { if (cmd == "/buddy") {
        print_inline("buddy is ")
        current = map_get(opts, 'buddy')
        if (current == nil) {
            print("OFF. restart with SWARM_CODE_BUDDY=1 to enable for this session,")
            print("or add \"buddy_enabled\": true to ~/.swarm-code/settings.json to make it permanent.")
        } else {
            name = to_string(map_get(current, 'name'))
            species = to_string(map_get(current, 'species'))
            print("ON. " ++ name ++ " (" ++ species ++ ") is watching.")
        }
        history
    }
    else { if (cmd == "/agents") {
        print(Agents.list_tool(map_new(), opts))
        history
    }
    else { if (cmd == "/mcp") {
        print(Mcp.list_servers(map_get(opts, 'mcp_table')))
        history
    }
    else {
        print("\e[33munknown command: " ++ cmd ++ "\e[0m  (type /help)")
        history
    }}}}}}}}}}}}}}}}}}}}}
}

fun show_help() {
    print("\e[1mcommands\e[0m")
    print("  /help                 show this help")
    print("  /status               session info")
    print("  /tools                list available tools")
    print("  /todos                show todo list")
    print("  /agents               list live subagents (swarm)")
    print("  /mcp                  list MCP servers and their tools")
    print("  /model                show active model")
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

# Probe the server's /v1/models endpoint and show what's actually
# loaded on the host, alongside the client-side limits. Useful for
# verifying a fresh serving restart took effect (e.g., after
# switching to multi-GPU tensor-parallel or bumping max context).
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
    if (length(msgs) == 0) {
        'ok'
    } else {
        entry = hd(msgs)
        role = elem(entry, 0)
        content = elem(entry, 1)
        truncated = preview_string(content, 200)
        print("\e[2m[" ++ to_string(i) ++ "] " ++ to_string(role) ++ ":\e[0m " ++ truncated)
        print_msgs(tl(msgs), i + 1)
    }
}

# Token count for footer display. Prefers the server-reported
# prompt_tokens from the last LLM response (exact number the model
# saw) and falls back to a 4-char-per-token estimate on the first
# turn of a session before we've made any calls.
fun display_tokens(history, opts) {
    last_pt = LLM.last_prompt_tokens(opts)
    if (last_pt != nil) { last_pt }
    else {
        total = sum_msg_chars(history, 0)
        total / 4
    }
}

# Legacy char-estimate, kept for the few call sites that don't have
# opts handy (status commands, etc).
fun approx_tokens(history) {
    total = sum_msg_chars(history, 0)
    total / 4
}

fun sum_msg_chars(msgs, acc) {
    if (length(msgs) == 0) {
        acc
    } else {
        entry = hd(msgs)
        content = elem(entry, 1)
        sum_msg_chars(tl(msgs), acc + string_length(content))
    }
}

# ------------------------------------------------------------
# Compaction — summarize oldest messages via an LLM call, replace
# them with a single synthetic assistant "summary" message.
# ------------------------------------------------------------
fun compact_history(history, opts) {
    # Keep system message + last 16 messages untouched. Summarize the rest.
    # 16 ≈ 5 tool turns (user+assistant+result each). Keeps recent findings
    # fresh so the model can recall specific values (keys, paths, IPs).
    if (length(history) < 10) {
        history
    } else {
        sys_msg = hd(history)
        rest = tl(history)
        keep_tail = take_last(rest, 16)
        # Earlier this dropped 8, which meant the same 8 messages
        # appeared both in the summary AND the kept tail. Use 16 to
        # match keep_tail so the two slices are disjoint.
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
            {'system', "You are a concise summarizer."},
            {'user', summary_prompt}
        ]
        # IMPORTANT: use chat_silent here — compaction is an internal
        # operation; its output must NOT stream to the user's terminal.
        # Previously we used LLM.chat which streamed the summary on top
        # of the user's view, making it look like the assistant replied
        # to the user with a compaction summary.
        summary = LLM.chat_silent(ask_msgs, opts)
        summary_text = if (summary == nil) {
            "[compaction failed, messages elided]"
        } else { summary }

        synth = {'assistant', "Summary of earlier conversation: " ++ summary_text}

        # Rebuild: system + synth summary + tail
        prepend([sys_msg, synth], keep_tail)
    }
}

fun take_last(lst, n) {
    if (length(lst) <= n) {
        lst
    } else {
        take_last(tl(lst), n)
    }
}

fun drop_last(lst, n) {
    keep_count = length(lst) - n
    take_first(lst, keep_count, [])
}

fun take_first(lst, n, acc) {
    if (n <= 0) {
        acc
    } else {
        if (length(lst) == 0) {
            acc
        } else {
            take_first(tl(lst), n - 1, list_append(acc, hd(lst)))
        }
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
    } else {
        acc
    }
}

fun list_at(lst, i) {
    if (i == 0) { hd(lst) }
    else { list_at(tl(lst), i - 1) }
}

fun format_for_summary(msgs, acc) {
    if (length(msgs) == 0) { acc }
    else {
        entry = hd(msgs)
        role = elem(entry, 0)
        content = elem(entry, 1)
        line = "[" ++ to_string(role) ++ "] " ++ preview_string(content, 500) ++ "\n"
        format_for_summary(tl(msgs), acc ++ line)
    }
}

# ------------------------------------------------------------
# Session persistence — save/load to ~/.swarm-code/sessions/
# Format: JSON list of [role_string, content] pairs.
# ------------------------------------------------------------
fun save_session(history, opts) {
    dir = session_dir()
    shell("mkdir -p " ++ dir)
    ts = to_string(timestamp())
    path = dir ++ "/session-" ++ ts ++ ".json"
    encoded = encode_history(history)
    file_write(path, encoded)
    path
}

fun encode_history(history) {
    pairs = history_to_pairs(history, [])
    json_encode(pairs)
}

fun history_to_pairs(msgs, acc) {
    if (length(msgs) == 0) { acc }
    else {
        entry = hd(msgs)
        role = to_string(elem(entry, 0))
        content = elem(entry, 1)
        as_pair = [role, content]
        history_to_pairs(tl(msgs), list_append(acc, as_pair))
    }
}

fun load_latest_session(opts) {
    dir = session_dir()
    list_cmd = "ls -t " ++ dir ++ "/session-*.json 2>/dev/null | head -1"
    result = shell(list_cmd)
    out = string_trim(elem(result, 1))
    if (string_length(out) == 0) {
        []
    } else {
        content = file_read(out)
        if (content == nil) { [] }
        else { decode_history(content) }
    }
}

fun decode_history(json_str) {
    pairs = json_decode(json_str)
    if (pairs == nil) { [] }
    else { pairs_to_history(pairs, []) }
}

fun pairs_to_history(pairs, acc) {
    if (length(pairs) == 0) { acc }
    else {
        p = hd(pairs)
        role_str = hd(p)
        content = hd(tl(p))
        tup = {string_to_role(role_str), content}
        pairs_to_history(tl(pairs), list_append(acc, tup))
    }
}

fun string_to_role(s) {
    if (s == "system") { 'system' }
    else { if (s == "user") { 'user' }
    else { if (s == "assistant") { 'assistant' }
    else { 'user' }}}
}

fun list_sessions() {
    dir = session_dir()
    cmd = "ls -t " ++ dir ++ "/session-*.json 2>/dev/null | head -20"
    result = shell(cmd)
    out = elem(result, 1)
    if (string_length(out) == 0) {
        print("(no sessions)")
    } else {
        print(out)
    }
}

# ------------------------------------------------------------
# One turn: call LLM, handle tool calls, recurse until the
# assistant produces a response with no tool calls.
# Returns the updated history.
# ------------------------------------------------------------
# Sum the character length of every message body in history. Cheap
# proxy for context size; real tokens are ~4x smaller.
fun history_chars(history) {
    history_chars_loop(history, 0)
}

fun history_chars_loop(h, acc) {
    if (length(h) == 0) { acc }
    else {
        entry = hd(h)
        content = elem(entry, 1)
        n = if (content == nil) { 0 } else { string_length(to_string(content)) }
        history_chars_loop(tl(h), acc + n)
    }
}

fun run_turn(history, opts, step) {
    if (step >= max_steps()) {
        print("\e[33m[warn] max tool steps reached\e[0m")
        history
    } else {
        # Preflight context budget check. Uses the server-reported
        # prompt_tokens from the previous LLM response when available
        # (exact count, same number the model sees) and falls back to
        # char estimate on the very first turn of a session.
        #
        # Trigger matches Claude Code's pattern: max_tokens - output
        # reserve - safety buffer. Tunable via SWARM_CODE_MAX_TOKENS,
        # SWARM_CODE_OUTPUT_RESERVE, SWARM_CODE_COMPACT_BUFFER env vars.
        last_pt = LLM.last_prompt_tokens(opts)
        budget_t = context_budget_tokens()
        over_budget = if (last_pt != nil) {
            if (last_pt > budget_t) { 'true' } else { 'false' }
        } else {
            # First turn, no server stats yet — char fallback.
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

        content = LLM.chat(working_hist, opts)
        debug_env = getenv("SWARM_CODE_DEBUG")
        if (debug_env == "1" && content != nil) {
            print("\e[2m[debug raw content]\n" ++ content ++ "\n[/debug]\e[0m")
        }
        if (content == nil) {
            print("\e[31m[error] llm call failed\e[0m")
            working_hist
        } else {
            with_assistant = list_append(working_hist, {'assistant', content})
            journal_sync(opts, with_assistant)
            tool_calls = extract_tool_calls(content)
            if (length(tool_calls) == 0) {
                visible = string_trim(content)
                if (string_length(visible) == 0) {
                    # Empty response — distinguish context blowup from
                    # a genuine "model had nothing to say".
                    last_pt2 = LLM.last_prompt_tokens(opts)
                    if (last_pt2 != nil && last_pt2 > context_budget_tokens() - 2000) {
                        print("  \e[38;5;240m(empty response — context near budget at " ++
                              to_string(last_pt2) ++ " tokens. Try /reset or a tighter query.)\e[0m")
                    } else {
                        # Reasoning-model failure mode: model emitted only
                        # `reasoning_content` and no spoken `content`. The
                        # streamed thinking is already visible above, so
                        # tell the user that's what happened — not "rephrase".
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
# For bash show the command, for read/write/edit show the path, etc.
# (Each branch uses unique var names to avoid sw's cross-branch scoping quirk.)
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

# Helper used by format_tool_args to accept either 'path' or 'file_path'
fun resolve_path_key(args_map) {
    rp = map_get(args_map, 'path')
    if (rp != nil) { rp } else { map_get(args_map, 'file_path') }
}

# Dispatch a tool call. Three families:
#   - 'task'                                 → in-module synchronous subagent (legacy)
#   - 'spawn_agent' / 'ask' / 'tell' /       → studio model (Agents module): long-lived
#     'list_agents' / 'kill' / 'parallel'      addressable subagents. Run inline — they
#                                              depend on running in this process for
#                                              subagent message routing.
#   - everything else                        → Tools.exec, run in an isolated worker
#                                              process (see exec_tool_isolated) so a
#                                              panicking tool can't take down the REPL.
fun dispatch_tool(name, args, opts) {
    if (name == 'task')         { handle_task_tool(args, opts) }
    else { if (name == 'spawn_agent')  { Agents.spawn_tool(args, opts) }
    else { if (name == 'ask')          { Agents.ask_tool(args, opts) }
    else { if (name == 'tell')         { Agents.tell_tool(args, opts) }
    else { if (name == 'list_agents')  { Agents.list_tool(args, opts) }
    else { if (name == 'kill')         { Agents.kill_tool(args, opts) }
    else { if (name == 'parallel')     { Agents.parallel_tool(args, opts) }
    else {
        # Browser tools hold a persistent CDP/WebSocket connection in
        # browser_table; a throwaway worker process would orphan it, so
        # they run inline. Everything else runs isolated.
        if (string_starts_with(to_string(name), "browser_") == 'true') {
            Tools.exec(name, args, opts)
        } else {
            exec_tool_isolated(name, args, opts)
        }
    }}}}}}}
}

# ------------------------------------------------------------
# Isolated tool execution
# ------------------------------------------------------------
# A tool is plain sw code, and a bug in it — or a builtin it calls on
# bad data (elem on a non-tuple, hd of [], a divide by zero) — can
# panic. panic is uncatchable in-process: run inside the main agent
# process it unwinds all the way out and kills the whole REPL.
#
# So Tools.exec tools run in a short-lived linked worker process. If
# the tool panics, only the worker dies; we trap the {'EXIT', ...}
# signal and hand the model an error string it can react to — exactly
# like any other failed tool call — instead of the session crashing.
fun exec_tool_isolated(name, args, opts) {
    trap_exit('true')
    w = spawn(tool_worker(self(), name, args, opts))
    link(w)
    collect_tool_result(name, nil)
}

# Worker process body: run the tool, ship the result home, exit.
fun tool_worker(parent, name, args, opts) {
    result = Tools.exec(name, args, opts)
    send(parent, {'tool_done', result})
}

# Collect from the worker. It emits at most one {'tool_done', result}
# and then — being linked — always an {'EXIT', _, reason} when it
# exits, normally or by panic. We loop until that EXIT (the last thing
# it can ever send), so nothing is stranded in the mailbox.
fun collect_tool_result(name, pending) {
    receive {
        {'tool_done', result} -> collect_tool_result(name, result)
        {'EXIT', _, ex_reason} ->
            # A tool_done means the tool produced a result — success,
            # whatever the worker's exit reason turns out to be. Only
            # an EXIT with no result behind it is a real crash; then
            # ex_reason is the panic message (or a bare code if the
            # worker died before we managed to link it).
            if (pending == nil) { tool_crash_msg(name, ex_reason) }
            else { pending }
    }
}

fun tool_crash_msg(name, reason) {
    "error: tool '" ++ to_string(name) ++ "' crashed: " ++ to_string(reason) ++
    "\n(a bug in the tool itself, not your input — try a different approach)"
}

# ------------------------------------------------------------
# Subagent via the Task tool
# ------------------------------------------------------------
# Matches Claude Code's Task tool: spawn a subagent with a focused
# prompt, run it to completion, return its final text response.
#
# Why this fits swarmrt: the runtime is built for spawn + receive.
# v1 runs the subagent synchronously in-process; a later version can
# flip to `spawn` for parallel subagents (swarmrt does up to 100K
# concurrent processes at ~100ns spawn cost).
#
# args: {"description": "...", "prompt": "...", "subagent_type": "explore|bash|general"}
fun handle_task_tool(args, opts) {
    prompt = map_get(args, 'prompt')
    subtype_opt = map_get(args, 'subagent_type')
    stype = if (subtype_opt == nil) { "general" } else { subtype_opt }

    if (prompt == nil) {
        "error: task tool requires a 'prompt' argument"
    } else {
        sub_sys = subagent_system_prompt(stype)
        sub_history = [{'system', sub_sys}, {'user', prompt}]
        result = run_subagent_loop(sub_history, opts, 0)
        "[subagent:" ++ stype ++ "]\n" ++ result
    }
}

fun subagent_max_steps() { 15 }

fun subagent_system_prompt(stype) {
    base = "You are a focused subagent spawned from swarm-code for a single " ++
           "task. Use tools as needed, then return a concise final answer. " ++
           "Call tools with: call:name{\"arg\":\"value\"}"
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

fun run_subagent_loop(history, opts, step) {
    if (step >= subagent_max_steps()) {
        "[subagent hit max steps without final answer]"
    } else {
        content = LLM.chat(history, opts)
        if (content == nil) {
            "[subagent llm call failed]"
        } else {
            tool_calls = extract_tool_calls(content)
            if (length(tool_calls) == 0) {
                strip_tool_blocks(content)
            } else {
                with_assistant = list_append(history, {'assistant', content})
                post_tools = subagent_exec_all(tool_calls, with_assistant, opts)
                run_subagent_loop(post_tools, opts, step + 1)
            }
        }
    }
}

fun subagent_exec_all(tool_calls, history, opts) {
    if (length(tool_calls) == 0) {
        history
    } else {
        tc = hd(tool_calls)
        name = elem(tc, 0)
        args_map = elem(tc, 1)
        # Subagents skip permission prompts and hooks to stay non-interactive.
        sub_result = dispatch_tool(name, args_map, opts)
        wrapped = "<tool_result>\n" ++ sub_result ++ "\n</tool_result>"
        new_hist = list_append(history, {'user', wrapped})
        subagent_exec_all(tl(tool_calls), new_hist, opts)
    }
}

# Execute each tool call in sequence, appending results to history.
# opts carries session state (todos_table, cwd, permissions, settings, ...).
#
# Permission + hook flow per tool:
#   1. check_permission → allow | deny | ask
#   2. If ask: prompt user, cache decision in perms_table
#   3. If denied: append a "permission denied" tool_result, skip hooks
#   4. Run PreToolUse hooks → if any block, append "blocked by hook"
#   5. Execute the tool
#   6. Run PostToolUse hooks (not blocking)
fun execute_all(tool_calls, history, opts) {
    if (length(tool_calls) == 0) {
        history
    } else {
        tc = hd(tool_calls)
        name = elem(tc, 0)
        args_map = elem(tc, 1)
        args_raw = elem(tc, 2)

        UI.tool_header(name, format_tool_args(name, args_map, args_raw))
        Log.tool_call(name, args_raw)

        # Permission gate.
        decision = resolve_permission(name, args_map, opts)
        if (decision == 'deny') {
            denial = "error: permission denied for tool '" ++ to_string(name) ++ "'"
            print("\e[31m" ++ denial ++ "\e[0m")
            hist_denied = list_append(history, {'user', "<tool_result>\n" ++ denial ++ "\n</tool_result>"})
            journal_sync(opts, hist_denied)
            execute_all(tl(tool_calls), hist_denied, opts)
        } else {
            # PreToolUse hooks.
            pre = Config.run_hooks("PreToolUse", name, args_raw, opts)
            if (pre == 'block') {
                blocked = "error: tool '" ++ to_string(name) ++ "' blocked by PreToolUse hook"
                print("\e[31m" ++ blocked ++ "\e[0m")
                hist_blocked = list_append(history, {'user', "<tool_result>\n" ++ blocked ++ "\n</tool_result>"})
                journal_sync(opts, hist_blocked)
                execute_all(tl(tool_calls), hist_blocked, opts)
            } else {
                result = dispatch_tool(name, args_map, opts)
                UI.tool_result(result)
                had_err = if (string_starts_with(result, "error:") == 'true') { 'true' } else { 'false' }
                Log.tool_result(name, string_length(result), had_err)

                Config.run_hooks("PostToolUse", name, args_raw, opts)

                wrapped = "<tool_result>\n" ++ result ++ "\n</tool_result>"
                hist_ok = list_append(history, {'user', wrapped})
                journal_sync(opts, hist_ok)
                execute_all(tl(tool_calls), hist_ok, opts)
            }
        }
    }
}

# Resolve a permission, possibly prompting the user. Caches 'ask' answers
# in opts.perms_table so the same tool+action isn't asked twice per session.
#
# The prompt is delegated to the Reader process via {'permission_ask',
# prompt, reply_pid} — Reader is the ONLY process that's allowed to call
# read_line, so there's no race between its main-input read_line and a
# concurrent permission read_line. We wait for {'permission_answer', ans}
# back before returning.
fun resolve_permission(name, args, opts) {
    raw = Config.check_permission(name, args, opts)
    if (raw == 'allow') { 'allow' }
    else { if (raw == 'deny') { 'deny' }
    else {
        # 'ask' — headless mode has no human/Reader to prompt, so it
        # auto-accepts. An explicit `swarm -p` IS the opt-in to
        # autonomous execution (mirrors `claude -p --dangerously-
        # skip-permissions`). Interactive mode prompts as before.
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

# Delegate the permission prompt to the Reader process via the
# interactive arrow-key picker (matching Claude Code's UX). Reader
# renders the choices, handles up/down + Enter + Esc + 1-9 shortcuts,
# and sends back the selected index. Nested selective receive lets
# other messages (heartbeat, bg_done) wait in the mailbox.
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
        }
        interpret_picker(idx, table, cache_key)
    }
}

# Map the picker index back to an allow/deny decision. -1 = cancelled
# (Esc), treated as deny. 0 = Yes once. 1 = Yes + cache for session.
# 2 = No.
fun interpret_picker(idx, table, cache_key) {
    if (idx == 0) { 'allow' }
    else { if (idx == 1) {
        if (table != nil) { ets_put(table, cache_key, 'allow_session') }
        'allow'
    }
    else { 'deny' }}
}

# ------------------------------------------------------------
# Tool-call extraction: scan content for <tool_call>{...}</tool_call>
# blocks. Returns a list of {name_atom, args_map, raw_json} tuples.
# ------------------------------------------------------------
fun extract_tool_calls(content) {
    # Primary: Gemma 4 native call:name{json} via C builtin.
    native = parse_gemma_calls(content)
    native_converted = convert_native_calls(native, [])
    if (length(native_converted) > 0) { native_converted }
    else {
        # Fallback: <tool_call>{...}</tool_call> XML wrapper (legacy/other models).
        extract_loop(content, [])
    }
}

# Convert parse_gemma_calls output [{name_atom, args_map}, ...] to the
# standard [{name_atom, args_map, raw_json}, ...] format the executor expects.
fun convert_native_calls(calls, acc) {
    if (length(calls) == 0) { acc }
    else {
        tc = hd(calls)
        name = elem(tc, 0)
        args = elem(tc, 1)
        raw = json_encode(args)
        converted = {name, args, raw}
        convert_native_calls(tl(calls), list_append(acc, converted))
    }
}

fun extract_loop(content, acc) {
    if (string_contains(content, "<tool_call>") == 'false') {
        acc
    } else {
        block = extract_between(content, "<tool_call>", "</tool_call>")
        if (block == nil) {
            acc
        } else {
            parsed = parse_tool_block(block)
            new_acc = if (parsed == nil) { acc } else { list_append(acc, parsed) }
            rest = after_tag(content, "</tool_call>")
            extract_loop(rest, new_acc)
        }
    }
}

# (rescue_native_calls removed — replaced by C builtin parse_gemma_calls)

# Parse a single block (the raw JSON string inside the tags) into a
# {name_atom, args_map, raw_json_string} tuple. Returns nil on failure.
#
# Defensive: accepts multiple common arg key names (arguments/args/parameters/
# input) and falls back to top-level keys if the arguments object is missing,
# since Gemma 4 occasionally flattens simple calls.
fun parse_tool_block(block) {
    trimmed = string_trim(block)
    decoded = json_decode(trimmed)
    if (decoded == nil) {
        nil
    } else {
        name_str = map_get(decoded, 'name')
        if (name_str == nil) {
            nil
        } else {
            # Try multiple key names for the arguments object.
            args_from_arguments = map_get(decoded, 'arguments')
            args_from_args = map_get(decoded, 'args')
            args_from_params = map_get(decoded, 'parameters')
            args_from_input = map_get(decoded, 'input')
            chosen = if (args_from_arguments != nil) { args_from_arguments }
                     else { if (args_from_args != nil) { args_from_args }
                     else { if (args_from_params != nil) { args_from_params }
                     else { if (args_from_input != nil) { args_from_input }
                     else { nil }}}}

            # If still nothing, flatten: strip known meta keys, pass the rest as args.
            flat_args = if (chosen == nil) { flatten_top_level(decoded) } else { chosen }

            raw_json = if (flat_args == nil) { "{}" } else { json_encode(flat_args) }
            resolved_args = if (flat_args == nil) { map_new() } else { flat_args }
            {string_to_atom(name_str), resolved_args, raw_json}
        }
    }
}

# Build a map from decoded top-level keys minus the metadata ones (name/type/id).
# This handles calls like {"name":"bash","command":"ls"} where args aren't nested.
fun flatten_top_level(decoded) {
    keys = map_keys(decoded)
    vals = map_values(decoded)
    flatten_filter(keys, vals, map_new())
}

fun flatten_filter(keys, vals, acc) {
    if (length(keys) == 0) {
        if (length(map_keys(acc)) == 0) { nil } else { acc }
    } else {
        k = hd(keys)
        ks = to_string(k)
        skip = if (ks == "name") { 'true' }
               else { if (ks == "type") { 'true' }
               else { if (ks == "id") { 'true' }
               else { 'false' }}}
        new_acc = if (skip == 'true') { acc } else { map_put(acc, k, hd(vals)) }
        flatten_filter(tl(keys), tl(vals), new_acc)
    }
}

# Helper: find substring between two markers. Returns nil if either is missing.
fun extract_between(s, start_tag, end_tag) {
    if (string_contains(s, start_tag) == 'false') {
        nil
    } else {
        after_start = after_tag(s, start_tag)
        if (string_contains(after_start, end_tag) == 'false') {
            nil
        } else {
            before_end(after_start, end_tag)
        }
    }
}

# Return everything after the first occurrence of `tag`.
# Uses string_replace with a unique marker because string_sub needs an index
# and we don't have string_find. Cute hack: replace tag with a marker, then
# split on marker.
fun after_tag(s, tag) {
    marker = "\x01\x02SWMARK\x02\x01"
    replaced = string_replace(s, tag, marker)
    parts = string_split(replaced, marker)
    if (length(parts) < 2) {
        ""
    } else {
        hd(tl(parts))
    }
}

# Return everything BEFORE the first occurrence of `tag` in `s`.
fun before_end(s, tag) {
    marker = "\x01\x02SWMARK\x02\x01"
    replaced = string_replace(s, tag, marker)
    parts = string_split(replaced, marker)
    hd(parts)
}

# Rationale = text before the first <tool_call>.
fun rationale_prefix(content) {
    if (string_contains(content, "<tool_call>") == 'false') {
        content
    } else {
        before_end(content, "<tool_call>")
    }
}

# Strip all <tool_call>...</tool_call> blocks from content.
fun strip_tool_blocks(content) {
    if (string_contains(content, "<tool_call>") == 'false') {
        content
    } else {
        prefix = before_end(content, "<tool_call>")
        tail_part = after_tag(content, "</tool_call>")
        strip_tool_blocks(prefix ++ tail_part)
    }
}

# Convert a string value to an atom (for tool name dispatch).
fun string_to_atom(s) {
    if (s == "bash") { 'bash' }
    else { if (s == "read") { 'read' }
    else { if (s == "write") { 'write' }
    else { if (s == "edit") { 'edit' }
    else { if (s == "multi_edit") { 'multi_edit' }
    else { if (s == "glob") { 'glob' }
    else { if (s == "grep") { 'grep' }
    else { if (s == "todo_write") { 'todo_write' }
    else { if (s == "web_fetch") { 'web_fetch' }
    else { if (s == "task") { 'task' }
    else { if (s == "remember") { 'remember' }
    else { if (s == "recall") { 'recall' }
    else { if (s == "memory_list") { 'memory_list' }
    else { if (s == "forget") { 'forget' }
    else { if (s == "background") { 'background' }
    else { if (s == "bg_status") { 'bg_status' }
    else { if (s == "bg_result") { 'bg_result' }
    else { if (s == "bg_server") { 'bg_server' }
    else { if (s == "bg_tail") { 'bg_tail' }
    else { if (s == "bg_kill") { 'bg_kill' }
    else { if (s == "sys_stats") { 'sys_stats' }
    else { if (s == "heartbeat_status") { 'heartbeat_status' }
    else { if (s == "web_search") { 'web_search' }
    else { if (s == "git_status") { 'git_status' }
    else { if (s == "git_diff") { 'git_diff' }
    else { if (s == "git_commit") { 'git_commit' }
    else { if (s == "code_search") { 'code_search' }
    else { if (s == "log_wait") { 'log_wait' }
    else { if (s == "file_watch") { 'file_watch' }
    # Unrecognized name → return the raw string (not 'unknown'). This
    # lets MCP tool names (mcp__server__tool) survive the XML-inband
    # path: Tools.exec checks the mcp__ prefix on to_string(name), and
    # a genuinely-unknown tool still resolves to "error: unknown tool".
    else { s }
    }}}}}}}}}}}}}}}}}}}}}}}}}}}}
}

# Truncate string for inline preview.
fun preview_string(s, cap) {
    if (string_length(s) <= cap) {
        s
    } else {
        string_sub(s, 0, cap) ++ " ..."
    }
}
