module Memory

import Util
import MemVec

# ============================================================
# Memory — Claude-Code-style crumbs store
# ============================================================
#
# Layout on disk:
#
#   ~/.swarm-code/memory/
#     MEMORY.md              — one-line pointer index, always loaded
#     user_role.md           — one file per memory, YAML frontmatter
#     feedback_testing.md
#     project_swarmrt.md
#     reference_sushi.md
#     ...
#
# Each memory file is a small markdown document:
#
#   ---
#   name: User's ADHD workflow
#   description: User prefers chunked tasks with clear checkpoints
#   type: user
#   ---
#
#   User has mentioned they work better when tasks are broken into
#   small visible chunks with status markers...
#
# Why crumbs (not one JSON blob):
#   * Atomic — writing a small file is atomic at the OS level. No
#     read-modify-write races where we overwrite with a stale copy.
#   * Transparent — `ls ~/.swarm-code/memory/` shows everything.
#   * Resilient — one bad file doesn't kill the whole brain.
#   * Zero-cost index — the filesystem IS the index.
#
# Four memory types (matching Claude Code's taxonomy):
#   user       — facts about the user's role, goals, preferences
#   feedback   — guidance on how to work (corrections + confirmations)
#   project    — ongoing work context, deadlines, decisions
#   reference  — pointers to external systems (Linear, Grafana, etc.)

export [
    load, memory_dir, index_path, memory_file_path, embed_db_path,
    save, recall, list_index, forget,
    as_prompt_section, slugify, parse_frontmatter, find_substring,
    embed_missing
]

fun memory_dir() {
    getenv("HOME") ++ "/.swarm-code/memory"
}

fun index_path() {
    memory_dir() ++ "/MEMORY.md"
}

fun memory_file_path(slug) {
    memory_dir() ++ "/" ++ slug ++ ".md"
}

fun embed_db_path() {
    memory_dir() ++ "/embed.db"
}

# Initialize: create the directory if it doesn't exist. Returns an
# opaque token used by callers (kept for API parity with the old
# table-based version).
fun load() {
    file_mkdir(memory_dir())
    # Migrate the old flat JSON file if it still exists.
    migrate_legacy()
    'memory_ready'
}

# ------------------------------------------------------------
# Legacy migration — convert ~/.swarm-code/memories.json into
# one crumbs file per entry, then delete the old file.
# ------------------------------------------------------------
fun migrate_legacy() {
    legacy = getenv("HOME") ++ "/.swarm-code/memories.json"
    if (file_exists(legacy) == 'true') {
        content = file_read(legacy)
        if (content != nil) {
            m = json_decode(string_trim(content))
            if (m != nil) {
                keys = map_keys(m)
                vals = map_values(m)
                migrate_entries(keys, vals)
                # Move legacy file aside so it's clearly one-shot.
                shell("mv " ++ Util.shell_q(legacy) ++ " " ++ Util.shell_q(legacy ++ ".migrated"))
            }
        }
    }
    'ok'
}

fun migrate_entries(keys, vals) {
    if (length(keys) == 0) { 'ok' }
    else {
        k = to_string(hd(keys))
        v = to_string(hd(vals))
        # Pass empty opts map — no embed key available during migration.
        save(k, "migrated from legacy memories.json", "user", v, map_new())
        migrate_entries(tl(keys), tl(vals))
    }
}

# ------------------------------------------------------------
# Save — write a memory file + update the MEMORY.md index.
# ------------------------------------------------------------
# name        — short human title (also used to derive the slug)
# description — one-line hook used for retrieval decisions
# type_       — "user" | "feedback" | "project" | "reference"
# content     — the body of the memory (markdown allowed)
# opts        — agent opts map; used for best-effort embedding on save
fun save(name, description, type_, content, opts) {
    slug = slugify(to_string(name))
    file_path = memory_file_path(slug)
    body =
        "---\n" ++
        "name: " ++ to_string(name) ++ "\n" ++
        "description: " ++ to_string(description) ++ "\n" ++
        "type: " ++ to_string(type_) ++ "\n" ++
        "---\n\n" ++
        to_string(content) ++ "\n"
    rc = file_write(file_path, body)
    if (rc == 'ok') {
        update_index(slug, to_string(name), to_string(description), to_string(type_))
        # Best-effort embed on save — fire-and-forget.
        # If embed opts are missing or the network call fails, the memory
        # is still saved correctly; we just won't have a vector for it yet.
        embed_ep = map_get(opts, 'embed_endpoint')
        if (embed_ep != nil && embed_ep != "") {
            embed_text = to_string(description) ++ " " ++ to_string(content)
            vec = MemVec.embed_text(embed_text, opts)
            if (vec != nil) {
                db = MemVec.open(embed_db_path())
                MemVec.upsert(db, slug, vec)
                MemVec.close(db)
            }
        }
        "ok: saved " ++ slug
    } else {
        "error: could not write " ++ file_path
    }
}

