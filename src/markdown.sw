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

export [render, repaint_streamed_prose, has_markdown, display_width]

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
            } else { if (is_table_row(line) == 'true') {
                # Collect this and any consecutive table rows into a
                # single 'table' block. Without this they fell through
                # to the paragraph branch and got space-joined into
                # one mangled line.
                tbl_last = if (length(blocks) == 0) { nil } else { list_last(blocks) }
                if (tbl_last != nil && elem(tbl_last, 0) == 'table') {
                    tbl_rows = elem(tbl_last, 1)
                    tbl_blocks = list_set_last(blocks, {'table', list_append(tbl_rows, string_trim(line))})
                    walk_blocks(rest, [], 'false', tbl_blocks)
                } else {
                    walk_blocks(rest, [], 'false', list_append(blocks, {'table', [string_trim(line)]}))
                }
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
            }}}}}}}
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

fun is_table_row(line) {
    t = string_trim(line)
    if (string_length(t) == 0) { 'false' }
    else { if (string_sub(t, 0, 1) == "|") { 'true' } else { 'false' }}
}

# Detect the alignment row: cells are all dashes (with optional :).
# e.g. |---|---|, |:---|---:|, |:--:|. Used to skip these in render.
fun is_table_align_row(line) {
    cells = parse_table_row(line)
    if (length(cells) == 0) { 'false' }
    else { all_dashes(cells) }
}

fun all_dashes(cells) {
    if (length(cells) == 0) { 'true' }
    else {
        c = string_trim(hd(cells))
        if (string_length(c) == 0) { all_dashes(tl(cells)) }
        else { if (only_dash_chars(c, 0) == 'true') { all_dashes(tl(cells)) }
        else { 'false' }}
    }
}

fun only_dash_chars(s, i) {
    if (i >= string_length(s)) { 'true' }
    else {
        ch = string_sub(s, i, 1)
        if (ch == "-" || ch == ":" || ch == " ") { only_dash_chars(s, i + 1) }
        else { 'false' }
    }
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
    else { if (kind == 'table')    { render_table(payload, width) }
    else { render_para(payload, width) }}}}}}}
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

# ------------------------------------------------------------
# Table rendering
# ------------------------------------------------------------
# rows: list of raw "| a | b | c |" lines (alignment row included).
# Strategy: parse each row into trimmed cells, drop the alignment-only
# row, compute max width per column, then re-render padded with a │
# separator. Header row gets a dim ─── divider beneath.
fun render_table(rows, width) {
    # Parse rows into [cells]. Skip alignment-only rows.
    parsed = parse_rows(rows, [])
    if (length(parsed) == 0) { "" }
    else {
        raw_widths = compute_col_widths(parsed, [])
        # Clamp the column widths so the whole row fits `width`. Without this
        # a wide table overflows and the terminal hard-wraps it mid-cell (the
        # final render goes through plain print(), not the column-aware
        # streaming emitter), destroying alignment.
        widths = clamp_table_widths(raw_widths, width)
        # First parsed row is the header. Render it, then the divider,
        # then the body rows.
        head = hd(parsed)
        body = tl(parsed)
        head_line = render_row(head, widths)
        div_line = render_divider(widths)
        body_lines = render_body_rows(body, widths, "")
        if (string_length(body_lines) == 0) {
            head_line ++ "\n" ++ div_line
        } else {
            head_line ++ "\n" ++ div_line ++ "\n" ++ body_lines
        }
    }
}

fun parse_rows(rows, acc) {
    if (length(rows) == 0) { acc }
    else {
        r = hd(rows)
        if (is_table_align_row(r) == 'true') { parse_rows(tl(rows), acc) }
        else { parse_rows(tl(rows), list_append(acc, parse_table_row(r))) }
    }
}

# Parse "| a | b | c |" → ["a", "b", "c"]. Drops the leading and
# trailing empty cells produced by surrounding `|` characters.
fun parse_table_row(line) {
    t = string_trim(line)
    parts = string_split(t, "|")
    trimmed = trim_cells(parts, [])
    drop_edge_empties(trimmed)
}

fun trim_cells(items, acc) {
    if (length(items) == 0) { acc }
    else { trim_cells(tl(items), list_append(acc, string_trim(hd(items)))) }
}

