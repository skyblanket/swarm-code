module Util

# ============================================================
# Util — tiny helpers shared across the codebase
# ============================================================
# Single-source replacements for the same helper that used to be
# copy-pasted into 8 modules (Background, Skills, Scheduler,
# SessionSearch, Vision and three differently-named twins in
# Agent/Config/Tools). Keeping these here means a bug fix lands
# once, not 8 times.

export [shell_q, json_args_well_formed]

# POSIX-safe single-quote wrap. Replaces `'` with `'\''` (close,
# escape, reopen) so the result is always safe to splice into a
# shell command line.
fun shell_q(s) {
    "'" ++ string_replace(s, "'", "'\\''") ++ "'"
}

# ------------------------------------------------------------
# Strict structural check for a tool call's JSON arguments.
# ------------------------------------------------------------
# The runtime's json_decode is LENIENT: `{"command":"echo hi` decodes to
# %{command: "echo hi"}, so a tool call whose arguments were cut off
# mid-string (output-token limit, ESC, a dropped stream) looks like a
# perfectly good call and gets executed with the truncated value. This is
# the check json_decode doesn't do: 'true' only when `s` is ONE complete
# JSON object or array — braces/brackets balanced and matched outside
# strings, every string terminated, nothing but whitespace after the
# top-level value. It checks structure, not every token (a truncation
# always shows up as an unclosed string or container at the end).
#
# Splits on `"` (a C-level builtin) instead of walking bytes: a per-byte
# string_sub walk costs ~2µs/byte, i.e. ~0.5s for a 200KB `write`. The
# pieces alternate outside/inside strings; a quote whose preceding piece
# ends in an odd run of backslashes is escaped and doesn't toggle. Only
# the (tiny) outside-string pieces are walked byte by byte — structural
# characters are ASCII, so byte offsets are safe inside UTF-8 text.
fun json_args_well_formed(s) {
    parts = string_split(to_string(s), "\"")
    if (length(parts) == 0) { 'false' }
    else { jwf_parts(parts, 'false', "", 'false', 'false') }
}

# in_str: the current piece is string content. stack: open containers
# ("{"/"[") as a string, innermost last. started/done: the top-level
# container was opened / has been closed.
fun jwf_parts(parts, in_str, stack, started, done) {
    p = hd(parts)
    more = if (length(tl(parts)) > 0) { 'true' } else { 'false' }
    if (in_str == 'true') {
        # String content with no closing quote after it: unterminated.
        if (more == 'false') { 'false' }
        else {
            escaped = if (trailing_backslashes(p, string_length(p) - 1, 0) % 2 == 1) { 'true' } else { 'false' }
            jwf_parts(tl(parts), escaped, stack, started, done)
        }
    } else {
        r = jwf_scan(p, 0, string_length(p), stack, started, done)
        if (r == 'bad') { 'false' }
        else {
            st = elem(r, 0)
            sd = elem(r, 1)
            dn = elem(r, 2)
            if (more == 'false') { dn }
            else {
                # A quote follows: it may only open a string INSIDE the
                # top-level container.
                if (sd == 'true' && dn == 'false') { jwf_parts(tl(parts), 'true', st, sd, dn) }
                else { 'false' }
            }
        }
    }
}

fun trailing_backslashes(p, i, acc) {
    if (i < 0) { acc }
    else { if (string_sub(p, i, 1) == "\\") { trailing_backslashes(p, i - 1, acc + 1) }
    else { acc } }
}

# Walk one outside-string piece. Returns {stack, started, done} or 'bad'.
fun jwf_scan(p, i, n, stack, started, done) {
    if (i >= n) { {stack, started, done} }
    else {
        c = string_sub(p, i, 1)
        if (c == " " || c == "\n" || c == "\r" || c == "\t") {
            jwf_scan(p, i + 1, n, stack, started, done)
        } else { if (done == 'true') { 'bad' }
        else { if (started == 'false') {
            if (c == "{" || c == "[") { jwf_scan(p, i + 1, n, c, 'true', 'false') }
            else { 'bad' }
        } else { if (c == "{" || c == "[") {
            jwf_scan(p, i + 1, n, stack ++ c, started, done)
        } else { if (c == "}" || c == "]") {
            sl = string_length(stack)
            want = if (c == "}") { "{" } else { "[" }
            if (sl == 0) { 'bad' }
            else { if (string_sub(stack, sl - 1, 1) != want) { 'bad' }
            else {
                closed = if (sl == 1) { 'true' } else { 'false' }
                jwf_scan(p, i + 1, n, string_sub(stack, 0, sl - 1), started, closed)
            }}
        } else {
            jwf_scan(p, i + 1, n, stack, started, done)
        }}}}}
    }
}
