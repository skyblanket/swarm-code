module Log

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
    bg_done, compaction, permission,
    tail_recent, summarize
]

# Ensure the telemetry directory exists and return today's log path.
fun init() {
    dir = getenv("HOME") ++ "/.swarm-code/telemetry"
    shell("mkdir -p " ++ dir)
    path()
}

fun path() {
    dir = getenv("HOME") ++ "/.swarm-code/telemetry"
    # Use date -u for consistency. We pre-create the dir in init().
    r = shell("date -u +%Y-%m-%d 2>/dev/null")
    date_str = string_trim(elem(r, 1))
    dir ++ "/" ++ date_str ++ ".jsonl"
}

# Core writer: serialize a map to JSON + write a single line.
# The map should already contain a 'type' key.
fun event(data) {
    with_ts = map_put(data, 'ts', timestamp())
    line = json_encode(with_ts) ++ "\n"
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
    event(%{
        type: "tool_call",
        name: to_string(name),
        args: truncate(args_raw, 400)
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
            "printf '  sessions     : '; grep -c '\"session_start\"' " ++ p ++ "; " ++
            "printf '  user inputs  : '; grep -c '\"user_input\"' " ++ p ++ "; " ++
            "printf '  llm requests : '; grep -c '\"llm_request\"' " ++ p ++ "; " ++
            "printf '  llm errors   : '; grep -c '\"llm_error\"' " ++ p ++ "; " ++
            "printf '  tool calls   : '; grep -c '\"tool_call\"' " ++ p ++ "; " ++
            "printf '  tool errors  : '; grep -c '\"tool_result\".*\"error\":true' " ++ p ++ "; " ++
            "printf '  bg_done      : '; grep -c '\"bg_done\"' " ++ p ++ "; " ++
            "echo; " ++
            "echo '  most-used tools:'; " ++
            "grep -o '\"tool_call\",[^}]*' " ++ p ++ " | sed 's/.*\"name\":\"\\([^\"]*\\)\".*/  \\1/' | sort | uniq -c | sort -rn | head -10; " ++
            "echo; " ++
            "echo '  recent errors:'; " ++
            "grep '\"llm_error\\|tool_result\".*\"error\":true' " ++ p ++ " | tail -5 | sed 's/^/  /'"
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
