module Agents

# ============================================================
# Agents — long-lived studio of subagents on swarmrt processes
# ============================================================
#
# A "swarm" of named, addressable, headless sw processes. The main
# agent (the one the user started) is the only TUI; subagents print
# nothing to stdout — all their output flows back as messages to main's
# mailbox and main's REPL renders them in a single stream.
#
# Each subagent:
#   * is a sw process running `agent_message_loop`
#   * has its own LLM session, history, role, goal, model, max_tokens,
#     and per-turn token-used accounting
#   * inherits the FULL Tools.exec dispatcher — same bash, read, write,
#     edit, grep, glob, etc. as main
#   * is registered by string name in an ETS `swarm_registry` table
#
# Public tool surface (called from agent.sw's dispatch_tool):
#   spawn_tool   — fire up a new agent
#   ask_tool     — send a task and BLOCK main until reply
#   tell_tool    — send a task fire-and-forget
#   list_tool    — render the registry
#   kill_tool    — terminate an agent (graceful or hard)
#   parallel_tool — spawn N + ask all + kill all (sugar over above)
#
# Message protocol main agent listens for (added in agent.sw):
#   {'agent_spawned', name}            — just registered
#   {'agent_reply',   name, content}   — full reply (resolves an `ask`)
#   {'agent_emit',    name, content}   — async push (mid-task discovery)
#   {'agent_died',    name, reason}    — graceful or crash teardown
#
# The registry table is created at session start by Main.main() and
# threaded through opts as 'swarm_registry'.

import LLM
import Tools
import UI
import Log

export [
    init,
    spawn_tool, ask_tool, tell_tool, list_tool, kill_tool, parallel_tool,
    registry_get, registry_list_names
]

# ------------------------------------------------------------
# Registry — ETS table keyed by name (string).
# Value is a map: %{pid, role, goal, status, model, max_tokens,
#                   tokens_used, spawned_at}.
# Status atoms: 'spawning' | 'idle' | 'working' | 'dying'
# ------------------------------------------------------------

fun init() { ets_new() }

# Lookup by name. Returns the entry map or nil.
fun registry_get(reg, name) {
    if (reg == nil) { nil } else { ets_get(reg, name) }
}

# Names of all live agents. Walks ets_list, skipping internal keys.
fun registry_list_names(reg) {
    if (reg == nil) { [] }
    else { collect_names(ets_list(reg), []) }
}

fun collect_names(entries, acc) {
    if (length(entries) == 0) { acc }
    else {
        e = hd(entries)
        k = elem(e, 0)
        # Skip nil and internal keys (none today, but defensive).
        is_internal = string_starts_with(to_string(k), "_")
        next_acc = if (is_internal == 'true') { acc } else { list_append(acc, k) }
        collect_names(tl(entries), next_acc)
    }
}

fun update_status(reg, name, new_status) {
    entry = ets_get(reg, name)
    if (entry == nil) { 'noop' }
    else { ets_put(reg, name, map_put(entry, 'status', new_status)) }
}

fun bump_tokens(reg, name, delta) {
    entry = ets_get(reg, name)
    if (entry == nil) { 'noop' }
    else {
        used = map_get(entry, 'tokens_used')
        cur = if (used == nil) { 0 } else { used }
        ets_put(reg, name, map_put(entry, 'tokens_used', cur + delta))
    }
}

