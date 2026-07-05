module Background

import Util

# ============================================================
# Background — async shell tasks (OS-detached, heartbeat-monitored)
# ============================================================
#
# background(command, label) starts a shell command as an OS-detached
# process (via the shell_detached runtime builtin) and returns
# immediately with a task id. The main agent keeps responding to the
# user; the heartbeat process polls running tasks on each tick and
# pushes {'bg_done', ...} messages to main_agent as soon as any task
# finishes.
#
# Why OS-level instead of sw-level spawn? sw_spawn from within a
# running scheduler thread queues the new process on the SAME thread,
# which doesn't always get scheduled reliably mid-turn. shell_detached
# double-forks + setsid()s a real OS process (session/pgroup leader,
# stdin=/dev/null, stdout+stderr→log) that runs on its own, completely
# independent of the sw scheduler — and, being pgroup leader, can be
# killed as a whole group via pid_kill_group.
#
# ETS layout per task:
#   '{id}/status'    → 'pending' | 'done' | 'error' | 'killed'
#   '{id}/cmd'       → command string
#   '{id}/label'     → human label
#   '{id}/pid'       → OS pid (string)
#   '{id}/pid_file'  → path to pid file
#   '{id}/log_file'  → path to captured stdout+stderr log
#   '{id}/started'   → ms timestamp
#   '{id}/ended'     → ms timestamp (once done)
#   '{id}/exit'      → exit code (once done)
#   '{id}/log_size'    → last observed byte size of the log (stall detector)
#   '{id}/log_grew_at' → ms timestamp the log size last changed
#   '{id}/stalled_sent'→ 'true' once a bg_stalled msg has fired (at most once)
#   'next_id'        → counter

export [
    init, launch, launch_server, status, result, list_all,
    log_path_for, tail_log, kill_task,
    poll_and_notify, all_pending_ids,
    finalize_if_done, wait_for_task,
    fg_claim, fg_release
]

# launch_server is an alias for launch — both use the same
# shell_detached pattern now. Kept for tool compatibility.
fun launch_server(table, command, label) {
    launch(table, command, label)
}

fun init() {
    table = ets_new()
    ets_put(table, 'next_id', 0)
    table
}

# Path of the log file capturing stdout+stderr.
fun log_path_for(task_id) {
    "/tmp/swarm-code-" ++ task_id ++ ".log"
}

fun pid_file_for(task_id) {
    "/tmp/swarm-code-" ++ task_id ++ ".pid"
}

# Launch a command detached. Returns the task id string.
fun launch(table, command, label) {
    raw_id = ets_get(table, 'next_id')
    next_id = if (raw_id == nil) { 0 } else { raw_id }
    task_id = "bg-" ++ to_string(next_id)
    ets_put(table, 'next_id', next_id + 1)

    log_file = log_path_for(task_id)
    pid_file = pid_file_for(task_id)
    exit_file = "/tmp/swarm-code-" ++ task_id ++ ".exit"

    # The rm -f first is load-bearing: bg-N ids restart at 0 every
    # session and /tmp/swarm-code-bg-N.* files are never cleaned, so a
    # stale exit file from a previous session would instantly mark this
    # fresh task done (poll_and_notify and Flows both file_exists it).
    shell("rm -f " ++ exit_file ++ " " ++ pid_file ++ " " ++ log_file)

    # shell_detached double-forks + setsid()s a worker that runs
    # `( command ); echo $? > exit_file` under /bin/sh with stdin=/dev/null
    # and stdout+stderr→log_file, then returns the worker pid (== pgid,
    # since the worker leads its own session/process group). No sleep +
    # pid-file readback race any more — the runtime hands us the pid
    # synchronously off its internal pipe.
    pid = shell_detached(command, log_file, exit_file)
    if (pid == nil) {
        "error: failed to start background task"
    } else {
        # We own the pid file now (the runtime doesn't write it) so
        # kill_task and external readers can find the pgroup leader.
        file_write(pid_file, to_string(pid))
        started = timestamp()

        ets_put(table, task_id ++ "/status", 'pending')
        ets_put(table, task_id ++ "/cmd", command)
        ets_put(table, task_id ++ "/label", label)
        ets_put(table, task_id ++ "/log_file", log_file)
        ets_put(table, task_id ++ "/pid_file", pid_file)
        ets_put(table, task_id ++ "/exit_file", exit_file)
        ets_put(table, task_id ++ "/started", started)
        ets_put(table, task_id ++ "/pid", to_string(pid))

        # Stall-detector bookkeeping: seed log_grew_at at launch so the
        # 45s no-growth window is measured from the start of the task.
        ets_put(table, task_id ++ "/log_size", 0)
        ets_put(table, task_id ++ "/log_grew_at", started)
        task_id
    }
}

