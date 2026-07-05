module LLM

import Log
import ToolSchemas
import Markdown
import Hooks

# ============================================================
# LLM — OpenAI-compatible chat completions client
# ============================================================
#
# Returns structured %{content, tool_calls, reasoning} maps — never
# stringifies tool calls into the assistant prose. This is the rule
# Claude Code follows (see /Users/sky/claude-code/src/utils/messages.ts
# and /Users/sky/claude-code/src/services/api/claude.ts): a tool call
# is its own structured content block, peer to text, all the way
# through history and back to the API on subsequent turns. No parse
# → stringify → re-parse cycle, no collision risk if the model emits
# prose that happens to look like a tool-call marker.
#
# Two wire formats, selected per-call via opts.tool_format:
#
#   'native' — OpenAI-native function calling. We send the tool
#              schemas in the `tools` request field; the model emits
#              structured `tool_calls`; we keep them structured.
#
#   'inband' — Gemma-4-style protocol. Model emits `call:NAME{JSON}`
#              text inline in its content. We parse the markers ONCE
#              on receive into the same structured form used by
#              native mode. The agent never sees the text markers
#              again; they're rebuilt on demand when we POST history
#              back to an inband-mode server.
#
# Auto-detected in main.sw from endpoint (z.ai, openai.com, groq, …
# → native; local/private → inband). Override via
# SWARM_CODE_TOOL_FORMAT.

export [
    chat, chat_silent, chat_for_subagent,
    build_request_body, chat_completions_url,
    last_prompt_tokens, last_reasoning, last_fail,
    record_usage, record_reasoning, extract_usage, extract_reasoning,
    extract_content, extract_finish_reason,
    new_message_system, new_message_user,
    new_message_assistant, new_message_tool,
    parse_inband_tool_calls, inband_assistant_text,
    api_tool_calls_to_internal,
    repair_history, apply_override,
    inject_context_status, build_status_string
]

# ============================================================
# Internal message shape (lives in history + journal):
#
#   %{role: 'system',    content: "..."}
#   %{role: 'user',      content: "..."}
#   %{role: 'assistant', content: "...",
#                        tool_calls: [%{id, name, arguments}, ...] | nil,
#                        reasoning:  "..." | nil}
#   %{role: 'tool',      tool_call_id: "...", content: "..."}
#
# Internal tool_call shape:
#   %{id: "call_abc",  name: "bash",  arguments: "{\"command\":\"ls\"}"}
#
# `arguments` is a JSON-encoded string (OpenAI's wire format). The
# executor json_decodes it at dispatch time.
# ============================================================
fun new_message_system(content)    { %{role: 'system',    content: content} }
fun new_message_user(content)      { %{role: 'user',      content: content} }
fun new_message_assistant(content, tool_calls, reasoning) {
    %{role: 'assistant', content: content,
       tool_calls: tool_calls, reasoning: reasoning}
}
fun new_message_tool(tool_call_id, content) {
    %{role: 'tool', tool_call_id: tool_call_id, content: content}
}

# ------------------------------------------------------------
# Endpoint URL — most OpenAI-compat servers expose
# `/v1/chat/completions`. Some providers (Zhipu / Z.AI GLM) use a
# non-standard path; for those, set SWARM_CODE_ENDPOINT to the full
# URL ending in `/chat/completions` and we'll use it verbatim.
# ------------------------------------------------------------
# ------------------------------------------------------------
# In-session profile override. Slash command /profile NAME writes
# ~/.swarm-code/.profile_override with {endpoint, model, api_key,
# tool_format}; every LLM call consults this file and applies the
# overrides before serialising the request. File-based (rather than
# threading opts through main_loop) so it's a 5-line touch instead of
# a deep refactor — `rm ~/.swarm-code/.profile_override` reverts.
# ------------------------------------------------------------
fun apply_override(opts) {
    home = getenv("HOME")
    if (home == nil) { opts }
    else {
        path = home ++ "/.swarm-code/.profile_override"
        if (file_exists(path) == 'false') { opts }
        else {
            raw = file_read(path)
            if (raw == nil) { opts }
            else {
                ov = json_decode(raw)
                if (ov == nil) { opts }
                else {
                    a = override_field(opts, ov, 'endpoint')
                    b = override_field(a, ov, 'model')
                    c = override_field(b, ov, 'api_key')
                    d = override_field(c, ov, 'tool_format')
                    d = override_field(d, ov, 'vision')
                    # chat_template_kwargs is a map (not a string), so it
                    # bypasses override_field's to_string coercion. Always
                    # replace, even with nil, so switching to a profile that
                    # doesn't set thinking-off actually clears it.
                    ct_v = map_get(ov, 'chat_template_kwargs')
                    d = map_put(d, 'chat_template_kwargs', ct_v)
                    # Re-derive temperature when model changes — Kimi K2.x
                    # rejects any temperature other than 1.0.
                    if (map_get(ov, 'model') != nil) {
                        new_model = to_string(map_get(d, 'model'))
                        new_temp = if (string_starts_with(new_model, "kimi") == 'true') { 1.0 }
                                   else { 0.2 }
                        map_put(d, 'temperature', new_temp)
                    } else { d }
                }
            }
        }
    }
}

fun override_field(opts, ov, key) {
    v = map_get(ov, key)
    if (v == nil) { opts }
    else {
        val = if (key == 'tool_format') {
            s = to_string(v)
            if (s == "native") { 'native' } else { 'inband' }
        } else { to_string(v) }
        map_put(opts, key, val)
    }
}

fun chat_completions_url(endpoint) {
    # Strip any trailing slash so suffix checks are deterministic.
    base = if (string_ends_with(endpoint, "/") == 'true') {
        string_sub(endpoint, 0, string_length(endpoint) - 1)
    } else { endpoint }
    if (string_ends_with(base, "/chat/completions") == 'true') { base }
    else { if (string_ends_with(base, "/v1") == 'true') { base ++ "/chat/completions" }
    else { base ++ "/v1/chat/completions" }}
}

# ============================================================
# repair_history — pre-flight cleanup before every outbound request
# ============================================================
# Three repairs, in order:
#   1. Drop orphan role:'tool' messages whose tool_call_id has no
#      matching assistant.tool_calls entry currently "open". Open set
#      resets at every assistant message (the id space is per-turn).
#   2. Drop a trailing role:'assistant' with non-empty tool_calls that
#      has NO tool messages after it — that's a crashed-mid-turn
#      artifact and would 400 the API ("expected tool results").
#   3. Collapse adjacent role:'user' messages (newline-joined).
#      Only when BOTH contents are strings — multimodal lists are
#      preserved verbatim so image blocks don't get mangled.
# ============================================================
fun repair_history(messages) {
    s1 = drop_orphan_tools(messages, [], [])
    s2 = drop_trailing_unmatched_calls(s1)
    s3 = backfill_missing_tool_results(s2, [])
    collapse_consecutive_users(s3, [])
}

# Every assistant message that announced N tool_calls MUST be followed by one
# role:'tool' per call, or the API 400s. A crash mid-execute_all (results are
# journaled one at a time) leaves a PARTIAL set — assistant(tool_calls=[a,b])
# + tool(a) only. drop_trailing_unmatched_calls misses it (the last message is
# a 'tool', not the assistant), so on reload every request 400s until /reset.
# Here we synthesize a stub result for each unanswered id so the conversation
# stays valid while preserving the completed work + prose.
fun backfill_missing_tool_results(msgs, acc) {
    if (length(msgs) == 0) { acc }
    else {
        m = hd(msgs)
        role = map_get(m, 'role')
        tcs = if (role == 'assistant') { map_get(m, 'tool_calls') } else { nil }
        if (tcs == nil || length(tcs) == 0) {
            backfill_missing_tool_results(tl(msgs), list_append(acc, m))
        } else {
            split = split_following_tools(tl(msgs), [])
            following = elem(split, 0)
            remainder = elem(split, 1)
            answered = tool_msg_ids(following, [])
            announced = tc_ids(tcs, [])
            stubs = stub_tool_msgs(announced, answered, [])
            acc2 = (list_append(acc, m) ++ following) ++ stubs
            backfill_missing_tool_results(remainder, acc2)
        }
    }
}

# Split the leading run of role:'tool' messages off the front → {tools, rest}.
fun split_following_tools(msgs, tools_acc) {
    if (length(msgs) == 0) { {tools_acc, []} }
    else {
        m = hd(msgs)
        if (map_get(m, 'role') == 'tool') {
            split_following_tools(tl(msgs), list_append(tools_acc, m))
        } else { {tools_acc, msgs} }
    }
}

fun tool_msg_ids(tools, acc) {
    if (length(tools) == 0) { acc }
    else {
        t = hd(tools)
        tid = map_get(t, 'tool_call_id')
        tid_s = if (tid == nil) { "" } else { to_string(tid) }
        tool_msg_ids(tl(tools), list_append(acc, tid_s))
    }
}

fun stub_tool_msgs(announced, answered, acc) {
    if (length(announced) == 0) { acc }
    else {
        id = hd(announced)
        next = if (id_in(id, answered) == 'true') { acc }
               else { list_append(acc, new_message_tool(id,
                        "[interrupted before completion — no result captured]")) }
        stub_tool_msgs(tl(announced), answered, next)
    }
}

