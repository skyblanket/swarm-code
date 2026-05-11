module LLM

import Log
import ToolSchemas

# ============================================================
# LLM — OpenAI-compatible chat completions client
# ============================================================
#
# Two tool-call wire formats are supported, selected per-call via
# opts.tool_format:
#
#   'inband' — the original Gemma 4 format. Model emits `call:NAME{JSON}`
#              text inline in its content. We stream the response and
#              parse it with parse_gemma_calls. Works with Gemma fine-
#              tunes on sushi.
#
#   'native' — OpenAI-native function calling. We send the tool schemas
#              in the `tools` request field; model emits structured
#              `tool_calls` in the response; we transcode those back
#              into in-band text so the agent's extract_tool_calls path
#              stays unchanged. Non-streaming for v1.
#
# Auto-detected in main.sw from endpoint (z.ai, openai.com, groq, etc →
# native; local/private → inband). Override with SWARM_CODE_TOOL_FORMAT.

export [chat, chat_silent, build_request_body, extract_content, extract_reasoning,
        extract_usage, last_prompt_tokens, record_usage, chat_completions_url,
        record_reasoning, last_reasoning]

# Build the final chat-completions URL from an endpoint base.
#
# Most OpenAI-compatible servers (vLLM, Ollama, Groq, Together, OpenRouter,
# DeepInfra, Fireworks, xAI, DeepSeek) expose the standard path
# `/v1/chat/completions`, so we append it by default.
#
# Some providers use a non-standard path — e.g. Zhipu / Z.AI's GLM series
# lives at `/api/paas/v4/chat/completions` (no `/v1/`). For those, set
# SWARM_CODE_ENDPOINT to the FULL URL ending in `/chat/completions` and we
# use it verbatim.
fun chat_completions_url(endpoint) {
    if (string_ends_with(endpoint, "/chat/completions") == 'true') {
        endpoint
    } else {
        endpoint ++ "/v1/chat/completions"
    }
}

# Build the JSON request body for a chat completions call.
#
# Dispatches on opts.tool_format:
#   'native' → adds `tools: [...]` + `tool_choice: "auto"` + stream:false,
#              and strips internal `call:NAME{JSON}` blocks from assistant
#              history (server sees clean prose only).
#   'inband' → original streaming shape, history passed as-is.
fun build_request_body(messages, opts) {
    model = map_get(opts, 'model')
    temp = map_get(opts, 'temperature')
    max_tokens = map_get(opts, 'max_tokens')
    tool_format = map_get(opts, 'tool_format')

    # In native mode the history must be reconstructed into proper
    # OpenAI shapes: assistant messages re-attach `tool_calls[]` parsed
    # from the inband markers we transcoded earlier, and the matching
    # `<tool_result>` user messages flip to `role: "tool"` with the
    # right `tool_call_id`. Without this, the server has no idea the
    # model has already acted — it sees orphan prose + an unparseable
    # tool_result wrapper and just re-runs the previous tool. See the
    # native-mode walker below for the full transformation.
    msg_maps = if (tool_format == 'native') {
        messages_to_maps_native(messages, 0, [], [])
    } else {
        messages_to_maps(messages, [])
    }

    base = %{
        model: model,
        temperature: temp,
        max_tokens: max_tokens,
        messages: msg_maps
    }

    final_req = if (tool_format == 'native') {
        native_req(base)
    } else {
        inband_req(base)
    }
    json_encode(final_req)
}

fun native_req(base) {
    a = map_put(base, 'tools', ToolSchemas.all_schemas())
    b = map_put(a, 'tool_choice', "auto")
    map_put(b, 'stream', 'false')
}

fun inband_req(base) {
    a = map_put(base, 'stream', 'true')
    map_put(a, 'stream_options', %{include_usage: 'true'})
}

