module Main

import Background

fun main() {
  ok = 0
  total = 0

  if (t_log_path_for() == 'pass) { ok = ok + 1 } else { print("  FAIL t_log_path_for") }
  total = total + 1

  if (t_status_unknown() == 'pass) { ok = ok + 1 } else { print("  FAIL t_status_unknown") }
  total = total + 1

  if (t_list_all_empty() == 'pass) { ok = ok + 1 } else { print("  FAIL t_list_all_empty") }
  total = total + 1

  if (t_all_pending_ids_empty() == 'pass) { ok = ok + 1 } else { print("  FAIL t_all_pending_ids_empty") }
  total = total + 1

  if (ok == total) {
    print("  ok background: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(0)
  } else {
    print("  fail background: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(1)
  }
}

fun t_log_path_for() {
  if (Background.log_path_for("bg-0") == "/tmp/swarm-code-bg-0.log") { 'pass } else { 'fail }
}

fun t_status_unknown() {
  table = Background.init()
  if (Background.status(table, "bg-0") == 'unknown) { 'pass } else { 'fail }
}

fun t_list_all_empty() {
  table = Background.init()
  if (Background.list_all(table) == "(no background tasks)") { 'pass } else { 'fail }
}

fun t_all_pending_ids_empty() {
  table = Background.init()
  if (Background.all_pending_ids(table) == []) { 'pass } else { 'fail }
}
