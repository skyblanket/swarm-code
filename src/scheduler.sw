module Scheduler

import Util
import JsonCheck

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
#         "runs": 0,
#         "paused": false
#       },
#       ...
#     ]
#
# Supported expressions (all interpreted internally as milliseconds
# because timestamp() — and therefore every comparison here — is ms):
#
#   30s, 5m, 2h, 1d     interval — a whole positive count + one unit
#                       (strict: "1.5h", "10x5m", "5 m", "-1h" are rejected)
#   daily HH:MM         fire once per day at the given UTC time
#                       (H or HH, exactly MM: "daily 9:05", "daily 23:59")
#   hourly              at the top of every hour (UTC wallclock, :00) —
#                       NOT "60 minutes after creation"; use 1h for that
#   daily               every 24h (alias for 1d)
#
# Robustness: schedule.json is hand-editable, so every read validates.
# The file must hold a JSON array; entries that are not objects, or
# whose id / expr / prompt / numeric fields don't validate, are SKIPPED
# (left untouched on disk) with a one-time warning — a bad entry never
# panics main's heartbeat handler. A file that exists but does not
# parse as an array is never overwritten: /schedule refuses to write
# instead of silently replacing every job. Writes go through
# file_atomic_write (temp file + rename), so a crash mid-write can't
# truncate the schedule.
#
# Dispatched children run with SWARM_CODE_DENY_DANGEROUS=1 (like
# /flows): a headless child otherwise auto-approves every 'ask', and a
# job firing unattended must not auto-run dangerous bash.
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
    load, add, add_checked, remove, list_all, tick,
    schedule_path, jobs_dir,
    parse_expr, parse_interval, daily_time_ms, compute_next_fire,
    expr_error, read_state_at, normalize_job, add_at, tick_at, dispatch_cmd,
    swarm_binary_path, prune_old_out_files,
    pause_job, resume_job
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
# Reading schedule.json
# ------------------------------------------------------------
# read_state_at(path) → {'ok', raw_entries} | {'corrupt', why}
#   missing or blank file          → {'ok', []}
#   unreadable / not JSON / not an array → {'corrupt', why}
# "Not JSON" is decided by the STRICT JsonCheck.valid, not by
# json_decode returning nil: the runtime decoder guesses its way
# through damage ("[{…} ,,, oops" decodes to a list padded with nils),
# and rewriting such a guess would destroy the jobs it mangled.
# The raw entries are returned UNVALIDATED so writers can round-trip
# entries they don't understand instead of dropping them; readers go
# through list_all() / normalize_job.
fun read_state_at(p) {
    if (file_exists(p) == 'false') { {'ok', []} }
    else {
        c = file_read(p)
        if (c == nil) { {'corrupt', "could not be read"} }
        else {
            trimmed = string_trim(c)
            if (string_length(trimmed) == 0) { {'ok', []} }
            else { if (JsonCheck.valid(trimmed) == 'false') { {'corrupt', "is not valid JSON"} }
            else {
                decoded = json_decode(trimmed)
                if (decoded == nil) { {'corrupt', "is not valid JSON"} }
                else { if (is_list(decoded) == 'false') {
                    {'corrupt', "must be a JSON array of jobs (found " ++ typeof(decoded) ++ ")"}
                } else { {'ok', decoded} }}
            }}
        }
    }
}

# Every valid, normalized job (invalid entries skipped). [] when the
# file is missing or corrupt — readers never see a non-list.
fun list_all() { valid_jobs_of(read_state_at(schedule_path())) }

fun valid_jobs_of(state) {
    if (elem(state, 0) != 'ok') { [] }
    else { valid_jobs_loop(elem(state, 1), []) }
}

fun valid_jobs_loop(entries, acc) {
    if (length(entries) == 0) { acc }
    else {
        r = normalize_job(hd(entries))
        next = if (elem(r, 0) == 'ok') { list_append(acc, elem(r, 1)) } else { acc }
        valid_jobs_loop(tl(entries), next)
    }
}

