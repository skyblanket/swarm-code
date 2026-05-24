module Main

import Mcp

fun main() {
  ok = 0
  total = 0

  if (t_all_schemas_nil() == 'pass') { ok = ok + 1 } else { print("  cross t_all_schemas_nil") }
  total = total + 1

  if (t_as_prompt_section_nil() == 'pass') { ok = ok + 1 } else { print("  cross t_as_prompt_section_nil") }
  total = total + 1

  if (t_list_servers_nil() == 'pass') { ok = ok + 1 } else { print("  cross t_list_servers_nil") }
  total = total + 1

  if (t_shutdown_nil() == 'pass') { ok = ok + 1 } else { print("  cross t_shutdown_nil") }
  total = total + 1

  if (ok == total) {
    print("  ok mcp: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(0)
  } else {
    print("  fail mcp: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(1)
  }
}

fun t_all_schemas_nil() {
  if (Mcp.all_schemas(nil) == []) { 'pass' } else { 'fail' }
}

fun t_as_prompt_section_nil() {
  if (Mcp.as_prompt_section(nil) == "") { 'pass' } else { 'fail' }
}

fun t_list_servers_nil() {
  if (Mcp.list_servers(nil) == "MCP not initialised") { 'pass' } else { 'fail' }
}

fun t_shutdown_nil() {
  if (Mcp.shutdown(nil) == 'ok') { 'pass' } else { 'fail' }
}
