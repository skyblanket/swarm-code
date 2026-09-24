module Config

import Util

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
        endpoint_host, is_local_endpoint, endpoint_refusal]

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
                join_names(ignored, "") ++ ") — to trust this repo, add its path to " ++
                "\"trusted_projects\" in ~/.swarm-code/settings.json"
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
# Policy (updated):
#   1. Default-allow for every BUILT-IN tool. The user explicitly asked
#      for "all allowed by default" — prompting on every bash/write/edit
#      was breaking flow during tool test runs. The one exception is MCP
#      tools (mcp__*): being external and unvetted, they default to 'ask'
#      so the user is prompted on first use (see default_permission).
#   2. settings.permissions[tool_name] in settings.json can downgrade
#      a specific tool to 'ask' or 'deny' if the user wants tighter
#      control on one tool (e.g. "bash": "ask").
#   3. The dangerous-bash hard gate still fires regardless. Commands
#      that look like `rm -rf`, `sudo`, `curl | sh`, `mkfs`, force
#      push, or hard resets still prompt even in default-allow mode.
#      We are not giving a model root access to the box.
# ------------------------------------------------------------
fun check_permission(tool_name, args, opts) {
    # HARDLINE: unbypassable deny for catastrophic patterns (mkfs, dd
    # to disk, shutdown/reboot, fork bomb, rm -rf /*). Fires BEFORE
    # any settings/env lookup so SWARM_CODE_ALLOW_DANGEROUS=1 cannot
    # turn it off. See is_hardline_bash for the pattern list.
    if (tool_name == 'bash' && is_hardline_bash(args) == 'true') {
        'deny'
    }
    else {
        settings = map_get(opts, 'settings')
        perms = if (settings == nil) { nil } else { map_get(settings, 'permissions') }

        # settings.json is decoded with atom keys, so pass tool_name directly.
        configured = if (perms == nil) {
            nil
        } else {
            map_get(perms, tool_name)
        }

        decision = if (configured != nil) {
            string_to_perm(configured)
        } else {
            default_permission(tool_name)
        }

        # Hard-gate dangerous bash commands regardless of config.
        # Headless converts 'ask' to 'allow' (agent.resolve_permission),
        # so unattended children (/flows fan-out sets
        # SWARM_CODE_DENY_DANGEROUS=1) turn this gate into a hard deny
        # instead of silently auto-approving.
        if (tool_name == 'bash' && is_dangerous_bash(args) == 'true') {
            if (getenv("SWARM_CODE_DENY_DANGEROUS") == "1") { 'deny' } else { 'ask' }
        } else {
            decision
        }
    }
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

# Return 'true' ONLY for truly catastrophic, unambiguous patterns.
# Scoped down from a broad "destructive commands" net because the old
# version was flagging perfectly normal dev workflows like
# `rm -rf ./build-dir`, `git push --force` on feature branches, and
# `git reset --hard HEAD~1`. The model is a coding assistant; those
# are its daily bread.
#
# What still trips the gate (after much narrowing):
#   * rm -rf targeting `/` or `~` or `$HOME` literally
#   * mkfs (formatting a block device)
#   * dd if=... writing to /dev/disk, /dev/sd, /dev/nvme, /dev/rdisk
#   * sudo (privilege escalation is always worth a beat)
#
# You can fully disable even this minimal gate by exporting
# SWARM_CODE_ALLOW_DANGEROUS=1 before launching swarm-code. Everything
# runs, nothing prompts. YOLO mode.
fun is_dangerous_bash(args) {
    bypass = getenv("SWARM_CODE_ALLOW_DANGEROUS")
    if (bypass == "1") { 'false' }
    else {
        cmd = map_get(args, 'command')
        if (cmd == nil) { 'false' }
        else {
            # rm targeting the filesystem root or user home literally.
            # We look for "rm " ++ anything ++ " /" at word boundary
            # rather than the broad "rm -rf" string match. A simple
            # conservative approach: flag only the specific dangerous
            # literal suffixes.
            if (string_contains(cmd, "rm -rf /") == 'true' &&
                string_contains(cmd, "rm -rf /tmp") == 'false' &&
                string_contains(cmd, "rm -rf /var/") == 'false' &&
                string_contains(cmd, "rm -rf /Users/") == 'false' &&
                string_contains(cmd, "rm -rf /home/") == 'false' &&
                string_contains(cmd, "rm -rf /opt/") == 'false') { 'true' }
            else { if (string_contains(cmd, "rm -rf ~") == 'true') { 'true' }
            else { if (string_contains(cmd, "rm -rf $HOME") == 'true') { 'true' }
            else { if (string_contains(cmd, "sudo ") == 'true') { 'true' }
            else { if (string_contains(cmd, "mkfs") == 'true') { 'true' }
            else { if (string_contains(cmd, "dd if=") == 'true' &&
                        string_contains(cmd, "of=/dev/") == 'true') { 'true' }
            else { 'false' }}}}}}
        }
    }
}

# ------------------------------------------------------------
# HARDLINE blocklist — UNBYPASSABLE bash patterns.
# ------------------------------------------------------------
# Unlike is_dangerous_bash, this CANNOT be turned off with
# SWARM_CODE_ALLOW_DANGEROUS=1. If your agent is asking to mkfs a
# disk or reboot the box, no env var should let it through.
#
# Categories:
#   * Filesystem destruction: mkfs, mkswap
#   * Disk wipe: dd if=... of=/dev/{sd,nvme,disk,rdisk}
#   * System halt: shutdown, reboot, halt, poweroff, init 0, init 6
#   * Filesystem lockout: chmod 000 /, chown -R 0:0 /
#   * Fork bomb literal: :(){:|:&};:
#   * Whole-disk rm: rm -rf /*
# ------------------------------------------------------------
fun is_hardline_bash(args) {
    cmd = map_get(args, 'command')
    if (cmd == nil) { 'false' }
    else {
        s = to_string(cmd)
        # Filesystem destruction
        if (string_contains(s, "mkfs") == 'true') { 'true' }
        else { if (string_contains(s, "mkswap") == 'true') { 'true' }
        # dd writing to a raw disk node
        else { if (string_contains(s, "dd if=") == 'true' &&
                   string_contains(s, "of=/dev/sd") == 'true') { 'true' }
        else { if (string_contains(s, "dd if=") == 'true' &&
                   string_contains(s, "of=/dev/nvme") == 'true') { 'true' }
        else { if (string_contains(s, "dd if=") == 'true' &&
                   string_contains(s, "of=/dev/disk") == 'true') { 'true' }
        else { if (string_contains(s, "dd if=") == 'true' &&
                   string_contains(s, "of=/dev/rdisk") == 'true') { 'true' }
        # System halt — matched as whole command words (not bare substrings),
        # so `cat asphalt_survey.csv` / `vim shutdown_handler.py` are NOT
        # blocked while `shutdown -h now`, `/sbin/reboot`, `poweroff` still are.
        else { if (contains_command_word(s, "shutdown") == 'true') { 'true' }
        else { if (contains_command_word(s, "reboot") == 'true') { 'true' }
        else { if (contains_command_word(s, "halt") == 'true') { 'true' }
        else { if (contains_command_word(s, "poweroff") == 'true') { 'true' }
        else { if (contains_command_word(s, "init 0") == 'true') { 'true' }
        else { if (contains_command_word(s, "init 6") == 'true') { 'true' }
        # telinit N is the SysV alias (telinit 0 halts, telinit 6 reboots) —
        # word-boundary "init 0" misses it ("init" preceded by 'l'), so match
        # the verb directly. Keep this as long as "init 0"/"init 6" are blocked.
        else { if (contains_command_word(s, "telinit") == 'true') { 'true' }
        # Filesystem lockout
        else { if (string_contains(s, "chmod 000 /") == 'true') { 'true' }
        else { if (string_contains(s, "chown -R 0:0 /") == 'true') { 'true' }
        # Fork bomb
        else { if (string_contains(s, ":(){:|:&};:") == 'true') { 'true' }
        # Whole-disk wipe
        else { if (string_contains(s, "rm -rf /*") == 'true') { 'true' }
        else { 'false' }}}}}}}}}}}}}}}}}
    }
}

# Whole-word match for a catastrophic verb: the word must be bounded by a
# non-identifier char (or string edge) on both sides, so it isn't matched as
# a substring of a larger filename/identifier (asphalt, rebooter,
# shutdown_handler). Over-blocks rare cases like `cat shutdown.sh` — the safe
# direction for an unbypassable floor (never under-blocks a real `shutdown`).
fun contains_command_word(s, word) {
    cw_scan(s, word, string_length(word), string_length(s), 0)
}

fun cw_scan(s, word, wlen, slen, i) {
    if (i + wlen > slen) { 'false' }
    else {
        if (string_sub(s, i, wlen) == word) {
            prev_ch = cw_char_at(s, i - 1, slen)
            next_ch = cw_char_at(s, i + wlen, slen)
            if (cw_boundary(prev_ch) == 'true' && cw_boundary(next_ch) == 'true') { 'true' }
            else { cw_scan(s, word, wlen, slen, i + 1) }
        } else { cw_scan(s, word, wlen, slen, i + 1) }
    }
}

fun cw_char_at(s, idx, slen) {
    if (idx < 0 || idx >= slen) { "" }
    else { string_sub(s, idx, 1) }
}

fun cw_boundary(ch) {
    if (ch == "") { 'true' }
    else { if (cw_is_ident(ch) == 'true') { 'false' } else { 'true' }}
}

fun cw_is_ident(ch) {
    if ((ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")
        || (ch >= "0" && ch <= "9") || ch == "_") { 'true' }
    else { 'false' }
}

# ------------------------------------------------------------
# Hooks — shell commands configured in settings.json.
#
# Settings shape:
#   "hooks": {
#     "PreToolUse":  [ {"matcher": "bash", "command": "..."} ],
#     "PostToolUse": [ {"matcher": "edit|write", "command": "..."} ],
#     "UserPromptSubmit": [ {"command": "..."} ],
#     "Stop":            [ {"command": "..."} ]
#   }
#
# Matcher is a literal substring of the tool name, or "*" for all.
# Hooks receive context through environment variables set before shell():
#   SWARM_CODE_EVENT, SWARM_CODE_TOOL, SWARM_CODE_ARGS
#
# Returns 'ok' normally. Returns 'block' if any PreToolUse hook exited
# non-zero (blocking the tool call).
# ------------------------------------------------------------
fun run_hooks(event, tool_name, args_json, opts) {
    settings = map_get(opts, 'settings')
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
                if (result == 'block') {
                    'block'
                } else {
                    run_matching_hooks(tl(hooks_list), tool_name, args_json, event)
                }
            } else {
                run_matching_hooks(tl(hooks_list), tool_name, args_json, event)
            }
        }
    }
}

