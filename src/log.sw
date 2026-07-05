module Log

import Util

# ============================================================
# Log — append-only JSONL telemetry for swarm-code
# ============================================================
#
# Every LLM call, tool invocation, error, and session event is written
# as one JSON object per line to ~/.swarm-code/telemetry/{date}.jsonl.
# The file is append-only, human-readable, and greppable.
#
# Events logged:
#   - session_start   {opts snapshot}
#   - session_end     {reason}
#   - user_input      {chars, line_preview}
#   - llm_request     {msgs, chars, model}
#   - llm_response    {latency_ms, chars, had_tools}
#   - llm_error       {reason, body_preview}
#   - tool_call       {name, args_raw, args_preview}
#   - tool_result     {name, chars, truncated, had_error}
#   - bg_done         {task_id, exit, label}
#   - bg_stalled      {task_id, label, tail}
#   - heartbeat       {count, uptime_ms}   (sampled 1-in-10)
#   - compaction      {before, after}
#   - permission      {tool, decision}
#
# Use /telemetry to see the last N events, /stats for a summary.

export [
    init, path,
    event,
    session_start, session_end,
    user_input,
    llm_request, llm_response, llm_error,
    tool_call, tool_result,
    bg_done, bg_stalled, compaction, permission,
    tail_recent, summarize,
    redact
]

# Ensure the telemetry directory exists and return the log path.
fun init() {
    file_mkdir(getenv("HOME") ++ "/.swarm-code/telemetry")
    path()
}

# Flat events.jsonl — no daily rotation. The old version date-stamped
# files (events-2026-05-24.jsonl), but computing the date required a
# shell("date") on every event, and swarmrt's shell() polls every 1s
# (~1s per Log.* call). Going flat trades pretty-rotation for instant
# logging. Rotate externally with logrotate if you actually need it.
fun path() {
    getenv("HOME") ++ "/.swarm-code/telemetry/events.jsonl"
}

# Core writer: serialize a map to JSON + write a single line.
# The map should already contain a 'type' key. The encoded line passes
# through redact() so secrets in previews/args never reach disk — this
# single funnel covers every event constructor below.
fun event(data) {
    with_ts = map_put(data, 'ts', timestamp())
    line = redact(json_encode(with_ts)) ++ "\n"
    file_append(path(), line)
}

# ------------------------------------------------------------
# Event constructors
# ------------------------------------------------------------

fun session_start(model, endpoint, cwd) {
    event(%{
        type: "session_start",
        model: model,
        endpoint: endpoint,
        cwd: cwd,
        pid: getenv("PPID")
    })
}

fun session_end(reason) {
    event(%{type: "session_end", reason: reason})
}

fun user_input(line) {
    event(%{
        type: "user_input",
        chars: string_length(line),
        preview: truncate(line, 200)
    })
}

fun llm_request(model, msg_count, total_chars) {
    event(%{
        type: "llm_request",
        model: model,
        msgs: msg_count,
        chars: total_chars
    })
}

fun llm_response(latency_ms, content_chars, had_tools) {
    event(%{
        type: "llm_response",
        latency_ms: latency_ms,
        chars: content_chars,
        had_tools: had_tools
    })
}

fun llm_error(reason, body_preview) {
    event(%{
        type: "llm_error",
        reason: reason,
        body: truncate(body_preview, 300)
    })
}

fun tool_call(name, args_raw) {
    # 2000 (was 400): 400 clipped most write/multi_edit args, leaving the
    # audit trail blind to what was actually attempted. Safe to widen:
    # event() runs redact() over the final encoded line, so the extra
    # chars get the same secret masking as before.
    event(%{
        type: "tool_call",
        name: to_string(name),
        args: truncate(args_raw, 2000)
    })
}

fun tool_result(name, output_chars, had_error) {
    event(%{
        type: "tool_result",
        name: to_string(name),
        chars: output_chars,
        error: had_error
    })
}

fun bg_done(task_id, exit_code, label) {
    event(%{
        type: "bg_done",
        task_id: task_id,
        exit: exit_code,
        label: label
    })
}

fun bg_stalled(task_id, label, tail) {
    event(%{
        type: "bg_stalled",
        task_id: task_id,
        label: label,
        tail: truncate(tail, 300)
    })
}

fun compaction(before_count, after_count) {
    event(%{
        type: "compaction",
        before_count: before_count,
        after_count: after_count
    })
}