# Walk forward; `open` is the list of tool_call_ids the most recent
# assistant message announced. Tool messages with ids outside that set
# are dropped silently. Open set is replaced (not appended) on every
# assistant message because OpenAI's wire format scopes ids per turn.
fun drop_orphan_tools(msgs, open, acc) {
    if (length(msgs) == 0) { acc }
    else {
        m = hd(msgs)
        role = map_get(m, 'role')
        if (role == 'assistant') {
            tcs = map_get(m, 'tool_calls')
            new_open = if (tcs == nil) { [] }
                       else { tc_ids(tcs, []) }
            drop_orphan_tools(tl(msgs), new_open, list_append(acc, m))
        }
        else { if (role == 'tool') {
            tcid = map_get(m, 'tool_call_id')
            tcid_s = if (tcid == nil) { "" } else { to_string(tcid) }
            if (id_in(tcid_s, open) == 'true') {
                drop_orphan_tools(tl(msgs), open, list_append(acc, m))
            } else {
                # Skip orphan — don't put it in acc.
                drop_orphan_tools(tl(msgs), open, acc)
            }
        }
        else {
            # system / user / unknown — pass through, leave open set alone.
            drop_orphan_tools(tl(msgs), open, list_append(acc, m))
        }}
    }
}

fun tc_ids(tcs, acc) {
    if (length(tcs) == 0) { acc }
    else {
        tc = hd(tcs)
        id = map_get(tc, 'id')
        id_s = if (id == nil) { "" } else { to_string(id) }
        tc_ids(tl(tcs), list_append(acc, id_s))
    }
}

fun id_in(id, lst) {
    if (length(lst) == 0) { 'false' }
    else { if (hd(lst) == id) { 'true' } else { id_in(id, tl(lst)) }}
}

# If the LAST message is role:'assistant' with non-empty tool_calls,
# drop it — the agent crashed (or compaction landed) before any tool
# results came back. Sending it would 400 the API. The next user turn
# starts cleanly from the prior assistant prose.
fun drop_trailing_unmatched_calls(msgs) {
    n = length(msgs)
    if (n == 0) { msgs }
    else {
        last = nth_safe(msgs, n - 1)
        role = map_get(last, 'role')
        if (role == 'assistant') {
            tcs = map_get(last, 'tool_calls')
            has_tcs = if (tcs == nil) { 'false' }
                      else { if (length(tcs) == 0) { 'false' } else { 'true' }}
            if (has_tcs == 'true') {
                take_first(msgs, n - 1, 0, [])
            } else { msgs }
        } else { msgs }
    }
}

fun nth_safe(lst, i) {
    if (i == 0) { hd(lst) }
    else { nth_safe(tl(lst), i - 1) }
}

fun take_first(lst, k, i, acc) {
    if (i >= k) { acc }
    else { if (length(lst) == 0) { acc }
    else { take_first(tl(lst), k, i + 1, list_append(acc, hd(lst))) }}
}

# Collapse two-or-more consecutive user messages into one. Pairwise
# scan: when prev and cur are both string-content users, emit a merged
# message into acc and continue with cur consumed. Multimodal (list)
# content stays untouched.
fun collapse_consecutive_users(msgs, acc) {
    if (length(msgs) == 0) { acc }
    else {
        cur = hd(msgs)
        rest = tl(msgs)
        if (length(rest) == 0) {
            list_append(acc, cur)
        } else {
            nxt = hd(rest)
            if (map_get(cur, 'role') == 'user' && map_get(nxt, 'role') == 'user') {
                cc = map_get(cur, 'content')
                nc = map_get(nxt, 'content')
                cur_is_list = is_list(cc)
                nxt_is_list = is_list(nc)
                if (cur_is_list == 'true' || nxt_is_list == 'true') {
                    # Multimodal — leave both alone, never merge image blocks.
                    collapse_consecutive_users(rest, list_append(acc, cur))
                } else {
                    merged_content = to_string(cc) ++ "\n" ++ to_string(nc)
                    merged = %{role: 'user', content: merged_content}
                    # Recurse on (merged :: rest_of_rest) so a third
                    # consecutive user collapses into the same message.
                    collapse_consecutive_users(
                        cons(merged, tl(rest)), acc)
                }
            } else {
                collapse_consecutive_users(rest, list_append(acc, cur))
            }
        }
    }
}

fun cons(x, lst) {
    # Prepend a single element to a list — uses ++ for list
    # concatenation (verified working in native_req above).
    [x] ++ lst
}

# ============================================================
# build_request_body — serialize history to OpenAI wire shape
# ============================================================
fun build_request_body(messages, opts) {
    model = map_get(opts, 'model')
    temp = map_get(opts, 'temperature')
    max_tokens = map_get(opts, 'max_tokens')
    tool_format = map_get(opts, 'tool_format')

    # Repair history before serialising — drops orphan tool messages,
    # trailing unmatched tool_calls, and collapses consecutive user
    # messages. Keeps the API from rejecting requests after a crash
    # mid-turn or a journal load that landed mid-conversation.
    repaired = repair_history(messages)

    # Drain any pending image attachments (from read_image) and inject
    # them into the LAST user message as OpenAI multimodal content
    # blocks. Cleared from the queue so each image is sent exactly once.
    pending = Vision.get_pending(opts)
    messages_with_images = if (length(pending) == 0) { repaired }
                          else {
                              Vision.clear(opts)
                              inject_attachments(repaired, pending)
                          }

    # Passive context meter — appends "<context_status>X% room until
    # compaction · …</context_status>" to the LAST user message so the
    # agent always sees how close it is to the auto-compactor without
    # having to call a tool. Cache-safe: the user message wasn't being
    # cached anyway; the static system prompt above it stays cacheable.
    # Skipped when last message isn't role:user (mid-tool, etc) or when
    # the content is a multimodal list (would corrupt image blocks).
    messages_with_status = inject_context_status(messages_with_images, opts)

    msg_maps = if (tool_format == 'native') {
        messages_to_api_native(messages_with_status, [])
    } else {
        messages_to_api_inband(messages_with_status, [])
    }

    base = %{
        model: model,
        temperature: temp,
        max_tokens: max_tokens,
        messages: msg_maps
    }

    # Profile-supplied chat_template_kwargs (e.g. Qwen3.x's enable_thinking:
    # false). Merged in only when present — keeps the wire shape clean for
    # providers that don't recognise the field.
    ct = map_get(opts, 'chat_template_kwargs')
    base_with_ct = if (ct == nil) { base }
                   else { map_put(base, 'chat_template_kwargs', ct) }

    final_req = if (tool_format == 'native') {
        native_req(base_with_ct, opts)
    } else {
        inband_req(base_with_ct)
    }
    json_encode(final_req)
}

# ------------------------------------------------------------
# Attachment injection — turn the last user message in `messages`
# into a multimodal content list, with image_url blocks before the
# text block. Called once per outbound request when Vision.get_pending
# returns a non-empty queue.
# ------------------------------------------------------------
fun inject_attachments(messages, attachments) {
    idx = last_user_idx(messages, length(messages) - 1)
    if (idx < 0) { messages }
    else {
        target = nth(messages, idx)
        replaced = attach_blocks_to(target, attachments)
        replace_at(messages, idx, replaced, 0, [])
    }
}

fun last_user_idx(messages, i) {
    if (i < 0) { 0 - 1 }
    else {
        m = nth(messages, i)
        if (map_get(m, 'role') == 'user') { i }
        else { last_user_idx(messages, i - 1) }
    }
}

fun nth(lst, i) {
    if (i == 0) { hd(lst) }
    else { nth(tl(lst), i - 1) }
}

fun replace_at(lst, idx, new_item, i, acc) {
    if (length(lst) == 0) { acc }
    else {
        item = if (i == idx) { new_item } else { hd(lst) }
        replace_at(tl(lst), idx, new_item, i + 1, list_append(acc, item))
    }
}

fun attach_blocks_to(msg, attachments) {
    text = to_string(map_get(msg, 'content'))
    img_blocks = build_image_blocks(attachments, [])
    text_block = %{type: "text", text: text}
    full_content = list_append(img_blocks, text_block)
    map_put(msg, 'content', full_content)
}

fun build_image_blocks(attachments, acc) {
    if (length(attachments) == 0) { acc }
    else {
        a = hd(attachments)
        block = %{
            type: "image_url",
            image_url: %{url: to_string(map_get(a, 'data_url'))}
        }
        build_image_blocks(tl(attachments), list_append(acc, block))
    }
}

# ------------------------------------------------------------
# inject_context_status — passive token/message meter on every turn
# ------------------------------------------------------------
# Appends a small <context_status>…</context_status> block to the
# last user message so the model is ambient-aware of how close it
# is to the auto-compactor. Replaces the explicit context_meter
# tool — the agent shouldn't have to remember to check its own
# budget.
#
# Wording is "N% room until compaction" using the TIGHTER of the
# two compactor triggers: 120-message threshold (Agent.compact_threshold)
# OR token budget (max_tokens - output_reserve - compact_buffer).
# Whichever is closer to firing is the one shown.
fun inject_context_status(messages, opts) {
    n = length(messages)
    if (n == 0) { messages }
    else {
        last_idx = n - 1
        last_msg = nth(messages, last_idx)
        role = map_get(last_msg, 'role')
        if (role != 'user') { messages }
        else {
            content = map_get(last_msg, 'content')
            if (is_list(content) == 'true') { messages }
            else {
                status = build_status_string(messages, opts)
                if (string_length(status) == 0) { messages }
                else {
                    # Bracketed marker (not XML) — avoids any future
                    # JSON-escape weirdness on `<`/`>` and reads cleaner
                    # to humans glancing at /tmp/swarm-code-last-body.json.
                    new_content = to_string(content) ++ "\n\n[" ++ status ++ "]"
                    new_msg = map_put(last_msg, 'content', new_content)
                    replace_at(messages, last_idx, new_msg, 0, [])
                }
            }
        }
    }
}

