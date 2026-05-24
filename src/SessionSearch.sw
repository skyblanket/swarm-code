module SessionSearch

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
    shell("mkdir -p " ++ sessions_dir())
    db = db_open(db_path())
    db_exec(db,
        "CREATE VIRTUAL TABLE IF NOT EXISTS journals USING fts5(" ++
        "session UNINDEXED, role UNINDEXED, content)")
    db_exec(db,
        "CREATE TABLE IF NOT EXISTS meta(" ++
        "session TEXT PRIMARY KEY, mtime TEXT, indexed_at INTEGER)")
    reindex(db)
    db_close(db)
    'session_search_ready'
}

# ------------------------------------------------------------
# reindex — walk journal-*.jsonl, reindex any whose mtime changed
# (or that aren't in the cache yet). Per-file mtime is the unit;
# when it bumps we wipe and re-insert that file's rows.
# ------------------------------------------------------------
fun reindex(db) {
    result = shell("ls -t " ++ sessions_dir() ++ "/journal-*.jsonl 2>/dev/null")
    code = elem(result, 0)
    out = elem(result, 1)
    if (code != 0 || string_length(string_trim(out)) == 0) { 'ok' }
    else {
        files = string_split(string_trim(out), "\n")
        reindex_loop(db, files)
    }
}

fun reindex_loop(db, files) {
    if (length(files) == 0) { 'ok' }
    else {
        path = hd(files)
        mtime = file_mtime(path)
        cached = cached_mtime(db, path)
        if (cached != nil && cached == mtime) {
            reindex_loop(db, tl(files))
        } else {
            # swarmrt's db_exec() doesn't bind params — only db_query does.
            # Use db_query for parameterised writes; the empty result list
            # is harmless.
            db_query(db, "DELETE FROM journals WHERE session = ?", [path])
            content = file_read(path)
            if (content != nil) {
                lines = string_split(content, "\n")
                ingest_lines(db, path, lines)
            }
            db_query(db,
                "INSERT OR REPLACE INTO meta(session, mtime, indexed_at) VALUES (?, ?, ?)",
                [path, mtime, timestamp()])
            reindex_loop(db, tl(files))
        }
    }
}

# Best-effort: works on darwin (`stat -f %m`) and linux (`stat -c %Y`).
fun file_mtime(path) {
    r = shell("stat -f %m " ++ shell_q(path) ++ " 2>/dev/null || " ++
              "stat -c %Y " ++ shell_q(path) ++ " 2>/dev/null")
    string_trim(elem(r, 1))
}

fun cached_mtime(db, path) {
    rows = db_query(db, "SELECT mtime FROM meta WHERE session = ?", [path])
    if (length(rows) == 0) { nil }
    else { to_string(map_get(hd(rows), "mtime")) }
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
        [query, limit])
    db_close(db)
    rows
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

fun shell_q(s) {
    safe = string_replace(s, "'", "'\\''")
    "'" ++ safe ++ "'"
}