# ============================================================
# Native-mode history walker — the heart of the fix
# ============================================================
#
# In inband mode, the assistant emits `prose\ncall:NAME{args}` and we
# keep that text verbatim in history. The model sees its own markers
# next turn and stays oriented.
#
# In native mode we transcoded the structured `tool_calls[]` into the
# same `\ncall:NAME{args}` text so agent.sw could keep one extraction
# path — but we still must REBUILD the structured shape every time we
# re-send history to the server, because OpenAI-compatible APIs do not
# understand the in-band marker.
#
# Transform per role:
#   {assistant, "prose\ncall:bash{...}\ncall:read{...}"}
#     →  %{role: "assistant", content: "prose",
#           tool_calls: [{id, type: "function", function:{name, arguments}}, ...]}
#
#   {user, "<tool_result>\nresult body\n</tool_result>"}
#     →  %{role: "tool", tool_call_id: <id from prior assistant>,
#           content: "result body"}
#
# Tool-call ids are deterministic (`swc_<msg_idx>_<call_idx>`) so the
# same history rebuilds to the same ids every turn.
fun messages_to_maps_native(messages, idx, pending_ids, acc) {
    if (length(messages) == 0) { acc }
    else {
        entry = hd(messages)
        role = elem(entry, 0)
        raw = elem(entry, 1)
        c_str = if (raw == nil) { "" } else { to_string(raw) }

        if (role == 'assistant') {
            rebuilt = build_assistant_native(c_str, idx)
            msg = elem(rebuilt, 0)
            new_ids = elem(rebuilt, 1)
            messages_to_maps_native(tl(messages), idx + 1, new_ids,
                list_append(acc, msg))
        }
        else { if (role == 'user' && string_starts_with(c_str, "<tool_result>") == 'true') {
            if (length(pending_ids) == 0) {
                # Orphan tool result (e.g. survived compaction). Send as
                # a regular user message so we never desync the protocol.
                messages_to_maps_native(tl(messages), idx + 1, [],
                    list_append(acc, %{role: "user", content: c_str}))
            } else {
                id = hd(pending_ids)
                stripped = strip_tool_result_wrapper(c_str)
                tool_msg = %{
                    role: "tool",
                    tool_call_id: id,
                    content: stripped
                }
                messages_to_maps_native(tl(messages), idx + 1, tl(pending_ids),
                    list_append(acc, tool_msg))
            }
        } else {
            messages_to_maps_native(tl(messages), idx + 1, pending_ids,
                list_append(acc, %{role: to_string(role), content: c_str}))
        }}
    }
}

# Build a native assistant message map from an in-band content string.
# Returns {msg_map, [tool_call_id, ...]} — the id list is what we expect
# matching tool_result messages to pop in order.
#
# Kimi K2 quirk: when `thinking` mode is enabled (the default), any
# assistant message that includes `tool_calls` MUST carry a
# `reasoning_content` field or the server 400s with
# "reasoning_content is missing in assistant tool call message". We
# don't yet round-trip the original reasoning_content across turns (it
# isn't stored in the history tuple), so we emit a short placeholder.
# Real reasoning preservation is a follow-up — see notes in
# record_reasoning / last_reasoning.
fun build_assistant_native(content, idx) {
    if (string_contains(content, "\ncall:") == 'false') {
        {%{role: "assistant", content: content}, []}
    } else {
        parts = string_split(content, "\ncall:")
        prose = hd(parts)
        rest = tl(parts)
        parsed = parse_call_segments(rest, idx, 0, [], [])
        calls = elem(parsed, 0)
        ids = elem(parsed, 1)
        # See the comment block above this function: Kimi K2 in
        # thinking mode requires `reasoning_content` to be present on
        # any assistant message that carries tool_calls, or the API
        # 400s. We don't roundtrip per-message reasoning across turns
        # yet (history is a flat {role, content} tuple), so we emit a
        # short placeholder. The 💭 emoji that used to render this in
        # the UI was removed — only the streaming response's real
        # reasoning gets displayed now, so this placeholder is API-only.
        msg = %{
            role: "assistant",
            content: string_trim(prose),
            reasoning_content: "Executing tool call.",
            tool_calls: calls
        }
        {msg, ids}
    }
}

# Parse each `NAME{json...}` segment into a native tool_call map.
# Skips malformed segments (no `{`, unbalanced braces) instead of
# crashing, so a stray "call:" in prose never breaks the request.
fun parse_call_segments(segs, msg_idx, call_idx, calls_acc, ids_acc) {
    if (length(segs) == 0) { {calls_acc, ids_acc} }
    else {
        seg = hd(segs)
        brace_idx = llm_find_substring(seg, "{")
        if (brace_idx < 0) {
            parse_call_segments(tl(segs), msg_idx, call_idx + 1, calls_acc, ids_acc)
        } else {
            name = string_trim(string_sub(seg, 0, brace_idx))
            end_idx = find_matching_brace(seg, brace_idx)
            if (end_idx < 0) {
                parse_call_segments(tl(segs), msg_idx, call_idx + 1, calls_acc, ids_acc)
            } else {
                args_len = end_idx - brace_idx + 1
                args_str = string_sub(seg, brace_idx, args_len)
                id = "swc_" ++ to_string(msg_idx) ++ "_" ++ to_string(call_idx)
                call_obj = %{
                    id: id,
                    type: "function",
                    function: %{
                        name: name,
                        arguments: args_str
                    }
                }
                parse_call_segments(tl(segs), msg_idx, call_idx + 1,
                    list_append(calls_acc, call_obj),
                    list_append(ids_acc, id))
            }
        }
    }
}