# Current status of a task.
fun status(table, task_id) {
    s = ets_get(table, task_id ++ "/status")
    if (s == nil) { 'unknown' } else { s }
}

# Human-formatted result, including log tail.
fun result(table, task_id) {
    s = status(table, task_id)
    if (s == 'unknown') {
        "error: unknown task id " ++ task_id
    } else {
        if (s == 'pending') {
            label = ets_get(table, task_id ++ "/label")
            "still running: " ++ to_string(label) ++
                "\n(use bg_tail to see partial output)"
        } else {
            exit_code = ets_get(table, task_id ++ "/exit")
            log_file = ets_get(table, task_id ++ "/log_file")
            tail = if (log_file == nil) { "" }
                   else {
                       r = shell("tail -n 40 " ++ Util.shell_q(to_string(log_file)) ++ " 2>&1")
                       elem(r, 1)
                   }
            "[" ++ to_string(s) ++ " · exit " ++ to_string(exit_code) ++ "]\n" ++
                to_string(tail)
        }
    }
}

# Tail a task's log (N lines).
# n_lines is validated upstream (Tools.do_bg_tail) to be a clean integer.
# Log path is internal (/tmp/swarm-code-bg-N.log) but quote anyway as
# belt-and-braces.
fun tail_log(table, task_id, n_lines) {
    log_file = ets_get(table, task_id ++ "/log_file")
    if (log_file == nil) {
        "error: task " ++ task_id ++ " has no log file"
    } else {
        cmd = "tail -n " ++ to_string(n_lines) ++ " " ++
              Util.shell_q(to_string(log_file)) ++ " 2>&1"
        r = shell(cmd)
        out = elem(r, 1)
        if (string_length(out) == 0) { "(log is empty)" } else { out }
    }
}

# Kill a task by its OS pid. Validates pid as digits-only before
# using it — pid_file lives in shared /tmp so a stray writer could
# otherwise feed junk here. pid_kill_group SIGTERMs the whole process
# group (the worker leads its own pgroup), so child processes the task
# forked die too, not just the /bin/sh wrapper.
fun kill_task(table, task_id) {
    pid_file = ets_get(table, task_id ++ "/pid_file")
    if (pid_file == nil) {
        "error: no pid file for " ++ task_id
    } else {
        pid_content = file_read(to_string(pid_file))
        if (pid_content == nil) {
            "error: could not read pid file"
        } else {
            pid = string_trim(pid_content)
            if (digits_only(pid) == 'false') {
                "error: refusing to kill — pid file has non-numeric content: " ++ pid
            } else {
                killed = pid_kill_group(parse_int_safe(pid))
                out = if (killed == 'true') { "killed" } else { "failed" }
                # Flip to 'killed' only if still 'pending' — if the poll loop
                # already recorded done/error (natural completion racing the
                # kill), the CAS no-ops rather than clobbering the real result.
                ets_cas(table, task_id ++ "/status", 'pending', 'killed')
                "pid " ++ pid ++ ": " ++ out
            }
        }
    }
}

fun digits_only(s) {
    if (string_length(s) == 0) { 'false' }
    else { digits_loop(s, 0) }
}

fun digits_loop(s, i) {
    if (i >= string_length(s)) { 'true' }
    else {
        ch = string_sub(s, i, 1)
        is_d = if (ch == "0") { 'true' }
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
        if (is_d == 'false') { 'false' }
        else { digits_loop(s, i + 1) }
    }
}

