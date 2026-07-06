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
#   `- X` `* X` `+ X`       → bullet • prefix (nested: ◦ ▪ ▫ by indent)
#   `1. X` / `1) X`         → ordered item, hanging indent
#   `- [ ] X` / `- [x] X`   → task checkbox ◻ / green ✔
#   `> X`                   → dim │ blockquote bar
#   ```                      → code fence (until closing ```)
#   `---` (alone on a line)  → horizontal rule
#   blank line              → paragraph break
#   anything else           → paragraph text
#
# Inline handling (within paragraph / heading / bullet / blockquote):
#   `**X**` / `__X__`        → ANSI bold
#   `*X*` / `_X_`            → ANSI italic (flanking heuristic; `_` not mid-word)
#   `~~X~~`                  → ANSI strikethrough
#   `` `X` ``                → ANSI inline-code color
#   `\*` `\_` `` \` ``       → backslash escapes (literal char, no markup)
#   `[label](url)`          → OSC-8 hyperlink (or `label (url)` when colors off)
#
# Soft word-wrap: every output line is wrapped at `width` columns at
# WORD boundaries. Never break a word mid-string. Display width
# accounts for the 2-col indent + ANSI codes don't count toward width.

import UI

export [render, repaint_streamed_prose, has_markdown, display_width,
        stream_feed, stream_flush, fence_info]

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
            blocks = walk_blocks(lines, [], 'false', [], nil, "")
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
# `code_acc` accumulates the lines of an open FENCED block; `fence_mk`
# is the marker that opened it ("```" or "~~~") — a fence only closes on
# its own marker, so a ``` line inside a ~~~ block stays content — and
# `code_lang` is the info-string language captured from the opening
# fence. Code blocks carry payload {lang, lines}.
fun walk_blocks(lines, code_acc, in_code, blocks, fence_mk, code_lang) {
    if (length(lines) == 0) {
        if (in_code == 'true') {
            list_append(blocks, {'code', {code_lang, code_acc}})
        } else {
            blocks
        }
    } else {
        line = hd(lines)
        rest = tl(lines)
        if (in_code == 'true') {
            if (sf_fence_closes(line, fence_mk) == 'true') {
                walk_blocks(rest, [], 'false', list_append(blocks, {'code', {code_lang, code_acc}}), nil, "")
            } else {
                walk_blocks(rest, list_append(code_acc, line), 'true', blocks, fence_mk, code_lang)
            }
        } else {
            fm = sf_fence_marker(line)
            if (fm != nil) {
                # Fence OPEN (``` or ~~~) — capture the info-string language.
                walk_blocks(rest, [], 'true', blocks, fm, fence_info(line))
            } else { if (is_blank(line) == 'true') {
                walk_blocks(rest, [], 'false', list_append(blocks, {'blank', ""}), nil, "")
            } else { if (is_hr(line) == 'true') {
                walk_blocks(rest, [], 'false', list_append(blocks, {'hr', ""}), nil, "")
            } else { if (header_depth(line) > 0) {
                d = header_depth(line)
                t = strip_prefix(line, header_prefix(d))
                walk_blocks(rest, [], 'false', list_append(blocks, {'header', {d, t}}), nil, "")
            } else { if (is_bullet(line) == 'true') {
                walk_blocks(rest, [], 'false', list_append(blocks, {'bullet', {bullet_level(line), bullet_text(line)}}), nil, "")
            } else { if (is_ordered(line) == 'true') {
                walk_blocks(rest, [], 'false', list_append(blocks, {'ordered', {bullet_level(line), ordered_marker(line), ordered_text(line)}}), nil, "")
            } else { if (is_quote(line) == 'true') {
                # Blockquote — capture nesting depth (`> >` → 2) so the
                # renderer can stack gutter bars, and the stripped content.
                walk_blocks(rest, [], 'false', list_append(blocks, {'quote', {quote_depth(line), quote_content(line)}}), nil, "")
            } else { if (is_table_row(line) == 'true') {
                # Collect this and any consecutive table rows into a
                # single 'table' block. Without this they fell through
                # to the paragraph branch and got space-joined into
                # one mangled line.
                tbl_last = if (length(blocks) == 0) { nil } else { list_last(blocks) }
                if (tbl_last != nil && elem(tbl_last, 0) == 'table') {
                    tbl_rows = elem(tbl_last, 1)
                    tbl_blocks = list_set_last(blocks, {'table', list_append(tbl_rows, string_trim(line))})
                    walk_blocks(rest, [], 'false', tbl_blocks, nil, "")
                } else {
                    walk_blocks(rest, [], 'false', list_append(blocks, {'table', [string_trim(line)]}), nil, "")
                }
            } else { if (is_indented_code(line) == 'true' && indcode_ok(blocks) == 'true') {
                # A run of >=4-space / tab-indented lines that begins
                # outside another block is an indented code block. It
                # renders through the same gutter path as a fence (lang
                # unknown). is_indented_code sits AFTER the bullet check
                # so "    - nested" is still a nested list, and indcode_ok
                # requires the previous block to be blank/none/code so a
                # 4-space wrapped paragraph continuation is not captured.
                stripped = strip_indent(line)
                ic_last = if (length(blocks) == 0) { nil } else { list_last(blocks) }
                if (ic_last != nil && elem(ic_last, 0) == 'code') {
                    cd = elem(ic_last, 1)
                    clines = elem(cd, 1)
                    ic_blocks = list_set_last(blocks, {'code', {elem(cd, 0), list_append(clines, stripped)}})
                    walk_blocks(rest, [], 'false', ic_blocks, nil, "")
                } else {
                    walk_blocks(rest, [], 'false', list_append(blocks, {'code', {"", [stripped]}}), nil, "")
                }
            } else {
                # Paragraph — extend or start. We keep paragraphs as
                # single blocks so the soft-wrap can re-flow them.
                last = if (length(blocks) == 0) { nil } else { list_last(blocks) }
                if (last != nil && elem(last, 0) == 'para') {
                    cur = elem(last, 1)
                    merged = cur ++ " " ++ string_trim(line)
                    new_blocks = list_set_last(blocks, {'para', merged})
                    walk_blocks(rest, [], 'false', new_blocks, nil, "")
                } else {
                    walk_blocks(rest, [], 'false', list_append(blocks, {'para', string_trim(line)}), nil, "")
                }
            }}}}}}}}}
        }
    }
}

