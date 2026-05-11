module Markdown

# ============================================================
# Markdown — minimal CC-inspired renderer for assistant prose
# ============================================================
#
# The model emits markdown. The terminal needs ANSI. Without a render
# pass, the user sees literal `### Header`, `**bold**`, `` `code` ``
# and the terminal hard-wraps mid-word into things like
# `robotic-hand-vie\nwer`. Both ugly.
#
# This module does a small, opinionated render — inspired by Claude
# Code's utils/markdown.ts (which uses the marked.js lexer) but
# written for sw without external deps.
#
# Block-level handling:
#   `### X` `## X` `# X`    → bold (with depth-graded styling)
#   `- X`     `* X`         → bullet • prefix
#   `> X`                   → dim │ blockquote bar
#   ```                      → code fence (until closing ```)
#   `---` (alone on a line)  → horizontal rule
#   blank line              → paragraph break
#   anything else           → paragraph text
#
# Inline handling (within paragraph / heading / bullet / blockquote):
#   `**X**`                  → ANSI bold
#   `` `X` ``                → ANSI inline-code color
#
# Italic (`*X*` / `_X_`) is NOT handled in v1 — too many false
# positives (model uses bare `*` for emphasis, glob patterns, math).
# We can add it later behind smarter heuristics.
#
# Soft word-wrap: every output line is wrapped at `width` columns at
# WORD boundaries. Never break a word mid-string. Display width
# accounts for the 2-col indent + ANSI codes don't count toward width.

import UI

export [render]

# ------------------------------------------------------------
# Public entry: render(content, width) -> string
# ------------------------------------------------------------
# `width` is the available column count INCLUDING the leading 2-space
# indent we add to every line. So if the terminal is 100 cols and the
# tool calls indent us 2 cols already, pass width=98.
fun render(content, width) {
    if (content == nil) { "" }
    else {
        text = to_string(content)
        if (string_length(string_trim(text)) == 0) { "" }
        else {
            lines = string_split(text, "\n")
            inner_w = width - 2
            blocks = walk_blocks(lines, [], 'false', [])
            join_blocks(blocks, inner_w, "")
        }
    }
}

# ------------------------------------------------------------
# Block walker: turn a list of lines into a list of {kind, payload}
# tuples.
# kind: 'header'|'bullet'|'quote'|'code'|'hr'|'para'|'blank'
# payload: header → {depth, text}
#          bullet → text (the part after "- ")
#          quote  → text (the part after "> ")
#          code   → list of lines (raw, no fence)
#          hr     → ""
#          para   → text (joined lines of the paragraph)
#          blank  → ""
# ------------------------------------------------------------
fun walk_blocks(lines, code_acc, in_code, blocks) {
    if (length(lines) == 0) {
        if (in_code == 'true') {
            list_append(blocks, {'code', code_acc})
        } else {
            blocks
        }
    } else {
        line = hd(lines)
        rest = tl(lines)
        if (in_code == 'true') {
            if (is_fence(line) == 'true') {
                walk_blocks(rest, [], 'false', list_append(blocks, {'code', code_acc}))
            } else {
                walk_blocks(rest, list_append(code_acc, line), 'true', blocks)
            }
        } else {
            if (is_fence(line) == 'true') {
                walk_blocks(rest, [], 'true', blocks)
            } else { if (is_blank(line) == 'true') {
                walk_blocks(rest, [], 'false', list_append(blocks, {'blank', ""}))
            } else { if (is_hr(line) == 'true') {
                walk_blocks(rest, [], 'false', list_append(blocks, {'hr', ""}))
            } else { if (header_depth(line) > 0) {
                d = header_depth(line)
                t = strip_prefix(line, header_prefix(d))
                walk_blocks(rest, [], 'false', list_append(blocks, {'header', {d, t}}))
            } else { if (is_bullet(line) == 'true') {
                walk_blocks(rest, [], 'false', list_append(blocks, {'bullet', bullet_text(line)}))
            } else { if (is_quote(line) == 'true') {
                walk_blocks(rest, [], 'false', list_append(blocks, {'quote', quote_text(line)}))
            } else {
                # Paragraph — extend or start. We keep paragraphs as
                # single blocks so the soft-wrap can re-flow them.
                last = if (length(blocks) == 0) { nil } else { list_last(blocks) }
                if (last != nil && elem(last, 0) == 'para') {
                    cur = elem(last, 1)
                    merged = cur ++ " " ++ string_trim(line)
                    new_blocks = list_set_last(blocks, {'para', merged})
                    walk_blocks(rest, [], 'false', new_blocks)
                } else {
                    walk_blocks(rest, [], 'false', list_append(blocks, {'para', string_trim(line)}))
                }
            }}}}}}
        }
    }
}

