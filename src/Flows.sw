module Flows

# ============================================================
# Flows — multi-agent parallel workflow orchestrator
# ============================================================
#
# Entry point: run_flows(raw_args, opts)
#
# The /flows command accepts either:
#   1. A path to a JSON workflow definition file:
#      { "name": "...", "description": "...", "phases": [...] }
#   2. Inline "label: prompt\nlabel2: prompt2" task pairs
#      (wrapped in a single synthetic phase, then run the same way)
#
# Each task is launched as a headless swarm-code subprocess via
# Background.launch, then polled every 500 ms via render_loop
# until all tasks complete. A live TUI shows progress. To abort a
# run mid-flight: touch /tmp/swarm-flows-stop.
#
# JSON workflow shape:
#   {
#     "name": "my-workflow",
#     "description": "what it does",
#     "phases": [
#       {
#         "name": "Phase Name",
#         "tasks": [
#           { "label": "task-label", "prompt": "what to do", "model": "..." }
#         ]
#       }
#     ]
#   }

import Background
import FlowsRender
import Scheduler
import Util
import UI

export [run_flows]

# ============================================================
# Entry point
# ============================================================

# run_flows(raw_args, opts) -> unit
#
# Called from slash_dispatch when cmd starts with "/flows".
# raw_args is the string after "/flows " (may be empty for "/flows").
fun run_flows(raw_args, opts) {
    trimmed = string_trim(raw_args)
    if (string_length(trimmed) == 0) {
        print(UI.warn_color() ++ "usage:" ++ UI.reset())
        print("  /flows path/to/workflow.json")
        print("  /flows label1: prompt1\\nlabel2: prompt2")
        print("")
        print(UI.grey_text() ++ "JSON workflow format:" ++ UI.reset())
        print(UI.grey_text() ++ "  { \"name\": \"my-flow\"," ++ UI.reset())
        print(UI.grey_text() ++ "    \"phases\": [{ \"name\": \"Phase 1\"," ++ UI.reset())
        print(UI.grey_text() ++ "      \"tasks\": [{ \"label\": \"t1\", \"prompt\": \"...\" }] }] }" ++ UI.reset())
    } else {
        # Detect if raw_args is a JSON file path
        looks_like_path = if (string_ends_with(trimmed, ".json") == 'true') { 'true' }
                          else { if (string_starts_with(trimmed, "/") == 'true') { 'true' }
                          else { if (string_starts_with(trimmed, "./") == 'true') { 'true' }
                          else { if (string_starts_with(trimmed, "~/") == 'true') { 'true' }
                          else { 'false' }}}}
        if (looks_like_path == 'true') {
            run_from_json_file(trimmed, opts)
        } else {
            run_from_inline(trimmed, opts)
        }
    }
}

# ============================================================
# JSON workflow path
# ============================================================

fun run_from_json_file(path, opts) {
    content = file_read(path)
    if (content == nil) {
        print(UI.err_color() ++ "error: cannot read file: " ++ path ++ UI.reset())
    } else {
        decoded = json_decode(content)
        if (decoded == nil) {
            print(UI.err_color() ++ "error: invalid JSON in: " ++ path ++ UI.reset())
        } else {
            run_json_workflow(decoded, opts)
        }
    }
}

fun run_json_workflow(workflow_map, opts) {
    # Reuse the agent's Background table (carried in opts): a private
    # table restarts the bg-N id counter at bg-0 and collides with the
    # agent's own (never-cleaned) /tmp/swarm-code-bg-N.* files, so a
    # stale exit file could instantly mark a fresh task as done.
    existing = map_get(opts, 'bg_table')
    bg_table = if (existing == nil) { Background.init() } else { existing }
    state = init_state(workflow_map)
    state_with_table = map_put(state, 'bg_table', bg_table)

    # Enter alt-screen
    UI.enter_alt_screen()

    # Spawn phase 0 tasks
    phases = map_get(state_with_table, 'phases')
    if (length(phases) == 0) {
        UI.leave_alt_screen()
        print(UI.warn_color() ++ "no phases defined in workflow" ++ UI.reset())
    } else {
        state_launched = spawn_phase_tasks(0, state_with_table, bg_table, opts)
        w = UI.term_width()
        FlowsRender.render_frame(state_launched, w, 24)
        render_loop(state_launched, bg_table, opts)
    }
}

