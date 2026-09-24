module CommandGuard

# ============================================================
# CommandGuard — token-aware risk classifier for shell commands
# ============================================================
#
# Config.check_permission asks this module how risky a model-supplied
# shell command is, for EVERY tool that runs one (bash, background,
# bg_server, run_tests.command — see Config.command_of). The old gate was
# raw substring matching on the bash tool only, which was wrong both ways:
#
#   * trivially bypassed — `rm -r -f /`, `rm -fr /`, `rm -rf  /*` (two
#     spaces), `dd of=/dev/sda if=…`, `:(){ :|:& };:`, `sudo<TAB>ls`, …
#   * false positives with no override — `grep -r shutdown src/`,
#     `echo reboot required`, `git commit -m 'halt the build'`, a heredoc
#     writing `def shutdown(` were all hard-denied.
#
# So the command is parsed the way sh would split it, then each SIMPLE
# COMMAND is judged by its command word and flags:
#
#   parse  — a small sh lexer: quotes ('…', "…", $'…'), backslash escapes,
#            `# comments`, separators (; & && | || newline ( ) ), redirections
#            (targets kept aside), heredoc bodies (skipped as data; an
#            unquoted body's $(…) is still parsed), and command substitution
#            ($(…), `…`, <(…), >(…)) — whose inner commands are parsed too.
#   judge  — strip leading VAR=val assignments and reserved words, unwrap
#            sudo/env/nohup/timeout/xargs/… , recurse into `sh -c SCRIPT` and
#            `eval`, then match the command word: rm (recursive/force flags in
#            any spelling + target), dd (of=), mkfs*/mkswap, shutdown/reboot/
#            halt/poweroff/telinit/init 0|6/systemctl poweroff, chmod/chown/
#            chgrp -R on /, sudo/doas. Redirections onto a raw disk and fork
#            bombs are checked on the whole command.
#
# This is a safety FLOOR against accidents, not a sandbox: a command built
# at runtime (`$cmd`, `x=re; ${x}boot`) can't be judged statically.
#
# Findings are {level, code, reason} with level 'hardline' (never allowed)
# or 'dangerous' (ask; denied when SWARM_CODE_DENY_DANGEROUS=1). The reason
# names the pattern AND the offending simple command, and is surfaced in the
# denial message so the model can adapt instead of retrying blindly.

export [classify, risk_of, uses_sudo, commands_of]

# ------------------------------------------------------------
# Public API
# ------------------------------------------------------------

# Most severe finding: {'hardline', reason} | {'dangerous', reason} | {'ok', ""}.
fun risk_of(cmd) {
    if (cmd == nil) { {'ok', ""} }
    else { worst(classify(to_string(cmd)), {'ok', ""}) }
}

# Every finding for the command (list of {level, code, reason}).
fun classify(cmd) {
    classify_text(to_string(cmd), 0)
}

# 'true' when any simple command (through wrappers, `sh -c`, `$(…)`) runs sudo/doas.
fun uses_sudo(cmd) {
    has_code(classify(to_string(cmd)), 'sudo')
}

# The parsed simple commands (list of word lists) — for tests and debugging.
fun commands_of(cmd) {
    map_get(parse(to_string(cmd)), 'cs')
}

fun worst(findings, best) {
    if (length(findings) == 0) { best }
    else {
        f = hd(findings)
        lvl = elem(f, 0)
        if (lvl == 'hardline') { {'hardline', elem(f, 2)} }
        else {
            next = if (elem(best, 0) == 'ok') { {'dangerous', elem(f, 2)} } else { best }
            worst(tl(findings), next)
        }
    }
}

fun has_code(findings, code) {
    if (length(findings) == 0) { 'false' }
    else { if (elem(hd(findings), 1) == code) { 'true' } else { has_code(tl(findings), code) } }
}

# Nesting guard for `sh -c "sh -c '…'"`, wrapper chains and $(…) inside $(…).
fun max_depth() { 8 }

fun classify_text(s, depth) {
    if (depth > max_depth()) { [] }
    else {
        st = parse(s)
        judge_all(map_get(st, 'cs'), depth, []) ++
            redirect_findings(map_get(st, 'rt'), []) ++
            fork_bomb_findings(s)
    }
}

# ============================================================
# Lexer — sh command string → simple commands
# ============================================================
# State (a map threaded through self-tail-recursive loops):
#   q     quote mode: 0 none, 1 '…', 2 "…", 3 $'…', 4 unquoted heredoc body
#   esc   'true' after a backslash
#   wl    chars of the word being built (in order)   hw  word in progress
#   wq    the word contained quoting (a quoted heredoc delimiter → literal body)
#   ws    words of the current simple command        cs  finished commands
#   rd    what the next word is: 'none' | 'out' | 'in' | 'hplain' | 'hdash'
#   rt    output-redirect targets (all commands)
#   hd    pending heredocs [%{d, dash, quoted}]      body 'true' while skipping bodies
#   cm    capture mode nil | 'paren' | 'tick' for $(…) / `…` / <(…)
#   cl    captured chars   cd paren depth   cq capture quote   cesc   cret (q to resume)

