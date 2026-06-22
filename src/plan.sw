module Plan

# ============================================================
# Plan — plan-before-execute mode for swarm-code
# ============================================================
#
# Intercepts complex user requests, generates a numbered plan via a
# no-tools LLM call, presents it for confirmation, then injects the
# confirmed plan into history so the model follows it.
#
# Three modes (opts['plan_mode']):
#   "auto" — trigger on complex requests (default)
#   "on"   — always trigger
#   "off"  — never trigger
#
# Env override: SWARM_CODE_PLAN=on|off|auto
# main.sw resolves this at startup into opts['plan_mode'].
#
# Slash commands are handled in agent.sw:
#   /plan           show current mode
#   /plan on        always show plan before executing
#   /plan off       never show plan
#   /plan auto      show plan only for complex requests (default)
#
# Integration point in agent.sw route_input (line ~428):
#   After Vision.auto_attach and before list_append(history, user_msg),
#   call Plan.is_active(line, opts). If 'true':
#     1. Generate plan: plan_text = Plan.generate(line, history, opts)
#     2. Display it:    Plan.display(plan_text)
#     3. Confirm:       answer = Plan.confirm()
#        - 'yes'          → inject + continue normally
#        - 'no'           → return history unchanged (abort)
#        - {'edit', text} → use text as new plan, show again, re-confirm once
#     4. On confirm:    history = Plan.inject_into_history(history, plan_text, line)
#        then continue to list_append + run_turn as normal.

import UI

export [
    init, generate, display, confirm,
    auto_trigger, inject_into_history,
    is_active, get_mode, set_mode_from_opts,
    show_mode, plan_mode_override_path
]

# ============================================================
# init — no-op. Mode is resolved in main.sw from env.
# Returns opts unchanged.
# ============================================================
fun init(opts) { opts }

# Path to the file that stores a /plan override for the session.
# Mirrors the model override approach.
fun plan_mode_override_path() {
    home = getenv("HOME")
    if (home == nil) { nil }
    else { home ++ "/.swarm-code/.plan_mode" }
}

# ============================================================
# get_mode — returns "on" | "off" | "auto"
# Priority: opts key > override file > env var > "auto" default
# ============================================================
fun get_mode(opts) {
    # 1. opts key (set at startup from env, or by tests)
    from_opts = map_get(opts, 'plan_mode')
    if (from_opts != nil) {
        s = to_string(from_opts)
        if (s == "on") { "on" }
        else { if (s == "off") { "off" }
        else { "auto" }}
    } else {
        # 2. Override file written by /plan command
        p = plan_mode_override_path()
        from_file = if (p == nil) { nil }
                    else { if (file_exists(p) == 'true') {
                        raw = file_read(p)
                        if (raw == nil) { nil } else { string_trim(raw) }
                    } else { nil }}
        if (from_file != nil) {
            s2 = from_file
            if (s2 == "on") { "on" }
            else { if (s2 == "off") { "off" }
            else { "auto" }}
        } else {
            # 3. Env var
            from_env = getenv("SWARM_CODE_PLAN")
            if (from_env != nil) {
                s3 = from_env
                if (s3 == "on") { "on" }
                else { if (s3 == "off") { "off" }
                else { "auto" }}
            } else { "auto" }
        }
    }
}

# ============================================================
# set_mode_from_opts — returns opts unchanged.
# Callers that toggle mode mid-session update opts directly:
#   new_opts = map_put(opts, 'plan_mode', "on")
# This function exists as a stable API surface.
# ============================================================
fun set_mode_from_opts(opts) { opts }

# ============================================================
# auto_trigger — heuristics for 'auto' mode
# Returns 'true' | 'false'
#
# TRIGGER if message:
#   - contains action keywords: implement / build / create / add /
#     refactor / migrate / rewrite
#   - contains sequence connectors: "and then" / "after that" / "also" /
#     "finally" / "first," / "second,"
#   - is more than 2 sentences (rough count of ". " breaks)
#   - mentions 2+ file paths or known extensions
#
# DO NOT trigger for:
#   - slash commands (starts with "/")
#   - very short messages (< 5 words)
#   - questions (starts with what/why/how/show/explain, or contains "?")
#   - messages starting with "just"/"only"/"quick"/"quickly"
# ---- helpers for auto_trigger — defined first to avoid forward references ----

fun word_count(s) { word_count_loop(s, 0, 0, 'false') }

