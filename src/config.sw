module Config

import Util
import CommandGuard
import Hooks

# ============================================================
# Config — settings.json, SWARM.md, permissions, hooks
# ============================================================
#
# Settings are loaded from two locations and merged:
#   1. $HOME/.swarm-code/settings.json          (user-global)
#   2. ./.swarm-code.json                       (project-local, overrides)
#
# The project file arrives with whatever repo you cloned, so it is NOT
# trusted by default: only harmless keys apply and permissions may only
# tighten (see project_scope). Listing the directory under
# "trusted_projects" in the user settings lets it apply in full.
#
# Project context is loaded from the first that exists:
#   1. ./SWARM.md                               (swarm-code's preferred name)
#   2. ./CLAUDE.md                              (fallback, most repos have one)
#
# Example settings.json:
# {
#   "model": "google/gemma-4-31B-it",
#   "endpoint": "http://sushi:8000",
#   "permissions": {
#     "bash": "ask",
#     "write": "allow",
#     "edit": "allow",
#     "read": "allow"
#   },
#   "hooks": {
#     "PreToolUse": [
#       {"matcher": "bash", "command": "echo pre"}
#     ],
#     "PostToolUse": [...]
#   }
# }

export [load, load_project_context, check_permission, run_hooks, is_dangerous_bash, is_hardline_bash,
        llm_timeout_ms, project_scope, project_ignored_keys, is_trusted_dir, project_notice,
        set_trusted, set_trusted_at, trusted_list, project_gated_keys, join_names,
        endpoint_host, is_local_endpoint, endpoint_refusal,
        command_of, command_risk, denial_message, denial_reason, uses_sudo,
        run_hooks_verdict]

# ------------------------------------------------------------
# load settings — merged map from user + project config files
# ------------------------------------------------------------
fun load() {
    user_settings = load_one(user_settings_path())
    project_settings = load_one(project_settings_path())
    trusted = project_trusted(user_settings, project_settings)
    map_merge(user_settings, project_scope(user_settings, project_settings, trusted))
}

fun user_settings_path()    { getenv("HOME") ++ "/.swarm-code/settings.json" }
fun project_settings_path() { "./.swarm-code.json" }

fun load_one(path) {
    if (file_exists(path) == 'false') {
        map_new()
    } else {
        file_content = file_read(path)
        if (file_content == nil) {
            map_new()
        } else {
            # A non-object top level ("[]", "1") would crash map_merge.
            decoded = json_decode(file_content)
            if (decoded == nil || is_map(decoded) != 'true') { map_new() } else { decoded }
        }
    }
}

# ------------------------------------------------------------
# Project scope — what a repo's ./.swarm-code.json may contribute.
# ------------------------------------------------------------
# Opening swarm-code inside a cloned repo must not hand that repo's
# author control of the session. Unless the directory is trusted, the
# project file may NOT:
#   * run commands            — hooks (SessionStart fires at launch)
#   * start processes         — mcpServers
#   * redirect the prompt     — endpoint, api_key, providers, profiles,
#                               fallback_profile
#   * loosen permissions      — a "permissions" entry only applies when
#                               it is STRICTER (allow < ask < deny) than
#                               what the user would otherwise get
# It is an ALLOW-list (project_safe_keys), so a key added later is
# ignored from project scope until someone decides it is harmless.
#
# Opt-in — user settings only, a project can never trust itself:
#   "trusted_projects": ["/abs/path/to/repo", ...]
# in ~/.swarm-code/settings.json; that directory's file applies in full.
# ------------------------------------------------------------
fun project_safe_keys() {
    ["model", "max_tokens", "llm_timeout_ms", "chat_template_kwargs", "vision"]
}

# The part of `project` that may be merged over `user`. trusted='true'
# returns the project unchanged (the old full-override behaviour).
fun project_scope(user, project, trusted) {
    if (trusted == 'true') { project }
    else {
        safe = copy_keys(project, project_safe_keys(), map_new())
        pp = map_get(project, 'permissions')
        if (pp == nil || is_map(pp) != 'true') { safe }
        else { map_put(safe, 'permissions', tighten_permissions(user_perms(user), pp)) }
    }
}

fun copy_keys(src, keys, acc) {
    if (length(keys) == 0) { acc }
    else {
        k = hd(keys)
        v = map_get(src, k)
        next = if (v == nil) { acc } else { map_put(acc, k, v) }
        copy_keys(src, tl(keys), next)
    }
}

fun user_perms(user) {
    up = map_get(user, 'permissions')
    if (up == nil || is_map(up) != 'true') { map_new() } else { up }
}

# User permissions plus every project entry that is stricter than the
# user's effective decision for that tool (configured, else the default).
fun tighten_permissions(uperms, pperms) {
    tighten_loop(map_keys(pperms), map_values(pperms), uperms, uperms)
}

fun tighten_loop(keys, vals, uperms, acc) {
    if (length(keys) == 0) { acc }
    else {
        k = hd(keys)
        next = if (perm_stricter(hd(vals), effective_user_perm(uperms, k)) == 'true') {
            map_put(acc, k, hd(vals))
        } else { acc }
        tighten_loop(tl(keys), tl(vals), uperms, next)
    }
}

