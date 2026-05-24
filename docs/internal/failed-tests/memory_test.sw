module Main

import Memory

fun main() {
  ok = 0
  total = 0

  if (t_slugify() == 'pass') { ok = ok + 1 } else { print("  cross t_slugify") }
  total = total + 1

  if (t_find_substring() == 'pass') { ok = ok + 1 } else { print("  cross t_find_substring") }
  total = total + 1

  if (t_parse_frontmatter() == 'pass') { ok = ok + 1 } else { print("  cross t_parse_frontmatter") }
  total = total + 1

  if (t_memory_file_path() == 'pass') { ok = ok + 1 } else { print("  cross t_memory_file_path") }
  total = total + 1

  if (ok == total) {
    print("  ok memory: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(0)
  } else {
    print("  fail memory: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(1)
  }
}

fun t_slugify() {
  if (Memory.slugify("User's ADHD workflow") == "user_s_adhd_workflow") { 'pass' } else { 'fail' }
}

fun t_find_substring() {
  if (Memory.find_substring("hello world", "world") == 6) { 'pass' } else { 'fail' }
}

fun t_parse_frontmatter() {
  fm = Memory.parse_frontmatter("---\nname: Test Mem\ntype: user\n---\nBody here")
  name = map_get(fm, "name")
  ty = map_get(fm, "type")
  if (name == "Test Mem" && ty == "user") { 'pass' } else { 'fail' }
}

fun t_memory_file_path() {
  path = Memory.memory_file_path("my_slug")
  if (string_ends_with(path, "/my_slug.md") == 'true') { 'pass' } else { 'fail' }
}
