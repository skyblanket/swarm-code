module Scheduler

import Util

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
#         "created_at": 1779635000000, # ms since epoch
#         "last_run": 0,
#         "runs": 0
#       },
#       ...
#     ]
#
# Supported expressions (all interpreted internally as milliseconds
# because timestamp() — and therefore every comparison here — is ms):
#
#   30s, 5m, 2h, 1d     interval
#   daily HH:MM         fire once per day at the given UTC time
#   hourly              every hour on the hour (alias for 1h)
#   daily               every 24h (alias for 1d)
#
# Dispatcher: hooked off the Heartbeat. Every tick the heartbeat
# calls Scheduler.tick(opts), which walks jobs, computes "is this due
# now?", and shells out `swarm-code -p "<prompt>"` in the background
# for any matches. Successful dispatch updates last_run + runs and
# schedule.json gets rewritten — but only when a job actually fired,
# so quiet ticks don't thrash the disk.
#
# Jobs are fire-and-forget. Output goes to ~/.swarm-code/telemetry/
# scheduled-<id>-<ts>.out so the user can `tail` later.

export [
    load, add, remove, list_all, tick,
    schedule_path, jobs_dir,
    parse_expr, parse_interval, daily_time_ms, compute_next_fire,
    swarm_binary_path, prune_old_out_files
]

fun schedule_path() { getenv("HOME") ++ "/.swarm-code/schedule.json" }
fun jobs_dir()      { getenv("HOME") ++ "/.swarm-code/telemetry" }

