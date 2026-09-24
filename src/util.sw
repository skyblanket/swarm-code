module Util

# ============================================================
# Util — tiny helpers shared across the codebase
# ============================================================
# Single-source replacements for the same helper that used to be
# copy-pasted into 8 modules (Background, Skills, Scheduler,
# SessionSearch, Vision and three differently-named twins in
# Agent/Config/Tools). Keeping these here means a bug fix lands
# once, not 8 times.

export [shell_q, noninteractive_wrap, no_stdin, join_all, json_args_well_formed]

# POSIX-safe single-quote wrap. Replaces `'` with `'\''` (close,
# escape, reopen) so the result is always safe to splice into a
# shell command line.
fun shell_q(s) {
    "'" ++ string_replace(s, "'", "'\\''") ++ "'"
}

# ------------------------------------------------------------
# Shell-script wrappers for commands built from MODEL input
# ------------------------------------------------------------
# The wrapped command is spliced in as its own LINES, never inline between
# parentheses: the old `( export …; CMD ) </dev/null 2>&1` form broke on any
# command ending in a `# comment` (it commented out the closing paren) or a
# heredoc (the terminator line became `EOF ) </dev/null…`), and sh's syntax
# error went to the agent's stderr, not the model. Here the redirections are
# an `exec` on line 1, which sh runs BEFORE it parses the user's lines — so a
# syntax error in them lands in the captured output. The script ends with a
# newline so whatever a caller appends starts on a fresh line.
#
# noninteractive_wrap: stdin from /dev/null (no tool can read a tty or our
# own stdin — the MCP server's JSON-RPC pipe), stderr folded into stdout, and
# the CI=1 family exported so scaffolders (npm create, cargo new, apt) skip
# their interactive prompts. Used by bash, background, bg_server, run_tests.
fun noninteractive_wrap(user_cmd) {
    "exec </dev/null 2>&1; export CI=1 DEBIAN_FRONTEND=noninteractive NO_COLOR=1 FORCE_COLOR=0 " ++
    "NPM_CONFIG_YES=true PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONUNBUFFERED=1\n" ++
    to_string(user_cmd) ++ "\n"
}

# no_stdin: for the harness's OWN helper pipelines (grep/glob/git/probes).
# shell_managed children inherit swarm-code's stdin — a tool that reads stdin
# by accident (rg with no path) would block on the terminal or swallow the
# MCP server's next request. stderr is left alone: each caller decides.
fun no_stdin(cmd) {
    "exec </dev/null\n" ++ to_string(cmd) ++ "\n"
}

# Concatenate a list of strings. `acc ++ s` in a loop re-copies the growing
# accumulator (quadratic on a 2000-line read); joining halves recursively is
# O(n log n) and the recursion is only log2(n) deep.
fun join_all(parts) {
    join_n(parts, length(parts))
}

fun join_n(parts, n) {
    if (n <= 16) { join_lin(parts, n, "") }
    else {
        h = n / 2
        join_n(take_n(parts, h, []), h) ++ join_n(drop_n(parts, h), n - h)
    }
}

fun join_lin(parts, n, acc) {
    if (n <= 0 || length(parts) == 0) { acc } else { join_lin(tl(parts), n - 1, acc ++ hd(parts)) }
}

fun take_n(lst, n, acc) {
    if (n <= 0 || length(lst) == 0) { acc } else { take_n(tl(lst), n - 1, list_append(acc, hd(lst))) }
}

fun drop_n(lst, n) {
    if (n <= 0 || length(lst) == 0) { lst } else { drop_n(tl(lst), n - 1) }
}

# ------------------------------------------------------------
# Strict structural check for a tool call's JSON arguments.
# ------------------------------------------------------------
# Older swarmrt builds' json_decode is LENIENT: `{"command":"echo hi` decodes to
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