# ------------------------------------------------------------
# spawn_tool — bring a new agent into existence
# args: %{name, role, goal, system_prompt?, model?, max_tokens?}
# ------------------------------------------------------------
fun spawn_tool(args, opts) {
    reg = map_get(opts, 'swarm_registry')
    name_v = map_get(args, 'name')
    role_v = map_get(args, 'role')
    goal_v = map_get(args, 'goal')

    if (reg == nil) { "error: swarm_registry not initialised" }
    else { if (name_v == nil) { "error: spawn_agent requires 'name'" }
    else { if (role_v == nil) { "error: spawn_agent requires 'role'" }
    else { if (goal_v == nil) { "error: spawn_agent requires 'goal'" }
    else {
        name = to_string(name_v)
        existing = ets_get(reg, name)
        if (existing != nil) {
            "error: agent '" ++ name ++ "' already exists — kill it first or pick a different name"
        } else {
            role = to_string(role_v)
            goal = to_string(goal_v)
            sys_p = map_get(args, 'system_prompt')
            sys_prompt = if (sys_p == nil) { "" } else { to_string(sys_p) }
            model_v = map_get(args, 'model')
            model = if (model_v == nil) { map_get(opts, 'model') } else { to_string(model_v) }
            mt_v = map_get(args, 'max_tokens')
            max_tokens = if (mt_v == nil) { agent_default_max_tokens() } else { to_int_safe(mt_v, agent_default_max_tokens()) }

            # Pre-register placeholder so concurrent spawns can't race.
            now = timestamp()
            ets_put(reg, name, %{
                pid: nil,
                role: role,
                goal: goal,
                status: 'spawning',
                model: model,
                max_tokens: max_tokens,
                tokens_used: 0,
                spawned_at: now
            })
            spawn(agent_message_loop(reg, name, role, goal, sys_prompt, opts, []))
            "ok: spawned '" ++ name ++ "' (role=" ++ role ++ ", model=" ++ to_string(model) ++ ")"
        }
    }}}}
}

fun agent_default_max_tokens() {
    e = getenv("SWARM_CODE_AGENT_MAX_TOKENS")
    if (e == nil) { 65000 } else { to_int_safe(e, 65000) }
}

fun to_int_safe(v, fallback) {
    s = to_string(v)
    n = parse_pos_int(s, 0, 0, 'false')
    if (n < 0) { fallback } else { n }
}

fun parse_pos_int(s, i, acc, saw) {
    if (i >= string_length(s)) {
        if (saw == 'true') { acc } else { 0 - 1 }
    } else {
        ch = string_sub(s, i, 1)
        d = if (ch == "0") { 0 } else { if (ch == "1") { 1 }
            else { if (ch == "2") { 2 } else { if (ch == "3") { 3 }
            else { if (ch == "4") { 4 } else { if (ch == "5") { 5 }
            else { if (ch == "6") { 6 } else { if (ch == "7") { 7 }
            else { if (ch == "8") { 8 } else { if (ch == "9") { 9 }
            else { 0 - 1 }}}}}}}}}}
        if (d < 0) { if (saw == 'true') { acc } else { 0 - 1 } }
        else { parse_pos_int(s, i + 1, acc * 10 + d, 'true') }
    }
}

# ------------------------------------------------------------
# agent_message_loop — the subagent process body
# ------------------------------------------------------------
# Runs forever until {'stop'} arrives. On each {'task'} it runs the
# LLM-tools loop and pushes back {'agent_reply'} (or {'agent_emit'}
# for partial updates — currently used only on tool errors).
#
# Note: the FIRST message after spawn is registration: we update the
# entry with our own pid (the spawn_tool placeholder had pid=nil) and
# tell main we're alive via {'agent_spawned', name}.
fun agent_message_loop(reg, name, role, goal, sys_prompt, parent_opts, history) {
    # First-time registration of our pid + status.
    if (length(history) == 0) {
        entry = ets_get(reg, name)
        if (entry != nil) {
            updated = map_put(map_put(entry, 'pid', self()), 'status', 'idle')
            ets_put(reg, name, updated)
        }
        notify_main({'agent_spawned', name})
    }

    receive {
        {'task', prompt, reply_pid} ->
            update_status(reg, name, 'working')
            # Build the agent's history if first task — system prompt is
            # the role + goal + any extra system_prompt the spawner set.
            base_history = if (length(history) == 0) {
                [{'system', build_system_prompt(role, goal, sys_prompt)}]
            } else {
                history
            }
            with_user = list_append(base_history, {'user', to_string(prompt)})
            agent_opts = build_agent_opts(reg, name, parent_opts)
            result = run_agent_turn(reg, name, with_user, agent_opts, 0)
            with_assistant = list_append(with_user, {'assistant', result})
            update_status(reg, name, 'idle')
            target = if (reply_pid == nil) { whereis('main_agent') } else { reply_pid }
            if (target != nil) {
                send(target, {'agent_reply', name, result})
            }
            agent_message_loop(reg, name, role, goal, sys_prompt, parent_opts, with_assistant)

        {'stop'} ->
            update_status(reg, name, 'dying')
            ets_delete(reg, name)
            notify_main({'agent_died', name, "stopped"})
            'ok'

        _other ->
            agent_message_loop(reg, name, role, goal, sys_prompt, parent_opts, history)
    }
}

