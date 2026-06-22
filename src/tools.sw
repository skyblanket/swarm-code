module Tools

# ============================================================
# Tools — bash, read, write, edit, multi_edit, glob, grep,
#         todo_write, web_fetch, task
# ============================================================
#
# Each tool is dispatched by atom name. Arguments arrive as a
# parsed map (from json_decode on the arguments block of a
# <tool_call>). Each handler returns a string result that gets
# sent back to the model.
#
# Most tools wrap existing swarmrt builtins — shell(), file_read(),
# file_write(), string_replace(), http_get() — which keeps the .sw
# source tiny.
#
# Tools that need session state (todos, permissions, etc.) take an
# `opts` map as the third arg. For simple stateless tools the opts
# argument is ignored.

import Memory
import Skills
import SessionSearch
import Vision
import Background
import Heartbeat
import Telemetry
import Browser
import Mcp
import Util
import TestRunner
import PathGuard

export [exec_raw, max_output_bytes]

# Keep tool output well under the 32K context so even a long history +
# a big bash stdout doesn't push the KV cache over. 6 KB ≈ ~1500 tokens.
fun max_output_bytes() { 6000 }

# Raw handler dispatch. Permission, context, guardrail, and hook policy
# lives in ToolExecutor; callers outside tests should use that boundary.
fun exec_raw(name, args, opts) {
    if (string_starts_with(to_string(name), "mcp__") == 'true') {
        truncate_output(Mcp.call_tool(to_string(name), args, opts), max_output_bytes())
    } else {
        handler = find_handler(all_tools(), name)
        if (handler == nil) {
            "error: unknown tool '" ++ to_string(name) ++ "'"
        } else {
            handler(args, opts)
        }
    }
}

fun find_handler(entries, name) {
    if (length(entries) == 0) { nil }
    else {
        e = hd(entries)
        if (map_get(e, 'atom') == name) { map_get(e, 'handler') }
        else { find_handler(tl(entries), name) }
    }
}

# ============================================================
# Tool registry — single source of truth for handler dispatch.
#
# Each entry: %{atom, handler}. Handler is a lambda normalised to
# (args, opts) — wrappers ignore opts for arity-1 do_* fns.
#
# This is what used to be a 50-case if/else in exec(). New tools:
# add ONE entry below and an entry in ToolRegistry.all_tools() —
# atom dispatch is now data, not control flow.
# ============================================================
fun all_tools() {
    [
        %{atom: 'bash',               handler: fun(args, opts) { do_bash(args) }},
        %{atom: 'read',               handler: fun(args, opts) { do_read(args) }},
        %{atom: 'write',              handler: fun(args, opts) { do_write(args) }},
        %{atom: 'edit',               handler: fun(args, opts) { do_edit(args) }},
        %{atom: 'multi_edit',         handler: fun(args, opts) { do_multi_edit(args) }},
        %{atom: 'glob',               handler: fun(args, opts) { do_glob(args) }},
        %{atom: 'grep',               handler: fun(args, opts) { do_grep(args) }},
        %{atom: 'todo_write',         handler: fun(args, opts) { do_todo_write(args, opts) }},
        %{atom: 'web_fetch',          handler: fun(args, opts) { do_web_fetch(args, opts) }},
        %{atom: 'web_search',         handler: fun(args, opts) { do_web_search(args) }},
        %{atom: 'remember',           handler: fun(args, opts) { do_remember(args, opts) }},
        %{atom: 'recall',             handler: fun(args, opts) { do_recall(args, opts) }},
        %{atom: 'memory_list',        handler: fun(args, opts) { do_memory_list(args, opts) }},
        %{atom: 'forget',             handler: fun(args, opts) { do_forget(args, opts) }},
        %{atom: 'learn_skill',        handler: fun(args, opts) { do_learn_skill(args) }},
        %{atom: 'recall_skill',       handler: fun(args, opts) { do_recall_skill(args) }},
        %{atom: 'forget_skill',       handler: fun(args, opts) { do_forget_skill(args) }},
        %{atom: 'skill_list',         handler: fun(args, opts) { do_skill_list(args) }},
        %{atom: 'session_search',     handler: fun(args, opts) { do_session_search(args) }},
        %{atom: 'read_image',         handler: fun(args, opts) { do_read_image(args, opts) }},
        %{atom: 'background',         handler: fun(args, opts) { do_background(args, opts) }},
        %{atom: 'bg_status',          handler: fun(args, opts) { do_bg_status(args, opts) }},
        %{atom: 'bg_result',          handler: fun(args, opts) { do_bg_result(args, opts) }},
        %{atom: 'bg_server',          handler: fun(args, opts) { do_bg_server(args, opts) }},
        %{atom: 'bg_tail',            handler: fun(args, opts) { do_bg_tail(args, opts) }},
        %{atom: 'bg_kill',            handler: fun(args, opts) { do_bg_kill(args, opts) }},
        %{atom: 'sys_stats',          handler: fun(args, opts) { Telemetry.sys_stats() }},
        %{atom: 'heartbeat_status',   handler: fun(args, opts) { do_heartbeat_status(opts) }},
        %{atom: 'git_status',         handler: fun(args, opts) { do_git_status(args) }},
        %{atom: 'git_diff',           handler: fun(args, opts) { do_git_diff(args) }},
        %{atom: 'git_commit',         handler: fun(args, opts) { do_git_commit(args) }},
        %{atom: 'run_tests',          handler: fun(args, opts) { do_run_tests(args) }},
        %{atom: 'code_search',        handler: fun(args, opts) { do_code_search(args) }},
        %{atom: 'sw_check',           handler: fun(args, opts) { do_sw_check(args) }},
        %{atom: 'log_wait',           handler: fun(args, opts) { do_log_wait(args, opts) }},
        %{atom: 'file_watch',         handler: fun(args, opts) { do_file_watch(args) }},
        %{atom: 'browser_launch',     handler: fun(args, opts) { do_browser_launch(args, opts) }},
        %{atom: 'browser_navigate',   handler: fun(args, opts) { do_browser_navigate(args, opts) }},
        %{atom: 'browser_click',      handler: fun(args, opts) { do_browser_click(args, opts) }},
        %{atom: 'browser_type',       handler: fun(args, opts) { do_browser_type(args, opts) }},
        %{atom: 'browser_screenshot', handler: fun(args, opts) { do_browser_screenshot(args, opts) }},
        %{atom: 'browser_get_text',   handler: fun(args, opts) { do_browser_get_text(args, opts) }},
        %{atom: 'browser_get_html',   handler: fun(args, opts) { do_browser_get_html(args, opts) }},
        %{atom: 'browser_evaluate',   handler: fun(args, opts) { do_browser_evaluate(args, opts) }},
        %{atom: 'browser_close',      handler: fun(args, opts) { do_browser_close(args, opts) }},
        %{atom: 'browser_console',    handler: fun(args, opts) { do_browser_console(args, opts) }}
    ]
}

# ------------------------------------------------------------
# Timeout infrastructure
# ------------------------------------------------------------
# Every tool that shells out runs through `shell_managed(cmd, ms)` (a swarmrt
# builtin): it runs the command in its OWN process group, enforces the timeout
# in C, and on timeout/ESC kills the WHOLE process group (TERM→KILL) — so a hung
# command (tail -f, stuck DNS, unresponsive git remote, or a leaked grandchild)
# can never pin the agent. The old perl-`alarm` `with_timeout` wrapper was
# removed: it only SIGALRM'd the direct child (leaking grandchildren) and left
# swarmrt's shell() polling for an exit file that never arrived → a multi-minute
# wedge. These constants supply the per-tool budgets in SECONDS; callers pass
# `* 1000` to shell_managed. Timeouts mirror Claude Code:
#   bash:       120s default, 600s max, overridable via timeout_ms arg
#   git/search: 30s · web_fetch: 45s · read-probes: 5s
# ------------------------------------------------------------
fun bash_default_timeout_s() { 120 }
fun bash_max_timeout_s() { 600 }
fun search_timeout_s() { 30 }
fun git_timeout_s() { 30 }
fun fetch_timeout_s() { 45 }

# Extract a host label from a URL for the web_fetch pre-flight line.
# "https://github.com/a/b?x=1" → "github.com". Falls back to "web_fetch"
# when the URL is empty or yields no host. Pure string ops, no parsing libs.
fun fetch_host_label(url) {
    s = to_string(url)
    after_scheme = if (string_contains(s, "://") == 'true') {
        elem_or(string_split(s, "://"), 1, s)
    } else { s }
    host_and_more = elem_or(string_split(after_scheme, "/"), 0, after_scheme)
    # Drop any userinfo (user:pass@host) and trailing port.
    host = if (string_contains(host_and_more, "@") == 'true') {
        elem_or(string_split(host_and_more, "@"), 1, host_and_more)
    } else { host_and_more }
    bare = elem_or(string_split(host, ":"), 0, host)
    if (string_length(bare) == 0) { "web_fetch" } else { bare }
}

# Safe 0-indexed list access with a fallback when out of range.
fun elem_or(xs, i, fallback) {
    if (length(xs) == 0) { fallback }
    else { if (i <= 0) { hd(xs) }
    else { elem_or(tl(xs), i - 1, fallback) } }
}
fun read_probe_timeout_s() { 5 }

# Prefix that makes git non-interactive: never prompt for credentials,
# make any askpass call fail-fast (empty), and force ssh batch mode so a
# host-key/passphrase prompt errors out instead of blocking on a dead tty.
# Uses `export ...;` (NOT a leading `VAR=val cmd` assignment list) so the
# vars persist across the WHOLE `sh -c` — every git in an `&&` chain
# (add && commit && rev-parse), not just the first command.
fun git_noninteractive_env() {
    "export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true GIT_SSH_COMMAND='ssh -oBatchMode=yes'; "
}

