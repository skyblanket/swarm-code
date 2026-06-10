module FlowsRender

import UI

# ============================================================
# FlowsRender — 3-panel TUI for /flows workflow view
# ============================================================
#
# Layout (total width W):
#   Left panel  : cols 1..22        (22 chars wide, 1-char right border at col 22)
#   Middle panel: cols 23..(W-28)   (W-50 chars wide)
#   Right panel : cols (W-27)..W    (28 chars wide, 1-char left border at col W-28)
#
# Row layout:
#   Row 1       : Title bar (full width)
#   Row 2       : Panel header row
#   Row 3       : Top border
#   Rows 4..(H-2): Panel body rows
#   Row H-1     : Bottom border
#   Row H       : Status bar

export [
    render_frame,
    render_title_bar,
    render_phases_panel,
    render_agents_panel,
    render_stats_panel,
    render_status_bar,
    panel_col,
    pad_right,
    trunc
]

# ============================================================
# Color helpers (local aliases — UI module is imported)
# ============================================================

fun teal_info()  { "\e[38;2;86;182;194m"  }   # #56b6c2

# ============================================================
# String utilities
# ============================================================

# pad_right(s, width) -> string
#   Pad s with spaces on the right to exactly width chars.
fun pad_right(s, width) {
    len = string_length(s)
    if (len >= width) {
        if (width <= 1) { string_sub(s, 0, 1) }
        else { string_sub(s, 0, width - 1) ++ " " }
    } else {
        s ++ pad_spaces(width - len, "")
    }
}

fun pad_spaces(n, acc) {
    if (n <= 0) { acc }
    else { pad_spaces(n - 1, acc ++ " ") }
}

# trunc(s, max_len) -> string
#   Truncate s to max_len chars, appending "…" if truncated.
fun trunc(s, max_len) {
    len = string_length(s)
    if (len <= max_len) { s }
    else {
        if (max_len <= 1) { "…" }
        else { string_sub(s, 0, max_len - 1) ++ "…" }
    }
}

# repeat_char(ch, n) -> string
fun repeat_char(ch, n) {
    if (n <= 0) { "" }
    else {
        if (n == 1) { ch }
        else { ch ++ repeat_char(ch, n - 1) }
    }
}

# ============================================================
# Cursor positioning
# ============================================================

# goto(row, col) -> string — ANSI absolute cursor position
fun goto(row, col) {
    "\e[" ++ to_string(row) ++ ";" ++ to_string(col) ++ "H"
}

# panel_col(col) -> string — ANSI cursor-to-column escape
fun panel_col(col) {
    "\e[" ++ to_string(col) ++ "G"
}

# ============================================================
# Elapsed time formatting
# ============================================================

# elapsed_str(started_ms, ended_ms_or_nil) -> string
#   Format elapsed time as "Xs" or "Xm Ys"
fun elapsed_str(started_ms, ended_ms) {
    now = if (ended_ms == nil) { timestamp() } else { ended_ms }
    elapsed_ms = now - started_ms
    format_elapsed(elapsed_ms)
}

fun format_elapsed(elapsed_ms) {
    if (elapsed_ms < 0) { "0s" }
    else {
        if (elapsed_ms < 60000) {
            to_string(elapsed_ms / 1000) ++ "s"
        } else {
            mins = elapsed_ms / 60000
            secs = (elapsed_ms / 1000) - (mins * 60)
            to_string(mins) ++ "m" ++ to_string(secs) ++ "s"
        }
    }
}

# ============================================================
# Spinner animation
# ============================================================

# spinner_char(tick) -> string — cycles through ◐◓◑◒
fun spinner_char(tick) {
    idx = tick % 4
    if (idx == 0) { "◐" }
    else { if (idx == 1) { "◓" }
    else { if (idx == 2) { "◑" }
    else { "◒" }}}
}

fun anim_tick() {
    (timestamp() / 200) % 4
}

# ============================================================
# Status icon for a task
# ============================================================

fun status_icon(status) {
    if (status == 'done') { "✔" }
    else { if (status == 'error') { "✗" }
    else { if (status == 'killed') { "⊘" }
    else { if (status == 'running') { spinner_char(anim_tick()) }
    else { "○" } }}}
}

fun status_color(status) {
    if (status == 'done') { UI.green() }
    else { if (status == 'error') { UI.err_color() }
    else { if (status == 'killed') { UI.warn_color() }
    else { if (status == 'running') { UI.brand_color() }
    else { UI.grey_text() } }}}
}

# ============================================================
# Phase label from flow state
# ============================================================