fun word_count_loop(s, i, n, in_word) {
    len = string_length(s)
    if (i >= len) {
        if (in_word == 'true') { n + 1 } else { n }
    } else {
        ch = string_sub(s, i, 1)
        is_ws = if (ch == " " || ch == "\t" || ch == "\n") { 'true' } else { 'false' }
        if (is_ws == 'true') {
            new_n = if (in_word == 'true') { n + 1 } else { n }
            word_count_loop(s, i + 1, new_n, 'false')
        } else {
            word_count_loop(s, i + 1, n, 'true')
        }
    }
}

fun is_question_word(t) {
    if (string_starts_with(t, "what ") == 'true') { 'true' }
    else { if (string_starts_with(t, "what's ") == 'true') { 'true' }
    else { if (string_starts_with(t, "whats ") == 'true') { 'true' }
    else { if (string_starts_with(t, "why ") == 'true') { 'true' }
    else { if (string_starts_with(t, "how ") == 'true') { 'true' }
    else { if (string_starts_with(t, "how's ") == 'true') { 'true' }
    else { if (string_starts_with(t, "show ") == 'true') { 'true' }
    else { if (string_starts_with(t, "explain ") == 'true') { 'true' }
    else { 'false' }}}}}}}}
}

fun is_question_verb(t) {
    if (string_starts_with(t, "can you ") == 'true') { 'true' }
    else { if (string_starts_with(t, "could you ") == 'true') { 'true' }
    else { if (string_starts_with(t, "do you ") == 'true') { 'true' }
    else { if (string_starts_with(t, "is ") == 'true') { 'true' }
    else { if (string_starts_with(t, "are ") == 'true') { 'true' }
    else { if (string_starts_with(t, "does ") == 'true') { 'true' }
    else { 'false' }}}}}}
}

fun is_question(t) {
    if (is_question_word(t) == 'true') { 'true' }
    else { if (is_question_verb(t) == 'true') { 'true' }
    else { if (string_contains(t, "?") == 'true') { 'true' }
    else { 'false' }}}
}

fun has_action_kw_a(t) {
    if (string_contains(t, "implement") == 'true') { 'true' }
    else { if (string_contains(t, "build") == 'true') { 'true' }
    else { if (string_contains(t, "create") == 'true') { 'true' }
    else { 'false' }}}
}

fun has_action_kw_b(t) {
    if (string_contains(t, "refactor") == 'true') { 'true' }
    else { if (string_contains(t, "migrate") == 'true') { 'true' }
    else { if (string_contains(t, "rewrite") == 'true') { 'true' }
    else { 'false' }}}
}

fun has_action_kw_c(t) {
    if (string_contains(t, " add ") == 'true') { 'true' }
    else { if (string_starts_with(t, "add ") == 'true') { 'true' }
    else { 'false' }}
}

fun has_action_keyword(t) {
    if (has_action_kw_a(t) == 'true') { 'true' }
    else { if (has_action_kw_b(t) == 'true') { 'true' }
    else { has_action_kw_c(t) }}
}

# Strong multi-step intent only. We deliberately do NOT match bare " also " or
# "finally" — those are everyday conversational filler ("qwen 3.5 also there",
# "finally working") and spuriously triggered plan generation on casual chat.
# "and then" genuinely signals a sequenced request.
fun has_sequence_connector(t) {
    string_contains(t, "and then")
}

# Rough sentence count — each ". " or ".\n" is a sentence break
fun sentence_count_loop(s, i, n) {
    len = string_length(s)
    if (i + 1 >= len) { n }
    else {
        ch = string_sub(s, i, 1)
        if (ch == ".") {
            nxt = string_sub(s, i + 1, 1)
            if (nxt == " " || nxt == "\n") {
                sentence_count_loop(s, i + 2, n + 1)
            } else {
                sentence_count_loop(s, i + 1, n)
            }
        } else {
            sentence_count_loop(s, i + 1, n)
        }
    }
}

fun sentence_count(s) { sentence_count_loop(s, 0, 1) }

fun is_file_ext_a(tok) {
    if (string_ends_with(tok, ".sw") == 'true') { 'true' }
    else { if (string_ends_with(tok, ".ex") == 'true') { 'true' }
    else { if (string_ends_with(tok, ".exs") == 'true') { 'true' }
    else { if (string_ends_with(tok, ".py") == 'true') { 'true' }
    else { if (string_ends_with(tok, ".ts") == 'true') { 'true' }
    else { if (string_ends_with(tok, ".tsx") == 'true') { 'true' }
    else { if (string_ends_with(tok, ".js") == 'true') { 'true' }
    else { if (string_ends_with(tok, ".rs") == 'true') { 'true' }
    else { 'false' }}}}}}}}
}

