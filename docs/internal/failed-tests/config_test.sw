module Main

import Config

fun main() {
  ok = 0
  total = 0

  if (t_default_allow() == 'pass') { ok = ok + 1 } else { print("  cross t_default_allow") }
  total = total + 1

  if (t_configured_deny() == 'pass') { ok = ok + 1 } else { print("  cross t_configured_deny") }
  total = total + 1

  if (t_mcp_default_ask() == 'pass') { ok = ok + 1 } else { print("  cross t_mcp_default_ask") }
  total = total + 1

  if (t_run_hooks_no_settings() == 'pass') { ok = ok + 1 } else { print("  cross t_run_hooks_no_settings") }
  total = total + 1

  if (t_run_hooks_settings_no_hooks() == 'pass') { ok = ok + 1 } else { print("  cross t_run_hooks_settings_no_hooks") }
  total = total + 1

  if (ok == total) {
    print("  ok config: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(0)
  } else {
    print("  fail config: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(1)
  }
}

fun t_default_allow() {
  if (Config.check_permission('read', map_new(), map_new()) == 'allow') { 'pass' } else { 'fail' }
}

fun t_configured_deny() {
  perms = map_put(map_new(), 'read', "deny")
  settings = map_put(map_new(), 'permissions', perms)
  opts = map_put(map_new(), 'settings', settings)
  if (Config.check_permission('read', map_new(), opts) == 'deny') { 'pass' } else { 'fail' }
}

fun t_mcp_default_ask() {
  if (Config.check_permission("mcp__test__tool", map_new(), map_new()) == 'ask') { 'pass' } else { 'fail' }
}

fun t_run_hooks_no_settings() {
  if (Config.run_hooks('PreToolUse', 'bash', "{}", map_new()) == 'ok') { 'pass' } else { 'fail' }
}

fun t_run_hooks_settings_no_hooks() {
  settings = map_put(map_new(), 'permissions', map_new())
  opts = map_put(map_new(), 'settings', settings)
  if (Config.run_hooks('PreToolUse', 'bash', "{}", opts) == 'ok') { 'pass' } else { 'fail' }
}