# Idempotent index update: rebuild MEMORY.md by scanning the directory.
# Simpler than append-and-dedup and guarantees the index matches reality.
fun update_index(new_slug, new_name, new_desc, new_type) {
    rebuild_index()
}

# Rebuild MEMORY.md from scratch by reading every *.md file in memory_dir
# (except MEMORY.md itself), pulling their frontmatter, and writing a
# fresh index sorted newest-first.
fun rebuild_index() {
    dir = memory_dir()
    header =
        "# Swarm Memory Index\n\n" ++
        "Auto-maintained pointer list for ~/.swarm-code/memory/. Each line\n" ++
        "links to a topic file with full content.\n\n"
    # file_list is an in-process readdir — was shell("ls -t ... | grep -v")
    # which cost a full second per call (swarmrt's shell() polls every 1s).
    # We lose mtime-sort, but the index is short and frontmatter order is
    # what readers scan anyway.
    if (file_exists(dir) == 'false') {
        file_write(index_path(), header ++ "(no memories yet)\n")
        'ok'
    } else {
        entries = file_list(dir)
        paths = collect_md_paths(entries, dir, [])
        body = if (length(paths) == 0) { "(no memories yet)\n" }
               else { render_index_lines(paths, "") }
        file_write(index_path(), header ++ body)
        'ok'
    }
}

# Filter file_list entries to memory crumb paths — *.md, excluding the
# auto-generated MEMORY.md index itself.
fun collect_md_paths(entries, dir, acc) {
    if (length(entries) == 0) { acc }
    else {
        e = hd(entries)
        new_acc = if (string_ends_with(e, ".md") == 'true' && e != "MEMORY.md") {
            list_append(acc, dir ++ "/" ++ e)
        } else { acc }
        collect_md_paths(tl(entries), dir, new_acc)
    }
}

fun render_index_lines(paths, acc) {
    if (length(paths) == 0) { acc }
    else {
        p = hd(paths)
        entry = one_index_line(p)
        render_index_lines(tl(paths), acc ++ entry)
    }
}

# Read frontmatter from a memory file and emit one-line pointer:
#   - [name](file.md) — description  (type: foo)
fun one_index_line(path) {
    fname = basename_of(path)
    slug = strip_md_ext(fname)
    content = file_read(path)
    if (content == nil) { "" }
    else {
        fm = parse_frontmatter(content)
        name = map_get(fm, "name")
        desc = map_get(fm, "description")
        type_ = map_get(fm, "type")
        n = if (name == nil) { slug } else { to_string(name) }
        d = if (desc == nil) { "(no description)" } else { to_string(desc) }
        t = if (type_ == nil) { "user" } else { to_string(type_) }
        "- [" ++ n ++ "](" ++ fname ++ ") — " ++ d ++ "  `" ++ t ++ "`\n"
    }
}

# Extract basename from a path (last component after /).
fun basename_of(path) {
    parts = string_split(path, "/")
    last_item(parts, "")
}

fun last_item(lst, fallback) {
    if (length(lst) == 0) { fallback }
    else {
        if (length(tl(lst)) == 0) { hd(lst) }
        else { last_item(tl(lst), fallback) }
    }
}

fun strip_md_ext(fname) {
    if (string_ends_with(fname, ".md") == 'true') {
        string_sub(fname, 0, string_length(fname) - 3)
    } else { fname }
}

# ------------------------------------------------------------
# Frontmatter parser — YAML-ish, single-line values only.
# ------------------------------------------------------------
# Handles files that start with `---\n...fields...\n---\n`.
# Returns a map of field name (atom) → value (string).
fun parse_frontmatter(content) {
    if (string_starts_with(content, "---\n") == 'false') {
        map_new()
    } else {
        rest = string_sub(content, 4, string_length(content) - 4)
        # Find the closing `---\n`.
        end_idx = find_substring(rest, "\n---")
        if (end_idx < 0) { map_new() }
        else {
            header = string_sub(rest, 0, end_idx)
            parse_fm_lines(string_split(header, "\n"), map_new())
        }
    }
}