# Info-string language from an opening fence line: the first token after
# the marker. "```sw" → "sw", "~~~python {.numberLines}" → "python",
# "```" → "".
fun fence_info(line) {
    t = string_trim(line)
    mk = sf_fence_marker(t)
    if (mk == nil) { "" }
    else {
        # Skip the WHOLE marker run — a 4-backtick fence must not yield a
        # bogus "`" language label.
        ml = string_length(mk)
        rest = string_trim(string_sub(t, ml, string_length(t) - ml))
        parts = string_split(rest, " ")
        if (length(parts) == 0) { "" } else { string_trim(hd(parts)) }
    }
}

# An indented code line: 4+ leading spaces or a leading tab, non-blank.
fun is_indented_code(line) {
    if (is_blank(line) == 'true') { 'false' }
    else {
        if (leading_spaces(line, 0) >= 4) { 'true' }
        else { if (string_length(line) > 0 && string_sub(line, 0, 1) == "\t") { 'true' }
        else { 'false' }}
    }
}

# Strip exactly one indent level (a tab or 4 spaces), preserving any
# deeper internal indentation inside the code block.
fun strip_indent(line) {
    if (string_length(line) > 0 && string_sub(line, 0, 1) == "\t") {
        string_sub(line, 1, string_length(line) - 1)
    } else {
        n = string_length(line)
        if (n >= 4) { string_sub(line, 4, n - 4) } else { line }
    }
}

# Indented code may only START when the previous block is a blank, a
# code block (continuation), or nothing — never mid-paragraph/list, so
# reflowed prose and nested lists are not swallowed.
fun indcode_ok(blocks) {
    if (length(blocks) == 0) { 'true' }
    else {
        k = elem(list_last(blocks), 0)
        if (k == 'blank' || k == 'code') { 'true' } else { 'false' }
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

fun is_bullet(line) {
    t = string_trim(line)
    if (string_length(t) < 2) { 'false' }
    else {
        h2 = string_sub(t, 0, 2)
        if (h2 == "- " || h2 == "* " || h2 == "+ ") { 'true' } else { 'false' }
    }
}

fun bullet_text(line) {
    t = string_trim(line)
    string_sub(t, 2, string_length(t) - 2)
}

# Nesting level for list items: floor(leading spaces / 2), capped at 3.
# "- x" → 0, "  - x" → 1, "    - x" → 2. Previously the trim discarded
# the indent and every nested list flattened to one level.
fun bullet_level(line) {
    sp = leading_spaces(line, 0)
    lvl = sp / 2
    if (lvl > 3) { 3 } else { lvl }
}

fun leading_spaces(s, i) {
    if (i >= string_length(s)) { i }
    else {
        if (string_sub(s, i, 1) == " ") { leading_spaces(s, i + 1) }
        else { i }
    }
}

# Ordered list item: 1-3 digits, then "." or ")", then a space.
# These previously fell through to the paragraph branch and consecutive
# numbered lines were space-merged into ONE line — the most visible
# markdown bug, since models emit numbered lists constantly.
fun is_ordered(line) {
    t = string_trim(line)
    n = digits_len(t, 0)
    if (n < 1 || n > 3) { 'false' }
    else {
        if (string_length(t) < n + 2) { 'false' }
        else {
            p = string_sub(t, n, 1)
            if ((p == "." || p == ")") && string_sub(t, n + 1, 1) == " ") { 'true' }
            else { 'false' }
        }
    }
}

fun digits_len(s, i) {
    if (i >= string_length(s)) { i }
    else {
        ch = string_sub(s, i, 1)
        if (ch >= "0" && ch <= "9") { digits_len(s, i + 1) }
        else { i }
    }
}

# "12. text" → "12."   "3) text" → "3)"
fun ordered_marker(line) {
    t = string_trim(line)
    n = digits_len(t, 0)
    string_sub(t, 0, n + 1)
}

fun ordered_text(line) {
    t = string_trim(line)
    n = digits_len(t, 0)
    string_sub(t, n + 2, string_length(t) - (n + 2))
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

# Nesting depth of a blockquote: the count of leading ">" markers,
# tolerating spaces between them. "> x" → 1, "> > x" / ">> x" → 2.
fun quote_depth(line) {
    qd_loop(string_trim(line), 0)
}

fun qd_loop(s, n) {
    t = string_trim(s)
    if (string_length(t) > 0 && string_sub(t, 0, 1) == ">") {
        qd_loop(string_sub(t, 1, string_length(t) - 1), n + 1)
    } else { n }
}

# The quote text with every leading ">" (and its padding) stripped.
fun quote_content(line) {
    qc_strip(string_trim(line))
}

fun qc_strip(s) {
    t = string_trim(s)
    if (string_length(t) > 0 && string_sub(t, 0, 1) == ">") {
        qc_strip(string_sub(t, 1, string_length(t) - 1))
    } else { t }
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
    else { if (prev_kind == 'ordered' && cur_kind == 'ordered') { "\n" }
    else { if (prev_kind == 'bullet' && cur_kind == 'ordered') { "\n" }
    else { if (prev_kind == 'ordered' && cur_kind == 'bullet') { "\n" }
    else { if (prev_kind == 'quote' && cur_kind == 'quote') { "\n" }
    else { "\n\n" }}}}}}
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
    else { if (kind == 'ordered')  { render_ordered(payload, width) }
    else { render_para(payload, width) }}}}}}}}
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
    level = elem(payload, 0)
    text = elem(payload, 1)
    ind = pad_chars(2 + level * 2, "")
    # Task-list items ("[ ] x" / "[x] x") swap the dot for a checkbox.
    marker = task_marker(text, bullet_marker(level))
    body = task_body(text)
    bullet = ind ++ marker ++ " "
    # Hanging indent sized to the VISUAL prefix (indent + 1-col marker +
    # space) — display_width on the marker would double-count multibyte
    # glyphs if string_sub is byte-based.
    cont = pad_chars(2 + level * 2 + 2, "")
    rendered = render_inline(body)
    wrap_with_prefixes(rendered, bullet, cont, width)
}

# Marker glyph steps with nesting depth: • ◦ ▪ ▫
fun bullet_marker(level) {
    if (level == 0) { "•" }
    else { if (level == 1) { "◦" }
    else { if (level == 2) { "▪" }
    else { "▫" }}}
}

