module Scheduler

# ============================================================
# Scheduler — interval-based recurring agent runs
# ============================================================
#
# Layout on disk:
#
#   ~/.swarm-code/schedule.json    JSON array of jobs
#     [
#       {
#         "id": "1",
#         "expr": "1h",                # interval or daily HH:MM
#         "prompt": "review open PRs",
#         "created_at": 1779635000,
#         "last_run": 0,
#         "runs": 0
#       },
#       ...
#     ]
#
# Supported expressions (kept tiny on purpose — extend later):
#
#   30s, 5m, 2h, 1d     interval (seconds, minutes, hours, days)
#   daily HH:MM         fire once per day at the given UTC time
#   hourly              every hour on the hour (alias for 1h)
#
# Dispatcher: hooked off the Heartbeat. Every N ticks the heartbeat
# calls Scheduler.tick(opts), which walks jobs, computes "is this due
# now?", and shells out `swarm-code -p "<prompt>"` in the background
# for any matches. Successful dispatch updates last_run + runs.
#
# Jobs are fire-and-forget. Output goes to ~/.swarm-code/telemetry/
# scheduled-<id>-<ts>.out so the user can `tail` later.

export [
    load, add, remove, list_all, tick,
    schedule_path, jobs_dir
]

fun schedule_path() { getenv("HOME") ++ "/.swarm-code/schedule.json" }
fun jobs_dir()      { getenv("HOME") ++ "/.swarm-code/telemetry" }

fun load() {
    file_mkdir(getenv("HOME") ++ "/.swarm-code")
    file_mkdir(jobs_dir())
    'scheduler_ready'
}

# ------------------------------------------------------------
# Read jobs from disk. Returns [] if file missing/unparseable.
# ------------------------------------------------------------
fun list_all() {
    p = schedule_path()
    if (file_exists(p) == 'false') { [] }
    else {
        c = file_read(p)
        if (c == nil) { [] }
        else {
            decoded = json_decode(string_trim(c))
            if (decoded == nil) { [] } else { decoded }
        }
    }
}

fun save_all(jobs) {
    file_write(schedule_path(), json_encode(jobs))
    'ok'
}

# ------------------------------------------------------------
# Add a new job. Returns the assigned id (string). expr must
# parse via parse_expr/1; otherwise returns nil.
# ------------------------------------------------------------
fun add(expr, prompt) {
    if (parse_expr(string_trim(to_string(expr))) == nil) { nil }
    else {
        jobs = list_all()
        id = to_string(next_id(jobs, 0))
        job = %{
            id: id,
            expr: to_string(expr),
            prompt: to_string(prompt),
            created_at: timestamp(),
            last_run: 0,
            runs: 0
        }
        save_all(list_append(jobs, job))
        id
    }
}

fun next_id(jobs, max_so_far) {
    if (length(jobs) == 0) { max_so_far + 1 }
    else {
        j = hd(jobs)
        v = to_string(map_get(j, 'id'))
        n = parse_int_simple(v)
        new_max = if (n > max_so_far) { n } else { max_so_far }
        next_id(tl(jobs), new_max)
    }
}

fun remove(id) {
    target = to_string(id)
    jobs = list_all()
    kept = remove_loop(jobs, target, [])
    if (length(kept) == length(jobs)) { 'false' }
    else { save_all(kept) ; 'true' }
}

fun remove_loop(jobs, target, acc) {
    if (length(jobs) == 0) { acc }
    else {
        j = hd(jobs)
        new_acc = if (to_string(map_get(j, 'id')) == target) { acc }
                  else { list_append(acc, j) }
        remove_loop(tl(jobs), target, new_acc)
    }
}

# ------------------------------------------------------------
# Tick — called from Heartbeat. Walks jobs, dispatches any due.
# `now` is a unix epoch in seconds.
# ------------------------------------------------------------
fun tick(opts) {
    jobs = list_all()
    if (length(jobs) == 0) { 'noop' }
    else {
        now = timestamp()
        updated = tick_loop(jobs, now, [])
        if (length(updated) > 0) { save_all(updated) }
        'ok'
    }
}

fun tick_loop(jobs, now, acc) {
    if (length(jobs) == 0) { acc }
    else {
        j = hd(jobs)
        new_j = maybe_fire(j, now)
        tick_loop(tl(jobs), now, list_append(acc, new_j))
    }
}