fun init_state() {
    %{q: 0, esc: 'false', wl: [], hw: 'false', wq: 'false', ws: [], cs: [], rd: 'none',
      rt: [], hd: [], body: 'false', cm: nil, cl: [], cd: 0, cq: 0, cesc: 'false', cret: 0}
}

fun parse(s) {
    finish_input(lex_lines(string_split(s, "\n"), init_state()))
}

fun lex_lines(lines, st) {
    if (length(lines) == 0) { st }
    else {
        line = hd(lines)
        rest = tl(lines)
        if (map_get(st, 'cm') == nil && map_get(st, 'body') == 'true') {
            h = hd(map_get(st, 'hd'))
            if (is_delim_line(line, h) == 'true') {
                left = tl(map_get(st, 'hd'))
                st2 = map_put(map_put(st, 'hd', left), 'body', if (length(left) > 0) { 'true' } else { 'false' })
                lex_lines(rest, st2)
            } else { if (map_get(h, 'quoted') == 'true') {
                lex_lines(rest, st)
            } else {
                # Unquoted body: data, but $(…) / `…` in it still execute.
                lex_lines(rest, end_line(lex_chars(string_chars(line), map_put(st, 'q', 4))))
            }}
        } else {
            lex_lines(rest, end_line(lex_chars(string_chars(line), st)))
        }
    }
}

fun is_delim_line(line, h) {
    l0 = if (string_ends_with(line, "\r") == 'true') { string_sub(line, 0, string_length(line) - 1) } else { line }
    l = if (map_get(h, 'dash') == 'true') { strip_leading_tabs(l0) } else { l0 }
    if (l == map_get(h, 'd')) { 'true' } else { 'false' }
}

fun strip_leading_tabs(s) {
    if (string_starts_with(s, "\t") == 'true') { strip_leading_tabs(string_sub(s, 1, string_length(s) - 1)) }
    else { s }
}

# End of input: an unterminated $(…) is still judged; an open word/command closes.
fun finish_input(st) {
    if (map_get(st, 'cm') != nil) { finish_cmd(end_capture(st)) }
    else { finish_cmd(st) }
}

# What a newline means depends on where we are.
fun end_line(st) {
    q = map_get(st, 'q')
    if (map_get(st, 'cm') != nil) { map_put(st, 'cl', list_append(map_get(st, 'cl'), "\n")) }
    else { if (q == 1 || q == 2 || q == 3) { add_char(st, "\n") }
    else { if (q == 4) { map_put(map_put(st, 'q', 0), 'esc', 'false') }
    else { if (map_get(st, 'esc') == 'true') { map_put(st, 'esc', 'false') }   # line continuation
    else {
        st2 = finish_cmd(st)
        if (length(map_get(st2, 'hd')) > 0) { map_put(st2, 'body', 'true') } else { st2 }
    }}}}
}

fun lex_chars(chars, st) {
    if (length(chars) == 0) { st }
    else { if (map_get(st, 'cm') == nil && map_get(st, 'esc') == 'false') {
        # Fast path: take a whole run of ordinary chars in one go (one state
        # update per run, not per char) — a 75KB `python -c '…'` word
        # otherwise costs a map update per byte.
        q = map_get(st, 'q')
        wl = map_get(st, 'wl')
        n0 = length(wl)
        # The run is appended straight onto the word (list_append is O(1)
        # amortized; `wl ++ run` would re-copy the word on every line).
        r = scan_plain(chars, q, if (q == 4) { [] } else { wl })
        grown = elem(r, 1)
        st2 = if (q == 4 || length(grown) == n0) { st }
              else { map_put(map_put(st, 'wl', grown), 'hw', 'true') }
        rest = elem(r, 0)
        if (length(rest) == 0) { st2 }
        else {
            r2 = step(hd(rest), tl(rest), st2)
            lex_chars(elem(r2, 0), elem(r2, 1))
        }
    } else {
        r = step(hd(chars), tl(chars), st)
        lex_chars(elem(r, 0), elem(r, 1))
    }}
}

# Leading run of chars that are literal in quote mode q → {rest, run}.
fun scan_plain(chars, q, acc) {
    if (length(chars) == 0) { {chars, acc} }
    else {
        c = hd(chars)
        if (is_special(q, c) == 'true') { {chars, acc} }
        else { scan_plain(tl(chars), q, list_append(acc, c)) }
    }
}