# Local substring scan (local copy so we don't reach across modules).
fun llm_find_substring(haystack, needle) {
    nl = string_length(needle)
    hl = string_length(haystack)
    if (nl == 0) { 0 }
    else { fsub_loop(haystack, needle, 0, hl, nl) }
}

fun fsub_loop(h, n, i, hl, nl) {
    if (i + nl > hl) { 0 - 1 }
    else {
        slice = string_sub(h, i, nl)
        if (slice == n) { i }
        else { fsub_loop(h, n, i + 1, hl, nl) }
    }
}

# Find the index of the closing `}` that matches the opening `{` at
# `open_idx`. Treats JSON string boundaries as opaque (so a `}` inside
# `"foo}bar"` does not close the object) and honours `\` escapes.
# Returns -1 if no match (malformed).
fun find_matching_brace(s, open_idx) {
    fmb_loop(s, open_idx, string_length(s), 0, 'false', 'false')
}

fun fmb_loop(s, i, sl, depth, in_str, escaped) {
    if (i >= sl) { 0 - 1 }
    else {
        ch = string_sub(s, i, 1)
        if (escaped == 'true') {
            fmb_loop(s, i + 1, sl, depth, in_str, 'false')
        }
        else { if (in_str == 'true' && ch == "\\") {
            fmb_loop(s, i + 1, sl, depth, in_str, 'true')
        }
        else { if (ch == "\"") {
            new_in_str = if (in_str == 'true') { 'false' } else { 'true' }
            fmb_loop(s, i + 1, sl, depth, new_in_str, 'false')
        }
        else { if (in_str == 'true') {
            fmb_loop(s, i + 1, sl, depth, in_str, 'false')
        }
        else { if (ch == "{") {
            fmb_loop(s, i + 1, sl, depth + 1, in_str, 'false')
        }
        else { if (ch == "}") {
            new_depth = depth - 1
            if (new_depth <= 0) { i }
            else { fmb_loop(s, i + 1, sl, new_depth, in_str, 'false') }
        }
        else {
            fmb_loop(s, i + 1, sl, depth, in_str, 'false')
        }}}}}}
    }
}

# Strip the `<tool_result>` wrapper that agent.sw adds around tool
# output before appending the message back to history. Accepts both
# the `\n`-padded form (the agent's actual output) and the unpadded
# form (defensive — older sessions, manual edits).
fun strip_tool_result_wrapper(s) {
    no_open = if (string_starts_with(s, "<tool_result>\n") == 'true') {
        string_sub(s, 14, string_length(s) - 14)
    } else { if (string_starts_with(s, "<tool_result>") == 'true') {
        string_sub(s, 13, string_length(s) - 13)
    } else { s }}
    if (string_ends_with(no_open, "\n</tool_result>") == 'true') {
        string_sub(no_open, 0, string_length(no_open) - 15)
    } else { if (string_ends_with(no_open, "</tool_result>") == 'true') {
        string_sub(no_open, 0, string_length(no_open) - 14)
    } else { no_open }}
}

# messages: [{role, content}, ...]  →  list of %{role: ..., content: ...} maps
fun messages_to_maps(messages, acc) {
    if (length(messages) == 0) {
        acc
    } else {
        entry = hd(messages)
        role = elem(entry, 0)
        content = elem(entry, 1)
        as_map = %{role: to_string(role), content: content}
        messages_to_maps(tl(messages), list_append(acc, as_map))
    }
}

# Public chat() — dispatches on tool_format.
#
# 'native' → chat_native (non-streaming, structured tool_calls parsing)
# 'inband' → chat_attempt (streaming with retry on transport failures)
fun chat(messages, opts) {
    tool_format = map_get(opts, 'tool_format')
    if (tool_format == 'native') {
        chat_native(messages, opts)
    } else {
        chat_attempt(messages, opts, 0)
    }
}