# List all tasks as a human string.
fun list_all(table) {
    raw_next = ets_get(table, 'next_id')
    next_id = if (raw_next == nil) { 0 } else { raw_next }
    if (next_id == 0) { "(no background tasks)" }
    else { list_loop(table, 0, next_id, "") }
}

fun list_loop(table, i, limit, acc) {
    if (i >= limit) { acc }
    else {
        task_id = "bg-" ++ to_string(i)
        s = status(table, task_id)
        label = ets_get(table, task_id ++ "/label")
        line = "  " ++ task_id ++ "  " ++ to_string(s) ++ "  " ++ to_string(label) ++ "\n"
        list_loop(table, i + 1, limit, acc ++ line)
    }
}

# ------------------------------------------------------------
# Watcher hook — called by the heartbeat on each tick
# ------------------------------------------------------------
# For every task still marked 'pending', check if its exit_file now
# exists (meaning the wrapper shell wrote the exit code). If so,
# mark the task done/error and send a {'bg_done', ...} message to
# main_agent. Returns the list of task ids that just flipped to done
# in this tick, for logging purposes.
fun poll_and_notify(table) {
    raw_next = ets_get(table, 'next_id')
    next_id = if (raw_next == nil) { 0 } else { raw_next }
    poll_loop(table, 0, next_id, [])
}

fun poll_loop(table, i, limit, acc) {
    if (i >= limit) { acc }
    else {
        task_id = "bg-" ++ to_string(i)
        # A task under an active foreground bash wait (fg_wait='true') owns its
        # own finalize + result — skip it entirely this tick so the heartbeat
        # can't win try_finalize's CAS and fire a spurious bg_done for a result
        # the foreground call is about to return itself. Such a task is also
        # <15s old, so it can't be 45s-stalled: skip check_stall too.
        fg = ets_get(table, task_id ++ "/fg_wait")
        new_acc = if (fg == 'true') { acc }
        else {
            # try_finalize does the exit_file check + CAS. `won` is 'true'
            # only for the caller that actually flipped 'pending' → done/error,
            # which is the caller that owns firing bg_done — exactly once, and
            # never for a task the foreground wait_for_task already claimed.
            res = try_finalize(table, task_id)
            st = elem(res, 0)
            won = elem(res, 1)
            if (won == 'true') {
                main_pid = whereis('main_agent')
                if (main_pid != nil) {
                    label_val = ets_get(table, task_id ++ "/label")
                    label_str = if (label_val == nil) { task_id }
                                else { to_string(label_val) }
                    exit_code = ets_get(table, task_id ++ "/exit")
                    send(main_pid, {'bg_done', task_id, exit_code, label_str})
                }
                list_append(acc, task_id)
            } else {
                # Still running → run the stall detector (fires bg_stalled at
                # most once if the task looks wedged on an interactive prompt).
                if (st == 'pending') { check_stall(table, task_id) }
                acc
            }
        }
        poll_loop(table, i + 1, limit, new_acc)
    }
}

