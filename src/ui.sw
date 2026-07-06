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
    tool_header, tool_result, tool_header_str, tool_result_str,
    edit_diff_render, diff_ops,
    rationale_box, answer_box,
    input_prompt, input_box_top, input_box_bottom, input_box_bottom_full,
    input_box_bottom_ctx, tool_result_full,
    set_title, set_title_cwd, set_title_turn,
    input_divider, footer_hint,
    status_line, stream_ticker_start, stream_ticker_stop,
    tool_progress, tool_progress_clear,
    enter_alt_screen, leave_alt_screen,
    term_width,
    todo_list_render, todo_summary,
    green, grey_text, grey_border, ui_text, warn_color, err_color, accent_color,
    code_color, warn_text, err_text, ok_text, dim_text,
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

# ------------------------------------------------------------
# COLORTERM detection + theme (Wave-4 item 8)
# ------------------------------------------------------------
# The palette is authored in 24-bit RGB. On a truecolor terminal
# (COLORTERM=truecolor|24bit) it emits `38;2;r;g;b`; otherwise it
# degrades every slot to the nearest xterm-256 index (`38;5;N`).
fun term_truecolor() {
    ct = getenv("COLORTERM")
    if (ct == nil) { 'false' }
    else {
        s = to_string(ct)
        if (string_contains(s, "truecolor") == 'true') { 'true' }
        else { if (string_contains(s, "24bit") == 'true') { 'true' } else { 'false' }}
    }
}

# "dark" (default) | "light". Light uses DARKER slot tones — the same
# semantic slots, tuned for contrast on a light background. main.sw
# copies the config `theme` into SWARM_CODE_THEME so this pure palette
# can read it globally without threading opts through every render fn.
fun ui_theme() {
    v = getenv("SWARM_CODE_THEME")
    if (v == nil) { "dark" }
    else { if (to_string(v) == "light") { "light" } else { "dark" }}
}

# rgb → an SGR foreground escape (truecolor or 256-nearest), NO_COLOR-gated.
fun rgb(r, g, b) {
    if (term_truecolor() == 'true') {
        paint("\e[38;2;" ++ to_string(r) ++ ";" ++ to_string(g) ++ ";" ++ to_string(b) ++ "m")
    } else {
        paint("\e[38;5;" ++ to_string(rgb_to_256(r, g, b)) ++ "m")
    }
}

# Nearest xterm-256 index: grayscale ramp (232-255) when r≈g≈b, else the
# 6×6×6 color cube (16-231).
fun rgb_to_256(r, g, b) {
    if (near_gray(r, g, b) == 'true') { gray_index(r, g, b) }
    else { 16 + 36 * cube6(r) + 6 * cube6(g) + cube6(b) }
}

fun near_gray(r, g, b) {
    if (absdiff(r, g) <= 10 && absdiff(g, b) <= 10 && absdiff(r, b) <= 10) { 'true' }
    else { 'false' }
}

fun absdiff(a, b) { if (a >= b) { a - b } else { b - a } }

# 0..255 → 0..5 cube step (xterm cube values are 0,95,135,175,215,255;
# thresholds are the midpoints).
fun cube6(v) {
    if (v < 48) { 0 }
    else { if (v < 115) { 1 }
    else { if (v < 155) { 2 }
    else { if (v < 195) { 3 }
    else { if (v < 235) { 4 }
    else { 5 }}}}}
}

# Grayscale ramp: 24 steps (indices 232..255), values 8..238.
fun gray_index(r, g, b) {
    avg = (r + g + b) / 3
    if (avg < 8) { 16 }
    else { if (avg > 238) { 231 }
    else { 232 + ((avg - 8) / 10) }}
}

fun brand_color() { if (ui_theme() == "light") { rgb(135, 0, 0) } else { rgb(175, 0, 0) } }   # deep red (brand/primary)
fun brand_dark()  { if (ui_theme() == "light") { rgb(110, 0, 0) } else { rgb(135, 0, 0) } }   # darker red
fun brand_dim()   { if (ui_theme() == "light") { rgb(80, 0, 0)  } else { rgb(95, 0, 0)  } }   # very dark red

# Neutrals (step scale).
fun grey_border() { if (ui_theme() == "light") { rgb(170, 170, 170) } else { rgb(72, 72, 72)   } } # borders
fun grey_text()   { if (ui_theme() == "light") { rgb(90, 90, 90)    } else { rgb(128, 128, 128) } } # muted / secondary
fun ui_text()     { if (ui_theme() == "light") { rgb(30, 30, 30)    } else { rgb(238, 238, 238) } } # primary text