fun effective_user_perm(uperms, tool) {
    cur = map_get(uperms, tool)
    if (cur == nil) { default_permission(tool) } else { string_to_perm(cur) }
}

# 'true' when the configured value v is stricter than the decision `cur`.
fun perm_stricter(v, cur) {
    if (perm_rank(string_to_perm(v)) > perm_rank(cur)) { 'true' } else { 'false' }
}

fun perm_rank(p) {
    if (p == 'deny') { 2 } else { if (p == 'ask') { 1 } else { 0 }}
}

# Names of the project keys project_scope drops for an untrusted dir —
# "permissions.<tool>" for a loosening entry. [] when nothing is lost.
fun project_ignored_keys(user, project) {
    ignored_loop(map_keys(project), project, user, [])
}

fun ignored_loop(keys, project, user, acc) {
    if (length(keys) == 0) { acc }
    else {
        k = hd(keys)
        ks = to_string(k)
        next = if (list_has(project_safe_keys(), ks) == 'true') { acc }
               else { if (ks == "permissions") {
                   pp = map_get(project, k)
                   if (pp == nil || is_map(pp) != 'true') { list_append(acc, ks) }
                   else { acc ++ loosening_keys(map_keys(pp), map_values(pp), user_perms(user), []) }
               }
               else { list_append(acc, ks) }}
        ignored_loop(tl(keys), project, user, next)
    }
}

fun loosening_keys(keys, vals, uperms, acc) {
    if (length(keys) == 0) { acc }
    else {
        k = hd(keys)
        cur = effective_user_perm(uperms, k)
        next = if (perm_rank(string_to_perm(hd(vals))) < perm_rank(cur)) {
            list_append(acc, "permissions." ++ to_string(k))
        } else { acc }
        loosening_keys(tl(keys), tl(vals), uperms, next)
    }
}

fun join_names(names, acc) {
    if (length(names) == 0) { acc }
    else {
        sep = if (string_length(acc) == 0) { "" } else { ", " }
        join_names(tl(names), acc ++ sep ++ to_string(hd(names)))
    }
}

fun list_has(lst, x) {
    if (length(lst) == 0) { 'false' }
    else { if (hd(lst) == x) { 'true' } else { list_has(tl(lst), x) }}
}

# Is the current directory listed in the user's "trusted_projects"?
# Costs one shell() (for the real cwd), paid only when there IS a
# project file and the user HAS a trust list.
fun project_trusted(user, project) {
    tp = map_get(user, 'trusted_projects')
    if (map_size(project) == 0 || tp == nil || is_list(tp) != 'true') { 'false' }
    else {
        # Both spellings of the cwd: logical (symlinks kept, as the user
        # typed it) and physical (pwd -P), so either form of entry matches.
        cwds = string_split(string_trim(to_string(elem(shell("pwd; pwd -P"), 1))), "\n")
        is_trusted_dir(tp, cwds)
    }
}

# Pure core of project_trusted: does any entry of `trusted` equal any
# of `cwds` (trailing slashes ignored)? Entries are absolute paths.
fun is_trusted_dir(trusted, cwds) {
    if (length(trusted) == 0) { 'false' }
    else {
        t = strip_trailing_slash(string_trim(to_string(hd(trusted))))
        if (string_length(t) > 0 && dir_in(cwds, t) == 'true') { 'true' }
        else { is_trusted_dir(tl(trusted), cwds) }
    }
}

fun dir_in(cwds, t) {
    if (length(cwds) == 0) { 'false' }
    else { if (strip_trailing_slash(string_trim(to_string(hd(cwds)))) == t) { 'true' }
    else { dir_in(tl(cwds), t) }}
}

fun strip_trailing_slash(s) {
    if (string_length(s) > 1 && string_ends_with(s, "/") == 'true') {
        strip_trailing_slash(string_sub(s, 0, string_length(s) - 1))
    } else { s }
}