fun maybe_fire(job, now) {
    expr = to_string(map_get(job, 'expr'))
    last = map_get(job, 'last_run')
    last_run = if (last == nil) { 0 } else { last }
    next_fire = compute_next_fire(expr, last_run)
    if (next_fire == nil || next_fire > now) { job }
    else {
        dispatch(job)
        runs = map_get(job, 'runs')
        new_runs = if (runs == nil) { 1 } else { runs + 1 }
        map_put(map_put(job, 'last_run', now), 'runs', new_runs)
    }
}

# Compute the next fire time given an expression and the prior run's
# epoch second. Returns nil for unparseable expressions.
fun compute_next_fire(expr, last_run) {
    secs = parse_expr(expr)
    if (secs == nil) { nil }
    else { last_run + secs }
}

# parse_expr — return the interval in seconds (number) for supported
# expression forms. Currently only intervals; daily HH:MM falls back
# to "24h since last run" which is close enough for most use cases.
fun parse_expr(s) {
    trimmed = string_trim(s)
    if (string_length(trimmed) == 0) { nil }
    else { if (trimmed == "hourly") { 3600 }
    else { if (trimmed == "daily") { 86400 }
    else { if (string_starts_with(trimmed, "daily ") == 'true') { 86400 }
    else { parse_interval(trimmed) }}}}
}

# parse_interval — `30s`, `5m`, `2h`, `1d` → seconds.
fun parse_interval(s) {
    n = string_length(s)
    if (n < 2) { nil }
    else {
        suffix = string_sub(s, n - 1, 1)
        num_str = string_sub(s, 0, n - 1)
        num = parse_int_simple(num_str)
        if (num <= 0) { nil }
        else {
            if (suffix == "s") { num }
            else { if (suffix == "m") { num * 60 }
            else { if (suffix == "h") { num * 3600 }
            else { if (suffix == "d") { num * 86400 }
            else { nil }}}}
        }
    }
}

# ------------------------------------------------------------
# Dispatch a job — spawn `swarm-code -p "<prompt>"` in the background,
# output to ~/.swarm-code/telemetry/scheduled-<id>-<ts>.out. Doesn't
# block the agent loop; we never wait on the child.
# ------------------------------------------------------------
fun dispatch(job) {
    id = to_string(map_get(job, 'id'))
    prompt = to_string(map_get(job, 'prompt'))
    ts = to_string(timestamp())
    out_path = jobs_dir() ++ "/scheduled-" ++ id ++ "-" ++ ts ++ ".out"
    bin = swarm_binary_path()
    # nohup + & detaches; redirect stdout+stderr to the per-run file.
    cmd =
        "nohup " ++ shell_q(bin) ++ " -p " ++ shell_q(prompt) ++
        " > " ++ shell_q(out_path) ++ " 2>&1 &"
    shell(cmd)
    'dispatched'
}

# Resolve the swarm-code binary. SWARM_CODE_BIN env override wins,
# else fall back to the canonical install path.
fun swarm_binary_path() {
    env_bin = getenv("SWARM_CODE_BIN")
    if (env_bin != nil && string_length(env_bin) > 0) { env_bin }
    else { "/Users/sky/swarm-code/bin/swarm-code" }
}

fun shell_q(s) { "'" ++ string_replace(s, "'", "'\\''") ++ "'" }

# Minimal int parser — borrowed from main.sw. Returns 0 on garbage,
# which causes parse_interval to reject (we require > 0).
fun parse_int_simple(s) { parse_int_loop(s, 0, 0) }

fun parse_int_loop(s, i, acc) {
    if (i >= string_length(s)) { acc }
    else {
        ch = string_sub(s, i, 1)
        d = if (ch == "0") { 0 } else { if (ch == "1") { 1 }
            else { if (ch == "2") { 2 } else { if (ch == "3") { 3 }
            else { if (ch == "4") { 4 } else { if (ch == "5") { 5 }
            else { if (ch == "6") { 6 } else { if (ch == "7") { 7 }
            else { if (ch == "8") { 8 } else { if (ch == "9") { 9 }
            else { 0 - 1 }}}}}}}}}}
        if (d < 0) { acc } else { parse_int_loop(s, i + 1, acc * 10 + d) }
    }
}