# Format a result from shell_managed (a {code, output, interrupted} 3-tuple).
# When interrupted == 'true' the whole process GROUP was SIGKILLed — either
# by the wall-clock timeout (exit 124) or a user ESC/Ctrl-C (exit 130) — so
# any partial output is all we have. We distinguish the two so the model
# knows whether to retry with a bigger budget or to stop entirely.
fun format_managed_result(code, out, seconds, interrupted) {
    if (interrupted == 'true') {
        banner = if (code == 130) {
            "[stopped by user (ESC/Ctrl-C) — process group killed]\n"
        } else {
            "[timed out after " ++ to_string(seconds) ++ "s — process group killed]\n"
        }
        banner ++
        "(partial output below; the whole process tree was terminated. Retry with\n" ++
        " a larger timeout_ms, a tighter command, or run long jobs in the background.)\n\n" ++
        out
    } else {
        "[exit " ++ to_string(code) ++ "]\n" ++ out
    }
}

# Clamp a millisecond timeout into [1000, bash_max_timeout_s() * 1000]
# and convert to seconds. Handles the model passing nil, a string, or
# a silly number. Returns a positive integer seconds count.
fun resolve_bash_timeout_s(timeout_ms_raw) {
    if (timeout_ms_raw == nil) { bash_default_timeout_s() }
    else {
        ms = to_string(timeout_ms_raw)
        parsed = parse_int_safe(ms, bash_default_timeout_s() * 1000)
        max_ms = bash_max_timeout_s() * 1000
        clamped = if (parsed <= 0) { bash_default_timeout_s() * 1000 }
                  else { if (parsed > max_ms) { max_ms } else { parsed } }
        # Floor division to seconds, minimum 1s.
        s = clamped / 1000
        if (s < 1) { 1 } else { s }
    }
}

fun parse_int_safe(s, fallback) {
    parse_int_safe_loop(s, 0, 0, fallback, 'false')
}

fun parse_int_safe_loop(s, i, acc, fallback, saw_digit) {
    if (i >= string_length(s)) {
        if (saw_digit == 'true') { acc } else { fallback }
    } else {
        ch = string_sub(s, i, 1)
        d = digit_of(ch)
        if (d < 0) {
            if (saw_digit == 'true') { acc } else { fallback }
        } else {
            parse_int_safe_loop(s, i + 1, acc * 10 + d, fallback, 'true')
        }
    }
}

fun digit_of(ch) {
    if (ch == "0") { 0 } else { if (ch == "1") { 1 }
    else { if (ch == "2") { 2 } else { if (ch == "3") { 3 }
    else { if (ch == "4") { 4 } else { if (ch == "5") { 5 }
    else { if (ch == "6") { 6 } else { if (ch == "7") { 7 }
    else { if (ch == "8") { 8 } else { if (ch == "9") { 9 }
    else { 0 - 1 }}}}}}}}}}
}

# ------------------------------------------------------------
# bash
# ------------------------------------------------------------
# Output is capped at BOTH 100 lines and 6KB. Commands like `ls -R`
# on large trees produce 400+ short lines that fit under the byte
# cap but blow the model's effective context anyway. The truncation
# marker tells the model to use a tighter query next time.
#
# Accepts an optional `timeout_ms` (1000..600000, default 120000).
# Hanging commands are killed via SIGALRM and the model is told to
# retry with a larger budget.
#
# Non-interactive by default. Every command runs with:
#   * stdin redirected from /dev/null (no tool can read from a tty)
#   * CI=1, DEBIAN_FRONTEND=noninteractive, NO_COLOR=1 in env
# This prevents scaffolders like `npm create vite`, `cargo new`,
# `yarn create`, and apt from hanging on prompts that would never
# be answered. CI=1 also makes most tools skip interactive wizards.
fun do_bash(args) {
    cmd = map_get(args, 'command')
    timeout_raw = map_get(args, 'timeout_ms')
    if (cmd == nil) {
        "error: missing 'command' argument"
    } else {
        # Sudo guard — outright block unless explicitly enabled. The
        # model has no safe way to enter a sudo password, and the
        # ambient setuid escalation risk is too high to gate behind
        # only a prompt (which is_dangerous_bash already does).
        # Set SWARM_CODE_ALLOW_SUDO=1 to opt back in.
        cmd_s = to_string(cmd)
        sudo_allowed = getenv("SWARM_CODE_ALLOW_SUDO")
        if (string_contains(cmd_s, "sudo ") == 'true' && sudo_allowed != "1") {
            "error: sudo is disabled — set SWARM_CODE_ALLOW_SUDO=1 to enable (acknowledge that an agent running sudo is high-risk)"
        }
        else {
            t_s = resolve_bash_timeout_s(timeout_raw)
            user_cmd = cmd_s
            # Keep the non-interactive env + stdin</dev/null + 2>&1 hardening,
            # but hand the timeout AND the kill to shell_managed instead of the
            # perl alarm: the alarm only SIGALRMs the single exec'd process, so
            # node/python/server grandchildren leaked and kept running. shell_managed
            # runs the command in its own process group, enforces the timeout in C,
            # killpg's the WHOLE tree on timeout, and lets a user ESC stop a hung
            # command mid-run (the alarm could never be cut short).
            noninteractive = noninteractive_wrap(user_cmd)
            r = shell_managed(noninteractive, t_s * 1000)
            code = elem(r, 0)
            out = elem(r, 1)
            interrupted = elem(r, 2)
            line_capped = truncate_output_lines(out, bash_max_lines())
            byte_capped = truncate_output(line_capped, max_output_bytes())
            format_managed_result(code, byte_capped, t_s, interrupted)
        }
    }
}

# Wrap a user command in a subshell that:
#   - exports CI=1 and friends BEFORE the command runs (so every
#     child process, including npm/cargo/pip subcommands, sees them)
#   - redirects stdin from /dev/null (closes the tty ghost)
#   - merges stderr into stdout for capture
# Applied before the timeout wrapper so the alarm covers the whole
# pipeline including the `export` setup.
fun noninteractive_wrap(user_cmd) {
    "( export CI=1 DEBIAN_FRONTEND=noninteractive NO_COLOR=1 FORCE_COLOR=0 " ++
    "NPM_CONFIG_YES=true PIP_DISABLE_PIP_VERSION_CHECK=1 " ++
    "PYTHONUNBUFFERED=1; " ++
    user_cmd ++ " ) </dev/null 2>&1"
}

fun bash_max_lines() { 100 }

# ------------------------------------------------------------
# read
# ------------------------------------------------------------
fun do_read(args) {
    p = resolve_path_arg(args)
    # offset is 1-based line number to start at (Claude Code semantics).
    # limit is max lines to return. Both optional; defaults match CC.
    offset_raw = map_get(args, 'offset')
    limit_raw = map_get(args, 'limit')
    offset = if (offset_raw == nil) { 1 } else { to_int(offset_raw) }
    limit = if (limit_raw == nil) { 2000 } else { to_int(limit_raw) }
    if (p == nil) {
        "error: missing 'path' argument"
    } else {
        rguard = PathGuard.validate_read(to_string(p))
        if (rguard != "ok") { rguard }
        else {
            read_file_capped(p, offset, limit)
        }
    }
}

fun read_file_capped(path, offset, limit) {
    pq = Util.shell_q(to_string(path))
    # Regular-file guard FIRST. `test -f` is false for FIFOs, char/block
    # devices, sockets, and directories. Reading any of those (e.g. a named
    # pipe with no writer, or /dev/stdin) blocks FOREVER — `file`, `wc -c`,
    # and `head -c` would all hang, freezing the tool worker. Refuse before
    # touching the path. Every probe below is also timeout-guarded as a
    # backstop (a path on a dead NFS mount can hang even `test`).
    rf_r = shell_managed(
        "test -f " ++ pq ++ " && echo reg || echo nonreg 2>&1", read_probe_timeout_s() * 1000)
    rf = string_trim(elem(rf_r, 1))
    if (elem(rf_r, 2) == 'true') {
        # Probe was killed by timeout/ESC (e.g. a dead NFS mount) — say so
        # rather than misreporting the path as a non-regular file.
        "error: read of " ++ to_string(path) ++ " was interrupted (timeout or ESC) " ++
        "before the file could be classified — the path may be on an unresponsive filesystem."
    } else { if (rf != "reg") {
        "error: not a regular file — " ++ to_string(path) ++
        "\n(FIFOs, devices, sockets, and directories are refused to avoid a hang. " ++
        "Use bash with an explicit, bounded reader if you really need to.)"
    } else {
        # Check if file is binary before reading — binary content poisons the
        # model's context and causes empty responses.
        file_type = elem(shell_managed("file --brief --mime-type " ++ pq ++ " 2>&1", read_probe_timeout_s() * 1000), 1)
        is_text = string_starts_with(string_trim(file_type), "text") == 'true'
        is_json = string_contains(file_type, "json") == 'true'
        is_xml = string_contains(file_type, "xml") == 'true'
        if (is_text == 'true' || is_json == 'true' || is_xml == 'true') {
            # Size guard: file_read() pulls the WHOLE file into memory, so a
            # multi-GB file would OOM the VM before truncate_output ever runs.
            # Stat first; for anything large, read only a capped head via
            # `head -c` instead of slurping the whole thing.
            size_str = string_trim(elem(shell_managed("wc -c < " ++ pq ++ " 2>/dev/null", read_probe_timeout_s() * 1000), 1))
            size = parse_int_safe(size_str, 0)
            read_ceiling = max_output_bytes() * 8
            content = if (size > read_ceiling) {
                head = elem(shell_managed("head -c " ++ to_string(read_ceiling) ++ " " ++ pq ++ " 2>&1", read_probe_timeout_s() * 1000), 1)
                head ++ "\n...[file is " ++ size_str ++ " bytes — showing first " ++
                to_string(read_ceiling) ++ ". Use bash sed/grep for specific ranges.]"
            } else {
                file_read(path)
            }
            if (content == nil) {
                "error: could not read " ++ path
            } else {
                sliced = slice_lines(content, offset, limit)
                truncate_output(sliced, max_output_bytes())
            }
        } else {
            "error: binary file (" ++ string_trim(file_type) ++ ") — " ++ to_string(path) ++
            "\nUse bash with hexdump, xxd, strings, or file to inspect binary files."
        }
    } }
}