fun is_file_ext_b(tok) {
    if (string_ends_with(tok, ".go") == 'true') { 'true' }
    else { if (string_ends_with(tok, ".c") == 'true') { 'true' }
    else { if (string_ends_with(tok, ".h") == 'true') { 'true' }
    else { if (string_ends_with(tok, ".json") == 'true') { 'true' }
    else { if (string_ends_with(tok, ".md") == 'true') { 'true' }
    else { if (string_ends_with(tok, ".yaml") == 'true') { 'true' }
    else { if (string_ends_with(tok, ".yml") == 'true') { 'true' }
    else { if (string_ends_with(tok, ".toml") == 'true') { 'true' }
    else { 'false' }}}}}}}}
}

fun is_file_token(tok) {
    if (string_length(tok) < 2) { 'false' }
    else { if (string_contains(tok, "/") == 'true') { 'true' }
    else { if (is_file_ext_a(tok) == 'true') { 'true' }
    else { is_file_ext_b(tok) }}}
}

fun count_file_tokens(msg, i, token_start, count) {
    len = string_length(msg)
    if (i >= len) {
        tok = string_sub(msg, token_start, len - token_start)
        if (is_file_token(tok) == 'true') { count + 1 } else { count }
    } else {
        ch = string_sub(msg, i, 1)
        is_sep = if (ch == " " || ch == "\t" || ch == "\n" ||
                     ch == "," || ch == ";" || ch == "\"" || ch == "'") {
            'true'
        } else { 'false' }
        if (is_sep == 'true') {
            tok = string_sub(msg, token_start, i - token_start)
            new_count = if (is_file_token(tok) == 'true') { count + 1 }
                        else { count }
            count_file_tokens(msg, i + 1, i + 1, new_count)
        } else {
            count_file_tokens(msg, i + 1, token_start, count)
        }
    }
}

# Count tokens that look like file paths/names (contain "/" or known extension).
# Returns 'true' when 2 or more such tokens are found.
fun has_multiple_file_refs(msg) {
    n = count_file_tokens(msg, 0, 0, 0)
    if (n >= 2) { 'true' } else { 'false' }
}

# ============================================================
fun auto_trigger(user_msg) {
    if (user_msg == nil) { 'false' }
    else {
        t = string_trim(string_lower(to_string(user_msg)))
        if (string_length(t) == 0) { 'false' }
        # Never plan slash commands
        else { if (string_starts_with(t, "/") == 'true') { 'false' }
        # Never plan very short messages (fewer than 5 words)
        else { if (word_count(t) < 5) { 'false' }
        # Never plan pure questions
        else { if (is_question(t) == 'true') { 'false' }
        # Never plan "just/only/quick" qualifiers
        else { if (string_starts_with(t, "just ") == 'true') { 'false' }
        else { if (string_starts_with(t, "only ") == 'true') { 'false' }
        else { if (string_starts_with(t, "quick ") == 'true') { 'false' }
        else { if (string_starts_with(t, "quickly ") == 'true') { 'false' }
        # --- Positive triggers ---
        # Action keywords
        else { if (has_action_keyword(t) == 'true') { 'true' }
        # Sequence connectors (multi-step signal)
        else { if (has_sequence_connector(t) == 'true') { 'true' }
        # Multi-sentence
        else { if (sentence_count(t) > 2) { 'true' }
        # Multiple file references (uses original casing)
        else { if (has_multiple_file_refs(user_msg) == 'true') { 'true' }
        else { 'false' }}}}}}}}}}}}
    }
}

# ============================================================
# is_active — should we run plan mode for this user message?
# Returns 'true' | 'false'
# ============================================================
fun is_active(user_msg, opts) {
    mode = get_mode(opts)
    if (mode == "off") { 'false' }
    else { if (mode == "on") { 'true' }
    # mode == "auto": apply heuristics
    else { auto_trigger(user_msg) }}
}