fun permission(tool_name, decision) {
    event(%{
        type: "permission",
        tool: to_string(tool_name),
        decision: to_string(decision)
    })
}

# ------------------------------------------------------------
# Readers — used by /telemetry and /stats slash commands
# ------------------------------------------------------------

# Return the last n lines of today's telemetry as a string (one JSON
# per line). If the file doesn't exist returns a friendly message.
fun tail_recent(n) {
    p = path()
    if (file_exists(p) == 'false') {
        "(no telemetry for today yet)"
    } else {
        cmd = "tail -n " ++ to_string(n) ++ " " ++ p ++ " 2>&1"
        r = shell(cmd)
        out = elem(r, 1)
        if (string_length(out) == 0) { "(empty)" } else { out }
    }
}

# One-line summary (pipes through a few shell greps — fast and robust).
fun summarize() {
    p = path()
    if (file_exists(p) == 'false') {
        "(no telemetry for today yet)"
    } else {
        cmd =
            "echo '  session summary for today'; " ++
            "echo '  --------------------------'; " ++
            "printf '  sessions     : '; grep -c '\"session_start\"' " ++ Util.shell_q(p) ++ "; " ++
            "printf '  user inputs  : '; grep -c '\"user_input\"' " ++ Util.shell_q(p) ++ "; " ++
            "printf '  llm requests : '; grep -c '\"llm_request\"' " ++ Util.shell_q(p) ++ "; " ++
            "printf '  llm errors   : '; grep -c '\"llm_error\"' " ++ Util.shell_q(p) ++ "; " ++
            "printf '  tool calls   : '; grep -c '\"tool_call\"' " ++ Util.shell_q(p) ++ "; " ++
            "printf '  tool errors  : '; grep -c '\"tool_result\".*\"error\":true' " ++ Util.shell_q(p) ++ "; " ++
            "printf '  bg_done      : '; grep -c '\"bg_done\"' " ++ Util.shell_q(p) ++ "; " ++
            "echo; " ++
            "echo '  most-used tools:'; " ++
            "grep -o '\"tool_call\",[^}]*' " ++ Util.shell_q(p) ++ " | sed 's/.*\"name\":\"\\([^\"]*\\)\".*/  \\1/' | sort | uniq -c | sort -rn | head -10; " ++
            "echo; " ++
            "echo '  recent errors:'; " ++
            "grep '\"llm_error\\|tool_result\".*\"error\":true' " ++ Util.shell_q(p) ++ " | tail -5 | sed 's/^/  /'"
        r = shell(cmd)
        elem(r, 1)
    }
}

# Truncate a string for display / log preview.
fun truncate(s, max_len) {
    if (s == nil) { "" }
    else {
        if (string_length(s) <= max_len) { s }
        else { string_sub(s, 0, max_len - 3) ++ "..." }
    }
}

# ------------------------------------------------------------
# Secret redaction
# ------------------------------------------------------------
#
# redact(s) masks common secret shapes in a string before it is
# written to disk. Applied to every events.jsonl line (see event())
# and to trajectory exports (Trajectory module). Layered, cheapest
# and most-precise first:
#   1. exact match on live SWARM_CODE_API_KEY / SWARM_CODE_EMBED_KEY
#   2. known token prefixes (sk-, mk_live_, AKIA, ghp_, xoxb-, ...)
#   3. "Bearer <token>" authorization headers
#   4. key/value shapes (_key":"..., password":"..., api_key=...,
#      + JSON-escaped forms)
#   5. long blobs: >= 40 contiguous [A-Za-z0-9+/=_-] mixing letters+digits
# sw has no regex, so these are recursive string_index_of/string_sub
# scans (tail calls, flat stack). Stateless; thresholds are conservative
# so file paths and short hashes stay readable.

fun redact(s) {
    if (s == nil) { "" }
    else {
        s1 = redact_exact(s, getenv("SWARM_CODE_API_KEY"))
        s2 = redact_exact(s1, getenv("SWARM_CODE_EMBED_KEY"))
        s3 = redact_prefixes(s2, [
            "sk-", "mk_live_", "mk_test_", "AKIA", "ghp_", "gho_",
            "github_pat_", "xoxb-", "xoxp-"
        ])
        s4 = redact_bearers(s3, ["Bearer ", "bearer "])
        s5 = redact_kvs(s4, [
            "_key\":\"", "token\":\"", "secret\":\"", "password\":\"",
            "authorization\":\"", "Authorization\":\"",
            "_key\\\":\\\"", "token\\\":\\\"", "secret\\\":\\\"", "password\\\":\\\"",
            "authorization\\\":\\\"", "Authorization\\\":\\\"",
            "api_key="
        ])
        redact_blobs(s5, string_length(s5), 0, 0, 'false', 'false')
    }
}