# ------------------------------------------------------------
# swarm-code trust / untrust — edit "trusted_projects" for the user.
# ------------------------------------------------------------
# set_trusted_at(settings_path, dir, add) → {'ok', abs_dir, changed} |
# {'error', message}. `dir` is resolved to an absolute path (cd + pwd, so
# symlinks and relative paths work); add='true' appends it once,
# add='false' removes every matching entry. Every other key in the file
# is kept, and a settings.json that doesn't parse as an object is never
# overwritten (the user would lose it) — the error says to fix it first.
fun set_trusted_at(settings_path, dir, add) {
    r = shell("cd " ++ Util.shell_q(to_string(dir)) ++ " 2>/dev/null && pwd")
    abs = string_trim(to_string(elem(r, 1)))
    if (elem(r, 0) != 0 || string_length(abs) == 0) {
        {'error', "no such directory: " ++ to_string(dir)}
    } else {
        raw = if (file_exists(settings_path) == 'true') { file_read(settings_path) } else { nil }
        decoded = if (raw == nil || string_length(string_trim(raw)) == 0) { map_new() } else { json_decode(raw) }
        if (decoded == nil || is_map(decoded) != 'true') {
            {'error', settings_path ++ " is not a valid JSON object — fix it by hand first " ++
                      "(swarm-code won't overwrite it)"}
        } else {
            cur = map_get(decoded, 'trusted_projects')
            tp = if (cur != nil && is_list(cur) == 'true') { cur } else { [] }
            had = is_trusted_dir(tp, [abs])
            next = if (add == 'true') {
                if (had == 'true') { tp } else { list_append(tp, abs) }
            } else { drop_dir(tp, abs, []) }
            changed = if (add == 'true') { bool_not_str(had) } else { had }
            if (changed == 'false') { {'ok', abs, 'false'} }
            else {
                file_mkdir(dirname_of(settings_path))
                rc = file_atomic_write(settings_path, Util.json_pretty(map_put(decoded, 'trusted_projects', next)))
                if (rc == 'ok') { {'ok', abs, 'true'} }
                else { {'error', "could not write " ++ settings_path} }
            }
        }
    }
}

fun set_trusted(dir, add) { set_trusted_at(user_settings_path(), dir, add) }

fun trusted_list() {
    tp = map_get(load_one(user_settings_path()), 'trusted_projects')
    if (tp != nil && is_list(tp) == 'true') { tp } else { [] }
}

fun drop_dir(tp, abs, acc) {
    if (length(tp) == 0) { acc }
    else {
        t = strip_trailing_slash(string_trim(to_string(hd(tp))))
        next = if (t == abs) { acc } else { list_append(acc, hd(tp)) }
        drop_dir(tl(tp), abs, next)
    }
}

fun bool_not_str(b) { if (b == 'true') { 'false' } else { 'true' } }

fun dirname_of(p) {
    i = last_slash(p, string_length(p) - 1)
    if (i <= 0) { "/" } else { string_sub(p, 0, i) }
}

fun last_slash(p, i) {
    if (i < 0) { 0 - 1 }
    else { if (string_sub(p, i, 1) == "/") { i } else { last_slash(p, i - 1) } }
}

# The keys a directory's .swarm-code.json sets that only apply once it is
# trusted — shown by `swarm-code trust` so the user sees what they grant.
fun project_gated_keys(dir) {
    project = load_one(to_string(dir) ++ "/.swarm-code.json")
    if (map_size(project) == 0) { nil }
    else { project_ignored_keys(map_new(), project) }
}

# One-line notice naming what an untrusted ./.swarm-code.json tried to
# set, or nil when nothing was dropped. main prints it once at startup.
fun project_notice() {
    project = load_one(project_settings_path())
    if (map_size(project) == 0) { nil }
    else {
        user = load_one(user_settings_path())
        if (project_trusted(user, project) == 'true') { nil }
        else {
            ignored = project_ignored_keys(user, project)
            if (length(ignored) == 0) { nil }
            else {
                "./.swarm-code.json: ignored untrusted project settings (" ++
                join_names(ignored, "") ++ ") — if you trust this repo, run " ++
                "`swarm-code trust` here (or /trust) and restart"
            }
        }
    }
}

# ------------------------------------------------------------
# Network isolation — may this LLM endpoint URL be dialed?
# ------------------------------------------------------------
# The ONE local-network check, used by main.sw's startup gate (primary
# endpoint) and by llm.sw at the point of dial, so fallback, providers[]
# and ~/.swarm-code/.profile_override endpoints get the same treatment.
# The URL is read the way curl will read it and anything ambiguous is
# refused:
#   * scheme http:// or https:// only (any case)
#   * no userinfo: curl dials "http://127.0.0.1@evil" at evil, so an '@'
#     anywhere in the authority is refused outright
#   * host lowercased, port (digits only) stripped, host chars limited
#     to [a-z0-9._-] — no %-escapes, braces or other curl-isms
#   * IPv6 only in brackets, and only ::1, fc00::/7 and fe80::/10
#   * a host whose LAST label is numeric (or 0x…) is an IPv4 literal and
#     must be a strict dotted quad: curl dials 3221225985, 0x7f.1 and
#     010.0.0.1 (octal) as other addresses than they appear to be
#   * names: localhost, *.local (mDNS), *.ts.net, or a bare dot-less
#     name (MagicDNS / /etc/hosts) — "127.0.0.1.evil.com" is a name
# IPv4: loopback 127/8, RFC1918 10/8 172.16/12 192.168/16, CGNAT 100.64/10.
# ------------------------------------------------------------

# nil when `url` may be dialed, else a one-line refusal reason. The only
# opt-out is SWARM_CODE_ALLOW_REMOTE=1 — an API key alone is not one.
fun endpoint_refusal(url) {
    if (getenv("SWARM_CODE_ALLOW_REMOTE") == "1") { nil }
    else { if (is_local_endpoint(url) == 'true') { nil }
    else {
        host = endpoint_host(url)
        why = if (host == nil) { "not a plain http(s)://host[:port] URL" }
              else { "host " ++ host ++ " is not on the local network" }
        "network isolation: refusing to contact " ++ to_string(url) ++ " (" ++ why ++
        ") — set SWARM_CODE_ALLOW_REMOTE=1 to allow remote endpoints"
    }}
}