# ============================================================
# generate — call LLM with planning prompt (no tools, temp=0)
# Returns the plan text string, or nil on error.
#
# Does a non-streaming http_post directly (mirrors LLM.chat_silent)
# to avoid circular imports: agent.sw → plan.sw → llm.sw → agent.sw.
# ============================================================
fun generate(user_msg, history, opts) {
    endpoint = map_get(opts, 'endpoint')
    api_key = map_get(opts, 'api_key')
    model = map_get(opts, 'model')

    url = plan_completions_url(endpoint)

    sys_content =
        "You are a planning assistant. The user wants to: " ++ to_string(user_msg) ++ "\n" ++
        "List the exact steps you will take as a numbered list.\n" ++
        "Be specific: name the files you will read or edit, the tools you will call.\n" ++
        "Keep it under 10 steps. No prose, just the numbered list."

    # Last 4 non-system, non-tool messages as prose context
    context_msgs = take_last_non_system(history, 4)

    # Wire messages: planning system + context + user task
    sys_wire = %{role: "system", content: sys_content}
    user_wire = %{role: "user", content: to_string(user_msg)}
    wire_msgs = [sys_wire] ++ plan_msgs_to_wire(context_msgs, []) ++ [user_wire]

    # Use the model's configured temperature — some providers (Kimi K2) reject
    # temperature:0 and require exactly 1.0. Fall back to 0 only for unknown models.
    temp = map_get(opts, 'temperature')
    req = %{
        model: model,
        temperature: if (temp != nil) { temp } else { 0 },
        max_tokens: 1024,
        stream: 'false',
        messages: wire_msgs
    }
    body = json_encode(req)

    base_hdrs = [{"Content-Type", "application/json"}]
    hdrs = if (api_key == nil) { base_hdrs }
           else { list_append(base_hdrs, {"Authorization", "Bearer " ++ api_key}) }

    # Pre-flight feedback: this http_post is synchronous and can block
    # 10-30s with no spinner of its own. Print one dim grey line before
    # the call and clear it right after so Plan.display() renders cleanly.
    # Gated off in headless/subagent — no TTY to draw on.
    show_wait = if (map_get(opts, 'headless') == 'true') { 'false' }
                else { if (map_get(opts, 'is_subagent') == 'true') { 'false' } else { 'true' } }
    if (show_wait == 'true') { print_inline("\r\e[K  \e[38;5;240m⋯ generating plan…\e[0m") }
    resp = http_post(url, hdrs, body)
    if (show_wait == 'true') { UI.tool_progress_clear() }
    if (resp == nil) { nil }
    else { plan_extract_content(resp) }
}

fun plan_completions_url(endpoint) {
    base = if (string_ends_with(endpoint, "/") == 'true') {
        string_sub(endpoint, 0, string_length(endpoint) - 1)
    } else { endpoint }
    if (string_ends_with(base, "/chat/completions") == 'true') { base }
    else { if (string_ends_with(base, "/v1") == 'true') {
        base ++ "/chat/completions"
    } else {
        base ++ "/v1/chat/completions"
    }}
}

# Return last N non-system, non-tool messages from history
fun take_last_non_system(history, n) {
    filtered = filter_for_context(history, [])
    len = length(filtered)
    if (len <= n) { filtered }
    else { drop_first_n(filtered, len - n) }
}

fun filter_for_context(msgs, acc) {
    if (length(msgs) == 0) { acc }
    else {
        m = hd(msgs)
        role = map_get(m, 'role')
        role_s = to_string(role)
        skip = if (role == 'system' || role_s == "system") { 'true' }
               else { if (role == 'tool' || role_s == "tool") { 'true' }
               else { 'false' }}
        if (skip == 'true') {
            filter_for_context(tl(msgs), acc)
        } else {
            filter_for_context(tl(msgs), list_append(acc, m))
        }
    }
}

fun drop_first_n(lst, n) {
    if (n <= 0) { lst }
    else { if (length(lst) == 0) { lst }
    else { drop_first_n(tl(lst), n - 1) }}
}

# Convert internal message maps to plain {role, content} wire maps.
# Drops tool-result messages; flattens tool_calls to prose only.
fun plan_msgs_to_wire(msgs, acc) {
    if (length(msgs) == 0) { acc }
    else {
        m = hd(msgs)
        role = map_get(m, 'role')
        role_s = to_string(role)
        if (role == 'tool' || role_s == "tool") {
            # Skip tool-result messages — noise for planning context
            plan_msgs_to_wire(tl(msgs), acc)
        } else {
            content = map_get(m, 'content')
            wire = %{
                role: role_s,
                content: if (content == nil) { "" } else { to_string(content) }
            }
            plan_msgs_to_wire(tl(msgs), list_append(acc, wire))
        }
    }
}