# Crash-safe write: file_atomic_write writes <path>.tmp.<pid> and
# rename(2)s it over the old file, so a crash mid-write leaves either
# the old schedule or the new one — never a truncated file that the
# next read would treat as corrupt. Returns 'ok' | 'error'.
fun save_at(p, entries) { file_atomic_write(p, json_encode(entries)) }

# ------------------------------------------------------------
# normalize_job(raw) → {'ok', job} | {'invalid', why}
# ------------------------------------------------------------
# Validates one hand-editable entry. The returned job is the raw map
# with its fields coerced to the types tick() relies on (extra keys
# are preserved), so a fire can write it back without losing data:
#   id          string or integer, [A-Za-z0-9_-]+ (it names pid/.out files)
#   expr        a schedule expression parse_expr accepts
#   prompt      a non-empty string
#   created_at / last_run   non-negative integer ms (numeric strings
#               coerced; floats truncated; missing → 0)
#   runs        non-negative integer (missing / junk → 0 — cosmetic)
#   paused      true/"true" → 'true', anything else → 'false'
fun normalize_job(raw) {
    if (is_map(raw) == 'false') { {'invalid', "entry is not a JSON object"} }
    else {
        id_v = map_get(raw, 'id')
        id_s = if (id_v == nil) { "" }
               else { if (typeof(id_v) == "string" || typeof(id_v) == "int") { to_string(id_v) }
               else { "" } }
        expr_v = map_get(raw, 'expr')
        prompt_v = map_get(raw, 'prompt')
        last_run = coerce_ms(map_get(raw, 'last_run'))
        created = coerce_ms(map_get(raw, 'created_at'))
        runs_c = coerce_ms(map_get(raw, 'runs'))
        runs = if (runs_c == nil) { 0 } else { runs_c }
        paused_v = map_get(raw, 'paused')
        paused = if (paused_v == 'true' || to_string(paused_v) == "true") { 'true' } else { 'false' }
        label = if (string_length(id_s) == 0) { "?" } else { id_s }
        if (safe_id(id_s) == 'false') {
            {'invalid', "job " ++ label ++ ": id must be a number or [A-Za-z0-9_-] string"}
        } else { if (expr_v == nil || typeof(expr_v) != "string" || parse_expr(to_string(expr_v)) == nil) {
            {'invalid', "job " ++ label ++ ": unparseable expr " ++ json_encode(expr_v)}
        } else { if (prompt_v == nil || typeof(prompt_v) != "string" ||
                     string_length(string_trim(to_string(prompt_v))) == 0) {
            {'invalid', "job " ++ label ++ ": prompt must be a non-empty string"}
        } else { if (last_run == nil) {
            {'invalid', "job " ++ label ++ ": last_run must be a timestamp in ms, got " ++
                        json_encode(map_get(raw, 'last_run'))}
        } else { if (created == nil) {
            {'invalid', "job " ++ label ++ ": created_at must be a timestamp in ms, got " ++
                        json_encode(map_get(raw, 'created_at'))}
        } else {
            j1 = map_put(raw, 'id', id_s)
            j2 = map_put(j1, 'expr', string_trim(to_string(expr_v)))
            j3 = map_put(j2, 'last_run', last_run)
            j4 = map_put(j3, 'created_at', created)
            j5 = map_put(j4, 'runs', runs)
            {'ok', map_put(j5, 'paused', paused)}
        }}}}}
    }
}

# Non-negative integer from a JSON value: nil → 0 (field absent), int
# as-is, float truncated, all-digit string parsed; anything else (a
# negative, "yesterday", a list, true) → nil = invalid.
fun coerce_ms(v) {
    if (v == nil) { 0 }
    else {
        t = typeof(v)
        if (t == "int") { if (v >= 0) { v } else { nil } }
        else { if (t == "float") { if (v >= 0) { to_int(v) } else { nil } }
        else { if (t == "string") {
            if (all_digits(v) == 'true') { to_int(v) } else { nil }
        } else { nil } } }
    }
}