fun is_local_endpoint(url) {
    host = endpoint_host(url)
    if (host == nil) { 'false' } else { is_local_host(host) }
}

# Lowercased host of an http(s) URL (an IPv6 literal without brackets),
# or nil when the URL is not a plain http(s)://host[:port][/...] form.
fun endpoint_host(url) {
    s = string_lower(string_trim(to_string(url)))
    rest = if (string_starts_with(s, "http://") == 'true') { string_sub(s, 7, string_length(s) - 7) }
           else { if (string_starts_with(s, "https://") == 'true') { string_sub(s, 8, string_length(s) - 8) }
           else { nil }}
    if (rest == nil) { nil }
    else {
        auth = authority_of(rest, 0, string_length(rest))
        if (string_length(auth) == 0 || string_contains(auth, "@") == 'true') { nil }
        else { host_of_authority(auth) }
    }
}

# Everything before the first '/', '?' or '#'.
fun authority_of(s, i, n) {
    if (i >= n) { s }
    else {
        ch = string_sub(s, i, 1)
        if (ch == "/" || ch == "?" || ch == "#") { string_sub(s, 0, i) }
        else { authority_of(s, i + 1, n) }
    }
}

fun host_of_authority(a) {
    if (string_starts_with(a, "[") == 'true') {
        close = string_index_of(a, "]")
        if (close < 0) { nil }
        else {
            inner = string_sub(a, 1, close - 1)
            port_part = string_sub(a, close + 1, string_length(a) - close - 1)
            if (valid_port_suffix(port_part) == 'true' && string_contains(inner, ":") == 'true' &&
                all_chars_in(inner, "0123456789abcdef:.") == 'true') { inner }
            else { nil }
        }
    } else {
        colon = string_index_of(a, ":")
        host = if (colon < 0) { a } else { string_sub(a, 0, colon) }
        port_part = if (colon < 0) { "" } else { string_sub(a, colon, string_length(a) - colon) }
        if (valid_port_suffix(port_part) == 'true' && valid_hostname(host) == 'true') { host }
        else { nil }
    }
}

# "" or ':' followed by 1-5 digits.
fun valid_port_suffix(s) {
    n = string_length(s)
    if (n == 0) { 'true' }
    else { if (string_starts_with(s, ":") == 'true' && n >= 2 && n <= 6) {
        all_chars_in(string_sub(s, 1, n - 1), "0123456789")
    } else { 'false' }}
}

# Non-empty, dot-separated labels of [a-z0-9_-].
fun valid_hostname(h) {
    if (string_length(h) == 0) { 'false' }
    else { if (all_chars_in(h, "abcdefghijklmnopqrstuvwxyz0123456789.-_") == 'false') { 'false' }
    else { if (string_starts_with(h, ".") == 'true' || string_ends_with(h, ".") == 'true' ||
               string_contains(h, "..") == 'true') { 'false' }
    else { 'true' }}}
}

fun all_chars_in(s, allowed) { aci_loop(s, allowed, 0, string_length(s)) }

fun aci_loop(s, allowed, i, n) {
    if (i >= n) { 'true' }
    else { if (string_contains(allowed, string_sub(s, i, 1)) == 'true') { aci_loop(s, allowed, i + 1, n) }
    else { 'false' }}
}

# `h` is a validated, lowercased host from endpoint_host.
fun is_local_host(h) {
    if (string_contains(h, ":") == 'true') { is_local_ipv6(h) }
    else { if (ipv4_like(h) == 'true') { is_private_ipv4(h) }
    else { is_local_name(h) }}
}

# The last label decides: numeric (or 0x-hex) means curl parses the whole
# host as an IPv4 address, however few dots it has.
fun ipv4_like(h) {
    last = last_label(h, string_length(h) - 1)
    if (string_starts_with(last, "0x") == 'true') { 'true' }
    else { all_chars_in(last, "0123456789") }
}

fun last_label(h, i) {
    if (i < 0) { h }
    else { if (string_sub(h, i, 1) == ".") { string_sub(h, i + 1, string_length(h) - i - 1) }
    else { last_label(h, i - 1) }}
}

fun is_private_ipv4(h) {
    parts = string_split(h, ".")
    if (length(parts) != 4) { 'false' }
    else { if (strict_octets(parts) == 'false') { 'false' }
    else {
        a = to_int(hd(parts))
        b = to_int(hd(tl(parts)))
        if (a == 127 || a == 10) { 'true' }
        else { if (a == 192 && b == 168) { 'true' }
        else { if (a == 172 && b >= 16 && b <= 31) { 'true' }
        else { if (a == 100 && b >= 64 && b <= 127) { 'true' }
        else { 'false' }}}}
    }}
}

