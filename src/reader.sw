module Reader

# ============================================================
# Reader — stdin → message process
# ============================================================
#
# A dedicated sw process that loops on read_line() and forwards each
# line to the main agent as a {'user_input', line} message. On EOF
# (Ctrl-D or pipe closed) it sends {'eof'}.
#
# Because swarmrt runs 4 scheduler threads, the reader being blocked
# on fgetc(stdin) only pins ONE of them — the main agent and heartbeat
# keep running on the others. This is what turns a line-based REPL
# into a continuous message loop.
#
# Handshake: the reader waits for a {'draw_and_read'} message from the
# main agent before drawing the input box and calling read_line. This
# prevents the next prompt from being drawn on top of the assistant's
# output while a turn is still streaming. Main sends the first signal
# at startup and another after every completed turn.

import UI

export [start]

fun start() {
    spawn(reader_loop())
}

# Reader is the ONLY process allowed to call read_line. Everything
# that needs to read a line (main user input, permission prompts,
# subagent input) sends a message and awaits a reply. This prevents
# two processes from ever racing on stdin — a race that previously
# caused "y" responses at permission prompts to be swallowed into
# the next LLM turn instead of resolving the permission.
fun reader_loop() {
    receive {
        {'draw_and_read'} ->
            handle_main_read()
        {'picker_ask', header, options, reply_pid, token} ->
            handle_picker(header, options, reply_pid, token)
        {'confirm_ask', prompt_text, reply_pid, token} ->
            handle_confirm(prompt_text, reply_pid, token)
        {'watch_interrupt', tok} ->
            watch_loop(tok)
        _other ->
            'ignore'
    }
    reader_loop()
}

# Interrupt-watch mode — entered while a NON-shell tool runs in a worker.
# Polls stdin for ESC (27) / Ctrl-C (3) and, on one, tells main_agent to
# interrupt the in-flight tool. Exits back to reader_loop when main sends
# {'stop_watch'} (the tool finished). Only ESC/Ctrl-C are forwarded; any
# other keystroke is dropped — matching the shell_managed + streaming
# interrupt convention. Shell tools (bash/log_wait) self-watch stdin inside
# shell_managed, so main never starts this watcher for them — stdin therefore
# always has exactly one reader at a time.
fun watch_loop(token) {
    # Check the stop signal first (non-blocking) so a tool that already
    # finished doesn't make us sit through a full poll slice.
    stop = receive { {'stop_watch'} -> 'stop' after 0 -> 'go' }
    if (stop == 'stop') { 'ok' }
    else {
        k = read_key(150)
        if (k == 27 || k == 3) {
            # Tag the interrupt with the dispatch token so collect_tool_result
            # only acts on it for the tool it was aimed at (read_key already
            # filters out arrow/F-key escape sequences, so k==27 is a bare Esc).
            main_pid = whereis('main_agent')
            if (main_pid != nil) { send(main_pid, {'interrupt', token}) }
        } else {
            # Every other key the user types mid-tool is type-ahead, not an
            # interrupt. Instead of dropping it, deposit the raw byte into the
            # runtime pending-input ring so the NEXT read_line seeds it as the
            # start of the following prompt (CC-style queued input). read_key
            # already drained arrow/F-key/paste framing, so k is a lone byte;
            # nil means poll-timeout / no key, so guard that.
            if (k != nil) { stdin_pending_push(bytes_to_string(byte(k))) }
        }
        watch_loop(token)
    }
}

# Arrow-key picker — render header + options, read a selection via
# the read_choice builtin, send the resulting index back to the
# caller. -1 means user cancelled (Esc or Ctrl+C).
fun handle_picker(header, options, reply_pid, token) {
    idx = read_choice(header, options)
    # Echo the caller's correlation token back so a late answer (after the
    # caller's deadline) can be identified and dropped instead of being
    # mis-applied to a later, different permission prompt.
    if (reply_pid != nil) { send(reply_pid, {'picker_answer', token, idx}) }
    'ok'
}

# Normal main-input path: draw the bordered box, read a line, forward
# it (or EOF) to main_agent as a user_input message.
fun handle_main_read() {
    UI.input_box_top()
    line = read_line(UI.input_prompt())
    main_pid = whereis('main_agent')
    if (line == nil) {
        if (main_pid != nil) { send(main_pid, {'eof'}) }
    } else {
        if (main_pid != nil) { send(main_pid, {'user_input', line}) }
        # Persist the submitted line to ~/.swarm-code/history so up-arrow recall
        # survives a restart. In-session recall already works via read_line's own
        # history push; this only adds cross-restart persistence.
        maybe_append_history(line)
    }
    'ok'
}

# Append one submitted line to the persistent history file, honouring the
# leading-space "don't record" convention and skipping blanks. rl_history_append
# creates the parent dir and rejects blank/multiline input itself; this is the
# policy layer on top of it.
fun maybe_append_history(line) {
    if (string_length(line) == 0) { 'ok' }
    else { if (string_starts_with(line, " ") == 'true') { 'ok' }
    else {
        path = history_path()
        if (path == nil) { 'ok' }
        else {
            rl_history_append(path, line)
            'ok'
        }
    }}
}

# Resolve ~/.swarm-code/history from $HOME, or nil if HOME is unset.
fun history_path() {
    home = getenv("HOME")
    if (home == nil) { nil } else { home ++ "/.swarm-code/history" }
}

# Plan-confirmation path: print the prompt, read one line, hand the RAW
# line straight back to the caller (plan.sw parses y/n/edit). Echoes the
# correlation token so a late answer can be matched/dropped — same
# discipline as handle_picker.
fun handle_confirm(prompt_text, reply_pid, token) {
    print(prompt_text)
    answer = read_line("  > ")
    line = if (answer == nil) { "" } else { to_string(answer) }
    if (reply_pid != nil) { send(reply_pid, {'confirm_answer', token, line}) }
    'ok'
}
