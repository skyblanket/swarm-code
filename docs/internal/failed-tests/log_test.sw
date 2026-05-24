module Main

import Log

fun main() {
  ok = 0
  total = 0

  if (t_path_contains_suffix() == 'pass') { ok = ok + 1 } else { print("  cross t_path_contains_suffix") }
  total = total + 1

  if (t_path_contains_telemetry() == 'pass') { ok = ok + 1 } else { print("  cross t_path_contains_telemetry") }
  total = total + 1

  if (ok == total) {
    print("  ok log: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(0)
  } else {
    print("  fail log: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(1)
  }
}

fun t_path_contains_suffix() {
  if (string_contains(Log.path(), "events.jsonl")) { 'pass' } else { 'fail' }
}

fun t_path_contains_telemetry() {
  if (string_contains(Log.path(), ".swarm-code/telemetry")) { 'pass' } else { 'fail' }
}
