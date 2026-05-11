module UI

# ============================================================
# UI — terminal rendering for swarm-code
# ============================================================
#
# After reading Claude Code's actual render components
# (AssistantToolUseMessage.tsx + MessageResponse.tsx + theme.ts),
# this module mirrors CC's visual conventions:
#
#   ⏺ ToolName(args preview)        ← black circle + bold name + args in parens
#     ⎿  first line of result       ← dim elbow gutter + result
#        continuation indented      ← result continues aligned under ⎿'s content col
#
#   ▌ user input                    ← left bar prompt (CC uses rounded-bottom border)
#   ─────────────────────────────
#    model · tokens · /help · /quit
#
# Theme: deep red (Otonomy brand) as primary, instead of CC's Claude-orange.
# Primary:   \e[38;5;124m  (0xaf0000 — deep red)
# Secondary: \e[38;5;88m   (0x870000 — darker red)
# Dim grey:  \e[38;5;240m  — borders
# Mid grey:  \e[38;5;244m  — footer text
# Teal:      \e[38;5;80m   — info values
#
# SWARM_CODE_TUI=1 enters alt-screen; default is in-place with native scrollback.

export [
    banner, divider, brand_color, brand_dark, reset,
    tool_header, tool_result,
    rationale_box, answer_box,
    input_prompt, input_box_top, input_box_bottom, input_box_bottom_full,
    input_divider, footer_hint,
    status_line, spinner_start, spinner_stop,
    enter_alt_screen, leave_alt_screen,
    term_width,
    todo_list_render, todo_summary,
    green, grey_text, grey_border
]

# ------------------------------------------------------------
# Brand colors — deep red (Otonomy)
# ------------------------------------------------------------
fun brand_color() { "\e[38;5;124m" }   # 0xaf0000 — deep red
fun brand_dark()  { "\e[38;5;88m"  }   # 0x870000 — darker red
fun brand_dim()   { "\e[38;5;52m"  }   # 0x5f0000 — very dark red (borders)
fun grey_border() { "\e[38;5;240m" }
fun grey_text()   { "\e[38;5;244m" }
fun teal_info()   { "\e[38;5;80m"  }
fun reset()       { "\e[0m" }

# ------------------------------------------------------------
# Terminal width via ioctl(TIOCGWINSZ) — the sw builtin `term_cols`
# tries stdout, stderr, and /dev/tty so it works even when the process
# was spawned with pipes. The old `tput cols` via shell() path always
# returned 80 because tput's stdout was the pipe back to swarm-code.
# ------------------------------------------------------------
fun term_width() {
    n = term_cols()
    if (n <= 0) { 80 } else { n }
}

fun parse_int(s, fallback) {
    parse_int_loop(s, 0, 0, fallback)
}

fun parse_int_loop(s, i, acc, fallback) {
    if (i >= string_length(s)) {
        if (acc == 0) { fallback } else { acc }
    } else {
        ch = string_sub(s, i, 1)
        digit = char_to_digit(ch)
        if (digit < 0) {
            if (acc == 0) { fallback } else { acc }
        } else {
            parse_int_loop(s, i + 1, acc * 10 + digit, fallback)
        }
    }
}

fun char_to_digit(ch) {
    if (ch == "0") { 0 }
    else { if (ch == "1") { 1 }
    else { if (ch == "2") { 2 }
    else { if (ch == "3") { 3 }
    else { if (ch == "4") { 4 }
    else { if (ch == "5") { 5 }
    else { if (ch == "6") { 6 }
    else { if (ch == "7") { 7 }
    else { if (ch == "8") { 8 }
    else { if (ch == "9") { 9 }
    else { 0 - 1 }}}}}}}}}}
}

# ------------------------------------------------------------
# Banner — printed once at startup
# ------------------------------------------------------------
fun banner(model_name, endpoint, cwd) {
    w = term_width()
    print("")
    print(" " ++ brand_color() ++ "\e[1m⏺ swarm-code" ++ reset() ++ " " ++ grey_text() ++ "· the fine sw coding agent" ++ reset())
    print("")
    print(" " ++ grey_text() ++ "model   " ++ reset() ++ " " ++ teal_info() ++ model_name ++ reset())
    print(" " ++ grey_text() ++ "endpoint" ++ reset() ++ " " ++ teal_info() ++ endpoint ++ reset())
    print(" " ++ grey_text() ++ "cwd     " ++ reset() ++ " " ++ teal_info() ++ cwd ++ reset())
    print("")
    print(" " ++ grey_text() ++ "/help for commands · /quit to exit" ++ reset())
    print(full_divider(w))
}

