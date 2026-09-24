module Hooks

import Util

# ============================================================
# Hooks — filesystem plugin hooks for pre/post tool and LLM calls
# ============================================================
#
# Executable scripts in ~/.swarm-code/hooks/ are called at key points
# in the agent loop. Hooks have a 5-second timeout (enforced by
# shell_managed, which kills the hook's whole process group).
#
# Context is a JSON document, delivered three ways (see run_with_payload):
#   * on the hook's STDIN — always; the recommended way to read it
#   * in a private 0600 temp file named by $SWARM_HOOK_DATA_FILE — always
#   * in $SWARM_HOOK_DATA — only when it is under inline_payload_cap()
#     bytes; above that it is omitted and $SWARM_HOOK_DATA_OMITTED=1
# The payload used to go ONLY into the env var + command line, so a big
# write/edit (>128KB) hit E2BIG: the hook never ran, shell() then polled
# 120s for it, and a vetoing pre_tool.sh was silently skipped.
#
# Hook scripts:
#   pre_tool.sh  — before every tool dispatch
#   post_tool.sh — after every tool dispatch (fire-and-forget)
#   pre_llm.sh   — before every LLM call (fire-and-forget)
#   post_llm.sh  — after every LLM call (fire-and-forget)
#
# pre_tool.sh semantics (stdout is parsed as JSON):
#   Exit 0 + prints {"veto": true}       → tool call is skipped
#   Exit 0 + prints {"args": {...}}       → use modified args for dispatch
#   Exit 0 + prints anything else / nil  → proceed as normal
#   Exit non-zero or timeout             → proceed as normal
#   Hook could not be RUN at all (payload file or launch failed)
#                                        → VETO (fail closed), with the reason
#
# All other hooks are fire-and-forget; their output and exit code are
# ignored (except for logging).

export [run_pre_tool, run_pre_tool_at, run_post_tool, run_pre_llm, run_post_llm, hooks_dir,
        run_with_payload, inline_payload_cap]

fun hooks_dir() {
    getenv("HOME") ++ "/.swarm-code/hooks"
}

fun hook_path(name) {
    hooks_dir() ++ "/" ++ name
}

fun hook_timeout_s() { 5 }

# Largest payload also exported inline as an env var. One env string must
# stay under the kernel's per-string limit (MAX_ARG_STRLEN, 128KB) with room
# for the rest of the environment.
fun inline_payload_cap() { 100000 }

fun tmp_prefix() {
    t = getenv("TMPDIR")
    base = if (t == nil || string_length(to_string(t)) == 0) { "/tmp" } else { to_string(t) }
    base ++ "/swarm-code-hook-"
}

# ============================================================
# run_with_payload — run a hook shell snippet with a JSON payload
# ============================================================
# The payload goes into a private temp file (mkstemp → 0600), which becomes
# the hook's stdin and is named by $<env_name>_FILE; $<env_name> carries it
# inline too when it's small (set INSIDE the script from the file, so it
# never touches the command line). `exports` is a shell prefix of extra
# `export K=V;` lines. stderr is folded into stdout.
#
# Returns %{ran: 'true', code, out, interrupted} when the hook ran, or
# %{ran: 'false', error} when it could NOT be run (callers fail closed).
fun run_with_payload(body, payload, env_name, exports, timeout_ms, prefix) {
    f = file_temp(prefix)
    if (f == nil) {
        %{ran: 'false', error: "could not create a temp file for the hook payload (" ++ prefix ++ "…)"}
    } else {
        data = to_string(payload)
        wrote = file_write(f, data)
        if (wrote != 'ok') {
            file_delete(f)
            %{ran: 'false', error: "could not write the hook payload to " ++ f}
        } else {
            file_var = env_name ++ "_FILE"
            inline = if (string_length(data) <= inline_payload_cap()) {
                env_name ++ "=$(cat \"$" ++ file_var ++ "\"); export " ++ env_name
            } else {
                "unset " ++ env_name ++ "; export " ++ env_name ++ "_OMITTED=1"
            }
            script = "export " ++ file_var ++ "=" ++ Util.shell_q(f) ++ "; " ++ exports ++ "\n" ++
                     inline ++ "\n" ++
                     "exec <\"$" ++ file_var ++ "\" 2>&1\n" ++
                     to_string(body) ++ "\n"
            r = shell_managed(script, timeout_ms)
            file_delete(f)
            code = elem(r, 0)
            if (code < 0) {
                %{ran: 'false', error: "hook failed to launch: " ++ to_string(elem(r, 1))}
            } else {
                %{ran: 'true', code: code, out: to_string(elem(r, 1)), interrupted: elem(r, 2)}
            }
        }
    }
}

