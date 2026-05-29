module ToolGuardrails

# ============================================================
# ToolGuardrails — per-turn loop / failure brakes
# ============================================================
#
# Tracks tool-call patterns within a single user turn so the agent
# can't burn through cost on a runaway loop.
#
# Two thresholds — these catch *pathological* behaviour, not normal
# exploration:
#   1. identical-call:  5  consecutive calls with the same name+args
#   2. same-tool-fail:  8  consecutive failing results from the same tool
#
# The earlier "no-progress" check (5 consecutive idempotent reads
# without a mutation) was removed after it kept firing on legitimate
# research turns — reading 5 different files to understand a feature
# is not a loop, it's how the agent gathers context. The identical-call
# check is still the right catch for real loops (same tool + same
# args repeated), and the failure-halt covers cascading errors.
#
# State is an ETS table created by init() and stashed on
# opts['guardrails_table'] at boot in main.sw. Keys:
#   'last_sig'    — signature of prior call ("name|args_json") | nil
#   'sig_count'   — consecutive identical-sig count
#   'last_tool'   — last tool name string | nil
#   'fail_count'  — consecutive failures of last_tool
#   'halt_reason' — string if a fatal halt fired (cleared on next turn)
#
# Public entry points:
#   init()                                     → ets table
#   observe_before(opts, name_str, args_raw)   → 'ok' | error_string
#   observe_after(opts, name_str, result_str)  → 'ok'
#   reset(opts)                                → 'ok' (call per turn)

export [init, observe_before, observe_after, reset, in_list]

fun init() { ets_new() }

fun threshold_identical()    { 5 }
fun threshold_same_failure() { 8 }

# Called BEFORE dispatching a tool. Returns 'ok' or an error string
# describing which guardrail tripped. agent.sw should turn a non-ok
# return into a synthetic tool_result and SKIP the actual dispatch.
fun observe_before(opts, name_str, args_raw) {
    table = map_get(opts, 'guardrails_table')
    if (table == nil) { 'ok' }
    else {
        sig = to_string(name_str) ++ "|" ++ to_string(args_raw)
        last_sig = ets_get(table, 'last_sig')
        sig_count = ets_get(table, 'sig_count')
        new_count = if (sig == last_sig) {
            if (sig_count == nil) { 2 } else { sig_count + 1 }
        } else { 1 }
        ets_put(table, 'last_sig', sig)
        ets_put(table, 'sig_count', new_count)

        if (new_count >= threshold_identical()) {
            "error: guardrail — you've called " ++ to_string(name_str) ++
            " with identical args " ++ to_string(new_count) ++
            " times in a row. Stop, reflect on whether the call is achieving anything, and try a different approach or report findings to the user."
        }
        else { 'ok' }
    }
}

# Called AFTER dispatch. Updates fail-streak; sets 'halt_reason' if
# the same tool failed too many times in a row.
fun observe_after(opts, name_str, result_str) {
    table = map_get(opts, 'guardrails_table')
    if (table == nil) { 'ok' }
    else {
        is_err = string_starts_with(to_string(result_str), "error:")
        last_tool = ets_get(table, 'last_tool')
        fail_count = ets_get(table, 'fail_count')
        if (is_err == 'true') {
            new_fc = if (to_string(name_str) == to_string(last_tool)) {
                if (fail_count == nil) { 2 } else { fail_count + 1 }
            } else { 1 }
            ets_put(table, 'last_tool', to_string(name_str))
            ets_put(table, 'fail_count', new_fc)
            if (new_fc >= threshold_same_failure()) {
                ets_put(table, 'halt_reason',
                    "tool '" ++ to_string(name_str) ++ "' failed " ++
                    to_string(new_fc) ++ " consecutive times. Halting the turn to prevent runaway cost.")
                'ok'
            } else { 'ok' }
        } else {
            ets_put(table, 'last_tool', to_string(name_str))
            ets_put(table, 'fail_count', 0)
            'ok'
        }
    }
}

# Clear all per-turn counters. Called at the start of each user
# message in route_input — guardrails are per-turn, not per-session.
fun reset(opts) {
    table = map_get(opts, 'guardrails_table')
    if (table == nil) { 'ok' }
    else {
        ets_put(table, 'last_sig', nil)
        ets_put(table, 'sig_count', 0)
        ets_put(table, 'last_tool', nil)
        ets_put(table, 'fail_count', 0)
        ets_put(table, 'halt_reason', nil)
        'ok'
    }
}

# Linear-scan list membership. Exported so agent.sw can reuse it for
# subagent_blocked without redefining.
fun in_list(lst, item) {
    if (length(lst) == 0) { 'false' }
    else {
        if (hd(lst) == item) { 'true' }
        else { in_list(tl(lst), item) }
    }
}