# init_state(workflow_map) — build initial state map from decoded JSON
fun init_state(workflow_map) {
    name = map_get(workflow_map, 'name')
    name_str = if (name == nil) { "unnamed-flow" } else { to_string(name) }
    desc = map_get(workflow_map, 'description')
    desc_str = if (desc == nil) { "" } else { to_string(desc) }
    phases_raw = map_get(workflow_map, 'phases')
    phases_list = if (phases_raw == nil) { [] } else { phases_raw }
    phases_init = init_phases(phases_list, 0, [])
    %{
        name:            name_str,
        description:     desc_str,
        phases:          phases_init,
        selected_phase:  0,
        start_ms:        timestamp(),
        tick:            0,
        phase:           'running',
        bg_table:        nil
    }
}

# Convert raw JSON phases list into internal phase maps with task maps
fun init_phases(phases, idx, acc) {
    if (length(phases) == 0) { acc }
    else {
        p = hd(phases)
        p_name = map_get(p, 'name')
        p_name_str = if (p_name == nil) { "Phase " ++ to_string(idx) }
                     else { to_string(p_name) }
        tasks_raw = map_get(p, 'tasks')
        tasks_list = if (tasks_raw == nil) { [] } else { tasks_raw }
        tasks_init = init_tasks(tasks_list, 0, [])
        phase_map = %{
            name:   p_name_str,
            tasks:  tasks_init,
            status: 'pending'
        }
        init_phases(tl(phases), idx + 1, list_append(acc, phase_map))
    }
}

fun init_tasks(tasks, idx, acc) {
    if (length(tasks) == 0) { acc }
    else {
        t = hd(tasks)
        label_raw = map_get(t, 'label')
        label_str = if (label_raw == nil) { "task-" ++ to_string(idx) }
                    else { to_string(label_raw) }
        prompt_raw = map_get(t, 'prompt')
        prompt_str = if (prompt_raw == nil) { "" } else { to_string(prompt_raw) }
        model_raw = map_get(t, 'model')
        model_str = if (model_raw == nil) { nil } else { to_string(model_raw) }
        task_map = %{
            label:       label_str,
            prompt:      prompt_str,
            model:       model_str,
            bg_task_id:  nil,
            status:      'pending',
            exit_code:   nil,
            tokens_in:   0,
            tokens_out:  0,
            tool_calls:  0,
            started_ms:  nil,
            ended_ms:    nil
        }
        init_tasks(tl(tasks), idx + 1, list_append(acc, task_map))
    }
}

# spawn_phase_tasks(phase_idx, state, bg_table, opts) — launch all tasks in a phase
fun spawn_phase_tasks(phase_idx, state, bg_table, opts) {
    phases = map_get(state, 'phases')
    phase = list_nth(phases, phase_idx)
    if (phase == nil) { state }
    else {
        tasks = map_get(phase, 'tasks')
        new_tasks = spawn_task_list(tasks, bg_table, opts, phase_idx, [])
        new_phase = map_put(phase, 'tasks', new_tasks)
        new_phase2 = map_put(new_phase, 'status', 'running')
        new_phases = list_replace_nth(phases, phase_idx, new_phase2)
        state2 = map_put(state, 'phases', new_phases)
        map_put(state2, 'selected_phase', phase_idx)
    }
}

fun spawn_task_list(tasks, bg_table, opts, phase_idx, acc) {
    if (length(tasks) == 0) { acc }
    else {
        t = hd(tasks)
        prompt = map_get(t, 'prompt')
        label = map_get(t, 'label')
        model = map_get(t, 'model')
        cmd = build_task_cmd(to_string(prompt), model)
        bg_task_id = Background.launch(bg_table, cmd, to_string(label))
        new_t = map_put(t, 'bg_task_id', bg_task_id)
        new_t2 = map_put(new_t, 'status', 'running')
        new_t3 = map_put(new_t2, 'started_ms', timestamp())
        spawn_task_list(tl(tasks), bg_table, opts, phase_idx, list_append(acc, new_t3))
    }
}