# Slice [offset, offset+limit) lines from content (1-based offset).
# When offset=1 and limit covers the whole file, returns content as-is
# so callers reading small files see no behavior change.
fun slice_lines(content, offset, limit) {
    if (offset <= 1 && limit >= 1000000) {
        content
    } else {
        lines = string_split(content, "\n")
        total = length(lines)
        start = if (offset < 1) { 0 } else { offset - 1 }
        if (start >= total) {
            ""
        } else {
            window = take_first_lines(drop_first_n(lines, start), limit, [])
            join_lines(window, "")
        }
    }
}

fun drop_first_n(lst, n) {
    if (n <= 0) { lst }
    else { if (length(lst) == 0) { lst }
    else { drop_first_n(tl(lst), n - 1) }}
}

fun to_int(v) {
    s = to_string(v)
    parse_int_safe(s, 0)
}

# Count non-overlapping occurrences of `sub` in `s`. Used by edit /
# multi_edit to enforce "old_string must be unique in the file" without
# the false-positive bug of post-replace inspection (which fires when
# new_string itself contains old_string, e.g. "foo" → "foobar").
fun count_substrings(s, sub) {
    if (string_length(sub) == 0) { 0 }
    else {
        parts = string_split(s, sub)
        length(parts) - 1
    }
}

# ------------------------------------------------------------
# write
# ------------------------------------------------------------
# Create all parent directories of a file path (like `mkdir -p $(dirname path)`).
# file_mkdir is single-level POSIX mkdir, so we walk the path and create each
# ancestor in turn (EEXIST is harmless). Without this the FIRST write into any
# new project dir fails — the model then has to mkdir+retry, burning a full turn.
fun ensure_parent_dirs(path) {
    mkdir_walk(to_string(path), 0, "")
}

fun mkdir_walk(p, i, acc) {
    if (i >= string_length(p)) { 'ok' }
    else {
        ch = string_sub(p, i, 1)
        if (ch == "/") {
            if (string_length(acc) > 0) { file_mkdir(acc) }
            mkdir_walk(p, i + 1, acc ++ "/")
        } else {
            mkdir_walk(p, i + 1, acc ++ ch)
        }
    }
}

fun do_write(args) {
    path = resolve_path_arg(args)
    content = map_get(args, 'content')
    if (path == nil) {
        "error: missing path"
    } else {
        if (content == nil) {
            "error: missing content"
        } else {
            guard = PathGuard.validate_write(to_string(path))
            if (guard != "ok") { guard }
            else {
                ensure_parent_dirs(to_string(path))
                rc = file_write(path, content)
                if (rc == 'ok') {
                    "ok: wrote " ++ to_string(string_length(content)) ++ " bytes to " ++ path
                } else {
                    "error: file_write failed for " ++ path
                }
            }
        }
    }
}

# ------------------------------------------------------------
# edit — exact string replacement (single occurrence required)
# ------------------------------------------------------------
fun do_edit(args) {
    path = resolve_path_arg(args)
    old_s = map_get(args, 'old_string')
    new_s = map_get(args, 'new_string')
    if (path == nil) { "error: missing path" }
    else {
        if (old_s == nil) { "error: missing old_string" }
        else {
            if (new_s == nil) { "error: missing new_string" }
            else { do_edit_impl(path, old_s, new_s) }
        }
    }
}

fun do_edit_impl(path, old_s, new_s) {
    guard = PathGuard.validate_write(to_string(path))
    if (guard != "ok") { guard }
    else { do_edit_impl_inner(path, old_s, new_s) }
}

fun do_edit_impl_inner(path, old_s, new_s) {
    original = file_read(path)
    if (original == nil) {
        # Missing file. Empty old_string = create it with new_string.
        if (string_length(old_s) == 0) {
            rc_c = file_write(path, new_s)
            if (rc_c == 'ok') {
                "ok: created " ++ path ++ " (" ++ to_string(string_length(new_s)) ++ " bytes)"
            } else { "error: could not create " ++ path }
        } else {
            "error: file " ++ path ++ " does not exist. Use write to create it, or call edit with old_string=\"\" to initialize it with new_string."
        }
    } else {
        if (string_length(original) == 0) {
            # Empty file. Empty old_string = initialize. Non-empty = can't match.
            if (string_length(old_s) == 0) {
                rc_i = file_write(path, new_s)
                if (rc_i == 'ok') {
                    "ok: initialized " ++ path ++ " (" ++ to_string(string_length(new_s)) ++ " bytes)"
                } else { "error: could not write " ++ path }
            } else {
                "error: file " ++ path ++ " is empty. Use write to replace it, or edit with old_string=\"\" to populate it."
            }
        } else {
            if (string_length(old_s) == 0) {
                # Empty old_string on non-empty file = append new_string
                rc_a = file_write(path, original ++ new_s)
                if (rc_a == 'ok') {
                    "ok: appended " ++ to_string(string_length(new_s)) ++ " bytes to " ++ path
                } else { "error: could not write " ++ path }
            } else {
                # Count occurrences in the ORIGINAL — checking the
                # post-replace buffer would falsely fire whenever
                # new_string contains old_string as a substring.
                occ = count_substrings(original, old_s)
                if (occ == 0) {
                    "error: old_string not found in " ++ path ++ ". Read the file first, then retry with an exact substring."
                } else { if (occ > 1) {
                    "error: old_string appears " ++ to_string(occ) ++ " times in " ++ path ++ " — add more context to make it unique"
                } else {
                    edited = string_replace(original, old_s, new_s)
                    rc_r = file_write(path, edited)
                    if (rc_r == 'ok') {
                        "ok: edited " ++ path
                    } else {
                        "error: could not write " ++ path
                    }
                }}
            }
        }
    }
}

# ------------------------------------------------------------
# glob — find files by pattern (shell-backed)
# ------------------------------------------------------------
fun do_glob(args) {
    pattern = map_get(args, 'pattern')
    path = map_get(args, 'path')
    if (pattern == nil) {
        "error: missing 'pattern'"
    } else {
        base = if (path == nil) { "." } else { to_string(path) }
        pat = to_string(pattern)
        pat_q = Util.shell_q(pat)
        # When base is ".", DON'T pass it to rg — `rg --files . ` emits
        # `./`-prefixed paths, and an anchored glob like `src/**/*.sw`
        # never matches `./src/...`. With no path arg rg emits clean
        # relative paths and anchored globs work.
        base_part = if (base == "." || string_length(string_trim(base)) == 0) {
            ""
        } else { " " ++ Util.shell_q(base) }
        base_q = Util.shell_q(base)
        # ripgrep `--files -g` gives real glob semantics, but rg is
        # often unavailable to a plain /bin/sh (e.g. when it's only a
        # shell function, not a real binary). So the `find` fallback
        # below MUST be correct on its own.
        #
        # Glob → find conversion:
        #   `**/`  collapses to nothing — find's `-path` treats `*` as
        #          matching across `/`, and `**` means "zero or more"
        #          dirs, so `src/**/*.sw` must also match `src/x.sw`.
        #          Replacing `**/`→`*/` would have forced ≥1 dir.
        #   `**`   (leftover, no slash) → `*`.
        #   slash present → `-path '*<pat>'` (whole-path match).
        #   no slash      → `-name '<pat>'` (basename, any depth).
        pat_nogs = string_replace(pat, "**/", "")
        pat_find = string_replace(pat_nogs, "**", "*")
        find_expr = if (string_contains(pat_find, "/") == 'true') {
            "-path " ++ Util.shell_q("*" ++ pat_find)
        } else {
            "-name " ++ Util.shell_q(pat_find)
        }
        # Pipe through `sed s|^\./||` to strip the `./` prefix `find`
        # adds when invoked with `.` — matches ripgrep's clean output
        # so downstream tools (Read) get the same path either way.
        cmd = "if command -v rg >/dev/null 2>&1; then " ++
              "rg --files --hidden --no-messages -g " ++ pat_q ++ base_part ++ "; " ++
              "else find " ++ base_q ++ " -type f " ++ find_expr ++ " 2>/dev/null | sed 's|^\\./||'; fi | head -n 100"
        result = shell_managed(cmd ++ " 2>&1", search_timeout_s() * 1000)
        code = elem(result, 0)
        out = elem(result, 1)
        interrupted = elem(result, 2)
        if (interrupted == 'true') {
            "[timed out after " ++ to_string(search_timeout_s()) ++ "s on " ++ base ++ " — narrow the path]"
        } else {
            if (string_length(string_trim(out)) == 0) { "(no matches)" } else { out }
        }
    }
}

# ------------------------------------------------------------
# grep — content search (shell-backed, ripgrep if available, 30s)
# ------------------------------------------------------------
fun do_grep(args) {
    pattern = map_get(args, 'pattern')
    if (pattern == nil) { "error: missing 'pattern'" }
    else {
        path = map_get(args, 'path')
        glob_arg = map_get(args, 'glob')
        mode = map_get(args, 'output_mode')
        hl = map_get(args, 'head_limit')
        base = if (path == nil) { "." } else { to_string(path) }
        pat_q = Util.shell_q(to_string(pattern))
        # Omit a "." path so rg emits clean (non-`./`-prefixed) paths.
        base_part = if (base == "." || string_length(string_trim(base)) == 0) {
            ""
        } else { " " ++ Util.shell_q(base) }
        base_q = Util.shell_q(base)

        # Optional glob filter (rg --glob / mirrors Claude Code's Grep).
        glob_flag = if (glob_arg == nil) { "" }
                    else { " -g " ++ Util.shell_q(to_string(glob_arg)) }

        # output_mode: 'content' (default — file:line:text), 'count'
        # (-c), 'files_with_matches' (-l). Earlier do_grep ignored this
        # arg entirely even though the schema advertised it.
        rg_mode = if (mode == "files_with_matches") { " -l" }
                  else { if (mode == "count") { " -c" }
                  else { " -n --no-heading" }}
        grep_mode = if (mode == "files_with_matches") { " -rl" }
                    else { if (mode == "count") { " -rc" }
                    else { " -rn" }}

        # head_limit caps the result lines (digit-validated; default 100).
        head_n = if (hl == nil) { 100 }
                 else {
                     hs = to_string(hl)
                     if (is_digits_only(hs) == 'true') { parse_int_safe(hs, 100) }
                     else { 100 }
                 }

        # `if/then/else` (not `rg || grep`) so an rg run that finds
        # nothing doesn't fall through and re-run grep over the whole
        # tree. --hidden so dotfiles aren't skipped; -e so a pattern
        # starting with `-` isn't read as a flag.
        grep_base = if (base == "." || string_length(string_trim(base)) == 0) {
            " ."
        } else { " " ++ base_q }
        # Strip leading `./` so grep's `path:line:text` matches rg's
        # `path:line:text` exactly — the model often hands those paths
        # back to Read, which doesn't need (and shouldn't see) a `./`.
        cmd = "if command -v rg >/dev/null 2>&1; then " ++
              "rg --color=never --hidden --no-messages" ++ rg_mode ++ glob_flag ++
              " -e " ++ pat_q ++ base_part ++ "; " ++
              "else grep" ++ grep_mode ++ " --color=never -e " ++ pat_q ++ grep_base ++ " 2>/dev/null | sed 's|^\\./||'; fi" ++
              " | head -n " ++ to_string(head_n)
        result = shell_managed(cmd ++ " 2>&1", search_timeout_s() * 1000)
        code = elem(result, 0)
        out = elem(result, 1)
        interrupted = elem(result, 2)
        if (interrupted == 'true') {
            "[timed out after " ++ to_string(search_timeout_s()) ++ "s on " ++ base ++ " — narrow the path]"
        } else {
            trimmed = truncate_output(out, max_output_bytes())
            if (string_length(string_trim(trimmed)) == 0) { "(no matches)" } else { trimmed }
        }
    }
}

