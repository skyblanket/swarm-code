module Util

# ============================================================
# Util — tiny helpers shared across the codebase
# ============================================================
# Single-source replacements for the same helper that used to be
# copy-pasted into 8 modules (Background, Skills, Scheduler,
# SessionSearch, Vision and three differently-named twins in
# Agent/Config/Tools). Keeping these here means a bug fix lands
# once, not 8 times.

export [shell_q, noninteractive_wrap, no_stdin]

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
