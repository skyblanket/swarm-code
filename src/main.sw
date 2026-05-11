module Main

# ============================================================
# swarm-code — terminal coding agent in sw
# ============================================================
#
# Config via environment variables (no argv parsing yet):
#   SWARM_CODE_ENDPOINT    default: http://sushi:8000
#                          Accepts either a base URL (we append
#                          /v1/chat/completions) or a full URL ending
#                          in /chat/completions (used verbatim — for
#                          providers like Zhipu/Z.AI GLM that don't
#                          use the /v1/ path).
#   SWARM_CODE_MODEL       default: google/gemma-4-31B-it
#   SWARM_CODE_API_KEY     default: (none)
#   SWARM_CODE_MAX_TOKENS  default: 262144 (Kimi K2.6 context window)
#   SWARM_CODE_OUTPUT_RESERVE  default: 16384 (Kimi K2.6 max output)
#   SWARM_CODE_TEMP        default: "0.2" (string — parsed to float)
#   SWARM_CODE_CWD         default: "." (used in system prompt)
#
# Example — GLM-5.1 via Zhipu / Z.AI:
#   SWARM_CODE_ENDPOINT=https://api.z.ai/api/paas/v4/chat/completions
#   SWARM_CODE_MODEL=glm-5.1
#   SWARM_CODE_API_KEY=<your key>
#   SWARM_CODE_ALLOW_REMOTE=1
#
# Built with: (cd /Users/sky/swarm-code && make)
# Run with:   /Users/sky/swarm-code/bin/swarm-code

import Prompts
import Agent
import Config
import UI
import Arthopod
import Memory
import Heartbeat
import Background
import Telemetry
import Log
import Agents