fun phase_label(flow_state) {
    p = map_get(flow_state, 'phase')
    if (p == nil) { 'running' }
    else { to_string(p) }
}

fun phase_status_str(phase) {
    if (phase == 'done') { "[done]" }
    else { if (phase == 'aborted') { "[aborted]" }
    else { "[running]" }}
}

fun phase_status_color(phase) {
    if (phase == 'done') { UI.green() }
    else { if (phase == 'aborted') { UI.err_color() }
    else { UI.brand_color() }}
}

# ============================================================
# Title bar (row 1, full width)
# ============================================================

# render_title_bar(flow_name, phase, term_w) -> unit
fun render_title_bar(flow_name, phase, term_w) {
    status_str = phase_status_str(phase)
    status_col = phase_status_color(phase)
    left_content = "  ⏺ swarm-code flows · " ++ flow_name ++ "  "
    left_len = string_length(left_content)
    right_len = string_length(status_str)
    gap = term_w - left_len - right_len - 2
    gap_str = if (gap <= 0) { " " } else { pad_spaces(gap, "") }
    full_line = left_content ++ gap_str ++ status_str ++ "  "
    print_inline(
        goto(1, 1) ++
        UI.brand_color() ++ "\e[1m" ++
        pad_right(full_line, term_w) ++
        UI.reset()
    )
}

# ============================================================
# Panel header row (row 2)
# ============================================================

fun render_panel_headers(term_w) {
    mid_col = 23
    right_col = term_w - 27
    print_inline(
        goto(2, 1) ++
        UI.grey_text() ++ "  PHASES" ++
        panel_col(mid_col) ++
        " AGENTS / OUTPUT" ++
        panel_col(right_col) ++
        " STATS" ++
        UI.reset() ++
        "\e[K"
    )
}

# ============================================================
# Top border (row 3)
# ============================================================

fun render_top_border(term_w, row) {
    left_dashes = repeat_char("─", 21)
    mid_dashes = repeat_char("─", term_w - 51)
    right_dashes = repeat_char("─", 27)
    line = "┌" ++ left_dashes ++ "┬" ++ mid_dashes ++ "┬" ++ right_dashes ++ "┐"
    print_inline(
        goto(row, 1) ++
        UI.grey_border() ++ line ++ UI.reset()
    )
}

# ============================================================
# Bottom border (row H-1)
# ============================================================

fun render_bottom_border(term_w, row) {
    left_dashes = repeat_char("─", 21)
    mid_dashes = repeat_char("─", term_w - 51)
    right_dashes = repeat_char("─", 27)
    line = "└" ++ left_dashes ++ "┴" ++ mid_dashes ++ "┴" ++ right_dashes ++ "┘"
    print_inline(
        goto(row, 1) ++
        UI.grey_border() ++ line ++ UI.reset()
    )
}

# ============================================================
# Left panel — phases list (col 1..22)
# ============================================================

# list_nth(lst, n) — get the nth element (0-indexed), nil if out of bounds
fun list_nth(lst, n) {
    if (length(lst) == 0) { nil }
    else { if (n == 0) { hd(lst) }
    else { list_nth(tl(lst), n - 1) } }
}

# count_done_tasks(tasks, acc) — count tasks with status 'done' or 'error'
fun count_done_tasks(tasks, acc) {
    if (length(tasks) == 0) { acc }
    else {
        t = hd(tasks)
        s = map_get(t, 'status')
        is_done = if (s == 'done') { 'true' }
                  else { if (s == 'error') { 'true' } else { 'false' } }
        new_acc = if (is_done == 'true') { acc + 1 } else { acc }
        count_done_tasks(tl(tasks), new_acc)
    }
}

# all_tasks_flat(phases, acc) — flatten all tasks across all phases.
# ++ concatenates: list_append would add each phase's task LIST as a
# single element, making length() count phases instead of tasks.
fun all_tasks_flat(phases, acc) {
    if (length(phases) == 0) { acc }
    else {
        p = hd(phases)
        ts = map_get(p, 'tasks')
        task_list = if (ts == nil) { [] } else { ts }
        all_tasks_flat(tl(phases), acc ++ task_list)
    }
}

# render_phases_panel(flow_state, start_row, height) -> unit
fun render_phases_panel(flow_state, start_row, height) {
    phases = map_get(flow_state, 'phases')
    phase_list = if (phases == nil) { [] } else { phases }
    selected = map_get(flow_state, 'selected_phase')
    selected_idx = if (selected == nil) { 0 } else { selected }
    body_rows = height - 4
    render_phases_rows(phase_list, start_row, body_rows, 0, selected_idx)
}