# ------------------------------------------------------------
# Shared finalize (the single source of truth for done/error state)
# ------------------------------------------------------------
# Returns {status, won}. If the task is already non-pending, returns
# its status with won='false'. If it is pending and its exit_file has
# appeared, reads the exit code and CASes 'pending' → 'done'/'error';
# the caller that wins the CAS gets won='true' (and owns bg_done),
# everyone else gets won='false'. The CAS is what guarantees no
# double-finalize: a concurrent bg_kill that flipped 'pending' → 'killed'
# makes the CAS fail so we never resurrect the task or fire a spurious
# bg_done, and the foreground wait and the heartbeat can't both notify.
#
# The '{id}/exit' and '{id}/ended' keys are written BEFORE the CAS so a
# reader that ever observes status 'done'/'error' can never read exit==nil.
# If the CAS then loses (bg_kill claimed 'pending' → 'killed' first) those
# writes are harmless — a killed task's exit key is ignored.
#
# Zombie fallback: a worker that was SIGKILLed or failed to exec never writes
# exit_file, so without this the task stays 'pending' forever. When exit_file
# is absent but the pid is gone (and the task has had >=2s to fork+exec, so a
# just-launched worker between fork and exec isn't misread), finalize it as an
# error with exit -1 via the same write-then-CAS path.
fun try_finalize(table, task_id) {
    s = status(table, task_id)
    if (s != 'pending') {
        {s, 'false'}
    } else {
        exit_file = ets_get(table, task_id ++ "/exit_file")
        if (exit_file != nil && file_exists(to_string(exit_file)) == 'true') {
            exit_content = file_read(to_string(exit_file))
            exit_code = if (exit_content == nil) { -1 }
                        else { parse_int_safe(string_trim(exit_content)) }
            final_status = if (exit_code == 0) { 'done' } else { 'error' }
            ets_put(table, task_id ++ "/exit", exit_code)
            ets_put(table, task_id ++ "/ended", timestamp())
            won = ets_cas(table, task_id ++ "/status", 'pending', final_status)
            if (won == 'true') {
                {final_status, 'true'}
            } else {
                # Lost the race — report whatever the winner recorded.
                {status(table, task_id), 'false'}
            }
        } else {
            pid_str = ets_get(table, task_id ++ "/pid")
            started = ets_get(table, task_id ++ "/started")
            grace_ok = started != nil && timestamp() - started >= 2000
            dead = pid_str != nil && digits_only(to_string(pid_str)) == 'true' &&
                   pid_alive(parse_int_safe(to_string(pid_str))) == 'false'
            if (grace_ok == 'true' && dead == 'true') {
                ets_put(table, task_id ++ "/exit", -1)
                ets_put(table, task_id ++ "/ended", timestamp())
                won = ets_cas(table, task_id ++ "/status", 'pending', 'error')
                if (won == 'true') {
                    {'error', 'true'}
                } else {
                    {status(table, task_id), 'false'}
                }
            } else {
                {'pending', 'false'}
            }
        }
    }
}

# Finalize a task without notifying main_agent — used by the foreground
# wait_for_task so it can claim a just-finished task's result without
# the heartbeat also firing a bg_done for it. Returns the resolved
# status ('done'|'error'|'killed'|'pending'|'unknown').
fun finalize_if_done(table, task_id) {
    elem(try_finalize(table, task_id), 0)
}

# fg_claim / fg_release — a foreground bash wait (Tools.bash_auto_bg) marks a
# task 'claimed' so the heartbeat's poll_loop skips finalizing it: the
# foreground call owns the result and must be the only one to report it. On
# EVERY exit from that wait — backgrounded (hand off to the heartbeat), done,
# error, or ESC-kill — the claim is released so ETS state doesn't lie (a
# finalized task is no longer 'pending' so poll_loop skips it anyway; release
# is hygiene). fg_release is a no-op when the key was never set.
fun fg_claim(table, task_id) {
    ets_put(table, task_id ++ "/fg_wait", 'true')
}

fun fg_release(table, task_id) {
    ets_delete(table, task_id ++ "/fg_wait")
}

# Block up to budget_ms for a task to leave 'pending', finalizing it
# ourselves (no bg_done) each round. Returns as soon as the task is
# not pending, or 'pending' if the budget is exhausted first. Deadline
# is carried as an arg so wait_loop is a pure self-tail-recursive loop
# (mutual recursion isn't TCO'd; self-recursion is).
fun wait_for_task(table, task_id, budget_ms) {
    deadline = timestamp() + budget_ms
    wait_loop(table, task_id, deadline)
}

fun wait_loop(table, task_id, deadline) {
    st = finalize_if_done(table, task_id)
    if (st != 'pending') { st }
    else {
        if (timestamp() >= deadline) { 'pending' }
        else {
            sleep(200)
            wait_loop(table, task_id, deadline)
        }
    }
}