fun main() {
    base_opts = load_opts()
    cwd = resolve_cwd()

    Log.init()
    Log.session_start(
        to_string(map_get(base_opts, 'model')),
        to_string(map_get(base_opts, 'endpoint')),
        cwd)

    # Network isolation: verify the configured endpoint is on a local /
    # private / Tailscale network. Refuse to run against a public-internet
    # endpoint unless SWARM_CODE_ALLOW_REMOTE=1 is set OR the user has
    # supplied an explicit API key (which is itself an intentional opt-in
    # to a remote provider). This guarantees no conversation data leaves
    # the user's network by accident.
    endpoint_url = to_string(map_get(base_opts, 'endpoint'))
    verify_network_isolation(endpoint_url, map_get(base_opts, 'api_key'))

    # Optional full-terminal alt-screen mode
    tui_env = getenv("SWARM_CODE_TUI")
    if (tui_env == "1") {
        UI.enter_alt_screen()
    }

    UI.banner(to_string(map_get(base_opts, 'model')),
              endpoint_url,
              cwd)

    # Load settings (user-global + project-local merged) and project context.
    settings = Config.load()
    project_ctx = Config.load_project_context()

    # Allocate session state: ETS tables for todos + permissions cache +
    # LLM stats (server-reported token counts cached per turn so the
    # agent can budget compaction against real prompt_tokens instead of
    # client-side char estimates).
    todos_table = ets_new()
    perms_table = ets_new()
    llm_stats_table = ets_new()
    swarm_registry = Agents.init()

    # Phase E features: memory, heartbeat, background tasks
    memory_table = Memory.load()
    bg_table = Background.init()
    # Short tick (2s) so bg_done notifications feel real-time. Polling
    # is a cheap file_exists check per pending task. Override with
    # SWARM_CODE_HEARTBEAT_SEC=N for slower pulses on quiet sessions.
    hb_interval_env = getenv("SWARM_CODE_HEARTBEAT_SEC")
    hb_parsed = if (hb_interval_env == nil) { 2 } else { parse_int_simple(hb_interval_env) }
    hb_interval = if (hb_parsed < 1) { 2 } else { hb_parsed }
    heartbeat_table = Heartbeat.start(hb_interval, bg_table)

    # Load the SWARM_MANIFESTO.md if present — Swarm's letter to itself
    manifesto_path = getenv("HOME") ++ "/.swarm-code/SWARM_MANIFESTO.md"
    manifesto_text = if (file_exists(manifesto_path) == 'true') {
        m = file_read(manifesto_path)
        if (m == nil) { "" } else { m }
    } else { "" }

    opts = map_put(base_opts, 'cwd', cwd)
    opts2 = map_put(opts, 'todos_table', todos_table)
    opts3 = map_put(opts2, 'perms_table', perms_table)
    opts3a = map_put(opts3, 'memory_table', memory_table)
    opts3b = map_put(opts3a, 'heartbeat_table', heartbeat_table)
    opts3c_stats = map_put(opts3b, 'llm_stats_table', llm_stats_table)
    opts3c = map_put(opts3c_stats, 'bg_table', bg_table)
    opts3c = map_put(opts3c, 'swarm_registry', swarm_registry)
    # Autonomy: wake the LLM on bg_done events so the model can react to
    # background activity without a user prompt. Default ON. Disable with
    # SWARM_CODE_AUTONOMY=0.
    auto_env = getenv("SWARM_CODE_AUTONOMY")
    autonomy_on = if (auto_env == "0") { 'false' } else { 'true' }
    opts3d = map_put(opts3c, 'autonomy', autonomy_on)

    # Daemon mode: periodic cognitive pulse. The heartbeat sends ticks,
    # and every N ticks the model self-prompts to check for work.
    # Default OFF — enable with SWARM_CODE_DAEMON=1.
    daemon_env = getenv("SWARM_CODE_DAEMON")
    daemon_on = if (daemon_env == "1") { 'true' } else { 'false' }
    opts3e = map_put(opts3d, 'daemon', daemon_on)
    opts4 = map_put(opts3e, 'settings', settings)

    # Hatch the arthopod ONLY if explicitly enabled:
    #   SWARM_CODE_BUDDY=1  — env var
    #   or settings.json "buddy_enabled": true
    # Default OFF — the buddy is a toy, not the product.
    buddy_env = getenv("SWARM_CODE_BUDDY")
    settings_buddy = map_get(settings, 'buddy_enabled')
    buddy_enabled = if (buddy_env == "1") { 'true' }
                    else { if (settings_buddy == 'true') { 'true' }
                    else { 'false' }}
    buddy = if (buddy_enabled == 'true') { Arthopod.hatch(opts4) } else { nil }

    if (buddy != nil) {
        Arthopod.render(buddy)
        Arthopod.render_with_bubble(buddy, Arthopod.greet_line(buddy))
    }

    opts5 = if (buddy == nil) { opts4 } else { map_put(opts4, 'buddy', buddy) }

    # Fire SessionStart hook (if configured).
    Config.run_hooks("SessionStart", 'session', "{}", opts5)

    buddy_prompt = if (buddy == nil) { "" }
    else {
        name = to_string(map_get(buddy, 'name'))
        species = to_string(map_get(buddy, 'species'))
        "\n\n=== COMPANION ===\n" ++
        "A small " ++ species ++ " named " ++ name ++ " sits beside the user's " ++
        "input. You are NOT " ++ name ++ " — it's a separate watcher. If the user " ++
        "addresses " ++ name ++ " or says 'arthopod', a separate bubble answers. " ++
        "Stay out of the way: respond briefly or just answer the part meant for you."
    }

    manifesto_section = if (string_length(manifesto_text) == 0) { "" }
        else { "\n\n=== SWARM MANIFESTO (your letter from the previous iteration) ===\n" ++ manifesto_text }

    memory_section = Memory.as_prompt_section(memory_table)
    heartbeat_section = Heartbeat.as_prompt_section(heartbeat_table)

    # Capture a system-stats snapshot at startup so Swarm sees the host
    # without having to call sys_stats for basic context.
    telemetry_snapshot = Telemetry.sys_stats()
    telemetry_section = "\n\n=== HOST SNAPSHOT (startup) ===\n" ++ telemetry_snapshot

    system_prompt_text = Prompts.system_prompt(cwd, to_string(map_get(base_opts, 'tool_format'))) ++
        (if (string_length(project_ctx) == 0) { "" }
         else { "\n\n=== PROJECT CONTEXT (SWARM.md) ===\n" ++ project_ctx }) ++
        manifesto_section ++
        memory_section ++
        heartbeat_section ++
        telemetry_section ++
        buddy_prompt

    Agent.run(opts5, system_prompt_text)
}

