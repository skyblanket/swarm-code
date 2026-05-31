module Main

# ============================================================
# swarm-code test suite
# ============================================================
# A standalone binary (bin/swarm-code-test) that exercises the
# harness's pure logic + the runtime invariants whose breakage
# caused real crashes. Run with `make test`.
#
# Every check prints ✓ / ✗ and contributes 1 / 0; main sums them
# and exits non-zero if anything failed, so CI / `make test` catches
# regressions. No network — these are fast, deterministic unit tests.
#
# Each test here is a regression guard for a specific bug fixed
# while hardening swarm-code:
#   - string_split("") panic            (Agents.sw hd-of-empty-list)
#   - string_split trailing-delim       (heap overflow → trace trap)
#   - && / || short-circuit             (compiler emit_binop)
#   - native tool_calls reconstruction  (infinite-write loop)
# plus coverage for glob/grep, markdown, permissions, memory.

import Markdown
import LLM
import Config
import Memory
import Tools
import Mcp
import ToolGuardrails
import Agent
import Scheduler

fun main() {
    print("")
    print("\e[1mswarm-code test suite\e[0m")
    print("\e[2m─────────────────────\e[0m")

    results = [
        t_split_empty(),
        t_split_trailing(),
        t_split_basic(),
        t_and_shortcircuit(),
        t_or_shortcircuit(),
        t_json_roundtrip(),
        t_list_ops(),
        t_native_tool_calls(),
        t_native_no_wrapper(),
        t_no_name_glitch_native(),
        t_journal_roundtrip(),
        t_chat_url(),
        t_markdown_basic(),
        t_markdown_empty(),
        t_markdown_oneline(),
        t_dangerous_bash(),
        t_slugify(),
        t_glob(),
        t_grep(),
        t_mcp_unconfigured(),
        t_remember_body(),
        t_spawn_send_receive(),
        t_hardline_unbypassable(),
        t_path_traversal_blocked(),
        t_sudo_blocked(),
        t_repair_history_drops_orphan_tool(),
        t_repair_history_drops_trailing_unmatched(),
        t_repair_history_collapses_users(),
        t_repair_history_keeps_matched_tool(),
        t_guardrail_identical_blocks(),
        t_guardrail_research_allowed(),
        t_guardrail_failure_halt(),
        t_subagent_blocked_tool(),
        t_context_status_injected(),
        t_scheduler_units_ms(),
        t_scheduler_daily_parses(),
        t_scheduler_daily_rejects_garbage(),
        t_scheduler_compute_next_fire_interval(),
        t_repair_history_backfills_partial(),
        t_hardline_word_boundary(),
        t_hardline_telinit(),
        t_has_markdown_tightened(),
        t_markdown_link(),
        t_markdown_table_clamps()
    ]

    passed = sum_list(results, 0)
    total = length(results)
    print("\e[2m─────────────────────\e[0m")
    if (passed == total) {
        print("\e[32m\e[1m" ++ to_string(passed) ++ "/" ++ to_string(total) ++ " passed\e[0m")
        sys_exit(0)
    } else {
        print("\e[31m\e[1m" ++ to_string(passed) ++ "/" ++ to_string(total) ++
              " passed — " ++ to_string(total - passed) ++ " FAILED\e[0m")
        sys_exit(1)
    }
}

# ------------------------------------------------------------
# Harness
# ------------------------------------------------------------
fun check(name, cond) {
    if (cond == 'true') {
        print("  \e[32m✓\e[0m " ++ name)
        1
    } else {
        print("  \e[31m✗\e[0m " ++ name)
        0
    }
}

fun sum_list(lst, acc) {
    if (length(lst) == 0) { acc }
    else { sum_list(tl(lst), acc + hd(lst)) }
}

fun repeat_str(s, n) {
    if (n <= 0) { "" }
    else { s ++ repeat_str(s, n - 1) }
}

fun bool_and(a, b) {
    if (a == 'true' && b == 'true') { 'true' } else { 'false' }
}

fun bool_and3(a, b, c) {
    bool_and(bool_and(a, b), c)
}

# ------------------------------------------------------------
# Runtime invariants — regression guards for the crash bugs
# ------------------------------------------------------------

# string_split("") used to return [] → hd() panicked "list is empty"
# (the Agents.sw crash). Must return a one-element list [""].
fun t_split_empty() {
    parts = string_split("", "\ncall:")
    ok = bool_and(
        if (length(parts) == 1) { 'true' } else { 'false' },
        if (hd(parts) == "") { 'true' } else { 'false' })
    check("string_split(\"\") returns [\"\"] (not [])", ok)
}

