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
import Agents
import Mcp
import HarnessLimits

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
        t_chat_url(),
        t_markdown_basic(),
        t_markdown_empty(),
        t_markdown_oneline(),
        t_dangerous_bash(),
        t_slugify(),
        t_glob(),
        t_grep(),
        t_registry_list_names(),
        t_mcp_unconfigured(),
        HarnessLimits.run_all()
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
# LLM — native-mode request reconstruction
# ------------------------------------------------------------
# The infinite-write loop: native mode dropped the assistant's
# tool_calls and the <tool_result> pairing when re-sending history.
# build_request_body must rebuild proper tool_calls[] + role:tool.
fun native_history() {
    [
        {'system', "you are a test"},
        {'user', "make a file"},
        {'assistant', "Sure.\ncall:write{\"path\":\"/tmp/x\",\"content\":\"hi\"}"},
        {'user', "<tool_result>\nok: wrote 2 bytes\n</tool_result>"}
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
        string_contains(body, "swc_2_0"))
    check("native build_request_body rebuilds tool_calls + tool role", ok)
}

# The raw <tool_result> wrapper must be stripped — leaving it in
# would desync the OpenAI protocol.
fun t_native_no_wrapper() {
    body = LLM.build_request_body(native_history(), native_opts())
    check("native build strips <tool_result> wrapper",
          if (string_contains(body, "<tool_result>") == 'false') { 'true' } else { 'false' })
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

# Agents.registry_list_names walked ets_list with elem(e, 0), treating
# each key as a {k,v} tuple — but ets_list returns bare keys (strings),
# so `list_agents` panicked "elem: not a tuple (got type 3)". Must
# return the registered names without crashing.
fun t_registry_list_names() {
    reg = Agents.init()
    ets_put(reg, "alpha-tester", %{role: "math whiz"})
    ets_put(reg, "beta-tester", %{role: "poet"})
    names = Agents.registry_list_names(reg)
    check("registry_list_names returns agent names (list_agents crash)",
          if (length(names) == 2) { 'true' } else { 'false' })
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
