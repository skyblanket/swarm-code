module Config

import Util

# ============================================================
# Config — settings.json, SWARM.md, permissions, hooks
# ============================================================
#
# Settings are loaded from two locations and merged:
#   1. $HOME/.swarm-code/settings.json          (user-global)
#   2. ./.swarm-code.json                       (project-local, overrides)
#
# Project context is loaded from the first that exists:
#   1. ./SWARM.md                               (swarm-code's preferred name)
#   2. ./CLAUDE.md                              (fallback, most repos have one)
#
# Example settings.json:
# {
#   "model": "google/gemma-4-31B-it",
#   "endpoint": "http://sushi:8000",
#   "permissions": {
#     "bash": "ask",
#     "write": "allow",
#     "edit": "allow",
#     "read": "allow"
#   },
#   "hooks": {
#     "PreToolUse": [
#       {"matcher": "bash", "command": "echo pre"}
#     ],
#     "PostToolUse": [...]
#   }
# }

export [load, load_project_context, check_permission, run_hooks, is_dangerous_bash, is_hardline_bash,
        llm_timeout_ms]

# ------------------------------------------------------------
# load settings — merged map from user + project config files
# ------------------------------------------------------------
fun load() {
    user_path = getenv("HOME") ++ "/.swarm-code/settings.json"
    project_path = "./.swarm-code.json"
    user_settings = load_one(user_path)
    project_settings = load_one(project_path)
    map_merge(user_settings, project_settings)
}

fun load_one(path) {
    if (file_exists(path) == 'false') {
        map_new()
    } else {
        file_content = file_read(path)
        if (file_content == nil) {
            map_new()
        } else {
            decoded = json_decode(file_content)
            if (decoded == nil) { map_new() } else { decoded }
        }
    }
}

# ------------------------------------------------------------
# llm_timeout_ms — inactivity window (ms) for the worker-routed LLM
# stream (llm.sw stream_call). If no stream message (chunk / reason /
# done / result) arrives within this window the in-flight call is
# treated as a TRANSIENT failure (hung connection) so the normal
# retry/backoff engages — closing the "a hung connection blocks the
# turn forever" hole. A coarse total deadline of 3x this value bounds
# even a trickling-but-never-finishing stream.
#
# Priority: SWARM_CODE_LLM_TIMEOUT_MS env → settings.json
# "llm_timeout_ms" → 300000 (5 minutes) default.
# ------------------------------------------------------------
fun llm_timeout_ms(opts) {
    env = getenv("SWARM_CODE_LLM_TIMEOUT_MS")
    env_n = if (env == nil) { 0 - 1 } else { parse_pos_int_cfg(to_string(env), 0, 0, 'false') }
    if (env_n > 0) { env_n }
    else {
        settings = map_get(opts, 'settings')
        sv = if (settings == nil) { nil } else { map_get(settings, 'llm_timeout_ms') }
        sn = if (sv == nil) { 0 - 1 } else { parse_pos_int_cfg(to_string(sv), 0, 0, 'false') }
        if (sn > 0) { sn } else { 300000 }
    }
}

# Positive-int parser (same pattern as agent.sw parse_budget_env /
# llm.sw parse_positive_int_local — kept local so config.sw stays
# dependency-free). Returns -1 when the string holds no leading digits.
fun parse_pos_int_cfg(s, i, acc, saw_digit) {
    if (i >= string_length(s)) {
        if (saw_digit == 'true') { acc } else { 0 - 1 }
    } else {
        ch = string_sub(s, i, 1)
        d = if (ch == "0") { 0 } else { if (ch == "1") { 1 }
            else { if (ch == "2") { 2 } else { if (ch == "3") { 3 }
            else { if (ch == "4") { 4 } else { if (ch == "5") { 5 }
            else { if (ch == "6") { 6 } else { if (ch == "7") { 7 }
            else { if (ch == "8") { 8 } else { if (ch == "9") { 9 }
            else { 0 - 1 }}}}}}}}}}
        if (d < 0) {
            if (saw_digit == 'true') { acc } else { 0 - 1 }
        } else {
            parse_pos_int_cfg(s, i + 1, acc * 10 + d, 'true')
        }
    }
}

