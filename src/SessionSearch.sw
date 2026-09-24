module SessionSearch

import Util

# ============================================================
# SessionSearch — SQLite FTS5 over every conversation turn
# ============================================================
#
# Layout on disk:
#
#   ~/.swarm-code/sessions/
#     index.db              — SQLite with FTS5 virtual table + size/mtime meta
#     journal-<ts>.jsonl    — existing per-session journals (one JSON per line)
#     .active               — pointer to current session journal
#
# What gets indexed: every {role, content} from every journal, plus
# tool_calls flattened into searchable text (`[tool_call NAME] ARGS`).
# System prompts are not journaled so they don't pollute the index.
#
# How the cache stays fresh: at session start we walk the journals
# directory, compare each file's size + mtime (file_stat — an in-process
# stat(2), no shell) against the values recorded in `meta` when it was
# last indexed, and reindex only the ones that changed. A journal is
# rewritten on every turn (`journal_sync`), so the active session's
# new turns land in the index on the next session start — including a
# journal that was still being written by ANOTHER instance when this
# one booted (previously it was marked indexed once and never
# refreshed, because only "present in meta" was checked).
#
# Usage:
#   /search QUERY        — slash command, prints top hits inline
#   session_search tool  — agent-callable; returns hits as a string

export [init, init_at, search, search_at, search_render, db_path, sessions_dir]

fun sessions_dir() { getenv("HOME") ++ "/.swarm-code/sessions" }
fun db_path()      { db_path_at(sessions_dir()) }
fun db_path_at(dir) { dir ++ "/index.db" }

# ------------------------------------------------------------
# init — create schema if missing, then incrementally reindex.
# Idempotent. Called from main.sw at session start. init_at(dir) is the
# same over an explicit sessions directory (unit tests).
# ------------------------------------------------------------
fun init() { init_at(sessions_dir()) }

fun init_at(dir) {
    file_mkdir(dir)
    db = db_open(db_path_at(dir))
    db_exec(db,
        "CREATE VIRTUAL TABLE IF NOT EXISTS journals USING fts5(" ++
        "session UNINDEXED, role UNINDEXED, content)")
    db_exec(db,
        "CREATE TABLE IF NOT EXISTS meta(" ++
        "session TEXT PRIMARY KEY, indexed_at INTEGER, size INTEGER, mtime INTEGER)")
    # Migrate an index.db created before size/mtime were tracked. On a
    # current schema these fail ("duplicate column") — harmless. Old
    # rows read back NULL, so every such journal reindexes once.
    db_exec(db, "ALTER TABLE meta ADD COLUMN size INTEGER")
    db_exec(db, "ALTER TABLE meta ADD COLUMN mtime INTEGER")
    reindex(db, dir)
    db_close(db)
    'session_search_ready'
}

# ------------------------------------------------------------
# reindex — enumerate journals via the file_list builtin (no shell)
# and (re)index every one that is new or whose size / mtime differ
# from what meta recorded at its last indexing. The currently-active
# session (per the .active marker) is always re-indexed as well: its
# turns grow during a run and a same-second rewrite could keep mtime.
# file_stat is an in-process stat(2) — the old "no mtime check, stat
# costs a 1s shell() poll per file" trade-off no longer applies.
# ------------------------------------------------------------
fun reindex(db, dir) {
    active = read_active_marker(dir)
    names = file_list(dir)
    reindex_loop(db, dir, names, active)
}

fun reindex_loop(db, dir, names, active) {
    if (length(names) == 0) { 'ok' }
    else {
        n = hd(names)
        if (is_journal_name(n) == 'true') {
            path = dir ++ "/" ++ n
            sig = file_sig(path)
            needs = if (path == active) { 'true' }
                    else { if (is_fresh(db, path, sig) == 'true') { 'false' }
                    else { 'true' }}
            if (needs == 'true') { index_one(db, path, sig) }
        }
        reindex_loop(db, dir, tl(names), active)
    }
}

fun is_journal_name(n) {
    string_starts_with(n, "journal-") == 'true' &&
    string_ends_with(n, ".jsonl") == 'true'
}

# {size, mtime} of a journal right now ({-1, -1} if it vanished).
fun file_sig(path) {
    st = file_stat(path)
    if (st == nil) { {0 - 1, 0 - 1} }
    else { {map_get(st, 'size'), map_get(st, 'mtime')} }
}

# Indexed AND unchanged since: meta's size + mtime match the file's.
fun is_fresh(db, path, sig) {
    rows = db_query(db, "SELECT size, mtime FROM meta WHERE session = ?", [path])
    if (length(rows) == 0) { 'false' }
    else {
        r = hd(rows)
        if (map_get(r, "size") == elem(sig, 0) && map_get(r, "mtime") == elem(sig, 1)) { 'true' }
        else { 'false' }
    }
}

# Read the .active pointer to know which journal is the currently
# running session (the only one that may have grown since last index).
fun read_active_marker(dir) {
    p = dir ++ "/.active"
    if (file_exists(p) == 'false') { nil }
    else {
        c = file_read(p)
        if (c == nil) { nil } else { string_trim(c) }
    }
}

# `sig` is the {size, mtime} observed BEFORE reading: if the journal
# grows while we ingest it, the recorded sig is older than the file and
# the next boot reindexes it again (never the reverse).
fun index_one(db, path, sig) {
    # swarmrt's db_exec() doesn't bind params — only db_query does.
    # Use db_query for parameterised writes; empty result is harmless.
    db_query(db, "DELETE FROM journals WHERE session = ?", [path])
    content = file_read(path)
    if (content != nil) {
        clines = string_split(content, "\n")
        ingest_lines(db, path, clines)
    }
    db_query(db,
        "INSERT OR REPLACE INTO meta(session, indexed_at, size, mtime) VALUES (?, ?, ?, ?)",
        [path, timestamp(), elem(sig, 0), elem(sig, 1)])
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
fun search(query, limit) { search_at(sessions_dir(), query, limit) }

fun search_at(dir, query, limit) {
    db = db_open(db_path_at(dir))
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
