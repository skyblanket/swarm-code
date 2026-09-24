module Config

import Util
import CommandGuard
import Hooks

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
        llm_timeout_ms, command_of, command_risk, denial_message, denial_reason, uses_sudo,
        run_hooks_verdict]

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
# Policy:
#   1. Default-allow for every BUILT-IN tool. The user explicitly asked
#      for "all allowed by default" — prompting on every bash/write/edit
#      was breaking flow during tool test runs. The one exception is MCP
#      tools (mcp__*): being external and unvetted, they default to 'ask'
#      so the user is prompted on first use (see default_permission).
#   2. settings.permissions[tool_name] in settings.json can downgrade
#      a specific tool to 'ask' or 'deny' if the user wants tighter
#      control on one tool (e.g. "bash": "ask").
#   3. Every tool that runs a model-supplied shell command (command_of:
#      bash, background, bg_server, run_tests.command) goes through the
#      CommandGuard classifier, which parses the command like sh does:
#        * hardline  (rm -r on /, mkfs, dd to a raw disk, halt/reboot,
#          chmod -R on /, fork bomb) → 'deny', unconditionally — before
#          any settings/env lookup, so SWARM_CODE_ALLOW_DANGEROUS=1
#          cannot turn it off.
#        * dangerous (sudo, rm -rf on ~ or a system path, dd to a
#          device) → escalates 'allow' to 'ask' (a configured 'deny'
#          stays 'deny'); 'deny' outright when SWARM_CODE_DENY_DANGEROUS=1
#          (unattended /flows children); skipped entirely when
#          SWARM_CODE_ALLOW_DANGEROUS=1.
#      denial_message() names the matched pattern so the model can adapt.
# ------------------------------------------------------------
fun check_permission(tool_name, args, opts) {
    risk = command_risk(tool_name, args)
    level = elem(risk, 0)
    if (level == 'hardline') {
        'deny'
    }
    else {
        decision = configured_decision(tool_name, opts)

        # Headless converts 'ask' to 'allow' (agent.resolve_permission),
        # so unattended children (/flows fan-out sets
        # SWARM_CODE_DENY_DANGEROUS=1) turn this gate into a hard deny
        # instead of silently auto-approving.
        if (level == 'dangerous' && dangerous_bypassed() == 'false') {
            if (decision == 'deny') { 'deny' }
            else { if (getenv("SWARM_CODE_DENY_DANGEROUS") == "1") { 'deny' } else { 'ask' } }
        } else {
            decision
        }
    }
}

# settings.permissions[tool] if set, else the built-in default.
fun configured_decision(tool_name, opts) {
    settings = if (opts == nil) { nil } else { map_get(opts, 'settings') }
    perms = if (settings == nil) { nil } else { map_get(settings, 'permissions') }
    # settings.json is decoded with atom keys, so pass tool_name directly.
    configured = if (perms == nil) { nil } else { map_get(perms, tool_name) }
    if (configured != nil) { string_to_perm(configured) } else { default_permission(tool_name) }
}

