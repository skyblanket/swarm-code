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
    tool_header, tool_result, edit_diff_render,
    rationale_box, answer_box,
    input_prompt, input_box_top, input_box_bottom, input_box_bottom_full,
    input_divider, footer_hint,
    status_line, spinner_start, spinner_stop,
    tool_progress, tool_progress_clear,
    enter_alt_screen, leave_alt_screen,
    term_width,
    todo_list_render, todo_summary,
    green, grey_text, grey_border, ui_text, warn_color, err_color, accent_color,
    agent_color, agent_tool_header, agent_emit_render,
    agent_reply_render, agent_block_leave, agents_table,
    stream_chunk_render, stream_reason_render, stream_done_render
]

# ------------------------------------------------------------
# Palette — Otonomy deep-red brand + OpenCode-derived neutrals and
# semantic colors (truecolor). The red is the brand identity;
# everything around it is tuned to OpenCode's calm dark theme.
# ------------------------------------------------------------
# NO_COLOR (https://no-color.org): any non-empty value disables ALL
# color emission. Bold/dim/strike survive — they're formatting, not
# color. reset() stays live so formatting still closes correctly.
fun colors_off() {
    v = getenv("NO_COLOR")
    if (v == nil) { 'false' }
    else { if (string_length(to_string(v)) > 0) { 'true' } else { 'false' } }
}

fun paint(code) { if (colors_off() == 'true') { "" } else { code } }

fun brand_color() { paint("\e[38;2;175;0;0m") }     # #af0000 — deep red (brand/primary)
fun brand_dark()  { paint("\e[38;2;135;0;0m") }     # #870000 — darker red
fun brand_dim()   { paint("\e[38;2;95;0;0m")  }     # #5f0000 — very dark red

# OpenCode dark-theme neutrals (step scale).
fun grey_border() { paint("\e[38;2;72;72;72m")    } # #484848 — borders
fun grey_text()   { paint("\e[38;2;128;128;128m") } # #808080 — muted / secondary text
fun ui_text()     { paint("\e[38;2;238;238;238m") } # #eeeeee — primary text

# OpenCode semantic colors.
fun teal_info()   { paint("\e[38;2;86;182;194m")  } # #56b6c2 — info / cyan
fun warn_color()  { paint("\e[38;2;245;167;66m")  } # #f5a742 — warning / orange
fun err_color()   { paint("\e[38;2;224;108;117m") } # #e06c75 — error / red
fun accent_color(){ paint("\e[38;2;157;124;216m") } # #9d7cd8 — accent / purple
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
    if (w >= 64) { banner_art() } else { print("") }
    print(" " ++ brand_color() ++ "\e[1m⏺ swarm-code" ++ reset() ++ " " ++ grey_text() ++ "· the fine sw coding agent" ++ reset() ++ "  " ++ seal())
    print("")
    print(" " ++ grey_text() ++ "model   " ++ reset() ++ " " ++ teal_info() ++ model_name ++ reset())
    print(" " ++ grey_text() ++ "endpoint" ++ reset() ++ " " ++ teal_info() ++ endpoint ++ reset())
    print(" " ++ grey_text() ++ "cwd     " ++ reset() ++ " " ++ teal_info() ++ cwd ++ reset())
    print("")
    print(" " ++ grey_text() ++ "/help for commands · /quit to exit" ++ reset())
    print(full_divider(w))
}