# ------------------------------------------------------------
# helpers
# ------------------------------------------------------------

# Accept either 'path' or 'file_path' (Claude Code uses file_path).
fun resolve_path_arg(args) {
    p = map_get(args, 'path')
    if (p != nil) { p } else { map_get(args, 'file_path') }
}

# Truncate long output to prevent context blowup.
#
# Old version kept ONLY the head — exactly wrong for long builds where
# the useful bits (errors, final status) land at the END. New version
# keeps both ends: 40% from the head (setup context) + 60% from the
# tail (where the action is), separated by a `[N bytes elided]` marker.
fun truncate_output(s, cap) {
    n = string_length(s)
    if (n <= cap) { s }
    else {
        head_bytes = cap * 4 / 10
        tail_bytes = cap - head_bytes
        elided = n - head_bytes - tail_bytes
        head_part = string_sub(s, 0, head_bytes)
        tail_part = string_sub(s, n - tail_bytes, tail_bytes)
        head_part ++
        "\n\n...[" ++ to_string(elided) ++ " bytes elided — " ++
        "use a tighter query (grep/head/tail/sed) for a specific slice]...\n\n" ++
        tail_part
    }
}

# Truncate output to a maximum number of lines. Keeps the first 30%
# and last 70% with an elision marker between — the tail usually has
# the error / final status from a long build.
fun truncate_output_lines(s, max_lines) {
    lines = string_split(s, "\n")
    total = length(lines)
    if (total <= max_lines) { s }
    else {
        head_lines = max_lines * 3 / 10
        tail_lines = max_lines - head_lines
        elided = total - head_lines - tail_lines
        head_part = take_first_lines(lines, head_lines, [])
        tail_part = take_last_lines(lines, tail_lines)
        join_lines(head_part, "") ++
        "\n...[" ++ to_string(elided) ++ " more lines elided — " ++
        "tail kept for error/status context]...\n" ++
        join_lines(tail_part, "")
    }
}

# Take the last `n` items from a list. O(len) but called once per
# truncation so the cost is negligible.
fun take_last_lines(lst, n) {
    total = length(lst)
    if (n >= total) { lst }
    else { drop_first(lst, total - n) }
}

fun drop_first(lst, n) {
    if (n <= 0 || length(lst) == 0) { lst }
    else { drop_first(tl(lst), n - 1) }
}

fun take_first_lines(lst, n, acc) {
    if (n <= 0) { acc }
    else {
        if (length(lst) == 0) { acc }
        else { take_first_lines(tl(lst), n - 1, list_append(acc, hd(lst))) }
    }
}

fun join_lines(lst, acc) {
    if (length(lst) == 0) { acc }
    else {
        h = hd(lst)
        sep = if (string_length(acc) == 0) { "" } else { "\n" }
        join_lines(tl(lst), acc ++ sep ++ h)
    }
}

# Proper shell single-quote wrap. Each embedded single quote is replaced
# with '\'' — close the current single-quoted string, insert an escaped
# single quote, reopen the single-quoted string. Handles Python source
# with raw strings, jq filters, anything.
# Whitelist check: lowercase letters only. Used to vet things we
# splice into shell as flags (rg --type=<lang>) where the value must
# never be a shell metachar.
fun is_simple_word(s) {
    if (string_length(s) == 0) { 'false' }
    else { is_simple_word_loop(s, 0) }
}

fun is_simple_word_loop(s, i) {
    if (i >= string_length(s)) { 'true' }
    else {
        ch = string_sub(s, i, 1)
        ok = if (ch == "a") { 'true' } else { if (ch == "b") { 'true' }
            else { if (ch == "c") { 'true' } else { if (ch == "d") { 'true' }
            else { if (ch == "e") { 'true' } else { if (ch == "f") { 'true' }
            else { if (ch == "g") { 'true' } else { if (ch == "h") { 'true' }
            else { if (ch == "i") { 'true' } else { if (ch == "j") { 'true' }
            else { if (ch == "k") { 'true' } else { if (ch == "l") { 'true' }
            else { if (ch == "m") { 'true' } else { if (ch == "n") { 'true' }
            else { if (ch == "o") { 'true' } else { if (ch == "p") { 'true' }
            else { if (ch == "q") { 'true' } else { if (ch == "r") { 'true' }
            else { if (ch == "s") { 'true' } else { if (ch == "t") { 'true' }
            else { if (ch == "u") { 'true' } else { if (ch == "v") { 'true' }
            else { if (ch == "w") { 'true' } else { if (ch == "x") { 'true' }
            else { if (ch == "y") { 'true' } else { if (ch == "z") { 'true' }
            else { 'false' }}}}}}}}}}}}}}}}}}}}}}}}}}
        if (ok == 'false') { 'false' }
        else { is_simple_word_loop(s, i + 1) }
    }
}

# Pure digit check — used to vet numeric args we splice into shell.
fun is_digits_only(s) {
    if (string_length(s) == 0) { 'false' }
    else { is_digits_loop(s, 0) }
}

fun is_digits_loop(s, i) {
    if (i >= string_length(s)) { 'true' }
    else {
        ch = string_sub(s, i, 1)
        d = digit_of(ch)
        if (d < 0) { 'false' }
        else { is_digits_loop(s, i + 1) }
    }
}

# ------------------------------------------------------------
# remember — save a memory crumb at ~/.swarm-code/memory/<slug>.md
# ------------------------------------------------------------
# Schema matches Claude Code: each memory has a name (title), a
# one-line description used for retrieval decisions, a type tag
# (user | feedback | project | reference), and a content body.
fun do_remember(args, opts) {
    name = map_get(args, 'name')
    desc = map_get(args, 'description')
    type_ = map_get(args, 'type')
    # Canonical key is `content`; also accept `body` — an earlier schema
    # named it that, and the mismatch silently saved empty memories
    # (frontmatter only, no body).
    content = map_get(args, 'content')
    body_alt = map_get(args, 'body')
    if (name == nil) {
        # Back-compat: accept the old {key, value} shape too.
        old_key = map_get(args, 'key')
        old_val = map_get(args, 'value')
        if (old_key == nil || old_val == nil) {
            "error: remember needs 'name', 'description', 'type', 'content'"
        } else {
            Memory.save(to_string(old_key),
                        "(legacy entry)",
                        "user",
                        to_string(old_val),
                        opts)
        }
    } else {
        d = if (desc == nil) { "(no description)" } else { to_string(desc) }
        t = if (type_ == nil) { "user" } else { to_string(type_) }
        c = if (content != nil) { to_string(content) }
            else { if (body_alt != nil) { to_string(body_alt) } else { "" } }
        Memory.save(to_string(name), d, t, c, opts)
    }
}

# ------------------------------------------------------------
# recall — read one memory file by slug or name
# ------------------------------------------------------------
fun do_recall(args, opts) {
    k = map_get(args, 'slug')
    k2 = if (k == nil) { map_get(args, 'key') } else { k }
    k3 = if (k2 == nil) { map_get(args, 'name') } else { k2 }
    if (k3 == nil) { "error: recall needs 'slug' (or 'name')" }
    else {
        v = Memory.recall(to_string(k3), opts)
        if (v == nil) { "error: no memory named '" ++ to_string(k3) ++ "'" }
        else { to_string(v) }
    }
}

# ------------------------------------------------------------
# memory_list — show the full MEMORY.md index
# ------------------------------------------------------------
fun do_memory_list(args, opts) {
    idx = Memory.list_index()
    if (string_length(string_trim(idx)) == 0) { "(no memories yet)" }
    else { idx }
}

# ------------------------------------------------------------
# forget — delete a memory file
# ------------------------------------------------------------
fun do_forget(args, opts) {
    k = map_get(args, 'slug')
    k2 = if (k == nil) { map_get(args, 'name') } else { k }
    if (k2 == nil) { "error: forget needs 'slug' (or 'name')" }
    else { Memory.forget(to_string(k2)) }
}

# ------------------------------------------------------------
# background — kick off an async shell task
# ------------------------------------------------------------
fun do_background(args, opts) {
    cmd = map_get(args, 'command')
    label = map_get(args, 'label')
    bg_table = map_get(opts, 'bg_table')
    if (cmd == nil) { "error: background needs 'command'" }
    else {
        if (bg_table == nil) { "error: background system not initialized" }
        else {
            label_str = if (label == nil) { to_string(cmd) } else { to_string(label) }
            id = Background.launch(bg_table, to_string(cmd), label_str)
            "launched " ++ id ++ ": " ++ label_str ++
                "\n(use bg_status and bg_result to check progress)"
        }
    }
}