# ------------------------------------------------------------
# load SWARM.md or CLAUDE.md from cwd — returns "" if neither exists
# ------------------------------------------------------------
fun load_project_context() {
    if (file_exists("./SWARM.md") == 'true') {
        swarm_md = file_read("./SWARM.md")
        if (swarm_md == nil) { "" } else { swarm_md }
    } else {
        if (file_exists("./CLAUDE.md") == 'true') {
            claude_md = file_read("./CLAUDE.md")
            if (claude_md == nil) { "" } else { claude_md }
        } else {
            ""
        }
    }
}

# ------------------------------------------------------------
# Permissions — decide whether a tool call should run.
# Returns an atom: 'allow', 'deny', or 'ask'.
#
# Policy (updated):
#   1. Default-allow for every BUILT-IN tool. The user explicitly asked
#      for "all allowed by default" — prompting on every bash/write/edit
#      was breaking flow during tool test runs. The one exception is MCP
#      tools (mcp__*): being external and unvetted, they default to 'ask'
#      so the user is prompted on first use (see default_permission).
#   2. settings.permissions[tool_name] in settings.json can downgrade
#      a specific tool to 'ask' or 'deny' if the user wants tighter
#      control on one tool (e.g. "bash": "ask").
#   3. The dangerous-bash hard gate still fires regardless. Commands
#      that look like `rm -rf`, `sudo`, `curl | sh`, `mkfs`, force
#      push, or hard resets still prompt even in default-allow mode.
#      We are not giving a model root access to the box.
# ------------------------------------------------------------
fun check_permission(tool_name, args, opts) {
    # HARDLINE: unbypassable deny for catastrophic patterns (mkfs, dd
    # to disk, shutdown/reboot, fork bomb, rm -rf /*). Fires BEFORE
    # any settings/env lookup so SWARM_CODE_ALLOW_DANGEROUS=1 cannot
    # turn it off. See is_hardline_bash for the pattern list.
    if (tool_name == 'bash' && is_hardline_bash(args) == 'true') {
        'deny'
    }
    else {
        settings = map_get(opts, 'settings')
        perms = if (settings == nil) { nil } else { map_get(settings, 'permissions') }

        # settings.json is decoded with atom keys, so pass tool_name directly.
        configured = if (perms == nil) {
            nil
        } else {
            map_get(perms, tool_name)
        }

        decision = if (configured != nil) {
            string_to_perm(configured)
        } else {
            default_permission(tool_name)
        }

        # Hard-gate dangerous bash commands regardless of config.
        # Headless converts 'ask' to 'allow' (agent.resolve_permission),
        # so unattended children (/flows fan-out sets
        # SWARM_CODE_DENY_DANGEROUS=1) turn this gate into a hard deny
        # instead of silently auto-approving.
        if (tool_name == 'bash' && is_dangerous_bash(args) == 'true') {
            if (getenv("SWARM_CODE_DENY_DANGEROUS") == "1") { 'deny' } else { 'ask' }
        } else {
            decision
        }
    }
}

fun string_to_perm(s) {
    if (s == "allow") { 'allow' }
    else { if (s == "deny") { 'deny' }
    else { 'ask' }}
}

# Built-in tools default to 'allow' (see the check_permission comment
# block above). MCP tools (mcp__server__tool) default to 'ask' instead:
# they are external and unvetted, and unlike `bash` they get no
# dangerous-pattern gate. The session permission cache means this is
# one prompt per MCP tool, not per call; a user can still pre-authorise
# one via the settings.json permissions map
# (e.g. "mcp__github__create_issue": "allow").
fun default_permission(tool_name) {
    if (string_starts_with(to_string(tool_name), "mcp__") == 'true') { 'ask' }
    else { 'allow' }
}