# build_task_cmd(prompt, model) — build the shell command for a single task.
# The per-task "model" rides in as SWARM_CODE_MODEL (env > profile >
# settings in load_opts) — the binary has no --model flag, and a bare
# --model value would be scanned as a positional profile name.
# SWARM_CODE_DENY_DANGEROUS=1 keeps the dangerous-bash gate a hard deny
# in the headless children, which otherwise auto-approve every 'ask'.
fun build_task_cmd(prompt, model) {
    binary = swarm_binary()
    base = "SWARM_CODE_DENY_DANGEROUS=1 " ++ Util.shell_q(binary) ++
           " -p " ++ Util.shell_q(prompt) ++ " --no-resume"
    if (model == nil) { base }
    else { "SWARM_CODE_MODEL=" ++ Util.shell_q(model) ++ " " ++ base }
}

# swarm_binary() — locate the swarm-code binary. Delegates to the
# Scheduler helper (SWARM_CODE_BIN env > argv[0] > ~/.local/bin/swarm >
# PATH lookup) — never a hardcoded dev path.
fun swarm_binary() {
    Scheduler.swarm_binary_path()
}

# ============================================================
# Render loop (JSON workflow mode)
# ============================================================

# render_loop(state, bg_table, opts) — tail-recursive poll loop
fun render_loop(state, bg_table, opts) {
    # Poll all running tasks and update state
    refreshed = refresh_all_phases(state, bg_table)

    # Read log stats for running tasks
    refreshed2 = refresh_log_stats(refreshed)

    # Increment tick for spinner
    tick = map_get(refreshed2, 'tick')
    refreshed3 = map_put(refreshed2, 'tick', tick + 1)

    # Render frame
    w = UI.term_width()
    FlowsRender.render_frame(refreshed3, w, 24)

    # Check if current phase is done, spawn next phase if needed
    selected = map_get(refreshed3, 'selected_phase')
    phases = map_get(refreshed3, 'phases')
    current_phase = list_nth(phases, selected)
    cur_done = if (current_phase == nil) { 'true' }
               else { all_agents_done(current_phase) }

    state_after_phase = if (cur_done == 'true') {
        next_idx = selected + 1
        if (next_idx < length(phases)) {
            # Spawn next phase
            spawn_phase_tasks(next_idx, refreshed3, bg_table, opts)
        } else {
            # All phases done
            map_put(refreshed3, 'phase', 'done')
        }
    } else { refreshed3 }

    # Check if all done or user requested stop via stop-file
    all_done = all_phases_done(state_after_phase)
    stop_file = file_exists("/tmp/swarm-flows-stop")
    user_stop = if (stop_file == 'true') {
        shell("rm -f /tmp/swarm-flows-stop")
        'true'
    } else { 'false' }
    # Stop-file abort: flip phase to 'aborted' so the final frame shows
    # [aborted] and print_summary takes the aborted branch.
    final_state = if (user_stop == 'true') {
        map_put(state_after_phase, 'phase', 'aborted')
    } else { state_after_phase }
    phase_atom = map_get(final_state, 'phase')
    aborted = if (phase_atom == 'aborted') { 'true' } else { 'false' }

    if (all_done == 'true' || aborted == 'true') {
        # Final render
        FlowsRender.render_frame(final_state, w, 24)
        UI.leave_alt_screen()
        print_summary(final_state)
    } else {
        # Sleep 500ms then recurse
        shell("sleep 0.5")
        render_loop(final_state, bg_table, opts)
    }
}

# refresh_all_phases — update statuses for all tasks across all phases
fun refresh_all_phases(state, bg_table) {
    phases = map_get(state, 'phases')
    new_phases = refresh_phases_loop(phases, bg_table, [])
    map_put(state, 'phases', new_phases)
}