# Extract content string from a non-streaming (stream:false) response body
fun plan_extract_content(resp_body) {
    decoded = json_decode(resp_body)
    if (decoded == nil) { nil }
    else {
        err = map_get(decoded, 'error')
        if (err != nil) { nil }
        else {
            choices = map_get(decoded, 'choices')
            if (choices == nil || length(choices) == 0) { nil }
            else {
                choice0 = hd(choices)
                msg_obj = map_get(choice0, 'message')
                if (msg_obj == nil) { nil }
                else {
                    c = map_get(msg_obj, 'content')
                    if (c == nil) { nil }
                    else {
                        t = string_trim(to_string(c))
                        if (string_length(t) == 0) { nil } else { t }
                    }
                }
            }
        }
    }
}

# ============================================================
# display — render the bordered plan box to the terminal
# ============================================================
#
# Colors:
#   Header line:   brand_color() + bold  — deep red #af0000
#   Step numbers:  teal_info()           — #56b6c2
#   Step prose:    ui_text()             — #eeeeee
#   Box borders:   grey_border()         — #484848
#
# Format:
#   ┌─ Plan ──────────────────────────────────────
#   │  1. Read src/auth.sw to understand flow
#   │  2. Edit src/auth.sw — add JWT validation
#   └─────────────────────────────────────────────
# ============================================================
fun display(plan_text) {
    w = UI.term_width()
    # border_len = usable line width (leave 1 col margin on right)
    border_len = if (w > 8) { w - 1 } else { 60 }

    # Header: ┌─ Plan ─────────────────────────────
    # "┌─" = 2 chars, " Plan " = 6 chars, "─" = 1 char, then fill
    header_label = " Plan "
    fill_count = border_len - 2 - string_length(header_label) - 1
    fill_dashes = repeat_ch("─", if (fill_count < 0) { 0 } else { fill_count })
    header = UI.brand_color() ++ "\e[1m┌─" ++ header_label ++ "─" ++
             fill_dashes ++ "\e[0m" ++ UI.reset()

    # Footer: └────────────────────────────────────
    footer_count = if (border_len - 1 < 0) { 0 } else { border_len - 1 }
    footer_dashes = repeat_ch("─", footer_count)
    footer = UI.brand_color() ++ "\e[1m└" ++ footer_dashes ++ "\e[0m" ++ UI.reset()

    print("")
    print(header)
    print_plan_lines(string_split(plan_text, "\n"))
    print(footer)
    print("")
}

fun print_plan_lines(lines) {
    if (length(lines) == 0) { 'done' }
    else {
        line = hd(lines)
        trimmed = string_trim(line)
        if (string_length(trimmed) > 0) {
            rendered = render_plan_line(trimmed)
            print(UI.grey_border() ++ "│" ++ UI.reset() ++ "  " ++ rendered)
        }
        print_plan_lines(tl(lines))
    }
}

# Color the leading step number (e.g. "1." or "2)") teal, rest ui_text.
fun render_plan_line(line) {
    num_end = find_step_num_end(line, 0)
    if (num_end < 0) {
        UI.ui_text() ++ line ++ UI.reset()
    } else {
        num_part = string_sub(line, 0, num_end)
        rest_len = string_length(line) - num_end
        rest_part = string_sub(line, num_end, rest_len)
        UI.teal_info() ++ num_part ++ UI.reset() ++
        UI.ui_text() ++ rest_part ++ UI.reset()
    }
}

# Return the index just AFTER "N." or "N)" at the start of line.
# Returns -1 if the line does not start with digits followed by . or ).
fun find_step_num_end(line, i) {
    len = string_length(line)
    if (i >= len) { 0 - 1 }
    else {
        ch = string_sub(line, i, 1)
        if (is_digit_ch(ch) == 'true') {
            find_step_num_end(line, i + 1)
        } else {
            if (i == 0) {
                # First char was not a digit
                0 - 1
            } else {
                # Saw at least one digit; check for terminator
                if (ch == "." || ch == ")") { i + 1 }
                else { 0 - 1 }
            }
        }
    }
}

fun is_digit_ch(ch) {
    if (ch == "0") { 'true' }
    else { if (ch == "1") { 'true' }
    else { if (ch == "2") { 'true' }
    else { if (ch == "3") { 'true' }
    else { if (ch == "4") { 'true' }
    else { if (ch == "5") { 'true' }
    else { if (ch == "6") { 'true' }
    else { if (ch == "7") { 'true' }
    else { if (ch == "8") { 'true' }
    else { if (ch == "9") { 'true' }
    else { 'false' }}}}}}}}}}
}

