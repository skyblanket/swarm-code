module Main

import SessionSearch

fun main() {
  ok = 0
  total = 0

  if (t_sessions_dir() == 'pass') { ok = ok + 1 } else { print("  cross t_sessions_dir") }
  total = total + 1

  if (t_db_path() == 'pass') { ok = ok + 1 } else { print("  cross t_db_path") }
  total = total + 1

  if (ok == total) {
    print("  ok SessionSearch: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(0)
  } else {
    print("  fail SessionSearch: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(1)
  }
}

fun t_sessions_dir() {
  if (string_ends_with(SessionSearch.sessions_dir(), "/.swarm-code/sessions") == 'true') { 'pass' } else { 'fail' }
}

fun t_db_path() {
  if (string_ends_with(SessionSearch.db_path(), "/.swarm-code/sessions/index.db") == 'true') { 'pass' } else { 'fail' }
}
