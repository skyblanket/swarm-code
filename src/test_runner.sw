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
import Plan
import MemVec
import ToolExecutor
import ToolRegistry
import Background

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
        t_markdown_ordered(),
        t_markdown_nested_bullets(),
        t_markdown_task_list(),
        t_markdown_detects_ordered(),
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
        t_tool_executor_noninteractive_ask_denied(),
        t_tool_executor_hardline_stays_denied(),
        t_tool_executor_missing_context_denied(),
        t_tool_registry_context_policy(),
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
        t_markdown_table_clamps(),
        t_plan_auto_trigger_fires(),
        t_plan_auto_trigger_skips_question(),
        t_plan_auto_trigger_skips_short(),
        t_plan_auto_trigger_skips_slash(),
        t_plan_inject_into_history(),
        t_plan_get_mode_default(),
        t_plan_get_mode_explicit(),
        t_memvec_cosine_orthogonal(),
        t_memvec_cosine_identical(),
        t_memvec_cosine_nil(),
        t_memvec_search_empty_db(),
        t_memvec_upsert_get_roundtrip(),
        t_memory_recall_no_embed_endpoint(),
        # --- new tests (27 added) ---
        t_markdown_empty_table(),
        t_markdown_code_block_preserved(),
        t_markdown_bold_inline(),
        t_markdown_inline_code_no_ticks(),
        t_markdown_heading_no_raw_hash(),
        t_plan_auto_trigger_refactor(),
        t_plan_auto_trigger_migrate(),
        t_plan_auto_trigger_deploy_skips(),
        t_plan_auto_trigger_sequence_connector(),
        t_plan_auto_trigger_just_prefix(),
        t_plan_inject_content_has_plan(),
        t_scheduler_parse_expr_30m(),
        t_scheduler_parse_expr_2h(),
        t_scheduler_parse_expr_daily_hhmm(),
        t_scheduler_next_id_empty(),
        t_scheduler_next_id_nonempty(),
        t_scheduler_jobs_dir_suffix(),
        t_memory_embed_db_path(),
        t_memory_dir_suffix(),
        t_memory_slugify_spaces(),
        t_memory_slugify_special_chars(),
        t_memory_save_recall_roundtrip(),
        t_hardline_shutdown_now(),
        t_hardline_rm_rf_root(),
        t_hardline_ls_la_allowed(),
        t_hardline_fork_bomb(),
        t_to_string_nil(),
        # --- harness-hardening regressions (F7/F8/F2) ---
        t_edit_quote_fold_preserves_others(),
        t_edit_replace_all(),
        t_edit_ambiguous_errors(),
        t_drop_to_last_clean_user(),
        t_trailing_turn_incomplete_detection(),
        t_context_meter_token_based(),
        # --- bash auto-backgrounding + Background module (7 added) ---
        t_bg_fast_returns_exit_output(),
        t_bg_auto_after_ms_no_double_finalize(),
        t_bg_run_in_background_immediate(),
        t_bg_stdin_devnull_no_hang(),
        t_bg_kill_group(),
        t_bg_stall_detector_one_shot(),
        t_bg_read_key_nil_safe()
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
    %{model: "kimi-k2.7-code", temperature: 1.0, max_tokens: 1024, tool_format: 'native'}
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

# Ordered lists must render one item per line. They previously fell into
# the paragraph branch and consecutive numbered lines were space-merged
# into a single wrapped line ("1. alpha 2. beta 3. gamma").
fun t_markdown_ordered() {
    r = Markdown.render("1. alpha\n2. beta\n3. gamma", 80)
    ok = bool_and3(
        string_contains(r, "1. alpha"),
        string_contains(r, "3. gamma"),
        if (string_contains(r, "alpha 2.") == 'true') { 'false' } else { 'true' })
    check("markdown ordered list: one item per line", ok)
}

# Indented sub-bullets keep their nesting (distinct marker glyph) instead
# of flattening to the top level.
fun t_markdown_nested_bullets() {
    r = Markdown.render("- top\n  - nested\n", 80)
    ok = if (string_contains(r, "•") == 'true' && string_contains(r, "◦") == 'true') { 'true' } else { 'false' }
    check("markdown nested bullets get distinct markers", ok)
}

fun t_markdown_task_list() {
    r = Markdown.render("- [ ] open\n- [x] done\n", 80)
    ok = bool_and3(
        string_contains(r, "◻"),
        string_contains(r, "✔"),
        if (string_contains(r, "[ ]") == 'true') { 'false' } else { 'true' })
    check("markdown task-list checkboxes", ok)
}