fun full_divider(width) {
    grey_border() ++ repeat_char("─", width) ++ reset()
}

fun repeat_char(ch, n) {
    if (n <= 0) { "" }
    else {
        if (n == 1) { ch }
        else { ch ++ repeat_char(ch, n - 1) }
    }
}

fun divider() {
    print("")
}

# ------------------------------------------------------------
# Tool call header — matching CC's exact format:
#   ⏺ ToolName(args)
# Black circle in brand color, tool name bold, args in normal parens.
# Indented 2 cols to line up with the bordered input box's content.
# ------------------------------------------------------------
fun tool_header(name, args_preview) {
    display_name = capitalize_first(to_string(name))
    print("")
    print("  " ++ brand_color() ++ "⏺" ++ reset() ++ " \e[1m" ++ display_name ++ "\e[0m(" ++ args_preview ++ ")")
}

# Capitalize first letter of a tool name (bash → Bash, multi_edit → Multi_edit)
fun capitalize_first(s) {
    if (string_length(s) == 0) { "" }
    else {
        first = string_sub(s, 0, 1)
        rest = string_sub(s, 1, string_length(s) - 1)
        string_upper(first) ++ rest
    }
}

# ------------------------------------------------------------
# Tool result — matching CC's MessageResponse format:
#   "  ⎿  first line
#        continuation"
# The elbow ⎿ is dim grey, leading the first line. Continuations
# align under the first result character (5-space indent).
# ------------------------------------------------------------
fun tool_result(text) {
    lines = string_split(text, "\n")
    preview_lines = take_n_lines(lines, 8, [])
    total = length(lines)
    rendered = render_result_lines(preview_lines, 0)
    print(rendered)
    if (total > 8) {
        print("     " ++ grey_text() ++ "… +" ++ to_string(total - 8) ++ " more lines" ++ reset())
    }
}

fun render_result_lines(lines, i) {
    if (length(lines) == 0) {
        ""
    } else {
        render_result_loop(lines, i, "")
    }
}

fun render_result_loop(lines, i, acc) {
    if (length(lines) == 0) {
        acc
    } else {
        line = hd(lines)
        prefix = if (i == 0) {
            "    " ++ grey_border() ++ "⎿" ++ reset() ++ "  " ++ grey_text()
        } else {
            "       " ++ grey_text()
        }
        new_line = prefix ++ line ++ reset()
        new_acc = if (string_length(acc) == 0) {
            new_line
        } else {
            acc ++ "\n" ++ new_line
        }
        render_result_loop(tl(lines), i + 1, new_acc)
    }
}

fun take_n_lines(lines, n, acc) {
    if (n <= 0) { acc }
    else {
        if (length(lines) == 0) { acc }
        else { take_n_lines(tl(lines), n - 1, list_append(acc, hd(lines))) }
    }
}

# ------------------------------------------------------------
# Rationale — inline dim text that appears before tool calls
# ------------------------------------------------------------
fun rationale_box(text) {
    print("")
    print(grey_text() ++ string_trim(text) ++ reset())
}

# Final answer — bold assistant response with breathing room
fun answer_box(text) {
    print("")
    print("\e[1m" ++ text ++ "\e[0m")
    print("")
}

# ------------------------------------------------------------
# Input box — Claude-Code-style bordered prompt
# ------------------------------------------------------------
# CC draws a rounded-border box with only top + bottom rails (no sides):
#   ╭────────────────────────────────────────╮
#     ❯ user types here
#   ╰────────────────────────────────────────╯
#     ⏎ send · /help · /quit   model · N tokens
#
# Reader calls input_box_top() then read_line(input_prompt()); after
# submit, agent.handle_user_input_msg calls input_box_bottom(model, tokens).
# ------------------------------------------------------------
fun input_box_top() {
    w = term_width()
    print("")
    print(grey_border() ++ "╭" ++ repeat_char("─", w - 2) ++ "╮" ++ reset())
}