fun refresh_phases_loop(phases, bg_table, acc) {
    if (length(phases) == 0) { acc }
    else {
        p = hd(phases)
        tasks = map_get(p, 'tasks')
        new_tasks = refresh_tasks_loop(tasks, bg_table, [])
        new_p = map_put(p, 'tasks', new_tasks)
        refresh_phases_loop(tl(phases), bg_table, list_append(acc, new_p))
    }
}

fun refresh_tasks_loop(tasks, bg_table, acc) {
    if (length(tasks) == 0) { acc }
    else {
        t = hd(tasks)
        bg_id = map_get(t, 'bg_task_id')
        new_t = if (bg_id == nil) { t }
                else {
                    s = task_file_status(to_string(bg_id))
                    t2 = map_put(t, 'status', s)
                    if (s == 'done' || s == 'error') {
                        ended = map_get(t2, 'ended_ms')
                        t3 = if (ended == nil) { map_put(t2, 'ended_ms', timestamp()) }
                             else { t2 }
                        exit_file = "/tmp/swarm-code-" ++ to_string(bg_id) ++ ".exit"
                        exit_content = file_read(exit_file)
                        ec = if (exit_content == nil) { 0 }
                             else { parse_exit_code(string_trim(exit_content)) }
                        map_put(t3, 'exit_code', ec)
                    } else { t2 }
                }
        refresh_tasks_loop(tl(tasks), bg_table, list_append(acc, new_t))
    }
}

# task_file_status — check bg task status via exit/pid files directly,
# bypassing Background ETS (which requires poll_and_notify to update).
fun task_file_status(bg_id) {
    exit_file = "/tmp/swarm-code-" ++ bg_id ++ ".exit"
    if (file_exists(exit_file) == 'true') {
        exit_content = file_read(exit_file)
        ec = if (exit_content == nil) { 0 }
             else { parse_exit_code(string_trim(exit_content)) }
        if (ec == 0) { 'done' } else { 'error' }
    } else {
        pid_file = "/tmp/swarm-code-" ++ bg_id ++ ".pid"
        if (file_exists(pid_file) == 'true') { 'running' } else { 'pending' }
    }
}

# refresh_log_stats — read token/tool counts from log files
fun refresh_log_stats(state) {
    phases = map_get(state, 'phases')
    new_phases = refresh_log_phases(phases, [])
    map_put(state, 'phases', new_phases)
}

fun refresh_log_phases(phases, acc) {
    if (length(phases) == 0) { acc }
    else {
        p = hd(phases)
        tasks = map_get(p, 'tasks')
        new_tasks = refresh_log_tasks(tasks, [])
        new_p = map_put(p, 'tasks', new_tasks)
        refresh_log_phases(tl(phases), list_append(acc, new_p))
    }
}

fun refresh_log_tasks(tasks, acc) {
    if (length(tasks) == 0) { acc }
    else {
        t = hd(tasks)
        bg_id = map_get(t, 'bg_task_id')
        new_t = if (bg_id == nil) { t }
                else {
                    log_file = "/tmp/swarm-code-" ++ to_string(bg_id) ++ ".log"
                    stats = parse_log_stats(log_file)
                    t2 = map_put(t, 'tokens_in', map_get(stats, 'tokens_in'))
                    t3 = map_put(t2, 'tokens_out', map_get(stats, 'tokens_out'))
                    map_put(t3, 'tool_calls', map_get(stats, 'tools'))
                }
        refresh_log_tasks(tl(tasks), list_append(acc, new_t))
    }
}

# parse_log_stats(log_file) — read token/tool counts from log file tail
fun parse_log_stats(log_file) {
    if (file_exists(log_file) != 'true') {
        %{ tokens_in: 0, tokens_out: 0, tools: 0 }
    } else {
        r = shell("tail -n 20 " ++ Util.shell_q(log_file) ++ " 2>/dev/null")
        tail = elem(r, 1)
        parse_stats_from_tail(tail)
    }
}