fun safe_id(s) {
    if (string_length(s) == 0 || string_length(s) > 64) { 'false' }
    else { safe_id_loop(s, 0) }
}

fun safe_id_loop(s, i) {
    if (i >= string_length(s)) { 'true' }
    else {
        c = codepoint_at(s, i)
        ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) ||
             (c >= 97 && c <= 122) || c == 95 || c == 45
        if (ok) { safe_id_loop(s, i + 1) } else { 'false' }
    }
}

# 'true' iff s is one or more ASCII digits and nothing else.
fun all_digits(s) {
    if (string_length(s) == 0) { 'false' } else { all_digits_loop(s, 0) }
}

fun all_digits_loop(s, i) {
    if (i >= string_length(s)) { 'true' }
    else {
        c = codepoint_at(s, i)
        if (c >= 48 && c <= 57) { all_digits_loop(s, i + 1) } else { 'false' }
    }
}

# ------------------------------------------------------------
# Add a new job.
# ------------------------------------------------------------
# add_checked(expr, prompt) → {'ok', id} | {'error', message}. Refuses
# to write — rather than silently replacing every job — when
# schedule.json exists but does not parse as an array: the old code
# treated a corrupt file as [] and overwrote it with just the new job.
fun add_checked(expr, prompt) { add_at(schedule_path(), expr, prompt) }

# add(expr, prompt) → id string, or nil on any failure. The specific
# reason (bad expression, corrupt schedule.json, write failure) is
# printed here, since the /schedule caller only sees nil.
fun add(expr, prompt) {
    r = add_checked(expr, prompt)
    if (elem(r, 0) == 'ok') { elem(r, 1) }
    else {
        print("\e[38;5;208m✗ " ++ to_string(elem(r, 1)) ++ "\e[0m")
        nil
    }
}

fun add_at(p, expr, prompt) {
    expr_str = string_trim(to_string(expr))
    bad_expr = expr_error(expr_str)
    prompt_str = to_string(prompt)
    if (bad_expr != nil) { {'error', bad_expr} }
    else { if (string_length(string_trim(prompt_str)) == 0) {
        {'error', "schedule prompt must not be empty"}
    } else {
        state = read_state_at(p)
        if (elem(state, 0) != 'ok') {
            {'error', p ++ " " ++ to_string(elem(state, 1)) ++
                      " — refusing to overwrite it (fix or move the file, then retry)"}
        } else {
            entries = elem(state, 1)
            id = to_string(next_id(entries, 0))
            job = %{
                id: id,
                expr: expr_str,
                prompt: prompt_str,
                created_at: timestamp(),
                # Seed last_run to NOW, not 0. With 0 (epoch), compute_next_fire
                # returns a 1970 timestamp that is always < now, so the next 2s
                # heartbeat fires the job immediately on creation (and a past-slot
                # daily HH:MM fires right away) instead of after one interval.
                last_run: timestamp(),
                runs: 0,
                paused: 'false'
            }
            # Append to the RAW entries: entries this version can't
            # validate are preserved on disk, not dropped by the rewrite.
            if (save_at(p, list_append(entries, job)) == 'ok') { {'ok', id} }
            else { {'error', "could not write " ++ p} }
        }
    }}
}

# Next free numeric id over the raw entries (non-map / non-numeric ids
# are ignored, never crash).
fun next_id(jobs, max_so_far) {
    if (length(jobs) == 0) { max_so_far + 1 }
    else {
        j = hd(jobs)
        n = if (is_map(j) == 'false') { 0 }
            else { parse_int_simple(to_string(map_get(j, 'id'))) }
        new_max = if (n > max_so_far) { n } else { max_so_far }
        next_id(tl(jobs), new_max)
    }
}

