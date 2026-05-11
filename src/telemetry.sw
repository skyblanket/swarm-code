module Telemetry

# ============================================================
# Telemetry — system stats (CPU, memory, disk, uptime)
# ============================================================
#
# sys_stats() runs real shell commands and parses the output. No
# hallucination — Swarm can actually see the machine it's running on.
# Works on macOS (darwin). Linux fallback where possible.

export [sys_stats, disk_usage, mem_free, uptime_info, cpu_load]

fun sys_stats() {
    cpu = cpu_load()
    mem = mem_free()
    disk = disk_usage()
    up = uptime_info()
    "cpu       " ++ cpu ++ "\n" ++
    "memory    " ++ mem ++ "\n" ++
    "disk      " ++ disk ++ "\n" ++
    "uptime    " ++ up
}

# ----- CPU load via `uptime` (works on both darwin and linux) -----
fun cpu_load() {
    r = shell("uptime | sed 's/.*load averages*: //'")
    out = string_trim(elem(r, 1))
    if (string_length(out) == 0) { "unknown" } else { out }
}

# ----- Memory: use vm_stat on darwin, free on linux -----
fun mem_free() {
    is_darwin = shell("uname -s | grep -q Darwin && echo yes || echo no")
    darwin_flag = string_trim(elem(is_darwin, 1))
    if (darwin_flag == "yes") {
        mem_free_darwin()
    } else {
        mem_free_linux()
    }
}

fun mem_free_darwin() {
    # vm_stat reports pages; page size is 4096 or 16384 depending on chip
    cmd = "vm_stat | awk '/Pages free/{free=$3} /Pages active/{active=$3} " ++
          "/Pages wired/{wired=$4} END{" ++
          "gsub(/\\./,\"\",free); gsub(/\\./,\"\",active); gsub(/\\./,\"\",wired);" ++
          "ps = 16384; " ++
          "free_mb = (free*ps)/1024/1024; " ++
          "used_mb = ((active+wired)*ps)/1024/1024; " ++
          "printf \"%d MB free, %d MB used\", free_mb, used_mb}'"
    r = shell(cmd)
    out = string_trim(elem(r, 1))
    if (string_length(out) == 0) { "unknown" } else { out }
}

fun mem_free_linux() {
    r = shell("free -m | awk '/^Mem:/{printf \"%s MB free, %s MB used\", $7, $3}'")
    out = string_trim(elem(r, 1))
    if (string_length(out) == 0) { "unknown" } else { out }
}

# ----- Disk usage of the cwd -----
fun disk_usage() {
    r = shell("df -h . | awk 'NR==2{printf \"%s used of %s (%s free)\", $3, $2, $4}'")
    out = string_trim(elem(r, 1))
    if (string_length(out) == 0) { "unknown" } else { out }
}

# ----- Uptime (system) -----
fun uptime_info() {
    r = shell("uptime | sed 's/,.*//' | sed 's/^.*up //'")
    out = string_trim(elem(r, 1))
    if (string_length(out) == 0) { "unknown" } else { out }
}