# ------------------------------------------------------------
# Stall detector — surfaces tasks wedged on an interactive prompt
# ------------------------------------------------------------
# Called once per heartbeat tick for each still-pending task. Tracks
# the log's byte size and the last time it grew. If the log hasn't
# grown for >=45s AND its tail looks like an interactive prompt
# (waiting on stdin, which is /dev/null → it will hang forever), send
# one {'bg_stalled', task_id, label, tail} to main_agent. Fires at most
# once per task (guarded by '{id}/stalled_sent').
fun check_stall(table, task_id) {
    log_file = ets_get(table, task_id ++ "/log_file")
    if (log_file == nil) { nil }
    else {
        wc = shell("wc -c < " ++ Util.shell_q(to_string(log_file)) ++ " 2>/dev/null")
        cur_size = parse_int_safe(string_trim(elem(wc, 1)))
        prev_size = ets_get(table, task_id ++ "/log_size")
        if (prev_size == nil || cur_size != prev_size) {
            # Log grew (or first observation) → reset the stall clock.
            ets_put(table, task_id ++ "/log_size", cur_size)
            ets_put(table, task_id ++ "/log_grew_at", timestamp())
        } else {
            stalled_sent = ets_get(table, task_id ++ "/stalled_sent")
            grew_at = ets_get(table, task_id ++ "/log_grew_at")
            if (stalled_sent == nil && grew_at != nil &&
                timestamp() - grew_at >= 45000) {
                maybe_send_stall(table, task_id, to_string(log_file))
            } else { nil }
        }
    }
}

fun maybe_send_stall(table, task_id, log_file) {
    tr = shell("tail -c 200 " ++ Util.shell_q(log_file) ++ " 2>/dev/null")
    tail = to_string(elem(tr, 1))
    if (looks_interactive(tail) == 'true') {
        main_pid = whereis('main_agent')
        if (main_pid != nil) {
            label_val = ets_get(table, task_id ++ "/label")
            label_str = if (label_val == nil) { task_id }
                        else { to_string(label_val) }
            send(main_pid, {'bg_stalled', task_id, label_str, tail})
        }
        # Mark sent even if main_agent is gone — we don't want to keep
        # re-scanning; a prompt won't un-prompt itself.
        ets_put(table, task_id ++ "/stalled_sent", 'true')
    } else { nil }
}

# Heuristic: does this log tail look like it's blocked on stdin? Prompt
# suffixes ("$ "/"> "/"# ") or common confirmation/password strings. The bare
# ": " suffix was dropped — it's too broad (long-silent compiler output often
# ends that way), causing false stall alerts on healthy long builds.
# string_ends_with / string_contains return ATOMS 'true'/'false'.
fun looks_interactive(tail) {
    if (string_ends_with(tail, "$ ") == 'true') { 'true' }
    else { if (string_ends_with(tail, "> ") == 'true') { 'true' }
    else { if (string_ends_with(tail, "# ") == 'true') { 'true' }
    else { if (string_contains(tail, "(y/n)") == 'true') { 'true' }
    else { if (string_contains(tail, "[Y/n]") == 'true') { 'true' }
    else { if (string_contains(tail, "password") == 'true') { 'true' }
    else { if (string_contains(tail, "Password") == 'true') { 'true' }
    else { 'false' }}}}}}}
}

# Simple int parser — the file contains just a number with a newline.
fun parse_int_safe(s) {
    parse_int_digits(s, 0, 0)
}

fun parse_int_digits(s, i, acc) {
    if (i >= string_length(s)) { acc }
    else {
        ch = string_sub(s, i, 1)
        d = if (ch == "0") { 0 }
            else { if (ch == "1") { 1 }
            else { if (ch == "2") { 2 }
            else { if (ch == "3") { 3 }
            else { if (ch == "4") { 4 }
            else { if (ch == "5") { 5 }
            else { if (ch == "6") { 6 }
            else { if (ch == "7") { 7 }
            else { if (ch == "8") { 8 }
            else { if (ch == "9") { 9 }
            else { 0 - 1 }}}}}}}}}}
        if (d < 0) { acc }
        else { parse_int_digits(s, i + 1, acc * 10 + d) }
    }
}

fun all_pending_ids(table) {
    raw_next = ets_get(table, 'next_id')
    next_id = if (raw_next == nil) { 0 } else { raw_next }
    pending_loop(table, 0, next_id, [])
}

fun pending_loop(table, i, limit, acc) {
    if (i >= limit) { acc }
    else {
        task_id = "bg-" ++ to_string(i)
        s = status(table, task_id)
        new_acc = if (s == 'pending') { list_append(acc, task_id) } else { acc }
        pending_loop(table, i + 1, limit, new_acc)
    }
}