fun parse_stats_from_tail(tail) {
    lines = string_split(tail, "\n")
    parse_stats_lines(lines, %{ tokens_in: 0, tokens_out: 0, tools: 0 })
}

fun parse_stats_lines(lines, acc) {
    if (length(lines) == 0) { acc }
    else {
        line = string_trim(hd(lines))
        new_acc = update_stats_from_line(line, acc)
        parse_stats_lines(tl(lines), new_acc)
    }
}

fun update_stats_from_line(line, acc) {
    # Look for patterns like "tokens_in: 1234" or "tool_calls: 5"
    # or "input tokens: 1234" or "[N tokens]"
    if (string_contains(line, "tokens_in:") == 'true') {
        n = extract_number_after(line, "tokens_in:")
        if (n >= 0) { map_put(acc, 'tokens_in', n) } else { acc }
    } else {
        if (string_contains(line, "tokens_out:") == 'true') {
            n = extract_number_after(line, "tokens_out:")
            if (n >= 0) { map_put(acc, 'tokens_out', n) } else { acc }
        } else {
            if (string_contains(line, "tool_calls:") == 'true') {
                n = extract_number_after(line, "tool_calls:")
                if (n >= 0) { map_put(acc, 'tools', n) } else { acc }
            } else {
                if (string_contains(line, "input_tokens") == 'true') {
                    n = extract_number_after(line, "input_tokens")
                    if (n >= 0) { map_put(acc, 'tokens_in', n) } else { acc }
                } else {
                    if (string_contains(line, "output_tokens") == 'true') {
                        n = extract_number_after(line, "output_tokens")
                        if (n >= 0) { map_put(acc, 'tokens_out', n) } else { acc }
                    } else { acc }
                }
            }
        }
    }
}

# Extract the first integer found after `marker` in `line`.
# string_index_of is the builtin (the codegen resolves builtins before
# module funs, so a local copy here would be silently dead code).
fun extract_number_after(line, marker) {
    idx = string_index_of(line, marker)
    if (idx < 0) { 0 - 1 }
    else {
        start = idx + string_length(marker)
        rest = string_sub(line, start, string_length(line) - start)
        parse_first_int(rest)
    }
}

fun parse_first_int(s) {
    parse_first_int_skip(s, 0)
}

# Skip non-digits then read digits
fun parse_first_int_skip(s, i) {
    if (i >= string_length(s)) { 0 - 1 }
    else {
        ch = string_sub(s, i, 1)
        is_digit = char_is_digit(ch)
        if (is_digit == 'true') { parse_first_int_read(s, i, 0) }
        else { parse_first_int_skip(s, i + 1) }
    }
}

fun parse_first_int_read(s, i, acc) {
    if (i >= string_length(s)) { acc }
    else {
        ch = string_sub(s, i, 1)
        d = char_digit_val(ch)
        if (d < 0) { acc }
        else { parse_first_int_read(s, i + 1, acc * 10 + d) }
    }
}

fun char_is_digit(ch) {
    if (ch == "0") { 'true' } else { if (ch == "1") { 'true' }
    else { if (ch == "2") { 'true' } else { if (ch == "3") { 'true' }
    else { if (ch == "4") { 'true' } else { if (ch == "5") { 'true' }
    else { if (ch == "6") { 'true' } else { if (ch == "7") { 'true' }
    else { if (ch == "8") { 'true' } else { if (ch == "9") { 'true' }
    else { 'false' }}}}}}}}}}
}

fun char_digit_val(ch) {
    if (ch == "0") { 0 } else { if (ch == "1") { 1 }
    else { if (ch == "2") { 2 } else { if (ch == "3") { 3 }
    else { if (ch == "4") { 4 } else { if (ch == "5") { 5 }
    else { if (ch == "6") { 6 } else { if (ch == "7") { 7 }
    else { if (ch == "8") { 8 } else { if (ch == "9") { 9 }
    else { 0 - 1 }}}}}}}}}}
}

fun parse_exit_code(s) {
    parse_exit_digits(s, 0, 0)
}

