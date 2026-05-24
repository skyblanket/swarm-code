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

export [load, load_project_context, check_permission, run_hooks, is_dangerous_bash]

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
    if (tool_name == 'bash' && is_dangerous_bash(args) == 'true') {
        'ask'
    } else {
        decision
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

# Local single-quote wrap (Config can't import Tools — circular).