# Ink-brush dragonfly, side profile — wings swept up-right with red
# pterostigma dots, long antenna trailing left, segmented tail with an
# upturned tip. Skipped entirely under 64 cols.
fun banner_art() {
    g = grey_text()
    b = ui_text()
    r = brand_color()
    x = reset()
    print("")
    print(g ++ "                                     _.-~~-)" ++ x)
    print(g ++ "                              _.-~~ " ++ r ++ "●" ++ g ++ " _.-~/" ++ x)
    print(g ++ "                         _.-~  ,  _.-~ " ++ r ++ "●" ++ g ++ ",/" ++ x)
    print(g ++ "                     .-~  ,  _.-~ , _.-~" ++ x)
    print(g ++ "                    ( ,  _.-~ , _.-~" ++ x)
    print(g ++ "               __   (_.-~ ,_.-~" ++ x)
    print(g ++ "    `~-.._    " ++ x ++ b ++ "((" ++ r ++ "@" ++ b ++ "__().-~~" ++ x)
    print(b ++ "          `~~--=(   )==,__" ++ x)
    print(g ++ "                / /~\\ \\_   `==,__" ++ x)
    print(g ++ "               ( (   \\ `\\_,     `==,_" ++ x)
    print(g ++ "                \\_)    `~-._        `=~-'" ++ x)
    print(g ++ "                            `~--`" ++ x)
    print("")
}