fun task_marker(text, fallback) {
    if (string_length(text) < 4) { fallback }
    else {
        h4 = string_sub(text, 0, 4)
        if (h4 == "[ ] ") { "◻" }
        else { if (h4 == "[x] " || h4 == "[X] ") { UI.green() ++ "✔" ++ UI.reset() }
        else { fallback }}
    }
}

fun task_body(text) {
    if (string_length(text) < 4) { text }
    else {
        h4 = string_sub(text, 0, 4)
        if (h4 == "[ ] " || h4 == "[x] " || h4 == "[X] ") {
            string_sub(text, 4, string_length(text) - 4)
        } else { text }
    }
}

# Ordered item: "  1. text" with a hanging indent under the text column.
fun render_ordered(payload, width) {
    level = elem(payload, 0)
    marker = elem(payload, 1)
    text = elem(payload, 2)
    ind = pad_chars(2 + level * 2, "")
    prefix = ind ++ marker ++ " "
    cont = pad_chars(2 + level * 2 + string_length(marker) + 1, "")
    rendered = render_inline(text)
    wrap_with_prefixes(rendered, prefix, cont, width)
}

# Blockquote — stack one dim "│ " gutter bar per nesting level, so a
# `> >` quote shows two bars. payload is {depth, content}.
fun render_quote(payload, width) {
    depth = elem(payload, 0)
    content = elem(payload, 1)
    d = if (depth < 1) { 1 } else { depth }
    bar = "  " ++ UI.grey_border() ++ qb_loop(d, "") ++ UI.reset()
    rendered = render_inline(content)
    wrap_with_prefixes(rendered, bar, bar, width)
}

fun qb_loop(n, acc) {
    if (n <= 0) { acc }
    else { qb_loop(n - 1, acc ++ "│ ") }
}

# ------------------------------------------------------------
# Code block rendering — payload {lang, lines}
# ------------------------------------------------------------
# A dim "│ " gutter runs down the left. Long lines hard-wrap at the
# available width; continuation rows swap the gutter for a dim "↪ " so
# the alignment (2-space indent + 2-col gutter) is preserved. A dim
# language label sits above the block when the fence carried an info
# string. Recognized languages get a small keyword highlighter.
#
# Wrapping is computed on the RAW line (display-width aware, so CJK code
# never overflows) and each physical segment is highlighted afterwards —
# so the highlighter's ANSI never confuses the column math.
fun render_code(payload, width) {
    lang = to_string(elem(payload, 0))
    lines = elem(payload, 1)
    avail = if (width - 4 < 4) { 4 } else { width - 4 }
    body = code_render_loop(lines, lang, avail, "")
    if (string_length(lang) == 0) { body }
    else {
        label = "  " ++ UI.grey_text() ++ lang ++ UI.reset()
        if (string_length(body) == 0) { label } else { label ++ "\n" ++ body }
    }
}

fun code_render_loop(lines, lang, avail, acc) {
    if (length(lines) == 0) { acc }
    else {
        rendered = render_code_line(hd(lines), lang, avail)
        next = if (string_length(acc) == 0) { rendered } else { acc ++ "\n" ++ rendered }
        code_render_loop(tl(lines), lang, avail, next)
    }
}

# One logical code line → one or more physical rows (wrapped at `avail`).
fun render_code_line(line, lang, avail) {
    rcl_join(wrap_code_line(line, avail), lang, 'true', "")
}

fun rcl_join(segs, lang, first, acc) {
    if (length(segs) == 0) { acc }
    else {
        glyph = if (first == 'true') { "│ " } else { "↪ " }
        gutter = UI.grey_border() ++ glyph ++ UI.reset()
        row = "  " ++ gutter ++ highlight_code(hd(segs), lang)
        next = if (string_length(acc) == 0) { row } else { acc ++ "\n" ++ row }
        rcl_join(tl(segs), lang, 'false', next)
    }
}

# Hard-wrap a raw line into segments each <= `avail` DISPLAY columns,
# breaking on codepoint boundaries (never mid-UTF-8, wide chars count 2).
fun wrap_code_line(line, avail) {
    a = if (avail < 1) { 1 } else { avail }
    wcl(string_chars(line), a, "", 0, [])
}

fun wcl(chars, avail, cur, curw, acc) {
    if (length(chars) == 0) {
        if (string_length(cur) == 0 && length(acc) > 0) { acc }
        else { list_append(acc, cur) }
    } else {
        c = hd(chars)
        cw = cp_width(first_cp(c))
        if (curw + cw > avail && curw > 0) {
            wcl(chars, avail, "", 0, list_append(acc, cur))
        } else {
            wcl(tl(chars), avail, cur ++ c, curw + cw, acc)
        }
    }
}

# ------------------------------------------------------------
# Small keyword highlighter — bold keywords, green string spans, dim
# comments. Naive by design (per-segment, no cross-line state): good
# enough to make code scannable without a real lexer. Unknown languages
# pass through untouched.
# ------------------------------------------------------------
fun highlight_code(line, lang) {
    if (is_supported_lang(lang) == 'false') { line }
    else { hl_scan(line, 0, string_length(line), keywords_for(lang), comment_marker(lang), "", "") }
}

fun hl_scan(s, i, n, kws, cmt, word, acc) {
    if (i >= n) { acc ++ flush_word(word, kws) }
    else {
        ch = string_sub(s, i, 1)
        if (is_ident_char(ch) == 'true') {
            hl_scan(s, i + 1, n, kws, cmt, word ++ ch, acc)
        } else {
            acc2 = acc ++ flush_word(word, kws)
            if (ch == "\"" || ch == "'") {
                close = find_close(s, i + 1, ch)
                if (close < 0) {
                    acc2 ++ UI.green() ++ string_sub(s, i, n - i) ++ UI.reset()
                } else {
                    span = string_sub(s, i, close - i + 1)
                    hl_scan(s, close + 1, n, kws, cmt, "", acc2 ++ UI.green() ++ span ++ UI.reset())
                }
            } else { if (cmt != "" && is_comment_at(s, i, n, cmt) == 'true') {
                acc2 ++ UI.grey_text() ++ string_sub(s, i, n - i) ++ UI.reset()
            } else {
                hl_scan(s, i + 1, n, kws, cmt, "", acc2 ++ ch)
            }}
        }
    }
}

fun flush_word(word, kws) {
    if (string_length(word) == 0) { "" }
    else { if (keyword_member(word, kws) == 'true') { UI.bold() ++ word ++ UI.reset() }
    else { word }}
}