fun load_opts() {
    # Settings.json fallback so users can stash endpoint / model /
    # api_key without re-exporting env vars every session. Env always
    # wins; settings fills the gaps; built-in default is Kimi K2.6 via
    # Moonshot's hosted API.
    settings = Config.load()
    ep_env = getenv("SWARM_CODE_ENDPOINT")
    ep_set = if (settings == nil) { nil } else { map_get(settings, 'endpoint') }
    endpoint = if (ep_env != nil) { ep_env }
               else { if (ep_set != nil) { to_string(ep_set) }
               else { "https://api.moonshot.ai/v1/chat/completions" }}

    model_env = getenv("SWARM_CODE_MODEL")
    model_set = if (settings == nil) { nil } else { map_get(settings, 'model') }
    model = if (model_env != nil) { model_env }
            else { if (model_set != nil) { to_string(model_set) }
            else { "kimi-k2.6" }}

    api_env = getenv("SWARM_CODE_API_KEY")
    api_set = if (settings == nil) { nil } else { map_get(settings, 'api_key') }
    api_key = if (api_env != nil) { api_env }
              else { if (api_set != nil) { to_string(api_set) }
              else { nil }}

    # Tool format: native (OpenAI-native tool_calls) or inband (Gemma 4
    # call:NAME{JSON} text). Explicit env wins, else auto-detect from
    # endpoint. See detect_tool_format/0.
    tf_env = getenv("SWARM_CODE_TOOL_FORMAT")
    tool_format = if (tf_env == "native") { 'native' }
                  else { if (tf_env == "inband") { 'inband' }
                  else { detect_tool_format(endpoint) }}

    # max_tokens = maximum output tokens the model will generate per call.
    # Default 32768 assumes a multi-GPU server (e.g. sushi's 2x RTX PRO
    # 6000 Blackwell = 192 GB VRAM running Gemma-4-31B at bf16 with
    # tensor-parallel sharding). This gives ~800 lines of dense code per
    # turn without hitting finish_reason=length. If your server is
    # single-GPU / quantized / tight on VRAM, lower it via
    # SWARM_CODE_MAX_OUTPUT_TOKENS=8192 (or whatever fits).
    mt_env = getenv("SWARM_CODE_MAX_OUTPUT_TOKENS")
    max_tokens = if (mt_env == nil) { 32768 }
                 else { parse_max_tokens_env(mt_env, 0, 0, 'false') }

    # Kimi K2.x rejects any temperature other than 1.0 — Moonshot
    # hard-codes their RLHF to one setting. For other providers we keep
    # the snappier 0.2 default that suits coding workflows.
    temperature = if (string_starts_with(model, "kimi") == 'true') { 1.0 }
                  else { 0.2 }

    %{
        endpoint: endpoint,
        model: model,
        api_key: api_key,
        temperature: temperature,
        max_tokens: max_tokens,
        tool_format: tool_format
    }
}

# Decide tool_format from endpoint. Public cloud providers support
# OpenAI-native function calling → 'native'. Local/private Gemma boxes
# get the in-band text protocol → 'inband'. Override via env if needed.
fun detect_tool_format(endpoint) {
    if (string_contains(endpoint, "moonshot") == 'true') { 'native' }
    else { if (string_contains(endpoint, "z.ai") == 'true') { 'native' }
    else { if (string_contains(endpoint, "bigmodel.cn") == 'true') { 'native' }
    else { if (string_contains(endpoint, "openai.com") == 'true') { 'native' }
    else { if (string_contains(endpoint, "anthropic") == 'true') { 'native' }
    else { if (string_contains(endpoint, "groq.com") == 'true') { 'native' }
    else { if (string_contains(endpoint, "together") == 'true') { 'native' }
    else { if (string_contains(endpoint, "openrouter") == 'true') { 'native' }
    else { if (string_contains(endpoint, "deepseek") == 'true') { 'native' }
    else { if (string_contains(endpoint, "fireworks") == 'true') { 'native' }
    else { if (string_contains(endpoint, "cerebras") == 'true') { 'native' }
    else { if (string_contains(endpoint, "x.ai") == 'true') { 'native' }
    else { if (string_contains(endpoint, "mistral.ai") == 'true') { 'native' }
    else { 'inband' }}}}}}}}}}}}}
}