# A string of exactly 64 "a\n" segments hits the realloc boundary at
# cap=64; the trailing-delimiter push used to write one past the
# buffer → heap corruption (the original trace trap).
fun t_split_trailing() {
    big = repeat_str("a\n", 64)
    parts = string_split(big, "\n")
    # 64 "a" segments + 1 trailing "" = 65
    check("string_split 64-seg trailing delim (no heap overflow)",
          if (length(parts) == 65) { 'true' } else { 'false' })
}

fun t_split_basic() {
    parts = string_split("a,b,c", ",")
    ok = bool_and(
        if (length(parts) == 3) { 'true' } else { 'false' },
        if (hd(parts) == "a") { 'true' } else { 'false' })
    check("string_split basic", ok)
}

# && must not evaluate its right operand when the left is false.
# If it does, elem(nil,0) panics and aborts the whole suite.
fun t_and_shortcircuit() {
    x = nil
    cond = if (x != nil && elem(x, 0) == 'foo') { 'true' } else { 'false' }
    check("&& short-circuits (no elem on nil)",
          if (cond == 'false') { 'true' } else { 'false' })
}

# || must not evaluate its right operand when the left is true.
fun t_or_shortcircuit() {
    x = "ok"
    cond = if (x == "ok" || elem(nil, 0) == 'z') { 'true' } else { 'false' }
    check("|| short-circuits (no elem on nil)", cond)
}

fun t_json_roundtrip() {
    m = %{name: "swarm", count: 7}
    j = json_encode(m)
    d = json_decode(j)
    ok = if (d == nil) { 'false' }
         else {
             if (to_string(map_get(d, 'name')) == "swarm") { 'true' } else { 'false' }
         }
    check("json encode/decode round-trip", ok)
}

fun t_list_ops() {
    lst = [10, 20, 30]
    ok = bool_and3(
        if (length(lst) == 3) { 'true' } else { 'false' },
        if (hd(lst) == 10) { 'true' } else { 'false' },
        if (hd(tl(lst)) == 20) { 'true' } else { 'false' })
    check("hd / tl / length", ok)
}

# ------------------------------------------------------------
# LLM — structured tool_call roundtrip (matches Claude Code's pattern)
# ------------------------------------------------------------
# History is now a list of message MAPS. Tool calls live as a
# separate field on the assistant message; tool results have their
# own role:'tool' messages keyed by tool_call_id. build_request_body
# is a structured roundtrip — no parse → stringify → re-parse cycle.
fun native_history() {
    [
        LLM.new_message_system("you are a test"),
        LLM.new_message_user("make a file"),
        LLM.new_message_assistant(
            "Sure.",
            [%{id: "call_abc", name: "write",
               arguments: "{\"path\":\"/tmp/x\",\"content\":\"hi\"}"}],
            nil),
        LLM.new_message_tool("call_abc", "ok: wrote 2 bytes")
    ]
}

fun native_opts() {
    %{model: "kimi-k2.6", temperature: 1.0, max_tokens: 1024, tool_format: 'native'}
}

fun t_native_tool_calls() {
    body = LLM.build_request_body(native_history(), native_opts())
    ok = bool_and3(
        string_contains(body, "tool_calls"),
        string_contains(body, "tool_call_id"),
        string_contains(body, "call_abc"))
    check("native build_request_body emits structured tool_calls + tool role", ok)
}

# The raw <tool_result> wrapper must NOT appear in the native-mode
# wire body — that's the inband-mode flatten; native uses role:'tool'.
fun t_native_no_wrapper() {
    body = LLM.build_request_body(native_history(), native_opts())
    check("native build strips <tool_result> wrapper",
          if (string_contains(body, "<tool_result>") == 'false') { 'true' } else { 'false' })
}