fun build_status_string(messages, opts) {
    max_tok = parse_env_int_local("SWARM_CODE_MAX_TOKENS", 262144)
    out_res = parse_env_int_local("SWARM_CODE_OUTPUT_RESERVE", 16384)
    buf = parse_env_int_local("SWARM_CODE_COMPACT_BUFFER", 52000)
    # Clamp to a floor of 1 — a degenerate env (reserve + buffer >= max_tokens)
    # would otherwise make this 0 or negative and the division below PANICS
    # (swarmrt traps integer divide-by-zero) on the very first turn.
    raw_budget = max_tok - out_res - buf
    tok_budget = if (raw_budget < 1) { 1 } else { raw_budget }

    # Use the server's real prompt-token count once we have it; fall back to a
    # char/4 estimate before the first response.
    last_pt = last_prompt_tokens(opts)
    tok_used = if (last_pt != nil) { last_pt }
               else { rough_token_estimate(messages, 0) }

    # % used (0% empty, 100% full) — TOKEN-ONLY, matching claude-code. Context
    # fullness is about tokens, not message count, and we compact on this same
    # token budget (see Agent.context_budget_tokens), so the meter tracks the
    # actual compaction trigger. A long run of small messages no longer reads as
    # "100% full" when the real token usage is a fraction of the budget.
    tok_used_pct = (tok_used * 100) / tok_budget
    tok_pos = if (tok_used_pct < 0) { 0 } else { tok_used_pct }
    pct = if (tok_pos > 100) { 100 } else { tok_pos }

    "ctx " ++ to_string(pct) ++ "% used · " ++
    fmt_k(tok_used) ++ "/" ++ fmt_k(tok_budget) ++ " tok"
}

# Estimate token count from char count (≈4 chars/token) for use on
# the first turn before the server has reported usage. Multimodal
# content lists are skipped (images aren't text-counted).
fun rough_token_estimate(msgs, acc) {
    if (length(msgs) == 0) { acc / 4 }
    else {
        m = hd(msgs)
        c = map_get(m, 'content')
        n_chars = if (c == nil) { 0 }
                  else { if (is_list(c) == 'true') { 0 }
                  else { string_length(to_string(c)) }}
        rough_token_estimate(tl(msgs), acc + n_chars)
    }
}

fun fmt_k(n) {
    if (n < 1000) { to_string(n) }
    else { to_string(n / 1000) ++ "k" }
}

# Local env-int parser — duplicated from agent.sw to keep llm.sw
# free of agent.sw dependencies (agent imports llm, so the reverse
# would be a cycle).
fun parse_env_int_local(name, fallback) {
    env = getenv(name)
    if (env == nil) { fallback }
    else {
        parsed = parse_positive_int_local(env, 0, 0, 'false')
        if (parsed < 0) { fallback } else { parsed }
    }
}

fun parse_positive_int_local(s, i, acc, saw_digit) {
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
            parse_positive_int_local(s, i + 1, acc * 10 + d, 'true')
        }
    }
}

# inband mode fallback: pull the text block out of a multimodal
# content list. Images are dropped silently — inband protocol
# (Gemma 4 in-band tool calls) is text-only.
# Workaround for a swarmrt-side bug: http_post_stream's content
# accumulator doesn't decode \uXXXX JSON escapes for ASCII-range
# characters, so prose like `df -h / && free` comes through as
# `df -h / u0026u0026 free` (the backslash is gone, but the `uXXXX`
# stays). Until swarmrt's stream emitter is fixed, replace the most
# common offenders on the prose we extracted. Limited to chars that
# almost never appear as a literal `uXXXX` in real prose, so the
# false-positive risk is negligible.
fun fix_json_unicode_escapes(s) {
    s1 = string_replace(s,  "u0026", "&")
    s2 = string_replace(s1, "u003c", "<")
    s3 = string_replace(s2, "u003e", ">")
    s4 = string_replace(s3, "u0027", "'")
    s5 = string_replace(s4, "u0022", "\"")
    s6 = string_replace(s5, "u002f", "/")
    s7 = string_replace(s6, "u003d", "=")
    string_replace(s7,      "u005c", "\\")
}

# True when the only content the model produced is the C-side truncation
# marker — a reasoning-only turn that hit max_tokens. Lets the recovery
# surface the reasoning instead of showing a near-blank turn.
fun is_truncation_marker_only(prose) {
    t = string_trim(to_string(prose))
    marker = "[Response truncated at max_tokens"
    if (string_contains(t, marker) == 'false') { 'false' }
    else {
        before = string_before_first(t, marker)
        if (string_length(string_trim(before)) == 0) { 'true' } else { 'false' }
    }
}

fun extract_text_block(content_list) {
    if (length(content_list) == 0) { "" }
    else {
        b = hd(content_list)
        if (map_get(b, 'type') == "text") { to_string(map_get(b, 'text')) }
        else { extract_text_block(tl(content_list)) }
    }
}

fun native_req(base, opts) {
    mcp_schemas = map_get(opts, 'mcp_schemas')
    builtins = ToolSchemas.all_schemas()
    tools = if (mcp_schemas == nil) { builtins }
            else { if (length(mcp_schemas) == 0) { builtins }
            else { builtins ++ mcp_schemas }}
    a = map_put(base, 'tools', tools)
    b = map_put(a, 'tool_choice', "auto")
    c = map_put(b, 'stream', 'true')
    map_put(c, 'stream_options', %{include_usage: 'true'})
}

fun inband_req(base) {
    a = map_put(base, 'stream', 'true')
    map_put(a, 'stream_options', %{include_usage: 'true'})
}

# ------------------------------------------------------------
# History → OpenAI native wire shape. Assistant messages with
# tool_calls re-emit them as a structured `tool_calls` array; tool
# results become role:"tool" messages with their tool_call_id intact.
# This is the lossless roundtrip — what the server sent us, we send
# back, with no text parsing in between.
# ------------------------------------------------------------
fun messages_to_api_native(messages, acc) {
    if (length(messages) == 0) { acc }
    else {
        msg = hd(messages)
        api_msg = one_msg_native(msg)
        messages_to_api_native(tl(messages), list_append(acc, api_msg))
    }
}

fun one_msg_native(msg) {
    role = map_get(msg, 'role')
    if (role == 'system') {
        %{role: "system", content: to_string(map_get(msg, 'content'))}
    }
    else { if (role == 'user') {
        # User content may have been transformed by inject_attachments
        # into a list of multimodal content blocks. Pass it through so
        # the wire format is [{type:"image_url", …}, {type:"text", …}].
        # Plain string content stays a string.
        c = map_get(msg, 'content')
        if (is_list(c) == 'true') { %{role: "user", content: c} }
        else { %{role: "user", content: to_string(c)} }
    }
    else { if (role == 'assistant') {
        build_api_assistant_native(msg)
    }
    else { if (role == 'tool') {
        tcid = map_get(msg, 'tool_call_id')
        %{
            role: "tool",
            tool_call_id: if (tcid == nil) { "" } else { to_string(tcid) },
            content: to_string(map_get(msg, 'content'))
        }
    }
    else {
        %{role: to_string(role), content: to_string(map_get(msg, 'content'))}
    }}}}
}

fun build_api_assistant_native(msg) {
    content = map_get(msg, 'content')
    tool_calls = map_get(msg, 'tool_calls')
    content_str = if (content == nil) { "" } else { to_string(content) }
    has_tcs = if (tool_calls == nil) { 'false' }
              else { if (length(tool_calls) == 0) { 'false' } else { 'true' }}
    if (has_tcs == 'false') {
        %{role: "assistant", content: content_str}
    } else {
        api_tcs = tool_calls_to_api(tool_calls, [])
        # Kimi K2 thinking-mode requires reasoning_content on any
        # assistant message carrying tool_calls. Round-trip stored
        # reasoning when we have it; otherwise stamp a short placeholder.
        reasoning = map_get(msg, 'reasoning')
        rc = if (reasoning == nil) { "Executing tool call." }
             else {
                 rs = to_string(reasoning)
                 if (string_length(rs) == 0) { "Executing tool call." } else { rs }
             }
        %{
            role: "assistant",
            content: content_str,
            reasoning_content: rc,
            tool_calls: api_tcs
        }
    }
}

fun tool_calls_to_api(tcs, acc) {
    if (length(tcs) == 0) { acc }
    else {
        tc = hd(tcs)
        api_tc = %{
            id: to_string(map_get(tc, 'id')),
            type: "function",
            function: %{
                name: to_string(map_get(tc, 'name')),
                arguments: to_string(map_get(tc, 'arguments'))
            }
        }
        tool_calls_to_api(tl(tcs), list_append(acc, api_tc))
    }
}

# ------------------------------------------------------------
# History → inband wire shape. Inband servers don't understand
# OpenAI's structured tool_calls field, so assistant messages get
# re-flattened: prose followed by `\ncall:NAME{json}` markers
# reconstructed from the stored tool_calls. Tool results flatten
# back to user-role messages wrapped in <tool_result>…</tool_result>
# the way Gemma-style models expect.
# ------------------------------------------------------------
fun messages_to_api_inband(messages, acc) {
    if (length(messages) == 0) { acc }
    else {
        msg = hd(messages)
        api_msg = one_msg_inband(msg)
        messages_to_api_inband(tl(messages), list_append(acc, api_msg))
    }
}

