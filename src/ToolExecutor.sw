module ToolExecutor

# ============================================================
# ToolExecutor — shared policy boundary around raw tool handlers
# ============================================================
#
# Every non-interactive execution context (subagents, MCP server,
# future workflow runners) must pass through this module. The main
# interactive agent prepares effective arguments here, resolves "ask"
# permissions with the Reader, then enters the same post-execution path.
#
# Tools.exec_raw owns handlers only. Policy belongs here:
#   context allow-list -> argument hook -> guardrails -> permissions
#   -> configured hook -> handler -> post hooks

import Config
import Hooks
import ToolGuardrails
import ToolRegistry
import Tools

export [execute, execute_outcome, prepare, preflight, postflight, permission_gate]

# Execute a regular registered tool without Agent's worker isolation.
# MCP server mode uses this entry point. Agent uses preflight/postflight
# around its isolated dispatcher so a crashing handler stays contained.
fun execute(name, args, opts) {
    pre = preflight(name, args, opts)
    if (map_get(pre, 'ok') != 'true') {
        to_string(map_get(pre, 'error'))
    } else {
        effective_args = map_get(pre, 'args')
        result = Tools.exec_raw(name, effective_args, opts)
        postflight(name, effective_args, result, opts)
        result
    }
}

# Structured variant of execute(): returns %{ok:'true'|'false', text:...}
# so callers (MCP server) can set failure status STRUCTURALLY rather than
# by sniffing the result payload for an "error:" prefix. Lexical sniffing
# both false-positives (a `bash` command that *prints* the word "error:"
# yet exits 0) and false-negatives (a `bash` command that exits non-zero
# but prints no "error:" text). Failure is determined by, in order:
#   1. preflight failure (allow-list / guardrail / permission / hook veto).
#   2. for `bash`, the process exit code from the "[exit N]\n" banner — the
#      ONLY ground-truth signal; command stdout is never inspected.
#   3. for every other tool, the handler's own "error: ..." sentinel prefix
#      (unchanged from the prior behavior; these handlers return a short
#      status line, not arbitrary content, so the prefix is reliable).
fun execute_outcome(name, args, opts) {
    pre = preflight(name, args, opts)
    if (map_get(pre, 'ok') != 'true') {
        %{ok: 'false', text: to_string(map_get(pre, 'error'))}
    } else {
        effective_args = map_get(pre, 'args')
        result = Tools.exec_raw(name, effective_args, opts)
        postflight(name, effective_args, result, opts)
        text = to_string(result)
        ok = classify_outcome(to_string(name), text)
        %{ok: ok, text: text}
    }
}

# Decide ok/error from a successful-preflight handler result.
fun classify_outcome(name_s, text) {
    if (name_s == "bash") {
        # bash always returns either a "[exit N]\n..." banner or an
        # interrupted-process banner. Only a non-zero exit is a failure;
        # the "error:" word appearing anywhere in command output is just
        # output and must NOT flip isError. An interrupted run (timeout /
        # ESC, no "[exit" prefix) is surfaced as a failure.
        if (string_starts_with(text, "[exit 0]") == 'true') { 'true' }
        else { if (string_starts_with(text, "[exit ") == 'true') { 'false' }
        else { 'false' }}
    }
    else {
        # Non-bash handlers return a short status string; an "error:" prefix
        # is their genuine failure sentinel (read's "not a regular file",
        # edit's "old_string not found", etc.). Preserve prior behavior.
        if (string_starts_with(text, "error:") == 'true') { 'false' }
        else { 'true' }
    }
}

# Run every pre-execution policy except interactive permission resolution.
# Agent uses this first so its permission prompt describes the effective
# hook-rewritten arguments. Non-interactive callers should use preflight.
fun prepare(name, args, opts) {
    context = map_get(opts, 'execution_context')
    if (context == nil) {
        failed("tool execution requires an explicit execution_context")
    } else {
        context_ok = ToolRegistry.allowed_in(to_string(context), to_string(name))
        if (context_ok != 'true') {
            failed("tool '" ++ to_string(name) ++ "' is not available in " ++
                   to_string(context) ++ " context")
        } else {
            filesystem_hook = Hooks.run_pre_tool(name, args, opts)
            if (map_get(filesystem_hook, 'veto') == 'true') {
                failed("tool '" ++ to_string(name) ++ "' blocked by pre_tool hook")
            } else {
                # Hooks may rewrite arguments, so every safety decision below
                # must inspect the effective arguments, never the originals.
                effective = map_get(filesystem_hook, 'args')
                args_raw = json_encode(effective)
                guard = ToolGuardrails.observe_before(opts, to_string(name), args_raw)
                if (guard != 'ok') {
                    failed(to_string(guard))
                } else {
                    configured_hook = Config.run_hooks("PreToolUse", name, args_raw, opts)
                    if (configured_hook == 'block') {
                        failed("tool '" ++ to_string(name) ++ "' blocked by PreToolUse hook")
                    } else {
                        %{ok: 'true', args: effective}
                    }
                }
            }
        }
    }
}

# Returns %{ok:'true', args:effective_args} or
# %{ok:'false', error:"error: ..."}. This is the fail-closed entry point
# for MCP server mode, subagents, and future non-interactive runners.
fun preflight(name, args, opts) {
    prepared = prepare(name, args, opts)
    if (map_get(prepared, 'ok') != 'true') {
        prepared
    } else {
        effective = map_get(prepared, 'args')
        gate = permission_gate(name, effective, opts)
        if (gate != 'ok') {
            failed(to_string(gate))
        } else {
            prepared
        }
    }
}

fun failed(message) {
    s = to_string(message)
    text = if (string_starts_with(s, "error:") == 'true') { s }
           else { "error: " ++ s }
    %{ok: 'false', error: text}
}

# Non-interactive callers fail closed on "ask". The interactive Agent
# resolves that state after prepare() and before raw dispatch.
fun permission_gate(name, args, opts) {
    decision = Config.check_permission(name, args, opts)
    if (decision == 'allow') { 'ok' }
    else { if (decision == 'deny') {
        "error: permission denied for tool '" ++ to_string(name) ++ "'"
    } else {
        "error: tool '" ++ to_string(name) ++
        "' requires interactive permission in this execution context"
    }}
}

fun postflight(name, args, result, opts) {
    Hooks.run_post_tool(name, result, 0, opts)
    Config.run_hooks("PostToolUse", name, json_encode(args), opts)
    ToolGuardrails.observe_after(opts, to_string(name), to_string(result))
    'ok'
}