# Semantic colors.
fun teal_info()   { if (ui_theme() == "light") { rgb(30, 120, 132) } else { rgb(86, 182, 194)  } } # info / cyan
fun warn_color()  { if (ui_theme() == "light") { rgb(176, 110, 20) } else { rgb(245, 167, 66)  } } # warning / orange
fun err_color()   { if (ui_theme() == "light") { rgb(176, 40, 50)  } else { rgb(224, 108, 117) } } # error / red
fun accent_color(){ if (ui_theme() == "light") { rgb(104, 72, 168) } else { rgb(157, 124, 216) } } # accent / purple
# Inline code — a calm teal/cyan (Wave-3B item 1), harmonious with the
# brand palette but DISTINCT from the deep red, which is now reserved for
# headings + the ⏺ tool bullet. Truecolor here; degrades to xterm-256
# index 80 (teal) automatically via rgb_to_256 on non-truecolor terms.
fun code_color()  { if (ui_theme() == "light") { rgb(18, 112, 128) } else { rgb(102, 204, 214) } } # inline code / cyan
fun reset()       { "\e[0m" }

# ------------------------------------------------------------
# Semantic text helpers (Wave-3B item 2). Wrap a string in a
# NO_COLOR-gated color + reset(), so diagnostic prints in agent/llm/
# main/tools never emit a raw, ungated escape. The color codes come
# from the paint()-gated palette, so under NO_COLOR they collapse to
# "" and only the (allowed) reset() survives.
fun warn_text(s) { warn_color() ++ to_string(s) ++ reset() }
fun err_text(s)  { err_color() ++ to_string(s) ++ reset() }
fun ok_text(s)   { green() ++ to_string(s) ++ reset() }
fun dim_text(s)  { grey_text() ++ to_string(s) ++ reset() }

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
    print("")
    print(tool_header_str(name, args_preview))
}

# String form — wake turns route it through print_above so tool output
# never scribbles over the pinned input line (agent.execute_all).
fun tool_header_str(name, args_preview) {
    display_name = capitalize_first(to_string(name))
    "  " ++ brand_color() ++ "⏺" ++ reset() ++ " \e[1m" ++ display_name ++ "\e[0m(" ++ args_preview ++ ")"
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
    print(tool_result_str(text))
}

# String form (multi-line) — wake turns split it and print_above each
# line so bg/pulse tool output lands above the pinned prompt.
fun tool_result_str(text) {
    lines = string_split(text, "\n")
    preview_lines = take_n_lines(lines, 8, [])
    total = length(lines)
    rendered = render_result_lines(preview_lines, 0)
    if (total > 8) {
        rendered ++ "\n" ++ "     " ++ grey_text() ++ "… +" ++ to_string(total - 8) ++
            " more lines (/expand)" ++ reset()
    } else { rendered }
}