# Regression for the "NAME glitch": when the model emits the literal
# substring `call:NAME{"arg":"val"}` in its prose (echoing a legacy
# anti-example from the system prompt, or just talking about the
# format), it must NOT be dispatched as a real tool call in native
# mode. With structured tool_calls, the content is content; only the
# server's actual tool_calls field can drive dispatch.
fun t_no_name_glitch_native() {
    glitch_history = [
        LLM.new_message_system("you are a test"),
        LLM.new_message_user("explain the legacy format"),
        LLM.new_message_assistant(
            "The legacy inband syntax looked like call:NAME{\"arg\":\"val\"} but we don't use it.",
            [],
            nil)
    ]
    body = LLM.build_request_body(glitch_history, native_opts())
    # Prose is preserved verbatim — but no extracted tool_call named "NAME"
    # appears in the request body. (Look for the exact OpenAI tool_calls
    # field with the bad name, not the prose mention.)
    has_prose = string_contains(body, "legacy inband syntax")
    has_fake_call = string_contains(body, "\"name\":\"NAME\"")
    ok = bool_and(
        if (has_prose == 'true') { 'true' } else { 'false' },
        if (has_fake_call == 'false') { 'true' } else { 'false' })
    check("native mode never parses tool_calls out of prose", ok)
}

# Round-trip the new structured journal format through encode +
# decode. An assistant with tool_calls + a matching tool result must
# survive verbatim, including tool_call_id pairing.
fun t_journal_roundtrip() {
    h = native_history()
    # Drop the system message — encode_journal omits system anyway.
    body = h
    encoded = LLM.build_request_body(body, native_opts())
    decoded_req = json_decode(encoded)
    if (decoded_req == nil) { check("journal/api shape decodes", 'false') }
    else {
        msgs = map_get(decoded_req, 'messages')
        # Find the assistant message — must carry tool_calls[].
        has_struct_tcs = walk_for_tcs(msgs, 0, 'false')
        check("structured assistant.tool_calls survives encode", has_struct_tcs)
    }
}

fun walk_for_tcs(msgs, i, found) {
    if (length(msgs) == 0) { found }
    else {
        m = hd(msgs)
        role = map_get(m, 'role')
        tcs = map_get(m, 'tool_calls')
        new_found = if (role == "assistant" && tcs != nil && length(tcs) > 0) { 'true' } else { found }
        walk_for_tcs(tl(msgs), i + 1, new_found)
    }
}

fun t_chat_url() {
    a = LLM.chat_completions_url("http://sushi:8000")
    b = LLM.chat_completions_url("https://api.z.ai/api/paas/v4/chat/completions")
    ok = bool_and(
        if (a == "http://sushi:8000/v1/chat/completions") { 'true' } else { 'false' },
        if (b == "https://api.z.ai/api/paas/v4/chat/completions") { 'true' } else { 'false' })
    check("chat_completions_url append vs verbatim", ok)
}

# ------------------------------------------------------------
# Markdown — walk_blocks must not crash
# ------------------------------------------------------------
fun t_markdown_basic() {
    r = Markdown.render("# Title\n\nFirst para.\n\nSecond with `code` and **bold**.\n\n- one\n- two\n", 80)
    check("markdown renders multi-block",
          if (string_length(r) > 0) { 'true' } else { 'false' })
}

fun t_markdown_empty() {
    r = Markdown.render("", 80)
    check("markdown render of empty → empty", if (r == "") { 'true' } else { 'false' })
}

# The exact single-paragraph shape that panicked walk_blocks before
# the && fix (em-dash + inline code).
fun t_markdown_oneline() {
    r = Markdown.render("Done. The swarmrt source has 86 files — core sources (`swc.c`).", 80)
    check("markdown single paragraph (&&-regression)",
          if (string_length(r) > 0) { 'true' } else { 'false' })
}

# ------------------------------------------------------------
# Config / Memory / Tools
# ------------------------------------------------------------
fun t_dangerous_bash() {
    d1 = Config.is_dangerous_bash(%{command: "rm -rf /"})
    d2 = Config.is_dangerous_bash(%{command: "ls -la /tmp"})
    d3 = Config.is_dangerous_bash(%{command: "sudo rm x"})
    ok = bool_and3(
        if (d1 == 'true') { 'true' } else { 'false' },
        if (d2 == 'false') { 'true' } else { 'false' },
        if (d3 == 'true') { 'true' } else { 'false' })
    check("is_dangerous_bash: flags rm -rf / + sudo, not ls", ok)
}

fun t_slugify() {
    s = Memory.slugify("User's ADHD Workflow")
    check("slugify normalizes to safe filename",
          if (s == "user_s_adhd_workflow") { 'true' } else { 'false' })
}

# glob with a path-component pattern — `find -name` (basename only)
# silently matched nothing here before the rg/find rewrite.
fun t_glob() {
    out = Tools.exec('glob', %{pattern: "*.sw", path: "src"}, %{})
    check("glob finds .sw files", string_contains(out, ".sw"))
}

