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
        {'permission_ask', prompt_text, reply_pid} ->
            handle_permission(prompt_text, reply_pid)
        {'picker_ask', header, options, reply_pid, token} ->
            handle_picker(header, options, reply_pid, token)
        _other ->
            'ignore'
    }
    reader_loop()
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
    }
    'ok'
}

# Permission-prompt path: print the prompt text main gave us, read a
# single line, hand it straight back to the caller (not main_agent by
# default — the sender might be a subagent). No box drawing; the
# prompt is inline under the tool header.
fun handle_permission(prompt_text, reply_pid) {
    print(prompt_text)
    answer = read_line("  > ")
    reply = if (answer == nil) { "" } else { answer }
    if (reply_pid != nil) { send(reply_pid, {'permission_answer', reply}) }
    'ok'
}