# Drop a leading "" and a trailing "" if present (artifacts of the
# bordering `|` chars). Keep internal empties — they're real empty cells.
fun drop_edge_empties(cells) {
    after_lead = if (length(cells) == 0) { cells }
                 else { if (string_length(hd(cells)) == 0) { tl(cells) }
                 else { cells }}
    drop_trail_empty(after_lead)
}

fun drop_trail_empty(cells) {
    n = length(cells)
    if (n == 0) { cells }
    else {
        last_v = list_last(cells)
        if (string_length(last_v) == 0) { take_n(cells, n - 1, []) }
        else { cells }
    }
}

fun take_n(lst, n, acc) {
    if (n <= 0) { acc }
    else { if (length(lst) == 0) { acc }
    else { take_n(tl(lst), n - 1, list_append(acc, hd(lst))) }}
}

# Compute max display width per column across all rows.
fun compute_col_widths(rows, acc) {
    if (length(rows) == 0) { acc }
    else {
        row_widths = row_to_widths(hd(rows), [])
        merged = merge_widths(acc, row_widths, [])
        compute_col_widths(tl(rows), merged)
    }
}

fun row_to_widths(cells, acc) {
    if (length(cells) == 0) { acc }
    else {
        rendered = render_inline(hd(cells))
        row_to_widths(tl(cells), list_append(acc, display_width(rendered)))
    }
}

# Element-wise max of two width lists, padding the shorter with 0.
fun merge_widths(a, b, acc) {
    if (length(a) == 0 && length(b) == 0) { acc }
    else { if (length(a) == 0) { merge_widths(a, tl(b), list_append(acc, hd(b))) }
    else { if (length(b) == 0) { merge_widths(tl(a), b, list_append(acc, hd(a))) }
    else {
        ah = hd(a)
        bh = hd(b)
        m = if (ah > bh) { ah } else { bh }
        merge_widths(tl(a), tl(b), list_append(acc, m))
    }}}
}

# Render one row as "  cell1 │ cell2 │ cell3" with each cell padded.
fun render_row(cells, widths) {
    "  " ++ row_cells_loop(cells, widths, "")
}

fun row_cells_loop(cells, widths, acc) {
    if (length(cells) == 0) { acc }
    else {
        cell = hd(cells)
        col_width = if (length(widths) == 0) { display_width(cell) } else { hd(widths) }
        padded = render_cell(cell, col_width)
        sep = if (string_length(acc) == 0) { "" } else { " " ++ UI.grey_border() ++ "│" ++ UI.reset() ++ " " }
        next_widths = if (length(widths) == 0) { [] } else { tl(widths) }
        row_cells_loop(tl(cells), next_widths, acc ++ sep ++ padded)
    }
}

fun pad_chars(n, acc) {
    if (n <= 0) { acc }
    else { pad_chars(n - 1, acc ++ " ") }
}

# Render one cell to exactly `col_width` display columns. When the content
# is too wide we truncate the RAW text (before render_inline adds ANSI), so
# we never split an escape sequence, then append a 1-col ellipsis.
fun render_cell(cell, col_width) {
    rendered = render_inline(cell)
    dw = display_width(rendered)
    if (dw <= col_width) {
        rendered ++ pad_chars(col_width - dw, "")
    } else {
        room = if (col_width > 1) { col_width - 1 } else { 1 }
        r2 = render_inline(truncate_raw(cell, room))
        dw2 = display_width(r2)
        pad_n = col_width - dw2 - 1
        r2 ++ "…" ++ pad_chars(if (pad_n > 0) { pad_n } else { 0 }, "")
    }
}

# Truncate a raw string to at most `n` bytes. Cells are typically ASCII; a
# rare multibyte cut is cosmetic and far better than a table overflowing the
# terminal and hard-wrapping mid-cell.
fun truncate_raw(s, n) {
    if (string_length(s) <= n) { s }
    else { string_sub(s, 0, n) }
}