# Compose the subagent's system prompt. Role + goal are mandatory and
# get framed as identity. Caller-supplied system_prompt extends it.
fun build_system_prompt(role, goal, extra) {
    base = "You are " ++ role ++ ", a focused subagent in a swarm-code studio.\n\n" ++
           "YOUR GOAL: " ++ goal ++ "\n\n" ++
           "You have the full swarm-code tool set: bash, read, write, edit, " ++
           "multi_edit, glob, grep, web_fetch, web_search, code_search, " ++
           "git_status, git_diff, git_commit, sys_stats, todo_write.\n\n" ++
           "Call tools with: call:name{\"arg\":\"value\"}\n\n" ++
           "Be decisive and finish quickly. When your goal is achieved, " ++
           "give a concise final answer (no further tool calls). The Architect " ++
           "(or another agent) is waiting for your reply."
    if (string_length(extra) == 0) { base }
    else { base ++ "\n\n" ++ extra }
}

# Build a derived opts map for the subagent's LLM calls. We use main's
# endpoint, api_key, tool_format, etc. but override the model + max_tokens
# from the agent's own registry entry. Permissions / hooks tables are
# shared so the agent honours the same gates as main.
fun build_agent_opts(reg, name, parent_opts) {
    entry = ets_get(reg, name)
    if (entry == nil) { parent_opts }
    else {
        m = map_get(entry, 'model')
        mt = map_get(entry, 'max_tokens')
        a = map_put(parent_opts, 'model', m)
        b = map_put(a, 'max_tokens', mt)
        # Tag opts so tools.sw / log.sw can attribute output to this agent.
        map_put(b, 'subagent_name', name)
    }
}

# ------------------------------------------------------------
# run_agent_turn — minimal LLM-tools loop for the subagent
# ------------------------------------------------------------
# Mirrors agent.sw run_subagent_loop but standalone (no Agent import).
# Caps at agent_max_steps() to prevent runaway. Subagents never write to
# stdout directly — every content/reasoning chunk is sent to main as
# {'stream_chunk', name, text} / {'stream_reason', name, text} via the
# subagent-mode variant of http_post_stream. Main's main loop (and
# wait_for_reply) drain those and render with a per-agent prefix, so
# parallel subagents don't interleave on the shared TTY.
fun run_agent_turn(reg, name, history, opts, step) {
    if (step >= agent_max_steps()) {
        emit_to_main(name, "[hit max steps without final answer]")
        "[hit max steps without final answer]"
    } else {
        # Route streaming through main if main is registered; otherwise
        # fall back to direct stdout (e.g. unit-test harness).
        main_pid = whereis('main_agent')
        content = if (main_pid == nil) {
            LLM.chat(history, opts)
        } else {
            LLM.chat_for_subagent(history, opts, main_pid, name)
        }
        if (content == nil) {
            emit_to_main(name, "[llm call failed]")
            "[llm call failed]"
        } else {
            tool_calls = local_extract_tool_calls(content)
            if (length(tool_calls) == 0) {
                # Final answer.
                local_strip_tool_blocks(content)
            } else {
                with_assistant = list_append(history, {'assistant', content})
                post_tools = exec_subagent_tools(tool_calls, with_assistant, opts, name)
                run_agent_turn(reg, name, post_tools, opts, step + 1)
            }
        }
    }
}

