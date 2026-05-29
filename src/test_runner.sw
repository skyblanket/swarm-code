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
        t_spawn_send_receive()
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