fun matches(matcher, tool_name) {
    if (matcher == nil) { 'true' }
    else {
        if (matcher == "*") { 'true' }
        else {
            # Two semantics, both supported via "either direction"
            # check:
            #   1. Pipe-alternation: matcher "bash|edit" matches tool
            #      "bash" because tool_name is a substring of matcher.
            #   2. Substring: matcher "ed" matches tool "edit" because
            #      matcher is a substring of tool_name.
            # The original code only did (1); the audit miscalled this
            # as a bug. Doing both makes the obvious matchers work
            # whichever way the user expected.
            m = to_string(matcher)
            t = to_string(tool_name)
            if (string_contains(m, t) == 'true') { 'true' }
            else { string_contains(t, m) }
        }
    }
}

# Run a single hook command. Wrap with env exports for context.
# If the command exits non-zero, treat as a block signal.
# Args JSON is exposed as SWARM_CODE_ARGS so hooks can inspect the
# tool payload (e.g. a `bash` hook that greps the command). Quoted
# with shell_q_local because args_json contains arbitrary JSON
# (including single quotes inside strings).
fun run_hook_cmd(cmd, event, tool_name, args_json) {
    args_safe = Util.shell_q(to_string(args_json))
    full = "export SWARM_CODE_EVENT=" ++ Util.shell_q(to_string(event)) ++ "; " ++
           "export SWARM_CODE_TOOL="  ++ Util.shell_q(to_string(tool_name)) ++ "; " ++
           "export SWARM_CODE_ARGS="  ++ args_safe ++ "; " ++
           cmd
    result = shell(full)
    code = elem(result, 0)
    if (code == 0) { 'ok' } else { 'block' }
}