# Shrink column widths so the whole row fits `width`. Layout is
# "  c1 │ c2 │ … │ cN" → 2 leading cols + 3 cols per separator (N-1 of them).
# When natural widths overflow, scale each by avail/total with a small floor
# so the widest columns surrender the most space.
fun clamp_table_widths(widths, width) {
    n = length(widths)
    if (n == 0) { widths }
    else {
        overhead = 2 + 3 * (n - 1)
        avail = width - overhead
        total = sum_ints(widths, 0)
        if (avail < n || total <= avail) { widths }
        else {
            # First pass: proportional scale with a per-column floor of 1.
            # Floor at 1 (not 4) so narrow cols don't eat surplus budget.
            scaled = scale_widths(widths, avail, total, [])
            # Second pass: shave any rounding/floor surplus from the widest
            # column(s) until sum == avail. This guarantees the row fits width.
            trim_to_avail(scaled, avail)
        }
    }
}

fun sum_ints(xs, acc) {
    if (length(xs) == 0) { acc }
    else { sum_ints(tl(xs), acc + hd(xs)) }
}

fun scale_widths(widths, avail, total, acc) {
    if (length(widths) == 0) { acc }
    else {
        w = hd(widths)
        scaled = (w * avail) / total
        floored = if (scaled < 1) { 1 } else { scaled }
        scale_widths(tl(widths), avail, total, list_append(acc, floored))
    }
}

# Shave (sum - avail) display columns off the widest column(s), one at a time,
# until the total equals avail. Each shave keeps a floor of 1. O(surplus) steps
# but surplus is bounded by n (rounding + floor) so it's always tiny.
fun trim_to_avail(widths, avail) {
    s = sum_ints(widths, 0)
    if (s <= avail) { widths }
    else { trim_to_avail(shave_widest(widths, [], 0), avail) }
}

fun shave_widest(widths, acc, max_so_far) {
    # Find the value of the widest column.
    mx = find_max(widths, 0)
    shave_widest_at(widths, acc, mx, 'false')
}

fun find_max(xs, m) {
    if (length(xs) == 0) { m }
    else {
        h = hd(xs)
        find_max(tl(xs), if (h > m) { h } else { m })
    }
}

# Shave 1 from the first occurrence of `mx` that is > 1, leave rest unchanged.
fun shave_widest_at(widths, acc, mx, done) {
    if (length(widths) == 0) { acc }
    else {
        w = hd(widths)
        if (done == 'false' && w == mx && w > 1) {
            shave_widest_at(tl(widths), list_append(acc, w - 1), mx, 'true')
        } else {
            shave_widest_at(tl(widths), list_append(acc, w), mx, done)
        }
    }
}

# Divider beneath the header row: ──── per column joined with ┼.
fun render_divider(widths) {
    "  " ++ UI.grey_border() ++ divider_loop(widths, "") ++ UI.reset()
}

fun divider_loop(widths, acc) {
    if (length(widths) == 0) { acc }
    else {
        w = hd(widths)
        bar = make_dashes(w, "")
        sep = if (string_length(acc) == 0) { "" } else { "─┼─" }
        divider_loop(tl(widths), acc ++ sep ++ bar)
    }
}

