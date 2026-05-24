module Main

import Heartbeat

fun main() {
  ok = 0
  total = 0

  if (t_get_state_nil_active() == 'pass') { ok = ok + 1 } else { print("  cross t_get_state_nil_active") }
  total = total + 1

  if (t_get_state_nil_tick_count() == 'pass') { ok = ok + 1 } else { print("  cross t_get_state_nil_tick_count") }
  total = total + 1

  if (t_get_state_nil_uptime_ms() == 'pass') { ok = ok + 1 } else { print("  cross t_get_state_nil_uptime_ms") }
  total = total + 1

  if (t_format_status_nil() == 'pass') { ok = ok + 1 } else { print("  cross t_format_status_nil") }
  total = total + 1

  if (ok == total) {
    print("  ok heartbeat: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(0)
  } else {
    print("  fail heartbeat: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(1)
  }
}

fun t_get_state_nil_active() {
  state = Heartbeat.get_state(nil)
  if (map_get(state, 'active') == 'false') { 'pass' } else { 'fail' }
}

fun t_get_state_nil_tick_count() {
  state = Heartbeat.get_state(nil)
  if (map_get(state, 'tick_count') == 0) { 'pass' } else { 'fail' }
}

fun t_get_state_nil_uptime_ms() {
  state = Heartbeat.get_state(nil)
  if (map_get(state, 'uptime_ms') == 0) { 'pass' } else { 'fail' }
}

fun t_format_status_nil() {
  result = Heartbeat.format_status(nil)
  expected = "pulse false · 0 ticks · 0s uptime · nils interval"
  if (result == expected) { 'pass' } else { 'fail' }
}