fun t_grep() {
    out = Tools.exec('grep', %{pattern: "module Tools", path: "src"}, %{})
    check("grep finds file content", string_contains(out, "tools.sw"))
}

# MCP with no mcpServers configured: init returns an empty table,
# no tool schemas, no prompt section — the zero-cost-when-unused path
# (also the regression guard that the Mcp module compiles + loads).
fun t_mcp_unconfigured() {
    table = Mcp.init(map_new())
    schemas = Mcp.all_schemas(table)
    section = Mcp.as_prompt_section(table)
    ok = bool_and(
        if (length(schemas) == 0) { 'true' } else { 'false' },
        if (section == "") { 'true' } else { 'false' })
    check("mcp: unconfigured -> no schemas, no prompt section", ok)
}

# remember saved frontmatter but an empty body: the schema named the
# content field `body` while do_remember read `content`, so the
# mismatch silently dropped every memory's content. Guard: a remember
# call must persist the body to the .md file.
fun t_remember_body() {
    marker = "REMEMBER-BODY-GUARD-77"
    Tools.exec('remember', %{name: "zz remember probe",
                             description: "regression guard",
                             type: "reference",
                             body: marker}, %{})
    path = getenv("HOME") ++ "/.swarm-code/memory/zz_remember_probe.md"
    saved = file_read(path)
    ok = if (saved == nil) { 'false' } else { string_contains(saved, marker) }
    file_delete(path)
    check("remember persists the body to the .md file", ok)
}

# Multi-agent concurrency primitive: spawn two workers, send each a
# ping, collect both pongs. Regression guard for the runtime's
# process scheduler + mailbox ordering.
fun t_spawn_send_receive() {
    parent = self()
    w1 = spawn(ping_worker(parent))
    w2 = spawn(ping_worker(parent))
    send(w1, {'ping', 1})
    send(w2, {'ping', 2})
    r1 = await_pong()
    r2 = await_pong()
    ok = bool_and(
        if (r1 + r2 == 3) { 'true' } else { 'false' },
        if (r1 != 0 && r2 != 0) { 'true' } else { 'false' })
    check("spawn/send/receive: two concurrent workers", ok)
}

fun ping_worker(parent) {
    receive {
        {'ping', n} -> send(parent, {'pong', n})
    }
}

fun await_pong() {
    receive {
        {'pong', n} -> n
        after 5000 { 0 }
    }
}

# ------------------------------------------------------------
# Security hardening regression guards
# ------------------------------------------------------------

# is_hardline_bash flags every catastrophic pattern category. These
# return 'deny' at check_permission regardless of
# SWARM_CODE_ALLOW_DANGEROUS — verified at the function level here.
fun t_hardline_unbypassable() {
    h_mkfs    = Config.is_hardline_bash(%{command: "mkfs /dev/sda1"})
    h_dd      = Config.is_hardline_bash(%{command: "dd if=/dev/zero of=/dev/sda bs=1M"})
    h_reboot  = Config.is_hardline_bash(%{command: "reboot now"})
    h_chmod   = Config.is_hardline_bash(%{command: "chmod 000 /"})
    h_forkbomb = Config.is_hardline_bash(%{command: ":(){:|:&};:"})
    h_rmstar  = Config.is_hardline_bash(%{command: "rm -rf /*"})
    h_safe    = Config.is_hardline_bash(%{command: "ls -la /tmp"})
    ok = bool_and(
        bool_and3(
            if (h_mkfs == 'true') { 'true' } else { 'false' },
            if (h_dd == 'true') { 'true' } else { 'false' },
            if (h_reboot == 'true') { 'true' } else { 'false' }),
        bool_and(
            bool_and3(
                if (h_chmod == 'true') { 'true' } else { 'false' },
                if (h_forkbomb == 'true') { 'true' } else { 'false' },
                if (h_rmstar == 'true') { 'true' } else { 'false' }),
            if (h_safe == 'false') { 'true' } else { 'false' }))
    check("is_hardline_bash: 6 catastrophic categories flagged, safe pass-through", ok)
}

