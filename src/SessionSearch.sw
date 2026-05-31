module SessionSearch

import Util

# ============================================================
# SessionSearch — SQLite FTS5 over every conversation turn
# ============================================================
#
# Layout on disk:
#
#   ~/.swarm-code/sessions/
#     index.db              — SQLite with FTS5 virtual table + mtime meta
#     journal-<ts>.jsonl    — existing per-session journals (one JSON per line)
#     .active               — pointer to current session journal
#
# What gets indexed: every {role, content} from every journal, plus
# tool_calls flattened into searchable text (`[tool_call NAME] ARGS`).
# System prompts are not journaled so they don't pollute the index.
#
# How the cache stays fresh: at session start we walk the journals
# directory, compare each file's mtime against the cached value in
# `meta`, and reindex only the ones that changed. A journal is
# rewritten on every turn (`journal_sync`), so the active session's
# new turns land in the index on the next session start.
#
# Usage:
#   /search QUERY        — slash command, prints top hits inline
#   session_search tool  — agent-callable; returns hits as a string

export [init, search, search_render, db_path, sessions_dir]

fun sessions_dir() { getenv("HOME") ++ "/.swarm-code/sessions" }
fun db_path()      { sessions_dir() ++ "/index.db" }

# ------------------------------------------------------------
# init — create schema if missing, then incrementally reindex.
# Idempotent. Called from main.sw at session start.
# ------------------------------------------------------------
fun init() {
    file_mkdir(sessions_dir())
    db = db_open(db_path())
    db_exec(db,
        "CREATE VIRTUAL TABLE IF NOT EXISTS journals USING fts5(" ++
        "session UNINDEXED, role UNINDEXED, content)")
    db_exec(db,
        "CREATE TABLE IF NOT EXISTS meta(" ++
        "session TEXT PRIMARY KEY, indexed_at INTEGER)")
    reindex(db)
    db_close(db)
    'session_search_ready'
}

# ------------------------------------------------------------
# reindex — enumerate journals via the file_list builtin (no shell)
# and index any that aren't in the meta cache yet. The currently-
# active session (per the .active marker) is always re-indexed,
# since its turns grow during a run.
#
# Why no mtime check: swarmrt's shell() polls every 1s, so 60 files
# × 1 stat call each = 60s startup. file_list is in-process and free,
# but doesn't surface mtimes — so we trade per-file freshness for
# instant boot. The active session is the only one that mutates
# during a run, and we always refresh it.
# ------------------------------------------------------------
fun reindex(db) {
    active = read_active_marker()
    names = file_list(sessions_dir())
    reindex_loop(db, names, active)
}

fun reindex_loop(db, names, active) {
    if (length(names) == 0) { 'ok' }
    else {
        n = hd(names)
        if (is_journal_name(n) == 'true') {
            path = sessions_dir() ++ "/" ++ n
            needs = if (path == active) { 'true' }
                    else { if (is_indexed(db, path) == 'true') { 'false' }
                    else { 'true' }}
            if (needs == 'true') { index_one(db, path) }
        }
        reindex_loop(db, tl(names), active)
    }
}

fun is_journal_name(n) {
    string_starts_with(n, "journal-") == 'true' &&
    string_ends_with(n, ".jsonl") == 'true'
}

fun is_indexed(db, path) {
    rows = db_query(db, "SELECT 1 FROM meta WHERE session = ?", [path])
    if (length(rows) == 0) { 'false' } else { 'true' }
}

# Read the .active pointer to know which journal is the currently
# running session (the only one that may have grown since last index).
fun read_active_marker() {
    p = sessions_dir() ++ "/.active"
    if (file_exists(p) == 'false') { nil }
    else {
        c = file_read(p)
        if (c == nil) { nil } else { string_trim(c) }
    }
}

fun index_one(db, path) {
    # swarmrt's db_exec() doesn't bind params — only db_query does.
    # Use db_query for parameterised writes; empty result is harmless.
    db_query(db, "DELETE FROM journals WHERE session = ?", [path])
    content = file_read(path)
    if (content != nil) {
        clines = string_split(content, "\n")
        ingest_lines(db, path, clines)
    }
    db_query(db,
        "INSERT OR REPLACE INTO meta(session, indexed_at) VALUES (?, ?)",
        [path, timestamp()])
    'ok'
}