fun input_box_bottom(model_name, token_count) {
    input_box_bottom_full(model_name, token_count, 0)
}

fun input_box_bottom_full(model_name, token_count, budget) {
    w = term_width()
    print(grey_border() ++ "╰" ++ repeat_char("─", w - 2) ++ "╯" ++ reset())
    token_str = if (budget > 0) {
        format_tokens_short(token_count) ++ " / " ++ format_tokens_short(budget)
    } else {
        format_tokens(token_count)
    }
    # Color the token count based on usage ratio
    colored_tokens = if (budget > 0 && token_count > 0) {
        ratio = (token_count * 100) / budget
        if (ratio > 85) { "\e[38;5;196m" ++ token_str ++ reset() }       # red — near limit
        else { if (ratio > 60) { "\e[38;5;208m" ++ token_str ++ reset() } # orange — getting there
        else { token_str }}
    } else { token_str }
    print("  " ++ grey_text() ++ "⏎ send  ·  /help  ·  /quit  ·  " ++
          model_name ++ "  ·  " ++ colored_tokens ++ reset())
}

# Short format: "3.7k" (no " tokens" suffix) for the budget display
fun format_tokens_short(n) {
    if (n < 1000) { to_string(n) }
    else { if (n < 1000000) { format_k_short(n) }
    else { format_m_short(n) }}
}

fun format_k_short(n) {
    k10 = n / 100
    whole = k10 / 10
    frac = k10 - (whole * 10)
    if (frac == 0) { to_string(whole) ++ "k" }
    else { to_string(whole) ++ "." ++ to_string(frac) ++ "k" }
}

fun format_m_short(n) {
    m10 = n / 100000
    whole = m10 / 10
    frac = m10 - (whole * 10)
    if (frac == 0) { to_string(whole) ++ "M" }
    else { to_string(whole) ++ "." ++ to_string(frac) ++ "M" }
}

# Format a token count like Claude Code does: "3.4k" once past 1000,
# "1.2M" past a million, raw integer below 1000.
fun format_tokens(n) {
    if (n < 1000) { to_string(n) ++ " tokens" }
    else { if (n < 1000000) { format_k(n) }
    else { format_m(n) }}
}

fun format_k(n) {
    k10 = n / 100
    whole = k10 / 10
    frac = k10 - (whole * 10)
    if (frac == 0) { to_string(whole) ++ "k tokens" }
    else { to_string(whole) ++ "." ++ to_string(frac) ++ "k tokens" }
}

fun format_m(n) {
    m10 = n / 100000
    whole = m10 / 10
    frac = m10 - (whole * 10)
    if (frac == 0) { to_string(whole) ++ "M tokens" }
    else { to_string(whole) ++ "." ++ to_string(frac) ++ "M tokens" }
}

# Prompt string passed to read_line. Two-space left margin (aligns with
# the box's content column) plus the ❯ chevron and a space.
fun input_prompt() {
    "  " ++ brand_color() ++ "❯" ++ reset() ++ " "
}

# Legacy — kept for slash commands that still reference it.
fun input_divider() {
    w = term_width()
    print(grey_border() ++ repeat_char("─", w) ++ reset())
}

# ------------------------------------------------------------
# Status line (transient \r-based)
# ------------------------------------------------------------
fun status_line(text) {
    print_inline("\r\e[K" ++ grey_text() ++ text ++ reset())
}

# Footer hint line below input divider
fun footer_hint(model_name, token_count) {
    print(" " ++ grey_text() ++ model_name ++ "  ·  " ++ to_string(token_count) ++
          " tokens  ·  /help · /quit" ++ reset())
}

# ------------------------------------------------------------
# Spinner
# ------------------------------------------------------------
fun spinner_start(label) {
    print_inline("\r\e[K " ++ brand_color() ++ "◐" ++ reset() ++ " " ++ grey_text() ++ label ++ "…" ++ reset())
}

fun spinner_stop() {
    print_inline("\r\e[K")
}