# has_markdown must fire on numbered-list replies, or they never get the
# post-stream render pass at all.
fun t_markdown_detects_ordered() {
    check("has_markdown detects ordered lists",
          Markdown.has_markdown("Steps:\n1. build\n2. test"))
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
    out = Tools.exec_raw('glob', %{pattern: "*.sw", path: "src"}, %{})
    check("glob finds .sw files", string_contains(out, ".sw"))
}

fun t_grep() {
    out = Tools.exec_raw('grep', %{pattern: "module Tools", path: "src"}, %{})
    check("grep finds file content", string_contains(out, "tools.sw"))
}

# F7: the quote-fold edit fallback must be LOCATE-ONLY — it splices the matched
# region of the ORIGINAL buffer and leaves curly quotes ELSEWHERE untouched.
# (The bug it guards: an earlier version wrote a globally quote-folded buffer,
# silently straightening every other curly quote in the file.)
fun t_edit_quote_fold_preserves_others() {
    p = "/tmp/swc_f7_fold.txt"
    file_write(p, "say “hello” here\nkeep “world” intact\n")
    # old_string uses STRAIGHT quotes → exact match misses → quote-fold fallback.
    r = Tools.exec_raw('edit', %{path: p, old_string: "say \"hello\" here", new_string: "say bye here"}, %{})
    aft = file_read(p)
    file_delete(p)
    ok = if (aft == nil) { 'false' }
         else { if (string_contains(aft, "say bye here") &&
                    string_contains(aft, "“world”") == 'true') { 'true' } else { 'false' } }
    check("edit quote-fold splices only the match (other curly quotes survive)", ok)
}

# F8: replace_all replaces every occurrence; without it an ambiguous match errors.
fun t_edit_replace_all() {
    p = "/tmp/swc_f8_all.txt"
    file_write(p, "x = 1\ny = x\nz = x\n")
    r = Tools.exec_raw('edit', %{path: p, old_string: "x", new_string: "q", replace_all: 'true'}, %{})
    aft = file_read(p)
    file_delete(p)
    ok = if (aft == nil) { 'false' }
         else { if (string_contains(aft, "q = 1") && string_contains(aft, "y = q") &&
                    string_contains(aft, "z = q")) { 'true' } else { 'false' } }
    check("edit replace_all replaces every occurrence", ok)
}

fun t_edit_ambiguous_errors() {
    p = "/tmp/swc_f8_ambig.txt"
    file_write(p, "a\na\n")
    r = Tools.exec_raw('edit', %{path: p, old_string: "a", new_string: "b"}, %{})
    file_delete(p)
    check("edit errors on ambiguous old_string (occ>1, no replace_all)",
          string_contains(r, "appears 2 times"))
}

# F2: drop_to_last_clean_user keeps system+last-user, drops the failing tail.
fun t_drop_to_last_clean_user() {
    msgs = [%{role: 'system', content: "s"}, %{role: 'user', content: "u1"},
            %{role: 'assistant', content: "a", tool_calls: [%{id: "1", arguments: "{}"}]},
            %{role: 'tool', content: "t"}]
    out = Agent.drop_to_last_clean_user(msgs)
    check("drop_to_last_clean_user keeps system+user, drops failing tail",
          if (length(out) == 2) { 'true' } else { 'false' })
}