# ============================================================
# Native function-calling path
# ============================================================
#
# Sends a non-streaming request with `tools` + `tool_choice:"auto"`,
# parses `message.tool_calls[]` from the JSON response, and transcodes
# them back into swarm-code's internal `call:NAME{JSON}` string format
# so agent.sw's extract_tool_calls() works unchanged.
#
# UX cost: no typewriter streaming. User sees a dim "⋯ thinking" line
# until the full response arrives, then prose + reasoning render at
# once. Tradeoff accepted for v1 — streaming native requires patching
# SSE tool_calls accumulation in swarmrt's C stream builtin.
fun chat_native(messages, opts) {
    endpoint = map_get(opts, 'endpoint')
    api_key = map_get(opts, 'api_key')
    model = map_get(opts, 'model')
    url = chat_completions_url(endpoint)
    body = build_request_body(messages, opts)
    body_chars = string_length(body)

    file_write("/tmp/swarm-code-last-body.json", body)
    Log.llm_request(to_string(model), length(messages), body_chars)
    start_ms = timestamp()

    print("  \e[38;5;240m⋯ thinking (" ++ to_string(model) ++ ")...\e[0m")

    base_hdrs = [{"Content-Type", "application/json"}]
    hdrs = if (api_key == nil) { base_hdrs }
           else { list_append(base_hdrs, {"Authorization", "Bearer " ++ api_key}) }

    resp = http_post(url, hdrs, body)
    latency = timestamp() - start_ms

    # Erase the "thinking..." line so final output is clean.
    print("\e[1A\e[K")

    if (resp == nil) {
        Log.llm_error("http_post returned nil (native)", "")
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
                if (length(choices) == 0) {
                    Log.llm_error("no choices (native)", resp)
                    nil
                } else {
                    choice0 = hd(choices)
                    msg_obj = map_get(choice0, 'message')
                    raw_content = map_get(msg_obj, 'content')
                    tool_calls_list = map_get(msg_obj, 'tool_calls')

                    # Show reasoning (if any) then visible prose. Dim
                    # italic, no emoji prefix — keep the channel quiet.
                    if (reason_text != nil) {
                        print("  \e[38;5;240m\e[3m" ++ to_string(reason_text) ++ "\e[0m")
                        print("")
                    }
                    prose = if (raw_content == nil) { "" } else { to_string(raw_content) }
                    if (string_length(string_trim(prose)) > 0) {
                        print("  " ++ prose)
                        print("")
                    }

                    tc_count = if (tool_calls_list == nil) { 0 } else { length(tool_calls_list) }
                    had_tools = if (tc_count > 0) { 'true' } else { 'false' }
                    Log.llm_response(latency, string_length(prose), had_tools)

                    # Transcode → in-band string. Zero agent.sw changes.
                    transcode_native_calls(tool_calls_list, prose)
                }
            }
        }
    }
}

fun transcode_native_calls(tool_calls, prose) {
    if (tool_calls == nil) { prose }
    else { if (length(tool_calls) == 0) { prose }
    else { transcode_loop(tool_calls, prose) }}
}

fun transcode_loop(tool_calls, acc) {
    if (length(tool_calls) == 0) { acc }
    else {
        tc = hd(tool_calls)
        fn = map_get(tc, 'function')
        name = map_get(fn, 'name')
        # OpenAI returns `arguments` as an already-JSON-encoded STRING,
        # so `call:NAME` + args_str directly produces a valid in-band
        # `call:bash{"command":"ls"}` marker. No further escaping needed.
        args_str = map_get(fn, 'arguments')
        line = "\ncall:" ++ to_string(name) ++ to_string(args_str)
        transcode_loop(tl(tool_calls), acc ++ line)
    }
}

fun max_chat_retries() { 2 }

fun chat_attempt(messages, opts, attempt) {
    content = chat_once(messages, opts)
    needs_retry = if (content == nil) { 'true' }
                  else { is_transport_truncated(content) }
    if (needs_retry == 'true' && attempt < max_chat_retries()) {
        delay_s = if (attempt == 0) { 2 } else { 5 }
        print("")
        print("  \e[38;5;208m↻ transport failure — retrying in " ++
              to_string(delay_s) ++ "s (attempt " ++
              to_string(attempt + 2) ++ "/" ++
              to_string(max_chat_retries() + 1) ++ ")\e[0m")
        sleep(delay_s)
        chat_attempt(messages, opts, attempt + 1)
    } else {
        content
    }
}