fun load() {
    home = getenv("HOME")
    if (home == nil) { 'scheduler_skipped' }
    else {
        file_mkdir(home ++ "/.swarm-code")
        file_mkdir(jobs_dir())
        'scheduler_ready'
    }
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
# Add a new job. Returns the assigned id (string), or nil if expr
# doesn't parse.
# ------------------------------------------------------------
fun add(expr, prompt) {
    expr_str = string_trim(to_string(expr))
    # Validate: either a known interval OR a daily HH:MM form.
    if (parse_expr(expr_str) == nil && daily_time_ms(expr_str) == nil) { nil }
    else {
        jobs = list_all()
        id = to_string(next_id(jobs, 0))
        job = %{
            id: id,
            expr: expr_str,
            prompt: to_string(prompt),
            created_at: timestamp(),
            # Seed last_run to NOW, not 0. With 0 (epoch), compute_next_fire
            # returns a 1970 timestamp that is always < now, so the next 2s
            # heartbeat fires the job immediately on creation (and a past-slot
            # daily HH:MM fires right away) instead of after one interval.
            last_run: timestamp(),
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
# Only writes schedule.json back to disk when at least one job
# actually fired (the dirty-flag gate). Previously this rewrote on
# every tick because tick_loop always rebuilt a same-length list.
# ------------------------------------------------------------
fun tick(opts) {
    jobs = list_all()
    if (length(jobs) == 0) { 'noop' }
    else {
        now = timestamp()
        r = tick_loop(jobs, now, [], 'false')
        updated = elem(r, 0)
        dirty = elem(r, 1)
        if (dirty == 'true') { save_all(updated) }
        # Prune .out files older than 7 days so output doesn't accumulate unbounded.
        prune_old_out_files()
        'ok'
    }
}

fun tick_loop(jobs, now, acc, dirty) {
    if (length(jobs) == 0) { {acc, dirty} }
    else {
        result = maybe_fire(hd(jobs), now)
        new_job = elem(result, 0)
        fired = elem(result, 1)
        new_dirty = if (fired == 'true') { 'true' } else { dirty }
        tick_loop(tl(jobs), now, list_append(acc, new_job), new_dirty)
    }
}

# maybe_fire returns {job, fired_atom} so tick_loop can track whether
# anything actually changed. When no fire: returns the input job
# unchanged (no mutation). When fire: dispatches and returns a new
# job with last_run + runs bumped.
fun maybe_fire(job, now) {
    expr = to_string(map_get(job, 'expr'))
    last_run = map_get(job, 'last_run', 0)
    next_fire = compute_next_fire(expr, last_run, now)
    if (next_fire == nil || next_fire > now) { {job, 'false'} }
    else {
        dispatch(job)
        runs = map_get(job, 'runs')
        new_runs = if (runs == nil) { 1 } else { runs + 1 }
        new_job = map_put(map_put(job, 'last_run', now), 'runs', new_runs)
        {new_job, 'true'}
    }
}

# ------------------------------------------------------------
# compute_next_fire — when (in ms-since-epoch) the next fire is
# scheduled for, given the expression and the prior fire's epoch ms.
# Two semantics:
#   * "daily HH:MM" — wallclock. Compute today's HH:MM slot in UTC.
#     If that's already past last_run, fire then. Otherwise wait
#     for tomorrow's slot.
#   * intervals (30s/5m/2h/1d/hourly/daily) — last_run + interval_ms.
# Returns nil if the expression is unparseable.
# ------------------------------------------------------------
fun compute_next_fire(expr, last_run, now) {
    daily_ms_offset = daily_time_ms(expr)
    if (daily_ms_offset != nil) {
        day_ms = 86400000
        today_midnight = (now / day_ms) * day_ms
        today_slot = today_midnight + daily_ms_offset
        # If today's slot still hasn't fired this scheduling cycle,
        # aim for it; otherwise schedule tomorrow's.
        if (today_slot > last_run) { today_slot }
        else { today_slot + day_ms }
    }
    else {
        interval_ms = parse_expr(expr)
        if (interval_ms == nil) { nil }
        else { last_run + interval_ms }
    }
}

# parse_expr — return the interval in MILLISECONDS for supported
# expression forms. Returns nil for unparseable, including the
# "daily HH:MM" form (callers route those through daily_time_ms +
# compute_next_fire's wallclock branch). "daily" alone is the 24h
# interval; "daily HH:MM" returns 86400000 here too so add()'s
# validation accepts both shapes uniformly.
fun parse_expr(s) {
    trimmed = string_trim(s)
    if (string_length(trimmed) == 0) { nil }
    else { if (trimmed == "hourly") { 3600000 }
    else { if (trimmed == "daily") { 86400000 }
    else { if (daily_time_ms(trimmed) != nil) { 86400000 }
    else { parse_interval(trimmed) }}}}
}

# parse_interval — `30s`, `5m`, `2h`, `1d` → MILLISECONDS.
# Previously this returned seconds, which silently mismatched
# timestamp()'s ms units and made every interval fire ~3.6 seconds
# after creation (with back-pressure masking it). Fixed: ms throughout.
fun parse_interval(s) {
    n = string_length(s)
    if (n < 2) { nil }
    else {
        suffix = string_sub(s, n - 1, 1)
        num_str = string_sub(s, 0, n - 1)
        num = parse_int_simple(num_str)
        if (num <= 0) { nil }
        else {
            if (suffix == "s") { num * 1000 }
            else { if (suffix == "m") { num * 60000 }
            else { if (suffix == "h") { num * 3600000 }
            else { if (suffix == "d") { num * 86400000 }
            else { nil }}}}
        }
    }
}

# daily_time_ms — parse "daily HH:MM" → ms since midnight, or nil
# if the expression isn't a daily-with-time form. Used by
# compute_next_fire to schedule wallclock-aligned fires.
fun daily_time_ms(s) {
    if (string_starts_with(s, "daily ") == 'false') { nil }
    else {
        time_part = string_trim(string_sub(s, 6, string_length(s) - 6))
        parts = string_split(time_part, ":")
        if (length(parts) != 2) { nil }
        else {
            h_str = string_trim(hd(parts))
            m_str = string_trim(hd(tl(parts)))
            h = parse_int_simple(h_str)
            m = parse_int_simple(m_str)
            if (h < 0 || h > 23 || m < 0 || m > 59) { nil }
            else { (h * 3600 + m * 60) * 1000 }
        }
    }
}

# ------------------------------------------------------------
# Dispatch a job — spawn `swarm-code -p "<prompt>"` in the background.
# Output to ~/.swarm-code/telemetry/scheduled-<id>-<ts>.out. Doesn't
# block the agent loop; we never wait on the child.
#
# Two safety rules baked in:
#   1. ALWAYS pass --no-resume so cron children never inherit the
#      parent's .active journal (a polluted history would loop them
#      indefinitely on tool calls).
#   2. Per-job back-pressure via a pidfile — if the previous fire's
#      child is still alive, skip this fire instead of piling another
#      on top ("swarm-bomb").
# ------------------------------------------------------------
fun dispatch(job) {
    id = to_string(map_get(job, 'id'))
    pid_file = jobs_dir() ++ "/scheduled-" ++ id ++ ".pid"
    if (previous_fire_alive(pid_file) == 'true') { 'skipped_busy' }
    else {
        prompt = to_string(map_get(job, 'prompt'))
        ts = to_string(timestamp())
        out_path = jobs_dir() ++ "/scheduled-" ++ id ++ "-" ++ ts ++ ".out"
        bin = swarm_binary_path()
        inner =
            "nohup " ++ Util.shell_q(bin) ++ " --no-resume -p " ++ Util.shell_q(prompt) ++
            " > " ++ Util.shell_q(out_path) ++ " 2>&1 & echo $! > " ++ Util.shell_q(pid_file)
        shell("bash -c " ++ Util.shell_q(inner))
        'dispatched'
    }
}

# Has the previous fire's child exited? Cheap kill(pid, 0) check via
# the pid_alive builtin — no shell() overhead. Returns 'true' if the
# previous child is still alive (so we should back off), 'false'
# otherwise (no pidfile, parse fail, or process gone).
fun previous_fire_alive(pid_file) {
    if (file_exists(pid_file) == 'false') { 'false' }
    else {
        pid_content = file_read(pid_file)
        if (pid_content == nil) { 'false' }
        else {
            pid_str = string_trim(to_string(pid_content))
            if (string_length(pid_str) == 0) { 'false' }
            else { pid_alive(pid_str) }
        }
    }
}

# ------------------------------------------------------------
# prune_old_out_files — delete .out files from jobs_dir() that are
# older than 7 days. Called from tick() once per scheduler cycle so
# scheduled-job output doesn't accumulate unbounded. Uses `find` with
# -mtime +6 (modified more than 6*24h ago, i.e. >= 7 days old).
# Silently skips if the dir doesn't exist or find fails.
# ------------------------------------------------------------
fun prune_old_out_files() {
    dir = jobs_dir()
    if (file_exists(dir) == 'false') { 'skipped' }
    else {
        cmd = "find " ++ Util.shell_q(dir) ++
              " -maxdepth 1 -name 'scheduled-*.out' -mtime +6 -delete 2>/dev/null; true"
        shell(cmd)
        'pruned'
    }
}

# Resolve the swarm-code binary path. Tried in order:
#   1. SWARM_CODE_BIN env override (operator escape hatch).
#   2. os_args()[0] if it's an absolute-ish path that still exists.
#      This catches the canonical case: cron children inherit
#      the same binary path the parent agent was invoked with.
#   3. ~/.local/bin/swarm — installer default.
#   4. `command -v swarm` / `command -v swarm-code` — PATH lookup
#      (one shell() call with a ~1s poll, only on miss).
#   5. Last resort: "swarm" — relies on the child shell's PATH.
#
# Previously this hardcoded /Users/sky/swarm-code/bin/swarm-code as
# the fallback, which broke any non-Sky install.
fun swarm_binary_path() {
    env_bin = getenv("SWARM_CODE_BIN")
    if (env_bin != nil && string_length(env_bin) > 0) { env_bin }
    else {
        args = os_args()
        a0 = if (length(args) == 0) { "" } else { to_string(hd(args)) }
        if (string_length(a0) > 0
            && string_contains(a0, "/") == 'true'
            && file_exists(a0) == 'true') { a0 }
        else {
            home = getenv("HOME")
            local = if (home == nil) { "" } else { home ++ "/.local/bin/swarm" }
            if (string_length(local) > 0 && file_exists(local) == 'true') { local }
            else {
                r = shell("command -v swarm 2>/dev/null || command -v swarm-code 2>/dev/null")
                which_path = string_trim(elem(r, 1))
                if (string_length(which_path) > 0) { which_path }
                else { "swarm" }
            }
        }
    }
}

# Minimal int parser — returns 0 on garbage. parse_interval / next_id
# treat 0 as rejection, so a bad expression like "abch" is caught
# upstream via the num <= 0 guard.
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
