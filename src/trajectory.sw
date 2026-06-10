module Trajectory

import Log

# ============================================================
# Trajectory — export session journals as OpenAI fine-tuning JSONL
# ============================================================
#
# Layout:
#
#   ~/.swarm-code/exports/
#     trajectories-<ts>.jsonl   one JSON line per session (default)
#     <user-supplied path>      `/export-trajectory <path>` form
#
# Each line is a single training example in the canonical OpenAI
# chat fine-tuning format:
#
#   {"messages": [
#       {"role": "system",    "content": "..."},
#       {"role": "user",      "content": "..."},
#       {"role": "assistant", "content": "...",
#                              "tool_calls": [
#                                  {"id":..., "type":"function",
#                                   "function":{"name":..., "arguments":...}}
#                              ]},
#       {"role": "tool",      "tool_call_id":..., "content": "..."},
#       ...
#   ]}
#
# Notes:
#   * Sessions with fewer than 2 messages (just a system or a single
#     user prompt with no assistant reply) are skipped — useless for
#     training.
#   * Empty or unparseable journal lines are dropped silently.
#   * No system prompt is synthesised; we emit only what's in the
#     journal (which already excludes the runtime system prompt by
#     design — see Agent.encode_journal).
#
# Privacy: every exported line passes through Log.redact, which masks
# common secret shapes (sk-/AKIA/ghp_-style tokens, Bearer headers,
# *_key / *_token / *_secret fields, long letter+digit blobs). The
# heuristics are not exhaustive — still review exports manually before
# publishing them anywhere.

export [
    export_all, export_current,
    exports_dir, default_path
]

fun exports_dir() { getenv("HOME") ++ "/.swarm-code/exports" }

fun default_path() {
    exports_dir() ++ "/trajectories-" ++ to_string(timestamp()) ++ ".jsonl"
}

# ------------------------------------------------------------
# export_all(out_path) — walk every journal file under
# ~/.swarm-code/sessions/, emit one JSONL line per valid session.
# Returns %{path, sessions, kept, skipped}.
# ------------------------------------------------------------
fun export_all(out_path) {
    file_mkdir(exports_dir())
    sessions_dir = getenv("HOME") ++ "/.swarm-code/sessions"
    if (file_exists(sessions_dir) == 'false') {
        %{path: out_path, sessions: 0, kept: 0, skipped: 0}
    } else {
        names = file_list(sessions_dir)
        # Pre-create the output file empty so file_append starts clean.
        file_write(out_path, "")
        stats = export_loop(names, sessions_dir, out_path, 0, 0, 0)
        map_put(stats, 'path', out_path)
    }
}

fun export_loop(names, dir, out_path, total, kept, skipped) {
    if (length(names) == 0) {
        %{sessions: total, kept: kept, skipped: skipped}
    } else {
        n = hd(names)
        if (is_journal_file(n) == 'true') {
            full = dir ++ "/" ++ n
            wrote = export_one(full, out_path)
            new_kept = if (wrote == 'true') { kept + 1 } else { kept }
            new_skipped = if (wrote == 'true') { skipped } else { skipped + 1 }
            export_loop(tl(names), dir, out_path, total + 1, new_kept, new_skipped)
        } else {
            export_loop(tl(names), dir, out_path, total, kept, skipped)
        }
    }
}

fun is_journal_file(n) {
    string_starts_with(n, "journal-") == 'true' &&
    string_ends_with(n, ".jsonl") == 'true'
}

# Export one journal. Returns 'true' if it was kept, 'false' if
# skipped (too short, unparseable, etc.).
fun export_one(journal_path, out_path) {
    content = file_read(journal_path)
    if (content == nil) { 'false' }
    else {
        messages = parse_journal_lines(string_split(content, "\n"), [])
        if (length(messages) < 2) { 'false' }
        else {
            wire = clean_messages(messages, [])
            example = %{messages: wire}
            file_append(out_path, Log.redact(json_encode(example)) ++ "\n")
            'true'
        }
    }
}

# ------------------------------------------------------------
# export_current(out_path, history) — emit ONLY the current
# in-memory session. Used by the slash command when the user
# wants the latest turn-set captured before /quit.
# ------------------------------------------------------------
fun export_current(out_path, history) {
    file_mkdir(exports_dir())
    wire = clean_messages(history, [])
    if (length(wire) < 2) {
        %{path: out_path, kept: 0, reason: "session too short"}
    } else {
        file_write(out_path, Log.redact(json_encode(%{messages: wire})) ++ "\n")
        %{path: out_path, kept: 1}
    }
}

# Parse JSONL lines into a list of message maps. Empty / unparseable
# lines are dropped — they're harmless artifacts of crash-recovery.
fun parse_journal_lines(lines, acc) {
    if (length(lines) == 0) { acc }
    else {
        line = string_trim(hd(lines))
        new_acc = if (string_length(line) == 0) { acc }
                  else {
                      m = json_decode(line)
                      if (m == nil) { acc } else { list_append(acc, m) }
                  }
        parse_journal_lines(tl(lines), new_acc)
    }
}

# Normalise messages for the fine-tuning wire shape:
#   * stringify role
#   * stringify content (or pass through list-content for multimodal)
#   * preserve tool_calls + tool_call_id where present
#   * drop swarm-code-internal fields like 'reasoning' that aren't
#     part of the OpenAI fine-tuning schema (model can still learn
#     reasoning patterns from the content stream)
fun clean_messages(messages, acc) {
    if (length(messages) == 0) { acc }
    else {
        m = hd(messages)
        cleaned = clean_one(m)
        new_acc = if (cleaned == nil) { acc }
                  else { list_append(acc, cleaned) }
        clean_messages(tl(messages), new_acc)
    }
}

fun clean_one(msg) {
    role = map_get(msg, 'role')
    if (role == nil) { nil }
    else {
        role_str = to_string(role)
        content = map_get(msg, 'content')
        content_v = if (content == nil) { "" }
                    else { if (is_list(content) == 'true') { content }
                    else { to_string(content) }}

        base = %{role: role_str, content: content_v}

        tool_calls = map_get(msg, 'tool_calls')
        with_tcs = if (tool_calls == nil) { base }
                   else { if (length(tool_calls) == 0) { base }
                   else { map_put(base, 'tool_calls', clean_tool_calls(tool_calls, [])) }}

        tcid = map_get(msg, 'tool_call_id')
        if (tcid == nil) { with_tcs }
        else { map_put(with_tcs, 'tool_call_id', to_string(tcid)) }
    }
}

# Re-emit tool_calls in OpenAI wire shape:
#   {id, type:"function", function: {name, arguments}}
# Internal shape from llm.sw is flat: %{id, name, arguments}.
fun clean_tool_calls(tcs, acc) {
    if (length(tcs) == 0) { acc }
    else {
        t = hd(tcs)
        # Already-wire-shaped (from journal) or internal flat?
        fn = map_get(t, 'function')
        name = if (fn != nil) { map_get(fn, 'name') } else { map_get(t, 'name') }
        args = if (fn != nil) { map_get(fn, 'arguments') } else { map_get(t, 'arguments') }
        id_v = map_get(t, 'id')
        cleaned = %{
            id: if (id_v == nil) { "" } else { to_string(id_v) },
            type: "function",
            function: %{
                name: if (name == nil) { "" } else { to_string(name) },
                arguments: if (args == nil) { "{}" } else { to_string(args) }
            }
        }
        clean_tool_calls(tl(tcs), list_append(acc, cleaned))
    }
}