fun render_body_rows(rows, widths, acc) {
    if (length(rows) == 0) { acc }
    else {
        line = render_row(hd(rows), widths)
        next_acc = if (string_length(acc) == 0) { line } else { acc ++ "\n" ++ line }
        render_body_rows(tl(rows), widths, next_acc)
    }
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
        # Try to match `` `...` `` first (code spans have priority over emphasis).
        if (peek1(s, i) == "`") {
            code_close = find_close(s, i + 1, "`")
            if (code_close < 0) {
                inline_loop(s, i + 1, acc ++ "`")
            } else {
                code_inner = string_sub(s, i + 1, code_close - (i + 1))
                colored = UI.brand_color() ++ code_inner ++ UI.reset()
                inline_loop(s, code_close + 1, acc ++ colored)
            }
        } else { if (peek2(s, i) == "**") {
            bold_close = find_close(s, i + 2, "**")
            # CommonMark-ish flanking: no closer, an EMPTY span (`****`), or a
            # space right inside either delimiter (`a ** b ** c`, glob/math
            # `2 ** 8`) is not emphasis — emit a literal "**" and keep scanning.
            if (bold_close < 0 || bold_close == i + 2
                || string_sub(s, i + 2, 1) == " "
                || string_sub(s, bold_close - 1, 1) == " ") {
                inline_loop(s, i + 2, acc ++ "**")
            } else {
                bold_inner = string_sub(s, i + 2, bold_close - (i + 2))
                inline_loop(s, bold_close + 2, acc ++ "\e[1m" ++ bold_inner ++ UI.reset())
            }
        } else { if (peek1(s, i) == "[") {
            # Markdown link [label](url): render the label, then the URL
            # dimmed in parens. Falls through to a literal "[" on any
            # non-match (lone bracket, missing "](", unclosed paren).
            close_br = find_close(s, i + 1, "]")
            if (close_br < 0 || peek1(s, close_br + 1) != "(") {
                inline_loop(s, i + 1, acc ++ "[")
            } else {
                close_paren = find_close(s, close_br + 2, ")")
                if (close_paren < 0) {
                    inline_loop(s, i + 1, acc ++ "[")
                } else {
                    label = string_sub(s, i + 1, close_br - (i + 1))
                    url = string_sub(s, close_br + 2, close_paren - (close_br + 2))
                    link_out = render_inline(label) ++ " " ++
                               UI.grey_text() ++ "(" ++ url ++ ")" ++ UI.reset()
                    inline_loop(s, close_paren + 1, acc ++ link_out)
                }
            }
        } else {
            ch = string_sub(s, i, 1)
            inline_loop(s, i + 1, acc ++ ch)
        }}}
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
    # A CSI sequence's FINAL byte is a letter (m, K, J, H, A-G, n, …). The
    # introducer '[', the digits, and ';' parameter bytes are NOT terminators,
    # so accepting any ASCII letter terminates correctly without prematurely
    # ending on '['. The old hand-list missed many valid finals (I, L, M, etc.),
    # which made display_width swallow following text as zero-width.
    if ((ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z")) { 'true' }
    else { 'false' }
}

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

fun indent_line(line, width) { "  " ++ line }

# ============================================================
# Post-stream re-render — clear the C-streamed prose and reprint it
# through the markdown renderer with a 2-col gutter.
# ============================================================
#
# During an LLM call swarmrt's http_post_stream emits tokens straight
# to the terminal — that's the live-feedback the user values, but it
# means literal `**bold**`, `### Headers`, fence markers, etc. land
# on screen as text. After the stream ends we know the full prose,
# so we wipe the streamed region and re-emit it formatted.
#
# Mechanics: cursor sits at end-of-prose. We move to column 0 with
# \r, clear current line, then `\e[1A\e[K` once per terminal row the
# prose consumed (counted from char length / term_width). Reasoning
# content (Kimi K2 thinking mode) streams BEFORE prose and is left
# untouched — only the prose tail is rewritten. Tool-call sequels
# stay clean too because tool_header / tool_result already render
# AFTER repaint runs.
#
# Disabled by SWARM_CODE_RAW_STREAM=1 — power users who prefer the
# unfiltered token stream can opt out.
fun repaint_streamed_prose(prose) {
    if (string_length(string_trim(to_string(prose))) == 0) { 'noop' }
    else {
        env_raw = getenv("SWARM_CODE_RAW_STREAM")
        if (env_raw == "1") { 'noop' }
        else {
            if (has_markdown(prose) == 'false') { 'noop' }
            else {
                w = UI.term_width()
                # Prefer the authoritative physical-row count the C stream
                # emitter recorded for THIS turn's content — it accounts for
                # soft-wrap at the real margin and UTF-8 display width exactly,
                # which the byte-based count_terminal_rows cannot. Fall back to
                # the estimate only if the builtin reports nothing.
                c_rows = stream_content_rows()
                rows = if (c_rows > 0) { c_rows } else { count_terminal_rows(prose, w) }
                # The cursor-up clear (`\e[1A\e[K`) can only walk back
                # as far as the top of the terminal's visible region.
                # If the streamed response was longer than that, the
                # earlier rows scrolled into the scrollback buffer and
                # can't be wiped — so the rendered version would end
                # up sandwiched between raw text above (scrolled off-
                # then-back-on as the user looks at it) and rendered
                # below.
                #
                # For long messages we switch strategy: leave the raw
                # stream alone, print a visible separator, and emit the
                # rendered version below as the "final" view. The user
                # gets clean formatting at the end of the buffer (where
                # their eyes are) and the raw stream still serves as
                # the live transcript.
                threshold = clearable_threshold()
                if (rows > threshold) {
                    print("")
                    print("  " ++ UI.grey_border() ++
                          "─── rendered ───" ++ UI.reset())
                    print("")
                    print(render(prose, w))
                } else {
                    # Short message — the cursor-clear works cleanly.
                    # Clear `rows` lines upward (one more than the math
                    # says) to absorb the C-side trailing newline
                    # between reasoning_content and content; otherwise
                    # the topmost prose row (usually the H1/H2 heading)
                    # leaks past the clear.
                    print_inline("\r\e[K")
                    clear_rows_up(rows)
                    print(render(prose, w))
                }
            }
        }
    }
}

# Cheap heuristic — skip the repaint when prose is plain text. Avoids
# eating a frame for "hi" and similar trivial replies, and keeps the
# UX identical for non-markdown content.
fun has_markdown(s) {
    if (string_contains(s, "**") == 'true') { 'true' }
    else { if (has_code_span(s) == 'true') { 'true' }
    else { if (has_heading(s) == 'true') { 'true' }
    else { if (string_contains(s, "\n- ") == 'true') { 'true' }
    else { if (string_starts_with(s, "- ") == 'true') { 'true' }
    else { if (string_contains(s, "\n* ") == 'true') { 'true' }
    else { if (string_starts_with(s, "* ") == 'true') { 'true' }
    else { if (string_contains(s, "\n> ") == 'true') { 'true' }
    else { if (string_contains(s, "\n|") == 'true') { 'true' }
    else { 'false' }}}}}}}}}
}

# Inline code or a fence needs at least TWO backticks (a balanced pair) —
# a single stray backtick, common in technical prose, no longer fires.
fun has_code_span(s) {
    if (length(string_split(s, "`")) >= 3) { 'true' } else { 'false' }
}

# A heading marker only counts at the START of a line (string start or after
# a newline), so an inline "C#"/"F#" no longer triggers an unnecessary repaint.
# `# ` matched anywhere previously — `string_contains(s, "# ")` is true for
# "in C# yesterday". The renderer's header_depth still validates the real form.
fun has_heading(s) {
    if (string_starts_with(s, "#") == 'true') { 'true' }
    else { if (string_contains(s, "\n#") == 'true') { 'true' } else { 'false' }}
}

# Conservative ceiling on how many rows we'll attempt to clear via
# the cursor-up sequence. Anything beyond this risks the cursor
# bumping into the top of the visible region before the clear
# completes, leaving partial raw text on screen. macOS Terminal and
# iTerm typically run 35-60 rows; we cap below the smallest common
# default to be safe across different setups.
fun max_clearable_rows() { 25 }

# How many rows we can safely walk the cursor up and clear: anything still
# on screen. We use the real terminal height (term_rows builtin) minus a
# small margin for the trailing newline + the line the cursor rests on.
# If the prose is taller than this, its top scrolled into scrollback and
# can't be wiped — so we fall back to printing the rendered form below a
# separator. Falls back to the conservative constant when height is unknown.
fun clearable_threshold() {
    tr = term_rows()
    if (tr > 6) { tr - 2 } else { max_clearable_rows() }
}

# Total terminal rows the prose occupies — sum of ceil(len/width)
# for each hard-newline-delimited line, with empty lines counted as 1.
fun count_terminal_rows(prose, width) {
    lines = string_split(prose, "\n")
    sum_rows(lines, width, 0)
}

fun sum_rows(lines, width, acc) {
    if (length(lines) == 0) { acc }
    else {
        line_len = string_length(hd(lines))
        rows = if (line_len == 0) { 1 }
               else { (line_len + width - 1) / width }
        sum_rows(tl(lines), width, acc + rows)
    }
}

fun clear_rows_up(n) {
    if (n <= 0) { 'ok' }
    else {
        print_inline("\e[1A\e[K")
        clear_rows_up(n - 1)
    }
}

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