fun is_special(q, c) {
    if (q == 1) { if (c == "'") { 'true' } else { 'false' } }
    else { if (q == 2) { in_list(["\"", "\\", "$", "`"], c) }
    else { if (q == 3) { if (c == "'" || c == "\\") { 'true' } else { 'false' } }
    else { if (q == 4) { in_list(["\\", "$", "`"], c) }
    else { in_list([" ", "\t", "\\", "'", "\"", "`", "$", "#", ";", "|", "(", ")", "&", ">", "<"], c) }}}}
}

fun peek(rest) { if (length(rest) == 0) { "" } else { hd(rest) } }

# One character → {remaining chars, new state}.
fun step(c, rest, st) {
    if (map_get(st, 'cm') != nil) { cap_step(c, rest, st) }
    else {
        q = map_get(st, 'q')
        if (map_get(st, 'esc') == 'true') {
            st2 = map_put(st, 'esc', 'false')
            if (q == 4) { {rest, st2} }
            else { if (q == 3) { {rest, add_char(add_char(st2, "\\"), c)} }
            else { {rest, add_char(st2, c)} } }
        } else { if (q == 1) {
            if (c == "'") { {rest, map_put(st, 'q', 0)} } else { {rest, add_char(st, c)} }
        } else { if (q == 3) {
            if (c == "\\") { {rest, map_put(st, 'esc', 'true')} }
            else { if (c == "'") { {rest, map_put(st, 'q', 0)} } else { {rest, add_char(st, c)} } }
        } else { if (q == 2) {
            if (c == "\\") { {rest, map_put(st, 'esc', 'true')} }
            else { if (c == "\"") { {rest, map_put(st, 'q', 0)} }
            else { if (c == "`") { {rest, start_capture(st, 'tick', 2)} }
            else { if (c == "$" && peek(rest) == "(") { {tl(rest), start_capture(st, 'paren', 2)} }
            else { {rest, add_char(st, c)} } } } }
        } else { if (q == 4) {
            if (c == "\\") { {rest, map_put(st, 'esc', 'true')} }
            else { if (c == "`") { {rest, start_capture(st, 'tick', 4)} }
            else { if (c == "$" && peek(rest) == "(") { {tl(rest), start_capture(st, 'paren', 4)} }
            else { {rest, st} } } }
        } else {
            step_unquoted(c, rest, st)
        }}}}}
    }
}

fun step_unquoted(c, rest, st) {
    nxt = peek(rest)
    if (c == " " || c == "\t") { {rest, finish_word(st)} }
    else { if (c == "\\") { {rest, map_put(mark_quoted(st), 'esc', 'true')} }
    else { if (c == "'") { {rest, map_put(mark_quoted(st), 'q', 1)} }
    else { if (c == "\"") { {rest, map_put(mark_quoted(st), 'q', 2)} }
    else { if (c == "`") { {rest, start_capture(st, 'tick', 0)} }
    else { if (c == "$" && nxt == "(") { {tl(rest), start_capture(st, 'paren', 0)} }
    else { if (c == "$" && nxt == "'") { {tl(rest), map_put(mark_quoted(st), 'q', 3)} }
    else { if (c == "#" && map_get(st, 'hw') == 'false') { {[], st} }   # comment to end of line
    else { if (c == ";" || c == "|" || c == "(" || c == ")") { {rest, finish_cmd(st)} }
    else { if (c == "&") {
        # `&>file` is a redirection; `&`, `&&`, `|&` end the command.
        if (nxt == ">") { {rest, finish_word(st)} } else { {rest, finish_cmd(st)} }
    }
    else { if (c == ">" || c == "<") { redirect_step(c, rest, st) }
    else { {rest, add_char(st, c)} }}}}}}}}}}}
}

# `>`, `>>`, `>&`, `>|`, `<`, `<&`, `<>`, `<<`, `<<-`, `<<<`, `<(…)`, `>(…)`.
fun redirect_step(c, rest, st) {
    st1 = finish_word(st)
    nxt = peek(rest)
    if (nxt == "(") { {tl(rest), start_capture(st1, 'paren', 0)} }   # process substitution
    else { if (c == ">") {
        rest2 = if (nxt == ">" || nxt == "&" || nxt == "|") { tl(rest) } else { rest }
        {rest2, map_put(st1, 'rd', 'out')}
    } else { if (nxt == "<") {
        r2 = tl(rest)
        n2 = peek(r2)
        if (n2 == "<") { {tl(r2), map_put(st1, 'rd', 'in')} }             # here-string
        else { if (n2 == "-") { {tl(r2), map_put(st1, 'rd', 'hdash')} }
        else { {r2, map_put(st1, 'rd', 'hplain')} } }
    } else {
        rest2 = if (nxt == "&" || nxt == ">") { tl(rest) } else { rest }
        {rest2, map_put(st1, 'rd', 'in')}
    }}}
}

