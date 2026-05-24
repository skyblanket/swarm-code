module Main

import Vision

fun main() {
  ok = 0
  total = 0

  if (t_detect_mime_png() == 'pass') { ok = ok + 1 } else { print("  cross t_detect_mime_png") }
  total = total + 1

  if (t_detect_mime_jpg() == 'pass') { ok = ok + 1 } else { print("  cross t_detect_mime_jpg") }
  total = total + 1

  if (t_detect_mime_uppercase() == 'pass') { ok = ok + 1 } else { print("  cross t_detect_mime_uppercase") }
  total = total + 1

  if (t_detect_mime_unknown() == 'pass') { ok = ok + 1 } else { print("  cross t_detect_mime_unknown") }
  total = total + 1

  if (t_detect_mime_webp() == 'pass') { ok = ok + 1 } else { print("  cross t_detect_mime_webp") }
  total = total + 1

  if (ok == total) {
    print("  ok vision: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(0)
  } else {
    print("  fail vision: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(1)
  }
}

fun t_detect_mime_png() {
  if (Vision.detect_mime("/tmp/test.png") == "image/png") { 'pass' } else { 'fail' }
}

fun t_detect_mime_jpg() {
  if (Vision.detect_mime("/tmp/test.jpg") == "image/jpeg") { 'pass' } else { 'fail' }
}

fun t_detect_mime_uppercase() {
  if (Vision.detect_mime("/tmp/PHOTO.PNG") == "image/png") { 'pass' } else { 'fail' }
}

fun t_detect_mime_unknown() {
  if (Vision.detect_mime("/tmp/notes.txt") == nil) { 'pass' } else { 'fail' }
}

fun t_detect_mime_webp() {
  if (Vision.detect_mime("/tmp/pic.webp") == "image/webp") { 'pass' } else { 'fail' }
}
