module JsonCheck

# ============================================================
# JsonCheck — strict JSON well-formedness (RFC 8259)
# ============================================================
#
# The runtime's json_decode is deliberately forgiving: it never fails
# on a truncated or hand-mangled document, it guesses. Observed:
#   "[1, 2"          → [1, 2]          (unterminated)
#   "[1,,2]"         → [1, nil, 2]
#   "[tru]"          → [nil, nil, nil]
#   "{\"a\":} junk"  → %{a: nil}
# That is fine for tolerant reads, but a WRITER must be able to tell
# "this file is valid JSON" from "this file is damaged": treating a
# damaged schedule.json as a parsed list and rewriting it silently
# destroys the user's data. valid(s) answers that question exactly —
# one JSON value, optionally surrounded by whitespace, nothing else.
#
# Byte-level scan via codepoint_at (sw has no regex). Structure is
# recursive descent with nesting capped at 512; every per-element loop
# (array items, object members, string bytes, digits) is SELF-tail-
# recursive, so long documents run in a flat stack. UTF-8 bytes >=
# 0x80 inside strings are accepted as-is (not re-validated).

export [valid]

fun max_depth() { 512 }

# 'true' iff `s` is exactly one well-formed JSON value (+ whitespace).
fun valid(s) {
    if (s == nil) { 'false' }
    else {
        str = to_string(s)
        n = string_length(str)
        i = jc_ws(str, 0, n)
        j = jc_value(str, i, n, 0)
        if (j < 0) { 'false' }
        else { if (jc_ws(str, j, n) == n) { 'true' } else { 'false' } }
    }
}

# Skip JSON whitespace (space, tab, LF, CR). Returns the next index.
fun jc_ws(s, i, n) {
    if (i >= n) { i }
    else {
        c = codepoint_at(s, i)
        if (c == 32 || c == 9 || c == 10 || c == 13) { jc_ws(s, i + 1, n) }
        else { i }
    }
}

# Parse one value starting at i. Returns the index just past it, or -1.
fun jc_value(s, i, n, depth) {
    if (i >= n || depth > max_depth()) { 0 - 1 }
    else {
        c = codepoint_at(s, i)
        if (c == 123) { jc_object(s, jc_ws(s, i + 1, n), n, depth + 1) }      # {
        else { if (c == 91) { jc_array(s, jc_ws(s, i + 1, n), n, depth + 1) } # [
        else { if (c == 34) { jc_string(s, i + 1, n) }                        # "
        else { if (c == 116) { jc_lit(s, i, n, "true") }
        else { if (c == 102) { jc_lit(s, i, n, "false") }
        else { if (c == 110) { jc_lit(s, i, n, "null") }
        else { if (c == 45 || jc_digit(c) == 'true') { jc_number(s, i, n) }
        else { 0 - 1 }}}}}}}
    }
}

fun jc_lit(s, i, n, word) {
    k = string_length(word)
    if (i + k <= n && string_sub(s, i, k) == word) { i + k } else { 0 - 1 }
}

fun jc_digit(c) { if (c >= 48 && c <= 57) { 'true' } else { 'false' } }

fun jc_hex(c) {
    if (jc_digit(c) == 'true' || (c >= 97 && c <= 102) || (c >= 65 && c <= 70)) { 'true' }
    else { 'false' }
}

# Array body; `i` is just past '[' and its whitespace.
fun jc_array(s, i, n, depth) {
    if (i < n && codepoint_at(s, i) == 93) { i + 1 }      # empty []
    else { jc_array_items(s, i, n, depth) }
}

fun jc_array_items(s, i, n, depth) {
    j = jc_value(s, i, n, depth)
    if (j < 0) { 0 - 1 }
    else {
        k = jc_ws(s, j, n)
        if (k >= n) { 0 - 1 }
        else {
            c = codepoint_at(s, k)
            if (c == 44) { jc_array_items(s, jc_ws(s, k + 1, n), n, depth) }   # ,
            else { if (c == 93) { k + 1 } else { 0 - 1 } }                    # ]
        }
    }
}