fun add_char(st, c) {
    map_put(map_put(st, 'wl', list_append(map_get(st, 'wl'), c)), 'hw', 'true')
}

fun mark_quoted(st) {
    map_put(map_put(st, 'wq', 'true'), 'hw', 'true')
}

fun finish_word(st) {
    if (map_get(st, 'hw') == 'false') { st }
    else {
        w = join_chars(map_get(st, 'wl'))
        rd = map_get(st, 'rd')
        st2 = if (rd == 'out') { map_put(st, 'rt', list_append(map_get(st, 'rt'), w)) }
              else { if (rd == 'in') { st }
              else { if (rd == 'hplain' || rd == 'hdash') {
                  h = %{d: w, dash: if (rd == 'hdash') { 'true' } else { 'false' },
                        quoted: map_get(st, 'wq')}
                  map_put(st, 'hd', list_append(map_get(st, 'hd'), h))
              } else { map_put(st, 'ws', list_append(map_get(st, 'ws'), w)) }}}
        map_put(map_put(map_put(map_put(st2, 'wl', []), 'hw', 'false'), 'wq', 'false'), 'rd', 'none')
    }
}

fun finish_cmd(st) {
    st1 = finish_word(st)
    ws = map_get(st1, 'ws')
    st2 = if (length(ws) > 0) { map_put(st1, 'cs', list_append(map_get(st1, 'cs'), ws)) } else { st1 }
    map_put(map_put(st2, 'ws', []), 'rd', 'none')
}

# ---------- command substitution capture ----------

fun start_capture(st, mode, ret) {
    map_put(map_put(map_put(map_put(map_put(map_put(st, 'cm', mode), 'cl', []), 'cd', 1), 'cq', 0),
            'cesc', 'false'), 'cret', ret)
}

fun cap_add(st, c) { map_put(st, 'cl', list_append(map_get(st, 'cl'), c)) }

fun cap_step(c, rest, st) {
    if (map_get(st, 'cesc') == 'true') { {rest, map_put(cap_add(st, c), 'cesc', 'false')} }
    else { if (map_get(st, 'cm') == 'tick') { cap_tick(c, rest, st) }
    else { cap_paren(c, rest, st) }}
}

fun cap_tick(c, rest, st) {
    if (c == "\\") { {rest, map_put(cap_add(st, c), 'cesc', 'true')} }
    else { if (c == "`") { {rest, end_capture(st)} }
    else { {rest, cap_add(st, c)} }}
}

# Inside $(…): track quotes so a `)` in a string doesn't close it, and
# nesting depth so $(a $(b)) closes at the right paren.
fun cap_paren(c, rest, st) {
    cq = map_get(st, 'cq')
    if (cq == 1) {
        if (c == "'") { {rest, map_put(cap_add(st, c), 'cq', 0)} } else { {rest, cap_add(st, c)} }
    }
    else { if (c == "\\") { {rest, map_put(cap_add(st, c), 'cesc', 'true')} }
    else { if (cq == 2) {
        if (c == "\"") { {rest, map_put(cap_add(st, c), 'cq', 0)} } else { {rest, cap_add(st, c)} }
    }
    else { if (c == "'") { {rest, map_put(cap_add(st, c), 'cq', 1)} }
    else { if (c == "\"") { {rest, map_put(cap_add(st, c), 'cq', 2)} }
    else { if (c == "(") { {rest, map_put(cap_add(st, c), 'cd', map_get(st, 'cd') + 1)} }
    else { if (c == ")") { cap_close(rest, st) }
    else { {rest, cap_add(st, c)} }}}}}}}
}

fun cap_close(rest, st) {
    d = map_get(st, 'cd')
    if (d <= 1) { {rest, end_capture(st)} }
    else { {rest, map_put(cap_add(st, ")"), 'cd', d - 1)} }
}

# The captured text is a full command line of its own: parse it and fold its
# commands and redirect targets into ours. The surrounding word gets a `$`
# placeholder (its runtime value is unknowable).
fun end_capture(st) {
    inner = parse(join_chars(map_get(st, 'cl')))
    ret = map_get(st, 'cret')
    st1 = map_put(map_put(map_put(st, 'cm', nil), 'cl', []), 'q', ret)
    st2 = map_put(map_put(st1, 'cs', map_get(st1, 'cs') ++ map_get(inner, 'cs')),
                  'rt', map_get(st1, 'rt') ++ map_get(inner, 'rt'))
    if (ret == 4) { st2 } else { add_char(st2, "$") }
}

# ---------- joining chars without quadratic copying ----------
# `acc ++ c` per char is O(n²) on a long word (a big `python -c '…'`), so
# join in balanced halves: O(n log n).
fun join_chars(lst) { join_n(lst, length(lst)) }

