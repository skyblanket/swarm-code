module Skills

# ============================================================
# Skills — Hermes-style reusable procedures
# ============================================================
#
# Layout on disk:
#
#   ~/.swarm-code/skills/
#     SKILLS.md              — one-line pointer index, always loaded
#     deploy-mally-otp/
#       SKILL.md             — frontmatter + instructions (markdown)
#       deploy.sh            — optional helper script the skill calls
#     ship-openear-dmg/
#       SKILL.md
#     ...
#
# Each SKILL.md is a small markdown document:
#
#   ---
#   name: Deploy mally-otp
#   description: Build + upload mally-otp burrito binaries
#   triggers: deploy mally, ship mally-otp, push otp release
#   ---
#
#   When the user asks to deploy mally-otp:
#   1. cd ~/mally-otp
#   2. ./scripts/deploy.sh
#   3. Verify with `curl https://api.mally.fyi/...`
#
# Why a directory per skill: skills often need helper files
# (scripts, configs, prompts). Co-locating them with SKILL.md
# keeps the unit movable — share / fork by copying one dir.
#
# Why a flat top-level index (SKILLS.md): the index is what
# lands in the system prompt at session start, so it must
# render small. SKILL.md bodies are pulled lazily via the
# recall_skill tool when the agent decides a skill matches.

import Memory

export [
    load, skills_dir, index_path, skill_dir, skill_file_path,
    save, recall, list_index, forget,
    as_prompt_section, slugify
]

fun skills_dir()             { getenv("HOME") ++ "/.swarm-code/skills" }
fun index_path()             { skills_dir() ++ "/SKILLS.md" }
fun skill_dir(slug)          { skills_dir() ++ "/" ++ slug }
fun skill_file_path(slug)    { skill_dir(slug) ++ "/SKILL.md" }

fun load() {
    shell("mkdir -p " ++ skills_dir())
    'skills_ready'
}

# ------------------------------------------------------------
# Save — create the skill directory + write SKILL.md + reindex.
# Idempotent: re-saving by the same name overwrites cleanly.
# ------------------------------------------------------------
fun save(name, description, triggers, instructions) {
    slug = slugify(to_string(name))
    dir = skill_dir(slug)
    shell("mkdir -p " ++ dir)
    body =
        "---\n" ++
        "name: " ++ to_string(name) ++ "\n" ++
        "description: " ++ to_string(description) ++ "\n" ++
        "triggers: " ++ to_string(triggers) ++ "\n" ++
        "---\n\n" ++
        to_string(instructions) ++ "\n"
    rc = file_write(skill_file_path(slug), body)
    if (rc == 'ok') {
        rebuild_index()
        "ok: saved skill " ++ slug
    } else {
        "error: could not write " ++ skill_file_path(slug)
    }
}

fun recall(slug) {
    p = skill_file_path(slug)
    if (file_exists(p) == 'false') {
        "error: no skill named '" ++ slug ++ "' — see /skills"
    } else {
        c = file_read(p)
        if (c == nil) { "error: could not read " ++ p } else { c }
    }
}

fun list_index() {
    rebuild_index()
    ip = index_path()
    if (file_exists(ip) == 'false') { "(no skills yet)" }
    else {
        c = file_read(ip)
        if (c == nil) { "(no skills yet)" } else { c }
    }
}

fun forget(slug) {
    d = skill_dir(slug)
    if (file_exists(d ++ "/SKILL.md") == 'false') {
        "error: no skill named '" ++ slug ++ "'"
    } else {
        result = shell("rm -rf " ++ shell_q(d))
        if (elem(result, 0) == 0) {
            rebuild_index()
            "ok: forgot " ++ slug
        } else {
            "error: could not remove " ++ d
        }
    }
}

# ------------------------------------------------------------
# Index — rebuilt from filesystem on save/forget/load.
# ------------------------------------------------------------
fun rebuild_index() {
    dir = skills_dir()
    # List all SKILL.md files inside skill subdirs, newest-first.
    result = shell("ls -t " ++ dir ++ "/*/SKILL.md 2>/dev/null")
    code = elem(result, 0)
    out = elem(result, 1)
    header =
        "# Swarm Skills Index\n\n" ++
        "Auto-maintained list of skills in ~/.swarm-code/skills/.\n" ++
        "Each skill is a directory with SKILL.md + optional scripts.\n\n"
    body = if (code == 0 && string_length(string_trim(out)) > 0) {
        lines = string_split(string_trim(out), "\n")
        render_index_lines(lines, "")
    } else { "(no skills yet)\n" }
    file_write(index_path(), header ++ body)
    'ok'
}

fun render_index_lines(paths, acc) {
    if (length(paths) == 0) { acc }
    else { render_index_lines(tl(paths), acc ++ one_index_line(hd(paths))) }
}

# Path looks like: /Users/sky/.swarm-code/skills/SLUG/SKILL.md
# We want the SLUG segment — i.e. the dirname's basename.
fun one_index_line(path) {
    parts = string_split(path, "/")
    slug = slug_from_parts(parts)
    content = file_read(path)
    if (content == nil) { "" }
    else {
        fm = Memory.parse_frontmatter(content)
        name_v = map_get(fm, "name")
        desc_v = map_get(fm, "description")
        trig_v = map_get(fm, "triggers")
        name = if (name_v == nil) { slug } else { to_string(name_v) }
        desc = if (desc_v == nil) { "(no description)" } else { to_string(desc_v) }
        trig = if (trig_v == nil || string_length(to_string(trig_v)) == 0) { "" }
               else { "  *triggers:* " ++ to_string(trig_v) }
        "- **" ++ slug ++ "** — " ++ name ++ ": " ++ desc ++ trig ++ "\n"
    }
}

# Pull the second-to-last path component (the slug dir).
fun slug_from_parts(parts) {
    n = length(parts)
    if (n < 2) { "?" }
    else { nth_from_end(parts, 2) }
}

fun nth_from_end(lst, n) {
    idx = length(lst) - n
    if (idx < 0) { hd(lst) }
    else { nth_loop(lst, idx) }
}

fun nth_loop(lst, idx) {
    if (idx == 0) { hd(lst) }
    else { nth_loop(tl(lst), idx - 1) }
}

# Slugify a human name. Defer to Memory.slugify so the rules
# stay consistent across crumbs.
fun slugify(s) { Memory.slugify(s) }

fun shell_q(s) {
    safe = string_replace(s, "'", "'\\''")
    "'" ++ safe ++ "'"
}

# ------------------------------------------------------------
# System-prompt section — injected at session start (like Memory).
# The agent sees the INDEX (cheap), then pulls full SKILL.md
# bodies on demand via the recall_skill tool.
# ------------------------------------------------------------
fun as_prompt_section(token) {
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
                "\n\n=== SKILLS (" ++ skills_dir() ++ ") ===\n" ++
                "Reusable procedures you have learned. Each skill is a small\n" ++
                "playbook for a recurring task — invoke when you see a matching\n" ++
                "trigger phrase in the user's request. Use `recall_skill <slug>`\n" ++
                "to read a skill's full instructions; save new ones with\n" ++
                "`learn_skill`.\n\n" ++
                trimmed ++ "\n"
            }
        }
    }
}
