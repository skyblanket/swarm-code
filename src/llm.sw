module LLM

import Log
import ToolSchemas
import Markdown

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
    last_prompt_tokens, last_reasoning,
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
    collapse_consecutive_users(s2, [])
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
                    new_content = to_string(content) ++
                        "\n\n<context_status>" ++ status ++ "</context_status>"
                    new_msg = map_put(last_msg, 'content', new_content)
                    replace_at(messages, last_idx, new_msg, 0, [])
                }
            }
        }
    }
}

fun build_status_string(messages, opts) {
    msg_count = length(messages)
    msg_threshold = 120

    last_pt = last_prompt_tokens(opts)
    max_tok = parse_env_int_local("SWARM_CODE_MAX_TOKENS", 262144)
    out_res = parse_env_int_local("SWARM_CODE_OUTPUT_RESERVE", 16384)
    buf = parse_env_int_local("SWARM_CODE_COMPACT_BUFFER", 52000)
    tok_budget = max_tok - out_res - buf

    tok_used = if (last_pt != nil) { last_pt }
               else { rough_token_estimate(messages, 0) }

    # Room left until each trigger. Clamp at 0 so an over-budget
    # state shows "0% room" rather than a negative.
    msg_room_pct = ((msg_threshold - msg_count) * 100) / msg_threshold
    tok_room_pct = ((tok_budget - tok_used) * 100) / tok_budget

    msg_clamped = if (msg_room_pct < 0) { 0 } else { msg_room_pct }
    tok_clamped = if (tok_room_pct < 0) { 0 } else { tok_room_pct }

    # The tighter of the two is the one the agent should care about.
    pct = if (msg_clamped < tok_clamped) { msg_clamped } else { tok_clamped }

    to_string(pct) ++ "% room until compaction · " ++
    to_string(msg_count) ++ "/" ++ to_string(msg_threshold) ++ " msgs · " ++
    fmt_k(tok_used) ++ "/" ++ fmt_k(tok_budget) ++ " tokens"
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
# chat — public entry, dispatches on tool_format
# ============================================================
fun chat(messages, opts) {
    eff = apply_override(opts)
    tool_format = map_get(eff, 'tool_format')
    if (tool_format == 'native') {
        chat_native_retry(messages, eff, 0)
    } else {
        chat_inband_retry(messages, eff, 0)
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
    base = 1000
    cap = 30000
    # Pow-of-two with cap.
    raw = if (attempt == 0) { base }
          else { if (attempt == 1) { base * 2 }
          else { if (attempt == 2) { base * 4 }
          else { if (attempt == 3) { base * 8 }
          else { cap }}}}
    bounded = if (raw > cap) { cap } else { raw }
    # Jitter: multiplicative 1.0 .. 1.5 from the timestamp's low bits.
    # swarmrt has no rand builtin, but timestamp() is ms-granular and
    # call sites here are seconds apart, so its low 10 bits are
    # effectively uniform. Goal is to break up thundering-herd retries
    # when multiple agents restart simultaneously — not crypto-grade.
    ts = timestamp()
    low10 = ts - (ts / 1024) * 1024
    jitter_pct = low10 * 50 / 1024
    bounded + (bounded * jitter_pct / 100)
}

fun max_chat_retries() { 3 }

fun chat_native_retry(messages, opts, attempt) {
    result = chat_native(messages, opts)
    if (result != nil) { result }
    else {
        reason = last_fail(opts)
        if (reason == "interrupted") { nil }
        else { if (attempt >= max_chat_retries()) {
            print("  \e[38;5;208m✗ llm call failed after " ++
                  to_string(max_chat_retries() + 1) ++ " attempts\e[0m")
            nil
        } else {
            d = retry_delay_ms(attempt)
            print("  \e[38;5;208m↻ llm call failed — retrying in " ++
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
    needs_retry = if (result == nil) { 'true' }
                  else {
                      content = to_string(map_get(result, 'content'))
                      is_transport_truncated(content)
                  }
    if (needs_retry == 'true' && attempt < max_chat_retries()) {
        d = retry_delay_ms(attempt)
        print("")
        print("  \e[38;5;208m↻ transport failure — retrying in " ++
              to_string(d / 1000) ++ "s (attempt " ++
              to_string(attempt + 2) ++ "/" ++
              to_string(max_chat_retries() + 1) ++ ")\e[0m")
        sleep(d)
        chat_inband_retry(messages, opts, attempt + 1)
    } else { result }
}

fun is_transport_truncated(content) {
    if (string_contains(content, "[Response cut off by transport timeout") == 'true') { 'true' }
    else { 'false' }
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
    start_ms = timestamp()

    base_hdrs = [{"Content-Type", "application/json"}]
    hdrs = if (api_key == nil) { base_hdrs }
           else { list_append(base_hdrs, {"Authorization", "Bearer " ++ api_key}) }

    record_fail(opts, "fail")
    resp = http_post_stream(url, hdrs, body)
    latency = timestamp() - start_ms

    if (resp == nil) {
        Log.llm_error("http_post_stream returned nil (native)", "")
        nil
    } else {
        decoded = json_decode(resp)
        if (decoded == nil) {
            Log.llm_error("json_decode failed (native)", resp)
            nil
        } else {
            err = map_get(decoded, 'error')
            if (err != nil) {
                em = map_get(err, 'message')
                print("  \e[38;5;208m[llm error] " ++ to_string(em) ++ "\e[0m")
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
                    prose_raw = if (raw_content == nil) { "" } else { to_string(raw_content) }
                    # Length-truncation recovery: when the server stops on
                    # max_tokens with an empty content but populated
                    # reasoning_content (Kimi K2 thinking mid-stream), we'd
                    # otherwise hand the user a blank turn. Surface the
                    # reasoning with a clear marker so it's at least actionable.
                    finish_reason = map_get(choice0, 'finish_reason')
                    fr_str = if (finish_reason == nil) { "" } else { to_string(finish_reason) }
                    prose = if (string_length(string_trim(prose_raw)) == 0
                                && reason_text != nil
                                && fr_str == "length") {
                        "[truncated due to length — model's reasoning surfaced below]\n\n" ++ to_string(reason_text)
                    } else { prose_raw }
                    tool_calls = api_tool_calls_to_internal(raw_tool_calls, [])

                    had_tools = if (length(tool_calls) > 0) { 'true' } else { 'false' }
                    Log.llm_response(latency, string_length(prose), had_tools)

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
                        reasoning: reason_text
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
    start_ms = timestamp()

    base_hdrs = [{"Content-Type", "application/json"}]
    hdrs = if (api_key == nil) { base_hdrs }
           else { list_append(base_hdrs, {"Authorization", "Bearer " ++ api_key}) }

    resp = http_post_stream(url, hdrs, body)
    latency = timestamp() - start_ms

    if (resp == nil) {
        Log.llm_error("http_post returned nil (inband)", "")
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

            parsed = parse_inband_tool_calls(to_string(raw_content))
            prose_raw = map_get(parsed, 'content')
            tool_calls = map_get(parsed, 'tool_calls')

            # Length-truncation recovery: see chat_native for rationale.
            # Inband mode rarely reports finish_reason: "length" (Gemma
            # servers usually fold it into truncated prose) but we apply
            # the same rule for safety so users never stare at a blank turn.
            fr_str = extract_finish_reason(resp)
            prose = if (string_length(string_trim(to_string(prose_raw))) == 0
                        && reason_text != nil
                        && fr_str == "length") {
                "[truncated due to length — model's reasoning surfaced below]\n\n" ++ to_string(reason_text)
            } else { prose_raw }

            had_tools = if (length(tool_calls) > 0) { 'true' } else { 'false' }
            Log.llm_response(latency, string_length(to_string(prose)), had_tools)

            # Sick-server detection: empty response in <500ms with a
            # small body = fingerprint of a wedged / OOM'd serving
            # process. NOT context exhaustion, NOT a bad prompt.
            empty = string_length(string_trim(to_string(prose))) == 0
                    && length(tool_calls) == 0
            if (empty == 'true' && latency < 500 && body_chars < 30000) {
                print("")
                print("  \e[38;5;208m⚠ server at " ++ to_string(endpoint) ++
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

            %{
                content: prose,
                tool_calls: tool_calls,
                reasoning: reason_text
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
        prose = string_before_first(text, "\ncall:")
        tcs = inband_calls_to_internal(raw_calls, 0, [])
        %{content: prose, tool_calls: tcs}
    }
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

    resp = http_post_stream(url, hdrs, body, target_pid, name)
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
                prose_raw = if (raw_content == nil) { "" } else { to_string(raw_content) }
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
        usage = map_get(decoded, 'usage')
        if (usage == nil) { nil } else { usage }
    }
}

fun record_usage(opts, usage) {
    table = map_get(opts, 'llm_stats_table')
    if (table == nil) { 'ok' }
    else {
        if (usage == nil) {
            ets_put(table, 'prompt_tokens', nil)
            ets_put(table, 'completion_tokens', nil)
            ets_put(table, 'total_tokens', nil)
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