fun parse_max_tokens_env(s, i, acc, saw) {
    if (i >= string_length(s)) {
        if (saw == 'true' && acc >= 512) { acc } else { 16384 }
    } else {
        ch = string_sub(s, i, 1)
        d = if (ch == "0") { 0 } else { if (ch == "1") { 1 }
            else { if (ch == "2") { 2 } else { if (ch == "3") { 3 }
            else { if (ch == "4") { 4 } else { if (ch == "5") { 5 }
            else { if (ch == "6") { 6 } else { if (ch == "7") { 7 }
            else { if (ch == "8") { 8 } else { if (ch == "9") { 9 }
            else { 0 - 1 }}}}}}}}}}
        if (d < 0) {
            if (saw == 'true' && acc >= 512) { acc } else { 16384 }
        } else {
            parse_max_tokens_env(s, i + 1, acc * 10 + d, 'true')
        }
    }
}

fun resolve_cwd() {
    cwd_env = getenv("SWARM_CODE_CWD")
    if (cwd_env == nil) { "." } else { cwd_env }
}

# ============================================================
# Network isolation
# ============================================================
#
# swarm-code makes network calls in only two places:
#   1. llm.sw  — http_post(endpoint + "/v1/chat/completions", ...)
#                Where `endpoint` is from SWARM_CODE_ENDPOINT env var or
#                settings.json, defaulting to http://sushi:8000.
#   2. tools.sw — http_get(url, ...) in the web_fetch tool, ONLY when
#                 the model calls web_fetch and the user allows it.
#
# There are NO telemetry calls, NO analytics, NO auto-updater, NO crash
# reports, NO hardcoded "phone home" URLs. This check enforces that the
# LLM endpoint is local/private by default. Set SWARM_CODE_ALLOW_REMOTE=1
# to bypass (e.g., when running against a remote LAN box intentionally).
fun verify_network_isolation(url, api_key) {
    bypass = getenv("SWARM_CODE_ALLOW_REMOTE")
    has_auth = if (api_key == nil) { 'false' }
               else { if (string_length(to_string(api_key)) == 0) { 'false' }
               else { 'true' }}
    host = extract_host(url)
    is_local = is_local_host(host)

    if (bypass == "1") {
        print(" \e[38;5;214m⚠ SWARM_CODE_ALLOW_REMOTE=1 — network isolation disabled\e[0m")
        "ok"
    }
    else { if (is_local == 'true') {
        "ok"
    }
    else { if (has_auth == 'true') {
        # User supplied an API key → intentional remote provider.
        print(" \e[38;5;214m⚠ remote endpoint " ++ host ++ " (auth via API key)\e[0m")
        "ok"
    }
    else {
        print("")
        print("\e[38;5;124m\e[1m⏺ swarm-code\e[0m refuses to contact non-local endpoints.")
        print("")
        print(" endpoint : " ++ url)
        print(" host     : " ++ host)
        print("")
        print(" This is to guarantee no conversation data leaves your")
        print(" network. swarm-code only allows:")
        print("   - loopback:       127.*, ::1, localhost")
        print("   - private RFC1918: 10.*, 172.16-31.*, 192.168.*")
        print("   - Tailscale CGNAT: 100.64.0.0/10")
        print("   - .local hostnames (mDNS)")
        print("   - Tailscale MagicDNS hosts (*.ts.net, bare hostnames)")
        print("")
        print(" Set SWARM_CODE_API_KEY=... or SWARM_CODE_ALLOW_REMOTE=1 to bypass.")
        print("")
        sys_exit(1)
        "denied"
    }}}
}

# Extract the host portion from a URL. Handles http:// and https://,
# and recognises bracketed IPv6 literals (`http://[::1]:8000/...`).
fun extract_host(url) {
    after_scheme = if (string_starts_with(url, "https://") == 'true') {
        string_sub(url, 8, string_length(url) - 8)
    } else {
        if (string_starts_with(url, "http://") == 'true') {
            string_sub(url, 7, string_length(url) - 7)
        } else {
            url
        }
    }
    # IPv6 literal: [::1] or [fd00::1]. Pull the body between brackets
    # before any path/port splitting.
    if (string_starts_with(after_scheme, "[") == 'true') {
        rest = string_sub(after_scheme, 1, string_length(after_scheme) - 1)
        close_parts = string_split(rest, "]")
        hd(close_parts)
    } else {
        no_path_parts = string_split(after_scheme, "/")
        host_with_port = hd(no_path_parts)
        port_parts = string_split(host_with_port, ":")
        hd(port_parts)
    }
}