# Detect line types ----------------------------------------

fun is_blank(line) {
    if (string_length(string_trim(line)) == 0) { 'true' } else { 'false' }
}

fun is_hr(line) {
    t = string_trim(line)
    if (t == "---" || t == "***" || t == "___") { 'true' } else { 'false' }
}

fun is_fence(line) {
    t = string_trim(line)
    # Match plain ``` or ```language
    if (string_length(t) < 3) { 'false' }
    else { if (string_sub(t, 0, 3) == "```") { 'true' } else { 'false' }}
}

fun is_bullet(line) {
    t = string_trim(line)
    if (string_length(t) < 2) { 'false' }
    else {
        h2 = string_sub(t, 0, 2)
        if (h2 == "- " || h2 == "* ") { 'true' } else { 'false' }
    }
}

fun bullet_text(line) {
    t = string_trim(line)
    string_sub(t, 2, string_length(t) - 2)
}

fun is_quote(line) {
    t = string_trim(line)
    if (string_length(t) < 2) { 'false' }
    else {
        if (string_sub(t, 0, 2) == "> ") { 'true' }
        else { if (string_sub(t, 0, 1) == ">") { 'true' } else { 'false' }}
    }
}

fun quote_text(line) {
    t = string_trim(line)
    if (string_sub(t, 0, 2) == "> ") { string_sub(t, 2, string_length(t) - 2) }
    else { string_sub(t, 1, string_length(t) - 1) }
}

# Returns 0 if not a header, else depth (1, 2, 3, 4+).
fun header_depth(line) {
    t = string_trim(line)
    h_count(t, 0)
}

fun h_count(s, n) {
    if (string_length(s) == 0) { 0 }
    else { if (n >= 6) { count_if_space(s, n) }
    else { if (string_sub(s, 0, 1) == "#") { h_count(string_sub(s, 1, string_length(s) - 1), n + 1) }
    else { count_if_space(s, n) }}}
}

fun count_if_space(s, n) {
    if (n == 0) { 0 }
    else { if (string_length(s) == 0) { 0 }
    else { if (string_sub(s, 0, 1) == " ") { n } else { 0 }}}
}

fun header_prefix(depth) {
    if (depth == 1) { "# " }
    else { if (depth == 2) { "## " }
    else { if (depth == 3) { "### " }
    else { if (depth == 4) { "#### " }
    else { if (depth == 5) { "##### " }
    else { "###### " }}}}}
}

fun strip_prefix(line, pfx) {
    t = string_trim(line)
    plen = string_length(pfx)
    if (string_length(t) < plen) { t }
    else {
        if (string_sub(t, 0, plen) == pfx) {
            string_sub(t, plen, string_length(t) - plen)
        } else { t }
    }
}

# ------------------------------------------------------------
# Block joiner: render each block + glue with appropriate spacing
# ------------------------------------------------------------
fun join_blocks(blocks, width, acc) {
    join_loop(blocks, width, acc, nil)
}

# kind-aware spacing: same-kind list-y blocks (bullet/quote) stay
# adjacent; everything else gets a blank line between. Blanks stay
# as empty contributions so explicit \n\n in source still produces
# breathing room.
fun join_loop(blocks, width, acc, prev_kind) {
    if (length(blocks) == 0) { acc }
    else {
        b = hd(blocks)
        kind = elem(b, 0)
        payload = elem(b, 1)
        rendered = render_block(kind, payload, width)
        sep = if (string_length(acc) == 0) { "" }
              else { pair_sep(prev_kind, kind) }
        new_acc = acc ++ sep ++ rendered
        join_loop(tl(blocks), width, new_acc, kind)
    }
}

fun pair_sep(prev_kind, cur_kind) {
    # Adjacent lines (no blank between):
    #   bullet→bullet, quote→quote        — list/quote continuation
    #   anything→blank, blank→anything    — blank already empties
    if (cur_kind == 'blank' || prev_kind == 'blank') { "\n" }
    else { if (prev_kind == 'bullet' && cur_kind == 'bullet') { "\n" }
    else { if (prev_kind == 'quote' && cur_kind == 'quote') { "\n" }
    else { "\n\n" }}}
}

# ------------------------------------------------------------
# Block renderers
# ------------------------------------------------------------

fun render_block(kind, payload, width) {
    if (kind == 'header')      { render_header(payload, width) }
    else { if (kind == 'bullet')   { render_bullet(payload, width) }
    else { if (kind == 'quote')    { render_quote(payload, width) }
    else { if (kind == 'code')     { render_code(payload, width) }
    else { if (kind == 'hr')       { render_hr(width) }
    else { if (kind == 'blank')    { "" }
    else { render_para(payload, width) }}}}}}
}