# Layer 1: exact-match a live key value (zero false positives).
fun redact_exact(s, k) {
    if (k == nil) { s }
    else {
        if (string_length(k) >= 8) { string_replace(s, k, "[REDACTED]") }
        else { s }
    }
}

# Layer 2: known token prefixes. Keeps the prefix visible (so logs
# still show what KIND of key was masked), masks the token body when
# prefix + body is >= 16 chars.
fun redact_prefixes(s, prefixes) {
    if (length(prefixes) == 0) { s }
    else { redact_prefixes(redact_prefix_from(s, hd(prefixes), 0), tl(prefixes)) }
}

# string_index_of has no start offset, so re-slice the remainder on
# each round and track absolute positions ourselves.
# The match must start at a token boundary (start-of-string or a
# non-token char before it) — otherwise the "sk-" in ordinary words
# like "task-oriented-scheduling" would mask the rest of the word.
fun redact_prefix_from(s, prefix, from) {
    slen = string_length(s)
    if (from >= slen) { s }
    else {
        idx = string_index_of(string_sub(s, from, slen - from), prefix)
        if (idx < 0) { s }
        else {
            abs = from + idx
            tok_start = abs + string_length(prefix)
            at_boundary = if (abs == 0) { 'true' }
                          else {
                              if (rd_is_token(codepoint_at(s, abs - 1)) == 'true') { 'false' }
                              else { 'true' }
                          }
            tok_end = rd_token_end(s, tok_start, slen)
            if (at_boundary == 'true' && tok_end - abs >= 16) {
                ns = string_sub(s, 0, tok_start) ++ "[REDACTED]" ++
                     string_sub(s, tok_end, slen - tok_end)
                redact_prefix_from(ns, prefix, tok_start + 10)
            } else {
                redact_prefix_from(s, prefix, tok_start)
            }
        }
    }
}

# Layer 3: "Bearer <token>" — mask the token after the marker when it
# is >= 12 chars.
fun redact_bearers(s, markers) {
    if (length(markers) == 0) { s }
    else { redact_bearers(redact_bearer_from(s, hd(markers), 0), tl(markers)) }
}

fun redact_bearer_from(s, marker, from) {
    slen = string_length(s)
    if (from >= slen) { s }
    else {
        idx = string_index_of(string_sub(s, from, slen - from), marker)
        if (idx < 0) { s }
        else {
            abs = from + idx
            tok_start = abs + string_length(marker)
            tok_end = rd_value_end(s, tok_start, slen)
            if (tok_end - tok_start >= 12) {
                ns = string_sub(s, 0, abs) ++ "Bearer [REDACTED]" ++
                     string_sub(s, tok_end, slen - tok_end)
                redact_bearer_from(ns, marker, abs + 17)
            } else {
                redact_bearer_from(s, marker, tok_start)
            }
        }
    }
}

# Layer 4: key/value shapes. Covers bare field names (password":",
# token":", secret":" — token/secret also catch the _token/_secret
# suffixed forms), the _key suffix (api_key etc.; bare key":" would
# false-positive on words like monkey), and the backslash-escaped
# forms (_key\":\"<val>) that appear once tool args are embedded
# inside a JSON-encoded line. Values >= 8 chars are masked up to the
# next quote/backslash/whitespace/delimiter.
fun redact_kvs(s, markers) {
    if (length(markers) == 0) { s }
    else { redact_kvs(redact_kv_from(s, hd(markers), 0), tl(markers)) }
}

fun redact_kv_from(s, marker, from) {
    slen = string_length(s)
    if (from >= slen) { s }
    else {
        idx = string_index_of(string_sub(s, from, slen - from), marker)
        if (idx < 0) { s }
        else {
            val_start = from + idx + string_length(marker)
            val_end = rd_value_end(s, val_start, slen)
            if (val_end - val_start >= 8) {
                ns = string_sub(s, 0, val_start) ++ "[REDACTED]" ++
                     string_sub(s, val_end, slen - val_end)
                redact_kv_from(ns, marker, val_start + 10)
            } else {
                redact_kv_from(s, marker, val_start)
            }
        }
    }
}

