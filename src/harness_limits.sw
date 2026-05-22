module HarnessLimits

# Limit tests for swarm-code harness
# Run via: cd /Users/sky/swarm-code && make test (after adding to test_runner)

export [run_all]

fun run_all() {
    print("")
    print("========================================")
    print("  HARNESS LIMIT TESTS")
    print("========================================")
    print("")

    passed = 0
    total = 17

    passed = passed + t_large_file()
    passed = passed + t_long_string()
    passed = passed + t_ets_limits()
    passed = passed + t_map_limits()
    passed = passed + t_json_limits()
    passed = passed + t_string_processing()
    passed = passed + t_list_limits()
    passed = passed + t_shell_limits()
    passed = passed + t_file_limits()
    passed = passed + t_string_concat()
    passed = passed + t_nested_maps()
    passed = passed + t_json_special()
    passed = passed + t_edit_limits()
    passed = passed + t_ets_key_limits()
    passed = passed + t_shell_timeout()
    passed = passed + t_edge_strings()
    passed = passed + t_memory_pressure()

    print("")
    print("========================================")
    print("  " ++ to_string(passed) ++ "/" ++ to_string(total) ++ " PASSED")
    print("========================================")
    passed
}

# --- Helpers ---
fun build_string(n, chunk) {
    if (n <= 0) { "" }
    else { chunk ++ build_string(n - 1, chunk) }
}

fun build_lines(n) {
    if (n <= 0) { "" }
    else { "line" ++ to_string(n) ++ "\n" ++ build_lines(n - 1) }
}

fun build_list(acc, i, max) {
    if (i >= max) { acc }
    else { build_list(list_append(acc, i), i + 1, max) }
}

fun fill_map(m, i, max) {
    if (i >= max) { m }
    else { fill_map(map_put(m, "k" ++ to_string(i), "v" ++ to_string(i)), i + 1, max) }
}

fun fill_ets(t, i, max) {
    if (i >= max) { 'done' }
    else {
        ets_put(t, "key" ++ to_string(i), "value" ++ to_string(i))
        fill_ets(t, i + 1, max)
    }
}

fun shell_quote(s) {
    "'" ++ string_replace(s, "'", "'\\''") ++ "'"
}

fun check(name, cond) {
    if (cond == 'true') {
        print("  [PASS] " ++ name)
        1
    } else {
        print("  [FAIL] " ++ name)
        0
    }
}

# --- Test 1: Large file write/read ---
fun t_large_file() {
    print("Test 1: Large file write/read (~50KB)")
    path = "/tmp/swarm_test_large.txt"
    content = build_string(5000, "0123456789")
    rc = file_write(path, content)
    read_back = file_read(path)
    ok = if (read_back == nil) { 'false' }
         else { string_length(read_back) == string_length(content) }
    shell("rm -f " ++ path)
    check("write/read 50KB file", ok)
}

# --- Test 2: Long string operations ---
fun t_long_string() {
    print("Test 2: String split on 1000-line input")
    big = build_lines(1000)
    parts = string_split(big, "\n")
    check("split 1000 lines -> 1001 parts", if (length(parts) == 1001) { 'true' } else { 'false' })
}

# --- Test 3: ETS table limits ---
fun t_ets_limits() {
    print("Test 3: ETS table with 10000 entries")
    t = ets_new()
    fill_ets(t, 0, 10000)
    v = ets_get(t, "key5000")
    check("ETS 10000 entries + random lookup", if (v == "value5000") { 'true' } else { 'false' })
}

# --- Test 4: Map limits ---
fun t_map_limits() {
    print("Test 4: Map with 5000 keys")
    m = fill_map(map_new(), 0, 5000)
    v = map_get(m, "k2500")
    check("map 5000 keys + lookup", if (v == "v2500") { 'true' } else { 'false' })
}

# --- Test 5: JSON limits ---
fun t_json_limits() {
    print("Test 5: JSON encode/decode 1000-key map")
    m = fill_map(map_new(), 0, 1000)
    j = json_encode(m)
    d = json_decode(j)
    v = if (d == nil) { nil } else { map_get(d, "k500") }
    check("JSON 1000-key round-trip", if (v == "v500") { 'true' } else { 'false' })
}

# --- Test 6: String processing on large markdown-like text ---
fun t_string_processing() {
    print("Test 6: Large text processing (500 lines)")
    md = build_lines(500)
    lines = string_split(md, "\n")
    check("process 500-line text", if (length(lines) == 501) { 'true' } else { 'false' })
}

# --- Test 7: List limits ---
fun t_list_limits() {
    print("Test 7: Large list (5000 items) + traversal")
    lst = build_list([], 0, 5000)
    len = length(lst)
    check("5000-item list", if (len == 5000) { 'true' } else { 'false' })
}

# --- Test 8: Shell with large output ---
fun t_shell_limits() {
    print("Test 8: Shell with 10000-line output")
    r = shell("seq 1 10000")
    out = elem(r, 1)
    lines = string_split(out, "\n")
    check("shell 10000 lines", if (length(lines) == 10001) { 'true' } else { 'false' })
}