# Remove by id. Never writes a corrupt file (nothing to remove there).
fun remove(id) {
    p = schedule_path()
    state = read_state_at(p)
    if (elem(state, 0) != 'ok') { 'false' }
    else {
        jobs = elem(state, 1)
        kept = remove_loop(jobs, to_string(id), [])
        if (length(kept) == length(jobs)) { 'false' }
        else { save_at(p, kept) ; 'true' }
    }
}

fun remove_loop(jobs, target, acc) {
    if (length(jobs) == 0) { acc }
    else {
        j = hd(jobs)
        hit = if (is_map(j) == 'false') { 'false' }
              else { if (to_string(map_get(j, 'id')) == target) { 'true' } else { 'false' } }
        new_acc = if (hit == 'true') { acc } else { list_append(acc, j) }
        remove_loop(tl(jobs), target, new_acc)
    }
}

# ------------------------------------------------------------
# Tick — called from Heartbeat. Walks jobs, dispatches any due.
# Only writes schedule.json back to disk when at least one job
# actually fired (the dirty-flag gate). Previously this rewrote on
# every tick because tick_loop always rebuilt a same-length list.
# ------------------------------------------------------------
# This runs INSIDE main's heartbeat handler: a panic here kills the
# interactive session. Hence tick_at's contract — any file content
# (wrong shape, bad field types) is skipped + reported, never raised.
fun tick(opts, count) {
    r = tick_at(schedule_path(), count)
    warn_problems(opts, r)
    map_get(r, 'status')
}

# tick_at(path, count) → %{status, fired, problems}
#   status    'noop' (no valid jobs) | 'ok' | 'corrupt'
#   fired     number of jobs dispatched this tick
#   problems  human-readable reasons for every skipped entry / a
#             corrupt file (surfaced once per distinct problem set)
fun tick_at(p, count) {
    state = read_state_at(p)
    ok_state = if (elem(state, 0) == 'ok') { 'true' } else { 'false' }
    entries = if (ok_state == 'true') { elem(state, 1) } else { [] }
    valid = valid_jobs_loop(entries, [])
    # Prune .out files on a ~15-minute cadence (tick 1, then every 450
    # ticks at the 2s default), NEVER per-tick: prune shells out, and
    # shell() runs on the CALLER's fiber — this is main's heartbeat
    # handler. Running it every tick made each tick cost more than the
    # tick interval and froze the UI behind a growing backlog
    # (2026-07-09). Still prunes even when the job list is empty or
    # corrupt, so .out files can't accumulate unbounded.
    if (count % 450 == 1) { prune_old_out_files(valid) } else { 'skip' }
    if (ok_state == 'false') {
        %{status: 'corrupt', fired: 0,
          problems: [p ++ " " ++ to_string(elem(state, 1)) ++ " — no scheduled jobs will run"]}
    } else {
        now = timestamp()
        r = tick_loop(entries, now, [], 0, [])
        updated = elem(r, 0)
        fired = elem(r, 1)
        problems = elem(r, 2)
        if (fired > 0) { save_at(p, updated) }
        %{status: (if (length(valid) == 0) { 'noop' } else { 'ok' }),
          fired: fired, problems: problems}
    }
}

# Walk the RAW entries: invalid ones are carried through untouched
# (and reported), valid ones get a fire check. A fired job is written
# back in its normalized form; an unfired one stays byte-identical.
fun tick_loop(entries, now, acc, fired, problems) {
    if (length(entries) == 0) { {acc, fired, problems} }
    else {
        raw = hd(entries)
        n = normalize_job(raw)
        if (elem(n, 0) != 'ok') {
            tick_loop(tl(entries), now, list_append(acc, raw), fired,
                      list_append(problems, to_string(elem(n, 1)) ++ " — skipped"))
        } else {
            result = maybe_fire(elem(n, 1), now)
            did = elem(result, 1)
            out = if (did == 'true') { elem(result, 0) } else { raw }
            tick_loop(tl(entries), now, list_append(acc, out),
                      (if (did == 'true') { fired + 1 } else { fired }), problems)
        }
    }
}