# Return 'true' ONLY for truly catastrophic, unambiguous patterns.
# Scoped down from a broad "destructive commands" net because the old
# version was flagging perfectly normal dev workflows like
# `rm -rf ./build-dir`, `git push --force` on feature branches, and
# `git reset --hard HEAD~1`. The model is a coding assistant; those
# are its daily bread.
#
# What still trips the gate (after much narrowing):
#   * rm -rf targeting `/` or `~` or `$HOME` literally
#   * mkfs (formatting a block device)
#   * dd if=... writing to /dev/disk, /dev/sd, /dev/nvme, /dev/rdisk
#   * sudo (privilege escalation is always worth a beat)
#
# You can fully disable even this minimal gate by exporting
# SWARM_CODE_ALLOW_DANGEROUS=1 before launching swarm-code. Everything
# runs, nothing prompts. YOLO mode.
fun is_dangerous_bash(args) {
    bypass = getenv("SWARM_CODE_ALLOW_DANGEROUS")
    if (bypass == "1") { 'false' }
    else {
        cmd = map_get(args, 'command')
        if (cmd == nil) { 'false' }
        else {
            # rm targeting the filesystem root or user home literally.
            # We look for "rm " ++ anything ++ " /" at word boundary
            # rather than the broad "rm -rf" string match. A simple
            # conservative approach: flag only the specific dangerous
            # literal suffixes.
            if (string_contains(cmd, "rm -rf /") == 'true' &&
                string_contains(cmd, "rm -rf /tmp") == 'false' &&
                string_contains(cmd, "rm -rf /var/") == 'false' &&
                string_contains(cmd, "rm -rf /Users/") == 'false' &&
                string_contains(cmd, "rm -rf /home/") == 'false' &&
                string_contains(cmd, "rm -rf /opt/") == 'false') { 'true' }
            else { if (string_contains(cmd, "rm -rf ~") == 'true') { 'true' }
            else { if (string_contains(cmd, "rm -rf $HOME") == 'true') { 'true' }
            else { if (string_contains(cmd, "sudo ") == 'true') { 'true' }
            else { if (string_contains(cmd, "mkfs") == 'true') { 'true' }
            else { if (string_contains(cmd, "dd if=") == 'true' &&
                        string_contains(cmd, "of=/dev/") == 'true') { 'true' }
            else { 'false' }}}}}}
        }
    }
}