# /expand — reprint a stashed tool result UNCAPPED, through the same
# ⎿-gutter renderer as tool_result (just no 8-line ceiling).
fun tool_result_full(text) {
    lines = string_split(text, "\n")
    print(render_result_lines(lines, 0))
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
# Edit diff preview — a REAL line-level diff (Wave-3B item 3).
#
# The old renderer printed the WHOLE old_string red then the WHOLE
# new_string green — so a one-line change in a six-line old_string
# looked like six deletions and six additions, and the changed line
# could fall past the 4-line cap. This computes an LCS line diff and
# interleaves the sides: dim context, red `-`, green `+`, with dim
# `@@ ⋯` hunk headers wherever unchanged runs are collapsed.
#
# Cap: 200 lines/side. A larger edit (or a full-file rewrite) falls
# back to the original two-block preview — the DP is O(n·m) and a
# quadratic blow-up on a huge paste isn't worth it for a preview.
# ------------------------------------------------------------
fun edit_diff_render(old_s, new_s) {
    o = if (old_s == nil) { "" } else { to_string(old_s) }
    n = if (new_s == nil) { "" } else { to_string(new_s) }
    old_lines = if (string_length(o) == 0) { [] } else { string_split(o, "\n") }
    new_lines = if (string_length(n) == 0) { [] } else { string_split(n, "\n") }
    na = length(old_lines)
    nb = length(new_lines)
    if (na > 200 || nb > 200) {
        # Fallback: the original whole-block preview, capped.
        if (na > 0) { diff_side(old_lines, "-", err_color(), 4) }
        if (nb > 0) { diff_side(new_lines, "+", green(), 4) }
    } else {
        ops = diff_ops(old_lines, new_lines)
        diff_print_hunks(ops)
    }
}

# LCS line diff → an ordered list of {kind, line} where kind is
# 'ctx' (unchanged), 'del' (old-only) or 'add' (new-only). Dels sort
# before adds at the same position, so a replacement reads "- / +".
fun diff_ops(a, b) {
    na = length(a)
    nb = length(b)
    arr_a = list_to_ets(a)
    arr_b = list_to_ets(b)
    dp = ets_new()
    dp_fill(dp, arr_a, arr_b, na, nb, na - 1)
    diff_backtrack(dp, arr_a, arr_b, na, nb, 0, 0, [])
}

# Index a list into an ETS table (integer keys) for O(1) access.
fun list_to_ets(xs) {
    t = ets_new()
    list_to_ets_loop(t, xs, 0)
    t
}

fun list_to_ets_loop(t, xs, i) {
    if (length(xs) == 0) { t }
    else {
        ets_put(t, i, hd(xs))
        list_to_ets_loop(t, tl(xs), i + 1)
    }
}

# Fill the suffix-LCS length table backward: dp[i][j] = LCS of a[i..],
# b[j..]. Missing cells read as 0 (the base row/column). The outer loop
# self-tail-recurses over i; the inner over j — each is TCO'd on its own,
# so the stack never grows past one frame per loop.
fun dp_fill(dp, arr_a, arr_b, na, nb, i) {
    if (i < 0) { 'ok' }
    else {
        dp_fill_row(dp, arr_a, arr_b, na, nb, i, nb - 1)
        dp_fill(dp, arr_a, arr_b, na, nb, i - 1)
    }
}

fun dp_fill_row(dp, arr_a, arr_b, na, nb, i, j) {
    if (j < 0) { 'ok' }
    else {
        ai = ets_get(arr_a, i)
        bj = ets_get(arr_b, j)
        v = if (ai == bj) {
            1 + dp_get(dp, nb, i + 1, j + 1)
        } else {
            d1 = dp_get(dp, nb, i + 1, j)
            d2 = dp_get(dp, nb, i, j + 1)
            if (d1 >= d2) { d1 } else { d2 }
        }
        ets_put(dp, i * (nb + 1) + j, v)
        dp_fill_row(dp, arr_a, arr_b, na, nb, i, j - 1)
    }
}

fun dp_get(dp, nb, i, j) {
    v = ets_get(dp, i * (nb + 1) + j)
    if (v == nil) { 0 } else { v }
}

# Walk the table forward from (0,0), emitting the standard edit script.
fun diff_backtrack(dp, arr_a, arr_b, na, nb, i, j, acc) {
    if (i >= na && j >= nb) { acc }
    else { if (i >= na) {
        diff_backtrack(dp, arr_a, arr_b, na, nb, i, j + 1,
                       list_append(acc, {'add', ets_get(arr_b, j)}))
    } else { if (j >= nb) {
        diff_backtrack(dp, arr_a, arr_b, na, nb, i + 1, j,
                       list_append(acc, {'del', ets_get(arr_a, i)}))
    } else {
        ai = ets_get(arr_a, i)
        bj = ets_get(arr_b, j)
        if (ai == bj) {
            diff_backtrack(dp, arr_a, arr_b, na, nb, i + 1, j + 1,
                           list_append(acc, {'ctx', ai}))
        } else {
            down = dp_get(dp, nb, i + 1, j)
            right = dp_get(dp, nb, i, j + 1)
            if (down >= right) {
                diff_backtrack(dp, arr_a, arr_b, na, nb, i + 1, j,
                               list_append(acc, {'del', ai}))
            } else {
                diff_backtrack(dp, arr_a, arr_b, na, nb, i, j + 1,
                               list_append(acc, {'add', bj}))
            }
        }
    }}}
}

# Render the edit script: keep a change ± its 2-line context window,
# collapse longer unchanged runs, and print a dim `@@ ⋯` header wherever
# a run is actually skipped (never a spurious leading header). No changes
# at all → nothing printed (identical old/new).
fun diff_ctx_window() { 2 }

fun diff_print_hunks(ops) {
    n = length(ops)
    if (n == 0) { 'ok' }
    else {
        arr = list_to_ets(ops)
        changes = diff_collect_changes(arr, n, 0, [])
        if (length(changes) == 0) { 'ok' }
        else { diff_emit(arr, n, changes, 0, 0 - 1) }
    }
}

fun diff_collect_changes(arr, n, i, acc) {
    if (i >= n) { acc }
    else {
        op = ets_get(arr, i)
        na = if (elem(op, 0) == 'ctx') { acc } else { list_append(acc, i) }
        diff_collect_changes(arr, n, i + 1, na)
    }
}

fun diff_emit(arr, n, changes, i, last_kept) {
    if (i >= n) { 'ok' }
    else {
        op = ets_get(arr, i)
        kind = elem(op, 0)
        keep = if (kind != 'ctx') { 'true' }
               else { diff_near_change(i, changes, diff_ctx_window()) }
        new_last = if (keep == 'true') {
            gap = if (last_kept < 0) { if (i > 0) { 'true' } else { 'false' } }
                  else { if (i - last_kept > 1) { 'true' } else { 'false' } }
            if (gap == 'true') { print(diff_hunk_header()) }
            print(diff_line_str(kind, elem(op, 1)))
            i
        } else { last_kept }
        diff_emit(arr, n, changes, i + 1, new_last)
    }
}

fun diff_near_change(i, changes, w) {
    if (length(changes) == 0) { 'false' }
    else {
        c = hd(changes)
        d = if (i >= c) { i - c } else { c - i }
        if (d <= w) { 'true' } else { diff_near_change(i, tl(changes), w) }
    }
}

fun diff_line_str(kind, line) {
    if (kind == 'del') { "     " ++ err_color() ++ "- " ++ to_string(line) ++ reset() }
    else { if (kind == 'add') { "     " ++ green() ++ "+ " ++ to_string(line) ++ reset() }
    else { "     " ++ grey_text() ++ dim() ++ "  " ++ to_string(line) ++ reset() }}
}

fun diff_hunk_header() {
    "     " ++ grey_text() ++ dim() ++ "@@ ⋯" ++ reset()
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
    input_box_bottom_ctx(model_name, token_count, budget, "", "", "")
}

# Enriched footer (Wave-4 item 4/7): /help · model · cwd (branch) · [mode] · tokens.
# cwd_base / branch are plain strings computed by agent.sw; mode_chip is a
# pre-colored, self-contained fragment (already "· "-terminated) or "".
fun input_box_bottom_ctx(model_name, token_count, budget, cwd_base, branch, mode_chip) {
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
    loc = footer_location(cwd_base, branch)
    # One calm muted line. The grey span stays open through loc; reset()
    # before the (self-contained) mode chip and the tinted token meter.
    print("  " ++ grey_text() ++ "/help  ·  " ++ model_name ++ loc ++ "  ·  " ++
          reset() ++ mode_chip ++ colored_tokens)
}

# "  ·  swarm-code (main)" / "  ·  swarm-code" / "" — rendered inside the
# footer's grey span, so no color codes of its own (keeps it calm + robust).
fun footer_location(cwd_base, branch) {
    if (string_length(cwd_base) == 0) { "" }
    else {
        b = if (string_length(branch) == 0) { "" } else { " (" ++ branch ++ ")" }
        "  ·  " ++ cwd_base ++ b
    }
}

# ------------------------------------------------------------
# Terminal title (OSC 2) — Wave-4 item 8. Gated by SW_NO_TITLE (any
# non-empty value disables it). BEL-terminated (0x07) like xterm's OSC 2;
# swarmrt's string lexer has no \a escape, so the BEL is built from a byte.
# ------------------------------------------------------------
fun title_enabled() {
    v = getenv("SW_NO_TITLE")
    if (v == nil) { 'true' }
    else { if (string_length(to_string(v)) > 0) { 'false' } else { 'true' }}
}

fun set_title(s) {
    if (title_enabled() == 'true') {
        print_inline("\e]2;" ++ title_sanitize(s) ++ bytes_to_string(byte(7)))
    }
    'ok'
}

# Strip C0 control bytes + DEL from the title text: a pasted ESC/BEL in
# the user's prompt would otherwise corrupt or terminate the OSC 2
# sequence and leak raw bytes to the terminal. UTF-8 high bytes pass
# through untouched (byte-wise walk keeps multibyte chars intact).
fun title_sanitize(s) {
    title_san_loop(to_string(s), 0, "")
}

fun title_san_loop(s, i, acc) {
    if (i >= string_length(s)) { acc }
    else {
        ch = string_sub(s, i, 1)
        o = ord(ch)
        keep = if (o < 32 || o == 127) { 'false' } else { 'true' }
        title_san_loop(s, i + 1, if (keep == 'true') { acc ++ ch } else { acc })
    }
}

# "swarm-code — <cwd base>" at startup.
fun set_title_cwd(cwd) {
    set_title("swarm-code — " ++ title_base(cwd))
}

# "swarm-code — <cwd base>: <prompt…>" per turn (short suffix).
fun set_title_turn(cwd, prompt) {
    p = title_clip(string_trim(to_string(prompt)), 40)
    if (string_length(p) == 0) { set_title_cwd(cwd) }
    else { set_title("swarm-code — " ++ title_base(cwd) ++ ": " ++ p) }
}

fun title_base(p) {
    title_last(string_split(to_string(p), "/"), "")
}

fun title_last(lst, acc) {
    if (length(lst) == 0) { acc }
    else {
        h = hd(lst)
        na = if (string_length(h) == 0) { acc } else { h }
        title_last(tl(lst), na)
    }
}

fun title_clip(s, n) {
    if (string_length(s) <= n) { s }
    else { title_trim_partial(string_sub(s, 0, n)) ++ "…" }
}

# string_sub is BYTE-oriented, so a clip can split a UTF-8 codepoint —
# drop any incomplete trailing sequence (mirror of the runtime's
# _sw_utf8_trim_incomplete) so the title never carries invalid bytes.
fun title_trim_partial(s) {
    len = string_length(s)
    cont = count_trailing_cont(s, len, 0)
    if (cont >= len) { "" }
    else {
        lead_i = len - cont - 1
        o = ord(string_sub(s, lead_i, 1))
        need = if (o < 128) { 1 }
               else { if (o >= 240) { 4 }
               else { if (o >= 224) { 3 }
               else { if (o >= 192) { 2 }
               else { 1 }}}}
        have = 1 + cont
        if (have >= need) { s } else { string_sub(s, 0, lead_i) }
    }
}

fun count_trailing_cont(s, len, acc) {
    i = len - acc - 1
    if (i < 0) { acc }
    else {
        o = ord(string_sub(s, i, 1))
        if (o >= 128 && o < 192) { count_trailing_cont(s, len, acc + 1) } else { acc }
    }
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
# Live stream ticker (Wave-1B) — replaces the dead spinner_start/stop
# ------------------------------------------------------------
# One dim \r-rewritten status line owned by a spawned ~1s tick process
# while the worker-routed LLM stream runs:
#
#   ◐ 12s · 176 tok · esc to interrupt
#   ◓ 3s · thinking · 2.1k · esc to interrupt     (pure-reasoning)
#
# Counters live in the stream_state_table ETS, written by llm.sw's
# receive loop: 'stream_tok' = content chunks seen (≈ tokens),
# 'stream_think' = reasoning chars seen. The RECEIVE LOOP owns the
# terminal — it clears the line before printing each rendered block;
# the ticker only ever does single-line \r rewrites, so the worst race
# is one stale frame that the next clear wipes (accepted; no locks).
# stream_ticker_stop kills the tick process AND clears the line —
# llm.sw calls it on EVERY exit path (done / interrupt / timeout /
# error), and calling it twice is a harmless no-op.
fun stream_ticker_start(tbl) {
    if (tbl == nil) { 'ok' }
    else {
        ets_put(tbl, 'stream_tok', 0)
        ets_put(tbl, 'stream_think', 0)
        pid = spawn(stream_ticker_loop(tbl, timestamp(), 0))
        ets_put(tbl, 'ticker_pid', pid)
        'ok'
    }
}

fun stream_ticker_stop(tbl) {
    if (tbl == nil) { 'ok' }
    else {
        pid = ets_get(tbl, 'ticker_pid')
        if (pid != nil) {
            # SYNCHRONOUS handshake: exit_proc only sets an async kill_flag,
            # so a ticker already past its receive (mid-print_inline on
            # another scheduler thread) could still paint a frame AFTER the
            # \r\e[K below and the next plain print would append to the
            # stale "◐ Ns · …" text. Send a tokened stop and WAIT for the
            # ack — the ack is sent from the ticker's receive arm, so any
            # in-flight frame print has already completed when it arrives.
            # The 250ms `after` is only a dead-ticker backstop.
            tok = to_string(timestamp()) ++ "-" ++ to_string(random_int(1, 1000000))
            send(pid, {'ticker_stop', self(), tok})
            wait_ticker_ack(tok)
            exit_proc(pid, 'kill')
            ets_put(tbl, 'ticker_pid', nil)
        }
        print_inline("\r\e[K")
        'ok'
    }
}

fun wait_ticker_ack(tok) {
    receive {
        {'ticker_ack', t} -> if (t == tok) { 'ok' } else { wait_ticker_ack(tok) }
        after 250 { 'ok' }
    }
}

# ~1s tick. SELF-tail-recursive (incl. the receive-after body) — the
# only loop shape swarmrt TCO's.
fun stream_ticker_loop(tbl, start_ms, tick) {
    m = receive {
        {'ticker_stop', from, tok} -> {'stop', from, tok}
        after 1000 { 'tick' }
    }
    if (m == 'tick') {
        print_inline(stream_ticker_frame(tbl, start_ms, tick))
        stream_ticker_loop(tbl, start_ms, tick + 1)
    } else {
        # Ack AFTER any frame print above has returned — this ordering is
        # what lets stream_ticker_stop guarantee no frame after its clear.
        send(elem(m, 1), {'ticker_ack', elem(m, 2)})
        'ok'
    }
}

fun stream_ticker_frame(tbl, start_ms, tick) {
    elapsed = (timestamp() - start_ms) / 1000
    tok = ticker_count(tbl, 'stream_tok')
    think = ticker_count(tbl, 'stream_think')
    mid = if (tok == 0 && think > 0) { "thinking · " ++ ticker_fmt_k(think) }
          else { ticker_fmt_k(tok) ++ " tok" }
    "\r\e[K  " ++ dim() ++ ticker_glyph(tick) ++ " " ++ to_string(elapsed) ++
        "s · " ++ mid ++ " · esc to interrupt" ++ reset()
}

fun ticker_count(tbl, key) {
    v = ets_get(tbl, key)
    if (v == nil) { 0 } else { v }
}

# ◐◓◑◒ — same cycle as FlowsRender.spinner_char. Modulo the long way
# (see agent_color).
fun ticker_glyph(tick) {
    idx = tick - (tick / 4) * 4
    if (idx == 0) { "◐" }
    else { if (idx == 1) { "◓" }
    else { if (idx == 2) { "◑" }
    else { "◒" }}}
}

# 1437 → "1.4k", 999 → "999"
fun ticker_fmt_k(n) {
    if (n < 1000) { to_string(n) }
    else {
        whole = n / 1000
        tenth = (n - whole * 1000) / 100
        to_string(whole) ++ "." ++ to_string(tenth) ++ "k"
    }
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

fun green()      { if (ui_theme() == "light") { rgb(30, 140, 70) } else { rgb(127, 216, 143) } }   # success
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

# Uppercase A–Z → 65..90, else 0. Split out so char_ord can try it first:
# capitals were previously folded to 0, so every agent name starting with a
# capital (Builder, Reviewer, …) hashed to the same bucket and drew the same
# color. Now they spread across the palette like lowercase names do.
fun char_ord_upper(ch) {
    if (ch == "A") { 65 } else { if (ch == "B") { 66 } else { if (ch == "C") { 67 }
    else { if (ch == "D") { 68 } else { if (ch == "E") { 69 } else { if (ch == "F") { 70 }
    else { if (ch == "G") { 71 } else { if (ch == "H") { 72 } else { if (ch == "I") { 73 }
    else { if (ch == "J") { 74 } else { if (ch == "K") { 75 } else { if (ch == "L") { 76 }
    else { if (ch == "M") { 77 } else { if (ch == "N") { 78 } else { if (ch == "O") { 79 }
    else { if (ch == "P") { 80 } else { if (ch == "Q") { 81 } else { if (ch == "R") { 82 }
    else { if (ch == "S") { 83 } else { if (ch == "T") { 84 } else { if (ch == "U") { 85 }
    else { if (ch == "V") { 86 } else { if (ch == "W") { 87 } else { if (ch == "X") { 88 }
    else { if (ch == "Y") { 89 } else { if (ch == "Z") { 90 }
    else { 0 }}}}}}}}}}}}}}}}}}}}}}}}}}
}

fun char_ord(ch) {
    # Approximate ord via comparison ladder for ASCII letters/digits;
    # other chars fold to 0. Good enough for color hashing. Uppercase is
    # tried first (see char_ord_upper) so capitalized names don't collide.
    up = char_ord_upper(ch)
    if (up > 0) { up }
    else {
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
    if (len > width) {
        # Truncated — mark it with an ellipsis in the last column so a
        # clipped name/role reads as clipped, not as a real short value.
        if (width <= 1) { "…" }
        else { string_sub(s, 0, width - 1) ++ "…" }
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
