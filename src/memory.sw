module Memory

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
    load, memory_dir, index_path, memory_file_path,
    save, recall, list_index, forget,
    as_prompt_section, slugify
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

# Initialize: create the directory if it doesn't exist. Returns an
# opaque token used by callers (kept for API parity with the old
# table-based version).
fun load() {
    shell("mkdir -p " ++ memory_dir())
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
                shell("mv " ++ legacy ++ " " ++ legacy ++ ".migrated")
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
        save(k, "migrated from legacy memories.json", "user", v)
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
fun save(name, description, type_, content) {
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
    # List all .md files except MEMORY.md, newest first (ls -t).
    result = shell("ls -t " ++ dir ++ "/*.md 2>/dev/null | grep -v '/MEMORY.md$'")
    code = elem(result, 0)
    out = elem(result, 1)
    header =
        "# Swarm Memory Index\n\n" ++
        "Auto-maintained pointer list for ~/.swarm-code/memory/. Each line\n" ++
        "links to a topic file with full content. Newest first.\n\n"
    body = if (code == 0 && string_length(string_trim(out)) > 0) {
        lines = string_split(string_trim(out), "\n")
        render_index_lines(lines, "")
    } else { "(no memories yet)\n" }
    file_write(index_path(), header ++ body)
    'ok'
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
# Recall — read one memory file by slug or by name.
# ------------------------------------------------------------
fun recall(slug_or_name) {
    slug = slugify(to_string(slug_or_name))
    fp = memory_file_path(slug)
    if (file_exists(fp) == 'false') {
        nil
    } else {
        file_read(fp)
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