fun keyword_member(w, kws) {
    if (length(kws) == 0) { 'false' }
    else { if (hd(kws) == w) { 'true' } else { keyword_member(w, tl(kws)) }}
}

fun is_ident_char(ch) {
    if ((ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")
        || (ch >= "0" && ch <= "9") || ch == "_") { 'true' }
    else { 'false' }
}

fun is_comment_at(s, i, n, cmt) {
    cl = string_length(cmt)
    if (i + cl > n) { 'false' }
    else { if (string_sub(s, i, cl) == cmt) { 'true' } else { 'false' }}
}

fun is_supported_lang(lang) {
    if (lang == "sw" || lang == "rust" || lang == "rs" || lang == "python"
        || lang == "py" || lang == "js" || lang == "javascript" || lang == "ts"
        || lang == "typescript" || lang == "go" || lang == "c") { 'true' }
    else { 'false' }
}

fun comment_marker(lang) {
    if (lang == "sw" || lang == "python" || lang == "py") { "#" }
    else { if (lang == "rust" || lang == "rs" || lang == "js" || lang == "javascript"
             || lang == "ts" || lang == "typescript" || lang == "go" || lang == "c") { "//" }
    else { "" }}
}

fun keywords_for(lang) {
    if (lang == "sw") {
        ["fun","if","else","module","import","export","receive","spawn","send",
         "self","after","match","case","true","false","nil","for","while","return","let"]
    } else { if (lang == "rust" || lang == "rs") {
        ["fn","let","mut","pub","struct","enum","impl","use","mod","match","if","else",
         "for","while","loop","return","self","trait","where","async","await","move",
         "ref","const","static","type","as","dyn","break","continue"]
    } else { if (lang == "python" || lang == "py") {
        ["def","class","if","elif","else","for","while","return","import","from","as",
         "with","try","except","finally","lambda","yield","pass","break","continue",
         "and","or","not","in","is","None","True","False","global","nonlocal","raise",
         "assert","async","await"]
    } else { if (lang == "js" || lang == "javascript" || lang == "ts" || lang == "typescript") {
        ["function","let","const","var","if","else","for","while","return","class","new",
         "this","import","export","from","async","await","try","catch","finally","throw",
         "typeof","instanceof","null","undefined","true","false","of","in","switch","case",
         "break","continue","default","extends","super","yield"]
    } else { if (lang == "go") {
        ["func","var","const","if","else","for","range","return","package","import","type",
         "struct","interface","map","chan","go","defer","select","switch","case","default",
         "break","continue","nil","true","false"]
    } else { if (lang == "c") {
        ["int","char","void","float","double","long","short","unsigned","signed","struct",
         "enum","union","static","const","if","else","for","while","do","return","switch",
         "case","break","continue","sizeof","typedef","goto","extern","volatile","register","inline"]
    } else { [] }}}}}}
}

fun render_hr(width) {
    bar = make_dashes(width - 2, "")
    "  " ++ UI.grey_border() ++ bar ++ UI.reset()
}

# ------------------------------------------------------------
# Table rendering
# ------------------------------------------------------------
# rows: list of raw "| a | b | c |" lines (alignment row included).
# Strategy: parse the alignment row for per-column :---: alignment, parse
# the data rows into trimmed cells, compute max width per column, clamp to
# fit `width`, then render. A cell wider than its (clamped) column WRAPS to
# multiple physical rows — siblings are padded with blank continuation
# rows so the columns stay aligned — rather than being truncated with an
# ellipsis. Only degenerate columns clamped to <=2 cols fall back to
# single-line ellipsis truncation (wrapping to 1-2 cols is unreadable).
fun render_table(rows, width) {
    aligns = parse_alignments(rows)
    parsed = parse_rows(rows, [])
    if (length(parsed) == 0) { "" }
    else {
        raw_widths = compute_col_widths(parsed, [])
        widths = clamp_table_widths(raw_widths, width)
        head = hd(parsed)
        body = tl(parsed)
        head_line = render_wrapped_row(head, widths, aligns, 'true')
        div_line = render_divider(widths)
        body_lines = render_body_wrapped(body, widths, aligns, "")
        if (string_length(body_lines) == 0) {
            head_line ++ "\n" ++ div_line
        } else {
            head_line ++ "\n" ++ div_line ++ "\n" ++ body_lines
        }
    }
}

# Per-column alignment from the `|:---|---:|:--:|` row: 'left / 'right /
# 'center. Empty list when there is no alignment row (default left).
fun parse_alignments(rows) {
    ar = find_align_row(rows)
    if (ar == nil) { [] }
    else { aligns_of(parse_table_row(ar), []) }
}

fun find_align_row(rows) {
    if (length(rows) == 0) { nil }
    else { if (is_table_align_row(hd(rows)) == 'true') { hd(rows) }
    else { find_align_row(tl(rows)) }}
}

fun aligns_of(cells, acc) {
    if (length(cells) == 0) { acc }
    else { aligns_of(tl(cells), list_append(acc, align_of_cell(string_trim(hd(cells))))) }
}

fun align_of_cell(c) {
    n = string_length(c)
    starts = if (n > 0 && string_sub(c, 0, 1) == ":") { 'true' } else { 'false' }
    ends = if (n > 0 && string_sub(c, n - 1, 1) == ":") { 'true' } else { 'false' }
    if (starts == 'true' && ends == 'true') { 'center' }
    else { if (ends == 'true') { 'right' } else { 'left' }}
}

fun align_at(aligns, i) {
    if (length(aligns) == 0) { 'left' }
    else { if (i <= 0) { hd(aligns) } else { align_at(tl(aligns), i - 1) }}
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

fun pad_chars(n, acc) {
    if (n <= 0) { acc }
    else { pad_chars(n - 1, acc ++ " ") }
}

# ------------------------------------------------------------
# Wrapped-cell row rendering
# ------------------------------------------------------------
# Render one logical table row (a list of raw cell strings). Each cell is
# wrapped to its column width into a list of physical lines; the row's
# height is the tallest cell, and shorter cells are padded with blank
# lines so the │ separators stay aligned down the whole row.
fun render_wrapped_row(cells, widths, aligns, is_header) {
    collines = wrap_all_cells(cells, widths, [])
    height = max_len(collines, 0)
    h = if (height < 1) { 1 } else { height }
    rwr_lines(collines, widths, aligns, is_header, 0, h, "")
}

fun render_body_wrapped(rows, widths, aligns, acc) {
    if (length(rows) == 0) { acc }
    else {
        line = render_wrapped_row(hd(rows), widths, aligns, 'false')
        next = if (string_length(acc) == 0) { line } else { acc ++ "\n" ++ line }
        render_body_wrapped(tl(rows), widths, aligns, next)
    }
}

# Wrap every cell to its column width → list (per column) of physical
# raw lines.
fun wrap_all_cells(cells, widths, acc) {
    if (length(cells) == 0) { acc }
    else {
        cw = if (length(widths) == 0) { display_width(hd(cells)) } else { hd(widths) }
        nw = if (length(widths) == 0) { [] } else { tl(widths) }
        wrap_all_cells(tl(cells), nw, list_append(acc, wrap_cell_raw(hd(cells), cw)))
    }
}

fun max_len(collines, m) {
    if (length(collines) == 0) { m }
    else {
        l = length(hd(collines))
        max_len(tl(collines), if (l > m) { l } else { m })
    }
}

# Emit `height` physical rows. For each, take the k-th line of every
# column, render + pad it, and join columns with the dim │ separator.
fun rwr_lines(collines, widths, aligns, is_header, k, height, acc) {
    if (k >= height) { acc }
    else {
        row = "  " ++ rwr_row(collines, widths, aligns, is_header, k, 0, "")
        next = if (string_length(acc) == 0) { row } else { acc ++ "\n" ++ row }
        rwr_lines(collines, widths, aligns, is_header, k + 1, height, next)
    }
}

fun rwr_row(collines, widths, aligns, is_header, k, ci, acc) {
    if (length(collines) == 0) { acc }
    else {
        cw = if (length(widths) == 0) { 0 } else { hd(widths) }
        nw = if (length(widths) == 0) { [] } else { tl(widths) }
        raw = nth_or_empty(hd(collines), k)
        cell_str = pad_aligned(render_inline(raw), cw, align_at(aligns, ci))
        piece = if (is_header == 'true') { UI.bold() ++ cell_str ++ UI.reset() } else { cell_str }
        sep = if (string_length(acc) == 0) { "" } else { " " ++ UI.grey_border() ++ "│" ++ UI.reset() ++ " " }
        rwr_row(tl(collines), nw, aligns, is_header, k, ci + 1, acc ++ sep ++ piece)
    }
}

fun nth_or_empty(lst, k) {
    if (k < 0 || length(lst) == 0) { "" }
    else { if (k == 0) { hd(lst) } else { nth_or_empty(tl(lst), k - 1) }}
}

# Pad a rendered (ANSI-carrying) cell line to `col_width` display columns
# honoring alignment. Never truncates — callers guarantee dw <= col_width.
fun pad_aligned(rendered, col_width, align) {
    dw = display_width(rendered)
    if (dw >= col_width) { rendered }
    else {
        pad = col_width - dw
        if (align == 'right') { pad_chars(pad, "") ++ rendered }
        else { if (align == 'center') {
            l = pad / 2
            pad_chars(l, "") ++ rendered ++ pad_chars(pad - l, "")
        } else { rendered ++ pad_chars(pad, "") }}
    }
}

# Wrap a RAW cell into physical lines each <= col_width display columns.
# Word-wraps on spaces; a single word longer than the column is hard-broken
# on codepoint boundaries. Columns clamped to <=2 cols truncate with an
# ellipsis instead (wrapping that narrow is unreadable).
fun wrap_cell_raw(cell, col_width) {
    if (col_width <= 2) { [ellipsis_raw(cell, col_width)] }
    else {
        words = split_words(cell)
        if (length(words) == 0) { [""] }
        else { wc_pack_raw(words, col_width, "", []) }
    }
}

fun wc_pack_raw(words, cw, cur, acc) {
    if (length(words) == 0) {
        if (string_length(cur) == 0 && length(acc) > 0) { acc }
        else { list_append(acc, cur) }
    } else {
        w = hd(words)
        wdisp = display_width(w)
        if (string_length(cur) == 0) {
            if (wdisp > cw) {
                segs = wrap_code_line(w, cw)
                acc2 = add_all_but_last(segs, acc)
                wc_pack_raw(tl(words), cw, list_last(segs), acc2)
            } else {
                wc_pack_raw(tl(words), cw, w, acc)
            }
        } else {
            if (display_width(cur) + 1 + wdisp <= cw) {
                wc_pack_raw(tl(words), cw, cur ++ " " ++ w, acc)
            } else {
                wc_pack_raw(words, cw, "", list_append(acc, cur))
            }
        }
    }
}

fun add_all_but_last(segs, acc) {
    n = length(segs)
    if (n <= 1) { acc }
    else { take_n(segs, n - 1, acc) }
}

# Truncate a RAW cell to <= cw display cols with a trailing ellipsis.
fun ellipsis_raw(cell, cw) {
    if (display_width(cell) <= cw) { cell }
    else {
        room = if (cw > 1) { cw - 1 } else { 0 }
        head = if (room == 0) { "" } else { hd(wrap_code_line(cell, room)) }
        head ++ "…"
    }
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
        # Backslash escape (`\*`, `\_`, `` \` ``, …): emit the next char
        # literally and skip both, so it never triggers markup.
        if (peek1(s, i) == "\\" && is_escapable(peek1(s, i + 1)) == 'true') {
            inline_loop(s, i + 2, acc ++ peek1(s, i + 1))
        } else { if (peek1(s, i) == "`") {
            # Code spans have priority over emphasis.
            code_close = find_close(s, i + 1, "`")
            if (code_close < 0) {
                inline_loop(s, i + 1, acc ++ "`")
            } else {
                code_inner = string_sub(s, i + 1, code_close - (i + 1))
                # De-red (Wave-3B item 1): inline code is teal/cyan now;
                # brand red is reserved for headings + the ⏺ tool bullet.
                colored = UI.code_color() ++ code_inner ++ UI.reset()
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
                inline_loop(s, bold_close + 2, acc ++ UI.bold() ++ bold_inner ++ UI.reset())
            }
        } else { if (peek2(s, i) == "__") {
            # __bold__ — same flanking as ** PLUS the not-mid-word rule
            # (underscores don't emphasize inside identifiers like a__b__c).
            und_close = find_close(s, i + 2, "__")
            if (und_close < 0 || und_close == i + 2
                || string_sub(s, i + 2, 1) == " "
                || string_sub(s, und_close - 1, 1) == " "
                || is_word_char(char_before(s, i)) == 'true'
                || is_word_char(peek1(s, und_close + 2)) == 'true') {
                inline_loop(s, i + 2, acc ++ "__")
            } else {
                und_inner = string_sub(s, i + 2, und_close - (i + 2))
                inline_loop(s, und_close + 2, acc ++ UI.bold() ++ und_inner ++ UI.reset())
            }
        } else { if (peek2(s, i) == "~~") {
            # ~~strikethrough~~
            st_close = find_close(s, i + 2, "~~")
            if (st_close < 0 || st_close == i + 2
                || string_sub(s, i + 2, 1) == " "
                || string_sub(s, st_close - 1, 1) == " ") {
                inline_loop(s, i + 2, acc ++ "~~")
            } else {
                st_inner = string_sub(s, i + 2, st_close - (i + 2))
                inline_loop(s, st_close + 2, acc ++ UI.strikethrough() ++ st_inner ++ UI.reset())
            }
        } else { if (peek1(s, i) == "[") {
            # Markdown link [label](url). Falls through to a literal "[" on
            # any non-match (lone bracket, missing "](", unclosed paren).
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
                    inline_loop(s, close_paren + 1, acc ++ render_link(label, url))
                }
            }
        } else { if (peek1(s, i) == "*") {
            # *italic* — flanking heuristic mirroring **.
            it_close = find_close(s, i + 1, "*")
            if (it_close < 0 || it_close == i + 1
                || string_sub(s, i + 1, 1) == " "
                || string_sub(s, it_close - 1, 1) == " ") {
                inline_loop(s, i + 1, acc ++ "*")
            } else {
                it_inner = string_sub(s, i + 1, it_close - (i + 1))
                inline_loop(s, it_close + 1, acc ++ "\e[3m" ++ it_inner ++ UI.reset())
            }
        } else { if (peek1(s, i) == "_") {
            # _italic_ — flanking PLUS not-mid-word (so my_var_name stays
            # literal).
            us_close = find_close(s, i + 1, "_")
            if (us_close < 0 || us_close == i + 1
                || string_sub(s, i + 1, 1) == " "
                || string_sub(s, us_close - 1, 1) == " "
                || is_word_char(char_before(s, i)) == 'true'
                || is_word_char(peek1(s, us_close + 1)) == 'true') {
                inline_loop(s, i + 1, acc ++ "_")
            } else {
                us_inner = string_sub(s, i + 1, us_close - (i + 1))
                inline_loop(s, us_close + 1, acc ++ "\e[3m" ++ us_inner ++ UI.reset())
            }
        } else {
            ch = string_sub(s, i, 1)
            inline_loop(s, i + 1, acc ++ ch)
        }}}}}}}}
    }
}