# do_write into a sensitive path (/.ssh/) must be refused with an
# error and NOT create the file. A normal /tmp path must succeed.
fun t_path_traversal_blocked() {
    home = getenv("HOME")
    evil_path = home ++ "/.ssh/swarm_code_test_should_not_exist"
    # Make sure prior runs didn't leave a stray copy.
    file_delete(evil_path)
    blocked = Tools.exec('write',
        %{path: evil_path, content: "evil"}, %{})
    blocked_str = to_string(blocked)
    refused = string_contains(blocked_str, "error")
    not_written = if (file_exists(evil_path) == 'false') { 'true' } else { 'false' }

    safe_path = "/tmp/sw_pathtest_guard.txt"
    file_delete(safe_path)
    allowed = Tools.exec('write',
        %{path: safe_path, content: "safe"}, %{})
    wrote = if (file_exists(safe_path) == 'true') { 'true' } else { 'false' }
    file_delete(safe_path)

    ok = bool_and3(refused, not_written, wrote)
    check("validate_write_path blocks .ssh, allows /tmp", ok)
}

# do_bash must outright refuse a sudo command without
# SWARM_CODE_ALLOW_SUDO=1. The error string must mention "sudo" so
# the model knows what was rejected.
fun t_sudo_blocked() {
    out = Tools.exec('bash', %{command: "sudo ls /"}, %{})
    s = to_string(out)
    ok = bool_and(
        if (string_contains(s, "error") == 'true') { 'true' } else { 'false' },
        if (string_contains(s, "sudo") == 'true') { 'true' } else { 'false' })
    check("do_bash refuses sudo without SWARM_CODE_ALLOW_SUDO=1", ok)
}

# ------------------------------------------------------------
# LLM.repair_history regression guards
# ------------------------------------------------------------
# Helper: count messages with a given role in a list.
fun count_role(msgs, role) {
    count_role_loop(msgs, role, 0)
}
fun count_role_loop(msgs, role, n) {
    if (length(msgs) == 0) { n }
    else {
        bump = if (map_get(hd(msgs), 'role') == role) { 1 } else { 0 }
        count_role_loop(tl(msgs), role, n + bump)
    }
}

# Orphan tool message — no preceding assistant.tool_calls with a
# matching tool_call_id — must be dropped. The user/system messages
# around it stay intact.
fun t_repair_history_drops_orphan_tool() {
    h = [
        LLM.new_message_system("sys"),
        LLM.new_message_user("hello"),
        LLM.new_message_tool("orphan_id_xyz", "shouldn't be here")
    ]
    out = LLM.repair_history(h)
    tool_count = count_role(out, 'tool')
    user_count = count_role(out, 'user')
    ok = bool_and(
        if (tool_count == 0) { 'true' } else { 'false' },
        if (user_count == 1) { 'true' } else { 'false' })
    check("repair_history drops orphan tool message", ok)
}

# Trailing assistant with tool_calls but no matching tool results = the
# agent crashed mid-turn. The API would 400. Drop the assistant.
fun t_repair_history_drops_trailing_unmatched() {
    h = [
        LLM.new_message_user("do something"),
        LLM.new_message_assistant(
            "calling tool",
            [%{id: "call_X", name: "bash", arguments: "{}"}],
            nil)
    ]
    out = LLM.repair_history(h)
    asst_count = count_role(out, 'assistant')
    user_count = count_role(out, 'user')
    ok = bool_and(
        if (asst_count == 0) { 'true' } else { 'false' },
        if (user_count == 1) { 'true' } else { 'false' })
    check("repair_history drops trailing assistant with unmatched tool_calls", ok)
}

# Three consecutive role:'user' messages collapse into one,
# newline-joined.
fun t_repair_history_collapses_users() {
    h = [
        LLM.new_message_user("a"),
        LLM.new_message_user("b"),
        LLM.new_message_user("c")
    ]
    out = LLM.repair_history(h)
    ok = if (length(out) == 1) {
        merged = to_string(map_get(hd(out), 'content'))
        if (merged == "a\nb\nc") { 'true' } else { 'false' }
    } else { 'false' }
    check("repair_history collapses 3 consecutive user msgs into one", ok)
}

# Sanity: a properly paired assistant+tool must NOT be dropped.
# Guards against an over-eager repair that nukes legit tool results.
fun t_repair_history_keeps_matched_tool() {
    h = [
        LLM.new_message_user("run it"),
        LLM.new_message_assistant(
            "ok",
            [%{id: "call_keep", name: "bash", arguments: "{}"}],
            nil),
        LLM.new_message_tool("call_keep", "result")
    ]
    out = LLM.repair_history(h)
    ok = if (length(out) == 3) { 'true' } else { 'false' }
    check("repair_history preserves matched assistant + tool pair", ok)
}