fun agent_max_steps() {
    e = getenv("SWARM_CODE_AGENT_MAX_STEPS")
    if (e == nil) { 25 } else { to_int_safe(e, 25) }
}

# Inline tool-call extraction (mirrors agent.sw extract_tool_calls).
# Uses the swarmrt builtin parse_gemma_calls only — that handles every
# model the studio currently targets (Kimi, GLM, Gemma, Claude). The
# legacy <tool_call>...</tool_call> XML fallback agent.sw still has is
# intentionally NOT mirrored here; if a subagent ever needs it, lift
# extract_tool_calls into a shared module instead of duplicating.
fun local_extract_tool_calls(content) {
    native = parse_gemma_calls(content)
    local_convert_native_calls(native, [])
}

fun local_convert_native_calls(calls, acc) {
    if (length(calls) == 0) { acc }
    else {
        tc = hd(calls)
        n = elem(tc, 0)
        a = elem(tc, 1)
        raw = json_encode(a)
        local_convert_native_calls(tl(calls), list_append(acc, {n, a, raw}))
    }
}

# Strip any leftover call: blocks from final answer prose.
fun local_strip_tool_blocks(content) {
    parts = string_split(content, "\ncall:")
    hd(parts)
}

# Execute subagent tool calls. Subagents skip permission prompts and
# hooks (they're non-interactive); they use Tools.exec directly. Tool
# headers print with an [agent-name] prefix so users can tell who's
# acting in main's stream.
fun exec_subagent_tools(tool_calls, history, opts, name) {
    if (length(tool_calls) == 0) { history }
    else {
        tc = hd(tool_calls)
        tname = elem(tc, 0)
        targs = elem(tc, 1)
        traw = elem(tc, 2)
        # Block recursive task / spawn / parallel from inside a subagent
        # for now — guards against accidental fork-bombs. We can lift
        # this in v2 once we have proper depth limits + total caps.
        if (is_recursive_tool(tname)) {
            denied_w = "<tool_result>\nerror: tool '" ++ to_string(tname) ++ "' is disabled inside subagents in v1\n</tool_result>"
            denied_h = list_append(history, {'user', denied_w})
            exec_subagent_tools(tl(tool_calls), denied_h, opts, name)
        } else {
            UI.agent_tool_header(name, tname, traw)
            sub_result = Tools.exec(tname, targs, opts)
            ok_w = "<tool_result>\n" ++ sub_result ++ "\n</tool_result>"
            ok_h = list_append(history, {'user', ok_w})
            exec_subagent_tools(tl(tool_calls), ok_h, opts, name)
        }
    }
}

fun is_recursive_tool(name) {
    if (name == 'task') { 'true' }
    else { if (name == 'spawn_agent') { 'true' }
    else { if (name == 'parallel') { 'true' }
    else { if (name == 'ask') { 'true' }
    else { 'false' }}}}
}

# Push an emit message to main (for partial updates / errors).
fun emit_to_main(name, content) {
    notify_main({'agent_emit', name, content})
}

# Send any message to main_agent if it's registered. Centralised so the
# whereis + send pattern lives in one place and so swc doesn't have to
# share a `main_pid` variable across multiple unrelated scopes within
# the same function (which it doesn't handle).
fun notify_main(msg) {
    mp = whereis('main_agent')
    if (mp == nil) { 'noop' } else { send(mp, msg) }
}

# ------------------------------------------------------------
# ask_tool — blocking send-and-wait
# args: %{name, prompt}
# Implements the "main waits for subagent reply" semantics. Uses
# selective receive: emits from OTHER agents stay in mailbox until
# main returns to its normal loop.
# ------------------------------------------------------------
fun ask_tool(args, opts) {
    reg = map_get(opts, 'swarm_registry')
    name_v = map_get(args, 'name')
    prompt_v = map_get(args, 'prompt')
    if (reg == nil) { "error: swarm_registry not initialised" }
    else { if (name_v == nil) { "error: ask requires 'name'" }
    else { if (prompt_v == nil) { "error: ask requires 'prompt'" }
    else {
        name = to_string(name_v)
        entry = ets_get(reg, name)
        if (entry == nil) { "error: no agent named '" ++ name ++ "' — spawn one first" }
        else {
            pid = map_get(entry, 'pid')
            if (pid == nil) {
                "error: agent '" ++ name ++ "' is still spawning, retry in a moment"
            } else {
                send(pid, {'task', to_string(prompt_v), self()})
                wait_for_reply_with(name, opts)
            }
        }
    }}}
}