# ------------------------------------------------------------
# Alt-screen mode
# ------------------------------------------------------------
fun enter_alt_screen() {
    print_inline("\e[?1049h\e[2J\e[H")
}

fun leave_alt_screen() {
    print_inline("\e[?1049l")
}

# ------------------------------------------------------------
# Todo list rendering — Claude-Code-style task checklist
# ------------------------------------------------------------
# Status icons (Unicode):
#   completed   → ✔  (green)
#   in_progress → ◼  (brand/clay)
#   pending     → ◻  (default)
#
# Completed items get strikethrough + dim.
# In-progress items get bold.
# Pending items are normal.

fun green()      { "\e[38;5;78m" }
fun strikethrough() { "\e[9m" }
fun dim()        { "\e[2m" }
fun bold()       { "\e[1m" }

# Render a todo list (sw list of maps) to a formatted string.
# Each map has: id, content, status.
fun todo_list_render(todos) {
    if (length(todos) == 0) {
        grey_text() ++ "  (no tasks)" ++ reset()
    } else {
        todo_render_loop(todos, "")
    }
}

fun todo_render_loop(todos, acc) {
    if (length(todos) == 0) { acc }
    else {
        item = hd(todos)
        line = todo_render_item(item)
        new_acc = if (string_length(acc) == 0) { line }
                  else { acc ++ "\n" ++ line }
        todo_render_loop(tl(todos), new_acc)
    }
}

fun todo_render_item(item) {
    status = map_get(item, 'status')
    content = map_get(item, 'content')
    id_val = map_get(item, 'id')
    s = if (status == nil) { "pending" } else { to_string(status) }
    c = if (content == nil) { "(untitled)" } else { to_string(content) }
    todo_format_line(s, c)
}

fun todo_format_line(status, content) {
    if (status == "completed") {
        "  " ++ green() ++ "✔" ++ reset() ++ " " ++
        dim() ++ strikethrough() ++ content ++ reset()
    } else {
        if (status == "in_progress") {
            "  " ++ brand_color() ++ "◼" ++ reset() ++ " " ++
            bold() ++ content ++ reset()
        } else {
            "  " ++ grey_text() ++ "◻" ++ reset() ++ " " ++ content
        }
    }
}

# Render a compact summary line: "2 pending, 1 in_progress, 1 completed"
fun todo_summary(todos) {
    counts = todo_count_statuses(todos, 0, 0, 0)
    p = elem(counts, 0)
    ip = elem(counts, 1)
    c = elem(counts, 2)
    parts = todo_summary_parts(p, ip, c, [])
    if (length(parts) == 0) { "no tasks" }
    else { join_with(parts, ", ") }
}

fun todo_count_statuses(todos, pending, in_prog, done) {
    if (length(todos) == 0) { {pending, in_prog, done} }
    else {
        item = hd(todos)
        s = map_get(item, 'status')
        status = if (s == nil) { "pending" } else { to_string(s) }
        if (status == "completed") {
            todo_count_statuses(tl(todos), pending, in_prog, done + 1)
        } else {
            if (status == "in_progress") {
                todo_count_statuses(tl(todos), pending, in_prog + 1, done)
            } else {
                todo_count_statuses(tl(todos), pending + 1, in_prog, done)
            }
        }
    }
}

fun todo_summary_parts(pending, in_prog, done, acc) {
    a1 = if (in_prog > 0) {
        list_append(acc, brand_color() ++ to_string(in_prog) ++ " in progress" ++ reset())
    } else { acc }
    a2 = if (pending > 0) {
        list_append(a1, to_string(pending) ++ " pending")
    } else { a1 }
    a3 = if (done > 0) {
        list_append(a2, green() ++ to_string(done) ++ " done" ++ reset())
    } else { a2 }
    a3
}

fun join_with(parts, sep) {
    if (length(parts) == 0) { "" }
    else { join_with_loop(tl(parts), sep, hd(parts)) }
}

fun join_with_loop(parts, sep, acc) {
    if (length(parts) == 0) { acc }
    else { join_with_loop(tl(parts), sep, acc ++ sep ++ hd(parts)) }
}