fun do_bg_status(args, opts) {
    id = map_get(args, 'task_id')
    bg_table = map_get(opts, 'bg_table')
    if (id == nil) { "error: bg_status needs 'task_id'" }
    else {
        if (bg_table == nil) { "error: background system not initialized" }
        else {
            s = Background.status(bg_table, to_string(id))
            to_string(s)
        }
    }
}

fun do_bg_result(args, opts) {
    id = map_get(args, 'task_id')
    bg_table = map_get(opts, 'bg_table')
    if (id == nil) { "error: bg_result needs 'task_id'" }
    else {
        if (bg_table == nil) { "error: background system not initialized" }
        else { Background.result(bg_table, to_string(id)) }
    }
}

# ------------------------------------------------------------
# heartbeat_status — query the pulse
# ------------------------------------------------------------
fun do_heartbeat_status(opts) {
    hb_table = map_get(opts, 'heartbeat_table')
    Heartbeat.format_status(hb_table)
}

# ------------------------------------------------------------
# bg_server — launch a detached server, get a task id + log file
# ------------------------------------------------------------
fun do_bg_server(args, opts) {
    cmd = map_get(args, 'command')
    label = map_get(args, 'label')
    bg_table = map_get(opts, 'bg_table')
    if (cmd == nil) { "error: bg_server needs 'command'" }
    else {
        if (bg_table == nil) { "error: background system not initialized" }
        else {
            label_str = if (label == nil) { to_string(cmd) } else { to_string(label) }
            id = Background.launch_server(bg_table, to_string(cmd), label_str)
            log_file = Background.log_path_for(id)
            "launched detached server " ++ id ++ ": " ++ label_str ++
                "\nlog: " ++ log_file ++
                "\n(use bg_tail to read log, bg_kill to stop)"
        }
    }
}

fun do_bg_tail(args, opts) {
    id = map_get(args, 'task_id')
    n_arg = map_get(args, 'lines')
    bg_table = map_get(opts, 'bg_table')
    # Coerce `lines` to a clean positive integer so it can't carry shell
    # payload into Background.tail_log (which splices it into a `tail -n
    # N path` command). Anything non-numeric → default 40.
    n = if (n_arg == nil) { 40 }
        else {
            ns = to_string(n_arg)
            if (is_digits_only(ns) == 'true') {
                parse_int_safe(ns, 40)
            } else { 40 }
        }
    if (id == nil) { "error: bg_tail needs 'task_id'" }
    else {
        if (bg_table == nil) { "error: background system not initialized" }
        else { Background.tail_log(bg_table, to_string(id), n) }
    }
}

fun do_bg_kill(args, opts) {
    id = map_get(args, 'task_id')
    bg_table = map_get(opts, 'bg_table')
    if (id == nil) { "error: bg_kill needs 'task_id'" }
    else {
        if (bg_table == nil) { "error: background system not initialized" }
        else { Background.kill_task(bg_table, to_string(id)) }
    }
}

# ------------------------------------------------------------
# web_search — DuckDuckGo HTML search (matches mally's primary path)
# ------------------------------------------------------------
# We shell out to a tiny Python script (python3 is always on macOS) that
# POSTs to html.duckduckgo.com with urlencoded query, parses the result
# HTML with the same regex approach as mally's web.ex, and prints JSON to
# stdout. sw then json_decodes and formats for the model.
#
# Free, no API key, no dependency on the Otonomy proxy. If DDG ever blocks
# or changes format, we can fall back to a Tavily/Otonomy-proxy path here.
fun do_web_search(args) {
    q = map_get(args, 'query')
    if (q == nil) { "error: web_search needs 'query'" }
    else {
        max_n = map_get(args, 'max_results', 5)
        # Python script: read query from env var to avoid shell-quote hell.
        py_script = ddg_python_script()
        cmd = "SWC_WSQ=" ++ Util.shell_q(to_string(q)) ++
              " SWC_WSN=" ++ Util.shell_q(to_string(max_n)) ++
              " python3 -c " ++ Util.shell_q(py_script)
        # stderr → /dev/null (NOT 2>&1): the python script writes non-fatal
        # diagnostics like "ddg failed: 403" to stderr while still printing
        # valid JSON (the Wikipedia fallback) to stdout. Folding stderr would
        # prepend that text and break json_decode of an otherwise-good result.
        result = shell_managed(cmd ++ " 2>/dev/null", fetch_timeout_s() * 1000)
        code = elem(result, 0)
        out = elem(result, 1)
        interrupted = elem(result, 2)
        if (interrupted == 'true') {
            "error: web_search timed out after " ++ to_string(fetch_timeout_s()) ++ "s (process group killed)"
        } else { if (code != 0) {
            "error: web_search failed (exit " ++ to_string(code) ++ "):\n" ++ out
        } else {
            decoded = json_decode(string_trim(out))
            if (decoded == nil) {
                "error: web_search returned unparseable output:\n" ++ truncate_output(out, 300)
            } else {
                format_search_results(decoded, 0, "")
            }
        }}
    }
}

# The DDG HTML search script — embedded as a single sw string literal.
#
# As of April 2026, DuckDuckGo rejects POSTs to html.duckduckgo.com/html/
# without a session (they return the homepage shell). GET with query params
# + a full set of browser headers + gzip handling works reliably. We also
# fall back to the Wikipedia REST search API if DDG ever returns zero
# blocks, so the tool never silently returns "(no results)".
fun ddg_python_script() {
    "import os,sys,json,re,gzip\n" ++
    "import urllib.request,urllib.parse\n" ++
    "q=os.environ.get('SWC_WSQ','')\n" ++
    "n=int(os.environ.get('SWC_WSN','5'))\n" ++
    "if not q:\n" ++
    "  print('[]'); sys.exit(0)\n" ++
    "def fetch(url,headers=None,data=None,timeout=15):\n" ++
    "  req=urllib.request.Request(url,headers=headers or {},data=data)\n" ++
    "  resp=urllib.request.urlopen(req,timeout=timeout)\n" ++
    "  raw=resp.read()\n" ++
    "  if resp.headers.get('Content-Encoding')=='gzip':\n" ++
    "    raw=gzip.decompress(raw)\n" ++
    "  return raw.decode('utf-8',errors='ignore')\n" ++
    "def ddg_search(query):\n" ++
    "  url='https://html.duckduckgo.com/html/?'+urllib.parse.urlencode({'q':query,'kl':'us-en'})\n" ++
    "  h={'User-Agent':'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',\n" ++
    "     'Accept':'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',\n" ++
    "     'Accept-Language':'en-US,en;q=0.5',\n" ++
    "     'Accept-Encoding':'gzip, deflate',\n" ++
    "     'Referer':'https://duckduckgo.com/',\n" ++
    "     'Connection':'keep-alive',\n" ++
    "     'Upgrade-Insecure-Requests':'1'}\n" ++
    "  html=fetch(url,headers=h)\n" ++
    "  blocks=re.split(r'class=\"[^\"]*result[^\"]*results_links[^\"]*\"',html)[1:]\n" ++
    "  if not blocks:\n" ++
    "    blocks=re.split(r'class=\"[^\"]*web-result[^\"]*\"',html)[1:]\n" ++
    "  out=[]\n" ++
    "  for b in blocks[:n]:\n" ++
    "    um=re.search(r'class=\"result__a\"[^>]*href=\"([^\"]*)\"',b)\n" ++
    "    if not um: continue\n" ++
    "    url2=um.group(1)\n" ++
    "    if url2.startswith('//'): url2='https:'+url2\n" ++
    "    try:\n" ++
    "      p=urllib.parse.urlparse(url2)\n" ++
    "      qs=urllib.parse.parse_qs(p.query)\n" ++
    "      if 'uddg' in qs: url2=qs['uddg'][0]\n" ++
    "    except: pass\n" ++
    "    tm=re.search(r'class=\"result__a\"[^>]*>(.*?)</a>',b,re.S)\n" ++
    "    sm=re.search(r'class=\"result__snippet\"[^>]*>(.*?)</a>',b,re.S)\n" ++
    "    title=re.sub(r'<[^>]+>','',tm.group(1)).strip() if tm else 'No title'\n" ++
    "    snip=re.sub(r'<[^>]+>','',sm.group(1)).strip()[:300] if sm else ''\n" ++
    "    out.append({'title':title,'url':url2,'snippet':snip})\n" ++
    "  return out\n" ++
    "def wiki_search(query):\n" ++
    "  url='https://en.wikipedia.org/w/api.php?'+urllib.parse.urlencode({'action':'query','list':'search','srsearch':query,'format':'json','srlimit':n,'utf8':'1'})\n" ++
    "  html=fetch(url,headers={'User-Agent':'swarm-code/0.1 (https://swarm-code.local)'})\n" ++
    "  data=json.loads(html)\n" ++
    "  out=[]\n" ++
    "  for r in data.get('query',{}).get('search',[])[:n]:\n" ++
    "    title=r.get('title','')\n" ++
    "    snip=re.sub(r'<[^>]+>','',r.get('snippet','')).strip()[:300]\n" ++
    "    url2='https://en.wikipedia.org/wiki/'+urllib.parse.quote(title.replace(' ','_'))\n" ++
    "    out.append({'title':title,'url':url2,'snippet':snip})\n" ++
    "  return out\n" ++
    "try:\n" ++
    "  results=ddg_search(q)\n" ++
    "except Exception as e:\n" ++
    "  results=[]\n" ++
    "  sys.stderr.write('ddg failed: '+str(e)+'\\n')\n" ++
    "if not results:\n" ++
    "  try:\n" ++
    "    results=wiki_search(q)\n" ++
    "  except Exception as e:\n" ++
    "    sys.stderr.write('wiki failed: '+str(e)+'\\n')\n" ++
    "print(json.dumps(results))\n"
}