fun one_msg_inband(msg) {
    role = map_get(msg, 'role')
    if (role == 'system') {
        %{role: "system", content: to_string(map_get(msg, 'content'))}
    }
    else { if (role == 'user') {
        # Inband mode is text-only (Gemma 4 in-band tool protocol can't
        # carry images). If content is a multimodal list, flatten to
        # just the text block — images are silently dropped. Use a
        # vision-capable profile (kimi) if you need image input.
        c = map_get(msg, 'content')
        text_only = if (is_list(c) == 'true') { extract_text_block(c) }
                    else { to_string(c) }
        %{role: "user", content: text_only}
    }
    else { if (role == 'assistant') {
        %{role: "assistant", content: inband_assistant_text(msg)}
    }
    else { if (role == 'tool') {
        %{
            role: "user",
            content: "<tool_result>\n" ++ to_string(map_get(msg, 'content')) ++ "\n</tool_result>"
        }
    }
    else {
        %{role: to_string(role), content: to_string(map_get(msg, 'content'))}
    }}}}
}

# Rebuild the inband assistant string from stored content + tool_calls.
# This is the canonical form an inband model would have emitted.
fun inband_assistant_text(msg) {
    content = map_get(msg, 'content')
    tool_calls = map_get(msg, 'tool_calls')
    base = if (content == nil) { "" } else { to_string(content) }
    if (tool_calls == nil) { base }
    else { if (length(tool_calls) == 0) { base }
    else {
        appended = inband_tc_loop(tool_calls, "")
        if (string_length(base) == 0) {
            # Trim the leading "\n" — no prose to separate from.
            if (string_length(appended) > 0 && string_sub(appended, 0, 1) == "\n") {
                string_sub(appended, 1, string_length(appended) - 1)
            } else { appended }
        } else { base ++ appended }
    }}
}

fun inband_tc_loop(tcs, acc) {
    if (length(tcs) == 0) { acc }
    else {
        tc = hd(tcs)
        line = "\ncall:" ++ to_string(map_get(tc, 'name')) ++
               to_string(map_get(tc, 'arguments'))
        inband_tc_loop(tl(tcs), acc ++ line)
    }
}

# ============================================================
# chat_with_providers — try each provider in order, falling back on nil
# ============================================================
# providers is a list of maps: [{endpoint, model, api_key, tool_format}, ...]
# idx is the current provider index (0-based).
# Builds per-provider opts by overlaying provider fields onto base opts,
# then calls chat_native_retry/chat_inband_retry. On nil, advances to idx+1.
fun chat_with_providers(messages, opts, providers, idx) {
    plen = length(providers)
    if (idx >= plen) {
        diag(opts, "  \e[38;5;208m✗ all " ++ to_string(plen) ++ " providers failed\e[0m")
        nil
    } else {
        p = nth_safe(providers, idx)
        p_ep  = map_get(p, 'endpoint')
        p_mod = map_get(p, 'model')
        p_key = map_get(p, 'api_key')
        p_tf  = map_get(p, 'tool_format')
        p_opts0 = if (p_ep  != nil) { map_put(opts,   'endpoint',    to_string(p_ep))  } else { opts   }
        p_opts1 = if (p_mod != nil) { map_put(p_opts0, 'model',       to_string(p_mod)) } else { p_opts0 }
        p_opts2 = if (p_key != nil) { map_put(p_opts1, 'api_key',     to_string(p_key)) } else { p_opts1 }
        p_opts3 = if (p_tf  != nil) {
                      tfs = to_string(p_tf)
                      tf_atom = if (tfs == "native") { 'native' } else { 'inband' }
                      map_put(p_opts2, 'tool_format', tf_atom)
                  } else { p_opts2 }
        # Show which provider we are trying (1-based display)
        ep_display = if (p_ep != nil) { to_string(p_ep) } else { to_string(map_get(opts, 'endpoint')) }
        if (idx > 0) {
            print("  \e[38;5;245m↳ provider " ++ to_string(idx + 1) ++ "/" ++ to_string(plen) ++ ": " ++ ep_display ++ "\e[0m")
        }
        eff = apply_override(p_opts3)
        tf = map_get(eff, 'tool_format')
        result = if (tf == 'native') { chat_native_retry(messages, eff, 0) }
                 else { chat_inband_retry(messages, eff, 0) }
        if (result == nil) {
            chat_with_providers(messages, opts, providers, idx + 1)
        } else {
            result
        }
    }
}

# ============================================================
# chat — public entry, dispatches on tool_format
# ============================================================
fun chat(messages, opts) {
    providers = map_get(opts, 'providers')
    if (providers != nil && length(providers) > 0) {
        chat_with_providers(messages, opts, providers, 0)
    } else {
        eff = apply_override(opts)
        model = map_get(eff, 'model')
        Hooks.run_pre_llm(model, length(messages), eff)
        start_ms = timestamp()
        tool_format = map_get(eff, 'tool_format')
        result = if (tool_format == 'native') {
            chat_native_retry(messages, eff, 0)
        } else {
            chat_inband_retry(messages, eff, 0)
        }
        latency = timestamp() - start_ms
        tokens = if (result == nil) { 0 }
                 else {
                     table = map_get(eff, 'llm_stats_table')
                     tt = if (table == nil) { nil } else { ets_get(table, 'total_tokens') }
                     if (tt == nil) { 0 } else { tt }
                 }
        Hooks.run_post_llm(model, tokens, latency, eff)
        result
    }
}

# ------------------------------------------------------------
# Retry on transient failures (5xx, dropped connection, half-decoded
# body). User-interrupted streams (ESC) are NOT retried — record_fail
# marks them and chat_*_retry honors that.
# ------------------------------------------------------------
fun record_fail(opts, reason) {
    table = map_get(opts, 'llm_stats_table')
    if (table == nil) { 'ok' }
    else { ets_put(table, 'fail_reason', reason) }
}

fun last_fail(opts) {
    table = map_get(opts, 'llm_stats_table')
    if (table == nil) { nil } else { ets_get(table, 'fail_reason') }
}

fun retry_delay_ms(attempt) {
    base = if (attempt == 0) { 1000 }
           else { if (attempt == 1) { 2000 }
           else { if (attempt == 2) { 4000 }
           else { 8000 }}}
    # Deterministic pseudo-jitter: 0..400ms range keyed on attempt number.
    # Provides reproducible spread without needing a PRNG — each attempt
    # gets a fixed offset so a fleet of agents retrying attempt 0 all at
    # the same ms won't collide on a single delay value.
    jitter = (attempt * 7919 + 3571) % 401
    base + jitter
}

fun max_chat_retries() { 3 }

fun chat_native_retry(messages, opts, attempt) {
    result = chat_native(messages, opts)
    if (result != nil) { result }
    else {
        # A user interrupt (ESC) is NOT retried: the C stream returns a
        # NON-nil partial response (carrying a "[Request interrupted by user]"
        # marker), so we never reach this nil branch on interrupt — only a
        # genuine failure (nil) does. (The old `last_fail == "interrupted"`
        # guard here was dead code: record_fail is never called with that value.)
        #
        # F1: a FATAL request error (4xx / parse-error body / structured error
        # object) must NOT be retried — re-sending the byte-identical poisoned
        # body just re-fails 4× then dies. chat_native already surfaced it; stop
        # here and let the agent layer recover (drop the failing turn). The
        # fallback endpoint is still worth one shot (different server may accept).
        if (last_fail(opts) == 'fatal') {
            fb = map_get(opts, 'fallback_endpoint')
            if (fb != nil) {
                print("  [llm] request rejected — trying fallback endpoint once...")
                fb_key   = map_get(opts, 'fallback_key')
                fb_model = map_get(opts, 'fallback_model')
                fb_tf    = map_get(opts, 'fallback_tool_format')
                fb_opts  = map_put(opts, 'endpoint', to_string(fb))
                fb_opts2 = if (fb_model != nil) { map_put(fb_opts,  'model',       to_string(fb_model)) } else { fb_opts  }
                fb_opts3 = if (fb_key   != nil) { map_put(fb_opts2, 'api_key',     to_string(fb_key))   } else { fb_opts2 }
                fb_opts4 = if (fb_tf    != nil) { map_put(fb_opts3, 'tool_format', fb_tf)               } else { fb_opts3 }
                fb_format = map_get(fb_opts4, 'tool_format')
                if (fb_format == 'inband') { chat_inband(messages, fb_opts4) }
                else { chat_native(messages, fb_opts4) }
            } else { nil }
        } else { if (attempt >= max_chat_retries()) {
            fb = map_get(opts, 'fallback_endpoint')
            if (fb != nil) {
                print("  [llm] retrying on fallback endpoint...")
                fb_key   = map_get(opts, 'fallback_key')
                fb_model = map_get(opts, 'fallback_model')
                fb_tf    = map_get(opts, 'fallback_tool_format')
                fb_opts  = map_put(opts, 'endpoint', to_string(fb))
                fb_opts2 = if (fb_model != nil) { map_put(fb_opts,  'model',       to_string(fb_model)) } else { fb_opts  }
                fb_opts3 = if (fb_key   != nil) { map_put(fb_opts2, 'api_key',     to_string(fb_key))   } else { fb_opts2 }
                fb_opts4 = if (fb_tf    != nil) { map_put(fb_opts3, 'tool_format', fb_tf)               } else { fb_opts3 }
                # Re-dispatch through chat_native/chat_inband based on the fallback's tool_format,
                # not the primary's — prevents sending a native request to an inband endpoint.
                fb_format = map_get(fb_opts4, 'tool_format')
                if (fb_format == 'inband') { chat_inband(messages, fb_opts4) }
                else { chat_native(messages, fb_opts4) }
            } else {
                diag(opts, "  \e[38;5;208m✗ llm call failed after " ++
                      to_string(max_chat_retries() + 1) ++ " attempts\e[0m")
                nil
            }
        } else {
            # Honor a server-supplied Retry-After (429/503) when it's longer
            # than our backoff; otherwise use the exponential schedule.
            ra = last_retry_after(opts)
            base_d = retry_delay_ms(attempt)
            d = if (ra > base_d) { ra } else { base_d }
            diag(opts, "  \e[38;5;208m↻ llm call failed (transient) — retrying in " ++
                  to_string(d / 1000) ++ "s (attempt " ++
                  to_string(attempt + 2) ++ "/" ++
                  to_string(max_chat_retries() + 1) ++ ")\e[0m")
            sleep(d)
            chat_native_retry(messages, opts, attempt + 1)
        }}
    }
}