# Headers: bold. h1 also underlined. Prepend nothing — no `### ` text.
# Followed by a blank line by the joiner.
fun render_header(payload, width) {
    depth = elem(payload, 0)
    text = elem(payload, 1)
    inline_rendered = render_inline(text)
    style = if (depth == 1) { UI.brand_color() ++ "\e[1m\e[4m" }
            else { if (depth == 2) { UI.brand_color() ++ "\e[1m" }
            else { "\e[1m" }}
    indent_line(style ++ inline_rendered ++ UI.reset(), width)
}

fun render_bullet(payload, width) {
    bullet = "  • "    # 4-char prefix (incl. 2-space indent)
    cont   = "    "    # 4-char hanging indent for wrapped lines
    rendered = render_inline(payload)
    wrap_with_prefixes(rendered, bullet, cont, width)
}

fun render_quote(payload, width) {
    bar = "  " ++ UI.grey_border() ++ "│ " ++ UI.reset()
    rendered = render_inline(payload)
    wrap_with_prefixes(rendered, bar, bar, width - 2)
}

# Code block: indent each line, color dimly. No syntax highlight in v1.
fun render_code(lines, width) {
    bg = UI.grey_text()
    code_indent_loop(lines, bg, "")
}

fun code_indent_loop(lines, color, acc) {
    if (length(lines) == 0) { acc }
    else {
        line = hd(lines)
        formatted = "  " ++ color ++ line ++ UI.reset()
        next_acc = if (string_length(acc) == 0) { formatted }
                   else { acc ++ "\n" ++ formatted }
        code_indent_loop(tl(lines), color, next_acc)
    }
}

fun render_hr(width) {
    bar = make_dashes(width - 2, "")
    "  " ++ UI.grey_border() ++ bar ++ UI.reset()
}

fun make_dashes(n, acc) {
    if (n <= 0) { acc }
    else { make_dashes(n - 1, acc ++ "─") }
}

# Paragraph: render inline tokens, soft-wrap at width.
fun render_para(payload, width) {
    rendered = render_inline(payload)
    wrap_with_prefixes(rendered, "  ", "  ", width)
}

# ------------------------------------------------------------
# Inline renderer — scans for `**X**` and `` `X` ``
# ------------------------------------------------------------
# Simple state machine. Iterates char by char, looks for openers,
# captures runs, emits ANSI-wrapped output.
fun render_inline(text) {
    inline_loop(text, 0, "")
}

fun inline_loop(s, i, acc) {
    if (i >= string_length(s)) { acc }
    else {
        # Try to match `**...**` first (longer marker has priority).
        if (peek2(s, i) == "**") {
            bold_close = find_close(s, i + 2, "**")
            if (bold_close < 0) {
                # No closer — emit literal "**" and continue.
                inline_loop(s, i + 2, acc ++ "**")
            } else {
                bold_inner = string_sub(s, i + 2, bold_close - (i + 2))
                inline_loop(s, bold_close + 2, acc ++ "\e[1m" ++ bold_inner ++ UI.reset())
            }
        } else { if (peek1(s, i) == "`") {
            code_close = find_close(s, i + 1, "`")
            if (code_close < 0) {
                inline_loop(s, i + 1, acc ++ "`")
            } else {
                code_inner = string_sub(s, i + 1, code_close - (i + 1))
                colored = UI.brand_color() ++ code_inner ++ UI.reset()
                inline_loop(s, code_close + 1, acc ++ colored)
            }
        } else {
            ch = string_sub(s, i, 1)
            inline_loop(s, i + 1, acc ++ ch)
        }}
    }
}

fun peek1(s, i) {
    if (i >= string_length(s)) { "" }
    else { string_sub(s, i, 1) }
}

fun peek2(s, i) {
    if (i + 2 > string_length(s)) { "" }
    else { string_sub(s, i, 2) }
}

# Find next occurrence of `needle` at or after `from`, return start
# index or -1. needle is 1 or 2 chars in our use.
fun find_close(s, from, needle) {
    nlen = string_length(needle)
    slen = string_length(s)
    find_close_loop(s, slen, needle, nlen, from)
}

fun find_close_loop(s, slen, needle, nlen, i) {
    if (i + nlen > slen) { 0 - 1 }
    else {
        if (string_sub(s, i, nlen) == needle) { i }
        else { find_close_loop(s, slen, needle, nlen, i + 1) }
    }
}

