module Main

import ToolSchemas

fun main() {
  ok = 0
  total = 0

  if (t_all_schemas_count() == 'pass') { ok = ok + 1 } else { print("  cross t_all_schemas_count") }
  total = total + 1

  if (t_all_schemas_first() == 'pass') { ok = ok + 1 } else { print("  cross t_all_schemas_first") }
  total = total + 1

  if (t_all_schemas_json() == 'pass') { ok = ok + 1 } else { print("  cross t_all_schemas_json") }
  total = total + 1

  if (ok == total) {
    print("  ok ToolSchemas: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(0)
  } else {
    print("  fail ToolSchemas: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(1)
  }
}

fun t_all_schemas_count() {
  if (length(ToolSchemas.all_schemas()) == 29) { 'pass' } else { 'fail' }
}

fun t_all_schemas_first() {
  schemas = ToolSchemas.all_schemas()
  first = hd(schemas)
  fn_map = map_get(first, 'function')
  name = map_get(fn_map, 'name')
  if (name == "bash") { 'pass' } else { 'fail' }
}

fun t_all_schemas_json() {
  json = ToolSchemas.all_schemas_json()
  if (string_contains(json, "bash")) { 'pass' } else { 'fail' }
}