# Detect the C streaming layer's mid-stream truncation marker.
# Only matches on curl 28 (transport timeout); doesn't match on
# user interrupt or model token-limit truncation.
fun is_transport_truncated(content) {
    if (string_contains(content, "[Response cut off by transport timeout") == 'true') { 'true' }
    else { 'false' }
}

# POST to {endpoint}/v1/chat/completions and return the raw assistant
# content string, or nil on error. Logs request/response/error to the
# telemetry layer for observability. Wrapped by chat() above for retry.
fun chat_once(messages, opts) {
    endpoint = map_get(opts, 'endpoint')
    api_key = map_get(opts, 'api_key')
    model = map_get(opts, 'model')
    url = chat_completions_url(endpoint)

    body = build_request_body(messages, opts)
    body_chars = string_length(body)

    # Debug: always dump the last request to /tmp so we can curl it
    # directly when chat() misbehaves. Cheap, always on — the file is
    # clobbered per call so it's just "the last thing we sent".
    file_write("/tmp/swarm-code-last-body.json", body)

    Log.llm_request(to_string(model), length(messages), body_chars)
    start_ms = timestamp()

    base_hdrs = [{"Content-Type", "application/json"}]
    hdrs = if (api_key == nil) {
        base_hdrs
    } else {
        list_append(base_hdrs, {"Authorization", "Bearer " ++ api_key})
    }

    # Use the streaming variant: tokens print to stdout as they arrive,
    # and the returned string is a minimal OpenAI response shape with the
    # accumulated content, so extract_content still works unchanged.
    resp = http_post_stream(url, hdrs, body)
    latency = timestamp() - start_ms

    if (resp == nil) {
        Log.llm_error("http_post returned nil", "")
        nil
    } else {
        content = extract_content(resp)
        if (content == nil) {
            Log.llm_error("extract_content returned nil", resp)
            nil
        } else {
            # Scrape real prompt_tokens from the server's usage field and
            # cache it in the stats table for compaction decisions + footer
            # display. This is the SAME number the server uses internally,
            # not a client-side char estimate.
            usage = extract_usage(resp)
            record_usage(opts, usage)
            # Cache reasoning_content (GLM-5.1 / DeepSeek-R1 / o1) in the
            # stats table so the agent loop can detect "model reasoned but
            # said nothing" and recover instead of giving up.
            reason_text = extract_reasoning(resp)
            record_reasoning(opts, reason_text)
            has_xml = string_contains(content, "<tool_call>") == 'true'
            has_native = string_contains(content, "call:") == 'true'
            had_tools = if (has_xml == 'true') { 'true' }
                        else { if (has_native == 'true') { 'true' } else { 'false' } }
            Log.llm_response(latency, string_length(content), had_tools)
            # Sick-server detection: empty response returned in under
            # 500ms with a small body is the fingerprint of a wedged or
            # OOM'd serving process — NOT context exhaustion and NOT a
            # bad prompt. Warn the user so they know where the problem
            # actually is instead of blaming themselves.
            empty = string_length(string_trim(content)) == 0
            if (empty == 'true' && latency < 500 && body_chars < 30000) {
                print("")
                print("  \e[38;5;208m⚠ server at " ++ to_string(endpoint) ++
                      " returned empty in " ++ to_string(latency) ++ "ms\e[0m")
                print("  \e[38;5;240m(fingerprint of a wedged / OOM'd serving process." ++
                      " Try restarting vllm on the host.)\e[0m")
                print("")
            }
            content
        }
    }
}

# ------------------------------------------------------------
# Silent chat — same as chat() but uses non-streaming http_post so
# nothing leaks onto the user's terminal. Used for internal ops
# like compaction, background summarization, buddy replies. Requests
# are sent with "stream": false so the server returns a single JSON
# blob instead of an SSE event stream.
# ------------------------------------------------------------
fun chat_silent(messages, opts) {
    endpoint = map_get(opts, 'endpoint')
    api_key = map_get(opts, 'api_key')
    url = chat_completions_url(endpoint)

    body = build_request_body_silent(messages, opts)

    base_hdrs = [{"Content-Type", "application/json"}]
    hdrs = if (api_key == nil) {
        base_hdrs
    } else {
        list_append(base_hdrs, {"Authorization", "Bearer " ++ api_key})
    }

    resp = http_post(url, hdrs, body)
    if (resp == nil) {
        nil
    } else {
        # Silent path — DO NOT print [llm error] to the terminal. The
        # caller (compaction, daemon pulse, buddy) handles failure by
        # returning nil and falling back. A printed error here would
        # leak debug noise on top of the user's view.
        usage = extract_usage(resp)
        record_usage(opts, usage)
        extract_content_quiet(resp)
    }
}