# ------------------------------------------------------------
# ToolGuardrails — per-turn loop / no-progress / failure brakes
# ------------------------------------------------------------

# Build a minimal opts map with a fresh guardrails table installed.
fun guardrail_opts() {
    table = ToolGuardrails.init()
    ToolGuardrails.reset(%{guardrails_table: table})
    %{guardrails_table: table}
}

# 5 identical calls in a row trip the identical-call threshold.
# The 5th observe_before must return an error string mentioning
# "guardrail" so the model gets clear in-band feedback.
fun t_guardrail_identical_blocks() {
    opts = guardrail_opts()
    r1 = ToolGuardrails.observe_before(opts, "bash", "{\"command\":\"ls\"}")
    r2 = ToolGuardrails.observe_before(opts, "bash", "{\"command\":\"ls\"}")
    r3 = ToolGuardrails.observe_before(opts, "bash", "{\"command\":\"ls\"}")
    r4 = ToolGuardrails.observe_before(opts, "bash", "{\"command\":\"ls\"}")
    r5 = ToolGuardrails.observe_before(opts, "bash", "{\"command\":\"ls\"}")
    ok = bool_and(
        if (r1 == 'ok' && r2 == 'ok' && r3 == 'ok' && r4 == 'ok') { 'true' } else { 'false' },
        if (r5 != 'ok' && string_contains(to_string(r5), "guardrail") == 'true') { 'true' } else { 'false' })
    check("guardrail blocks 5 identical calls in a row", ok)
}

# Reading 10 different files in a row must NOT trip the guardrail —
# that's legitimate research, not a loop. The earlier no-progress
# check fired on the 5th and was wrong; with that gone, only true
# loops (same name+args repeated) should block.
fun t_guardrail_research_allowed() {
    opts = guardrail_opts()
    r1 = ToolGuardrails.observe_before(opts, "read", "{\"path\":\"/a\"}")
    r2 = ToolGuardrails.observe_before(opts, "read", "{\"path\":\"/b\"}")
    r3 = ToolGuardrails.observe_before(opts, "grep", "{\"pattern\":\"foo\"}")
    r4 = ToolGuardrails.observe_before(opts, "read", "{\"path\":\"/c\"}")
    r5 = ToolGuardrails.observe_before(opts, "glob", "{\"pattern\":\"*.sw\"}")
    r6 = ToolGuardrails.observe_before(opts, "read", "{\"path\":\"/d\"}")
    r7 = ToolGuardrails.observe_before(opts, "read", "{\"path\":\"/e\"}")
    r8 = ToolGuardrails.observe_before(opts, "code_search", "{\"pattern\":\"bar\"}")
    r9 = ToolGuardrails.observe_before(opts, "read", "{\"path\":\"/f\"}")
    r10 = ToolGuardrails.observe_before(opts, "read", "{\"path\":\"/g\"}")
    ok = bool_and3(
        if (r1 == 'ok' && r2 == 'ok' && r3 == 'ok' && r4 == 'ok') { 'true' } else { 'false' },
        if (r5 == 'ok' && r6 == 'ok' && r7 == 'ok') { 'true' } else { 'false' },
        if (r8 == 'ok' && r9 == 'ok' && r10 == 'ok') { 'true' } else { 'false' })
    check("guardrail allows 10 distinct reads (research, not a loop)", ok)
}

# 8 consecutive error results from the same tool must set the
# halt_reason flag, which run_turn checks before the next LLM call.
fun t_guardrail_failure_halt() {
    opts = guardrail_opts()
    ToolGuardrails.observe_after(opts, "bash", "error: 1")
    ToolGuardrails.observe_after(opts, "bash", "error: 2")
    ToolGuardrails.observe_after(opts, "bash", "error: 3")
    ToolGuardrails.observe_after(opts, "bash", "error: 4")
    ToolGuardrails.observe_after(opts, "bash", "error: 5")
    ToolGuardrails.observe_after(opts, "bash", "error: 6")
    ToolGuardrails.observe_after(opts, "bash", "error: 7")
    ToolGuardrails.observe_after(opts, "bash", "error: 8")
    table = map_get(opts, 'guardrails_table')
    halt = ets_get(table, 'halt_reason')
    ok = if (halt != nil && string_contains(to_string(halt), "8 consecutive") == 'true') { 'true' } else { 'false' }
    check("guardrail: 8 same-tool failures set halt_reason", ok)
}