fun ingest_lines(db, path, lines) {
    if (length(lines) == 0) { 'ok' }
    else {
        line = hd(lines)
        if (string_length(string_trim(line)) > 0) {
            m = json_decode(line)
            if (m != nil) { ingest_one(db, path, m) }
        }
        ingest_lines(db, path, tl(lines))
    }
}

fun ingest_one(db, path, msg) {
    role = to_string(map_get(msg, 'role'))
    content_v = map_get(msg, 'content')
    if (content_v != nil) {
        c = to_string(content_v)
        if (string_length(c) > 0) {
            db_query(db,
                "INSERT INTO journals(session, role, content) VALUES (?, ?, ?)",
                [path, role, c])
        }
    }
    # Flatten tool calls so the agent can find "where did I call X tool"
    tcs = map_get(msg, 'tool_calls')
    if (tcs != nil) { ingest_tool_calls(db, path, tcs) }
    'ok'
}

fun ingest_tool_calls(db, path, tcs) {
    if (length(tcs) == 0) { 'ok' }
    else {
        t = hd(tcs)
        fn = map_get(t, 'function')
        name = if (fn == nil) { map_get(t, 'name') } else { map_get(fn, 'name') }
        args = if (fn == nil) { map_get(t, 'arguments') } else { map_get(fn, 'arguments') }
        text = "[tool_call " ++ to_string(name) ++ "] " ++ to_string(args)
        db_query(db,
            "INSERT INTO journals(session, role, content) VALUES (?, ?, ?)",
            [path, "tool_call", text])
        ingest_tool_calls(db, path, tl(tcs))
    }
}

# ------------------------------------------------------------
# search — FTS5 MATCH, returns a list of result maps:
#   %{session, role, snippet}
# `snippet()` wraps matched terms in >>><<<.
# ------------------------------------------------------------
fun search(query, limit) {
    db = db_open(db_path())
    rows = db_query(db,
        "SELECT session, role, " ++
        "snippet(journals, 2, '>>>', '<<<', '…', 40) AS snip " ++
        "FROM journals WHERE journals MATCH ? LIMIT ?",
        [fts_escape(query), limit])
    db_close(db)
    rows
}

# FTS5 reads the MATCH string as a query EXPRESSION, so raw user text with
# `" * ( ) : - AND OR NEAR` (code symbols, partial quotes, `C++`, `obj-c:`)
# is a syntax error → sqlite3_step fails → db_query swallows it → 0 hits,
# indistinguishable from a genuine miss. Quote each whitespace-separated
# token as a literal phrase (doubling inner quotes) so any input matches
# literally, while preserving multi-term implicit-AND.
fun fts_escape(query) {
    toks = fts_quote_tokens(string_split(string_trim(to_string(query)), " "), [])
    if (length(toks) == 0) { "\"\"" } else { fts_join(toks, "") }
}

fun fts_quote_tokens(parts, acc) {
    if (length(parts) == 0) { acc }
    else {
        p = string_trim(hd(parts))
        next = if (string_length(p) == 0) { acc }
               else { list_append(acc, "\"" ++ string_replace(p, "\"", "\"\"") ++ "\"") }
        fts_quote_tokens(tl(parts), next)
    }
}

fun fts_join(toks, acc) {
    if (length(toks) == 0) { acc }
    else {
        sep = if (string_length(acc) == 0) { "" } else { " " }
        fts_join(tl(toks), acc ++ sep ++ hd(toks))
    }
}

# Render hits as a plain text block for slash command + tool output.
fun search_render(query, limit) {
    hits = search(query, limit)
    if (length(hits) == 0) {
        "(no hits for '" ++ query ++ "')"
    } else {
        "search: " ++ query ++ "  (" ++ to_string(length(hits)) ++ " hits)\n\n" ++
        render_hits(hits, "")
    }
}

fun render_hits(hits, acc) {
    if (length(hits) == 0) { acc }
    else {
        h = hd(hits)
        session = to_string(map_get(h, "session"))
        role = to_string(map_get(h, "role"))
        snip = to_string(map_get(h, "snip"))
        # Strip the long session path down to the basename
        parts = string_split(session, "/")
        sess_short = last_part(parts)
        entry =
            "[" ++ sess_short ++ "  " ++ role ++ "]\n" ++
            "  " ++ snip ++ "\n\n"
        render_hits(tl(hits), acc ++ entry)
    }
}

fun last_part(parts) {
    if (length(parts) == 0) { "?" }
    else { if (length(tl(parts)) == 0) { hd(parts) }
    else { last_part(tl(parts)) }}
}
