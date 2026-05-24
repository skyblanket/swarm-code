module Main

import LLM
import Vision

fun main() {
  ok = 0
  total = 0

  if (t_chat_completions_url() == 'pass') { ok = ok + 1 } else { print("  cross t_chat_completions_url") }
  total = total + 1

  if (t_new_messages() == 'pass') { ok = ok + 1 } else { print("  cross t_new_messages") }
  total = total + 1

  if (t_inband_assistant_text() == 'pass') { ok = ok + 1 } else { print("  cross t_inband_assistant_text") }
  total = total + 1

  if (t_extract_content() == 'pass') { ok = ok + 1 } else { print("  cross t_extract_content") }
  total = total + 1

  if (ok == total) {
    print("  ok llm: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(0)
  } else {
    print("  fail llm: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(1)
  }
}

fun t_chat_completions_url() {
  a = LLM.chat_completions_url("https://api.openai.com")
  b = LLM.chat_completions_url("https://api.openai.com/")
  c = LLM.chat_completions_url("https://api.openai.com/v1")
  d = LLM.chat_completions_url("https://custom.com/chat/completions")
  exp = "https://api.openai.com/v1/chat/completions"
  if (a == exp && b == exp && c == exp && d == "https://custom.com/chat/completions") {
    'pass'
  } else {
    'fail'
  }
}

fun t_new_messages() {
  sys = LLM.new_message_system("be helpful")
  usr = LLM.new_message_user("hello")
  tool = LLM.new_message_tool("call_1", "result")
  if (map_get(sys, 'role') == 'system' && map_get(sys, 'content') == "be helpful" &&
      map_get(usr, 'role') == 'user' && map_get(usr, 'content') == "hello" &&
      map_get(tool, 'role') == 'tool' && map_get(tool, 'tool_call_id') == "call_1" && map_get(tool, 'content') == "result") {
    'pass'
  } else {
    'fail'
  }
}

fun t_inband_assistant_text() {
  tc = %{name: "test", arguments: "{}"}
  msg1 = LLM.new_message_assistant("Hello", [tc], nil)
  r1 = LLM.inband_assistant_text(msg1)
  msg2 = LLM.new_message_assistant("", [tc], nil)
  r2 = LLM.inband_assistant_text(msg2)
  msg3 = LLM.new_message_assistant("Hello", nil, nil)
  r3 = LLM.inband_assistant_text(msg3)
  if (r1 == "Hello\ncall:test{}" && r2 == "call:test{}" && r3 == "Hello") {
    'pass'
  } else {
    'fail'
  }
}

fun t_extract_content() {
  resp = "{\"choices\":[{\"message\":{\"content\":\"hello\"}}]}"
  r = LLM.extract_content(resp)
  if (r == "hello") {
    'pass'
  } else {
    'fail'
  }
}