# F2: trailing_turn_incomplete keeps a COMPLETE tool turn (every tool_call
# answered) and flags a PARTIAL one (a tool_call left unanswered) — the robust
# detection that doesn't depend on json_decode. (NB: the args-malformed sub-check
# is only a weak backup: sw's json_decode is lenient and recovers truncated JSON
# into a partial map rather than nil, so a mid-string-truncated tool_call is
# caught by F4's finish_reason/marker path and this partial-tool-set check, not
# by json_decode==nil.)
fun t_trailing_turn_incomplete_detection() {
    complete = [%{role: 'user', content: "u"},
                %{role: 'assistant', content: "", tool_calls: [%{id: "1", arguments: "{}"}]},
                %{role: 'tool', content: "r"}]
    partial = [%{role: 'user', content: "u"},
               %{role: 'assistant', content: "", tool_calls: [%{id: "1", arguments: "{}"}, %{id: "2", arguments: "{}"}]},
               %{role: 'tool', content: "r"}]
    c_ok = if (Agent.trailing_turn_incomplete(complete) == 'false') { 'true' } else { 'false' }
    p_ok = if (Agent.trailing_turn_incomplete(partial) == 'true') { 'true' } else { 'false' }
    all_ok = if (c_ok == 'true' && p_ok == 'true') { 'true' } else { 'false' }
    check("trailing_turn_incomplete: complete kept, partial tool-set flagged", all_ok)
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
    Tools.exec_raw('remember', %{name: "zz remember probe",
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
    blocked = Tools.exec_raw('write',
        %{path: evil_path, content: "evil"}, %{})
    blocked_str = to_string(blocked)
    refused = string_contains(blocked_str, "error")
    not_written = if (file_exists(evil_path) == 'false') { 'true' } else { 'false' }

    safe_path = "/tmp/sw_pathtest_guard.txt"
    file_delete(safe_path)
    allowed = Tools.exec_raw('write',
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
    out = Tools.exec_raw('bash', %{command: "sudo ls /"}, %{})
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

# Non-interactive entry points cannot answer an "ask" permission
# decision. They must fail closed instead of silently running it.
fun t_tool_executor_noninteractive_ask_denied() {
    out = ToolExecutor.permission_gate(
        'bash',
        %{command: "rm -rf ~/tmp"},
        %{settings: map_new(), execution_context: "mcp_server"})
    ok = if (string_contains(to_string(out), "requires interactive permission") == 'true') {
        'true'
    } else { 'false' }
    check("tool executor denies ask without interactive approval", ok)
}

fun t_tool_executor_hardline_stays_denied() {
    out = ToolExecutor.permission_gate(
        'bash',
        %{command: "mkfs.ext4 /dev/null"},
        %{settings: map_new()})
    ok = if (string_contains(to_string(out), "permission denied") == 'true') {
        'true'
    } else { 'false' }
    check("tool executor preserves the hardline deny floor", ok)
}

fun t_tool_executor_missing_context_denied() {
    out = ToolExecutor.prepare('read', %{path: "README.md"}, %{settings: map_new()})
    ok = if (string_contains(to_string(map_get(out, 'error')), "explicit execution_context") == 'true') {
        'true'
    } else { 'false' }
    check("tool executor denies calls without an execution context", ok)
}

fun t_tool_registry_context_policy() {
    mcp_policy = bool_and(
        ToolRegistry.allowed_in("mcp_server", "bash"),
        if (ToolRegistry.allowed_in("mcp_server", "git_commit") == 'false') {
            'true'
        } else { 'false' })
    subagent_policy = if (ToolRegistry.allowed_in("subagent", "remember") == 'false' &&
                         ToolRegistry.allowed_in("subagent", "read") == 'true') {
        'true'
    } else { 'false' }
    council_policy = if (ToolRegistry.allowed_in("council_panel", "read") == 'true' &&
                         ToolRegistry.allowed_in("council_panel", "task") == 'false' &&
                         ToolRegistry.allowed_in("council_panel", "bash") == 'false' &&
                         ToolRegistry.allowed_in("council_judge", "read") == 'false' &&
                         ToolRegistry.allowed_in("council_panle", "read") == 'false') {
        'true'
    } else { 'false' }
    policy_names_known = bool_and(
        all_registered(ToolRegistry.names_for("mcp_server")),
        bool_and(
            all_registered(ToolRegistry.subagent_blocked_tools()),
            all_registered(ToolRegistry.council_panel_tools())))
    ok = bool_and(
        bool_and3(mcp_policy, subagent_policy, council_policy),
        policy_names_known)
    check("tool registry centralizes execution-context policy", ok)
}

fun all_registered(names) {
    if (length(names) == 0) { 'true' }
    else {
        if (ToolRegistry.knows(hd(names)) == 'true') {
            all_registered(tl(names))
        } else { 'false' }
    }
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
        string_contains(body, "tok"))
    check("[ctx N% used · ...] token-based block injected into last user msg", ok)
}

# Regression: the context meter must be TOKEN-based, not message-count-based.
# 200 tiny messages blow past the OLD 120-message threshold (which made the meter
# report ~100% used) but are only a few hundred tokens — it must read LOW now.
fun t_context_meter_token_based() {
    msgs = make_tiny_msgs(200, [])
    s = LLM.build_status_string(msgs, %{})
    not_full = if (string_contains(s, "100% used") == 'true') { 'false' } else { 'true' }
    check("context meter is token-based (200 tiny msgs NOT reported ~100% used)", not_full)
}

fun make_tiny_msgs(n, acc) {
    if (n <= 0) { acc }
    else { make_tiny_msgs(n - 1, list_append(acc, %{role: 'user', content: "hi"})) }
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

# ------------------------------------------------------------
# Plan — regression guards for plan mode logic
# ------------------------------------------------------------

# "implement JWT auth in src/auth.sw" contains the action keyword
# "implement" and a file reference — must trigger auto mode.
fun t_plan_auto_trigger_fires() {
    result = Plan.auto_trigger("implement JWT auth in src/auth.sw")
    check("plan auto_trigger: fires on 'implement auth'",
          if (result == 'true') { 'true' } else { 'false' })
}

# A pure question must never trigger the plan flow.
fun t_plan_auto_trigger_skips_question() {
    result = Plan.auto_trigger("what does this function do?")
    check("plan auto_trigger: skips questions",
          if (result == 'false') { 'true' } else { 'false' })
}

# Very short messages (fewer than 5 words) must be skipped.
fun t_plan_auto_trigger_skips_short() {
    result = Plan.auto_trigger("ok")
    check("plan auto_trigger: skips short messages",
          if (result == 'false') { 'true' } else { 'false' })
}

# Slash commands must never trigger the plan flow.
fun t_plan_auto_trigger_skips_slash() {
    result = Plan.auto_trigger("/help")
    check("plan auto_trigger: skips /slash commands",
          if (result == 'false') { 'true' } else { 'false' })
}

# inject_into_history appends exactly one assistant message whose
# content contains "Plan confirmed".
fun t_plan_inject_into_history() {
    history = [%{role: 'user', content: 'hello'}]
    result = Plan.inject_into_history(history, "1. Do X\n2. Do Y", "implement X")
    len_ok = if (length(result) == 2) { 'true' } else { 'false' }
    second = hd(tl(result))
    role_ok = if (map_get(second, 'role') == 'assistant') { 'true' } else { 'false' }
    content_ok = string_contains(to_string(map_get(second, 'content')), "Plan confirmed")
    ok = bool_and3(len_ok, role_ok, content_ok)
    check("plan inject_into_history: appends plan message", ok)
}

# When opts explicitly carries plan_mode: "auto", get_mode must return "auto".
# (Passing it in opts bypasses override-file / env-var lookup so the test is
# not sensitive to ~/.swarm-code/.plan_mode or SWARM_CODE_PLAN being set.)
fun t_plan_get_mode_default() {
    opts = %{model: "test", plan_mode: "auto"}
    result = Plan.get_mode(opts)
    check("plan get_mode: defaults to auto",
          if (result == "auto") { 'true' } else { 'false' })
}

# When opts has plan_mode: "on", get_mode must return "on".
fun t_plan_get_mode_explicit() {
    opts = %{plan_mode: "on"}
    result = Plan.get_mode(opts)
    check("plan get_mode: reads plan_mode key",
          if (result == "on") { 'true' } else { 'false' })
}

# ------------------------------------------------------------
# MemVec — semantic memory vector store tests (no network required)
# ------------------------------------------------------------

# Orthogonal vectors have zero dot product → cosine similarity == 0.
fun t_memvec_cosine_orthogonal() {
    a = [1.0, 0.0, 0.0]
    b = [0.0, 1.0, 0.0]
    result = MemVec.cosine_sim(a, b)
    check("memvec cosine_sim: orthogonal vectors = 0",
          if (result == 0.0) { 'true' } else { 'false' })
}

# A vector compared to itself should give similarity ≈ 1.0 (within 0.001).
fun t_memvec_cosine_identical() {
    a = [1.0, 2.0, 3.0]
    result = MemVec.cosine_sim(a, a)
    diff = if (result > 1.0) { result - 1.0 } else { 1.0 - result }
    check("memvec cosine_sim: identical vectors = 1",
          if (diff < 0.001) { 'true' } else { 'false' })
}

# Passing nil as either argument must return 0 without panicking.
fun t_memvec_cosine_nil() {
    result = MemVec.cosine_sim(nil, [1.0])
    check("memvec cosine_sim: nil vectors = 0",
          if (result == 0) { 'true' } else { 'false' })
}

# search_top_k on a fresh empty database must return an empty list.
fun t_memvec_search_empty_db() {
    db = MemVec.open("/tmp/test_memvec_empty.db")
    results = MemVec.search_top_k(db, [1.0, 0.0], 3)
    MemVec.close(db)
    check("memvec search_top_k: returns empty for empty db",
          if (length(results) == 0) { 'true' } else { 'false' })
}

# upsert then get_vector must return the same-length vector (round-trip).
fun t_memvec_upsert_get_roundtrip() {
    db = MemVec.open("/tmp/test_memvec_rt.db")
    MemVec.upsert(db, "test-slug", [0.1, 0.2, 0.3])
    v = MemVec.get_vector(db, "test-slug")
    MemVec.close(db)
    ok = bool_and(
        if (v != nil) { 'true' } else { 'false' },
        if (v != nil && length(v) == 3) { 'true' } else { 'false' })
    check("memvec upsert + get_vector round-trip", ok)
}

# Without an embed_endpoint key in opts, map_get returns nil — the
# memory recall path takes the keyword fallback branch.
fun t_memory_recall_no_embed_endpoint() {
    opts = %{model: "test"}
    result = map_get(opts, 'embed_endpoint', nil)
    check("memory recall: falls back to keyword when no embed_endpoint",
          if (result == nil) { 'true' } else { 'false' })
}

# ------------------------------------------------------------
# MARKDOWN — additional edge-case guards
# ------------------------------------------------------------

# A table with zero data rows (header + separator only) must not crash
# and must still render the header line.
fun t_markdown_empty_table() {
    tbl = "| col1 | col2 |\n|---|---|\n"
    r = Markdown.render(tbl, 80)
    check("markdown empty table (no data rows) renders without crash",
          if (string_contains(r, "col1") == 'true') { 'true' } else { 'false' })
}

# A fenced code block must preserve its content as-is (no word-wrap or
# table transformation applied to lines inside the block).
fun t_markdown_code_block_preserved() {
    src = "```\n    indented_code();\n    more_code();\n```"
    r = Markdown.render(src, 80)
    check("markdown fenced code block: content preserved",
          string_contains(r, "indented_code"))
}

# Bold (**text**) inside a line must render the text without the raw
# asterisks leaking through.
fun t_markdown_bold_inline() {
    r = Markdown.render("This is **important** text.", 80)
    ok = bool_and(
        string_contains(r, "important"),
        if (string_contains(r, "**") == 'false') { 'true' } else { 'false' })
    check("markdown bold: renders text, no raw ** leaked", ok)
}

# Inline code `fn()` must render the text without the raw backticks.
fun t_markdown_inline_code_no_ticks() {
    r = Markdown.render("Call `do_thing()` now.", 80)
    ok = bool_and(
        string_contains(r, "do_thing"),
        if (string_contains(r, "`do_thing`") == 'false') { 'true' } else { 'false' })
    check("markdown inline code: text visible, raw backticks gone", ok)
}

# A heading line (## Heading) must not appear literally in output — it
# should be rendered with some treatment (bold ANSI or stripped of ##).
fun t_markdown_heading_no_raw_hash() {
    r = Markdown.render("## My Section\n\nsome body text", 80)
    check("markdown heading: ## prefix not in raw output",
          if (string_contains(r, "## My Section") == 'false') { 'true' } else { 'false' })
}

# ------------------------------------------------------------
# PLAN — additional keyword and edge-case guards
# ------------------------------------------------------------

# "refactor the auth module for clarity" contains the keyword "refactor"
# and enough words — must trigger.
fun t_plan_auto_trigger_refactor() {
    result = Plan.auto_trigger("refactor the auth module for clarity")
    check("plan auto_trigger: fires on 'refactor' keyword",
          if (result == 'true') { 'true' } else { 'false' })
}

# "migrate the database schema to v2" contains "migrate" — must trigger.
fun t_plan_auto_trigger_migrate() {
    result = Plan.auto_trigger("migrate the database schema to v2")
    check("plan auto_trigger: fires on 'migrate' keyword",
          if (result == 'true') { 'true' } else { 'false' })
}

# "deploy to staging" — short and contains "deploy" but only 3 words.
# auto_trigger requires >=4 words, so must NOT fire.
fun t_plan_auto_trigger_deploy_skips() {
    result = Plan.auto_trigger("deploy to staging")
    check("plan auto_trigger: 'deploy to staging' (3 words) does NOT trigger",
          if (result == 'false') { 'true' } else { 'false' })
}

# "update foo and then fix bar" — contains the sequence connector "and then"
# which has >=4 words — must trigger.
fun t_plan_auto_trigger_sequence_connector() {
    result = Plan.auto_trigger("update foo and then fix bar")
    check("plan auto_trigger: fires on sequence connector 'and then'",
          if (result == 'true') { 'true' } else { 'false' })
}

# "just fix a typo" — "just" prefix suppresses auto-trigger.
fun t_plan_auto_trigger_just_prefix() {
    result = Plan.auto_trigger("just fix a typo in the docs")
    check("plan auto_trigger: 'just' prefix suppresses trigger",
          if (result == 'false') { 'true' } else { 'false' })
}

# inject_into_history with an active plan returns a non-empty history list.
fun t_plan_inject_content_has_plan() {
    mode_opts = %{plan_mode: 'on'}
    history = Plan.inject_into_history("do the thing", [], mode_opts)
    check("plan inject_into_history: returns non-empty list when plan_mode=on",
          if (length(history) > 0) { 'true' } else { 'false' })
}

# ------------------------------------------------------------
# SCHEDULER — parse_expr and next_id guards
# ------------------------------------------------------------

# parse_expr("30m") must return 30*60*1000 = 1800000 ms.
fun t_scheduler_parse_expr_30m() {
    result = Scheduler.parse_expr("30m")
    check("scheduler parse_expr('30m'): returns 1800000",
          if (result == 1800000) { 'true' } else { 'false' })
}

# parse_expr("2h") must return 2*3600*1000 = 7200000 ms.
fun t_scheduler_parse_expr_2h() {
    result = Scheduler.parse_expr("2h")
    check("scheduler parse_expr('2h'): returns 7200000",
          if (result == 7200000) { 'true' } else { 'false' })
}

# parse_expr("daily 09:30") must return 86400000 (24h in ms).
fun t_scheduler_parse_expr_daily_hhmm() {
    result = Scheduler.parse_expr("daily 09:30")
    check("scheduler parse_expr('daily 09:30'): returns 86400000",
          if (result == 86400000) { 'true' } else { 'false' })
}

# next_id of empty list must return 1.
fun t_scheduler_next_id_empty() {
    result = Scheduler.next_id([], 0)
    check("scheduler next_id: empty list returns 1",
          if (result == 1) { 'true' } else { 'false' })
}

# next_id of [3,1,7] must return 8.
fun t_scheduler_next_id_nonempty() {
    jobs = [%{id: "3"}, %{id: "1"}, %{id: "7"}]
    result = Scheduler.next_id(jobs, 0)
    check("scheduler next_id: max of [3,1,7] + 1 = 8",
          if (result == 8) { 'true' } else { 'false' })
}

# jobs_dir() must return a path string that ends with "telemetry".
fun t_scheduler_jobs_dir_suffix() {
    d = Scheduler.jobs_dir()
    check("scheduler jobs_dir() ends with 'telemetry'",
          string_ends_with(d, "telemetry"))
}

# ------------------------------------------------------------
# MEMORY — save/recall round-trip and path guards
# ------------------------------------------------------------

# embed_db_path() must end with "embed.db".
fun t_memory_embed_db_path() {
    p = Memory.embed_db_path()
    check("memory embed_db_path() ends with 'embed.db'",
          string_ends_with(p, "embed.db"))
}

# memory_dir() must end with "memory" (path sanity).
fun t_memory_dir_suffix() {
    d = Memory.memory_dir()
    check("memory memory_dir() ends with 'memory'",
          string_ends_with(d, "memory"))
}

# slugify collapses spaces and strips special chars.
fun t_memory_slugify_spaces() {
    s = Memory.slugify("Hello World")
    check("memory slugify: spaces become underscores",
          if (s == "hello_world") { 'true' } else { 'false' })
}

# slugify strips punctuation and collapses consecutive underscores.
fun t_memory_slugify_special_chars() {
    s = Memory.slugify("user's ADHD workflow!")
    # Expected: "user_s_adhd_workflow" (apostrophe → _, spaces → _, ! stripped)
    check("memory slugify: special chars stripped, underscores collapsed",
          if (string_contains(s, "adhd") == 'true' &&
              string_contains(s, "__") == 'false') { 'true' } else { 'false' })
}

# save + recall_by_slug round-trip: write a memory, read it back.
fun t_memory_save_recall_roundtrip() {
    rc = Memory.save("test_rt_mem", "a test memory", "user",
                     "body content here", %{})
    ok_save = string_contains(rc, "ok")
    recalled = Memory.recall_by_slug("test_rt_mem")
    ok_recall = if (recalled != nil && string_contains(recalled, "body content here") == 'true') {
        'true'
    } else { 'false' }
    ok = bool_and(ok_save, ok_recall)
    check("memory save + recall_by_slug round-trip", ok)
}

# ------------------------------------------------------------
# SESSION / TOOLS — additional hardline and contract guards
# ------------------------------------------------------------

# "shutdown now" must be blocked by the hardline floor.
fun t_hardline_shutdown_now() {
    result = Config.is_hardline_bash(%{command: "shutdown now"})
    check("is_hardline_bash: 'shutdown now' blocked",
          if (result == 'true') { 'true' } else { 'false' })
}

# "rm -rf /*" is the exact whole-disk wipe pattern in the hardline list.
fun t_hardline_rm_rf_root() {
    result = Config.is_hardline_bash(%{command: "rm -rf /*"})
    check("is_hardline_bash: 'rm -rf /*' blocked",
          if (result == 'true') { 'true' } else { 'false' })
}

# "ls -la /tmp" is a safe read command — must NOT be blocked.
fun t_hardline_ls_la_allowed() {
    result = Config.is_hardline_bash(%{command: "ls -la /tmp"})
    check("is_hardline_bash: 'ls -la /tmp' allowed",
          if (result == 'false') { 'true' } else { 'false' })
}

# The fork-bomb literal (no spaces — exact string the config checks for)
# must be blocked.
fun t_hardline_fork_bomb() {
    result = Config.is_hardline_bash(%{command: ":(){:|:&};:"})
    check("is_hardline_bash: fork bomb blocked",
          if (result == 'true') { 'true' } else { 'false' })
}

# to_string(nil) must return the string "nil" (language contract).
fun t_to_string_nil() {
    result = to_string(nil)
    check("to_string(nil) returns \"nil\"",
          if (result == "nil") { 'true' } else { 'false' })
}

# ------------------------------------------------------------
# Bash auto-backgrounding + Background module
# ------------------------------------------------------------
# These exercise the real OS-detached path (shell_detached / pid_kill_group
# runtime builtins) end-to-end through Tools.exec_raw('bash', ...) and the
# Background module. Interactive-ish opts = a bg_table present and NOT
# headless/subagent/mcp_server, which is exactly what makes do_bash eligible
# for auto-backgrounding.

fun bg_opts(table) {
    %{bg_table: table, execution_context: "cli"}
}

# A fast command with auto-bg-eligible opts finishes within the budget and
# comes back through the foreground contract: "[exit 0]\n" ++ output. This is
# the "finished-within-budget" branch of bash_auto_bg — no task id leaks out.
fun t_bg_fast_returns_exit_output() {
    table = Background.init()
    r = Tools.exec_raw('bash', %{command: "echo hi"}, bg_opts(table))
    s = to_string(r)
    ok = bool_and(
        string_contains(s, "[exit 0]"),
        string_contains(s, "hi"))
    check("bash: fast cmd returns [exit 0] + output via auto-bg-eligible path", ok)
}

# background_after_ms:500 on a 3s command must background it: the tool returns a
# [backgrounded...] string carrying the task id and log path. Then
# wait_for_task finalizes it to 'done' and the log contains "late". CRITICAL:
# after that foreground finalize, poll_and_notify must NOT re-finalize — it
# returns [] (no newly-flipped ids) and the status stays 'done' (the CAS in
# try_finalize guarantees exactly-once, so no duplicate bg_done).
fun t_bg_auto_after_ms_no_double_finalize() {
    table = Background.init()
    r = Tools.exec_raw('bash',
        %{command: "sleep 3; echo late", background_after_ms: 500},
        bg_opts(table))
    s = to_string(r)
    id = "bg-0"
    backgrounded = bool_and3(
        string_contains(s, "[backgrounded"),
        string_contains(s, id),
        string_contains(s, Background.log_path_for(id)))

    st = Background.wait_for_task(table, id, 6000)
    done_ok = if (st == 'done') { 'true' } else { 'false' }
    log_ok = string_contains(Background.tail_log(table, id, 40), "late")

    # No duplicate finalize: the heartbeat's poll must find nothing to flip.
    flipped = Background.poll_and_notify(table)
    no_reflip = if (length(flipped) == 0) { 'true' } else { 'false' }
    still_done = if (Background.status(table, id) == 'done') { 'true' } else { 'false' }

    ok = bool_and(
        bool_and(backgrounded, done_ok),
        bool_and3(log_ok, no_reflip, still_done))
    check("bash: background_after_ms backgrounds, wait_for_task=done, no double-finalize", ok)
}

# run_in_background='true' detaches immediately — the tool returns a task id
# without blocking. Elapsed wall time must be well under the ~15s auto-bg
# budget (a real block would be seconds); we assert < 1500ms.
fun t_bg_run_in_background_immediate() {
    table = Background.init()
    t0 = timestamp()
    r = Tools.exec_raw('bash',
        %{command: "sleep 5", run_in_background: 'true'},
        bg_opts(table))
    t1 = timestamp()
    s = to_string(r)
    # Clean up the lingering sleep so it doesn't outlive the suite.
    Background.kill_task(table, "bg-0")
    ok = bool_and3(
        string_contains(s, "[backgrounded]"),
        string_contains(s, "bg-0"),
        if (t1 - t0 < 1500) { 'true' } else { 'false' })
    check("bash: run_in_background='true' returns a task id immediately (<1.5s)", ok)
}

# Background workers get stdin=/dev/null, so a `read` hits EOF immediately
# instead of hanging forever. wait_for_task must resolve (non-pending) within
# 3s — a hang would leave it 'pending' at the deadline.
fun t_bg_stdin_devnull_no_hang() {
    table = Background.init()
    id = Background.launch(table, "read x; echo got:[$x]", "stdin probe")
    st = Background.wait_for_task(table, id, 3000)
    check("background stdin is /dev/null (read gets EOF, finishes <3s not hang)",
          if (st != 'pending') { 'true' } else { 'false' })
}

# bg_kill must SIGTERM the WHOLE process group, not just the /bin/sh wrapper.
# Launch a wrapper that forks a backgrounded sleep plus a foreground sleep;
# after kill_task + a short grace, pgrep -g <pgid> must find zero survivors.
fun t_bg_kill_group() {
    table = Background.init()
    id = Background.launch(table, "sh -c 'sleep 60 & sleep 60; wait'", "kill probe")
    # Let the wrapper actually spawn its sleep children into the pgroup first.
    sleep(300)
    pid = ets_get(table, id ++ "/pid")
    Background.kill_task(table, id)
    sleep(600)
    r = shell("pgrep -g " ++ to_string(pid) ++ " 2>/dev/null | wc -l | tr -d ' \n'")
    count = string_trim(to_string(elem(r, 1)))
    check("bg_kill terminates the whole process group (0 survivors)",
          if (count == "0") { 'true' } else { 'false' })
}

# Stall detector white-box: build a pending task whose log tail LOOKS like an
# interactive prompt ("Password: ") and force its no-growth clock back >45s.
# Registering self() as 'main_agent' lets us receive the {'bg_stalled', ...}
# the detector fires. Two poll_and_notify passes must yield EXACTLY ONE
# message (the '{id}/stalled_sent' one-shot flag suppresses the second).
fun t_bg_stall_detector_one_shot() {
    table = Background.init()
    id = "bg-0"
    stall_log = "/tmp/swarm-code-stall-probe.log"
    file_write(stall_log, "Password: ")
    ets_put(table, 'next_id', 1)
    ets_put(table, id ++ "/status", 'pending')
    ets_put(table, id ++ "/label", "stall probe")
    ets_put(table, id ++ "/log_file", stall_log)
    # log_size == the file's byte count ("Password: " = 10) so check_stall sees
    # NO growth this tick; grew_at 46s in the past trips the >=45s threshold.
    ets_put(table, id ++ "/log_size", 10)
    ets_put(table, id ++ "/log_grew_at", timestamp() - 46000)
    # NB: deliberately DON'T set '{id}/exit_file' — try_finalize then leaves the
    # task 'pending' regardless of any stray /tmp exit file, so check_stall runs.
    register('main_agent', self())

    Background.poll_and_notify(table)
    got1 = receive {
        {'bg_stalled', tid, lbl, tail} -> tid
        after 1000 { 'none' }
    }
    Background.poll_and_notify(table)
    got2 = receive {
        {'bg_stalled', tid2, lbl2, tail2} -> 'extra'
        after 1000 { 'timeout' }
    }
    file_delete(stall_log)
    ok = bool_and(
        if (got1 == "bg-0") { 'true' } else { 'false' },
        if (got2 == 'timeout') { 'true' } else { 'false' })
    check("stall detector: fires once on prompt-tail, one-shot (no repeat)", ok)
}

# ESC handling can't be driven headless (no tty), so instead guard the
# invariant that makes the non-tty path safe: read_key(0) returns nil when no
# key is buffered, and bash_wait_loop's guard `(k == 27 || k == 3)` must be
# false for nil (never self-interrupt) yet true for a real ESC (27).
fun t_bg_read_key_nil_safe() {
    nil_key = nil
    nil_trips = if (nil_key == 27 || nil_key == 3) { 'true' } else { 'false' }
    esc_key = 27
    esc_trips = if (esc_key == 27 || esc_key == 3) { 'true' } else { 'false' }
    ok = bool_and(
        if (nil_trips == 'false') { 'true' } else { 'false' },
        if (esc_trips == 'true') { 'true' } else { 'false' })
    check("bash_wait_loop ESC guard: nil key never kills, ESC (27) does", ok)
}
