module Main

import Skills

fun main() {
  ok = 0
  total = 0

  if (t_skill_dir() == 'pass') { ok = ok + 1 } else { print("  cross t_skill_dir") }
  total = total + 1

  if (t_skill_file_path() == 'pass') { ok = ok + 1 } else { print("  cross t_skill_file_path") }
  total = total + 1

  if (t_index_path() == 'pass') { ok = ok + 1 } else { print("  cross t_index_path") }
  total = total + 1

  if (t_slugify() == 'pass') { ok = ok + 1 } else { print("  cross t_slugify") }
  total = total + 1

  if (ok == total) {
    print("  ok skills: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(0)
  } else {
    print("  fail skills: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(1)
  }
}

fun t_skill_dir() {
  dir = Skills.skill_dir("deploy")
  if (string_sub(dir, string_length(dir) - 7, 7) == "/deploy") { 'pass' } else { 'fail' }
}

fun t_skill_file_path() {
  path = Skills.skill_file_path("deploy")
  if (string_sub(path, string_length(path) - 16, 16) == "/deploy/SKILL.md") { 'pass' } else { 'fail' }
}

fun t_index_path() {
  path = Skills.index_path()
  if (string_sub(path, string_length(path) - 10, 10) == "/SKILLS.md") { 'pass' } else { 'fail' }
}

fun t_slugify() {
  if (Skills.slugify("Hello World!") == "hello_world_") { 'pass' } else { 'fail' }
}
