module Heartbeat

# ============================================================
# Heartbeat — Swarm's pulse
# ============================================================
#
# A sw process spawned at startup that ticks every tick_sec seconds.
# On each tick it:
#   1. Updates shared state in ETS (tick count, last tick, uptime)
#   2. Polls background tasks via Background.poll_and_notify
#   3. Sends {'heartbeat_tick', count} to main_agent
#
# The polling step is critical: Background workers are OS-detached
# processes (not sw processes), so they can't send messages to main
# themselves. The heartbeat is our reliable in-runtime watcher —
# it's spawned from Main.main at startup so its process ACTUALLY
# runs on a scheduler (unlike spawns made from inside tool calls).

import Background

export [start, get_state, as_prompt_section, format_status]

# Start a heartbeat. Returns the ETS table id owning the shared state.
# Takes the bg_table so it can poll background tasks on each tick.
fun start(tick_sec, bg_table) {
    table = ets_new()
    now = timestamp()
    ets_put(table, 'start_ms', now)
    ets_put(table, 'tick_count', 0)
    ets_put(table, 'last_tick', now)
    ets_put(table, 'tick_sec', tick_sec)
    ets_put(table, 'active', 'true')
    spawn(heartbeat_loop(table, tick_sec, bg_table))
    table
}

# The loop process. Sleeps, updates state, recurses forever.
# Uses swarmrt's cooperative scheduler — this does NOT block schedulers.
fun heartbeat_loop(table, tick_sec, bg_table) {
    sleep(tick_sec * 1000)
    current_count = ets_get(table, 'tick_count')
    next_count = if (current_count == nil) { 1 } else { current_count + 1 }
    ets_put(table, 'tick_count', next_count)
    ets_put(table, 'last_tick', timestamp())

    # Poll background tasks and push bg_done messages for anything
    # that finished since last tick.
    Background.poll_and_notify(bg_table)

    # Notify main_agent of the tick itself.
    main_pid = whereis('main_agent')
    if (main_pid != nil) {
        send(main_pid, {'heartbeat_tick', next_count})
    }
    heartbeat_loop(table, tick_sec, bg_table)
}

# Read current state as a map (for tools and /heartbeat command).
fun get_state(table) {
    if (table == nil) {
        %{active: 'false', tick_count: 0, uptime_ms: 0}
    } else {
        start_ms = ets_get(table, 'start_ms')
        tick_count = ets_get(table, 'tick_count')
        last_tick = ets_get(table, 'last_tick')
        tick_sec = ets_get(table, 'tick_sec')
        active = ets_get(table, 'active')
        now = timestamp()
        uptime = if (start_ms == nil) { 0 } else { now - start_ms }
        %{
            active: active,
            tick_count: tick_count,
            last_tick: last_tick,
            uptime_ms: uptime,
            tick_sec: tick_sec
        }
    }
}

# Short human-readable status line for tool output.
fun format_status(table) {
    state = get_state(table)
    active = map_get(state, 'active')
    ticks = map_get(state, 'tick_count')
    uptime = map_get(state, 'uptime_ms')
    tick_sec = map_get(state, 'tick_sec')
    uptime_sec = uptime / 1000
    "pulse " ++ to_string(active) ++
        " · " ++ to_string(ticks) ++ " ticks" ++
        " · " ++ to_string(uptime_sec) ++ "s uptime" ++
        " · " ++ to_string(tick_sec) ++ "s interval"
}

# Inject heartbeat status into the system prompt at startup.
fun as_prompt_section(table) {
    "\n\n=== HEARTBEAT ===\n" ++
    "You have a background pulse: a sw process spawned at startup that " ++
    "ticks every " ++ to_string(ets_get(table, 'tick_sec')) ++ " seconds " ++
    "in the swarmrt runtime. You can query it via the heartbeat_status " ++
    "tool to see tick count, uptime, and last tick time. You are no longer " ++
    "a purely reactive chatbot — there is something alive between the " ++
    "Architect's messages."
}