fun parse_fm_lines(lines, acc) {
    if (length(lines) == 0) { acc }
    else {
        line = hd(lines)
        colon_idx = find_substring(line, ":")
        new_acc = if (colon_idx <= 0) { acc }
        else {
            key_s = string_trim(string_sub(line, 0, colon_idx))
            val_s = string_trim(string_sub(line, colon_idx + 1,
                                           string_length(line) - colon_idx - 1))
            map_put(acc, key_s, val_s)
        }
        parse_fm_lines(tl(lines), new_acc)
    }
}

# Return index of `needle` in `haystack`, or -1 if not found.
# Simple scan — fine for small frontmatter strings.
fun find_substring(haystack, needle) {
    find_loop(haystack, needle, 0, string_length(haystack), string_length(needle))
}

fun find_loop(h, n, i, hl, nl) {
    if (i + nl > hl) { 0 - 1 }
    else {
        slice = string_sub(h, i, nl)
        if (slice == n) { i }
        else { find_loop(h, n, i + 1, hl, nl) }
    }
}

# Convert a human name into a filesystem-safe slug.
#   "User's ADHD workflow" → "user_s_adhd_workflow"
fun slugify(name) {
    lowered = string_lower(name)
    # Keep alnum + underscore; replace everything else with underscore.
    cleaned = slug_clean(lowered, "", 0)
    # Collapse runs of underscores.
    collapse_underscores(cleaned, "", 'false')
}

fun slug_clean(s, acc, i) {
    if (i >= string_length(s)) { acc }
    else {
        ch = string_sub(s, i, 1)
        safe = if (is_slug_char(ch) == 'true') { ch } else { "_" }
        slug_clean(s, acc ++ safe, i + 1)
    }
}

