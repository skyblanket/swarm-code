module Main

import ToolRegistry

fun main() {
  ok = 0
  total = 0

  if (t_all_tools() == 'pass') { ok = ok + 1 } else { print("  cross t_all_tools") }
  total = total + 1

  if (t_atom_for_known() == 'pass') { ok = ok + 1 } else { print("  cross t_atom_for_known") }
  total = total + 1

  if (t_atom_for_unknown() == 'pass') { ok = ok + 1 } else { print("  cross t_atom_for_unknown") }
  total = total + 1

  if (t_knows_true() == 'pass') { ok = ok + 1 } else { print("  cross t_knows_true") }
  total = total + 1

  if (t_knows_false() == 'pass') { ok = ok + 1 } else { print("  cross t_knows_false") }
  total = total + 1

  if (ok == total) {
    print("  ok ToolRegistry: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(0)
  } else {
    print("  fail ToolRegistry: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(1)
  }
}

fun t_all_tools() {
  tools = ToolRegistry.all_tools()
  if (length(tools) > 0) {
    first = hd(tools)
    if (map_get(first, 'name') == "bash") { 'pass' } else { 'fail' }
  } else {
    'fail'
  }
}

fun t_atom_for_known() {
  if (ToolRegistry.atom_for("bash") == 'bash') { 'pass' } else { 'fail' }
}

fun t_atom_for_unknown() {
  if (ToolRegistry.atom_for("nonexistent") == "nonexistent") { 'pass' } else { 'fail' }
}

fun t_knows_true() {
  if (ToolRegistry.knows("read") == 'true') { 'pass' } else { 'fail' }
}

fun t_knows_false() {
  if (ToolRegistry.knows("nope") == 'false') { 'pass' } else { 'fail' }
}