fun dangerous_bypassed() {
    if (getenv("SWARM_CODE_ALLOW_DANGEROUS") == "1") { 'true' } else { 'false' }
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

# The shell command a tool call will run, or nil for tools that don't run
# one. Every tool listed here gets the same hardline/dangerous gate as bash —
# before, `background` / `bg_server` / `run_tests.command` ran ungated.
fun command_of(tool_name, args) {
    t = to_string(tool_name)
    if (args == nil || is_map(args) == 'false') { nil }
    else { if (t == "bash" || t == "background" || t == "bg_server" || t == "run_tests") {
        c = map_get(args, 'command')
        if (c == nil) { nil } else { to_string(c) }
    } else { nil }}
}

# {'hardline'|'dangerous'|'ok', reason} for a tool call.
fun command_risk(tool_name, args) {
    cmd = command_of(tool_name, args)
    if (cmd == nil) { {'ok', ""} } else { CommandGuard.risk_of(cmd) }
}

fun uses_sudo(cmd) { CommandGuard.uses_sudo(cmd) }

# "error: permission denied for tool 'X' — <why>". The why names the
# matched pattern (and the offending simple command), so the model can
# pick a narrower command instead of retrying the same call.
fun denial_message(tool_name, args, opts) {
    "error: permission denied for tool '" ++ to_string(tool_name) ++ "'" ++
        denial_reason(tool_name, args, opts)
}

fun denial_reason(tool_name, args, opts) {
    risk = command_risk(tool_name, args)
    level = elem(risk, 0)
    if (level == 'hardline') {
        " — blocked by the hardline safety floor: " ++ elem(risk, 1) ++
        ". This is never allowed (no setting or env var lifts it); use a narrower command."
    } else { if (configured_decision(tool_name, opts) == 'deny') {
        " — denied by settings.json (permissions." ++ to_string(tool_name) ++ " = \"deny\")."
    } else { if (level == 'dangerous' && dangerous_bypassed() == 'false' &&
                 getenv("SWARM_CODE_DENY_DANGEROUS") == "1") {
        " — flagged dangerous: " ++ elem(risk, 1) ++
        ". SWARM_CODE_DENY_DANGEROUS=1 is set for this unattended run, so it is denied; use a narrower command."
    } else { if (level == 'dangerous' && dangerous_bypassed() == 'false') {
        " — flagged dangerous: " ++ elem(risk, 1) ++ "; it was not approved."
    } else {
        " — not approved at the permission prompt (don't retry the same call; ask the user or try another approach)."
    }}}}
}

# Kept for callers/tests that ask about a bash args map directly.
# 'true' for dangerous OR hardline commands (a hardline command is certainly
# dangerous); 'false' when SWARM_CODE_ALLOW_DANGEROUS=1 (YOLO mode).
fun is_dangerous_bash(args) {
    if (dangerous_bypassed() == 'true') { 'false' }
    else {
        level = elem(command_risk('bash', args), 0)
        if (level == 'ok') { 'false' } else { 'true' }
    }
}

# 'true' for the unbypassable tier (see CommandGuard for the categories).
fun is_hardline_bash(args) {
    if (elem(command_risk('bash', args), 0) == 'hardline') { 'true' } else { 'false' }
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
# Hooks receive context through the environment and stdin:
#   SWARM_CODE_EVENT, SWARM_CODE_TOOL — event and tool name
#   stdin, and the private 0600 file $SWARM_CODE_ARGS_FILE — the args JSON
#     (always; read one of these to see every call)
#   SWARM_CODE_ARGS — the same JSON inline, only when it is under 100KB;
#     above that it is unset and SWARM_CODE_ARGS_OMITTED=1
# (The args used to be spliced into the command line + env: a >128KB
# write hit E2BIG, the hook never ran, and shell() polled 120s before
# reporting a block.) Hooks time out after hook_cmd_timeout_ms().
#
# Returns 'ok' normally. Returns 'block' if any PreToolUse hook exited
# non-zero, timed out, or could not be run at all (fail closed) —
# blocking the tool call. run_hooks_verdict also says why.
# ------------------------------------------------------------
fun run_hooks(event, tool_name, args_json, opts) {
    v = run_hooks_verdict(event, tool_name, args_json, opts)
    if (v == 'ok') { 'ok' } else { 'block' }
}

# 'ok' | {'block', reason}
fun run_hooks_verdict(event, tool_name, args_json, opts) {
    settings = if (opts == nil) { nil } else { map_get(opts, 'settings') }
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
                if (result != 'ok') {
                    result
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

# Run a single hook command with the context described above run_hooks.
# 'ok' on exit 0; {'block', reason} on a non-zero exit, a timeout, or when
# the hook could not be run at all — the reason carries the exit code and
# the start of the hook's output (stdout+stderr) so the model can see why.
fun hook_cmd_timeout_ms() { 60000 }

fun run_hook_cmd(cmd, event, tool_name, args_json) {
    exports = "export SWARM_CODE_EVENT=" ++ Util.shell_q(to_string(event)) ++ "; " ++
              "export SWARM_CODE_TOOL="  ++ Util.shell_q(to_string(tool_name)) ++ ";"
    res = Hooks.run_with_payload(cmd, to_string(args_json), "SWARM_CODE_ARGS", exports,
                                 hook_cmd_timeout_ms(), hook_tmp_prefix())
    label = to_string(event) ++ " hook `" ++ string_truncate(to_string(cmd), 80) ++ "`"
    if (map_get(res, 'ran') != 'true') {
        {'block', label ++ " could not run — " ++ to_string(map_get(res, 'error'))}
    } else { if (map_get(res, 'interrupted') == 'true') {
        {'block', label ++ " timed out after " ++ to_string(hook_cmd_timeout_ms() / 1000) ++ "s"}
    } else { if (map_get(res, 'code') == 0) {
        'ok'
    } else {
        out = string_trim(to_string(map_get(res, 'out')))
        tail = if (string_length(out) == 0) { "" } else { ": " ++ string_truncate(out, 500) }
        {'block', label ++ " exited " ++ to_string(map_get(res, 'code')) ++ tail}
    }}}
}

fun hook_tmp_prefix() {
    t = getenv("TMPDIR")
    base = if (t == nil || string_length(to_string(t)) == 0) { "/tmp" } else { to_string(t) }
    base ++ "/swarm-code-hook-"
}