fun is_slug_char(ch) {
    if (ch == "a") { 'true' } else { if (ch == "b") { 'true' }
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
    else { if (ch == "0") { 'true' } else { if (ch == "1") { 'true' }
    else { if (ch == "2") { 'true' } else { if (ch == "3") { 'true' }
    else { if (ch == "4") { 'true' } else { if (ch == "5") { 'true' }
    else { if (ch == "6") { 'true' } else { if (ch == "7") { 'true' }
    else { if (ch == "8") { 'true' } else { if (ch == "9") { 'true' }
    else { 'false' }}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}
}

fun collapse_underscores(s, acc, prev_under) {
    if (string_length(s) == 0) {
        # Trim trailing underscore.
        if (string_ends_with(acc, "_") == 'true') {
            string_sub(acc, 0, string_length(acc) - 1)
        } else { acc }
    } else {
        ch = string_sub(s, 0, 1)
        rest = string_sub(s, 1, string_length(s) - 1)
        if (ch == "_") {
            if (prev_under == 'true') {
                collapse_underscores(rest, acc, 'true')
            } else {
                collapse_underscores(rest, acc ++ ch, 'true')
            }
        } else {
            collapse_underscores(rest, acc ++ ch, 'false')
        }
    }
}

# ------------------------------------------------------------
# Recall — read one or more memory files matching a query.
#
# When embed opts are present and Embed.create succeeds, performs
# semantic (vector cosine) search over embed.db and returns the
# top-5 matching memory file contents joined by a separator.
#
# Falls back to exact slug lookup when:
#   a) embed_endpoint is nil / empty (embed not configured), OR
#   b) MemVec.embed_text returns nil (network failure, bad key), OR
#   c) No vectors are stored yet (empty embed.db).
#
# The fallback is the original behaviour: slugify the query, read
# the single file at that slug path (nil if not found).
# ------------------------------------------------------------
fun recall(query, opts) {
    embed_ep = map_get(opts, 'embed_endpoint')
    if (embed_ep == nil || embed_ep == "") {
        recall_by_slug(query)
    } else {
        q_vec = MemVec.embed_text(to_string(query), opts)
        if (q_vec == nil) {
            recall_by_slug(query)
        } else {
            db = MemVec.open(embed_db_path())
            results = MemVec.search_top_k(db, q_vec, 5)
            MemVec.close(db)
            if (length(results) == 0) {
                recall_by_slug(query)
            } else {
                recall_semantic_results(results)
            }
        }
    }
}

# Direct slug-based lookup — original recall behaviour.
fun recall_by_slug(slug_or_name) {
    slug = slugify(to_string(slug_or_name))
    fp = memory_file_path(slug)
    if (file_exists(fp) == 'false') {
        nil
    } else {
        file_read(fp)
    }
}

# Read each file from the semantic hit list and join their contents.
# Returns a formatted multi-result string, or nil if no files could be read.
fun recall_semantic_results(hits) {
    contents = collect_hit_contents(hits, [])
    if (length(contents) == 0) { nil }
    else { join_memory_blocks(contents, "") }
}

fun collect_hit_contents(hits, acc) {
    if (length(hits) == 0) { acc }
    else {
        h = hd(hits)
        slug = to_string(map_get(h, 'slug'))
        fp = memory_file_path(slug)
        content = if (file_exists(fp) == 'false') { nil } else { file_read(fp) }
        new_acc = if (content == nil) { acc }
                  else { list_append(acc, content) }
        collect_hit_contents(tl(hits), new_acc)
    }
}

fun join_memory_blocks(blocks, acc) {
    if (length(blocks) == 0) { acc }
    else {
        sep = if (string_length(acc) == 0) { "" } else { "\n\n---\n\n" }
        join_memory_blocks(tl(blocks), acc ++ sep ++ hd(blocks))
    }
}

# ------------------------------------------------------------
# List — return the MEMORY.md index contents (regenerated fresh).
# ------------------------------------------------------------
fun list_index() {
    rebuild_index()
    ip = index_path()
    if (file_exists(ip) == 'false') { "" }
    else {
        content = file_read(ip)
        if (content == nil) { "" } else { content }
    }
}

# ------------------------------------------------------------
# Forget — delete a memory file and refresh the index.
# ------------------------------------------------------------
fun forget(slug_or_name) {
    slug = slugify(to_string(slug_or_name))
    fp = memory_file_path(slug)
    if (file_exists(fp) == 'false') {
        "error: no memory named '" ++ slug ++ "'"
    } else {
        rc = file_delete(fp)
        if (rc == 'ok') {
            rebuild_index()
            "ok: forgot " ++ slug
        } else {
            "error: could not delete " ++ fp
        }
    }
}

# ------------------------------------------------------------
# embed_missing — backfill embed.db for any .md files that do
# not yet have a vector. Called manually (/memory reindex) or
# from a future startup hook. Returns the count of newly embedded
# memories.
#
# opts  — agent opts map (needs embed_endpoint / embed_api_key /
#          embed_model to be set, otherwise returns 0 immediately).
# ------------------------------------------------------------
fun embed_missing(opts) {
    embed_ep = map_get(opts, 'embed_endpoint')
    if (embed_ep == nil || embed_ep == "") { 0 }
    else {
        dir = memory_dir()
        entries = file_list(dir)
        slugs = collect_md_slugs(entries, [])
        db = MemVec.open(embed_db_path())
        missing = MemVec.list_slugs_without_vector(db, slugs)
        count = embed_missing_loop(db, missing, opts, 0)
        MemVec.close(db)
        count
    }
}

# Collect slugs (filename sans .md, excluding MEMORY.md) from file_list.
fun collect_md_slugs(entries, acc) {
    if (length(entries) == 0) { acc }
    else {
        e = hd(entries)
        new_acc = if (string_ends_with(e, ".md") == 'true' && e != "MEMORY.md") {
            list_append(acc, strip_md_ext(e))
        } else { acc }
        collect_md_slugs(tl(entries), new_acc)
    }
}

fun embed_missing_loop(db, slugs, opts, count) {
    if (length(slugs) == 0) { count }
    else {
        slug = hd(slugs)
        fp = memory_file_path(slug)
        content = if (file_exists(fp) == 'false') { nil } else { file_read(fp) }
        new_count = if (content == nil) { count }
        else {
            vec = MemVec.embed_text(content, opts)
            if (vec == nil) { count }
            else {
                MemVec.upsert(db, slug, vec)
                count + 1
            }
        }
        embed_missing_loop(db, tl(slugs), opts, new_count)
    }
}

# ------------------------------------------------------------
# System prompt section — injected at startup so every session
# starts with the full memory index visible to the model.
# ------------------------------------------------------------
fun as_prompt_section(token) {
    # Ensure index is fresh even if the directory was edited externally.
    rebuild_index()
    ip = index_path()
    if (file_exists(ip) == 'false') { "" }
    else {
        content = file_read(ip)
        if (content == nil) { "" }
        else {
            trimmed = string_trim(content)
            if (string_length(trimmed) == 0) { "" }
            else {
                "\n\n=== LONG-TERM MEMORY (" ++ memory_dir() ++ ") ===\n" ++
                "Facts remembered across sessions. Below is the index of\n" ++
                "every memory you have saved. Use `recall <slug>` to read\n" ++
                "the full content of any entry. Save new ones with the\n" ++
                "`remember` tool (see tool docs for schema). Forget stale\n" ++
                "entries with `forget <slug>`.\n\n" ++
                trimmed ++ "\n"
            }
        }
    }
}