fun join_n(lst, n) {
    if (n <= 32) { join_lin(lst, n, "") }
    else {
        h = n / 2
        join_n(take_n(lst, h, []), h) ++ join_n(drop_n(lst, h), n - h)
    }
}

fun join_lin(lst, n, acc) {
    if (n <= 0 || length(lst) == 0) { acc } else { join_lin(tl(lst), n - 1, acc ++ hd(lst)) }
}

fun take_n(lst, n, acc) {
    if (n <= 0 || length(lst) == 0) { acc } else { take_n(tl(lst), n - 1, list_append(acc, hd(lst))) }
}

fun drop_n(lst, n) {
    if (n <= 0 || length(lst) == 0) { lst } else { drop_n(tl(lst), n - 1) }
}

# ============================================================
# Judge — one simple command (a word list) → findings
# ============================================================

fun judge_all(cmds, depth, acc) {
    if (length(cmds) == 0) { acc }
    else { judge_all(tl(cmds), depth, acc ++ judge(hd(cmds), depth)) }
}

fun finding(level, code, reason, words) {
    {level, code, reason ++ " — in `" ++ string_truncate(join_words(words, ""), 120) ++ "`"}
}

fun judge(words, depth) {
    ws = skip_prefix(words)
    if (length(ws) == 0 || depth > max_depth()) { [] }
    else {
        name = basename(hd(ws))
        args = tl(ws)
        if (name == "sudo" || name == "doas") {
            [finding('dangerous', 'sudo', name ++ " (privilege escalation)", ws)] ++
                judge(skip_opts(args, ["-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T"]), depth + 1)
        }
        else { if (name == "env") { judge(skip_env(args), depth + 1) }
        else { if (is_plain_wrapper(name) == 'true') { judge(skip_opts(args, []), depth + 1) }
        else { if (name == "nice") { judge(skip_opts(args, ["-n"]), depth + 1) }
        else { if (name == "ionice") { judge(skip_opts(args, ["-c", "-n", "-p", "-P", "-u"]), depth + 1) }
        else { if (name == "timeout") { judge(drop_n(skip_opts(args, ["-s", "-k"]), 1), depth + 1) }
        else { if (name == "xargs") {
            judge(skip_opts(args, ["-I", "-i", "-n", "-P", "-L", "-l", "-s", "-d", "-E", "-e", "-a"]), depth + 1)
        }
        else { if (name == "watch") { judge(skip_opts(args, ["-n", "-d"]), depth + 1) }
        else { if (is_shell(name) == 'true') {
            script = shell_c_script(args, 'false')
            if (script == nil) { [] } else { classify_text(script, depth + 1) }
        }
        else { if (name == "eval") { classify_text(join_words(args, ""), depth + 1) }
        else { judge_verb(name, args, ws) }}}}}}}}}}
    }
}

fun is_plain_wrapper(name) {
    in_list(["nohup", "exec", "command", "builtin", "time", "setsid", "unbuffer",
             "busybox", "stdbuf", "chrt", "taskset", "caffeinate"], name)
}