# Render a [label](url) link. When colors are on, use an OSC-8 hyperlink
# so the terminal makes `label` clickable; when off, fall back to the
# plain "label (url)" form so the URL is still visible.
fun render_link(label, url) {
    if (UI.colors_off() == 'true') {
        render_inline(label) ++ " (" ++ url ++ ")"
    } else {
        "\e]8;;" ++ url ++ "\e\\" ++ render_inline(label) ++ "\e]8;;\e\\"
    }
}

# Chars a backslash may escape into a literal (the markdown-active
# punctuation set).
fun is_escapable(ch) {
    if (ch == "\\" || ch == "`" || ch == "*" || ch == "_" || ch == "~"
        || ch == "[" || ch == "]" || ch == "(" || ch == ")" || ch == "#"
        || ch == "+" || ch == "-" || ch == "." || ch == "!" || ch == "|"
        || ch == ">" || ch == "<" || ch == "{" || ch == "}") { 'true' }
    else { 'false' }
}

fun is_word_char(ch) {
    if (string_length(ch) == 0) { 'false' }
    else { if ((ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")
            || (ch >= "0" && ch <= "9")) { 'true' } else { 'false' }}
}

fun char_before(s, i) {
    if (i <= 0) { "" } else { string_sub(s, i - 1, 1) }
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

# Display width of a string in terminal COLUMNS. Escape sequences count
# zero; UTF-8 is decoded so wide CJK and emoji codepoints count 2. Byte
# values come from codepoint_at (byte-indexed by design). States:
#   'norm'     normal text
#   'csi'      inside a CSI seq (ESC [ … final 0x40-0x7E) — zero width
#   'osc'      inside an OSC seq (ESC ] … BEL or ST) — e.g. OSC-8 links
#   'osc_esc'  saw ESC inside OSC — consume the ST's trailing "\"
fun display_width(s) {
    dw_loop(s, 0, string_length(s), 0, 'norm')
}

fun dw_loop(s, i, slen, count, st) {
    if (i >= slen) { count }
    else {
        b = codepoint_at(s, i)
        if (st == 'csi') {
            if (b >= 64 && b <= 126) { dw_loop(s, i + 1, slen, count, 'norm') }
            else { dw_loop(s, i + 1, slen, count, 'csi') }
        } else { if (st == 'osc') {
            if (b == 7) { dw_loop(s, i + 1, slen, count, 'norm') }
            else { if (b == 27) { dw_loop(s, i + 1, slen, count, 'osc_esc') }
            else { dw_loop(s, i + 1, slen, count, 'osc') }}
        } else { if (st == 'osc_esc') {
            dw_loop(s, i + 1, slen, count, 'norm')
        } else {
            if (b == 27) {
                nb = codepoint_at(s, i + 1)
                if (nb == 91) { dw_loop(s, i + 2, slen, count, 'csi') }
                else { if (nb == 93) { dw_loop(s, i + 2, slen, count, 'osc') }
                else { dw_loop(s, i + 1, slen, count, 'csi') }}
            } else {
                seq = utf8_seq_len(b)
                dw_loop(s, i + seq, slen, count + cp_width(utf8_decode(s, i, b, seq)), 'norm')
            }
        }}}
    }
}

# UTF-8 lead-byte → sequence length (1-4). A stray continuation byte
# resyncs as width 1.
fun utf8_seq_len(b) {
    if (b < 128) { 1 }
    else { if (b >= 240) { 4 }
    else { if (b >= 224) { 3 }
    else { if (b >= 192) { 2 }
    else { 1 }}}}
}

# Decode the codepoint value of the UTF-8 sequence starting at byte i.
fun utf8_decode(s, i, b, seq) {
    if (seq == 1) { b }
    else { if (seq == 2) {
        (b - 192) * 64 + cont_byte(s, i + 1)
    } else { if (seq == 3) {
        (b - 224) * 4096 + cont_byte(s, i + 1) * 64 + cont_byte(s, i + 2)
    } else {
        (b - 240) * 262144 + cont_byte(s, i + 1) * 4096
            + cont_byte(s, i + 2) * 64 + cont_byte(s, i + 3)
    }}}
}

fun cont_byte(s, i) {
    v = codepoint_at(s, i)
    if (v < 0) { 0 } else { v - 128 }
}

# Codepoint value at the START of a (typically single-codepoint) string.
fun first_cp(cs) {
    b = codepoint_at(cs, 0)
    if (b < 0) { 0 } else { utf8_decode(cs, 0, b, utf8_seq_len(b)) }
}

# Terminal column width of a codepoint: 2 for CJK/fullwidth + emoji, else 1.
fun cp_width(cp) {
    if (cp_is_wide(cp) == 'true') { 2 } else { 1 }
}

fun cp_is_wide(cp) {
    if (cp >= 4352 && cp <= 4447) { 'true' }            # Hangul Jamo 1100-115F
    else { if (cp >= 11904 && cp <= 42191) { 'true' }   # CJK/Kana/… 2E80-A4CF
    else { if (cp >= 44032 && cp <= 55203) { 'true' }   # Hangul syllables AC00-D7A3
    else { if (cp >= 63744 && cp <= 64255) { 'true' }   # CJK compat F900-FAFF
    else { if (cp >= 65072 && cp <= 65103) { 'true' }   # CJK compat forms FE30-FE4F
    else { if (cp >= 65280 && cp <= 65376) { 'true' }   # Fullwidth forms FF00-FF60
    else { if (cp >= 65504 && cp <= 65510) { 'true' }   # Fullwidth signs FFE0-FFE6
    else { if (cp >= 131072) { 'true' }                 # SIP+ >= 20000
    else { if (cp >= 127744 && cp <= 129791) { 'true' } # emoji 1F300-1FAFF
    else { if (cp >= 9728 && cp <= 10175) { 'true' }    # misc symbols 2600-27BF
    else { 'false' }}}}}}}}}}
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
    else { if (string_contains(s, "\n+ ") == 'true') { 'true' }
    else { if (string_starts_with(s, "+ ") == 'true') { 'true' }
    else { if (string_contains(s, "\n> ") == 'true') { 'true' }
    else { if (string_contains(s, "\n|") == 'true') { 'true' }
    else { if (string_starts_with(s, "|") == 'true') { 'true' }
    else { if (string_contains(s, "](") == 'true') { 'true' }
    else { if (has_ordered_item(s) == 'true') { 'true' }
    else { 'false' }}}}}}}}}}}}}}
}