# Decimal 0-255, 1-3 digits, no leading zero (curl reads 010 as octal 8).
fun strict_octets(parts) {
    if (length(parts) == 0) { 'true' }
    else {
        p = hd(parts)
        n = string_length(p)
        ok = if (n < 1 || n > 3) { 'false' }
             else { if (all_chars_in(p, "0123456789") == 'false') { 'false' }
             else { if (n > 1 && string_starts_with(p, "0") == 'true') { 'false' }
             else { if (to_int(p) > 255) { 'false' } else { 'true' }}}}
        if (ok == 'true') { strict_octets(tl(parts)) } else { 'false' }
    }
}

# Loopback, ULA fc00::/7, link-local fe80::/10. The first group must be
# written out in full: "fd::1" is 00fd::1 — a public address.
fun is_local_ipv6(h) {
    if (h == "::1" || h == "0:0:0:0:0:0:0:1") { 'true' }
    else {
        colon = string_index_of(h, ":")
        first = if (colon < 0) { h } else { string_sub(h, 0, colon) }
        if (string_length(first) != 4) { 'false' }
        else {
            p2 = string_sub(first, 0, 2)
            p3 = string_sub(first, 0, 3)
            if (p2 == "fc" || p2 == "fd") { 'true' }
            else { if (p3 == "fe8" || p3 == "fe9" || p3 == "fea" || p3 == "feb") { 'true' }
            else { 'false' }}
        }
    }
}

fun is_local_name(h) {
    if (h == "localhost") { 'true' }
    else { if (string_ends_with(h, ".local") == 'true') { 'true' }
    else { if (string_ends_with(h, ".ts.net") == 'true') { 'true' }
    # Bare (dot-less) name: mDNS / Tailscale MagicDNS / /etc/hosts. It can't
    # be told apart from a public bare host without DNS; on dev machines the
    # local case is overwhelmingly the common one.
    else { string_contains(h, ".") == 'false' }}}
}

# ------------------------------------------------------------
# llm_timeout_ms — inactivity window (ms) for the worker-routed LLM
# stream (llm.sw stream_call). If no stream message (chunk / reason /
# done / result) arrives within this window the in-flight call is
# treated as a TRANSIENT failure (hung connection) so the normal
# retry/backoff engages — closing the "a hung connection blocks the
# turn forever" hole. A coarse total deadline of 3x this value bounds
# even a trickling-but-never-finishing stream.
#
# Priority: SWARM_CODE_LLM_TIMEOUT_MS env → settings.json
# "llm_timeout_ms" → 300000 (5 minutes) default.
# ------------------------------------------------------------
fun llm_timeout_ms(opts) {
    env = getenv("SWARM_CODE_LLM_TIMEOUT_MS")
    env_n = if (env == nil) { 0 - 1 } else { parse_pos_int_cfg(to_string(env), 0, 0, 'false') }
    if (env_n > 0) { env_n }
    else {
        settings = map_get(opts, 'settings')
        sv = if (settings == nil) { nil } else { map_get(settings, 'llm_timeout_ms') }
        sn = if (sv == nil) { 0 - 1 } else { parse_pos_int_cfg(to_string(sv), 0, 0, 'false') }
        if (sn > 0) { sn } else { 300000 }
    }
}

# Positive-int parser (same pattern as agent.sw parse_budget_env /
# llm.sw parse_positive_int_local — kept local so config.sw stays
# dependency-free). Returns -1 when the string holds no leading digits.
fun parse_pos_int_cfg(s, i, acc, saw_digit) {
    if (i >= string_length(s)) {
        if (saw_digit == 'true') { acc } else { 0 - 1 }
    } else {
        ch = string_sub(s, i, 1)
        d = if (ch == "0") { 0 } else { if (ch == "1") { 1 }
            else { if (ch == "2") { 2 } else { if (ch == "3") { 3 }
            else { if (ch == "4") { 4 } else { if (ch == "5") { 5 }
            else { if (ch == "6") { 6 } else { if (ch == "7") { 7 }
            else { if (ch == "8") { 8 } else { if (ch == "9") { 9 }
            else { 0 - 1 }}}}}}}}}}
        if (d < 0) {
            if (saw_digit == 'true') { acc } else { 0 - 1 }
        } else {
            parse_pos_int_cfg(s, i + 1, acc * 10 + d, 'true')
        }
    }
}

# ------------------------------------------------------------
# load SWARM.md or CLAUDE.md from cwd — returns "" if neither exists
# ------------------------------------------------------------
fun load_project_context() {
    if (file_exists("./SWARM.md") == 'true') {
        swarm_md = file_read("./SWARM.md")
        if (swarm_md == nil) { "" } else { swarm_md }
    } else {
        if (file_exists("./CLAUDE.md") == 'true') {
            claude_md = file_read("./CLAUDE.md")
            if (claude_md == nil) { "" } else { claude_md }
        } else {
            ""
        }
    }
}