# One-time warning per distinct problem set: the heartbeat ticks every
# 2s, so re-printing would spam the prompt. The last-warned set lives
# on the heartbeat ETS table (main's session state); print_above keeps
# the pinned input line intact. A fixed file clears the latch, so a
# later breakage warns again.
fun warn_problems(opts, r) {
    problems = map_get(r, 'problems')
    table = if (opts == nil) { nil } else { map_get(opts, 'heartbeat_table') }
    sig = if (problems == nil) { "" } else { json_encode(problems) }
    if (table == nil) { 'skip' }
    else { if (problems == nil || length(problems) == 0) {
        ets_put(table, 'sched_warned', nil)
        'ok'
    } else { if (ets_get(table, 'sched_warned') == sig) { 'skip' }
    else {
        ets_put(table, 'sched_warned', sig)
        print_above("\e[38;5;208m⚠ schedule: " ++ problem_lines(problems, "") ++ "\e[0m")
        'warned'
    }}}
}

fun problem_lines(ps, acc) {
    if (length(ps) == 0) { acc }
    else {
        sep = if (string_length(acc) == 0) { "" } else { "; " }
        problem_lines(tl(ps), acc ++ sep ++ to_string(hd(ps)))
    }
}

# maybe_fire returns {job, fired_atom} so tick_loop can track whether
# anything actually changed. When no fire: returns the input job
# unchanged (no mutation). When fire: dispatches and returns a new
# job with last_run + runs bumped.
fun maybe_fire(job, now) {
    # Skip paused jobs entirely — do not advance last_run so they
    # fire immediately on resume (not wait another full interval).
    paused = map_get(job, 'paused', 'false')
    if (to_string(paused) == "true") { {job, 'false'} }
    else {
        expr = to_string(map_get(job, 'expr'))
        last_run = map_get(job, 'last_run', 0)
        next_fire = compute_next_fire(expr, last_run, now)
        if (next_fire == nil || next_fire > now) { {job, 'false'} }
        else {
            d = dispatch(job)
            # skipped_busy (previous fire still running): do NOT bump
            # last_run/runs — leave the job due so it retries on the
            # next tick once the child exits, instead of silently
            # swallowing the fire for a whole interval.
            if (d == 'skipped_busy') { {job, 'false'} }
            else {
                runs = map_get(job, 'runs')
                new_runs = if (runs == nil) { 1 } else { runs + 1 }
                new_job = map_put(map_put(job, 'last_run', now), 'runs', new_runs)
                {new_job, 'true'}
            }
        }
    }
}

# ------------------------------------------------------------
# compute_next_fire — when (in ms-since-epoch) the next fire is
# scheduled for, given the expression and the prior fire's epoch ms.
# Three semantics:
#   * "daily HH:MM" — wallclock. Compute today's HH:MM slot in UTC.
#     If that's already past last_run, fire then. Otherwise wait
#     for tomorrow's slot.
#   * "hourly" — wallclock, the first top-of-the-hour (:00 UTC) after
#     last_run. A missed hour (machine asleep) fires once on wake,
#     then realigns to the next :00.
#   * intervals (30s/5m/2h/1d/daily) — last_run + interval_ms.
# Returns nil if the expression is unparseable.
# ------------------------------------------------------------
fun compute_next_fire(expr, last_run, now) {
    trimmed = string_trim(to_string(expr))
    daily_ms_offset = daily_time_ms(trimmed)
    if (daily_ms_offset != nil) {
        day_ms = 86400000
        today_midnight = (now / day_ms) * day_ms
        today_slot = today_midnight + daily_ms_offset
        # If today's slot still hasn't fired this scheduling cycle,
        # aim for it; otherwise schedule tomorrow's.
        if (today_slot > last_run) { today_slot }
        else { today_slot + day_ms }
    }
    else { if (trimmed == "hourly") {
        hour_ms = 3600000
        (last_run / hour_ms + 1) * hour_ms
    }
    else {
        interval_ms = parse_expr(trimmed)
        if (interval_ms == nil) { nil }
        else { last_run + interval_ms }
    }}
}