# Selective receive — only resolves on the matching agent's reply.
# {'agent_emit', name, _} from this agent are surfaced to stdout
# inline so the user sees progress; emits from OTHER agents queue
# until the main loop drains them.
fun wait_for_reply(name) {
    wait_for_reply_with(name, nil)
}

# wait_for_reply variant that knows about opts (so it can render stream
# chunks via UI helpers that need the stream_state_table). Both
# ask_tool and parallel_tool flow into this.
fun wait_for_reply_with(name, opts) {
    receive {
        {'agent_reply', n, content} ->
            if (n == name) { to_string(content) }
            else {
                # Re-send to self so main can pick it up later. Cheap
                # alternative to a true mailbox-stay primitive.
                send(self(), {'agent_reply', n, content})
                wait_for_reply_with(name, opts)
            }
        {'agent_emit', n, content} ->
            if (n == name) {
                UI.agent_emit_render(n, to_string(content))
                wait_for_reply_with(name, opts)
            } else {
                send(self(), {'agent_emit', n, content})
                wait_for_reply_with(name, opts)
            }
        {'stream_chunk', n, content} ->
            UI.stream_chunk_render(to_string(n), to_string(content), opts)
            wait_for_reply_with(name, opts)
        {'stream_reason', n, content} ->
            UI.stream_reason_render(to_string(n), to_string(content), opts)
            wait_for_reply_with(name, opts)
        {'stream_done', n} ->
            UI.stream_done_render(to_string(n), opts)
            wait_for_reply_with(name, opts)
        {'agent_died', n, reason} ->
            if (n == name) {
                "error: agent '" ++ n ++ "' died before replying (" ++ to_string(reason) ++ ")"
            } else {
                send(self(), {'agent_died', n, reason})
                wait_for_reply_with(name, opts)
            }
    }
}

# ------------------------------------------------------------
# tell_tool — fire-and-forget
# ------------------------------------------------------------
fun tell_tool(args, opts) {
    reg = map_get(opts, 'swarm_registry')
    name_v = map_get(args, 'name')
    msg_v = map_get(args, 'msg')
    if (reg == nil) { "error: swarm_registry not initialised" }
    else { if (name_v == nil) { "error: tell requires 'name'" }
    else { if (msg_v == nil) { "error: tell requires 'msg'" }
    else {
        name = to_string(name_v)
        entry = ets_get(reg, name)
        if (entry == nil) { "error: no agent named '" ++ name ++ "'" }
        else {
            pid = map_get(entry, 'pid')
            if (pid == nil) { "error: agent '" ++ name ++ "' is still spawning" }
            else {
                send(pid, {'task', to_string(msg_v), nil})
                "ok: queued for '" ++ name ++ "'"
            }
        }
    }}}
}

# ------------------------------------------------------------
# list_tool — render the registry
# ------------------------------------------------------------
fun list_tool(args, opts) {
    reg = map_get(opts, 'swarm_registry')
    if (reg == nil) { "no swarm registry" }
    else {
        names = registry_list_names(reg)
        if (length(names) == 0) { "no agents spawned" }
        else { UI.agents_table(reg, names) }
    }
}