fun render_phases_rows(phases, start_row, max_rows, idx, selected_idx) {
    if (idx >= max_rows) { 'ok' }
    else {
        row = start_row + idx
        if (length(phases) == 0) {
            print_inline(
                goto(row, 1) ++
                UI.grey_text() ++ pad_right("", 21) ++ UI.reset() ++
                UI.grey_border() ++ "│" ++ UI.reset()
            )
            render_phases_rows([], start_row, max_rows, idx + 1, selected_idx)
        } else {
            phase = hd(phases)
            is_sel = idx == selected_idx
            render_phase_row(phase, row, is_sel)
            render_phases_rows(tl(phases), start_row, max_rows, idx + 1, selected_idx)
        }
    }
}

fun render_phase_row(phase, row, is_selected) {
    name = map_get(phase, 'name')
    tasks = map_get(phase, 'tasks')
    task_list = if (tasks == nil) { [] } else { tasks }
    name_str = if (name == nil) { "Phase" } else { to_string(name) }
    done = count_done_tasks(task_list, 0)
    total = length(task_list)
    prefix = if (is_selected == 'true') { "> " } else { "  " }
    progress = to_string(done) ++ "/" ++ to_string(total)
    name_t = trunc(name_str, 13)
    content = prefix ++ name_t
    content_padded = pad_right(content, 16)
    full = content_padded ++ " " ++ pad_right(progress, 4)
    all_done = done == total && total > 0
    col = if (all_done == 'true') { UI.green() } else { UI.grey_text() }
    sel_col = if (is_selected == 'true') { UI.ui_text() } else { col }
    print_inline(
        goto(row, 1) ++
        sel_col ++ pad_right(full, 21) ++ UI.reset() ++
        UI.grey_border() ++ "│" ++ UI.reset()
    )
}

# ============================================================
# Middle panel — agents / output (col 23..W-28)
# ============================================================

# render_agents_panel(flow_state, left_x, width, start_row, height) -> unit
fun render_agents_panel(flow_state, left_x, width, start_row, height) {
    phases = map_get(flow_state, 'phases')
    phase_list = if (phases == nil) { [] } else { phases }
    selected = map_get(flow_state, 'selected_phase')
    selected_idx = if (selected == nil) { 0 } else { selected }
    phase = list_nth(phase_list, selected_idx)
    tasks = if (phase == nil) { nil } else { map_get(phase, 'tasks') }
    task_list = if (tasks == nil) { [] } else { tasks }
    body_rows = height - 4
    focused_idx = find_focus_idx(task_list, 0, 0 - 1, 0 - 1)
    render_agents_rows(task_list, left_x, width, start_row, body_rows, 0, focused_idx)
}

# Find focus: first 'running' task; fallback to first 'pending'; fallback to 0
fun find_focus_idx(tasks, idx, running_idx, pending_idx) {
    if (length(tasks) == 0) {
        if (running_idx >= 0) { running_idx }
        else { if (pending_idx >= 0) { pending_idx }
        else { 0 }}
    } else {
        task = hd(tasks)
        status = map_get(task, 'status')
        status_val = if (status == nil) { 'pending' } else { status }
        new_running = if (status_val == 'running' && running_idx < 0) { idx } else { running_idx }
        new_pending = if (status_val == 'pending' && pending_idx < 0) { idx } else { pending_idx }
        find_focus_idx(tl(tasks), idx + 1, new_running, new_pending)
    }
}

fun render_agents_rows(tasks, left_x, width, start_row, max_rows, task_idx, focused_idx) {
    if (task_idx >= max_rows) { 'ok' }
    else {
        row = start_row + task_idx
        if (length(tasks) == 0) {
            render_agent_empty_row(left_x, width, row)
            render_agents_rows([], left_x, width, start_row, max_rows, task_idx + 1, focused_idx)
        } else {
            task = hd(tasks)
            is_focused = task_idx == focused_idx
            if (is_focused == 'true') {
                render_agent_focused(task, left_x, width, row)
            } else {
                render_agent_summary(task, left_x, width, row)
            }
            render_agents_rows(tl(tasks), left_x, width, start_row, max_rows, task_idx + 1, focused_idx)
        }
    }
}

fun render_agent_empty_row(left_x, width, row) {
    print_inline(
        goto(row, left_x) ++
        UI.grey_text() ++ pad_right("", width - 1) ++ UI.reset() ++
        "\e[K"
    )
}