fun repeat_ch(ch, n) {
    if (n <= 0) { "" } else { ch ++ repeat_ch(ch, n - 1) }
}

# ============================================================
# confirm(opts) — present the confirmation prompt and parse input.
# Returns: 'yes' | 'no' | {'edit', text}
#
# Routes through the Reader process (the sole owner of stdin) using the
# same correlation-token protocol as permission/picker prompts. The old
# behavior called read_line() directly from the main_agent process, which
# raced the Reader for stdin and could wedge the REPL. Falls back to a
# direct read_line only when no reader_pid is in opts (headless / tests).
# ============================================================
fun confirm(opts) {
    reader_pid = if (opts == nil) { nil } else { map_get(opts, 'reader_pid') }
    prompt = UI.warn_color() ++ "  Proceed? [y / n, or type a revised plan]  " ++
             UI.reset() ++ UI.brand_color() ++ "❯" ++ UI.reset() ++ " "
    line = if (reader_pid == nil) {
        print(prompt)
        raw = read_line("  " ++ UI.brand_color() ++ "❯" ++ UI.reset() ++ " ")
        if (raw == nil) { "" } else { to_string(raw) }
    } else {
        token = to_string(self()) ++ "/" ++ to_string(timestamp())
        send(reader_pid, {'confirm_ask', prompt, self(), token})
        await_confirm(token)
    }
    t = string_trim(line)
    lower = string_lower(t)
    parse_confirm(lower, t)
}

# Wait for THIS confirmation's answer; drop stale tokens. The 600s backstop
# is only for a dead Reader — a plan confirmation is a human action, so we
# don't impose a short deadline (mirrors agent.sw await_picker).
fun await_confirm(token) {
    receive {
        {'confirm_answer', t, line} -> if (t == token) { line } else { await_confirm(token) }
        after 600000 { "" }
    }
}

fun is_yes_input(lower) {
    if (lower == "y") { 'true' }
    else { if (lower == "yes") { 'true' }
    else { if (lower == "ok") { 'true' }
    else { if (lower == "go") { 'true' }
    else { if (lower == "1") { 'true' }
    else { 'false' }}}}}
}

fun is_no_input(lower) {
    if (lower == "n") { 'true' }
    else { if (lower == "no") { 'true' }
    else { if (lower == "cancel") { 'true' }
    else { if (lower == "abort") { 'true' }
    else { if (lower == "0") { 'true' }
    else { 'false' }}}}}
}

fun parse_confirm(lower, original) {
    if (is_yes_input(lower) == 'true') { 'yes' }
    else { if (is_no_input(lower) == 'true') { 'no' }
    else { if (string_length(original) == 0) { 'no' }
    # Any other text is treated as an edited/replacement plan
    else { {'edit', original} }
    }}
}

# ============================================================
# inject_into_history — add the confirmed plan to history
# ============================================================
# Appends a single assistant message carrying the plan + confirmation
# note, so the model sees its own plan and follows it when run_turn
# calls the LLM next.
#
# The user message (original_msg) is NOT added here — it was already
# appended to history by route_input before the plan flow ran. We only
# add the assistant plan acknowledgment.
fun inject_into_history(history, plan_text, original_msg) {
    plan_msg = %{
        role: 'assistant',
        content: "**Plan:**\n" ++ to_string(plan_text) ++
                 "\n\n[Plan confirmed. Executing now.]",
        tool_calls: nil,
        reasoning: nil
    }
    list_append(history, plan_msg)
}

# ============================================================
# show_mode — print current plan mode to the terminal.
# Called by the /plan slash command in agent.sw.
# ============================================================
fun show_mode(opts) {
    mode = get_mode(opts)
    color = if (mode == "on") { UI.brand_color() }
            else { if (mode == "off") { UI.grey_text() }
            else { UI.teal_info() }}
    print("")
    print(color ++ "  plan mode: " ++ mode ++ UI.reset())
    if (mode == "auto") {
        print(UI.grey_text() ++
              "  auto-triggers on: implement / build / create / add / " ++
              "refactor / migrate / rewrite, multi-step connectors, " ++
              "multi-file references" ++ UI.reset())
        print(UI.grey_text() ++
              "  skips: questions, short messages, /commands, just/only/quick prefix" ++
              UI.reset())
    }
    if (mode == "on") {
        print(UI.grey_text() ++
              "  always generates a plan before executing" ++ UI.reset())
    }
    if (mode == "off") {
        print(UI.grey_text() ++
              "  plan mode disabled — executing immediately" ++ UI.reset())
    }
    print("")
}