# True when any line is an ordered-list item ("1. x" / "2) y"). These
# were invisible to the old heuristic, so numbered-list replies never
# got the render pass at all.
fun has_ordered_item(s) {
    any_ordered(string_split(s, "\n"))
}

fun any_ordered(lines) {
    if (length(lines) == 0) { 'false' }
    else {
        if (is_ordered(hd(lines)) == 'true') { 'true' }
        else { any_ordered(tl(lines)) }
    }
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

# ============================================================
# Wave-1B — incremental block streaming (docs/TUI_UX_REVIEW_2026-07-06.md)
# ============================================================
# stream_feed(tbl, chunk) / stream_flush(tbl): ETS-backed incremental
# markdown renderer for the worker-routed LLM stream (llm.sw
# routed_collect). Instead of painting raw tokens and repainting the
# whole response afterwards, the stream buffers per BLOCK and each
# block renders exactly once — through the same Markdown.render as the
# final view, ALWAYS (no has_markdown gate: streamed output must look
# identical to a full render, plain prose included).
#
# Block boundaries are detected ON FEED, over COMPLETE lines only — a
# partial line stays pending until its newline arrives, so a fence
# marker or heading split mid-chunk can never misfire:
#   · blank line outside a fence → close the pending block
#   · fence toggle-CLOSE (``` and ~~~; the closing marker must match
#     the opener, so a ``` line inside a ~~~ fence stays content)
#   · heading line start → close the pending block; the heading line
#     itself completes immediately (it's a one-line block)
# Fence OPEN is NOT a boundary: prose directly above a fence rides
# along and renders with it, exactly as a full-document render joins
# them.
#
# Return value: the rendered text for the caller to print (the caller
# owns the terminal), or nil when no block completed. Segments after
# the first carry a leading "\n" so consecutive prints reproduce the
# one blank line join_blocks puts between blocks at these boundaries.
#
# ETS keys on the session stream_state_table — md_-prefixed to stay
# clear of ui.sw's agent-block keys ('block'/'sline') and the ticker
# counters ('stream_tok'/'stream_think'/'ticker_pid'):
#   'md_buf'      complete lines of the in-flight block ("\n"-joined)
#   'md_tail'     partial line still waiting for its newline
#   'md_fence'    'true' while inside a fence
#   'md_fence_mk' "```" | "~~~" — the marker that opened the fence
#   'md_emitted'  'true' once any segment was returned this stream
# stream_flush renders the remainder (walk_blocks closes unterminated
# fences at EOF) and RESETS every key — llm.sw calls it on each exit
# path of the receive loop, so the table is always clean for the next
# call.
# ------------------------------------------------------------
fun stream_feed(tbl, chunk) {
    if (tbl == nil) { nil }
    else {
        data = sf_tail(tbl) ++ to_string(chunk)
        parts = string_split(data, "\n")
        sf_walk(tbl, parts, sf_buf(tbl), sf_fence(tbl), sf_mk(tbl), sf_pblank(tbl), nil)
    }
}

fun stream_flush(tbl) {
    if (tbl == nil) { nil }
    else {
        buf = sf_buf(tbl)
        tail = sf_tail(tbl)
        full = if (string_length(tail) == 0) { buf } else { sf_append(buf, tail) }
        was = ets_get(tbl, 'md_emitted')
        ets_put(tbl, 'md_buf', "")
        ets_put(tbl, 'md_tail', "")
        ets_put(tbl, 'md_fence', 'false')
        ets_put(tbl, 'md_fence_mk', nil)
        ets_put(tbl, 'md_emitted', nil)
        ets_put(tbl, 'md_prev_blank', nil)
        if (string_length(string_trim(full)) == 0) { nil }
        else {
            rendered = render(full, UI.term_width())
            if (string_length(rendered) == 0) { nil }
            else { if (was == 'true') { "\n" ++ rendered } else { rendered } }
        }
    }
}

# Line walker over the split parts. The LAST element is the text after
# the final "\n" (possibly "") — that's the new pending tail, never
# classified. Self-tail-recursive only (swarmrt TCO's nothing else).
fun sf_walk(tbl, parts, buf, fence, mk, pblank, out) {
    if (length(parts) <= 1) {
        tail = if (length(parts) == 0) { "" } else { hd(parts) }
        ets_put(tbl, 'md_tail', tail)
        ets_put(tbl, 'md_buf', buf)
        ets_put(tbl, 'md_fence', fence)
        ets_put(tbl, 'md_fence_mk', mk)
        ets_put(tbl, 'md_prev_blank', pblank)
        out
    } else {
        line = hd(parts)
        rest = tl(parts)
        if (fence == 'true') {
            nbuf = sf_append(buf, line)
            if (sf_fence_closes(line, mk) == 'true') {
                # Toggle-close — the completed block includes the fence.
                sf_walk(tbl, rest, "", 'false', nil, 'false', sf_emit(tbl, nbuf, out))
            } else {
                sf_walk(tbl, rest, nbuf, 'true', mk, 'false', out)
            }
        } else {
            fm = sf_fence_marker(line)
            if (fm != nil) {
                # Fence OPEN — not a boundary; the fence joins the
                # pending block and closes it later.
                sf_walk(tbl, rest, sf_append(buf, line), 'true', fm, 'false', out)
            } else { if (is_blank(line) == 'true') {
                # The FIRST blank after content is the block separator the
                # emit convention already reproduces (it closes the pending
                # block, or follows a self-closed fence/heading). Every
                # ADDITIONAL blank in a run is a real row in the batch
                # render, so the stream emits one empty segment for it.
                out_b = if (string_length(string_trim(buf)) > 0) {
                    sf_emit(tbl, buf, out)
                } else { if (pblank == 'true') {
                    sf_blank_extra(tbl, out)
                } else { out }}
                sf_walk(tbl, rest, "", 'false', nil, 'true', out_b)
            } else { if (header_depth(line) > 0) {
                # Heading start closes the pending block; the heading
                # itself is complete the moment its newline arrived.
                out2 = sf_emit(tbl, buf, out)
                sf_walk(tbl, rest, "", 'false', nil, 'false', sf_emit(tbl, line, out2))
            } else {
                sf_walk(tbl, rest, sf_append(buf, line), 'false', nil, 'false', out)
            }}}
        }
    }
}

# Render one completed block and append it to the outgoing segment
# accumulator. Whitespace-only blocks (e.g. consecutive blank lines)
# contribute nothing. Segments after the first get a leading "\n" —
# printed after the previous segment's trailing newline that makes
# exactly one blank separator line, matching join_blocks' "\n\n".
fun sf_emit(tbl, text, out) {
    if (string_length(string_trim(text)) == 0) { out }
    else {
        rendered = render(text, UI.term_width())
        if (string_length(rendered) == 0) { out }
        else {
            was = ets_get(tbl, 'md_emitted')
            ets_put(tbl, 'md_emitted', 'true')
            piece = if (was == 'true') { "\n" ++ rendered } else { rendered }
            if (out == nil) { piece } else { out ++ "\n" ++ piece }
        }
    }
}

fun sf_append(buf, line) {
    if (string_length(buf) == 0) { line } else { buf ++ "\n" ++ line }
}

# One extra blank line inside a RUN of blanks (the first blank of the
# run already closed the block and yields the standard one-blank
# separator). Contributes exactly one empty segment → one blank row
# when printed, matching join_blocks' per-'blank'-block "\n". Leading
# blanks (nothing emitted yet) are dropped, as the batch joiner does.
fun sf_blank_extra(tbl, out) {
    was = ets_get(tbl, 'md_emitted')
    if (was != 'true') { out }
    else { if (out == nil) { "" } else { out ++ "\n" } }
}

# The full fence-marker RUN of a line: "```..." → "```" + any further
# backticks ("````" for a 4-tick fence), "~~~~~..." → the ~ run;
# anything else → nil. The run LENGTH matters: CommonMark requires a
# closing fence at least as long as its opener, so ``` inside a
# ````-quoted example must stay content.
fun sf_fence_marker(line) {
    t = string_trim(line)
    if (string_length(t) < 3) { nil }
    else { if (string_sub(t, 0, 3) == "```") { "```" ++ sf_fence_run(t, 3, "`") }
    else { if (string_sub(t, 0, 3) == "~~~") { "~~~" ++ sf_fence_run(t, 3, "~") }
    else { nil }}}
}

fun sf_fence_run(t, i, ch) {
    if (i >= string_length(t)) { "" }
    else { if (string_sub(t, i, 1) == ch) { ch ++ sf_fence_run(t, i + 1, ch) }
    else { "" }}
}

# Does `line` CLOSE a fence opened by marker `mk`? Same fence char,
# run at least as long as the opener, and nothing but the marker on
# the line (a closer carries no info string — "```python" inside a
# fence is content, per CommonMark).
fun sf_fence_closes(line, mk) {
    if (mk == nil) { 'false' }
    else {
        fm = sf_fence_marker(line)
        if (fm == nil) { 'false' }
        else {
            mks = to_string(mk)
            if (string_sub(fm, 0, 1) != string_sub(mks, 0, 1)) { 'false' }
            else { if (string_length(fm) < string_length(mks)) { 'false' }
            else { if (string_trim(line) == fm) { 'true' }
            else { 'false' }}}
        }
    }
}

# nil-tolerant state readers — a fresh table needs no priming.
fun sf_buf(tbl) {
    v = ets_get(tbl, 'md_buf')
    if (v == nil) { "" } else { to_string(v) }
}

fun sf_tail(tbl) {
    v = ets_get(tbl, 'md_tail')
    if (v == nil) { "" } else { to_string(v) }
}

fun sf_fence(tbl) {
    v = ets_get(tbl, 'md_fence')
    if (v == 'true') { 'true' } else { 'false' }
}

fun sf_mk(tbl) {
    ets_get(tbl, 'md_fence_mk')
}

fun sf_pblank(tbl) {
    v = ets_get(tbl, 'md_prev_blank')
    if (v == 'true') { 'true' } else { 'false' }
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