# ------------------------------------------------------------
# HARDLINE blocklist — UNBYPASSABLE bash patterns.
# ------------------------------------------------------------
# Unlike is_dangerous_bash, this CANNOT be turned off with
# SWARM_CODE_ALLOW_DANGEROUS=1. If your agent is asking to mkfs a
# disk or reboot the box, no env var should let it through.
#
# Categories:
#   * Filesystem destruction: mkfs, mkswap
#   * Disk wipe: dd if=... of=/dev/{sd,nvme,disk,rdisk}
#   * System halt: shutdown, reboot, halt, poweroff, init 0, init 6
#   * Filesystem lockout: chmod 000 /, chown -R 0:0 /
#   * Fork bomb literal: :(){:|:&};:
#   * Whole-disk rm: rm -rf /*
# ------------------------------------------------------------
fun is_hardline_bash(args) {
    cmd = map_get(args, 'command')
    if (cmd == nil) { 'false' }
    else {
        s = to_string(cmd)
        # Filesystem destruction
        if (string_contains(s, "mkfs") == 'true') { 'true' }
        else { if (string_contains(s, "mkswap") == 'true') { 'true' }
        # dd writing to a raw disk node
        else { if (string_contains(s, "dd if=") == 'true' &&
                   string_contains(s, "of=/dev/sd") == 'true') { 'true' }
        else { if (string_contains(s, "dd if=") == 'true' &&
                   string_contains(s, "of=/dev/nvme") == 'true') { 'true' }
        else { if (string_contains(s, "dd if=") == 'true' &&
                   string_contains(s, "of=/dev/disk") == 'true') { 'true' }
        else { if (string_contains(s, "dd if=") == 'true' &&
                   string_contains(s, "of=/dev/rdisk") == 'true') { 'true' }
        # System halt — matched as whole command words (not bare substrings),
        # so `cat asphalt_survey.csv` / `vim shutdown_handler.py` are NOT
        # blocked while `shutdown -h now`, `/sbin/reboot`, `poweroff` still are.
        else { if (contains_command_word(s, "shutdown") == 'true') { 'true' }
        else { if (contains_command_word(s, "reboot") == 'true') { 'true' }
        else { if (contains_command_word(s, "halt") == 'true') { 'true' }
        else { if (contains_command_word(s, "poweroff") == 'true') { 'true' }
        else { if (contains_command_word(s, "init 0") == 'true') { 'true' }
        else { if (contains_command_word(s, "init 6") == 'true') { 'true' }
        # telinit N is the SysV alias (telinit 0 halts, telinit 6 reboots) —
        # word-boundary "init 0" misses it ("init" preceded by 'l'), so match
        # the verb directly. Keep this as long as "init 0"/"init 6" are blocked.
        else { if (contains_command_word(s, "telinit") == 'true') { 'true' }
        # Filesystem lockout
        else { if (string_contains(s, "chmod 000 /") == 'true') { 'true' }
        else { if (string_contains(s, "chown -R 0:0 /") == 'true') { 'true' }
        # Fork bomb
        else { if (string_contains(s, ":(){:|:&};:") == 'true') { 'true' }
        # Whole-disk wipe
        else { if (string_contains(s, "rm -rf /*") == 'true') { 'true' }
        else { 'false' }}}}}}}}}}}}}}}}}
    }
}

# Whole-word match for a catastrophic verb: the word must be bounded by a
# non-identifier char (or string edge) on both sides, so it isn't matched as
# a substring of a larger filename/identifier (asphalt, rebooter,
# shutdown_handler). Over-blocks rare cases like `cat shutdown.sh` — the safe
# direction for an unbypassable floor (never under-blocks a real `shutdown`).
fun contains_command_word(s, word) {
    cw_scan(s, word, string_length(word), string_length(s), 0)
}

fun cw_scan(s, word, wlen, slen, i) {
    if (i + wlen > slen) { 'false' }
    else {
        if (string_sub(s, i, wlen) == word) {
            prev_ch = cw_char_at(s, i - 1, slen)
            next_ch = cw_char_at(s, i + wlen, slen)
            if (cw_boundary(prev_ch) == 'true' && cw_boundary(next_ch) == 'true') { 'true' }
            else { cw_scan(s, word, wlen, slen, i + 1) }
        } else { cw_scan(s, word, wlen, slen, i + 1) }
    }
}

fun cw_char_at(s, idx, slen) {
    if (idx < 0 || idx >= slen) { "" }
    else { string_sub(s, idx, 1) }
}

fun cw_boundary(ch) {
    if (ch == "") { 'true' }
    else { if (cw_is_ident(ch) == 'true') { 'false' } else { 'true' }}
}