# Same shape as build_request_body but with stream:false — the
# non-streaming http_post builtin expects a plain JSON response.
fun build_request_body_silent(messages, opts) {
    model = map_get(opts, 'model')
    temp = map_get(opts, 'temperature')
    max_tokens = map_get(opts, 'max_tokens')
    msg_maps = messages_to_maps(messages, [])
    req = %{
        model: model,
        temperature: temp,
        max_tokens: max_tokens,
        stream: 'false',
        messages: msg_maps
    }
    json_encode(req)
}

# Pull choices[0].message.content out of an OpenAI-compat response.
# Prints `[llm error]` to the terminal if the server returned a
# structured error — the streaming chat path wants this visibility.
# Use `extract_content_quiet/1` for internal ops (compaction, pulse).
fun extract_content(resp_body) {
    extract_content_impl(resp_body, 'false')
}

# Quiet variant — same parsing, no terminal printing on errors.
fun extract_content_quiet(resp_body) {
    extract_content_impl(resp_body, 'true')
}

fun extract_content_impl(resp_body, silent) {
    decoded = json_decode(resp_body)
    if (decoded == nil) {
        nil
    } else {
        err = map_get(decoded, 'error')
        if (err != nil) {
            if (silent != 'true') {
                err_msg = map_get(err, 'message')
                print("[llm error] " ++ to_string(err_msg))
            }
            nil
        } else {
            choices = map_get(decoded, 'choices')
            if (length(choices) == 0) {
                nil
            } else {
                choice0 = hd(choices)
                msg_obj = map_get(choice0, 'message')
                map_get(msg_obj, 'content')
            }
        }
    }
}

# Pull choices[0].message.reasoning_content. Returns nil if the model
# isn't a reasoning model (Gemma, GPT-3.5-class) or the field is empty.
# Populated by swarmrt's http_post_stream when the server emits
# delta.reasoning_content (GLM-5.1, DeepSeek-R1, o1-style models).
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

# ------------------------------------------------------------
# Usage tracking — server-reported token counts
# ------------------------------------------------------------
# Extract the `usage` block from an OpenAI-compatible response and
# return it as a map {prompt_tokens, completion_tokens, total_tokens}.
# Returns nil if the server didn't include usage (e.g. non-streaming
# endpoints that don't populate it, or older SSE implementations).
fun extract_usage(resp_body) {
    decoded = json_decode(resp_body)
    if (decoded == nil) { nil }
    else {
        usage = map_get(decoded, 'usage')
        if (usage == nil) { nil } else { usage }
    }
}

# Cache the latest usage numbers in the stats ETS table passed via
# opts. The agent's budget check reads from here. When the server
# omits usage entirely we MUST clear the prior values — otherwise a
# stale prompt_tokens from many turns ago drives the budget check
# (either triggering premature compaction or skipping a needed one).
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
            # Always write — nil entries clear stale data.
            ets_put(table, 'prompt_tokens', pt)
            ets_put(table, 'completion_tokens', ct)
            ets_put(table, 'total_tokens', tt)
            'ok'
        }
    }
}

# Read the last server-reported prompt_tokens. Returns nil if we
# haven't made a successful call yet (first turn of the session).
fun last_prompt_tokens(opts) {
    table = map_get(opts, 'llm_stats_table')
    if (table == nil) { nil } else { ets_get(table, 'prompt_tokens') }
}

# Cache the last reasoning_content for empty-content recovery. Stored
# as a string; cleared (set to nil) on each successful call so stale
# reasoning from a prior turn isn't mistaken for current.
fun record_reasoning(opts, reason_text) {
    table = map_get(opts, 'llm_stats_table')
    if (table == nil) { 'ok' }
    else {
        if (reason_text == nil) { ets_put(table, 'last_reasoning', nil) }
        else { ets_put(table, 'last_reasoning', to_string(reason_text)) }
        'ok'
    }
}

# Read the last reasoning_content. Returns nil if no reasoning was
# emitted on the most recent call (non-reasoning model, or model spoke
# directly without thinking).
fun last_reasoning(opts) {
    table = map_get(opts, 'llm_stats_table')
    if (table == nil) { nil } else { ets_get(table, 'last_reasoning') }
}