fun chat_inband_retry(messages, opts, attempt) {
    result = chat_inband(messages, opts)
    # F1: a FATAL request error (4xx / parse-error body) must not be retried.
    # chat_inband already surfaced it; never re-send the identical poisoned body.
    fatal = if (result == nil && last_fail(opts) == 'fatal') { 'true' } else { 'false' }
    needs_retry = if (fatal == 'true') { 'false' }
                  else { if (result == nil) { 'true' }
                  else {
                      content = to_string(map_get(result, 'content'))
                      is_transport_truncated(content)
                  }}
    if (fatal == 'true') {
        # Fatal — try the fallback endpoint once (a different server may
        # accept), else surface nil to the agent layer for turn-drop recovery.
        fb = map_get(opts, 'fallback_endpoint')
        if (fb != nil) {
            print("  [llm] request rejected — trying fallback endpoint once...")
            fb_key   = map_get(opts, 'fallback_key')
            fb_model = map_get(opts, 'fallback_model')
            fb_tf    = map_get(opts, 'fallback_tool_format')
            fb_opts  = map_put(opts, 'endpoint', to_string(fb))
            fb_opts2 = if (fb_model != nil) { map_put(fb_opts,  'model',       to_string(fb_model)) } else { fb_opts  }
            fb_opts3 = if (fb_key   != nil) { map_put(fb_opts2, 'api_key',     to_string(fb_key))   } else { fb_opts2 }
            fb_opts4 = if (fb_tf    != nil) { map_put(fb_opts3, 'tool_format', fb_tf)               } else { fb_opts3 }
            fb_format = map_get(fb_opts4, 'tool_format')
            if (fb_format == 'native') { chat_native(messages, fb_opts4) }
            else { chat_inband(messages, fb_opts4) }
        } else { nil }
    } else { if (needs_retry == 'true' && attempt < max_chat_retries()) {
        ra = last_retry_after(opts)
        base_d = retry_delay_ms(attempt)
        d = if (ra > base_d) { ra } else { base_d }
        print("")
        diag(opts, "  \e[38;5;208m↻ transport failure — retrying in " ++
              to_string(d / 1000) ++ "s (attempt " ++
              to_string(attempt + 2) ++ "/" ++
              to_string(max_chat_retries() + 1) ++ ")\e[0m")
        sleep(d)
        chat_inband_retry(messages, opts, attempt + 1)
    } else {
        if (needs_retry == 'true') {
            fb = map_get(opts, 'fallback_endpoint')
            if (fb != nil) {
                print("  [llm] retrying on fallback endpoint...")
                fb_key   = map_get(opts, 'fallback_key')
                fb_model = map_get(opts, 'fallback_model')
                fb_tf    = map_get(opts, 'fallback_tool_format')
                fb_opts  = map_put(opts, 'endpoint', to_string(fb))
                fb_opts2 = if (fb_model != nil) { map_put(fb_opts,  'model',       to_string(fb_model)) } else { fb_opts  }
                fb_opts3 = if (fb_key   != nil) { map_put(fb_opts2, 'api_key',     to_string(fb_key))   } else { fb_opts2 }
                fb_opts4 = if (fb_tf    != nil) { map_put(fb_opts3, 'tool_format', fb_tf)               } else { fb_opts3 }
                fb_format = map_get(fb_opts4, 'tool_format')
                if (fb_format == 'native') { chat_native(messages, fb_opts4) }
                else { chat_inband(messages, fb_opts4) }
            } else { result }
        } else { result }
    }}
}

fun is_transport_truncated(content) {
    if (string_contains(content, "[Response cut off by transport timeout") == 'true') { 'true' }
    else { 'false' }
}

# unwrap_stream — http_post_stream returns {'ok', json_str} or {'error, reason}.
# Old swarmrt returned a bare string; new builds return a 2-tuple.
# This helper normalises both forms to a bare JSON string (or nil on error).
# Kept for chat_for_subagent (which doesn't classify); the main paths use
# classify_stream/3 below so they can distinguish fatal vs transient failures.
fun unwrap_stream(raw) {
    if (raw == nil) { nil }
    else {
        tag = elem(raw, 0)
        if (tag == 'ok') { elem(raw, 1) }
        else {
            # Error tuple. Current contract: {'error, status_int, body}. elem(raw,1)
            # is the STATUS code, elem(raw,2) the body — log the BODY (the useful
            # part), prefixed with the status, not the bare status int.
            status = elem(raw, 1)
            body = elem(raw, 2)
            if (status == nil) { raw }
            else {
                detail = if (body != nil) { "HTTP " ++ to_string(status) ++ ": " ++ to_string(body) }
                         else { "HTTP " ++ to_string(status) }
                Log.llm_error("stream error", detail)
                nil
            }
        }
    }
}

# ============================================================
# F1 — classify the HTTP stream result (CROSS-SLICE CONTRACT)
# ============================================================
# The streaming builtin (threaded through slice C) returns one of:
#   {'ok',    body_string}              — success
#   {'error, status_int, body_string}  — failure; status_int is the HTTP
#                                        code, or 0 for connection-refused /
#                                        timeout / no-response.
# classify_stream/1 normalises BOTH that shape AND the legacy shapes
# ({'ok,body} / {'error,reason} / bare-string / nil) into a 3-way tag:
#   {'ok',        body}        — proceed
#   {'fatal',     status, msg} — DO NOT retry (4xx, esp 400, or a body that
#                               is not parseable JSON). Re-sending the same
#                               body would just re-fail; surface it.
#   {'transient', status, msg} — backoff-retry (status 0 / 408 / 429 / 5xx,
#                               or an unclassifiable/legacy failure).
# A bare nil (oldest runtime, no tagged tuples) is treated as transient but
# bounded by max_chat_retries() — the safe fallback the contract requires.
fun classify_stream(raw) {
    if (raw == nil) { {'transient', 0, "no response"} }
    else {
        tag = elem(raw, 0)
        if (tag == 'ok') {
            body = elem(raw, 1)
            # A present-but-unparseable body is a FATAL request error (a 400
            # error page, an HTML 502 from a proxy mislabeled 'ok, …): retrying
            # the identical body can't fix it. Empty/nil body → transient.
            if (body == nil) { {'transient', 0, "empty ok body"} }
            else { if (json_decode(to_string(body)) == nil) {
                {'fatal', 200, "response body was not valid JSON"}
            } else { {'ok', to_string(body)} }}
        } else {
            # Error tuple. New shape: {'error, status, body}. Legacy: {'error, reason}.
            second = elem(raw, 1)
            third  = elem(raw, 2)
            if (second == nil) {
                # Not a tagged tuple at all — bare JSON string from an old
                # runtime. Re-classify it as if it had been {'ok', raw}.
                if (json_decode(to_string(raw)) == nil) {
                    {'fatal', 200, "response body was not valid JSON"}
                } else { {'ok', to_string(raw)} }
            } else { if (third == nil) {
                # Legacy {'error, reason} — no status available. Treat as
                # transient (bounded by the retry cap) per the safe fallback.
                {'transient', 0, to_string(second)}
            } else {
                status = to_int_safe(second)
                msg = to_string(third)
                if (is_transient_status(status) == 'true') {
                    {'transient', status, msg}
                } else {
                    {'fatal', status, msg}
                }
            }}
        }
    }
}

# Coerce a possibly-string/possibly-int status to an int. 0 on garbage.
fun to_int_safe(v) {
    if (v == nil) { 0 }
    else {
        s = to_string(v)
        n = parse_positive_int_local(s, 0, 0, 'false')
        if (n < 0) { 0 } else { n }
    }
}

# Transient = retry-worthy: connection-level (0), request-timeout (408),
# rate-limit (429), or any 5xx. Everything else (4xx, esp 400) is fatal.
fun is_transient_status(status) {
    if (status == 0) { 'true' }
    else { if (status == 408) { 'true' }
    else { if (status == 429) { 'true' }
    else { if (status >= 500 && status <= 599) { 'true' }
    else { 'false' }}}}
}

# Parse a Retry-After hint (seconds) embedded in the error body by the C
# stream as `retry-after: N` (case-insensitive-ish, we lower first). Returns
# milliseconds, or 0 when absent. Honored by chat_native_retry for 429/503.
fun parse_retry_after_ms(msg) {
    low = string_lower(to_string(msg))
    marker = "retry-after:"
    if (string_contains(low, marker) == 'false') { 0 }
    else {
        tail = string_after_first(low, marker)
        secs = parse_leading_int(string_trim(tail), 0, 0, 'false')
        if (secs <= 0) { 0 } else { secs * 1000 }
    }
}