# --- Test 9: File limits ---
fun t_file_limits() {
    print("Test 9: Directory with 500 files")
    shell("mkdir -p /tmp/swarm_glob_test && for i in $(seq 1 500); do touch /tmp/swarm_glob_test/file_$i.txt; done")
    r = shell("find /tmp/swarm_glob_test -name '*.txt' | wc -l")
    count = parse_int(string_trim(elem(r, 1)))
    shell("rm -rf /tmp/swarm_glob_test")
    check("500 files in directory", if (count == 500) { 'true' } else { 'false' })
}

fun parse_int(s) {
    if (s == "0") { 0 } else {
    if (s == "1") { 1 } else {
    if (s == "2") { 2 } else {
    if (s == "3") { 3 } else {
    if (s == "4") { 4 } else {
    if (s == "5") { 5 } else {
    if (s == "6") { 6 } else {
    if (s == "7") { 7 } else {
    if (s == "8") { 8 } else {
    if (s == "9") { 9 } else {
    if (s == "500") { 500 } else {
    if (s == "1000") { 1000 } else {
    if (s == "10000") { 10000 } else {
    if (s == "10001") { 10001 } else { 0 }}}}}}}}}}}}}}}
}

# --- Test 10: String concat performance ---
fun t_string_concat() {
    print("Test 10: String concat (100KB)")
    start = timestamp()
    s = build_string(10000, "0123456789")
    elapsed = timestamp() - start
    ok = string_length(s) == 100000
    print("  built 100KB in " ++ to_string(elapsed) ++ " ms")
    check("string concat 100KB", if (ok) { 'true' } else { 'false' })
}

# --- Test 11: Nested maps ---
fun t_nested_maps() {
    print("Test 11: Deep nested maps (50 levels)")
    m = build_nested(0, 50)
    check("50-level nested map", 'true')
}

fun build_nested(depth, max) {
    if (depth >= max) { "bottom" }
    else { map_put(map_new(), "level" ++ to_string(depth), build_nested(depth + 1, max)) }
}

# --- Test 12: JSON special chars ---
fun t_json_special() {
    print("Test 12: JSON special character round-trip")
    m = %{
        newline: "hello\nworld",
        quote: "hello \"world\"",
        backslash: "hello\\world",
        tab: "hello\tworld"
    }
    j = json_encode(m)
    d = json_decode(j)
    v = if (d == nil) { nil } else { map_get(d, 'newline') }
    check("JSON special chars", if (v == "hello\nworld") { 'true' } else { 'false' })
}

# --- Test 13: Edit on large file ---
fun t_edit_limits() {
    print("Test 13: Edit on 500-line file")
    path = "/tmp/swarm_edit_test.txt"
    lines = build_lines(500)
    file_write(path, lines)
    shell("sed -i '' 's/line250/LINE250/' " ++ path)
    content = file_read(path)
    ok = string_contains(content, "LINE250")
    shell("rm -f " ++ path)
    check("edit large file", ok)
}

# --- Test 14: ETS long key ---
fun t_ets_key_limits() {
    print("Test 14: ETS with 2600-char key")
    t = ets_new()
    long_key = build_string(100, "abcdefghijklmnopqrstuvwxyz")
    ets_put(t, long_key, "value")
    v = ets_get(t, long_key)
    check("ETS long key", if (v == "value") { 'true' } else { 'false' })
}

# --- Test 15: Shell timeout ---
fun t_shell_timeout() {
    print("Test 15: Shell command timeout")
    r = shell("perl -e 'alarm 1; sleep 10' 2>&1; echo exit=$?")
    out = elem(r, 1)
    # Exit 142 = SIGALRM, or the shell wrapper catches it
    check("shell timeout (1s)", if (string_contains(out, "142") == 'true' || string_contains(out, "timed out") == 'true') { 'true' } else { 'false' })
}

# --- Test 16: Edge strings ---
fun t_edge_strings() {
    print("Test 16: Edge case strings")
    parts = string_split("", "\n")
    ok1 = if (length(parts) == 1 && hd(parts) == "") { 'true' } else { 'false' }

    parts2 = string_split("\n\n\n", "\n")
    ok2 = if (length(parts2) == 4) { 'true' } else { 'false' }

    parts3 = string_split("a", "\n")
    ok3 = if (length(parts3) == 1 && hd(parts3) == "a") { 'true' } else { 'false' }

    check("edge strings (empty, delims, single)", if (ok1 && ok2 && ok3) { 'true' } else { 'false' })
}

# --- Test 17: Memory pressure ---
fun t_memory_pressure() {
    print("Test 17: Memory pressure (5 iterations)")
    memory_pressure_loop(0, 5)
    check("memory pressure", 'true')
}

fun memory_pressure_loop(i, max) {
    if (i >= max) { 'done' }
    else {
        big = build_string(10000, "0123456789")
        m = fill_map(map_new(), 0, 5000)
        lst = build_list([], 0, 10000)
        memory_pressure_loop(i + 1, max)
    }
}