fun run_script_hook(path, data_json) {
    run_with_payload("sh " ++ Util.shell_q(path), data_json, "SWARM_HOOK_DATA", "",
                     hook_timeout_s() * 1000, tmp_prefix())
}

# ============================================================
# run_pre_tool — called before every tool dispatch.
# Returns %{veto: 'false', args: original_args} normally, or
#         %{veto: 'true',  args: original_args, reason} when vetoed.
# If the hook prints {"args": {...}}, the modified args map is returned.
# ============================================================
fun run_pre_tool(tool_name, args_map, opts) {
    run_pre_tool_at(hook_path("pre_tool.sh"), tool_name, args_map, tmp_prefix())
}

fun run_pre_tool_at(path, tool_name, args_map, prefix) {
    if (file_exists(path) == 'false') {
        %{veto: 'false', args: args_map}
    } else {
        data_json = json_encode(%{tool: to_string(tool_name), args: args_map})
        res = run_with_payload("sh " ++ Util.shell_q(path), data_json, "SWARM_HOOK_DATA", "",
                               hook_timeout_s() * 1000, prefix)
        if (map_get(res, 'ran') != 'true') {
            # Fail CLOSED: a veto hook that never ran must not wave the call through.
            %{veto: 'true', args: args_map,
              reason: "pre_tool hook " ++ path ++ " could not run — " ++ to_string(map_get(res, 'error'))}
        } else {
            code = map_get(res, 'code')
            out  = string_trim(map_get(res, 'out'))
            if (code != 0) {
                # Hook failed or timed out — proceed normally (documented contract)
                %{veto: 'false', args: args_map}
            } else {
                if (string_length(out) == 0) {
                    %{veto: 'false', args: args_map}
                } else {
                    parsed = json_decode(out)
                    if (parsed == nil || is_map(parsed) == 'false') {
                        %{veto: 'false', args: args_map}
                    } else {
                        veto_val = map_get(parsed, 'veto')
                        new_args = map_get(parsed, 'args')
                        is_veto = veto_val == 'true' || veto_val == "true" || veto_val == true
                        if (is_veto == true) {
                            %{veto: 'true', args: args_map, reason: "vetoed by pre_tool hook " ++ path}
                        } else {
                            if (new_args != nil) {
                                %{veto: 'false', args: new_args}
                            } else {
                                %{veto: 'false', args: args_map}
                            }
                        }
                    }
                }
            }
        }
    }
}

# ============================================================
# run_post_tool — called after every tool dispatch (fire-and-forget).
# ============================================================
fun run_post_tool(tool_name, result_str, exit_code, opts) {
    path = hook_path("post_tool.sh")
    if (file_exists(path) == 'false') {
        'ok'
    } else {
        data_json = json_encode(%{
            tool: to_string(tool_name),
            result: to_string(result_str),
            exit_code: exit_code
        })
        run_script_hook(path, data_json)
        'ok'
    }
}

# ============================================================
# run_pre_llm — called before each LLM call (fire-and-forget).
# ============================================================
fun run_pre_llm(model, n_messages, opts) {
    path = hook_path("pre_llm.sh")
    if (file_exists(path) == 'false') {
        'ok'
    } else {
        data_json = json_encode(%{
            model: to_string(model),
            messages: n_messages
        })
        run_script_hook(path, data_json)
        'ok'
    }
}

# ============================================================
# run_post_llm — called after each LLM call (fire-and-forget).
# ============================================================
fun run_post_llm(model, tokens, latency_ms, opts) {
    path = hook_path("post_llm.sh")
    if (file_exists(path) == 'false') {
        'ok'
    } else {
        data_json = json_encode(%{
            model: to_string(model),
            tokens: tokens,
            latency_ms: latency_ms
        })
        run_script_hook(path, data_json)
        'ok'
    }
}