fun parse_exit_digits(s, i, acc) {
    if (i >= string_length(s)) { acc }
    else {
        ch = string_sub(s, i, 1)
        d = char_digit_val(ch)
        if (d < 0) { acc }
        else { parse_exit_digits(s, i + 1, acc * 10 + d) }
    }
}

# all_agents_done(phase_map) — returns 'true' if every agent in phase done/error
fun all_agents_done(phase_map) {
    tasks = map_get(phase_map, 'tasks')
    all_tasks_done(tasks)
}

fun all_tasks_done(tasks) {
    if (length(tasks) == 0) { 'true' }
    else {
        t = hd(tasks)
        s = map_get(t, 'status')
        s_str = if (s == nil) { "pending" } else { to_string(s) }
        is_done = if (s_str == "done") { 'true' }
                  else { if (s_str == "error") { 'true' }
                  else { if (s_str == "killed") { 'true' }
                  else { 'false' }}}
        if (is_done == 'false') { 'false' }
        else { all_tasks_done(tl(tasks)) }
    }
}

# all_phases_done(state) — returns 'true' if all phases complete
fun all_phases_done(state) {
    phase_atom = map_get(state, 'phase')
    if (phase_atom == 'done') { 'true' }
    else {
        phases = map_get(state, 'phases')
        all_phases_list_done(phases)
    }
}

fun all_phases_list_done(phases) {
    if (length(phases) == 0) { 'true' }
    else {
        p = hd(phases)
        done = all_agents_done(p)
        if (done == 'false') { 'false' }
        else { all_phases_list_done(tl(phases)) }
    }
}

# count_done(state) — total done agents across all phases
fun count_done(state) {
    phases = map_get(state, 'phases')
    count_done_phases(phases, 0)
}

fun count_done_phases(phases, acc) {
    if (length(phases) == 0) { acc }
    else {
        p = hd(phases)
        tasks = map_get(p, 'tasks')
        n = count_done_tasks(tasks, 0)
        count_done_phases(tl(phases), acc + n)
    }
}

fun count_done_tasks(tasks, acc) {
    if (length(tasks) == 0) { acc }
    else {
        t = hd(tasks)
        s = map_get(t, 'status')
        s_str = if (s == nil) { "pending" } else { to_string(s) }
        is_done = if (s_str == "done") { 'true' }
                  else { if (s_str == "error") { 'true' }
                  else { if (s_str == "killed") { 'true' }
                  else { 'false' }}}
        new_acc = if (is_done == 'true') { acc + 1 } else { acc }
        count_done_tasks(tl(tasks), new_acc)
    }
}

# count_total(state) — total agents across all phases
fun count_total(state) {
    phases = map_get(state, 'phases')
    count_total_phases(phases, 0)
}

fun count_total_phases(phases, acc) {
    if (length(phases) == 0) { acc }
    else {
        p = hd(phases)
        tasks = map_get(p, 'tasks')
        count_total_phases(tl(phases), acc + length(tasks))
    }
}

# print_summary — final summary after all done
fun print_summary(state) {
    name = map_get(state, 'name')
    start_ms = map_get(state, 'start_ms')
    elapsed_ms = timestamp() - start_ms
    elapsed_s = elapsed_ms / 1000
    done_n = count_done(state)
    total_n = count_total(state)
    phase_atom = map_get(state, 'phase')
    aborted = if (phase_atom == 'aborted') { 'true' } else { 'false' }

    print("")
    if (aborted == 'true') {
        print(UI.warn_color() ++ "⏺ flows aborted: " ++ to_string(name) ++ UI.reset())
    } else {
        print(UI.brand_color() ++ "⏺ flows complete: " ++ to_string(name) ++ UI.reset())
    }
    print(UI.grey_text() ++ "  " ++ to_string(done_n) ++ "/" ++ to_string(total_n) ++
          " tasks done in " ++ to_string(elapsed_s) ++ "s" ++ UI.reset())
    print("")
}

# ============================================================
# Inline mode (label: prompt pairs)
# ============================================================