# Hanko-style red seal — a nod to the stamp on the reference art.
fun seal() {
    if (colors_off() == 'true') { "" }
    else { "\e[48;2;135;0;0m\e[38;2;238;238;238m\e[1m sw \e[0m" }
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
# Edit diff preview — colored ± lines under the tool result, so the
# user sees WHAT changed instead of just "ok: edited path".
#   - old   ← red,  capped
#   + new   ← green, capped
# ------------------------------------------------------------
fun edit_diff_render(old_s, new_s) {
    o = if (old_s == nil) { "" } else { to_string(old_s) }
    n = if (new_s == nil) { "" } else { to_string(new_s) }
    if (string_length(o) > 0) {
        diff_side(string_split(o, "\n"), "-", err_color(), 4)
    }
    if (string_length(n) > 0) {
        diff_side(string_split(n, "\n"), "+", green(), 4)
    }
}

fun diff_side(lines, sign, color, cap) {
    total = length(lines)
    shown = take_n_lines(lines, cap, [])
    diff_lines_loop(shown, sign, color)
    if (total > cap) {
        print("       " ++ grey_text() ++ "… " ++ to_string(total - cap) ++
              " more " ++ sign ++ " lines" ++ reset())
    }
}

fun diff_lines_loop(lines, sign, color) {
    if (length(lines) == 0) { 'ok' }
    else {
        print("     " ++ color ++ sign ++ " " ++ hd(lines) ++ reset())
        diff_lines_loop(tl(lines), sign, color)
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
# Spacer line above the input prompt. The bordered box was dropped —
# the input is a single ❯ line now, so print_above() can keep it
# pinned to the bottom while async output streams in above it.
fun input_box_top() {
    print("")
}

fun input_box_bottom(model_name, token_count) {
    input_box_bottom_full(model_name, token_count, 0)
}

fun input_box_bottom_full(model_name, token_count, budget) {
    token_str = if (budget > 0) {
        format_tokens_short(token_count) ++ " / " ++ format_tokens_short(budget)
    } else {
        format_tokens(token_count)
    }
    # Token count tints toward warning/error as the budget fills.
    colored_tokens = if (budget > 0 && token_count > 0) {
        ratio = (token_count * 100) / budget
        if (ratio > 85) { err_color() ++ token_str ++ reset() }
        else { if (ratio > 60) { warn_color() ++ token_str ++ reset() }
        else { grey_text() ++ token_str ++ reset() }}
    } else { grey_text() ++ token_str ++ reset() }
    # Footer: one calm muted line — slash-help hint · model · token meter.
    print("  " ++ grey_text() ++ "/help  ·  " ++ model_name ++ "  ·  " ++
          reset() ++ colored_tokens)
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

# Transient "still running" line for a long non-LLM tool wait. Mirrors the
# LLM wait_hint look (dim grey ⋯) but lives on its own \r line so each
# refresh overwrites the prior one. Cleared by tool_progress_clear() on
# completion. No C-runtime coupling — the LLM spinner owns http_post_stream.
fun tool_progress(label, elapsed_sec) {
    print_inline("\r\e[K  \e[38;5;240m⋯ " ++ to_string(label) ++
                 " still running (" ++ to_string(elapsed_sec) ++ "s)\e[0m")
}

fun tool_progress_clear() {
    print_inline("\r\e[K")
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

fun green()      { paint("\e[38;2;127;216;143m") }   # #7fd88f — success (OpenCode)
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

# ============================================================
# Swarm — multi-agent rendering
# ============================================================
#
# When the main agent has spawned subagents, their activity needs to
# appear in the same single TUI as main's own work. We give each agent
# a deterministic color (hashed from name) and prefix every line with
# its name in that color, like a chat-app username column.
#
# Three render functions:
#   agent_tool_header(name, tool, args_raw)
#       [name] ⏺ Tool(args)            — agent did a tool call
#   agent_emit_render(name, content)
#       [name] │ content                — async push from agent
#   agent_reply_render(name, content)
#       [name] ⎿ content                — final reply from an `ask`
#   agents_table(reg, names)
#       └── pretty list_agents output

# Deterministic ANSI color from name. 8 vivid 256-color palette
# entries, picked to be readable on dark backgrounds and distinct
# from the brand red. Hash is djb2-style summed over UTF-8 bytes.
fun agent_color(name) {
    h = djb2_hash(name, 5381)
    # sw has no `%` modulo operator; do it the long way.
    palette_idx = h - (h / 8) * 8
    paint(pick_palette(palette_idx))
}

fun djb2_hash(s, h) {
    if (string_length(s) == 0) { h }
    else {
        ch = string_sub(s, 0, 1)
        rest = string_sub(s, 1, string_length(s) - 1)
        # ((h << 5) + h) + ord(ch)  ==  h * 33 + ord(ch)
        new_h = h * 33 + char_ord(ch)
        djb2_hash(rest, new_h)
    }
}

fun char_ord(ch) {
    # Approximate ord via comparison ladder for ASCII letters/digits;
    # other chars fold to 0. Good enough for color hashing.
    if (ch == "a") { 97 } else { if (ch == "b") { 98 } else { if (ch == "c") { 99 }
    else { if (ch == "d") { 100 } else { if (ch == "e") { 101 } else { if (ch == "f") { 102 }
    else { if (ch == "g") { 103 } else { if (ch == "h") { 104 } else { if (ch == "i") { 105 }
    else { if (ch == "j") { 106 } else { if (ch == "k") { 107 } else { if (ch == "l") { 108 }
    else { if (ch == "m") { 109 } else { if (ch == "n") { 110 } else { if (ch == "o") { 111 }
    else { if (ch == "p") { 112 } else { if (ch == "q") { 113 } else { if (ch == "r") { 114 }
    else { if (ch == "s") { 115 } else { if (ch == "t") { 116 } else { if (ch == "u") { 117 }
    else { if (ch == "v") { 118 } else { if (ch == "w") { 119 } else { if (ch == "x") { 120 }
    else { if (ch == "y") { 121 } else { if (ch == "z") { 122 }
    else { if (ch == "-") { 45 } else { if (ch == "_") { 95 }
    else { if (ch == "0") { 48 } else { if (ch == "1") { 49 } else { if (ch == "2") { 50 }
    else { if (ch == "3") { 51 } else { if (ch == "4") { 52 } else { if (ch == "5") { 53 }
    else { if (ch == "6") { 54 } else { if (ch == "7") { 55 } else { if (ch == "8") { 56 }
    else { if (ch == "9") { 57 } else { 0 }}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}
}

fun pick_palette(i) {
    if (i == 0) { "\e[38;2;92;156;245m"  }          # blue    #5c9cf5
    else { if (i == 1) { "\e[38;2;245;167;66m"  }   # orange  #f5a742
    else { if (i == 2) { "\e[38;2;157;124;216m" }   # purple  #9d7cd8
    else { if (i == 3) { "\e[38;2;86;182;194m"  }   # cyan    #56b6c2
    else { if (i == 4) { "\e[38;2;229;192;123m" }   # yellow  #e5c07b
    else { if (i == 5) { "\e[38;2;224;108;117m" }   # red     #e06c75
    else { if (i == 6) { "\e[38;2;127;216;143m" }   # green   #7fd88f
    else { "\e[38;2;255;192;159m"  }}}}}}}          # peach   #ffc09f
}

fun agent_prefix(name) {
    agent_color(name) ++ "[" ++ name ++ "]" ++ reset()
}

# ============================================================
# Grouped agent blocks
# ============================================================
# A subagent's activity renders as a block: a header line
# (▌ name · role) printed once, then every following line carried on
# a colored ▌ gutter in the agent's hue. The block stays open while
# the same agent keeps producing output; a different agent — or the
# agent's final reply — closes it. State lives in the stream_state
# ETS table, threaded through opts:
#   'block' → name of the agent whose block is open (or nil)
#   'sline' → 'prose' | 'reason' | nil — a streaming line is mid-flight
# ------------------------------------------------------------

# Role string for an agent, read from the registry handle in opts.
# Empty when unknown — no hard dependency on the Agents module.
fun agent_role(opts, name) {
    reg = map_get(opts, 'swarm_registry')
    if (reg == nil) { "" }
    else {
        e = ets_get(reg, name)
        if (e == nil) { "" }
        else {
            r = map_get(e, 'role')
            if (r == nil) { "" } else { to_string(r) }
        }
    }
}

# Colored gutter prefix for a body line inside an agent's block.
fun agent_gutter(name) {
    "  " ++ agent_color(name) ++ "▌" ++ reset() ++ " "
}

# Close a mid-stream gutter line, if one is open.
fun agent_sline_close(tbl) {
    if (tbl != nil) {
        if (ets_get(tbl, 'sline') != nil) {
            print(reset())
            ets_put(tbl, 'sline', nil)
        }
    }
}

# Ensure `name`'s block is the open one. If a different agent's block
# (or none) is current, close it and print this agent's header.
fun agent_block_enter(opts, name) {
    tbl = map_get(opts, 'stream_state_table')
    if (tbl == nil) { 'ok' }
    else {
        if (ets_get(tbl, 'block') == name) { 'ok' }
        else {
            agent_sline_close(tbl)
            role = agent_role(opts, name)
            role_str = if (string_length(role) == 0) { "" }
                       else { "  " ++ grey_text() ++ "· " ++ role ++ reset() }
            print_above("")
            print_above("  " ++ agent_color(name) ++ "▌ \e[1m" ++ name ++ "\e[0m" ++
                  reset() ++ role_str)
            ets_put(tbl, 'block', name)
            ets_put(tbl, 'sline', nil)
        }
    }
}

# Close the open agent block, if any — called when the main agent
# takes over (a new user turn) or an agent's run ends.
fun agent_block_leave(opts) {
    tbl = map_get(opts, 'stream_state_table')
    if (tbl != nil) {
        agent_sline_close(tbl)
        if (ets_get(tbl, 'block') != nil) { ets_put(tbl, 'block', nil) }
    }
}

# A subagent's tool call — rendered on its block gutter.
fun agent_tool_header(opts, name, tool, args_preview) {
    agent_block_enter(opts, name)
    agent_sline_close(map_get(opts, 'stream_state_table'))
    cap_name = capitalize_first(to_string(tool))
    print_above(agent_gutter(name) ++ brand_color() ++ "⏺" ++ reset() ++
          " \e[1m" ++ cap_name ++ "\e[0m  " ++ grey_text() ++
          to_string(args_preview) ++ reset())
}

# An async push from a subagent (status notices, mid-task discovery).
fun agent_emit_render(opts, name, content) {
    agent_block_enter(opts, name)
    agent_sline_close(map_get(opts, 'stream_state_table'))
    print_above(agent_gutter(name) ++ to_string(content))
}

# Final reply from an agent (resolves an `ask`). Renders with an
# elbow on the gutter, then closes the block.
fun agent_reply_render(opts, name, content) {
    agent_block_enter(opts, name)
    agent_sline_close(map_get(opts, 'stream_state_table'))
    print_above(agent_gutter(name) ++ brand_color() ++ "⎿" ++ reset() ++ " " ++
          to_string(content))
    agent_block_leave(opts)
}

# ------------------------------------------------------------
# Streaming render — {'stream_chunk'} (prose) and {'stream_reason'}
# (thinking) chunks from a subagent. Token-by-token chunks merge onto
# one gutter line; an agent switch or {'stream_done'} breaks it.
# ------------------------------------------------------------
fun stream_chunk_render(opts, name, content) {
    agent_block_enter(opts, name)
    tbl = map_get(opts, 'stream_state_table')
    if (tbl == nil) { print_inline(to_string(content)) }
    else {
        if (ets_get(tbl, 'sline') == 'prose') {
            print_inline(to_string(content))
        } else {
            agent_sline_close(tbl)
            print_inline(agent_gutter(name) ++ to_string(content))
            ets_put(tbl, 'sline', 'prose')
        }
    }
}

# Reasoning chunks render dim + italic on the gutter.
fun stream_reason_render(opts, name, content) {
    agent_block_enter(opts, name)
    tbl = map_get(opts, 'stream_state_table')
    if (tbl == nil) { print_inline(to_string(content)) }
    else {
        if (ets_get(tbl, 'sline') == 'reason') {
            print_inline(to_string(content))
        } else {
            agent_sline_close(tbl)
            print_inline(agent_gutter(name) ++ grey_text() ++ "\e[3m")
            print_inline(to_string(content))
            ets_put(tbl, 'sline', 'reason')
        }
    }
}

fun stream_done_render(opts, name) {
    agent_sline_close(map_get(opts, 'stream_state_table'))
}

# Render the registry as a table. `names` is the list to show in order.
# Columns: name (colored), role, status, tokens, age.
fun agents_table(reg, names) {
    header = "  " ++ grey_text() ++ "name              role            status   tokens     age" ++ reset()
    rows = render_agent_rows(reg, names, "")
    if (string_length(rows) == 0) { header ++ "\n  " ++ grey_text() ++ "(no agents)" ++ reset() }
    else { header ++ "\n" ++ rows }
}

fun render_agent_rows(reg, names, acc) {
    if (length(names) == 0) { acc }
    else {
        n = hd(names)
        e = ets_get(reg, n)
        line = if (e == nil) { "" } else { format_agent_row(n, e) }
        new_acc = if (string_length(acc) == 0) { line } else { acc ++ "\n" ++ line }
        render_agent_rows(reg, tl(names), new_acc)
    }
}

fun format_agent_row(name, entry) {
    role = to_string(map_get(entry, 'role'))
    status_v = map_get(entry, 'status')
    status = if (status_v == nil) { "?" } else { to_string(status_v) }
    tokens_v = map_get(entry, 'tokens_used')
    tokens = if (tokens_v == nil) { "0" } else { to_string(tokens_v) }
    spawned_v = map_get(entry, 'spawned_at')
    age_ms = if (spawned_v == nil) { 0 } else { timestamp() - spawned_v }
    age_str = to_string(age_ms / 1000) ++ "s"
    # Each cell is padded as plain text to a fixed column width; the
    # color codes wrap the padded cell so they never skew width math.
    "  " ++ agent_color(name) ++ pad_right(name, 18) ++ reset() ++
        pad_right(role, 16) ++
        status_color(status) ++ pad_right(status, 9) ++ reset() ++
        pad_right(tokens, 11) ++
        grey_text() ++ age_str ++ reset()
}

# Pad — or truncate — a plain string to exactly `width` visible
# columns. The old version discarded `s` and emitted only spaces.
fun pad_right(s, width) {
    len = string_length(s)
    if (len >= width) {
        if (width <= 1) { string_sub(s, 0, 1) }
        else { string_sub(s, 0, width - 1) ++ " " }
    } else {
        s ++ s_pad(width - len, "")
    }
}

fun s_pad(n, acc) {
    if (n <= 0) { acc }
    else { s_pad(n - 1, acc ++ " ") }
}

fun status_color(status) {
    if (status == "working") { brand_color() }
    else { if (status == "idle") { green() }
    else { if (status == "spawning") { teal_info() }
    else { if (status == "dying") { grey_text() }
    else { grey_text() }}}}
}