# For the focused task, show its log tail (up to 4 lines)
# We use it for one line per call in the panel body for simplicity
fun render_agent_focused(task, left_x, width, row) {
    label = map_get(task, 'label')
    status = map_get(task, 'status')
    label_str = if (label == nil) { "task" } else { to_string(label) }
    status_val = if (status == nil) { 'pending' } else { status }
    status_word = to_string(status_val)
    col = status_color(status_val)
    content = "  " ++ col ++ "\e[1m" ++ trunc(label_str, 20) ++ UI.reset() ++
              UI.grey_text() ++ " – " ++ status_word ++ " ◀" ++ UI.reset()
    print_inline(
        goto(row, left_x) ++
        content ++
        "\e[K"
    )
}

fun render_agent_summary(task, left_x, width, row) {
    label = map_get(task, 'label')
    status = map_get(task, 'status')
    label_str = if (label == nil) { "task" } else { to_string(label) }
    status_val = if (status == nil) { 'pending' } else { status }
    status_word = to_string(status_val)
    col = status_color(status_val)
    label_trunc = trunc(label_str, 24)
    content = "  " ++ UI.grey_text() ++ label_trunc ++ " – " ++ col ++ status_word ++ UI.reset()
    print_inline(
        goto(row, left_x) ++
        content ++
        "\e[K"
    )
}

# ============================================================
# Right panel — stats (col W-27..W)
# ============================================================

# render_stats_panel(flow_state, left_x, start_row, height) -> unit
fun render_stats_panel(flow_state, left_x, start_row, height) {
    phases = map_get(flow_state, 'phases')
    phase_list = if (phases == nil) { [] } else { phases }
    selected = map_get(flow_state, 'selected_phase')
    selected_idx = if (selected == nil) { 0 } else { selected }
    phase = list_nth(phase_list, selected_idx)
    tasks = if (phase == nil) { nil } else { map_get(phase, 'tasks') }
    task_list = if (tasks == nil) { [] } else { tasks }
    body_rows = height - 4
    totals = sum_stats(task_list, 0, 0, 0)
    total_in = elem(totals, 0)
    total_out = elem(totals, 1)
    total_tools = elem(totals, 2)
    render_stats_rows(task_list, left_x, start_row, body_rows, 0,
                      total_in, total_out, total_tools, body_rows)
}

fun sum_stats(tasks, acc_in, acc_out, acc_tools) {
    if (length(tasks) == 0) { {acc_in, acc_out, acc_tools} }
    else {
        task = hd(tasks)
        tin  = map_get(task, 'tokens_in')
        tout = map_get(task, 'tokens_out')
        tc   = map_get(task, 'tool_calls')
        tin_n  = if (tin == nil)   { 0 } else { tin }
        tout_n = if (tout == nil)  { 0 } else { tout }
        tc_n   = if (tc == nil)    { 0 } else { tc }
        sum_stats(tl(tasks), acc_in + tin_n, acc_out + tout_n, acc_tools + tc_n)
    }
}

fun render_stats_rows(tasks, left_x, start_row, max_rows, idx,
                       total_in, total_out, total_tools, total_body_rows) {
    if (idx >= max_rows) { 'ok' }
    else {
        row = start_row + idx
        # Last row: aggregate summary
        is_last = idx == max_rows - 1
        if (is_last == 'true') {
            render_stats_summary(left_x, row, total_in, total_out, total_tools)
        } else {
            if (length(tasks) == 0) {
                render_stats_empty_row(left_x, row)
                render_stats_rows([], left_x, start_row, max_rows, idx + 1,
                                   total_in, total_out, total_tools, total_body_rows)
            } else {
                task = hd(tasks)
                render_stats_task_row(task, left_x, row)
                render_stats_rows(tl(tasks), left_x, start_row, max_rows, idx + 1,
                                   total_in, total_out, total_tools, total_body_rows)
            }
        }
    }
}

fun render_stats_empty_row(left_x, row) {
    border_col = left_x - 1
    print_inline(
        goto(row, border_col) ++
        UI.grey_border() ++ "│" ++ UI.reset() ++
        pad_right("", 27) ++
        "\e[K"
    )
}