# Layer 5: long-blob heuristic. Any contiguous run of base64-ish chars
# [A-Za-z0-9+/=_-] that is >= 40 long AND mixes letters with digits is
# masked. Threshold 40 keeps file paths and 7-char short hashes
# readable; "[REDACTED]" (letters only) can never re-match itself.
# Two exemptions keep coding-agent output readable: pure-hex runs of
# exactly 40/64 chars (full git SHA-1/SHA-256) and '/'-bearing runs
# under 80 chars (digit-containing file paths — '/' stays in the
# charset because base64 secrets contain it, but those run long).
fun redact_blobs(s, slen, i, start, seen_alpha, seen_digit) {
    if (i >= slen) {
        if (rd_blob_hit(s, start, slen, seen_alpha, seen_digit) == 'true') {
            string_sub(s, 0, start) ++ "[REDACTED]"
        } else { s }
    } else {
        c = codepoint_at(s, i)
        if (rd_is_blob(c) == 'true') {
            na = if (rd_is_alpha(c) == 'true') { 'true' } else { seen_alpha }
            nd = if (rd_is_digit(c) == 'true') { 'true' } else { seen_digit }
            redact_blobs(s, slen, i + 1, start, na, nd)
        } else {
            if (rd_blob_hit(s, start, i, seen_alpha, seen_digit) == 'true') {
                ns = string_sub(s, 0, start) ++ "[REDACTED]" ++
                     string_sub(s, i, slen - i)
                redact_blobs(ns, string_length(ns), start + 10, start + 10, 'false', 'false')
            } else {
                redact_blobs(s, slen, i + 1, i + 1, 'false', 'false')
            }
        }
    }
}

fun rd_blob_hit(s, start, run_end, seen_alpha, seen_digit) {
    run_len = run_end - start
    if (run_len >= 40 && seen_alpha == 'true' && seen_digit == 'true') {
        if (rd_is_hex_run(s, start, run_end) == 'true' &&
            (run_len == 40 || run_len == 64)) { 'false' }
        else {
            if (rd_run_has_slash(s, start, run_end) == 'true') {
                if (run_len >= 80) { 'true' } else { 'false' }
            } else { 'true' }
        }
    } else { 'false' }
}

# Is [i, run_end) entirely hex digits? (git SHA exemption)
fun rd_is_hex_run(s, i, run_end) {
    if (i >= run_end) { 'true' }
    else {
        if (rd_is_hex(codepoint_at(s, i)) == 'true') { rd_is_hex_run(s, i + 1, run_end) }
        else { 'false' }
    }
}

fun rd_is_hex(c) {
    rd_is_digit(c) == 'true' || (c >= 97 && c <= 102) || (c >= 65 && c <= 70)
}

# Does [i, run_end) contain '/'? (file-path exemption)
fun rd_run_has_slash(s, i, run_end) {
    if (i >= run_end) { 'false' }
    else {
        if (codepoint_at(s, i) == 47) { 'true' }
        else { rd_run_has_slash(s, i + 1, run_end) }
    }
}

# End (exclusive) of a run of token chars [A-Za-z0-9_-] starting at i.
fun rd_token_end(s, i, slen) {
    if (i >= slen) { i }
    else {
        if (rd_is_token(codepoint_at(s, i)) == 'true') { rd_token_end(s, i + 1, slen) }
        else { i }
    }
}

# End (exclusive) of a secret value: stops at whitespace, quotes,
# backslash (start of a JSON escape), and ,/}/]/& delimiters.
fun rd_value_end(s, i, slen) {
    if (i >= slen) { i }
    else {
        if (rd_is_stop(codepoint_at(s, i)) == 'true') { i }
        else { rd_value_end(s, i + 1, slen) }
    }
}

fun rd_is_token(c) {
    (c >= 48 && c <= 57) || (c >= 65 && c <= 90) ||
    (c >= 97 && c <= 122) || c == 95 || c == 45
}

fun rd_is_blob(c) {
    rd_is_alpha(c) == 'true' || rd_is_digit(c) == 'true' ||
    c == 43 || c == 47 || c == 61 || c == 95 || c == 45
}

fun rd_is_alpha(c) { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }

fun rd_is_digit(c) { c >= 48 && c <= 57 }

# space tab nl cr " ' \ , } ] &
fun rd_is_stop(c) {
    c == 32 || c == 9 || c == 10 || c == 13 || c == 34 || c == 39 ||
    c == 92 || c == 44 || c == 125 || c == 93 || c == 38
}