# ------------------------------------------------------------
# kill_tool — graceful or hard
# args: %{name, hard?}
# ------------------------------------------------------------
fun kill_tool(args, opts) {
    reg = map_get(opts, 'swarm_registry')
    name_v = map_get(args, 'name')
    hard = map_get(args, 'hard')
    if (reg == nil) { "error: swarm_registry not initialised" }
    else { if (name_v == nil) { "error: kill requires 'name'" }
    else {
        name = to_string(name_v)
        entry = ets_get(reg, name)
        if (entry == nil) { "error: no agent named '" ++ name ++ "'" }
        else {
            pid = map_get(entry, 'pid')
            if (hard == 'true' || hard == "true") {
                # sw runtime doesn't expose process exit/2 from
                # userland, so "hard" today is best-effort: send stop
                # AND clear the registry entry so the agent name frees
                # up immediately even if the process is mid-turn. The
                # process will exit on its next receive. Real preempt
                # needs a runtime builtin (planned).
                if (pid != nil) { send(pid, {'stop'}) }
                ets_delete(reg, name)
                "ok: hard-stop sent to '" ++ name ++ "' (registry cleared; process will exit on next receive)"
            } else {
                if (pid != nil) { send(pid, {'stop'}) }
                "ok: stop signal sent to '" ++ name ++ "' (will finish current turn first)"
            }
        }
    }}
}

# ------------------------------------------------------------
# parallel_tool — sugar over spawn + ask + kill for fan-out
# args: %{tasks: [{name, role, goal, prompt, system_prompt?, model?}, ...]}
# Spawns N agents, asks each its prompt, gathers replies in order,
# kills them all. Used when the model wants ephemeral helpers.
# ------------------------------------------------------------
fun parallel_tool(args, opts) {
    tasks_v = map_get(args, 'tasks')
    if (tasks_v == nil) { "error: parallel requires 'tasks' list" }
    else { if (length(tasks_v) == 0) { "error: parallel given empty tasks list" }
    else {
        # Phase 1: spawn all
        spawn_results = parallel_spawn_each(tasks_v, opts, [])
        # Phase 2: send tasks (using the agent's self-pid so the reply
        # comes to THIS process, which is the main agent).
        send_results = parallel_send_each(tasks_v, opts, [])
        # Phase 3: collect N replies.
        names = parallel_extract_names(tasks_v, [])
        replies = parallel_collect_with(names, [], opts)
        # Phase 4: cleanup — graceful kill each.
        parallel_kill_each(names, opts)
        # Render combined.
        parallel_render(names, replies, "")
    }}
}

fun parallel_spawn_each(tasks, opts, acc) {
    if (length(tasks) == 0) { acc }
    else {
        t = hd(tasks)
        r = spawn_tool(t, opts)
        parallel_spawn_each(tl(tasks), opts, list_append(acc, r))
    }
}

fun parallel_send_each(tasks, opts, acc) {
    if (length(tasks) == 0) { acc }
    else {
        t = hd(tasks)
        name_v = map_get(t, 'name')
        prompt_v = map_get(t, 'prompt')
        if (name_v == nil || prompt_v == nil) {
            parallel_send_each(tl(tasks), opts, acc)
        } else {
            reg = map_get(opts, 'swarm_registry')
            send_task_to_named(reg, to_string(name_v), to_string(prompt_v), self())
            parallel_send_each(tl(tasks), opts, acc)
        }
    }
}

# Fetch agent pid from registry. If not yet registered (still spawning),
# wait a short beat and retry once before giving up.
fun send_task_to_named(reg, name, prompt, reply_to) {
    if (reg == nil) { 'noop' }
    else {
        pid = pid_for(reg, name)
        pid2 = if (pid == nil) { sleep_then_pid(reg, name) } else { pid }
        if (pid2 == nil) { 'noop' }
        else { send(pid2, {'task', prompt, reply_to}) }
    }
}

# Sleep briefly then re-check the registry. Extracted because sw
# doesn't accept `;` to chain statements inside an if-branch
# expression — only function bodies are multi-statement.
fun sleep_then_pid(reg, name) {
    sleep(50)
    pid_for(reg, name)
}

fun pid_for(reg, name) {
    e = ets_get(reg, name)
    if (e == nil) { nil } else { map_get(e, 'pid') }
}

fun parallel_extract_names(tasks, acc) {
    if (length(tasks) == 0) { acc }
    else {
        t = hd(tasks)
        n = map_get(t, 'name')
        next = if (n == nil) { acc } else { list_append(acc, to_string(n)) }
        parallel_extract_names(tl(tasks), next)
    }
}