# Prefix-aware leading-int parser: stops at the first non-digit. Used for
# Retry-After where the value may be followed by other text.
fun parse_leading_int(s, i, acc, saw) {
    if (i >= string_length(s)) { if (saw == 'true') { acc } else { 0 } }
    else {
        ch = string_sub(s, i, 1)
        d = if (ch == "0") { 0 } else { if (ch == "1") { 1 }
            else { if (ch == "2") { 2 } else { if (ch == "3") { 3 }
            else { if (ch == "4") { 4 } else { if (ch == "5") { 5 }
            else { if (ch == "6") { 6 } else { if (ch == "7") { 7 }
            else { if (ch == "8") { 8 } else { if (ch == "9") { 9 }
            else { 0 - 1 }}}}}}}}}}
        if (d < 0) { if (saw == 'true') { acc } else { 0 } }
        else { parse_leading_int(s, i + 1, acc * 10 + d, 'true') }
    }
}

# Substring after the first occurrence of marker ("" if not present).
fun string_after_first(s, marker) {
    if (string_contains(s, marker) == 'false') { "" }
    else {
        sentinel = "\x01\x02SWAFTER\x02\x01"
        replaced = string_replace(s, marker, sentinel)
        parts = string_split(replaced, sentinel)
        if (length(parts) < 2) { "" } else { hd(tl(parts)) }
    }
}

# Stash/read a pending Retry-After delay (ms) on the stats table so the
# retry loop can honor it without re-plumbing return shapes.
fun record_retry_after(opts, ms) {
    table = map_get(opts, 'llm_stats_table')
    if (table == nil) { 'ok' } else { ets_put(table, 'retry_after_ms', ms) }
}

fun last_retry_after(opts) {
    table = map_get(opts, 'llm_stats_table')
    if (table == nil) { 0 }
    else {
        v = ets_get(table, 'retry_after_ms')
        if (v == nil) { 0 } else { v }
    }
}

# ============================================================
# Live-wait feedback — turn the silent TTFT spinner into a real signal
# ============================================================
# The swarmrt C runtime owns the terminal line during http_post_stream
# (spinner + streamed tokens land there). The only window sw controls is
# BEFORE that call, so we print one dim-grey status line stating the
# request size and, when we have it, the speed learned from the PREVIOUS
# turn (latency + completion_tokens already live in llm_stats_table).
# No disk read, no C-runtime change. First turn degrades to a size-only
# line — still strictly more than a blank spinner.
fun wait_hint(opts, body_chars, model) {
    table = map_get(opts, 'llm_stats_table')
    kb = body_chars / 1024
    base = "  \e[38;5;240m↑ " ++ to_string(model) ++ " · " ++
           to_string(kb) ++ " KB request"
    line = if (table == nil) { base ++ " · waiting for first token…\e[0m" }
           else {
        last_ms = ets_get(table, 'last_latency_ms')
        last_ct = ets_get(table, 'last_completion_tokens')
        if (last_ms == nil || last_ct == nil || last_ms == 0 || last_ct == 0) {
            base ++ " · waiting for first token…\e[0m"
        } else {
            # tok/s from the prior turn (latency is ms).
            tps = (last_ct * 1000) / last_ms
            if (tps == 0) {
                # sub-1 tok/s turn — show the warning without a bogus "~0 tok/s".
                base ++ " · slow model, this can take a while\e[0m"
            } else {
                slow = if (tps < 40) { " · slow model, this can take a while" } else { "" }
                base ++ " · ~" ++ to_string(tps) ++ " tok/s last turn" ++ slow ++ "\e[0m"
            }
        }
    }
    line
}

# Persist this turn's observed speed so the NEXT wait_hint reflects real
# throughput. completion_tokens may be omitted by some servers on
# truncation — nil-guard skips the update and the prior value stands.
fun record_turn_speed(opts, latency, ct) {
    table = map_get(opts, 'llm_stats_table')
    if (table == nil) { 'ok' }
    else {
        if (latency != nil && latency > 0) { ets_put(table, 'last_latency_ms', latency) }
        if (ct != nil && ct > 0) { ets_put(table, 'last_completion_tokens', ct) }
        'ok'
    }
}

# Operator diagnostics (retries, provider/transport failures). swc has no
# stderr builtin, so these go through print — but stdout is the captured
# RESULT in headless `-p` and the JSON-RPC stream under --mcp-server, so
# suppress there (failure is signalled by exit 1 / the --json status).
# Interactive (TTY) keeps the colored diagnostics.
fun diag(opts, msg) {
    if (map_get(opts, 'headless') == 'true') { 'ok' }
    else { if (map_get(opts, 'execution_context') == "mcp_server") { 'ok' }
    else { print(msg) } }
}

# ============================================================
# Native streaming path — structured tool_calls preserved end-to-end
# ============================================================
fun chat_native(messages, opts) {
    endpoint = map_get(opts, 'endpoint')
    api_key = map_get(opts, 'api_key')
    model = map_get(opts, 'model')
    url = chat_completions_url(endpoint)
    body = build_request_body(messages, opts)
    body_chars = string_length(body)

    file_mkdir(getenv("HOME") ++ "/.swarm-code")
    file_write(getenv("HOME") ++ "/.swarm-code/last-body.json", body)
    Log.llm_request(to_string(model), length(messages), body_chars)
    # Substantive live-wait line shown for the whole TTFT window; the C
    # spinner renders beneath it and tokens stream in after.
    if (map_get(opts, 'headless') != 'true') { print(wait_hint(opts, body_chars, model)) }
    start_ms = timestamp()

    base_hdrs = [{"Content-Type", "application/json"}]
    hdrs = if (api_key == nil) { base_hdrs }
           else { list_append(base_hdrs, {"Authorization", "Bearer " ++ api_key}) }

    record_fail(opts, "fail")
    record_retry_after(opts, 0)
    cls = classify_stream(http_post_stream(url, hdrs, body))
    latency = timestamp() - start_ms

    cls_tag = elem(cls, 0)
    resp = if (cls_tag == 'ok') { elem(cls, 1) } else { nil }

    if (resp == nil) {
        # F1: classify the failure so chat_native_retry can decide whether to
        # re-send. 'fatal (4xx / parse-error body) → STOP (re-sending the same
        # body just re-fails). 'transient (0 / 408 / 429 / 5xx) → backoff-retry,
        # honoring any Retry-After the server sent.
        if (cls_tag == 'fatal') {
            f_status = elem(cls, 1)
            f_msg = elem(cls, 2)
            record_fail(opts, 'fatal')
            diag(opts, "  \e[38;5;208m✗ request rejected (HTTP " ++
                  to_string(f_status) ++ ") — not retrying: " ++ to_string(f_msg) ++ "\e[0m")
            Log.llm_error("fatal request error " ++ to_string(f_status), to_string(f_msg))
            nil
        } else {
            t_status = elem(cls, 1)
            t_msg = elem(cls, 2)
            record_fail(opts, 'transient')
            record_retry_after(opts, parse_retry_after_ms(t_msg))
            Log.llm_error("http_post_stream transient (native, HTTP " ++
                  to_string(t_status) ++ ")", to_string(t_msg))
            nil
        }
    } else {
        decoded = json_decode(resp)
        if (decoded == nil) {
            # classify_stream already guarantees resp parses, but keep the
            # belt-and-braces nil-guard; a parse failure here is fatal.
            record_fail(opts, 'fatal')
            Log.llm_error("json_decode failed (native)", resp)
            nil
        } else {
            err = map_get(decoded, 'error')
            if (err != nil) {
                em = map_get(err, 'message')
                # A structured error object is a request-level rejection
                # (bad params, context overflow, auth) — re-sending the
                # identical body just re-fails. Mark fatal so the retry
                # loop stops instead of hammering the same poisoned body.
                record_fail(opts, 'fatal')
                diag(opts, "  \e[38;5;208m[llm error] " ++ to_string(em) ++ "\e[0m")
                Log.llm_error("server error", to_string(em))
                nil
            } else {
                usage = extract_usage(resp)
                record_usage(opts, usage)
                reason_text = extract_reasoning(resp)
                record_reasoning(opts, reason_text)

                choices = map_get(decoded, 'choices')
                if (choices == nil || length(choices) == 0) {
                    Log.llm_error("no choices (native)", resp)
                    nil
                } else {
                    record_fail(opts, nil)
                    choice0 = hd(choices)
                    msg_obj = map_get(choice0, 'message')
                    raw_content = map_get(msg_obj, 'content')
                    raw_tool_calls = map_get(msg_obj, 'tool_calls')
                    prose_raw = if (raw_content == nil) { "" }
                                else { fix_json_unicode_escapes(to_string(raw_content)) }
                    # Length-truncation recovery: when the server stops on
                    # max_tokens with an empty content but populated
                    # reasoning_content (Kimi K2 thinking mid-stream), we'd
                    # otherwise hand the user a blank turn. Surface the
                    # reasoning with a clear marker so it's at least actionable.
                    # Length-truncation recovery. The C stream appends a
                    # "[Response truncated at max_tokens …]" marker to content
                    # but never emits a finish_reason field — so the old
                    # `finish_reason == "length"` test was unreachable, AND the
                    # appended marker meant prose_raw was never empty either.
                    # Detect the marker directly: if the model streamed ONLY
                    # that marker (reasoning-only turn), surface the reasoning
                    # so the user doesn't get a near-blank turn.
                    prose = if (reason_text != nil
                                && is_truncation_marker_only(prose_raw)) {
                        "[truncated due to length — model's reasoning surfaced below]\n\n" ++
                            to_string(reason_text) ++ "\n\n" ++ string_trim(to_string(prose_raw))
                    } else { prose_raw }
                    tool_calls = api_tool_calls_to_internal(raw_tool_calls, [])

                    # F4: signal length-truncation to the agent layer. With slice
                    # C threading the body out, finish_reason may now be present;
                    # also catch the C-appended marker. run_turn uses this to
                    # escalate max_tokens / inject a smaller-edits recovery nudge.
                    fin = extract_finish_reason(resp)
                    truncated = if (fin == "length") { 'true' }
                                else { if (string_contains(to_string(prose_raw),
                                          "[Response truncated at max_tokens") == 'true') { 'true' }
                                else { 'false' }}

                    had_tools = if (length(tool_calls) > 0) { 'true' } else { 'false' }
                    Log.llm_response(latency, string_length(prose), had_tools)
                    # Feed the learned-speed signal for the next wait_hint.
                    record_turn_speed(opts, latency,
                        if (usage == nil) { nil } else { map_get(usage, 'completion_tokens') })

                    # Post-stream re-render: wipe the C-streamed prose
                    # and reprint it formatted with the 2-col gutter.
                    # Only fires when (a) there's prose, (b) it contains
                    # markdown-y syntax, (c) SWARM_CODE_RAW_STREAM != 1.
                    # Skipped when tool_calls is non-empty because tool
                    # headers will render immediately after and a clean
                    # re-render mid-turn would clobber them.
                    if (had_tools == 'false') {
                        Markdown.repaint_streamed_prose(prose)
                    }

                    %{
                        content: prose,
                        tool_calls: tool_calls,
                        reasoning: reason_text,
                        truncated: truncated
                    }
                }
            }
        }
    }
}