# ------------------------------------------------------------
# Permissions — decide whether a tool call should run.
# Returns an atom: 'allow', 'deny', or 'ask'.
#
# Policy:
#   1. Default-allow for every BUILT-IN tool. The user explicitly asked
#      for "all allowed by default" — prompting on every bash/write/edit
#      was breaking flow during tool test runs. The one exception is MCP
#      tools (mcp__*): being external and unvetted, they default to 'ask'
#      so the user is prompted on first use (see default_permission).
#   2. settings.permissions[tool_name] in settings.json can downgrade
#      a specific tool to 'ask' or 'deny' if the user wants tighter
#      control on one tool (e.g. "bash": "ask").
#   3. Every tool that runs a model-supplied shell command (command_of:
#      bash, background, bg_server, run_tests.command) goes through the
#      CommandGuard classifier, which parses the command like sh does:
#        * hardline  (rm -r on /, mkfs, dd to a raw disk, halt/reboot,
#          chmod -R on /, fork bomb) → 'deny', unconditionally — before
#          any settings/env lookup, so SWARM_CODE_ALLOW_DANGEROUS=1
#          cannot turn it off.
#        * dangerous (sudo, rm -rf on ~ or a system path, dd to a
#          device) → escalates 'allow' to 'ask' (a configured 'deny'
#          stays 'deny'); 'deny' outright when SWARM_CODE_DENY_DANGEROUS=1
#          (unattended /flows children); skipped entirely when
#          SWARM_CODE_ALLOW_DANGEROUS=1.
#      denial_message() names the matched pattern so the model can adapt.
# ------------------------------------------------------------
fun check_permission(tool_name, args, opts) {
    risk = command_risk(tool_name, args)
    level = elem(risk, 0)
    if (level == 'hardline') {
        'deny'
    }
    else {
        decision = configured_decision(tool_name, opts)

        # Headless denies an 'ask' unless SWARM_CODE_HEADLESS_APPROVE=1
        # (agent.resolve_permission); SWARM_CODE_DENY_DANGEROUS=1 (set for
        # /flows fan-out and scheduled children) makes this a hard deny
        # even then.
        if (level == 'dangerous' && dangerous_bypassed() == 'false') {
            if (decision == 'deny') { 'deny' }
            else { if (getenv("SWARM_CODE_DENY_DANGEROUS") == "1") { 'deny' } else { 'ask' } }
        } else {
            decision
        }
    }
}

# settings.permissions[tool] if set, else the built-in default.
fun configured_decision(tool_name, opts) {
    settings = if (opts == nil) { nil } else { map_get(opts, 'settings') }
    perms = if (settings == nil) { nil } else { map_get(settings, 'permissions') }
    # settings.json is decoded with atom keys, so pass tool_name directly.
    configured = if (perms == nil) { nil } else { map_get(perms, tool_name) }
    if (configured != nil) { string_to_perm(configured) } else { default_permission(tool_name) }
}

fun dangerous_bypassed() {
    if (getenv("SWARM_CODE_ALLOW_DANGEROUS") == "1") { 'true' } else { 'false' }
}

fun string_to_perm(s) {
    if (s == "allow") { 'allow' }
    else { if (s == "deny") { 'deny' }
    else { 'ask' }}
}

# Built-in tools default to 'allow' (see the check_permission comment
# block above). MCP tools (mcp__server__tool) default to 'ask' instead:
# they are external and unvetted, and unlike `bash` they get no
# dangerous-pattern gate. The session permission cache means this is
# one prompt per MCP tool, not per call; a user can still pre-authorise
# one via the settings.json permissions map
# (e.g. "mcp__github__create_issue": "allow").
fun default_permission(tool_name) {
    if (string_starts_with(to_string(tool_name), "mcp__") == 'true') { 'ask' }
    else { 'allow' }
}

# The shell command a tool call will run, or nil for tools that don't run
# one. Every tool listed here gets the same hardline/dangerous gate as bash —
# before, `background` / `bg_server` / `run_tests.command` ran ungated.
fun command_of(tool_name, args) {
    t = to_string(tool_name)
    if (args == nil || is_map(args) == 'false') { nil }
    else { if (t == "bash" || t == "background" || t == "bg_server" || t == "run_tests") {
        c = map_get(args, 'command')
        if (c == nil) { nil } else { to_string(c) }
    } else { nil }}
}

# {'hardline'|'dangerous'|'ok', reason} for a tool call.
fun command_risk(tool_name, args) {
    cmd = command_of(tool_name, args)
    if (cmd == nil) { {'ok', ""} } else { CommandGuard.risk_of(cmd) }
}

fun uses_sudo(cmd) { CommandGuard.uses_sudo(cmd) }

# "error: permission denied for tool 'X' — <why>". The why names the
# matched pattern (and the offending simple command), so the model can
# pick a narrower command instead of retrying the same call.
fun denial_message(tool_name, args, opts) {
    "error: permission denied for tool '" ++ to_string(tool_name) ++ "'" ++
        denial_reason(tool_name, args, opts)
}