# parse_expr — return the interval in MILLISECONDS for supported
# expression forms, nil for anything else. "hourly" and "daily HH:MM"
# are wallclock-aligned (see compute_next_fire) but still report
# their nominal period here so validation accepts every shape
# uniformly. Strict: see expr_error for what is rejected and why.
fun parse_expr(s) {
    if (expr_error(to_string(s)) == nil) { expr_period_ms(string_trim(to_string(s))) }
    else { nil }
}

fun expr_period_ms(trimmed) {
    if (trimmed == "hourly") { 3600000 }
    else { if (trimmed == "daily") { 86400000 }
    else { if (daily_time_ms(trimmed) != nil) { 86400000 }
    else { parse_interval(trimmed) }}}
}

# expr_error(s) → nil when `s` is a valid schedule expression, else a
# one-line reason. The old parsers read the leading digits and ignored
# the rest, so "1.5h" ran hourly, "10x5m" every 10 minutes, "daily :"
# at 00:00 and "daily 9:5x" at 09:05 — all silently accepted.
fun expr_error(s) {
    t = string_trim(to_string(s))
    q = "'" ++ t ++ "'"
    hint = " — use e.g. 30s, 5m, 2h, 1d, hourly, daily or daily 09:00"
    if (string_length(t) == 0) { "empty schedule expression" ++ hint }
    else { if (t == "hourly" || t == "daily") { nil }
    else { if (string_starts_with(t, "daily ") == 'true') {
        if (daily_time_ms(t) != nil) { nil }
        else { "invalid time in " ++ q ++ ": want daily HH:MM (UTC, 00:00-23:59, e.g. daily 9:05)" }
    }
    else { if (parse_interval(t) != nil) { nil }
    else {
        "invalid schedule " ++ q ++ ": an interval is a whole number plus s/m/h/d" ++ hint
    }}}}
}