# Object body; `i` is just past '{' and its whitespace.
fun jc_object(s, i, n, depth) {
    if (i < n && codepoint_at(s, i) == 125) { i + 1 }     # empty {}
    else { jc_members(s, i, n, depth) }
}

fun jc_members(s, i, n, depth) {
    if (i >= n || codepoint_at(s, i) != 34) { 0 - 1 }     # key must be a string
    else {
        kend = jc_string(s, i + 1, n)
        if (kend < 0) { 0 - 1 }
        else {
            colon = jc_ws(s, kend, n)
            if (colon >= n || codepoint_at(s, colon) != 58) { 0 - 1 }   # :
            else {
                j = jc_value(s, jc_ws(s, colon + 1, n), n, depth)
                if (j < 0) { 0 - 1 }
                else {
                    k = jc_ws(s, j, n)
                    if (k >= n) { 0 - 1 }
                    else {
                        c = codepoint_at(s, k)
                        if (c == 44) { jc_members(s, jc_ws(s, k + 1, n), n, depth) }
                        else { if (c == 125) { k + 1 } else { 0 - 1 } }
                    }
                }
            }
        }
    }
}

# String body; `i` is just past the opening quote. Control characters
# must be escaped; escapes are \" \\ \/ \b \f \n \r \t \uXXXX only.
fun jc_string(s, i, n) {
    if (i >= n) { 0 - 1 }
    else {
        c = codepoint_at(s, i)
        if (c == 34) { i + 1 }
        else { if (c < 32) { 0 - 1 }
        else { if (c == 92) {
            if (i + 1 >= n) { 0 - 1 }
            else {
                e = codepoint_at(s, i + 1)
                if (e == 34 || e == 92 || e == 47 || e == 98 || e == 102 ||
                    e == 110 || e == 114 || e == 116) { jc_string(s, i + 2, n) }
                else { if (e == 117) {
                    if (i + 5 < n && jc_hex(codepoint_at(s, i + 2)) == 'true' &&
                        jc_hex(codepoint_at(s, i + 3)) == 'true' &&
                        jc_hex(codepoint_at(s, i + 4)) == 'true' &&
                        jc_hex(codepoint_at(s, i + 5)) == 'true') { jc_string(s, i + 6, n) }
                    else { 0 - 1 }
                } else { 0 - 1 } }
            }
        } else { jc_string(s, i + 1, n) } } }
    }
}

# -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
fun jc_number(s, i, n) {
    a = if (codepoint_at(s, i) == 45) { i + 1 } else { i }
    if (a >= n || jc_digit(codepoint_at(s, a)) == 'false') { 0 - 1 }
    else {
        b = if (codepoint_at(s, a) == 48) { a + 1 } else { jc_digits(s, a, n) }
        c = if (b < n && codepoint_at(s, b) == 46) {                  # .
                if (b + 1 < n && jc_digit(codepoint_at(s, b + 1)) == 'true') { jc_digits(s, b + 1, n) }
                else { 0 - 1 }
            } else { b }
        if (c < 0) { 0 - 1 }
        else {
            if (c < n && (codepoint_at(s, c) == 101 || codepoint_at(s, c) == 69)) {   # e E
                d = if (c + 1 < n && (codepoint_at(s, c + 1) == 43 || codepoint_at(s, c + 1) == 45)) { c + 2 }
                    else { c + 1 }
                if (d < n && jc_digit(codepoint_at(s, d)) == 'true') { jc_digits(s, d, n) }
                else { 0 - 1 }
            } else { c }
        }
    }
}

fun jc_digits(s, i, n) {
    if (i < n && jc_digit(codepoint_at(s, i)) == 'true') { jc_digits(s, i + 1, n) }
    else { i }
}