fun cw_is_ident(ch) {
    if ((ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")
        || (ch >= "0" && ch <= "9") || ch == "_") { 'true' }
    else { 'false' }
}

# ------------------------------------------------------------
# Hooks — shell commands configured in settings.json.
#
# Settings shape:
#   "hooks": {
#     "PreToolUse":  [ {"matcher": "bash", "command": "..."} ],
#     "PostToolUse": [ {"matcher": "edit|write", "command": "..."} ],
#     "UserPromptSubmit": [ {"command": "..."} ],
#     "Stop":            [ {"command": "..."} ]
#   }
#
# Matcher is a literal substring of the tool name, or "*" for all.
# Hooks receive context through environment variables set before shell():
#   SWARM_CODE_EVENT, SWARM_CODE_TOOL, SWARM_CODE_ARGS
#
# Returns 'ok' normally. Returns 'block' if any PreToolUse hook exited
# non-zero (blocking the tool call).
# ------------------------------------------------------------
fun run_hooks(event, tool_name, args_json, opts) {
    settings = map_get(opts, 'settings')
    if (settings == nil) { 'ok' }
    else {
        hooks = map_get(settings, 'hooks')
        if (hooks == nil) { 'ok' }
        else {
            # event is a string; hooks map has atom keys from json_decode —
            # try both. sw lacks a direct string→atom conversion in .sw, so we
            # attempt string key first then fall back by iterating all keys.
            event_hooks = map_get_either(hooks, event)
            if (event_hooks == nil) { 'ok' }
            else {
                run_matching_hooks(event_hooks, tool_name, args_json, event)
            }
        }
    }
}

# Look up a key in a map, trying string key first then comparing every
# key's string form. Handles the atom-vs-string mismatch from json_decode.
#
# NOTE: main.sw has a parallel pair — lookup_string_key/find_key_by_string —
# with the same logic plus an extra nil-map guard. Keep the core walk in sync
# if the algorithm changes; the nil guard lives there, not here.
fun map_get_either(m, key_string) {
    direct = map_get(m, key_string)
    if (direct != nil) {
        direct
    } else {
        find_by_string_key(map_keys(m), map_values(m), key_string)
    }
}

fun find_by_string_key(keys, values, target) {
    if (length(keys) == 0) {
        nil
    } else {
        k = hd(keys)
        if (to_string(k) == target) {
            hd(values)
        } else {
            find_by_string_key(tl(keys), tl(values), target)
        }
    }
}

fun run_matching_hooks(hooks_list, tool_name, args_json, event) {
    if (length(hooks_list) == 0) { 'ok' }
    else {
        hook = hd(hooks_list)
        matcher = map_get(hook, 'matcher')
        cmd = map_get(hook, 'command')
        if (cmd == nil) {
            run_matching_hooks(tl(hooks_list), tool_name, args_json, event)
        } else {
            if (matches(matcher, tool_name) == 'true') {
                result = run_hook_cmd(cmd, event, tool_name, args_json)
                if (result == 'block') {
                    'block'
                } else {
                    run_matching_hooks(tl(hooks_list), tool_name, args_json, event)
                }
            } else {
                run_matching_hooks(tl(hooks_list), tool_name, args_json, event)
            }
        }
    }
}

fun matches(matcher, tool_name) {
    if (matcher == nil) { 'true' }
    else {
        if (matcher == "*") { 'true' }
        else {
            # Two semantics, both supported via "either direction"
            # check:
            #   1. Pipe-alternation: matcher "bash|edit" matches tool
            #      "bash" because tool_name is a substring of matcher.
            #   2. Substring: matcher "ed" matches tool "edit" because
            #      matcher is a substring of tool_name.
            # The original code only did (1); the audit miscalled this
            # as a bug. Doing both makes the obvious matchers work
            # whichever way the user expected.
            m = to_string(matcher)
            t = to_string(tool_name)
            if (string_contains(m, t) == 'true') { 'true' }
            else { string_contains(t, m) }
        }
    }
}

# Run a single hook command. Wrap with env exports for context.
# If the command exits non-zero, treat as a block signal.
# Args JSON is exposed as SWARM_CODE_ARGS so hooks can inspect the
# tool payload (e.g. a `bash` hook that greps the command). Quoted
# with shell_q_local because args_json contains arbitrary JSON
# (including single quotes inside strings).
fun run_hook_cmd(cmd, event, tool_name, args_json) {
    args_safe = Util.shell_q(to_string(args_json))
    full = "export SWARM_CODE_EVENT=" ++ Util.shell_q(to_string(event)) ++ "; " ++
           "export SWARM_CODE_TOOL="  ++ Util.shell_q(to_string(tool_name)) ++ "; " ++
           "export SWARM_CODE_ARGS="  ++ args_safe ++ "; " ++
           cmd
    result = shell(full)
    code = elem(result, 0)
    if (code == 0) { 'ok' } else { 'block' }
}
