module Main

import UI

fun main() {
  ok = 0
  total = 0

  if (t_brand_color() == 'pass') { ok = ok + 1 } else { print("  cross t_brand_color") }
  total = total + 1

  if (t_reset() == 'pass') { ok = ok + 1 } else { print("  cross t_reset") }
  total = total + 1

  if (t_agent_color() == 'pass') { ok = ok + 1 } else { print("  cross t_agent_color") }
  total = total + 1

  if (t_todo_summary() == 'pass') { ok = ok + 1 } else { print("  cross t_todo_summary") }
  total = total + 1

  if (t_todo_list_render() == 'pass') { ok = ok + 1 } else { print("  cross t_todo_list_render") }
  total = total + 1

  if (ok == total) {
    print("  ok ui: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(0)
  } else {
    print("  fail ui: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(1)
  }
}

fun t_brand_color() {
  if (UI.brand_color() == "\e[38;2;175;0;0m") { 'pass' } else { 'fail' }
}

fun t_reset() {
  if (UI.reset() == "\e[0m") { 'pass' } else { 'fail' }
}

fun t_agent_color() {
  if (UI.agent_color("test") == "\e[38;2;127;216;143m") { 'pass' } else { 'fail' }
}

fun t_todo_summary() {
  todos = [
    %{status: "completed", content: "done task"},
    %{status: "pending", content: "pending task"}
  ]
  expected = "1 pending, " ++ UI.green() ++ "1 done" ++ UI.reset()
  if (UI.todo_summary(todos) == expected) { 'pass' } else { 'fail' }
}

fun t_todo_list_render() {
  todos = [
    %{status: "completed", content: "finish tests"}
  ]
  r = UI.todo_list_render(todos)
  if (string_contains(r, "finish tests")) { 'pass' } else { 'fail' }
}