# ------------------------------------------------------------
# Soft word-wrap
# ------------------------------------------------------------
# Take a string with embedded ANSI codes, split into "display tokens"
# (words and ANSI sequences), assemble lines that don't exceed
# `width` display chars (ANSI codes don't count). Each line gets
# `first_prefix` for the first wrapped line and `cont_prefix` for
# subsequent ones (e.g. bullets indent continuations under the text).
fun wrap_with_prefixes(text, first_prefix, cont_prefix, width) {
    avail = width - display_width(first_prefix)
    if (avail < 8) {
        # Pathological narrow terminal — bail to no wrapping
        first_prefix ++ text
    } else {
        words = split_words(text)
        wrap_loop(words, first_prefix, cont_prefix, width, "", "", 'true')
    }
}

# Walk words, building current_line; flush + new line when adding
# another word would exceed width.
fun wrap_loop(words, first_prefix, cont_prefix, width, lines_acc, current, on_first) {
    if (length(words) == 0) {
        if (string_length(current) == 0) { lines_acc }
        else { append_line(lines_acc, current) }
    } else {
        w = hd(words)
        rest = tl(words)
        prefix = if (on_first == 'true') { first_prefix } else { cont_prefix }
        # display widths
        cur_disp = display_width(current)
        w_disp = display_width(w)
        if (string_length(current) == 0) {
            wrap_loop(rest, first_prefix, cont_prefix, width, lines_acc, prefix ++ w, on_first)
        } else {
            # +1 for space separator
            if (cur_disp + 1 + w_disp <= width) {
                wrap_loop(rest, first_prefix, cont_prefix, width, lines_acc, current ++ " " ++ w, on_first)
            } else {
                # Flush current line and start a new one with cont_prefix.
                wrap_loop(rest, first_prefix, cont_prefix, width,
                          append_line(lines_acc, current),
                          cont_prefix ++ w, 'false')
            }
        }
    }
}

fun append_line(acc, line) {
    if (string_length(acc) == 0) { line } else { acc ++ "\n" ++ line }
}

# Split a string into "display tokens" — words + their interleaved
# ANSI codes. Splits on spaces; ANSI codes stay attached to whichever
# word they preceded/follow.
fun split_words(text) {
    parts = string_split(text, " ")
    filter_empty(parts, [])
}

fun filter_empty(items, acc) {
    if (length(items) == 0) { acc }
    else {
        h = hd(items)
        next = if (string_length(h) == 0) { acc } else { list_append(acc, h) }
        filter_empty(tl(items), next)
    }
}

# Display width of a string — counts non-ANSI chars only. ANSI escape
# sequences start with \x1b[ and end with a letter.
fun display_width(s) {
    dw_loop(s, 0, 0, 'false')
}

fun dw_loop(s, i, count, in_esc) {
    if (i >= string_length(s)) { count }
    else {
        ch = string_sub(s, i, 1)
        if (in_esc == 'true') {
            # ANSI sequences end at any letter (m, K, J, A, etc.)
            if (is_ansi_end_char(ch) == 'true') {
                dw_loop(s, i + 1, count, 'false')
            } else {
                dw_loop(s, i + 1, count, 'true')
            }
        } else {
            if (ch == "\e") {
                dw_loop(s, i + 1, count, 'true')
            } else {
                dw_loop(s, i + 1, count + 1, 'false')
            }
        }
    }
}

fun is_ansi_end_char(ch) {
    # ANSI CSI terminators: A-Z and a-z
    if (ch == "m" || ch == "K" || ch == "J" || ch == "H" || ch == "A"
        || ch == "B" || ch == "C" || ch == "D" || ch == "E" || ch == "F"
        || ch == "G" || ch == "S" || ch == "T" || ch == "f"
        || ch == "h" || ch == "l" || ch == "n" || ch == "s" || ch == "u") {
        'true'
    } else { 'false' }
}

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

fun indent_line(line, width) { "  " ++ line }

fun list_last(lst) {
    if (length(lst) == 0) { nil }
    else { last_loop(lst) }
}

fun last_loop(lst) {
    t = tl(lst)
    if (length(t) == 0) { hd(lst) } else { last_loop(t) }
}

fun list_set_last(lst, val) {
    n = length(lst)
    if (n == 0) { [val] }
    else { set_last_loop(lst, n - 1, val, 0, []) }
}

fun set_last_loop(lst, target_idx, val, i, acc) {
    if (length(lst) == 0) { acc }
    else {
        h = hd(lst)
        next_item = if (i == target_idx) { val } else { h }
        set_last_loop(tl(lst), target_idx, val, i + 1, list_append(acc, next_item))
    }
}