# Convert OpenAI tool_calls → internal flat shape.
# Wire shape:    [%{id, type:"function", function:%{name, arguments: <json_string>}}, ...]
# Internal flat: [%{id, name, arguments: <json_string>}, ...]
fun api_tool_calls_to_internal(raw, acc) {
    if (raw == nil) { acc }
    else { if (length(raw) == 0) { acc }
    else {
        tc = hd(raw)
        fn = map_get(tc, 'function')
        name_v = if (fn == nil) { map_get(tc, 'name') } else { map_get(fn, 'name') }
        args_v = if (fn == nil) { map_get(tc, 'arguments') } else { map_get(fn, 'arguments') }
        id_v = map_get(tc, 'id')
        # Synthesize an id when the server omits one — tool_call_id is the
        # pairing key between assistant.tool_calls[N] and the role:tool
        # response. Without a stable id the next-turn API request can't
        # match results to calls.
        id_str = if (id_v == nil) {
            "swc_synth_" ++ to_string(timestamp()) ++ "_" ++ to_string(length(acc))
        } else { to_string(id_v) }
        internal = %{
            id: id_str,
            name: if (name_v == nil) { "" } else { to_string(name_v) },
            arguments: if (args_v == nil) { "{}" } else { to_string(args_v) }
        }
        api_tool_calls_to_internal(tl(raw), list_append(acc, internal))
    }}
}

# ============================================================
# Inband streaming path — parse markers ONCE into structured form
# ============================================================
fun chat_inband(messages, opts) {
    endpoint = map_get(opts, 'endpoint')
    api_key = map_get(opts, 'api_key')
    model = map_get(opts, 'model')
    url = chat_completions_url(endpoint)
    body = build_request_body(messages, opts)
    body_chars = string_length(body)

    file_write("/tmp/swarm-code-last-body.json", body)
    Log.llm_request(to_string(model), length(messages), body_chars)
    # Same live-wait line for the inband (Gemma-style) path.
    if (map_get(opts, 'headless') != 'true') { print(wait_hint(opts, body_chars, model)) }
    start_ms = timestamp()

    base_hdrs = [{"Content-Type", "application/json"}]
    hdrs = if (api_key == nil) { base_hdrs }
           else { list_append(base_hdrs, {"Authorization", "Bearer " ++ api_key}) }

    record_fail(opts, "fail")
    record_retry_after(opts, 0)
    cls = classify_stream(http_post_stream(url, hdrs, body))
    latency = timestamp() - start_ms

    cls_tag = elem(cls, 0)
    resp = if (cls_tag == 'ok') { elem(cls, 1) } else { nil }

    if (resp == nil) {
        # F1: same classification as chat_native — fatal request errors stop the
        # retry loop (chat_inband_retry checks last_fail), transient ones retry.
        if (cls_tag == 'fatal') {
            record_fail(opts, 'fatal')
            diag(opts, "  \e[38;5;208m✗ request rejected (HTTP " ++
                  to_string(elem(cls, 1)) ++ ") — not retrying: " ++ to_string(elem(cls, 2)) ++ "\e[0m")
            Log.llm_error("fatal request error (inband, HTTP " ++ to_string(elem(cls, 1)) ++ ")", to_string(elem(cls, 2)))
        } else {
            record_fail(opts, 'transient')
            record_retry_after(opts, parse_retry_after_ms(elem(cls, 2)))
            Log.llm_error("http_post transient (inband, HTTP " ++ to_string(elem(cls, 1)) ++ ")", to_string(elem(cls, 2)))
        }
        nil
    } else {
        raw_content = extract_content(resp)
        if (raw_content == nil) {
            Log.llm_error("extract_content returned nil (inband)", resp)
            nil
        } else {
            usage = extract_usage(resp)
            record_usage(opts, usage)
            reason_text = extract_reasoning(resp)
            record_reasoning(opts, reason_text)

            parsed = parse_inband_tool_calls(fix_json_unicode_escapes(to_string(raw_content)))
            prose_raw = map_get(parsed, 'content')
            tool_calls = map_get(parsed, 'tool_calls')

            # Length-truncation recovery: see chat_native for rationale.
            # Inband mode rarely reports finish_reason: "length" (Gemma
            # servers usually fold it into truncated prose) but we apply
            # the same rule for safety so users never stare at a blank turn.
            # Same length-truncation recovery as chat_native: detect the
            # appended truncation marker rather than a (never-emitted)
            # finish_reason field, and surface reasoning on a marker-only turn.
            prose = if (reason_text != nil
                        && is_truncation_marker_only(to_string(prose_raw))) {
                "[truncated due to length — model's reasoning surfaced below]\n\n" ++
                    to_string(reason_text) ++ "\n\n" ++ string_trim(to_string(prose_raw))
            } else { prose_raw }

            had_tools = if (length(tool_calls) > 0) { 'true' } else { 'false' }
            Log.llm_response(latency, string_length(to_string(prose)), had_tools)
            # Feed the learned-speed signal for the next wait_hint.
            record_turn_speed(opts, latency,
                if (usage == nil) { nil } else { map_get(usage, 'completion_tokens') })

            # Sick-server detection: empty response in <500ms with a
            # small body = fingerprint of a wedged / OOM'd serving
            # process. NOT context exhaustion, NOT a bad prompt.
            empty = string_length(string_trim(to_string(prose))) == 0
                    && length(tool_calls) == 0
            if (empty == 'true' && latency < 500 && body_chars < 30000) {
                print("")
                diag(opts, "  \e[38;5;208m⚠ server at " ++ to_string(endpoint) ++
                      " returned empty in " ++ to_string(latency) ++ "ms\e[0m")
                print("  \e[38;5;240m(fingerprint of a wedged / OOM'd serving process. " ++
                      "Try restarting vllm on the host.)\e[0m")
                print("")
            }

            # Post-stream re-render (same rationale as chat_native):
            # wipe the raw streamed prose and reprint via Markdown so
            # bold/headers/lists/code render properly with a 2-col
            # gutter. Skipped when tool_calls present so tool headers
            # render cleanly right after.
            if (had_tools == 'false') {
                Markdown.repaint_streamed_prose(to_string(prose))
            }

            # F4: same length-truncation signal as chat_native.
            fin = extract_finish_reason(resp)
            truncated = if (fin == "length") { 'true' }
                        else { if (string_contains(to_string(prose_raw),
                                  "[Response truncated at max_tokens") == 'true') { 'true' }
                        else { 'false' }}

            %{
                content: prose,
                tool_calls: tool_calls,
                reasoning: reason_text,
                truncated: truncated
            }
        }
    }
}

# Parse inband `\ncall:NAME{json}` markers out of content. Returns
# %{content: prose_only_no_markers, tool_calls: [%{id, name, arguments}, ...]}.
# Synthesizes ids since the inband protocol carries none.
fun parse_inband_tool_calls(text) {
    raw_calls = parse_gemma_calls(text)
    if (raw_calls == nil || length(raw_calls) == 0) {
        %{content: text, tool_calls: []}
    } else {
        prose = strip_before_call_marker(text)
        tcs = inband_calls_to_internal(raw_calls, 0, [])
        %{content: prose, tool_calls: tcs}
    }
}

# Strip prose at the first inband tool-call marker. parse_gemma_calls accepts
# `call:` preceded by ANY non-word char (".call:" / " call:" / "\ncall:", the
# GLM-5.1 cases), but the old split on the literal "\ncall:" missed the
# punctuation/space-prefixed forms — leaking the raw marker into stored content
# and DUPLICATING it on the next request. Match the same boundary here.
fun strip_before_call_marker(text) {
    idx = find_call_marker(text, 0)
    if (idx < 0) { text }
    else { string_sub(text, 0, idx) }
}

