module Main

import Tools

fun main() {
  ok = 0
  total = 0

  if (t_max_output_bytes() == 'pass') { ok = ok + 1 } else { print("  cross t_max_output_bytes") }
  total = total + 1

  if (ok == total) {
    print("  ok tools: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(0)
  } else {
    print("  fail tools: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(1)
  }
}

fun t_max_output_bytes() {
  if (Tools.max_output_bytes() == 6000) { 'pass' } else { 'fail' }
}