fun denial_reason(tool_name, args, opts) {
    risk = command_risk(tool_name, args)
    level = elem(risk, 0)
    if (level == 'hardline') {
        " — blocked by the hardline safety floor: " ++ elem(risk, 1) ++
        ". This is never allowed (no setting or env var lifts it); use a narrower command."
    } else { if (configured_decision(tool_name, opts) == 'deny') {
        " — denied by settings.json (permissions." ++ to_string(tool_name) ++ " = \"deny\")."
    } else { if (level == 'dangerous' && dangerous_bypassed() == 'false' &&
                 getenv("SWARM_CODE_DENY_DANGEROUS") == "1") {
        " — flagged dangerous: " ++ elem(risk, 1) ++
        ". SWARM_CODE_DENY_DANGEROUS=1 is set for this unattended run, so it is denied; use a narrower command."
    } else { if (level == 'dangerous' && dangerous_bypassed() == 'false') {
        " — flagged dangerous: " ++ elem(risk, 1) ++ "; it was not approved."
    } else {
        " — not approved at the permission prompt (don't retry the same call; ask the user or try another approach)."
    }}}}
}

# Kept for callers/tests that ask about a bash args map directly.
# 'true' for dangerous OR hardline commands (a hardline command is certainly
# dangerous); 'false' when SWARM_CODE_ALLOW_DANGEROUS=1 (YOLO mode).
fun is_dangerous_bash(args) {
    if (dangerous_bypassed() == 'true') { 'false' }
    else {
        level = elem(command_risk('bash', args), 0)
        if (level == 'ok') { 'false' } else { 'true' }
    }
}

# 'true' for the unbypassable tier (see CommandGuard for the categories).
fun is_hardline_bash(args) {
    if (elem(command_risk('bash', args), 0) == 'hardline') { 'true' } else { 'false' }
}

# ------------------------------------------------------------
# Hooks — shell commands configured in settings.json.
#
# Settings shape:
#   "hooks": {
#     "PreToolUse":  [ {"matcher": "bash", "command": "..."} ],       (+ background, bg_server, run_tests, …)
#     "PostToolUse": [ {"matcher": "edit|write", "command": "..."} ], (+ multi_edit)
#     "UserPromptSubmit": [ {"command": "..."} ],
#     "Stop":            [ {"command": "..."} ]
#   }
#
# Matcher: "*" (or none) for all tools, else "|"-separated alternatives,
# each a case-insensitive substring of the tool name or a tool FAMILY —
# "bash" also fires for background/bg_server/run_tests/file_watch/log_wait,
# "edit" also for multi_edit. See matches() for the exact rules.
# Hooks receive context through the environment and stdin:
#   SWARM_CODE_EVENT, SWARM_CODE_TOOL — event and tool name
#   stdin, and the private 0600 file $SWARM_CODE_ARGS_FILE — the args JSON
#     (always; read one of these to see every call)
#   SWARM_CODE_ARGS — the same JSON inline, only when it is under 100KB;
#     above that it is unset and SWARM_CODE_ARGS_OMITTED=1
# (The args used to be spliced into the command line + env: a >128KB
# write hit E2BIG, the hook never ran, and shell() polled 120s before
# reporting a block.) Hooks time out after hook_cmd_timeout_ms().
#
# Returns 'ok' normally. Returns 'block' if any PreToolUse hook exited
# non-zero, timed out, or could not be run at all (fail closed) —
# blocking the tool call. run_hooks_verdict also says why.
# ------------------------------------------------------------
fun run_hooks(event, tool_name, args_json, opts) {
    v = run_hooks_verdict(event, tool_name, args_json, opts)
    if (v == 'ok') { 'ok' } else { 'block' }
}

# 'ok' | {'block', reason}
fun run_hooks_verdict(event, tool_name, args_json, opts) {
    settings = if (opts == nil) { nil } else { map_get(opts, 'settings') }
    if (settings == nil) { 'ok' }
    else {
        hooks = map_get(settings, 'hooks')
        if (hooks == nil) { 'ok' }
        else {
            # event is a string; hooks map has atom keys from json_decode —
            # try both. sw lacks a direct string→atom conversion in .sw, so we
            # attempt string key first then fall back by iterating all keys.
            event_hooks = map_get_either(hooks, event)
            if (event_hooks == nil) { 'ok' }
            else {
                run_matching_hooks(event_hooks, tool_name, args_json, event)
            }
        }
    }
}

# Look up a key in a map, trying string key first then comparing every
# key's string form. Handles the atom-vs-string mismatch from json_decode.
#
# NOTE: main.sw has a parallel pair — lookup_string_key/find_key_by_string —
# with the same logic plus an extra nil-map guard. Keep the core walk in sync
# if the algorithm changes; the nil guard lives there, not here.
fun map_get_either(m, key_string) {
    direct = map_get(m, key_string)
    if (direct != nil) {
        direct
    } else {
        find_by_string_key(map_keys(m), map_values(m), key_string)
    }
}

fun find_by_string_key(keys, values, target) {
    if (length(keys) == 0) {
        nil
    } else {
        k = hd(keys)
        if (to_string(k) == target) {
            hd(values)
        } else {
            find_by_string_key(tl(keys), tl(values), target)
        }
    }
}

