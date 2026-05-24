module Main

import Markdown

fun main() {
  ok = 0
  total = 0

  if (t_empty() == 'pass') { ok = ok + 1 } else { print("  x t_empty") }
  total = total + 1

  if (t_header() == 'pass') { ok = ok + 1 } else { print("  x t_header") }
  total = total + 1

  if (t_bullet() == 'pass') { ok = ok + 1 } else { print("  x t_bullet") }
  total = total + 1

  if (t_inline_bold() == 'pass') { ok = ok + 1 } else { print("  x t_inline_bold") }
  total = total + 1

  if (t_inline_code() == 'pass') { ok = ok + 1 } else { print("  x t_inline_code") }
  total = total + 1

  if (ok == total) {
    print("  ok markdown: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(0)
  } else {
    print("  fail markdown: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(1)
  }
}

fun t_empty() {
  a = Markdown.render("", 80)
  b = Markdown.render(nil, 80)
  if (a == "" && b == "") { 'pass' } else { 'fail' }
}

fun t_header() {
  h1 = Markdown.render("# Hello", 80)
  h2 = Markdown.render("## Hello", 80)
  h3 = Markdown.render("### Hello", 80)
  e1 = "  \e[38;2;175;0;0m\e[1m\e[4mHello\e[0m"
  e2 = "  \e[38;2;175;0;0m\e[1mHello\e[0m"
  e3 = "  \e[1mHello\e[0m"
  if (h1 == e1 && h2 == e2 && h3 == e3) { 'pass' } else { 'fail' }
}

fun t_bullet() {
  r = Markdown.render("- Hello world", 80)
  e = "  • Hello world"
  if (r == e) { 'pass' } else { 'fail' }
}

fun t_inline_bold() {
  r = Markdown.render("Hello **world**", 80)
  e = "  Hello \e[1mworld\e[0m"
  if (r == e) { 'pass' } else { 'fail' }
}

fun t_inline_code() {
  r = Markdown.render("Hello `world`", 80)
  e = "  Hello \e[38;2;175;0;0mworld\e[0m"
  if (r == e) { 'pass' } else { 'fail' }
}