# Return 'true' if host is on a local/private/Tailscale network.
fun is_local_host(host) {
    if (host == "localhost") { 'true' }
    else { if (host == "127.0.0.1") { 'true' }
    else { if (host == "::1") { 'true' }
    else { if (string_starts_with(host, "127.") == 'true') { 'true' }
    else { if (string_starts_with(host, "10.") == 'true') { 'true' }
    else { if (string_starts_with(host, "192.168.") == 'true') { 'true' }
    else { if (is_172_private(host) == 'true') { 'true' }
    else { if (is_100_cgnat(host) == 'true') { 'true' }
    else { if (string_ends_with(host, ".local") == 'true') { 'true' }
    else { if (string_ends_with(host, ".ts.net") == 'true') { 'true' }
    else { if (is_ipv6_private(host) == 'true') { 'true' }
    else {
        # Bare hostname (no dots, no colons) = probably mDNS or
        # Tailscale MagicDNS. We can't tell apart a public bare host
        # from a private one without DNS resolution; mDNS / MagicDNS
        # is the overwhelmingly common case on dev laptops, so allow.
        if (string_contains(host, ".") == 'false'
            && string_contains(host, ":") == 'false') { 'true' }
        else { 'false' }
    }}}}}}}}}}}
}

# IPv6 private ranges (best-effort): loopback (already above), ULA
# fc00::/7 (starts with `fc` or `fd`), link-local fe80::/10.
fun is_ipv6_private(host) {
    if (string_starts_with(host, "fc") == 'true') { 'true' }
    else { if (string_starts_with(host, "fd") == 'true') { 'true' }
    else { if (string_starts_with(host, "fe8") == 'true') { 'true' }
    else { if (string_starts_with(host, "fe9") == 'true') { 'true' }
    else { if (string_starts_with(host, "fea") == 'true') { 'true' }
    else { if (string_starts_with(host, "feb") == 'true') { 'true' }
    else { 'false' }}}}}}
}

fun is_172_private(host) {
    # 172.16.0.0/12 = 172.16.* through 172.31.*
    if (string_starts_with(host, "172.") == 'false') { 'false' }
    else {
        parts172 = string_split(host, ".")
        if (length(parts172) < 2) { 'false' }
        else {
            second172 = hd(tl(parts172))
            n172 = parse_int_simple(second172)
            if (n172 < 16) { 'false' }
            else {
                if (n172 > 31) { 'false' } else { 'true' }
            }
        }
    }
}

fun is_100_cgnat(host) {
    # 100.64.0.0/10 = 100.64.* through 100.127.*
    if (string_starts_with(host, "100.") == 'false') { 'false' }
    else {
        parts100 = string_split(host, ".")
        if (length(parts100) < 2) { 'false' }
        else {
            second100 = hd(tl(parts100))
            n100 = parse_int_simple(second100)
            if (n100 < 64) { 'false' }
            else {
                if (n100 > 127) { 'false' } else { 'true' }
            }
        }
    }
}

fun parse_int_simple(s) {
    parse_int_loop(s, 0, 0)
}

fun parse_int_loop(s, i, acc) {
    if (i >= string_length(s)) { acc }
    else {
        ch = string_sub(s, i, 1)
        d = if (ch == "0") { 0 }
            else { if (ch == "1") { 1 }
            else { if (ch == "2") { 2 }
            else { if (ch == "3") { 3 }
            else { if (ch == "4") { 4 }
            else { if (ch == "5") { 5 }
            else { if (ch == "6") { 6 }
            else { if (ch == "7") { 7 }
            else { if (ch == "8") { 8 }
            else { if (ch == "9") { 9 }
            else { 0 - 1 }}}}}}}}}}
        if (d < 0) { acc }
        else { parse_int_loop(s, i + 1, acc * 10 + d) }
    }
}