fun run_matching_hooks(hooks_list, tool_name, args_json, event) {
    if (length(hooks_list) == 0) { 'ok' }
    else {
        hook = hd(hooks_list)
        matcher = map_get(hook, 'matcher')
        cmd = map_get(hook, 'command')
        if (cmd == nil) {
            run_matching_hooks(tl(hooks_list), tool_name, args_json, event)
        } else {
            if (matches(matcher, tool_name) == 'true') {
                result = run_hook_cmd(cmd, event, tool_name, args_json)
                if (result != 'ok') {
                    result
                } else {
                    run_matching_hooks(tl(hooks_list), tool_name, args_json, event)
                }
            } else {
                run_matching_hooks(tl(hooks_list), tool_name, args_json, event)
            }
        }
    }
}

# Matcher semantics (PreToolUse / PostToolUse):
#   nil, "", "*"   → every tool
#   "a|b" / "a,b"  → any alternative matches
#   an alternative matches a tool — case-insensitively, so Claude-Code-style
#   "Bash" / "Edit|Write" / "MultiEdit" work — when it is a substring of the
#   tool name (so "browser" covers every browser_* tool and "mcp__github"
#   every tool of that server; underscores are ignored, "WebFetch" ≈
#   "web_fetch"), or when it names a FAMILY the tool belongs to:
#     bash (or shell) → bash, background, bg_server, run_tests, file_watch,
#                       log_wait — every tool that runs a shell command or
#                       shell poll loop, so a "bash" guard hook can't be
#                       sidestepped by calling `background` instead
#     edit            → edit, multi_edit
#     multiedit       → multi_edit
# (The old check was "matcher ⊂ tool or tool ⊂ matcher" on the raw string:
# "edit|write" never fired for multi_edit, "bash" never for background.)
fun matches(matcher, tool_name) {
    if (matcher == nil) { 'true' }
    else {
        m = string_lower(string_trim(to_string(matcher)))
        if (m == "" || m == "*") { 'true' }
        else {
            alts = string_split(string_replace(m, ",", "|"), "|")
            any_alt_matches(alts, string_lower(to_string(tool_name)))
        }
    }
}

fun any_alt_matches(alts, t) {
    if (length(alts) == 0) { 'false' }
    else { if (alt_matches(string_trim(hd(alts)), t) == 'true') { 'true' }
    else { any_alt_matches(tl(alts), t) }}
}

fun alt_matches(a, t) {
    if (a == "") { 'false' }
    else { if (a == "*") { 'true' }
    else { if (hook_list_has(hook_family(a), t) == 'true') { 'true' }
    else { if (string_contains(t, a) == 'true') { 'true' }
    else { string_contains(string_replace(t, "_", ""), string_replace(a, "_", "")) }}}}
}

fun hook_family(a) {
    if (a == "bash" || a == "shell") {
        ["bash", "background", "bg_server", "run_tests", "file_watch", "log_wait"]
    } else { if (a == "edit") { ["edit", "multi_edit"] }
    else { if (a == "multiedit") { ["multi_edit"] }
    else { [] }}}
}

fun hook_list_has(lst, item) {
    if (length(lst) == 0) { 'false' }
    else { if (hd(lst) == item) { 'true' } else { hook_list_has(tl(lst), item) } }
}

# Run a single hook command with the context described above run_hooks.
# 'ok' on exit 0; {'block', reason} on a non-zero exit, a timeout, or when
# the hook could not be run at all — the reason carries the exit code and
# the start of the hook's output (stdout+stderr) so the model can see why.
fun hook_cmd_timeout_ms() { 60000 }

fun run_hook_cmd(cmd, event, tool_name, args_json) {
    exports = "export SWARM_CODE_EVENT=" ++ Util.shell_q(to_string(event)) ++ "; " ++
              "export SWARM_CODE_TOOL="  ++ Util.shell_q(to_string(tool_name)) ++ ";"
    res = Hooks.run_with_payload(cmd, to_string(args_json), "SWARM_CODE_ARGS", exports,
                                 hook_cmd_timeout_ms(), hook_tmp_prefix())
    label = to_string(event) ++ " hook `" ++ string_truncate(to_string(cmd), 80) ++ "`"
    if (map_get(res, 'ran') != 'true') {
        {'block', label ++ " could not run — " ++ to_string(map_get(res, 'error'))}
    } else { if (map_get(res, 'interrupted') == 'true') {
        {'block', label ++ " timed out after " ++ to_string(hook_cmd_timeout_ms() / 1000) ++ "s"}
    } else { if (map_get(res, 'code') == 0) {
        'ok'
    } else {
        out = string_trim(to_string(map_get(res, 'out')))
        tail = if (string_length(out) == 0) { "" } else { ": " ++ string_truncate(out, 500) }
        {'block', label ++ " exited " ++ to_string(map_get(res, 'code')) ++ tail}
    }}}
}

fun hook_tmp_prefix() {
    t = getenv("TMPDIR")
    base = if (t == nil || string_length(to_string(t)) == 0) { "/tmp" } else { to_string(t) }
    base ++ "/swarm-code-hook-"
}