# parse_interval — `30s`, `5m`, `2h`, `1d` → MILLISECONDS, or nil.
# Strict: the count must be ONLY digits (no sign, decimal point, space
# or other junk), >= 1 and <= 9 digits (no int overflow), followed by
# exactly one unit letter. Previously this returned seconds, which
# silently mismatched timestamp()'s ms units; ms throughout now.
fun parse_interval(s) {
    n = string_length(s)
    if (n < 2) { nil }
    else {
        suffix = string_sub(s, n - 1, 1)
        num_str = string_sub(s, 0, n - 1)
        if (all_digits(num_str) == 'false' || string_length(num_str) > 9) { nil }
        else {
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
}

# daily_time_ms — parse "daily HH:MM" -> ms since midnight, or nil
# if the expression isn't a (valid) daily-with-time form. Strict: the
# hour is 1-2 digits, the minute exactly 2, nothing else — "daily :",
# "daily 9:5x", "daily 9:5" and "daily 24:00" are all nil. Used by
# compute_next_fire to schedule wallclock-aligned fires.
fun daily_time_ms(s) {
    if (string_starts_with(s, "daily ") == 'false') { nil }
    else {
        time_part = string_trim(string_sub(s, 6, string_length(s) - 6))
        parts = string_split(time_part, ":")
        if (length(parts) != 2) { nil }
        else {
            h_str = hd(parts)
            m_str = hd(tl(parts))
            shape_ok = all_digits(h_str) == 'true' && all_digits(m_str) == 'true' &&
                       string_length(h_str) <= 2 && string_length(m_str) == 2
            if (shape_ok == 'false') { nil }
            else {
                h = parse_int_simple(h_str)
                m = parse_int_simple(m_str)
                if (h < 0 || h > 23 || m < 0 || m > 59) { nil }
                else { (h * 3600 + m * 60) * 1000 }
            }
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
    # Re-create jobs_dir() if it was deleted externally since startup.
    # Without this, the nohup redirect and pid echo both silently fail,
    # causing an infinite silent-retry loop on every subsequent tick.
    file_mkdir(jobs_dir())
    id = to_string(map_get(job, 'id'))
    pid_file = jobs_dir() ++ "/scheduled-" ++ id ++ ".pid"
    if (previous_fire_alive(pid_file) == 'true') { 'skipped_busy' }
    else {
        prompt = to_string(map_get(job, 'prompt'))
        ts = to_string(timestamp())
        out_path = jobs_dir() ++ "/scheduled-" ++ id ++ "-" ++ ts ++ ".out"
        shell(dispatch_cmd(swarm_binary_path(), prompt, out_path, pid_file))
        'dispatched'
    }
}

# The shell command dispatch() runs. Pure, so the safety prefix is
# unit-testable. SWARM_CODE_DENY_DANGEROUS=1 turns the dangerous-bash
# gate into a hard deny in the child — a headless run otherwise
# auto-approves every 'ask', and a job firing unattended (nobody at
# the terminal, possibly hours later) must not auto-run `rm -rf ~/…`.
# Same rule as Flows.build_task_cmd.
# Pidfile records "PID LSTART" (process start-time) so
# previous_fire_alive can detect a recycled PID — kill(pid,0)
# alone returns alive on EPERM, wedging the job in skipped_busy.
fun dispatch_cmd(bin, prompt, out_path, pid_file) {
    inner =
        "SWARM_CODE_DENY_DANGEROUS=1 nohup " ++ Util.shell_q(bin) ++
        " --no-resume -p " ++ Util.shell_q(prompt) ++
        " > " ++ Util.shell_q(out_path) ++ " 2>&1 & SW_PID=$!; " ++
        "echo \"$SW_PID $(ps -o lstart= -p \"$SW_PID\" 2>/dev/null)\" > " ++ Util.shell_q(pid_file)
    "bash -c " ++ Util.shell_q(inner)
}

# Has the previous fire's child exited? Cheap kill(pid, 0) check via
# the pid_alive builtin first — no shell() overhead on the common
# (dead) path. pid_alive returns 'true' on EPERM too, so a recycled
# PID owned by another user would wedge the job in skipped_busy
# forever; when the pidfile carries an LSTART field we re-verify the
# process start-time via ps and treat a mismatch as "recycled, gone".
# Returns 'true' if the previous child is still alive (so we should
# back off), 'false' otherwise (no pidfile, parse fail, process gone,
# or PID recycled).
fun previous_fire_alive(pid_file) {
    if (file_exists(pid_file) == 'false') { 'false' }
    else {
        pid_content = file_read(pid_file)
        if (pid_content == nil) { 'false' }
        else {
            content = string_trim(to_string(pid_content))
            if (string_length(content) == 0) { 'false' }
            else {
                # Pidfile format: "PID LSTART". LSTART itself contains
                # spaces ("Tue Jun 10 08:15:01 2026"), so take the first
                # token as the PID and slice the remainder as LSTART
                # instead of rejoining split parts.
                parts = string_split(content, " ")
                pid_str = hd(parts)
                lstart = if (length(parts) > 1) {
                    string_trim(string_sub(content, string_length(pid_str) + 1,
                                           string_length(content) - string_length(pid_str) - 1))
                } else { "" }
                if (pid_alive(pid_str) == 'false') { 'false' }
                else {
                    # Old-format pidfile (bare PID, pre start-time): fall
                    # back to the pid_alive answer for back-compat.
                    if (string_length(lstart) == 0) { 'true' }
                    else {
                        # Alive — but is it OUR child or a recycled PID?
                        # shell() polls at ~1s, so only pay for this on the
                        # already-rare path where pid_alive says 'true'.
                        r = shell("ps -o lstart= -p " ++ Util.shell_q(pid_str) ++ " 2>/dev/null")
                        current = string_trim(elem(r, 1))
                        if (current == lstart) { 'true' } else { 'false' }
                    }
                }
            }
        }
    }
}

# ------------------------------------------------------------
# prune_old_out_files — keep only the newest MAX_OUT_FILES .out files
# per job. Called from tick() unconditionally (even when the job list
# is empty/corrupt) so output can never accumulate unbounded.
#
# Strategy: for each known job ID, list all matching
# scheduled-<id>-<ts>.out files sorted by mtime newest-first.
# Delete everything beyond the newest 10. Also runs a single global
# sweep to catch orphaned .out files left behind by removed jobs
# (any file whose ID is no longer in the jobs list AND age > 7 days).
# ------------------------------------------------------------
fun max_out_files() { 10 }

fun prune_old_out_files(jobs) {
    dir = jobs_dir()
    if (file_exists(dir) == 'false') { 'skipped' }
    else {
        # Per-job retention: keep newest max_out_files() per job.
        prune_jobs_loop(jobs, dir)
        # Global sweep: remove orphan .out files older than 7 days.
        orphan_cmd = "find " ++ Util.shell_q(dir) ++
                     " -maxdepth 1 -name 'scheduled-*.out' -mtime +6 -delete 2>/dev/null; true"
        shell(orphan_cmd)
        'pruned'
    }
}

fun prune_jobs_loop(jobs, dir) {
    if (length(jobs) == 0) { 'ok' }
    else {
        j = hd(jobs)
        id = to_string(map_get(j, 'id'))
        prune_job_outputs(id, dir)
        prune_jobs_loop(tl(jobs), dir)
    }
}

# Keep the newest max_out_files() .out files for job `id`.
# Uses `ls -1t` (sort newest-first by mtime) and pipes through
# tail to find the excess, then deletes them.
fun prune_job_outputs(id, dir) {
    pattern = Util.shell_q(dir) ++ "/scheduled-" ++ Util.shell_q(id) ++ "-*.out"
    # tail -n +N prints from line N onward, so keeping the newest
    # max_out_files() means deleting from line max_out_files()+1.
    keep = to_string(max_out_files() + 1)
    # ls -1t: one-file-per-line, newest first. tail -n +N: lines from the
    # Nth onward (i.e. the oldest beyond the keep window). xargs rm -f: delete them.
    # If fewer than keep files exist, tail -n +N produces nothing, xargs is a no-op.
    cmd = "ls -1t " ++ pattern ++ " 2>/dev/null | tail -n +" ++ keep ++
          " | xargs rm -f 2>/dev/null; true"
    shell(cmd)
    'ok'
}

# ------------------------------------------------------------
# pause_job / resume_job — toggle the 'paused' flag on a job and
# persist the change to schedule.json. Returns 'true' on success,
# 'false' if no job with that ID exists.
# ------------------------------------------------------------
fun pause_job(id) {
    set_paused(to_string(id), 'true')
}

fun resume_job(id) {
    set_paused(to_string(id), 'false')
}

fun set_paused(target_id, paused_val) {
    p = schedule_path()
    state = read_state_at(p)
    if (elem(state, 0) != 'ok') { 'false' }
    else {
        r = set_paused_loop(elem(state, 1), target_id, paused_val, [], 'false')
        new_jobs = elem(r, 0)
        found = elem(r, 1)
        if (found == 'true') { save_at(p, new_jobs) ; 'true' }
        else { 'false' }
    }
}

fun set_paused_loop(jobs, target_id, paused_val, acc, found) {
    if (length(jobs) == 0) { {acc, found} }
    else {
        j = hd(jobs)
        if (is_map(j) == 'true' && to_string(map_get(j, 'id')) == target_id) {
            new_j = map_put(j, 'paused', paused_val)
            set_paused_loop(tl(jobs), target_id, paused_val, list_append(acc, new_j), 'true')
        } else {
            set_paused_loop(tl(jobs), target_id, paused_val, list_append(acc, j), found)
        }
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
