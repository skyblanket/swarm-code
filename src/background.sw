module Background

import Util

# ============================================================
# Background — async shell tasks (OS-detached, heartbeat-monitored)
# ============================================================
#
# background(command, label) starts a shell command as an OS-detached
# process (nohup + disown) and returns immediately with a task id. The
# main agent keeps responding to the user; the heartbeat process polls
# running tasks on each tick and pushes {'bg_done', ...} messages to
# main_agent as soon as any task finishes.
#
# Why OS-level instead of sw-level spawn? sw_spawn from within a
# running scheduler thread queues the new process on the SAME thread,
# which doesn't always get scheduled reliably mid-turn. nohup gives
# us a real OS process that runs on its own, completely independent
# of the sw scheduler.
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
#   'next_id'        → counter

export [
    init, launch, launch_server, status, result, list_all,
    log_path_for, tail_log, kill_task,
    poll_and_notify, all_pending_ids
]

# launch_server is an alias for launch — both use the same
# nohup+disown pattern now. Kept for tool compatibility.
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

    # nohup + disown + save pid + capture exit code.
    # The wrapper shell runs the command, then writes its exit code to
    # exit_file. disown detaches it so swarm-code can exit freely.
    exit_file = "/tmp/swarm-code-" ++ task_id ++ ".exit"
    wrapped = "(" ++ command ++ "); echo $? > " ++ exit_file
    detach_cmd =
        "nohup sh -c " ++ Util.shell_q(wrapped) ++
        " > " ++ log_file ++ " 2>&1 & " ++
        "echo $! > " ++ pid_file ++ "; " ++
        "disown"
    shell(detach_cmd)

    ets_put(table, task_id ++ "/status", 'pending')
    ets_put(table, task_id ++ "/cmd", command)
    ets_put(table, task_id ++ "/label", label)
    ets_put(table, task_id ++ "/log_file", log_file)
    ets_put(table, task_id ++ "/pid_file", pid_file)
    ets_put(table, task_id ++ "/exit_file", exit_file)
    ets_put(table, task_id ++ "/started", timestamp())

    # Read the pid back (tiny race but ok — nohup already started it)
    sleep(20)
    pid_content = file_read(pid_file)
    pid = if (pid_content == nil) { "?" } else { string_trim(pid_content) }
    ets_put(table, task_id ++ "/pid", pid)
    task_id
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
# splicing into `kill` — pid_file lives in shared /tmp so an attacker
# (or a stray writer) could otherwise feed shell payload here.
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
                r = shell("kill " ++ pid ++ " 2>&1 && echo killed || echo failed")
                out = string_trim(elem(r, 1))
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
        s = status(table, task_id)
        if (s == 'pending') {
            exit_file = ets_get(table, task_id ++ "/exit_file")
            if (exit_file != nil && file_exists(to_string(exit_file)) == 'true') {
                # Task finished. Read exit code, flip state, notify main.
                exit_content = file_read(to_string(exit_file))
                exit_code = if (exit_content == nil) { -1 }
                            else {
                                trimmed = string_trim(exit_content)
                                parse_int_safe(trimmed)
                            }
                final_status = if (exit_code == 0) { 'done' } else { 'error' }
                # Compare-and-swap from 'pending': if a concurrent bg_kill
                # already flipped this to 'killed' (the status read above is
                # not atomic with this write), the CAS fails and we DON'T
                # resurrect the task as done/error or fire a spurious bg_done.
                won = ets_cas(table, task_id ++ "/status", 'pending', final_status)
                if (won == 'true') {
                    ets_put(table, task_id ++ "/exit", exit_code)
                    ets_put(table, task_id ++ "/ended", timestamp())
                    main_pid = whereis('main_agent')
                    if (main_pid != nil) {
                        label_val = ets_get(table, task_id ++ "/label")
                        label_str = if (label_val == nil) { task_id }
                                    else { to_string(label_val) }
                        send(main_pid, {'bg_done', task_id, exit_code, label_str})
                    }
                    poll_loop(table, i + 1, limit, list_append(acc, task_id))
                } else {
                    poll_loop(table, i + 1, limit, acc)
                }
            } else {
                poll_loop(table, i + 1, limit, acc)
            }
        } else {
            poll_loop(table, i + 1, limit, acc)
        }
    }
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
