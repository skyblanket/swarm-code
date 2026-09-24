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
    redact, redact_value
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
# The map should already contain a 'type' key. Every string VALUE is
# redacted BEFORE encoding (redact_value) so secrets in previews/args
# never reach disk — this single funnel covers every event constructor
# below. Redacting the ENCODED line instead corrupted it: a masked run
# could swallow the letter of a \n escape, leaving an invalid `\[`.
fun event(data) {
    with_ts = map_put(data, 'ts', timestamp())
    line = json_encode(redact_value(with_ts)) ++ "\n"
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
# redact(s) masks common secret shapes in a PLAIN-TEXT string before it
# is written to disk; redact_value(v) applies it to every string inside
# a decoded value (maps / lists walked recursively, keys kept) and is
# what callers use BEFORE json_encode — events.jsonl (event()) and
# trajectory exports (Trajectory module). Never run redact over encoded
# JSON: escapes (\n, \") would be masked into invalid JSON.
# Layered, cheapest and most-precise first:
#   1. exact match on live SWARM_CODE_API_KEY / SWARM_CODE_EMBED_KEY
#   2. PEM blocks (-----BEGIN …----- … -----END …-----): body masked
#      wholesale — base64 lines with '/' dodged the blob heuristic
#   3. URL userinfo: scheme://user:pass@host → scheme://user:[REDACTED]@host
#   4. known token prefixes (sk-, mk_live_, AKIA, ghp_, xoxb-, ...)
#   5. "Bearer <token>" authorization headers
#   6. key/value shapes, case-insensitive, for identifiers ENDING in a
#      secret word (password, passwd, secret, token, api_key, apikey,
#      access_key, private_key, _key, …: PGPASSWORD=, AWS_SECRET_ACCESS_KEY=,
#      "password": "…", password: … (YAML), \"token\":\"…\" (JSON in text))
#      with optional quotes / whitespace around = : or =>
#   7. long blobs: >= 40 contiguous [A-Za-z0-9+/=_-] mixing letters+digits;
#      a backslash and the character it escapes end a run
# sw has no regex, so these are recursive string_index_of/string_sub
# scans (tail calls, flat stack). Stateless; thresholds are conservative
# so file paths and short hashes stay readable.

fun redact(s) {
    if (s == nil) { "" }
    else {
        s1 = redact_exact(to_string(s), getenv("SWARM_CODE_API_KEY"))
        s2 = redact_exact(s1, getenv("SWARM_CODE_EMBED_KEY"))
        s3 = redact_pem(s2, 0)
        s4 = redact_userinfo(s3, 0)
        s5 = redact_prefixes(s4, [
            "sk-", "mk_live_", "mk_test_", "AKIA", "ghp_", "gho_",
            "github_pat_", "xoxb-", "xoxp-"
        ])
        s6 = redact_bearers(s5, ["Bearer ", "bearer "])
        s7 = redact_kvs(s6, rd_secret_words())
        redact_blobs(s7, string_length(s7), 0, 0, 'false', 'false')
    }
}

# Redact every string inside a decoded JSON-shaped value. Map keys are
# structure, not data, and are kept verbatim.
fun redact_value(v) {
    if (v == nil) { v }
    else { if (typeof(v) == "string") { redact(v) }
    else { if (is_list(v) == 'true') { map(fn(x) { redact_value(x) }, v) }
    else { if (is_map(v) == 'true') {
        rd_map_loop(map_keys(v), map_values(v), map_new())
    } else { v } } } }
}

fun rd_map_loop(keys, vals, acc) {
    if (length(keys) == 0) { acc }
    else { rd_map_loop(tl(keys), tl(vals), map_put(acc, hd(keys), redact_value(hd(vals)))) }
}

# Layer 1: exact-match a live key value (zero false positives).
fun redact_exact(s, k) {
    if (k == nil) { s }
    else {
        if (string_length(k) >= 8) { string_replace(s, k, "[REDACTED]") }
        else { s }
    }
}

# Layer 2: PEM blocks. The BEGIN/END lines stay (they say WHAT was
# there); everything between is masked. A block with no END (a
# truncated preview) is masked to the end of the string.
fun redact_pem(s, from) {
    slen = string_length(s)
    idx = rd_index_from(s, "-----BEGIN ", from)
    if (idx < 0) { s }
    else {
        close = rd_index_from(s, "-----", idx + 11)
        body_start = if (close < 0) { slen } else { close + 5 }
        end_idx = rd_index_from(s, "-----END ", body_start)
        if (end_idx < 0) {
            string_sub(s, 0, body_start) ++ "\n[REDACTED]"
        } else {
            ns = string_sub(s, 0, body_start) ++ "\n[REDACTED]\n" ++
                 string_sub(s, end_idx, slen - end_idx)
            redact_pem(ns, body_start + 12 + 9)
        }
    }
}

# Layer 3: URL userinfo. In scheme://user:pass@host the password is
# masked (the user stays: it is rarely secret and useful context).
fun redact_userinfo(s, from) {
    slen = string_length(s)
    idx = rd_index_from(s, "://", from)
    if (idx < 0) { s }
    else {
        auth_start = idx + 3
        auth_end = rd_authority_end(s, auth_start, slen)
        at = rd_last_at(s, auth_start, auth_end, 0 - 1)
        colon = if (at < 0) { 0 - 1 } else { rd_index_in(s, 58, auth_start, at) }
        if (colon < 0 || at - colon - 1 < 1 ||
            string_sub(s, colon + 1, at - colon - 1) == "[REDACTED]") {
            redact_userinfo(s, auth_start)
        } else {
            ns = string_sub(s, 0, colon + 1) ++ "[REDACTED]" ++ string_sub(s, at, slen - at)
            redact_userinfo(ns, colon + 11)
        }
    }
}

# End of a URL authority: first / ? # whitespace quote < > \ ) ] or end.
fun rd_authority_end(s, i, slen) {
    if (i >= slen) { i }
    else {
        c = codepoint_at(s, i)
        if (c == 47 || c == 63 || c == 35 || c == 32 || c == 9 || c == 10 || c == 13 ||
            c == 34 || c == 39 || c == 60 || c == 62 || c == 92 || c == 41 || c == 93) { i }
        else { rd_authority_end(s, i + 1, slen) }
    }
}

fun rd_last_at(s, i, stop, found) {
    if (i >= stop) { found }
    else { rd_last_at(s, i + 1, stop, (if (codepoint_at(s, i) == 64) { i } else { found })) }
}

# First index of byte `c` in [i, stop), or -1.
fun rd_index_in(s, c, i, stop) {
    if (i >= stop) { 0 - 1 }
    else { if (codepoint_at(s, i) == c) { i } else { rd_index_in(s, c, i + 1, stop) } }
}

# string_index_of with a start offset (absolute result, -1 if absent).
fun rd_index_from(s, needle, from) {
    slen = string_length(s)
    if (from >= slen) { 0 - 1 }
    else {
        idx = string_index_of(string_sub(s, from, slen - from), needle)
        if (idx < 0) { 0 - 1 } else { from + idx }
    }
}

# Layer 4: known token prefixes. Keeps the prefix visible (so logs
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

# Layer 5: "Bearer <token>" — mask the token after the marker when it
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

# Layer 6: key/value secrets. Each entry is {word, min_value_len}: an
# identifier (case-insensitive) ENDING in `word` — PGPASSWORD,
# db_password, AWS_SECRET_ACCESS_KEY, X-Api-Key — followed by an
# optional closing quote (" ' or \"), blanks, a separator (= : =>, but
# not == or ::), blanks and an optional opening quote. Words that are
# unambiguous secrets mask any non-trivial value; the generic suffixes
# (token, _key) keep the old >= 8 threshold so `max_token: 4096` or
# `sort_key: id` stay readable.
fun rd_secret_words() {
    [{"password", 1}, {"passwd", 1}, {"passphrase", 1}, {"secret", 1},
     {"api_key", 1}, {"apikey", 1}, {"api-key", 1}, {"access_key", 1},
     {"private_key", 1}, {"authorization", 1},
     {"token", 8}, {"_key", 8}, {"-key", 8}, {"credential", 8}, {"credentials", 8}]
}

fun redact_kvs(s, words) {
    if (length(words) == 0) { s }
    else {
        w = hd(words)
        redact_kvs(redact_kv_from(s, string_lower(s), elem(w, 0), elem(w, 1), 0), tl(words))
    }
}

# `low` is string_lower(s): same byte length (ASCII-only lowering), so
# offsets found in it apply to `s`.
fun redact_kv_from(s, low, word, min_len, from) {
    slen = string_length(s)
    idx = rd_index_from(low, word, from)
    if (idx < 0) { s }
    else {
        wend = idx + string_length(word)
        ident_ends = if (wend >= slen) { 'true' }
                     else { if (rd_is_token(codepoint_at(s, wend)) == 'true') { 'false' } else { 'true' } }
        span = if (ident_ends == 'true') { rd_kv_span(s, wend, slen, min_len <= 1) } else { {0 - 1, 0 - 1} }
        vs = elem(span, 0)
        ve = elem(span, 1)
        if (vs < 0) { redact_kv_from(s, low, word, min_len, wend) }
        else { if (rd_kv_maskable(s, vs, ve, min_len) == 'false') {
            redact_kv_from(s, low, word, min_len, (if (ve > wend) { ve } else { wend }))
        } else {
            ns = string_sub(s, 0, vs) ++ "[REDACTED]" ++ string_sub(s, ve, slen - ve)
            redact_kv_from(ns, string_lower(ns), word, min_len, vs + 10)
        }}
    }
}

# Value span {start, end} after a key ending at i, or {-1, -1} when no
# key/value separator follows. Quoted values run to the matching quote;
# unquoted `=` values (env / query / ini) stop at whitespace and
# delimiters; unquoted `:` values (YAML / headers) run to end of line
# for the unambiguous secret words (`to_eol`: "password: two words")
# but stop at whitespace for the generic suffixes, so prose such as
# "max_token: 4096 sort_key: id" keeps its short values.
fun rd_kv_span(s, i, slen, to_eol) {
    j0 = rd_skip_key_quote(s, i, slen)
    j1 = rd_skip_blanks(s, j0, slen)
    if (j1 >= slen) { {0 - 1, 0 - 1} }
    else {
        c = codepoint_at(s, j1)
        n1 = if (j1 + 1 < slen) { codepoint_at(s, j1 + 1) } else { 0 }
        sep_end = if (c == 58 && n1 != 58) { j1 + 1 }                     # :  (not ::)
                  else { if (c == 61 && n1 == 62) { j1 + 2 }               # =>
                  else { if (c == 61 && n1 != 61) { j1 + 1 }               # =  (not ==)
                  else { 0 - 1 } } }
        if (sep_end < 0) { {0 - 1, 0 - 1} }
        else {
            j = rd_skip_blanks(s, sep_end, slen)
            q = if (j < slen) { codepoint_at(s, j) } else { 0 }
            q2 = if (j + 1 < slen) { codepoint_at(s, j + 1) } else { 0 }
            if (q == 34 || q == 39) {
                {j + 1, rd_until_quote(s, j + 1, slen, q)}
            } else { if (q == 92 && q2 == 34) {
                {j + 2, rd_until_quote(s, j + 2, slen, 92)}
            } else { if (c == 58 && to_eol == 'true') {
                {j, rd_trim_end(s, j, rd_until_eol(s, j, slen))}
            } else {
                {j, rd_value_end(s, j, slen)}
            }}}
        }
    }
}

fun rd_skip_key_quote(s, i, slen) {
    if (i >= slen) { i }
    else {
        c = codepoint_at(s, i)
        if (c == 34 || c == 39) { i + 1 }
        else { if (c == 92 && i + 1 < slen && codepoint_at(s, i + 1) == 34) { i + 2 }
        else { i } }
    }
}

fun rd_skip_blanks(s, i, slen) {
    if (i >= slen) { i }
    else {
        c = codepoint_at(s, i)
        if (c == 32 || c == 9) { rd_skip_blanks(s, i + 1, slen) } else { i }
    }
}

# Up to (not including) quote byte q, a backslash, or a newline.
fun rd_until_quote(s, i, slen, q) {
    if (i >= slen) { i }
    else {
        c = codepoint_at(s, i)
        if (c == q || c == 92 || c == 10 || c == 13) { i } else { rd_until_quote(s, i + 1, slen, q) }
    }
}

# Up to end of line, or a flow-style delimiter , } ] or quote.
fun rd_until_eol(s, i, slen) {
    if (i >= slen) { i }
    else {
        c = codepoint_at(s, i)
        if (c == 10 || c == 13 || c == 44 || c == 125 || c == 93 || c == 34 || c == 39) { i }
        else { rd_until_eol(s, i + 1, slen) }
    }
}

fun rd_trim_end(s, start, e) {
    if (e <= start) { e }
    else {
        c = codepoint_at(s, e - 1)
        if (c == 32 || c == 9) { rd_trim_end(s, start, e - 1) } else { e }
    }
}

# Worth masking: long enough for its class, not already masked, and not
# a bare boolean/null ("secret: true" is configuration, not a secret).
fun rd_kv_maskable(s, vs, ve, min_len) {
    n = ve - vs
    if (n < min_len || n < 1) { 'false' }
    else {
        v = string_lower(string_sub(s, vs, n))
        # "[redacted" — the span may stop at the marker's own "]".
        if (string_starts_with(v, "[redacted") == 'true') { 'false' }
        else { if (v == "true" || v == "false" || v == "null" || v == "none" || v == "nil") { 'false' }
        else { 'true' } }
    }
}

# Layer 7: long-blob heuristic. Any contiguous run of base64-ish chars
# [A-Za-z0-9+/=_-] that is >= 40 long AND mixes letters with digits is
# masked. Threshold 40 keeps file paths and 7-char short hashes
# readable; "[REDACTED]" (letters only) can never re-match itself.
# Two exemptions keep coding-agent output readable: pure-hex runs of
# exactly 40/64 chars (full git SHA-1/SHA-256) and '/'-bearing runs
# under 80 chars (digit-containing file paths — '/' stays in the
# charset because base64 secrets contain it, but those run long).
# A backslash ends a run AND the byte it escapes is skipped: in text
# that embeds JSON / C strings, "\nAKIA…" must not become a run
# starting with the escape letter (masking it yields "\[REDACTED]").
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
            skip = if (c == 92) { 2 } else { 1 }
            if (rd_blob_hit(s, start, i, seen_alpha, seen_digit) == 'true') {
                ns = string_sub(s, 0, start) ++ "[REDACTED]" ++
                     string_sub(s, i, slen - i)
                nstart = start + 10 + skip
                redact_blobs(ns, string_length(ns), nstart, nstart, 'false', 'false')
            } else {
                redact_blobs(s, slen, i + skip, i + skip, 'false', 'false')
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
# backslash (start of a JSON escape), and , } ] & ; ) delimiters.
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

# space tab nl cr " ' \ , } ] & ; )
fun rd_is_stop(c) {
    c == 32 || c == 9 || c == 10 || c == 13 || c == 34 || c == 39 ||
    c == 92 || c == 44 || c == 125 || c == 93 || c == 38 || c == 59 || c == 41
}