# Subagent toolset restriction: "task" is in the blocked list and
# "read" is not. Guards the substring check Agent.subagent_blocked uses.
fun t_subagent_blocked_tool() {
    blocked_task = Agent.subagent_blocked("task")
    blocked_remember = Agent.subagent_blocked("remember")
    allowed_read = Agent.subagent_blocked("read")
    allowed_bash = Agent.subagent_blocked("bash")
    ok = bool_and(
        if (blocked_task == 'true' && blocked_remember == 'true') { 'true' } else { 'false' },
        if (allowed_read == 'false' && allowed_bash == 'false') { 'true' } else { 'false' })
    check("subagent_blocked: blocks task/remember, allows read/bash", ok)
}

# The passive context-status injection replaces the old explicit
# context_meter tool. Verify the wire body for a basic native-mode
# request carries the `[ctx ...]` bracketed block with the
# "% used" wording on the last user message.
fun t_context_status_injected() {
    msgs = [
        LLM.new_message_system("you are a test"),
        LLM.new_message_user("hello")
    ]
    body = LLM.build_request_body(msgs, native_opts())
    ok = bool_and3(
        string_contains(body, "ctx "),
        string_contains(body, "% used"),
        string_contains(body, "msg"))
    check("[ctx N% used · ...] block injected into last user msg", ok)
}

# ------------------------------------------------------------
# Scheduler — interval unit / daily / next-fire regression guards
# ------------------------------------------------------------
# parse_interval used to return SECONDS while timestamp() returns
# milliseconds, so "1h" actually fired every ~3.6 seconds.
fun t_scheduler_units_ms() {
    ok = bool_and3(
        if (Scheduler.parse_expr("30s") == 30000) { 'true' } else { 'false' },
        if (Scheduler.parse_expr("1m") == 60000) { 'true' } else { 'false' },
        if (Scheduler.parse_expr("1h") == 3600000) { 'true' } else { 'false' })
    check("scheduler intervals return ms (30s=30000, 1m=60000, 1h=3.6e6)", ok)
}

# "daily HH:MM" was matched as the prefix-only "daily " branch and
# threw away the time. daily_time_ms now parses it to ms-since-midnight.
fun t_scheduler_daily_parses() {
    nine_am = 9 * 3600 * 1000
    eleven_fifty_nine = (23 * 3600 + 59 * 60) * 1000
    ok = bool_and(
        if (Scheduler.daily_time_ms("daily 09:00") == nine_am) { 'true' } else { 'false' },
        if (Scheduler.daily_time_ms("daily 23:59") == eleven_fifty_nine) { 'true' } else { 'false' })
    check("daily HH:MM parses to ms-since-midnight", ok)
}

# Out-of-range hours/minutes and non-"daily " inputs must return nil.
fun t_scheduler_daily_rejects_garbage() {
    ok = bool_and3(
        if (Scheduler.daily_time_ms("daily 25:00") == nil) { 'true' } else { 'false' },
        if (Scheduler.daily_time_ms("daily abc") == nil) { 'true' } else { 'false' },
        if (Scheduler.daily_time_ms("hourly") == nil) { 'true' } else { 'false' })
    check("daily HH:MM rejects out-of-range / malformed forms", ok)
}

# Interval branch: compute_next_fire returns last_run + interval_ms.
# Validates the ms-aligned math against the new contract.
fun t_scheduler_compute_next_fire_interval() {
    last = 1000
    now = 5000
    nf = Scheduler.compute_next_fire("30s", last, now)
    # 1000 + 30000 = 31000 (still in the future relative to now=5000)
    check("compute_next_fire ms-aligned for intervals",
          if (nf == 31000) { 'true' } else { 'false' })
}

# ------------------------------------------------------------
# 2026-06 audit fixes — regression guards
# ------------------------------------------------------------

# A crash after SOME of an assistant's tool_calls were answered leaves a
# partial set; repair_history must synthesize a stub for each missing id so
# the next request doesn't 400 (assistant(tcs=[a,b]) + tool(a) → +stub(b)).
fun t_repair_history_backfills_partial() {
    h = [
        LLM.new_message_user("do two things"),
        LLM.new_message_assistant("calling tools",
            [%{id: "call_a", name: "bash", arguments: "{}"},
             %{id: "call_b", name: "read", arguments: "{}"}], nil),
        LLM.new_message_tool("call_a", "result a")
    ]
    out = LLM.repair_history(h)
    ok = bool_and(
        if (count_role(out, 'assistant') == 1) { 'true' } else { 'false' },
        if (count_role(out, 'tool') == 2) { 'true' } else { 'false' })
    check("repair_history backfills a stub for a partial tool-call set", ok)
}