fun find_call_marker(s, i) {
    slen = string_length(s)
    if (i + 5 > slen) { 0 - 1 }
    else {
        if (string_sub(s, i, 5) == "call:") {
            prev = if (i == 0) { "\n" } else { string_sub(s, i - 1, 1) }
            if (is_word_char(prev) == 'false') {
                # Also require a '{' somewhere after the name — this gates out
                # prose phrases like "call: read the file" which parse_gemma_calls
                # also rejects (a 'call:' with no following '{' is not a tool call).
                if (has_brace_after(s, i + 5, slen) == 'true') { i }
                else { find_call_marker(s, i + 1) }
            } else { find_call_marker(s, i + 1) }
        } else { find_call_marker(s, i + 1) }
    }
}

fun has_brace_after(s, from, slen) {
    if (from >= slen) { 'false' }
    else {
        ch = string_sub(s, from, 1)
        if (ch == "{") { 'true' }
        else { if (ch == "\n") { 'false' }
        else { has_brace_after(s, from + 1, slen) }}
    }
}

fun is_word_char(ch) {
    if ((ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")
        || (ch >= "0" && ch <= "9") || ch == "_") { 'true' }
    else { 'false' }
}

fun inband_calls_to_internal(raw, idx, acc) {
    if (length(raw) == 0) { acc }
    else {
        tc = hd(raw)
        name = elem(tc, 0)
        args = elem(tc, 1)
        args_str = json_encode(args)
        id = "swc_inband_" ++ to_string(timestamp()) ++ "_" ++ to_string(idx)
        internal = %{
            id: id,
            name: to_string(name),
            arguments: args_str
        }
        inband_calls_to_internal(tl(raw), idx + 1, list_append(acc, internal))
    }
}

# Prefix of s up to (not including) the first occurrence of marker.
# If marker isn't found, returns s unchanged. Used to strip inband
# tool-call markers from prose so they don't sit in stored content.
fun string_before_first(s, marker) {
    if (string_contains(s, marker) == 'false') { s }
    else {
        sentinel = "\x01\x02SWPROSE\x02\x01"
        replaced = string_replace(s, marker, sentinel)
        parts = string_split(replaced, sentinel)
        hd(parts)
    }
}

# ============================================================
# chat_silent — non-streaming, used by compaction + daemon pulse.
# Returns just the content string. Tool calls would not be useful
# for compaction (it's a summarisation prompt) and the pulse path
# does its own inband-only parse via parse_inband_tool_calls.
# ============================================================
fun chat_silent(messages, opts) {
    opts = apply_override(opts)
    endpoint = map_get(opts, 'endpoint')
    api_key = map_get(opts, 'api_key')
    url = chat_completions_url(endpoint)
    body = build_request_body_silent(messages, opts)

    base_hdrs = [{"Content-Type", "application/json"}]
    hdrs = if (api_key == nil) { base_hdrs }
           else { list_append(base_hdrs, {"Authorization", "Bearer " ++ api_key}) }

    resp = http_post(url, hdrs, body)
    if (resp == nil) { nil }
    else {
        usage = extract_usage(resp)
        record_usage(opts, usage)
        extract_content_quiet(resp)
    }
}

# Silent path: stream:false + no tools array. We send via the inband
# walker (`messages_to_api_inband`) which flattens both formats to
# straight prose — the silent call never benefits from server-side
# tool_choice anyway.
fun build_request_body_silent(messages, opts) {
    model = map_get(opts, 'model')
    temp = map_get(opts, 'temperature')
    max_tokens = map_get(opts, 'max_tokens')
    msg_maps = messages_to_api_inband(messages, [])
    req = %{
        model: model,
        temperature: temp,
        max_tokens: max_tokens,
        stream: 'false',
        messages: msg_maps
    }
    json_encode(req)
}

# ============================================================
# chat_for_subagent — streaming with per-chunk routing to a parent.
# Same structured return shape as chat() so a subagent's run-loop is
# uniform with main's.
# ============================================================
fun chat_for_subagent(messages, opts, target_pid, name) {
    opts = apply_override(opts)
    endpoint = map_get(opts, 'endpoint')
    api_key = map_get(opts, 'api_key')
    model = map_get(opts, 'model')
    url = chat_completions_url(endpoint)
    body = build_request_body(messages, opts)
    body_chars = string_length(body)

    Log.llm_request(to_string(model), length(messages), body_chars)
    start_ms = timestamp()

    base_hdrs = [{"Content-Type", "application/json"}]
    hdrs = if (api_key == nil) { base_hdrs }
           else { list_append(base_hdrs, {"Authorization", "Bearer " ++ api_key}) }

    resp = unwrap_stream(http_post_stream(url, hdrs, body, target_pid, name))
    latency = timestamp() - start_ms

    if (resp == nil) {
        Log.llm_error("http_post returned nil (subagent " ++ name ++ ")", "")
        nil
    } else {
        decoded = json_decode(resp)
        if (decoded == nil) {
            Log.llm_error("subagent json_decode failed", resp)
            nil
        } else {
            usage = extract_usage(resp)
            record_usage(opts, usage)
            reason_text = extract_reasoning(resp)
            record_reasoning(opts, reason_text)

            choices = map_get(decoded, 'choices')
            if (choices == nil || length(choices) == 0) { nil }
            else {
                choice0 = hd(choices)
                msg_obj = map_get(choice0, 'message')
                raw_content = map_get(msg_obj, 'content')
                prose_raw = if (raw_content == nil) { "" }
                            else { fix_json_unicode_escapes(to_string(raw_content)) }
                tool_format = map_get(opts, 'tool_format')
                result_map = if (tool_format == 'native') {
                    %{
                        content: prose_raw,
                        tool_calls: api_tool_calls_to_internal(
                            map_get(msg_obj, 'tool_calls'), [])
                    }
                } else {
                    parse_inband_tool_calls(prose_raw)
                }
                tcs_len = length(map_get(result_map, 'tool_calls'))
                had_tools = if (tcs_len > 0) { 'true' } else { 'false' }
                Log.llm_response(latency, string_length(prose_raw), had_tools)
                map_put(result_map, 'reasoning', reason_text)
            }
        }
    }
}

# ============================================================
# Response extraction helpers
# ============================================================
fun extract_content(resp_body) {
    extract_content_impl(resp_body, 'false')
}

fun extract_content_quiet(resp_body) {
    extract_content_impl(resp_body, 'true')
}

fun extract_content_impl(resp_body, silent) {
    decoded = json_decode(resp_body)
    if (decoded == nil) { nil }
    else {
        err = map_get(decoded, 'error')
        if (err != nil) {
            if (silent != 'true') {
                err_msg = map_get(err, 'message')
                print("[llm error] " ++ to_string(err_msg))
            }
            nil
        } else {
            choices = map_get(decoded, 'choices')
            if (choices == nil) { nil }
            else { if (length(choices) == 0) { nil }
            else {
                choice0 = hd(choices)
                msg_obj = map_get(choice0, 'message')
                if (msg_obj == nil) { nil }
                else { map_get(msg_obj, 'content') }
            }}
        }
    }
}

fun extract_reasoning(resp_body) {
    decoded = json_decode(resp_body)
    if (decoded == nil) { nil }
    else {
        choices = map_get(decoded, 'choices')
        if (choices == nil) { nil }
        else { if (length(choices) == 0) { nil }
        else {
            choice0 = hd(choices)
            msg_obj = map_get(choice0, 'message')
            if (msg_obj == nil) { nil }
            else {
                rc = map_get(msg_obj, 'reasoning_content')
                if (rc == nil) { nil }
                else { if (string_length(to_string(rc)) == 0) { nil } else { rc } }
            }
        }}
    }
}

fun extract_finish_reason(resp_body) {
    decoded = json_decode(resp_body)
    if (decoded == nil) { "" }
    else {
        choices = map_get(decoded, 'choices')
        if (choices == nil) { "" }
        else { if (length(choices) == 0) { "" }
        else {
            choice0 = hd(choices)
            fr = map_get(choice0, 'finish_reason')
            if (fr == nil) { "" } else { to_string(fr) }
        }}
    }
}

fun extract_usage(resp_body) {
    decoded = json_decode(resp_body)
    if (decoded == nil) { nil }
    else {
        map_get(decoded, 'usage', nil)
    }
}

fun record_usage(opts, usage) {
    table = map_get(opts, 'llm_stats_table')
    if (table == nil) { 'ok' }
    else {
        if (usage == nil) {
            # Stream omitted usage (some OpenAI-compat servers drop it on
            # truncation). RETAIN the last-known counts instead of wiping
            # them — a recent real server count is a far better budget/
            # compaction proxy than falling back to the 4-chars/token guess.
            'ok'
        } else {
            pt = map_get(usage, 'prompt_tokens')
            ct = map_get(usage, 'completion_tokens')
            tt = map_get(usage, 'total_tokens')
            ets_put(table, 'prompt_tokens', pt)
            ets_put(table, 'completion_tokens', ct)
            ets_put(table, 'total_tokens', tt)
            'ok'
        }
    }
}

fun last_prompt_tokens(opts) {
    table = map_get(opts, 'llm_stats_table')
    if (table == nil) { nil } else { ets_get(table, 'prompt_tokens') }
}

fun record_reasoning(opts, reason_text) {
    table = map_get(opts, 'llm_stats_table')
    if (table == nil) { 'ok' }
    else {
        if (reason_text == nil) { ets_put(table, 'last_reasoning', nil) }
        else { ets_put(table, 'last_reasoning', to_string(reason_text)) }
        'ok'
    }
}

fun last_reasoning(opts) {
    table = map_get(opts, 'llm_stats_table')
    if (table == nil) { nil } else { ets_get(table, 'last_reasoning') }
}