# Block until all named agents have replied. Uses the same selective-
# receive pattern as ask_tool but for a SET of expected names.
fun parallel_collect(names_remaining, acc) {
    parallel_collect_with(names_remaining, acc, nil)
}

fun parallel_collect_with(names_remaining, acc, opts) {
    if (length(names_remaining) == 0) { acc }
    else {
        receive {
            {'agent_reply', n, content} ->
                if (list_contains(names_remaining, n) == 'true') {
                    new_remaining = list_remove(names_remaining, n)
                    new_acc = list_append(acc, {n, to_string(content)})
                    parallel_collect_with(new_remaining, new_acc, opts)
                } else {
                    send(self(), {'agent_reply', n, content})
                    parallel_collect_with(names_remaining, acc, opts)
                }
            {'agent_emit', n, content} ->
                UI.agent_emit_render(n, to_string(content))
                parallel_collect_with(names_remaining, acc, opts)
            {'stream_chunk', n, content} ->
                UI.stream_chunk_render(to_string(n), to_string(content), opts)
                parallel_collect_with(names_remaining, acc, opts)
            {'stream_reason', n, content} ->
                UI.stream_reason_render(to_string(n), to_string(content), opts)
                parallel_collect_with(names_remaining, acc, opts)
            {'stream_done', n} ->
                UI.stream_done_render(to_string(n), opts)
                parallel_collect_with(names_remaining, acc, opts)
            {'agent_died', n, reason} ->
                if (list_contains(names_remaining, n) == 'true') {
                    new_remaining = list_remove(names_remaining, n)
                    new_acc = list_append(acc, {n, "[died before reply: " ++ to_string(reason) ++ "]"})
                    parallel_collect_with(new_remaining, new_acc, opts)
                } else {
                    send(self(), {'agent_died', n, reason})
                    parallel_collect_with(names_remaining, acc, opts)
                }
        }
    }
}

fun list_contains(lst, v) {
    if (length(lst) == 0) { 'false' }
    else { if (hd(lst) == v) { 'true' }
    else { list_contains(tl(lst), v) }}
}

fun list_remove(lst, v) { list_remove_loop([], lst, v) }

fun list_remove_loop(acc, rest, v) {
    if (length(rest) == 0) { acc }
    else { if (hd(rest) == v) { acc ++ tl(rest) }
    else { list_remove_loop(list_append(acc, hd(rest)), tl(rest), v) }}
}

fun parallel_kill_each(names, opts) {
    if (length(names) == 0) { 'ok' }
    else {
        kill_tool(%{name: hd(names)}, opts)
        parallel_kill_each(tl(names), opts)
    }
}

fun parallel_render(names, replies, acc) {
    if (length(names) == 0) { acc }
    else {
        n = hd(names)
        r = lookup_reply(replies, n)
        block = "[" ++ n ++ "]\n" ++ r ++ "\n\n"
        parallel_render(tl(names), replies, acc ++ block)
    }
}

fun lookup_reply(replies, name) {
    if (length(replies) == 0) { "[no reply]" }
    else {
        r = hd(replies)
        if (elem(r, 0) == name) { elem(r, 1) }
        else { lookup_reply(tl(replies), name) }
    }
}

# ============================================================
# ROADMAP (v2+)
# ============================================================
# - True per-agent stdout capture so subagents don't print directly;
#   route LLM streaming through {'agent_emit'} messages instead of
#   stdout writes. Will need a small swarmrt builtin for "stream into
#   a callback" rather than the current "stream to stdout".
# - Per-agent log files at ~/.swarm-code/swarm-{ts}/agent-{name}.jsonl
#   for forensics.
# - Total-swarm token cap with hard cutoff + user prompt.
# - Allow lifting the recursive-tool ban with a depth counter.
# - Persistent agents across REPL sessions (serialise registry).
# - Shared ETS scratchpad table (`swarm_kb`) for agent collaboration
#   without going through main.