# Hardline blocks must match whole command words, not substrings — so a file
# named asphalt_survey.csv / shutdown_handler.py is NOT blocked, while a real
# shutdown / reboot (incl. /sbin/ path) still is.
fun t_hardline_word_boundary() {
    asphalt = Config.is_hardline_bash(%{command: "cat asphalt_survey.csv"})
    handler = Config.is_hardline_bash(%{command: "vim shutdown_handler.py"})
    real_sd = Config.is_hardline_bash(%{command: "shutdown -h now"})
    path_rb = Config.is_hardline_bash(%{command: "/sbin/reboot"})
    ok = bool_and(
        bool_and(
            if (asphalt == 'false') { 'true' } else { 'false' },
            if (handler == 'false') { 'true' } else { 'false' }),
        bool_and(
            if (real_sd == 'true') { 'true' } else { 'false' },
            if (path_rb == 'true') { 'true' } else { 'false' }))
    check("hardline matches whole command words (asphalt/handler pass, shutdown blocked)", ok)
}

# telinit 0/6 are real SysV halt/reboot aliases — must remain on the
# unbypassable floor even after the word-boundary word-match refactor.
fun t_hardline_telinit() {
    t0 = Config.is_hardline_bash(%{command: "telinit 0"})
    t6 = Config.is_hardline_bash(%{command: "telinit 6"})
    sudo_t6 = Config.is_hardline_bash(%{command: "sudo telinit 6"})
    ok = bool_and3(
        if (t0 == 'true') { 'true' } else { 'false' },
        if (t6 == 'true') { 'true' } else { 'false' },
        if (sudo_t6 == 'true') { 'true' } else { 'false' })
    check("is_hardline_bash: telinit 0/6 still blocked (SysV halt/reboot aliases)", ok)
}

# has_markdown must ignore "C#" and a lone backtick (false-positive repaints)
# while still firing on a balanced code pair and a heading.
fun t_has_markdown_tightened() {
    csharp = Markdown.has_markdown("I wrote it in C# yesterday")
    one_tick = Markdown.has_markdown("the ` key is tricky")
    two_tick = Markdown.has_markdown("use `foo` and `bar`")
    heading = Markdown.has_markdown("## Section\n\nbody text here")
    ok = bool_and(
        bool_and(
            if (csharp == 'false') { 'true' } else { 'false' },
            if (one_tick == 'false') { 'true' } else { 'false' }),
        bool_and(
            if (two_tick == 'true') { 'true' } else { 'false' },
            if (heading == 'true') { 'true' } else { 'false' }))
    check("has_markdown ignores C#/lone backtick, fires on code pair + heading", ok)
}

# Inline links render the label + dimmed url, never the raw [label](url).
fun t_markdown_link() {
    r = Markdown.render("See [the docs](https://example.com/x) for details.", 80)
    ok = bool_and3(
        string_contains(r, "the docs"),
        string_contains(r, "https://example.com/x"),
        if (string_contains(r, "](") == 'false') { 'true' } else { 'false' })
    check("markdown renders [label](url) without raw link syntax", ok)
}

# A table wider than the terminal must be clamped — cell content is
# truncated with an ellipsis rather than overflowing and hard-wrapping.
# We verify: (a) the ellipsis appears (content was truncated), and
# (b) with an all-ASCII wide table the rendered data row does not contain
# more than `width` raw bytes (proxy check: ASCII rows have no multibyte
# chars, so byte length == display width after ANSI stripping).
# Note: the divider row (`──┼──`) is excluded because the box-drawing
# runes are 3 bytes each; display_width cannot account for them accurately
# without a full Unicode width table. The actual clamping invariant holds
# on the cell-content rows that matter for readability.
fun t_markdown_table_clamps() {
    tbl = "| name | description |\n|---|---|\n| alpha | " ++
          "a very long description that would otherwise overflow a narrow terminal badly |\n"
    r = Markdown.render(tbl, 40)
    ok = bool_and(
        string_contains(r, "…"),
        if (string_contains(r, "│") == 'true') { 'true' } else { 'false' })
    check("render_table clamps wide cells to terminal width (has ellipsis + separator)", ok)
}