# ------------------------------------------------------------
# run_tests  parse and gate on test output from any framework
# ------------------------------------------------------------
# args: {"repo_path": "/path/to/repo", "command": "npm test" (optional)}
fun do_run_tests(args) {
    repo = map_get(args, 'repo_path')
    cmd = map_get(args, 'command')
    if (repo == nil) { "error: run_tests needs 'repo_path'" }
    else {
        command = if (cmd == nil) { "" } else { to_string(cmd) }
        result = TestRunner.run_tests(to_string(repo), command)
        fw = map_get(result, 'framework')
        passed = map_get(result, 'passed')
        failed = map_get(result, 'failed')
        total = map_get(result, 'total')
        exit_code = map_get(result, 'exit_code')
        raw = map_get(result, 'raw')
        summary = "Framework: " ++ fw ++ "\n" ++
                  "Passed: " ++ to_string(passed) ++ "\n" ++
                  "Failed: " ++ to_string(failed) ++ "\n" ++
                  "Total: " ++ to_string(total) ++ "\n" ++
                  "Exit code: " ++ to_string(exit_code)
        if (failed > 0) {
            tail = if (string_length(raw) > 2000) {
                string_sub(raw, string_length(raw) - 2000, 2000)
            } else {
                raw
            }
            summary ++ "\n\n--- raw output (last 2000 chars) ---\n" ++ tail
        } else {
            summary
        }
    }
}

# ------------------------------------------------------------
# git_status — porcelain status of the current repo  (30s timeout)
# ------------------------------------------------------------
fun do_git_status(args) {
    cwd_arg = map_get(args, 'cwd')
    cwd_part = if (cwd_arg == nil) { "" } else { "-C " ++ Util.shell_q(to_string(cwd_arg)) ++ " " }
    cmd = git_noninteractive_env() ++ "git " ++ cwd_part ++ "status --porcelain --branch 2>&1 | head -n 100"
    r = shell_managed(cmd, git_timeout_s() * 1000)
    code = elem(r, 0)
    out = elem(r, 1)
    interrupted = elem(r, 2)
    if (interrupted == 'true') {
        "[timed out after " ++ to_string(git_timeout_s()) ++ "s]\n" ++ out
    } else {
        if (string_length(out) == 0) { "(clean)" } else { out }
    }
}

# ------------------------------------------------------------
# git_diff — staged + unstaged changes (truncated, 30s timeout)
# ------------------------------------------------------------
fun do_git_diff(args) {
    cwd_arg = map_get(args, 'cwd')
    staged = map_get(args, 'staged')
    cwd_part = if (cwd_arg == nil) { "" } else { "-C " ++ Util.shell_q(to_string(cwd_arg)) ++ " " }
    flag = if (staged == 'true') { "--staged " } else { "" }
    cmd = git_noninteractive_env() ++ "git " ++ cwd_part ++ "diff " ++ flag ++ "--no-color 2>&1"
    r = shell_managed(cmd, git_timeout_s() * 1000)
    code = elem(r, 0)
    out = elem(r, 1)
    interrupted = elem(r, 2)
    if (interrupted == 'true') {
        "[timed out after " ++ to_string(git_timeout_s()) ++ "s]\n" ++ out
    } else {
        truncated = truncate_output(out, max_output_bytes())
        if (string_length(truncated) == 0) { "(no changes)" } else { truncated }
    }
}

# ------------------------------------------------------------
# git_commit — stage files + commit + return hash  (30s timeout)
# ------------------------------------------------------------
# args: {"files": ["path1", "path2"] (optional, default "."),
#        "message": "commit message",
#        "cwd": "/path/to/repo" (optional)}
fun do_git_commit(args) {
    msg = map_get(args, 'message')
    files = map_get(args, 'files')
    cwd_arg = map_get(args, 'cwd')
    if (msg == nil) { "error: git_commit needs 'message'" }
    else {
        stage_list = if (files == nil) { "." } else { join_files(files, "") }
        cwd_part = if (cwd_arg == nil) { "" } else { "-C " ++ Util.shell_q(to_string(cwd_arg)) ++ " " }
        # Group the add && commit && rev-parse chain in { …; } 2>&1 so stderr
        # from ALL three git invocations is captured (a leading per-segment
        # 2>&1 would only fold one). The group exits with the chain's last
        # status, preserving the code==0 success check.
        cmd =
            git_noninteractive_env() ++
            "{ git " ++ cwd_part ++ "add " ++ stage_list ++
            " && git " ++ cwd_part ++ "commit -m " ++ Util.shell_q(to_string(msg)) ++
            " && git " ++ cwd_part ++ "rev-parse --short HEAD ; } 2>&1"
        r = shell_managed(cmd, git_timeout_s() * 1000)
        code = elem(r, 0)
        out = elem(r, 1)
        interrupted = elem(r, 2)
        if (interrupted == 'true') {
            "error: git commit timed out after " ++ to_string(git_timeout_s()) ++ "s\n" ++ out
        } else { if (code == 0) {
            "ok: committed\n" ++ out
        } else {
            "error: git commit failed\n" ++ out
        }}
    }
}

# Join a list of file path strings into shell-quoted args.
fun join_files(files, acc) {
    if (length(files) == 0) { acc }
    else {
        f = hd(files)
        quoted = Util.shell_q(to_string(f))
        new_acc = if (string_length(acc) == 0) { quoted } else { acc ++ " " ++ quoted }
        join_files(tl(files), new_acc)
    }
}

# ------------------------------------------------------------
# code_search — ripgrep-backed symbol search
# ------------------------------------------------------------
# args: {"pattern": "symbolName",
#        "kind": "def|ref|type" (optional, default ref),
#        "path": "/path" (optional, default .),
#        "lang": "rust|swift|python|go|..." (optional)}
fun do_code_search(args) {
    pat = map_get(args, 'pattern')
    if (pat == nil) { "error: code_search needs 'pattern'" }
    else {
        kind = map_get(args, 'kind')
        path = map_get(args, 'path')
        lang = map_get(args, 'lang')
        k = if (kind == nil) { "ref" } else { to_string(kind) }
        base = if (path == nil) { "." } else { to_string(path) }
        p = to_string(pat)

        # Build a regex that matches the kind:
        #   def: look for definition-style patterns (fn/def/function/class/struct/let/var)
        #   ref: word-boundary match
        #   type: class/struct/type/interface/enum
        rgx = if (k == "def") {
            "\\b(fn|def|function|func|class|struct|impl|type|let|var|pub\\s+fn)\\s+" ++ p ++ "\\b"
        } else { if (k == "type") {
            "\\b(class|struct|type|interface|enum|typealias)\\s+" ++ p ++ "\\b"
        } else {
            "\\b" ++ p ++ "\\b"
        }}

        # Lang flag is constrained to ripgrep's known set; allow only
        # [a-z]+ characters before injecting. Anything else is dropped.
        lang_flag = if (lang == nil) { "" }
                    else {
                        ls = to_string(lang)
                        if (is_simple_word(ls) == 'true') { "--type " ++ ls ++ " " }
                        else { "" }
                    }
        base_q = Util.shell_q(base)
        # Prefer rg (ripgrep) for speed. Fall back to grep -rn if not installed.
        cmd =
            "(command -v rg >/dev/null && rg -n --no-heading --color=never " ++ lang_flag ++
            Util.shell_q(rgx) ++ " " ++ base_q ++
            " || grep -rn --color=never -E " ++ Util.shell_q(rgx) ++ " " ++ base_q ++
            ") 2>&1 | head -n 80"
        r = shell_managed(cmd, search_timeout_s() * 1000)
        code = elem(r, 0)
        out = elem(r, 1)
        interrupted = elem(r, 2)
        if (interrupted == 'true') {
            "[timed out after " ++ to_string(search_timeout_s()) ++ "s on " ++ base ++ " — narrow the path]"
        } else {
            truncated = truncate_output(out, max_output_bytes())
            if (string_length(truncated) == 0) { "(no matches)" } else { truncated }
        }
    }
}

# ------------------------------------------------------------
# log_wait — block until a pattern appears in a log file
# ------------------------------------------------------------
# args: {"task_id": "bg-0" OR "path": "/tmp/x.log",
#        "pattern": "server ready",
#        "timeout_sec": 60 (optional, default 60)}
# Returns as soon as the pattern is found, or "timeout" after timeout_sec.
fun do_log_wait(args, opts) {
    pat = map_get(args, 'pattern')
    if (pat == nil) { "error: log_wait needs 'pattern'" }
    else {
        task_id = map_get(args, 'task_id')
        path_arg = map_get(args, 'path')
        timeout = map_get(args, 'timeout_sec')
        timeout_n = if (timeout == nil) { 60 } else { parse_int_safe(to_string(timeout), 60) }

        # Resolve log path: explicit path, or task_id's log file
        log_path = if (path_arg != nil) { to_string(path_arg) }
                   else {
                       if (task_id == nil) { "" }
                       else { "/tmp/swarm-code-" ++ to_string(task_id) ++ ".log" }
                   }
        if (string_length(log_path) == 0) {
            "error: log_wait needs either 'task_id' or 'path'"
        } else {
            # Shell poll loop with grep -q, run via shell_managed so the timeout
            # is enforced in C and the whole process group (the sleep loop) is
            # killed on timeout/ESC — no GNU `timeout` dependency, no orphan.
            # Quote BOTH the pattern and the log path — both reach us from the model.
            inner = "until grep -q " ++ Util.shell_q(to_string(pat)) ++
                    " " ++ Util.shell_q(log_path) ++ " 2>/dev/null; do sleep 0.5; done"
            # shell_managed (not the perl alarm) so a user ESC can stop the
            # wait, and so the `sleep` poll-loop's whole process group dies on
            # timeout. Timeout/interrupt surface via the interrupted flag now,
            # not exit 142.
            r = shell_managed(inner, timeout_n * 1000)
            code = elem(r, 0)
            interrupted = elem(r, 2)
            if (interrupted == 'true') {
                "timeout: pattern not found within " ++ to_string(timeout_n) ++ "s (or stopped)"
            } else { if (code == 0) {
                "ok: pattern found in " ++ log_path
            } else {
                "error: log_wait failed (exit " ++ to_string(code) ++ ")"
            }}
        }
    }
}

