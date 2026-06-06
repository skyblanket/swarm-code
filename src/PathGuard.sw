module PathGuard

# ============================================================
# PathGuard — centralized path validation for read/write tools
# ============================================================
#
# Consolidates all path-sensitivity checks in one place so that
# adding a new blocked pattern doesn't require editing every tool.
#
# Public API:
#   validate_write(path) → 'ok' | "error: ..."
#   validate_read(path)  → 'ok' | "error: ..."  (more permissive)
#   is_sensitive(path)   → 'true' | 'false'
#
# Bypass: export SWARM_CODE_UNSAFE_WRITES=1 to skip write guards.
#
# Blocked on WRITE (and is_sensitive):
#   /.ssh/                         (SSH keys / authorized_keys)
#   /.gnupg/                       (GPG private keys)
#   /etc/passwd, /etc/shadow,      (system account / auth files)
#   /etc/sudoers
#   /boot/                         (bootloader — prefix)
#   /.aws/                         (AWS credentials)
#   /.config/gh/hosts.yml          (gh CLI auth token)
#   /.config/git/credentials       (git credentials)
#   /.swarm-code/settings.json     (our own config)
#
# Blocked on READ (private key material only):
#   /.gnupg/private-keys*          (GPG private key material)
#   /.ssh/id_*                     (SSH private keys)

import Util

export [validate_write, validate_read, is_sensitive]

# ------------------------------------------------------------------
# resolve — normalise the path via realpath -m to defeat ../.. tricks.
# Returns the resolved string, or falls back to orig if realpath fails.
# ------------------------------------------------------------------
fun resolve_path(path) {
    resolved_raw = elem(shell("realpath -m " ++ Util.shell_q(to_string(path)) ++ " 2>/dev/null || echo " ++ Util.shell_q(to_string(path))), 1)
    resolved = string_trim(resolved_raw)
    if (string_length(resolved) > 0) { resolved } else { to_string(path) }
}

# ------------------------------------------------------------------
# is_sensitive — true if path matches any sensitive pattern.
# Used by do_read to emit a warning without blocking.
# ------------------------------------------------------------------
fun is_sensitive(path) {
    rp = resolve_path(path)
    _sensitive_check(rp)
}

fun _sensitive_check(rp) {
    if (string_contains(rp, "/.ssh/") == 'true') { 'true' }
    else { if (string_contains(rp, "/.gnupg/") == 'true') { 'true' }
    else { if (string_starts_with(rp, "/etc/") == 'true') { 'true' }
    else { if (string_starts_with(rp, "/boot/") == 'true') { 'true' }
    else { if (string_contains(rp, "/.aws/") == 'true') { 'true' }
    else { if (string_contains(rp, "/.config/gh/hosts.yml") == 'true') { 'true' }
    else { if (string_contains(rp, "/.config/git/credentials") == 'true') { 'true' }
    else { if (string_contains(rp, "/.swarm-code/settings.json") == 'true') { 'true' }
    else { 'false' }}}}}}}}
}

# ------------------------------------------------------------------
# validate_write — blocks writes to sensitive paths.
# Returns 'ok' or an error string.
# Bypass: SWARM_CODE_UNSAFE_WRITES=1
# ------------------------------------------------------------------
fun validate_write(path) {
    bypass = getenv("SWARM_CODE_UNSAFE_WRITES")
    if (bypass == "1") { "ok" }
    else {
        rp = resolve_path(path)
        _write_check(rp)
    }
}

fun _write_check(rp) {
    if (string_contains(rp, "/.ssh/") == 'true') {
        "error: write to sensitive path blocked: refusing to write inside an .ssh directory — set SWARM_CODE_UNSAFE_WRITES=1 to override"
    }
    else { if (string_contains(rp, "/.gnupg/") == 'true') {
        "error: write to sensitive path blocked: refusing to write inside a .gnupg directory (GPG keys) — set SWARM_CODE_UNSAFE_WRITES=1 to override"
    }
    else { if (rp == "/etc/passwd") {
        "error: write to sensitive path blocked: refusing to write /etc/passwd — set SWARM_CODE_UNSAFE_WRITES=1 to override"
    }
    else { if (rp == "/etc/shadow") {
        "error: write to sensitive path blocked: refusing to write /etc/shadow — set SWARM_CODE_UNSAFE_WRITES=1 to override"
    }
    else { if (rp == "/etc/sudoers") {
        "error: write to sensitive path blocked: refusing to write /etc/sudoers — set SWARM_CODE_UNSAFE_WRITES=1 to override"
    }
    else { if (string_starts_with(rp, "/etc/") == 'true') {
        "error: write to sensitive path blocked: refusing to write under /etc/ — set SWARM_CODE_UNSAFE_WRITES=1 to override"
    }
    else { if (string_starts_with(rp, "/boot/") == 'true') {
        "error: write to sensitive path blocked: refusing to write under /boot/ — set SWARM_CODE_UNSAFE_WRITES=1 to override"
    }
    else { if (string_contains(rp, "/.aws/") == 'true') {
        "error: write to sensitive path blocked: refusing to write inside an .aws directory (credentials) — set SWARM_CODE_UNSAFE_WRITES=1 to override"
    }
    else { if (string_contains(rp, "/.config/gh/hosts.yml") == 'true') {
        "error: write to sensitive path blocked: refusing to write the gh CLI hosts.yml (auth token) — set SWARM_CODE_UNSAFE_WRITES=1 to override"
    }
    else { if (string_contains(rp, "/.config/git/credentials") == 'true') {
        "error: write to sensitive path blocked: refusing to write git credentials file — set SWARM_CODE_UNSAFE_WRITES=1 to override"
    }
    else { if (string_contains(rp, "/.swarm-code/settings.json") == 'true') {
        "error: write to sensitive path blocked: refusing to write swarm-code's own settings.json — edit it yourself, or set SWARM_CODE_UNSAFE_WRITES=1 to override"
    }
    else { "ok" }}}}}}}}}}}
}

# ------------------------------------------------------------------
# validate_read — blocks reads of private key material.
# Much more permissive than write: agents need to inspect config files
# for debugging. Only hard-blocks actual private key files.
# Returns 'ok' or an error string.
# ------------------------------------------------------------------
fun validate_read(path) {
    rp = resolve_path(path)
    _read_check(rp)
}

fun _read_check(rp) {
    if (string_contains(rp, "/.gnupg/private-keys") == 'true') {
        "error: read blocked: refusing to read GPG private key material in .gnupg/private-keys*"
    }
    else { if (_is_ssh_private_key(rp) == 'true') {
        "error: read blocked: refusing to read SSH private key (/.ssh/id_*) — use the public key (.pub) instead"
    }
    else { "ok" }}
}

# Returns 'true' if the path looks like an SSH private key file.
# Matches /.ssh/id_* but not /.ssh/id_*.pub.
fun _is_ssh_private_key(rp) {
    if (string_contains(rp, "/.ssh/id_") == 'true') {
        if (string_ends_with(rp, ".pub") == 'true') { 'false' }
        else { 'true' }
    }
    else { 'false' }
}