fun render_stats_task_row(task, left_x, row) {
    label    = map_get(task, 'label')
    tin      = map_get(task, 'tokens_in')
    tout     = map_get(task, 'tokens_out')
    started  = map_get(task, 'started_ms')
    ended    = map_get(task, 'ended_ms')
    status   = map_get(task, 'status')
    label_str = if (label == nil) { "task" } else { to_string(label) }
    tin_n    = if (tin == nil)    { 0 } else { tin }
    tout_n   = if (tout == nil)   { 0 } else { tout }
    elapsed  = if (started == nil) { "—" } else { elapsed_str(started, ended) }
    status_v = if (status == nil) { 'pending' } else { status }
    border_col = left_x - 1
    label_t = trunc(label_str, 7)
    icon = status_icon(status_v)
    scol = status_color(status_v)
    # Fit within 26 visible chars: │<icon><sp><label7><sp><elapsed6>
    elapsed_t = trunc(elapsed, 6)
    content =
        UI.grey_border() ++ "│" ++ UI.reset() ++
        scol ++ icon ++ UI.reset() ++
        " " ++ teal_info() ++ pad_right(label_t, 7) ++ UI.reset() ++
        " " ++ UI.grey_text() ++ pad_right(elapsed_t, 6) ++ UI.reset()
    print_inline(
        goto(row, border_col) ++
        content ++
        "\e[K"
    )
}

fun render_stats_summary(left_x, row, total_in, total_out, total_tools) {
    border_col = left_x - 1
    in_str  = to_string(total_in)
    out_str = to_string(total_out)
    tc_str  = to_string(total_tools)
    content =
        UI.grey_border() ++ "│" ++ UI.reset() ++
        " " ++ UI.green() ++ "total" ++ UI.reset() ++
        " tools:" ++ UI.grey_text() ++ pad_right(tc_str, 4) ++ UI.reset() ++
        " i:" ++ UI.grey_text() ++ pad_right(in_str, 5) ++ UI.reset() ++
        " o:" ++ UI.grey_text() ++ out_str ++ UI.reset()
    print_inline(
        goto(row, border_col) ++
        content ++
        "\e[K"
    )
}

# ============================================================
# Status bar (row H, full width)
# ============================================================

# render_status_bar(term_w, term_h) -> unit
# (No key handling during the poll loop — abort is via the stop file.)
fun render_status_bar(term_w, term_h) {
    hint = "  touch /tmp/swarm-flows-stop to abort  ·  watching agents…"
    print_inline(
        goto(term_h, 1) ++
        UI.grey_border() ++ repeat_char("─", term_w) ++ UI.reset() ++
        goto(term_h, 1) ++
        UI.grey_text() ++ hint ++ UI.reset()
    )
}

fun render_status_bar_n(term_w, term_h, n_agents) {
    hint = "  touch /tmp/swarm-flows-stop to abort  ·  watching " ++
           to_string(n_agents) ++ " agents…"
    print_inline(
        goto(term_h, 1) ++
        UI.grey_border() ++ repeat_char("─", term_w) ++ UI.reset() ++
        goto(term_h, 1) ++
        UI.grey_text() ++ hint ++ UI.reset()
    )
}

# ============================================================
# Full frame render
# ============================================================

# render_frame(flow_state, term_w, term_h) -> unit
#   Redraws the entire 3-panel TUI in the alt-screen buffer.
fun render_frame(flow_state, term_w, term_h) {
    flow_name = map_get(flow_state, 'name')
    name_str  = if (flow_name == nil) { "flow" } else { to_string(flow_name) }
    phase     = map_get(flow_state, 'phase')
    phase_val = if (phase == nil) { 'running' } else { phase }

    # Clear screen and home
    print_inline("\e[2J\e[H")

    # Row 1: Title bar
    render_title_bar(name_str, phase_val, term_w)

    # Row 2: Panel headers
    render_panel_headers(term_w)

    # Row 3: Top border
    render_top_border(term_w, 3)

    # Rows 4..(H-2): Panel body. Panels compute body_rows = height - 4
    # starting at row 4, so pass term_h - 1 to keep the last body row
    # at H-2 — clear of the bottom border drawn at H-1.
    body_start = 4
    body_height = term_h - 1

    # Left panel (col 1..22)
    render_phases_panel(flow_state, body_start, body_height)

    # Middle panel (col 23..W-28)
    mid_left = 23
    mid_width = term_w - 50
    render_agents_panel(flow_state, mid_left, mid_width, body_start, body_height)

    # Right panel (col W-27..W, border at W-28)
    right_left = term_w - 26
    render_stats_panel(flow_state, right_left, body_start, body_height)

    # Row H-1: Bottom border
    render_bottom_border(term_w, term_h - 1)

    # Row H: Status bar — count all tasks across all phases
    phases_all = map_get(flow_state, 'phases')
    phases_all_list = if (phases_all == nil) { [] } else { phases_all }
    all_tasks = all_tasks_flat(phases_all_list, [])
    n_tasks = length(all_tasks)
    render_status_bar_n(term_w, term_h, n_tasks)
}