# ------------------------------------------------------------
# file_watch — block until a file changes (mtime) or appears
# ------------------------------------------------------------
# args: {"path": "/path/to/file", "timeout_sec": 60}
# Returns when the file's mtime changes or it appears, or on timeout.
fun do_file_watch(args) {
    path_arg = map_get(args, 'path')
    if (path_arg == nil) { "error: file_watch needs 'path'" }
    else {
        path = to_string(path_arg)
        timeout = map_get(args, 'timeout_sec')
        timeout_n = if (timeout == nil) { 60 } else { to_int(timeout) }

        # Capture initial mtime, then poll every 0.5s until it changes.
        # Run via shell_managed so the timeout is enforced in C and the poll
        # loop's process group is killed on timeout/ESC (no GNU `timeout` dep).
        inner =
            "p=" ++ shell_inner_quote(path) ++ "; " ++
            "initial=$(stat -f %m \"$p\" 2>/dev/null || echo missing); " ++
            "while true; do " ++
            "  current=$(stat -f %m \"$p\" 2>/dev/null || echo missing); " ++
            "  [ \"$current\" != \"$initial\" ] && echo \"changed: $initial -> $current\" && exit 0; " ++
            "  sleep 0.5; " ++
            "done"
        r = shell_managed(inner, timeout_n * 1000)
        code = elem(r, 0)
        out = string_trim(elem(r, 1))
        interrupted = elem(r, 2)
        if (interrupted == 'true') {
            "timeout: no change to " ++ path ++ " in " ++ to_string(timeout_n) ++ "s"
        } else { if (code == 0) { "ok: " ++ out }
        else {
            "error: file_watch failed (exit " ++ to_string(code) ++ "): " ++ out
        }}
    }
}

# ------------------------------------------------------------
# sw_check — compile-verify a .sw file and surface the loud
# compiler errors so the model can self-fix.
#
# sw's compiler is the single best correction signal you have when
# writing sw: it points at the exact src/<Module>.sw:LINE and emits
# did-you-mean hints ("filter is a global builtin — write filter(fn,
# list), not Std.filter", "use ++ to concatenate", "unknown function
# 'Main_fn' — fn is not a keyword"). The eval proved that an agent
# which compiles what it writes and fixes on the error beats one that
# single-shots. This tool is the loop primitive.
#
# We run `swc emit` (full parse + typecheck + codegen to /dev/null)
# rather than `build` — no cc invocation, so it's fast and isolates
# *sw-level* errors. Exit 0 ⇒ the sw is valid; non-zero ⇒ return the
# stderr verbatim (it already names the file:line and the fix).
#
# args: {"path": "src/foo.sw" (the .sw file to verify)}
# Resolves the swc binary from: SWARM_CODE_SWC env → swc on PATH →
# ../swarmrt/bin/swc relative to cwd (swarm-code's sibling layout).
fun do_sw_check(args) {
    path_arg = map_get(args, 'path')
    if (path_arg == nil) { "error: sw_check needs 'path' (the .sw file to verify)" }
    else {
        path = to_string(path_arg)
        if (file_exists(path) == 'false') {
            "error: no such file: " ++ path
        } else {
            swc = resolve_swc()
            # `swc emit` writes generated C to STDOUT and diagnostics to STDERR.
            # We only want the diagnostics, so stdout → /dev/null and stderr →
            # a temp file we read back. One emit run; the temp file is filtered
            # of the harmless auto-import / cannot-open chatter swc always prints.
            errf = "/tmp/swc-check-" ++ to_string(timestamp()) ++ ".err"
            cmd = swc ++ " emit " ++ Util.shell_q(path) ++
                  " >/dev/null 2>" ++ Util.shell_q(errf) ++ "; S=$?; " ++
                  "grep -v 'auto-imported\\|cannot open' " ++ Util.shell_q(errf) ++
                  "; rm -f " ++ Util.shell_q(errf) ++ "; exit $S"
            r = shell_managed(cmd, 60 * 1000)
            code = elem(r, 0)
            out = string_trim(elem(r, 1))
            interrupted = elem(r, 2)
            if (interrupted == 'true') {
                "[timed out after 60s while compiling " ++ path ++ "]"
            } else { if (code == 0) {
                "OK: " ++ path ++ " compiles clean (parse + typecheck + codegen passed)."
            } else {
                "COMPILE ERROR in " ++ path ++ " (exit " ++ to_string(code) ++ "):\n" ++
                out ++
                "\n\nFix the line the compiler names, then call sw_check again. " ++
                "The error message tells you the idiom — trust it."
            }}
        }
    }
}

# Resolve the swc compiler binary. swarm-code ships beside swarmrt
# (../swarmrt/bin/swc); allow an explicit override via env, then fall
# back to PATH, then the sibling-repo path.
fun resolve_swc() {
    override = getenv("SWARM_CODE_SWC")
    if (override != nil) { to_string(override) }
    else {
        r = shell_managed("command -v swc 2>/dev/null", read_probe_timeout_s() * 1000)
        found = string_trim(elem(r, 1))
        if (string_length(found) > 0) { found }
        else { "../swarmrt/bin/swc" }
    }
}

# Escape for use INSIDE a double-quoted shell string (bash).
fun shell_inner_quote(s) {
    no_dq = string_replace(s, "\"", "\\\"")
    "\"" ++ no_dq ++ "\""
}

# Format the parsed results list as a readable string for the model.
fun format_search_results(results, i, acc) {
    if (length(results) == 0) {
        if (string_length(acc) == 0) { "(no results)" } else { acc }
    } else {
        entry = hd(results)
        title = to_string(map_get(entry, 'title'))
        url = to_string(map_get(entry, 'url'))
        snip = to_string(map_get(entry, 'snippet'))
        block = "[" ++ to_string(i + 1) ++ "] " ++ title ++ "\n" ++
                "    " ++ url ++ "\n" ++
                "    " ++ snip ++ "\n\n"
        format_search_results(tl(results), i + 1, acc ++ block)
    }
}

# ------------------------------------------------------------
# multi_edit — apply a sequence of edits atomically to one file
# ------------------------------------------------------------
# args: {"path": "...", "edits": [{"old_string": ..., "new_string": ...}, ...]}
# Semantics: load file once, apply edits in order, write result once.
# Each edit's old_string must match exactly once in the current buffer
# (checked via string_contains before/after replace). If any edit fails
# the whole operation aborts and the file is not modified.
fun do_multi_edit(args) {
    path = resolve_path_arg(args)
    edits = map_get(args, 'edits')
    if (path == nil) { "error: missing path" }
    else {
        if (edits == nil) { "error: missing edits list" }
        else {
            guard = PathGuard.validate_write(to_string(path))
            if (guard != "ok") { guard }
            else {
                original = file_read(path)
                if (original == nil) {
                    "error: could not read " ++ path
                } else {
                    apply_edits(path, original, edits, 0)
                }
            }
        }
    }
}

fun apply_edits(path, buffer, edits, count) {
    if (length(edits) == 0) {
        rc = file_write(path, buffer)
        if (rc == 'ok') {
            "ok: applied " ++ to_string(count) ++ " edits to " ++ path
        } else {
            "error: could not write " ++ path
        }
    } else {
        edit_map = hd(edits)
        old_s = map_get(edit_map, 'old_string')
        new_s = map_get(edit_map, 'new_string')
        if (old_s == nil) { "error: edit " ++ to_string(count) ++ " missing old_string" }
        else {
            if (new_s == nil) { "error: edit " ++ to_string(count) ++ " missing new_string" }
            else {
                # Count in the CURRENT buffer (pre-replace) — using
                # the post-replace check produced false positives when
                # new_string contained old_string as a substring.
                occ = count_substrings(buffer, old_s)
                if (occ == 0) {
                    "error: edit " ++ to_string(count) ++ " old_string not found in " ++ path
                } else { if (occ > 1) {
                    "error: edit " ++ to_string(count) ++ " old_string appears " ++ to_string(occ) ++ " times — make it more specific"
                } else {
                    replaced = string_replace(buffer, old_s, new_s)
                    apply_edits(path, replaced, tl(edits), count + 1)
                }}
            }
        }
    }
}

# ------------------------------------------------------------
# todo_write — manage the session todo list
# ------------------------------------------------------------
# args: {"todos": [{"content": "...", "status": "pending|in_progress|completed", "id": "..."}, ...]}
# We store the list as a JSON string in an ETS entry keyed by 'todos_list'.
# The ETS table id lives in opts['todos_table'].
fun do_todo_write(args, opts) {
    todos = map_get(args, 'todos')
    table = map_get(opts, 'todos_table')
    if (todos == nil) { "error: missing 'todos' argument" }
    else {
        if (table == nil) { "error: todo state not initialised" }
        else {
            # Re-encode the list to preserve as a JSON string.
            encoded = json_encode(todos)
            ets_put(table, 'todos_list', encoded)
            # Render the checklist to the terminal and return a
            # compact confirmation to the model.
            print("")
            print(UI.todo_list_render(todos))
            print("")
            "ok: " ++ UI.todo_summary(todos)
        }
    }
}

# Read current todo list as raw JSON (for system prompt injection).
fun todo_read_json(opts) {
    table = map_get(opts, 'todos_table')
    if (table == nil) {
        "[]"
    } else {
        stored = ets_get(table, 'todos_list')
        if (stored == nil) { "[]" } else { stored }
    }
}

# Read and render the todo list for /todos display.
fun todo_read(opts) {
    table = map_get(opts, 'todos_table')
    if (table == nil) { nil }
    else {
        stored = ets_get(table, 'todos_list')
        if (stored == nil) { nil }
        else {
            parsed = json_decode(stored)
            if (parsed == nil) { nil }
            else { parsed }
        }
    }
}