# Inline pairs are wrapped in a single synthetic phase and run through
# the JSON path — one state shape (FlowsRender reads 'phases'), one
# render loop, one termination path (all-done / stop-file).
fun run_from_inline(raw_args, opts) {
    pairs = parse_flows_args(raw_args)
    if (pairs == nil) {
        print(UI.warn_color() ++ "usage: /flows label1: prompt1; label2: prompt2" ++ UI.reset())
        print(UI.grey_text() ++ "  or:  /flows path/to/workflow.json" ++ UI.reset())
    } else {
        if (length(pairs) == 0) {
            print(UI.warn_color() ++ "no tasks found — check your format" ++ UI.reset())
        } else {
            tasks = pairs_to_task_maps(pairs, [])
            workflow_map = %{
                name:   "inline-flow",
                phases: [ %{ name: "Tasks", tasks: tasks } ]
            }
            run_json_workflow(workflow_map, opts)
        }
    }
}

# pairs_to_task_maps([[label, prompt], ...]) -> [%{label: .., prompt: ..}, ...]
fun pairs_to_task_maps(pairs, acc) {
    if (length(pairs) == 0) { acc }
    else {
        pair = hd(pairs)
        label = hd(pair)
        prompt = hd(tl(pair))
        t = %{ label: to_string(label), prompt: to_string(prompt) }
        pairs_to_task_maps(tl(pairs), list_append(acc, t))
    }
}

# ============================================================
# parse_flows_args(raw) — parse "label: prompt" pairs
# ============================================================

# Accepts "label: prompt\nlabel2: prompt2" or semicolon-separated.
# Returns list of 2-element lists [label, prompt], or nil if empty/unparseable.
fun parse_flows_args(raw) {
    trimmed = string_trim(raw)
    if (string_length(trimmed) == 0) { nil }
    else {
        # Newline split first. REPL input is single-line, so a lone line
        # containing ";" is the advertised inline multi-task form — split
        # on ";" instead. (The old zero-pairs fallback was unreachable:
        # any non-empty line yields at least one pair.)
        lines = string_split(trimmed, "\n")
        parts = if (length(lines) == 1 && string_contains(trimmed, ";") == 'true') {
            string_split(trimmed, ";")
        } else { lines }
        parse_lines_to_pairs(parts, [])
    }
}

fun parse_lines_to_pairs(lines, acc) {
    if (length(lines) == 0) { acc }
    else {
        line = string_trim(hd(lines))
        if (string_length(line) == 0) {
            parse_lines_to_pairs(tl(lines), acc)
        } else {
            colon_idx = string_index_of(line, ":")
            if (colon_idx < 0) {
                # No colon — treat whole line as prompt with auto-label
                label = "task-" ++ to_string(length(acc))
                pair = [label, line]
                parse_lines_to_pairs(tl(lines), list_append(acc, pair))
            } else {
                label = string_trim(string_sub(line, 0, colon_idx))
                rest_start = colon_idx + 1
                rest_len = string_length(line) - rest_start
                prompt = string_trim(string_sub(line, rest_start, rest_len))
                if (string_length(prompt) == 0) {
                    parse_lines_to_pairs(tl(lines), acc)
                } else {
                    pair = [label, prompt]
                    parse_lines_to_pairs(tl(lines), list_append(acc, pair))
                }
            }
        }
    }
}

# ============================================================
# List utility helpers
# ============================================================

# list_nth(list, n) — get the nth element (0-indexed), or nil
fun list_nth(lst, n) {
    if (length(lst) == 0) { nil }
    else {
        if (n == 0) { hd(lst) }
        else { list_nth(tl(lst), n - 1) }
    }
}

# list_replace_nth(list, n, val) — replace nth element, return new list
fun list_replace_nth(lst, n, val) {
    list_replace_nth_loop(lst, n, val, 0, [])
}

fun list_replace_nth_loop(lst, n, val, i, acc) {
    if (length(lst) == 0) { acc }
    else {
        item = hd(lst)
        new_item = if (i == n) { val } else { item }
        list_replace_nth_loop(tl(lst), n, val, i + 1, list_append(acc, new_item))
    }
}

