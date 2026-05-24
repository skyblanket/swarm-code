module Util

# ============================================================
# Util — tiny helpers shared across the codebase
# ============================================================
# Single-source replacements for the same helper that used to be
# copy-pasted into 8 modules (Background, Skills, Scheduler,
# SessionSearch, Vision and three differently-named twins in
# Agent/Config/Tools). Keeping these here means a bug fix lands
# once, not 8 times.

export [shell_q]

# POSIX-safe single-quote wrap. Replaces `'` with `'\''` (close,
# escape, reopen) so the result is always safe to splice into a
# shell command line.
fun shell_q(s) {
    "'" ++ string_replace(s, "'", "'\\''") ++ "'"
}