fun is_shell(name) {
    in_list(["sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "fish"], name)
}

# The script argument of `sh -c SCRIPT` (also -lc / -ec / -xc bundles), or
# nil for `sh file.sh` (a file we can't see). `-o opt` / `+o opt` take a value.
fun shell_c_script(args, saw_c) {
    if (length(args) == 0) { nil }
    else {
        a = hd(args)
        if (a == "-o" || a == "+o" || a == "-O" || a == "+O") { shell_c_script(drop_n(args, 2), saw_c) }
        else { if (a == "--") { shell_c_script(tl(args), saw_c) }
        else { if (string_starts_with(a, "-") == 'true' || string_starts_with(a, "+") == 'true') {
            has_c = if (string_starts_with(a, "--") == 'false' && string_contains(a, "c") == 'true') { 'true' } else { saw_c }
            shell_c_script(tl(args), has_c)
        } else {
            if (saw_c == 'true') { a } else { nil }
        }}}
    }
}

fun judge_verb(name, args, ws) {
    if (name == "rm") { rm_findings(args, ws) }
    else { if (name == "mkfs" || string_starts_with(name, "mkfs.") == 'true' ||
               name == "mke2fs" || name == "mkswap") {
        [finding('hardline', 'mkfs', name ++ " formats a filesystem / swap device", ws)]
    }
    else { if (name == "dd") { dd_findings(args, ws, []) }
    else { if (in_list(["shutdown", "reboot", "halt", "poweroff", "telinit"], name) == 'true') {
        [finding('hardline', 'halt', name ++ " halts or reboots the machine", ws)]
    }
    else { if (name == "init" && length(args) > 0 && (hd(args) == "0" || hd(args) == "6")) {
        [finding('hardline', 'halt', "init " ++ hd(args) ++ " halts or reboots the machine", ws)]
    }
    else { if (name == "systemctl") {
        sub = first_non_flag(args)
        if (sub != nil && in_list(["poweroff", "reboot", "halt", "kexec"], sub) == 'true') {
            [finding('hardline', 'halt', "systemctl " ++ sub ++ " halts or reboots the machine", ws)]
        } else { [] }
    }
    else { if (name == "chmod" || name == "chown" || name == "chgrp") { perm_findings(name, args, ws) }
    else { [] }}}}}}}
}

# ---------- rm ----------
# Recursive = -r/-R/--recursive, force = -f/--force, in any order or bundle
# (-rf, -fr, -Rf, -r -f). Everything after `--` is a target.
fun rm_findings(args, ws) {
    s = rm_scan(args, 'false', 'false', 'false', [], 'false')
    rec = elem(s, 0)
    force = elem(s, 1)
    nopres = elem(s, 2)
    targets = elem(s, 3)
    if (rec == 'true' && (nopres == 'true' || any_target(targets, 'root') == 'true')) {
        what = if (nopres == 'true') { "rm -r --no-preserve-root" } else { "rm -r on the filesystem root (/ or /*)" }
        [finding('hardline', 'rm_root', what, ws)]
    }
    else { if (rec == 'true' && any_target(targets, 'home') == 'true') {
        [finding('dangerous', 'rm_home', "rm -r on your home directory", ws)]
    }
    else { if (rec == 'true' && force == 'true' &&
               (any_target(targets, 'under_home') == 'true' || any_target(targets, 'system') == 'true')) {
        [finding('dangerous', 'rm_outside', "rm -rf on a path outside the project (home or system directory)", ws)]
    }
    else { [] }}}
}

fun rm_scan(args, rec, force, nopres, targets, after_dd) {
    if (length(args) == 0) { {rec, force, nopres, targets} }
    else {
        a = hd(args)
        rest = tl(args)
        if (after_dd == 'true') { rm_scan(rest, rec, force, nopres, list_append(targets, a), after_dd) }
        else { if (a == "--") { rm_scan(rest, rec, force, nopres, targets, 'true') }
        else { if (a == "--recursive") { rm_scan(rest, 'true', force, nopres, targets, after_dd) }
        else { if (a == "--force") { rm_scan(rest, rec, 'true', nopres, targets, after_dd) }
        else { if (a == "--no-preserve-root") { rm_scan(rest, rec, force, 'true', targets, after_dd) }
        else { if (string_starts_with(a, "--") == 'true') { rm_scan(rest, rec, force, nopres, targets, after_dd) }
        else { if (string_starts_with(a, "-") == 'true' && string_length(a) > 1) {
            r2 = if (string_contains(a, "r") == 'true' || string_contains(a, "R") == 'true') { 'true' } else { rec }
            f2 = if (string_contains(a, "f") == 'true') { 'true' } else { force }
            rm_scan(rest, r2, f2, nopres, targets, after_dd)
        }
        else { rm_scan(rest, rec, force, nopres, list_append(targets, a), after_dd) }}}}}}}
    }
}

fun any_target(targets, kind) {
    if (length(targets) == 0) { 'false' }
    else {
        t = norm_path(hd(targets))
        hit = if (kind == 'root') { is_root_path(t) }
              else { if (kind == 'home') { is_home_path(t) }
              else { if (kind == 'under_home') { is_under_home(t) }
              else { is_system_path(t) }}}
        if (hit == 'true') { 'true' } else { any_target(tl(targets), kind) }
    }
}

# Collapse `//` and drop trailing slashes (keeping a lone `/`).
fun norm_path(p) {
    c = collapse_slashes(p)
    strip_trailing_slashes(c)
}

fun collapse_slashes(p) {
    if (string_contains(p, "//") == 'true') { collapse_slashes(string_replace(p, "//", "/")) } else { p }
}

fun strip_trailing_slashes(p) {
    if (string_length(p) > 1 && string_ends_with(p, "/") == 'true') {
        strip_trailing_slashes(string_sub(p, 0, string_length(p) - 1))
    } else { p }
}

fun is_root_path(t) {
    in_list(["/", "/*", "/.", "/..", "/.*"], t)
}

# ~, $HOME, ${HOME} (optionally /* or /.) — or the literal $HOME path.
fun is_home_path(t) {
    rest = home_rest(t)
    if (rest != nil && in_list(["", "/*", "/.", "/.*"], rest) == 'true') { 'true' }
    else {
        h = getenv("HOME")
        if (h == nil) { 'false' }
        else {
            hn = norm_path(to_string(h))
            if (hn != "/" && (t == hn || t == hn ++ "/*" || t == hn ++ "/.")) { 'true' } else { 'false' }
        }
    }
}

fun is_under_home(t) {
    if (home_rest(t) != nil) { 'true' } else { 'false' }
}

# What follows a leading ~ / $HOME / ${HOME}, or nil if the path doesn't start with one.
fun home_rest(t) {
    if (string_starts_with(t, "${HOME}") == 'true') { string_sub(t, 7, string_length(t) - 7) }
    else { if (string_starts_with(t, "$HOME") == 'true') { string_sub(t, 5, string_length(t) - 5) }
    else { if (string_starts_with(t, "~") == 'true') {
        r = string_sub(t, 1, string_length(t) - 1)
        # ~user/… is another user's home: treat like ~/…
        if (r == "" || string_starts_with(r, "/") == 'true') { r } else { "/" ++ r }
    } else { nil }}}
}

# An absolute path outside the usual scratch/project roots (the pre-existing
# rm -rf policy: /tmp, /var/…, /home/…, /Users/…, /opt/… are fine).
fun is_system_path(t) {
    if (string_starts_with(t, "/") == 'false') { 'false' }
    else { if (starts_with_any(t, ["/tmp", "/var/", "/Users/", "/home/", "/opt/",
                                   "/private/tmp", "/private/var/"]) == 'true') { 'false' }
    else { 'true' }}
}

# ---------- dd ----------
fun dd_findings(args, ws, acc) {
    if (length(args) == 0) { acc }
    else {
        a = hd(args)
        next = if (string_starts_with(a, "of=") == 'true') {
            dev = norm_path(string_sub(a, 3, string_length(a) - 3))
            if (is_raw_disk(dev) == 'true') {
                list_append(acc, finding('hardline', 'dd_disk', "dd writing to raw disk device " ++ dev, ws))
            } else { if (string_starts_with(dev, "/dev/") == 'true' && is_benign_dev(dev) == 'false') {
                list_append(acc, finding('dangerous', 'dd_dev', "dd writing to device " ++ dev, ws))
            } else { acc }}
        } else { acc }
        dd_findings(tl(args), ws, next)
    }
}

fun is_raw_disk(dev) {
    starts_with_any(dev, ["/dev/sd", "/dev/nvme", "/dev/disk", "/dev/rdisk", "/dev/hd", "/dev/vd",
                          "/dev/xvd", "/dev/mmcblk", "/dev/md", "/dev/dm-", "/dev/mapper/"])
}

fun is_benign_dev(dev) {
    if (in_list(["/dev/null", "/dev/zero", "/dev/stdout", "/dev/stderr", "/dev/tty",
                 "/dev/full", "/dev/random", "/dev/urandom"], dev) == 'true') { 'true' }
    else { starts_with_any(dev, ["/dev/fd/", "/dev/pts/"]) }
}

fun redirect_findings(targets, acc) {
    if (length(targets) == 0) { acc }
    else {
        t = norm_path(hd(targets))
        next = if (is_raw_disk(t) == 'true') {
            list_append(acc, {'hardline', 'redirect_disk', "shell redirection onto raw disk device " ++ t})
        } else { acc }
        redirect_findings(tl(targets), next)
    }
}

# ---------- chmod / chown / chgrp ----------
# Recursive (-R, bundles, --recursive) on / or /*, or `chmod 000 /`.
fun perm_findings(name, args, ws) {
    rec = perm_recursive(args)
    rest = non_flags(args, [])
    mode = if (length(rest) == 0) { "" } else { hd(rest) }
    targets = if (length(rest) == 0) { [] } else { tl(rest) }
    lockout = if (name == "chmod" && in_list(["000", "0000", "a-rwx", "ugo-rwx", "a=", "ugo="], mode) == 'true') { 'true' } else { 'false' }
    if (any_target(targets, 'root') == 'true' && (rec == 'true' || lockout == 'true')) {
        flag = if (rec == 'true') { " -R" } else { " " ++ mode }
        [finding('hardline', 'perm_root', name ++ flag ++ " on the filesystem root", ws)]
    } else { [] }
}

fun perm_recursive(args) {
    if (length(args) == 0) { 'false' }
    else {
        a = hd(args)
        if (a == "--recursive" || (string_starts_with(a, "-") == 'true' && string_starts_with(a, "--") == 'false' &&
                                   string_contains(a, "R") == 'true')) { 'true' }
        else { perm_recursive(tl(args)) }
    }
}

# ---------- fork bomb ----------
# `NAME(){ NAME|NAME& };NAME` in any spacing: find each `(){` definition in
# the whitespace-stripped command and check whether its body pipes the
# function into itself in the background.
fun fork_bomb_findings(s) {
    stripped = string_replace(string_replace(string_replace(s, " ", ""), "\t", ""), "\n", "")
    if (string_contains(stripped, "(){") == 'false') { [] }
    else { fb_scan(string_split(stripped, "(){"), stripped) }
}

fun fb_scan(parts, stripped) {
    if (length(parts) < 2) { [] }
    else {
        name = trailing_name(hd(parts))
        if (string_length(name) > 0 && string_contains(stripped, name ++ "|" ++ name ++ "&") == 'true') {
            [{'hardline', 'fork_bomb', "fork bomb (" ++ name ++ "(){ " ++ name ++ "|" ++ name ++ "& })"}]
        } else { fb_scan(tl(parts), stripped) }
    }
}

# The function name right before `(){`: the chars after the last separator.
fun trailing_name(part) {
    tn_loop(string_chars(part), "")
}

fun tn_loop(chars, cur) {
    if (length(chars) == 0) { cur }
    else {
        c = hd(chars)
        if (in_list([";", "&", "|", "{", "}", "(", ")"], c) == 'true') { tn_loop(tl(chars), "") }
        else { tn_loop(tl(chars), cur ++ c) }
    }
}

# ============================================================
# Word helpers
# ============================================================

# Drop leading VAR=val assignments and reserved words (`!`, `{`, `if`, `then`,
# `do`, …) so the real command word comes first.
fun skip_prefix(words) {
    if (length(words) == 0) { words }
    else {
        w = hd(words)
        if (is_assignment(w) == 'true' || is_reserved(w) == 'true') { skip_prefix(tl(words)) }
        else { words }
    }
}

fun is_reserved(w) {
    in_list(["!", "{", "}", "if", "then", "else", "elif", "fi", "do", "done", "while",
             "until", "case", "esac", "in", "for", "select", "function", "coproc", "[[", "]]"], w)
}

fun is_assignment(w) {
    i = string_index_of(w, "=")
    if (i <= 0) { 'false' }
    else { is_ident(string_sub(w, 0, i)) }
}

fun is_ident(s) {
    cs = string_chars(s)
    if (length(cs) == 0) { 'false' }
    else { if (is_digit_char(hd(cs)) == 'true') { 'false' } else { all_ident(cs) } }
}

fun all_ident(cs) {
    if (length(cs) == 0) { 'true' }
    else {
        c = hd(cs)
        if ((c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || is_digit_char(c) == 'true' || c == "_") {
            all_ident(tl(cs))
        } else { 'false' }
    }
}

fun is_digit_char(c) { if (c >= "0" && c <= "9" && string_length(c) == 1) { 'true' } else { 'false' } }

# Skip leading options; options named in `with_arg` consume the next word.
# Stops at the first non-option (the wrapped command) or after `--`.
fun skip_opts(args, with_arg) {
    if (length(args) == 0) { args }
    else {
        a = hd(args)
        if (a == "--") { tl(args) }
        else { if (string_starts_with(a, "-") == 'true' && string_length(a) > 1) {
            if (in_list(with_arg, a) == 'true') { skip_opts(drop_n(args, 2), with_arg) }
            else { skip_opts(tl(args), with_arg) }
        } else { args }}
    }
}

# env [-i] [-u NAME] [-C DIR] [NAME=val ...] CMD — assignments are dropped by
# skip_prefix inside judge().
fun skip_env(args) {
    skip_opts(args, ["-u", "-C", "-S", "--unset", "--chdir"])
}

fun first_non_flag(args) {
    if (length(args) == 0) { nil }
    else { if (string_starts_with(hd(args), "-") == 'true') { first_non_flag(tl(args)) } else { hd(args) } }
}

fun non_flags(args, acc) {
    if (length(args) == 0) { acc }
    else {
        a = hd(args)
        next = if (string_starts_with(a, "-") == 'true') { acc } else { list_append(acc, a) }
        non_flags(tl(args), next)
    }
}

fun basename(w) {
    parts = string_split(w, "/")
    last = last_of(parts, w)
    if (string_length(last) == 0) { w } else { last }
}

fun last_of(lst, fallback) {
    if (length(lst) == 0) { fallback }
    else { if (length(lst) == 1) { hd(lst) } else { last_of(tl(lst), fallback) } }
}

fun join_words(words, acc) {
    if (length(words) == 0) { acc }
    else {
        sep = if (string_length(acc) == 0) { "" } else { " " }
        join_words(tl(words), acc ++ sep ++ hd(words))
    }
}

fun starts_with_any(s, prefixes) {
    if (length(prefixes) == 0) { 'false' }
    else { if (string_starts_with(s, hd(prefixes)) == 'true') { 'true' } else { starts_with_any(s, tl(prefixes)) } }
}

fun in_list(lst, item) {
    if (length(lst) == 0) { 'false' }
    else { if (hd(lst) == item) { 'true' } else { in_list(tl(lst), item) } }
}