# ------------------------------------------------------------
# web_fetch — http_get a URL and return plain text
# ------------------------------------------------------------
# args: {"url": "...", "prompt": "optional, instruction for summarization"}
# v1 strips HTML tags via a sed-backed shell command and caps output.
# When prompt is provided we append an instruction block to the body —
# the model can then summarize on its next turn.
fun do_web_fetch(args, opts) {
    url = map_get(args, 'url')
    if (url == nil) { "error: missing 'url'" }
    else {
        # Pre-flight feedback: http_get is a single blocking builtin (0-45s,
        # ESC-interruptible upstream) with no poll loop to hang a heartbeat on.
        # Print one dim grey line before it and clear right after, gated off
        # in headless/subagent runs.
        show_wait = if (map_get(opts, 'headless') == 'true') { 'false' }
                    else { if (map_get(opts, 'is_subagent') == 'true') { 'false' }
                    # mcp_server mode reserves stdout for JSON-RPC — never print there.
                    else { if (map_get(opts, 'execution_context') == "mcp_server") { 'false' } else { 'true' } } }
        if (show_wait == 'true') {
            print_inline("\r\e[K  \e[38;5;240m⋯ fetching " ++ fetch_host_label(url) ++ "…\e[0m")
        }
        # http_get(url, headers) → response body string, or nil on failure
        body = http_get(url, [])
        if (show_wait == 'true') { UI.tool_progress_clear() }
        if (body == nil) {
            "error: fetch failed for " ++ url
        } else {
            # Strip HTML by writing to a tmp file and running a shell pipeline.
            # This avoids needing a native HTML parser in .sw.
            tmp_path = "/tmp/swarm_code_fetch.html"
            file_write(tmp_path, body)
            strip_cmd = "cat " ++ tmp_path ++
                        " | sed -e 's/<script[^>]*>[^<]*<\\/script>//g'" ++
                        " -e 's/<style[^>]*>[^<]*<\\/style>//g'" ++
                        " -e 's/<[^>]*>//g'" ++
                        " -e 's/&nbsp;/ /g' -e 's/&amp;/\\&/g'" ++
                        " -e 's/&lt;/</g' -e 's/&gt;/>/g'" ++
                        " -e 's/&quot;/\"/g' | tr -s ' \\n' | head -c 30000"
            result = shell_managed(strip_cmd ++ " 2>&1", fetch_timeout_s() * 1000)
            text = elem(result, 1)
            file_delete(tmp_path)
            "fetched " ++ url ++ " (" ++ to_string(string_length(text)) ++
                " chars after strip)\n\n" ++ text
        }
    }
}

# ------------------------------------------------------------
# browser_* — CDP browser control via swarmrt's wsc_* / chrome_launch
# ------------------------------------------------------------
# A single session is held in opts['browser_table'] (an ETS table).
# First call to browser_launch lazy-creates it. Subsequent calls
# reuse — chrome stays warm across the whole REPL session.

fun ensure_browser(opts) {
    table = map_get(opts, 'browser_table')
    if (table == nil) { nil }
    else {
        sess = ets_get(table, 'session')
        if (sess == nil) { nil }
        else {
            # If the prior session's WS was flagged dead (transport failure or
            # an unresponsive CDP call in cdp_call_with_timeout), transparently
            # relaunch rather than operating on a stale handle. Chrome usually
            # stays warm on :9222, so this is a fast re-attach, not a cold start.
            if (ets_get(sess, 'dead') == 'true') {
                Browser.close(sess)
                fresh = Browser.init('true')
                if (fresh == nil) {
                    ets_delete(table, 'session')
                    nil
                } else {
                    ets_put(table, 'session', fresh)
                    fresh
                }
            } else { sess }
        }
    }
}

fun do_browser_launch(args, opts) {
    table = map_get(opts, 'browser_table')
    if (table == nil) { "error: browser table not initialised in opts" }
    else {
        existing = ets_get(table, 'session')
        if (existing != nil) {
            "ok: browser already launched (reusing session)"
        } else {
            headless_v = map_get(args, 'headless')
            # Default to a VISIBLE browser (real WebGL, you can watch it) — only
            # go headless if the caller explicitly asks for it.
            headless = if (headless_v == 'true' || headless_v == "true") { 'true' } else { 'false' }
            sess = Browser.init(headless)
            if (sess == nil) {
                "error: chrome_launch failed — is Chrome / Chromium installed? checked /Applications and /usr/bin"
            } else {
                ets_put(table, 'session', sess)
                "ok: browser launched (headless=" ++ to_string(headless) ++ ")"
            }
        }
    }
}

fun do_browser_navigate(args, opts) {
    sess = ensure_browser(opts)
    url = map_get(args, 'url')
    if (sess == nil) { "error: no browser session — call browser_launch first" }
    else { if (url == nil) { "error: navigate requires 'url'" }
    else { Browser.navigate(sess, url, opts) }}
}

fun do_browser_click(args, opts) {
    sess = ensure_browser(opts)
    sel = map_get(args, 'selector')
    if (sess == nil) { "error: no browser session — call browser_launch first" }
    else { if (sel == nil) { "error: click requires 'selector'" }
    else { Browser.click(sess, sel, opts) }}
}

fun do_browser_type(args, opts) {
    sess = ensure_browser(opts)
    sel = map_get(args, 'selector')
    text = map_get(args, 'text')
    if (sess == nil) { "error: no browser session — call browser_launch first" }
    else { if (sel == nil) { "error: type requires 'selector'" }
    else { if (text == nil) { "error: type requires 'text'" }
    else { Browser.type_text(sess, sel, text, opts) }}}
}

fun do_browser_screenshot(args, opts) {
    sess = ensure_browser(opts)
    path_v = map_get(args, 'path')
    path = if (path_v == nil) { "/tmp/swc-page.png" } else { to_string(path_v) }
    if (sess == nil) { "error: no browser session — call browser_launch first" }
    else { Browser.screenshot(sess, path, opts) }
}

fun do_browser_get_text(args, opts) {
    sess = ensure_browser(opts)
    sel = map_get(args, 'selector')
    if (sess == nil) { "error: no browser session — call browser_launch first" }
    else { Browser.get_text(sess, sel, opts) }
}

fun do_browser_get_html(args, opts) {
    sess = ensure_browser(opts)
    if (sess == nil) { "error: no browser session — call browser_launch first" }
    else { Browser.get_html(sess, opts) }
}

fun do_browser_evaluate(args, opts) {
    sess = ensure_browser(opts)
    expr = map_get(args, 'expression')
    if (sess == nil) { "error: no browser session — call browser_launch first" }
    else { if (expr == nil) { "error: evaluate requires 'expression'" }
    else { Browser.evaluate(sess, expr, opts) }}
}

fun do_browser_close(args, opts) {
    table = map_get(opts, 'browser_table')
    if (table == nil) { "ok: no browser to close" }
    else {
        sess = ets_get(table, 'session')
        if (sess == nil) { "ok: no browser session to close" }
        else {
            Browser.close(sess)
            ets_delete(table, 'session')
            "ok: browser session closed (chrome still running for fast re-launch)"
        }
    }
}

fun do_browser_console(args, opts) {
    sess = ensure_browser(opts)
    if (sess == nil) { "error: no browser session — call browser_launch first" }
    else {
        logs = Browser.console_logs(sess)
        if (logs == nil || logs == "[]" || logs == "") {
            "ok: no console output/errors captured yet — navigate (or reload) the page; " ++
            "the capture records console + JS errors from page load onward"
        } else {
            "console output + JS errors (most recent last):\n" ++ logs
        }
    }
}

# ============================================================
# Skills — Hermes-style reusable procedures
# ============================================================
# Wraps the Skills module so the agent can author, look up, and
# delete its own playbooks. Skills live as SKILL.md files under
# ~/.swarm-code/skills/<slug>/ — see skills.sw for the layout.

fun do_learn_skill(args) {
    name = map_get(args, 'name')
    desc = map_get(args, 'description')
    triggers = map_get(args, 'triggers')
    instr = map_get(args, 'instructions')
    if (name == nil || string_length(to_string(name)) == 0) {
        "error: learn_skill requires 'name'"
    }
    else { if (instr == nil || string_length(to_string(instr)) == 0) {
        "error: learn_skill requires 'instructions'"
    }
    else {
        d = if (desc == nil) { "" } else { to_string(desc) }
        t = if (triggers == nil) { "" } else { to_string(triggers) }
        Skills.save(to_string(name), d, t, to_string(instr))
    }}
}

fun do_recall_skill(args) {
    slug = map_get(args, 'slug')
    if (slug == nil) { "error: recall_skill requires 'slug'" }
    else { Skills.recall(to_string(slug)) }
}

fun do_forget_skill(args) {
    slug = map_get(args, 'slug')
    if (slug == nil) { "error: forget_skill requires 'slug'" }
    else { Skills.forget(to_string(slug)) }
}

fun do_skill_list(args) {
    Skills.list_index()
}

# ============================================================
# session_search — FTS5 over every past conversation turn
# ============================================================
fun do_session_search(args) {
    q = map_get(args, 'query')
    if (q == nil || string_length(to_string(q)) == 0) {
        "error: session_search requires 'query'"
    } else {
        limit_v = map_get(args, 'limit')
        # Cap at 30 so a fishing-expedition match doesn't flood the context.
        cap = if (limit_v == nil) { 10 }
              else {
                  n = limit_v
                  if (n > 30) { 30 } else { if (n < 1) { 1 } else { n }}
              }
        SessionSearch.search_render(to_string(q), cap)
    }
}

# ============================================================
# read_image — attach an image to the next user-message turn
# ============================================================
# The model calls this when the user references a local image path.
# The handler base64-encodes the file and enqueues it in the
# session attachment table. On the NEXT outbound request, llm.sw
# transforms the user message into a multimodal content array.
fun do_read_image(args, opts) {
    if (Vision.supports(opts) == 'false') {
        "error: this profile doesn't support vision — switch to one " ++
        "with vision:true in settings.json (e.g. kimi), or set " ++
        "SWARM_CODE_VISION=1 to force"
    }
    else {
        path = map_get(args, 'path')
        if (path == nil || string_length(to_string(path)) == 0) {
            "error: read_image requires 'path'"
        }
        else {
            entry = Vision.attach(opts, to_string(path))
            if (entry == nil) {
                "error: could not read or encode " ++ to_string(path) ++
                " (file missing, unsupported MIME, or base64 failed)"
            }
            else {
                "ok: image attached — it will appear in your NEXT " ++
                "request. Continue the turn with your question."
            }
        }
    }
}
