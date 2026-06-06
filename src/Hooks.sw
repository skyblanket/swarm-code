module Hooks

import Util

# ============================================================
# Hooks — filesystem plugin hooks for pre/post tool and LLM calls
# ============================================================
#
# Executable scripts in ~/.swarm-code/hooks/ are called at key points
# in the agent loop. Context is passed via the SWARM_HOOK_DATA env var
# as a JSON string. Hooks have a 5-second timeout; on failure or
# timeout the agent proceeds normally (best-effort).
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
#
# All other hooks are fire-and-forget; their output and exit code are
# ignored (except for logging).

export [run_pre_tool, run_post_tool, run_pre_llm, run_post_llm, hooks_dir]

fun hooks_dir() {
    getenv("HOME") ++ "/.swarm-code/hooks"
}

fun hook_path(name) {
    hooks_dir() ++ "/" ++ name
}

fun hook_timeout_s() { 5 }

# Build a timeout-wrapped shell command that sets SWARM_HOOK_DATA and
# executes the hook script. The JSON data is single-quote-escaped so it
# is safe to splice into the shell command line.
fun hook_cmd(path, json_data) {
    "export SWARM_HOOK_DATA=" ++ Util.shell_q(json_data) ++ "; " ++
    "perl -e 'alarm shift; exec @ARGV' " ++ to_string(hook_timeout_s()) ++
    " sh " ++ Util.shell_q(path)
}

# ============================================================
# run_pre_tool — called before every tool dispatch.
# Returns %{veto: 'false', args: original_args} normally, or
#         %{veto: 'true',  args: original_args} when vetoed.
# If the hook prints {"args": {...}}, the modified args map is returned.
# ============================================================
fun run_pre_tool(tool_name, args_map, opts) {
    path = hook_path("pre_tool.sh")
    if (file_exists(path) == 'false') {
        %{veto: 'false', args: args_map}
    } else {
        args_json = json_encode(args_map)
        data_json = json_encode(%{tool: to_string(tool_name), args: args_map})
        cmd = hook_cmd(path, data_json)
        result = shell(cmd)
        code = elem(result, 0)
        out  = string_trim(elem(result, 1))
        if (code != 0) {
            # Hook failed or timed out — proceed normally
            %{veto: 'false', args: args_map}
        } else {
            if (string_length(out) == 0) {
                %{veto: 'false', args: args_map}
            } else {
                parsed = json_decode(out)
                if (parsed == nil) {
                    %{veto: 'false', args: args_map}
                } else {
                    veto_val = map_get(parsed, 'veto')
                    new_args = map_get(parsed, 'args')
                    is_veto = veto_val == 'true' || veto_val == "true" || veto_val == true
                    if (is_veto == true) {
                        %{veto: 'true', args: args_map}
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
        cmd = hook_cmd(path, data_json)
        shell(cmd)
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
        cmd = hook_cmd(path, data_json)
        shell(cmd)
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
        cmd = hook_cmd(path, data_json)
        shell(cmd)
        'ok'
    }
}
