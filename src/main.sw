module Main

# ============================================================
# swarm-code — terminal coding agent in sw
# ============================================================
#
# Flags:  swarm --help · swarm --version · swarm --print-config
#         (everything else is configured by environment, below.)
#
# Config via environment variables:
#   SWARM_CODE_ENDPOINT    default: http://sushi:8000
#                          Accepts either a base URL (we append
#                          /v1/chat/completions) or a full URL ending
#                          in /chat/completions (used verbatim — for
#                          providers like Zhipu/Z.AI GLM that don't
#                          use the /v1/ path).
#   SWARM_CODE_MODEL       default: google/gemma-4-31B-it
#   SWARM_CODE_API_KEY     default: (none)
#   SWARM_CODE_MAX_TOKENS  default: 262144 (Kimi K2.7 context window)
#   SWARM_CODE_OUTPUT_RESERVE  default: 16384 (Kimi K2.7 max output)
#   SWARM_CODE_COMPACT_BUFFER  default: 52000 — reserve and buffer are each
#                          capped at 1/4 of SWARM_CODE_MAX_TOKENS
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
import Memory
import Skills
import SessionSearch
import Vision
import Scheduler
import Heartbeat
import Background
import Telemetry
import Log
import Mcp
import ToolGuardrails
import McpServer
import Version
import Util

fun main() {
    # MCP server mode: `swarm --mcp-server` boots as a stdio JSON-RPC
    # server exposing bash/read/write/edit/glob/grep/web_fetch tools.
    # No LLM, no agent loop — pure tool execution for orchestrators.
    if (has_flag(os_args(), "--mcp-server") == 'true') {
        # stdout is JSON-RPC framing — the notice goes to stderr.
        mcp_pn = Config.project_notice()
        if (mcp_pn != nil) { eprint("swarm-code: " ++ mcp_pn) }
        mcp_server_opts = %{
            cwd: resolve_cwd(),
            settings: Config.load(),
            guardrails_table: ToolGuardrails.init(),
            execution_context: "mcp_server"
        }
        McpServer.run(mcp_server_opts)
        sys_exit(0)
    }
    # CLI flags (--help / --version / --print-config) print and exit
    # before any runtime setup. Returns "ok" when no flag was given.
    handle_cli_flags(os_args())

    # Headless mode: `swarm -p "<prompt>"` runs one task to completion
    # and exits — no TUI, no Reader. `--json` adds a final result line.
    # The prompt comes from the argument after -p (or, when a flag follows
    # -p, the first positional argument: `-p --json "..."`), OR from stdin
    # when there is none (or `-p -`) — so an orchestrator can pipe a
    # multi-line prompt without shell-quoting it as an argument.
    cli_args = os_args()
    p_present = if (has_flag(cli_args, "-p") == 'true') { 'true' }
                else { if (has_flag(cli_args, "--print") == 'true') { 'true' }
                else { 'false' }}
    json_mode = if (has_flag(cli_args, "--json") == 'true') { 'true' } else { 'false' }
    # --no-resume makes the headless run start fresh instead of resuming
    # the .active session journal. Critical when firing many parallel
    # `swarm -p ...` agents — they'd otherwise all race on the same
    # journal and trigger auto-compaction storms.
    no_resume = if (has_flag(cli_args, "--no-resume") == 'true') { 'true' } else { 'false' }
    arg_prompt = get_print_arg(cli_args)
    headless = p_present
    # Headless stdout carries only the result: the --json line, or the final
    # answer when stdout is piped. The transcript (tool calls, streamed
    # tokens, notices) moves to stderr, so `swarm -p ... | jq` and
    # `x=$(swarm -p ...)` get clean output. A terminal stdout keeps the live
    # transcript as before (-1 = not diverted).
    result_fd = if (headless == 'true' &&
                    (json_mode == 'true' || stdout_is_tty() == 'false')) {
        stdout_to_stderr()
    } else { -1 }
    headless_prompt = if (p_present == 'false') { nil }
                      else { if (arg_prompt != nil) { arg_prompt }
                      else { read_all_stdin("") }}

    base_opts = load_opts()
    cwd = resolve_cwd()

    Log.init()
    Log.session_start(
        to_string(map_get(base_opts, 'model')),
        to_string(map_get(base_opts, 'endpoint')),
        cwd)

    # Network isolation: verify the configured endpoint is on a local /
    # private / Tailscale network. Refuse to run against a public-internet
    # endpoint unless SWARM_CODE_ALLOW_REMOTE=1 is set (an API key alone is
    # NOT an opt-in). This guarantees no conversation data leaves the
    # user's network by accident. llm.sw re-checks every URL it dials.
    endpoint_url = to_string(map_get(base_opts, 'endpoint'))

    # Optional full-terminal alt-screen mode (interactive only)
    tui_env = getenv("SWARM_CODE_TUI")
    if (tui_env == "1" && headless == 'false') {
        UI.enter_alt_screen()
    }

    if (headless == 'false') {
        UI.banner(to_string(map_get(base_opts, 'model')),
                  endpoint_url,
                  cwd)
    }

    # Network isolation — verified AFTER the banner so any ⚠ remote /
    # bypass notice lands beneath swarm-code's identity (and isn't wiped
    # by the alt-screen clear above). The refusal path still hard-exits;
    # in_alt tells it to LEAVE the alt screen first so the explanation
    # isn't discarded with the alt buffer (silent-exit bug).
    in_alt = if (tui_env == "1" && headless == 'false') { 'true' } else { 'false' }
    verify_network_isolation(endpoint_url, in_alt)

    # An untrusted ./.swarm-code.json had keys dropped (Config.project_scope)
    # — say so once, so a repo's config never half-applies silently.
    project_note = Config.project_notice()
    if (project_note != nil) { print(" " ++ UI.warn_text("⚠ " ++ project_note)) }

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
    browser_table = ets_new()
    # Tracks "which subagent is currently streaming" so chunks from the
    # same agent merge inline and prefix lines only print on agent
    # transitions. Single key 'current' → name | nil.
    stream_state = ets_new()
    # Stashes the FULL text of the most recent tool result so /expand can
    # reprint it uncapped (the ⎿ view caps at 8 lines). Single key
    # 'last_tool_output'.
    expand_table = ets_new()
    # Stashes a file's prior bytes just before a `write` overwrites it,
    # keyed by path, so show_edit_diff can render a real overwrite diff.
    write_diff_table = ets_new()

    # Phase E features: memory, heartbeat, background tasks
    memory_table = Memory.load()
    skills_token = Skills.load()
    if (headless == 'false') {
        print_inline(UI.grey_text() ++ " ⏳ indexing past sessions…" ++ UI.reset())
    }
    SessionSearch.init()
    Scheduler.load()
    if (headless == 'false') {
        # Wipe the loader line in-place so the banner-to-prompt transition stays clean.
        print_inline("\r\e[K")
    }
    bg_table = Background.init()
    # Short tick (2s) so bg_done notifications feel real-time. Polling
    # is a cheap file_exists check per pending task. Override with
    # SWARM_CODE_HEARTBEAT_SEC=N for slower pulses on quiet sessions.
    hb_interval_env = getenv("SWARM_CODE_HEARTBEAT_SEC")
    hb_parsed = if (hb_interval_env == nil) { 2 } else { parse_int_simple(hb_interval_env) }
    hb_interval = if (hb_parsed < 1) { 2 } else { hb_parsed }
    heartbeat_table = Heartbeat.start(hb_interval, bg_table)

    # MCP — start any configured Model Context Protocol servers and
    # discover their tools. Returns an empty table (and prints nothing)
    # when no mcpServers are set, so MCP is zero-cost when unused.
    # mcp_schemas is the discovered tools as OpenAI function schemas,
    # merged into the request `tools` array by llm.sw's native_req.
    mcp_table = Mcp.init(settings)
    mcp_schemas = Mcp.all_schemas(mcp_table)

    # Load the SWARM_MANIFESTO.md if present — Swarm's letter to itself
    home_env = getenv("HOME")
    manifesto_path = if (home_env == nil) { "" } else { home_env ++ "/.swarm-code/SWARM_MANIFESTO.md" }
    manifesto_text = if (file_exists(manifesto_path) == 'true') {
        m = file_read(manifesto_path)
        if (m == nil) { "" } else { m }
    } else { "" }

    context_env = getenv("SWARM_CODE_EXECUTION_CONTEXT")
    execution_context = if (context_env == nil) { "main" }
                        else { to_string(context_env) }
    # session_id: stamps /profile and /model overrides so THIS session's beat
    # env vars while one left over from an earlier session doesn't (LLM.apply_override).
    opts0 = map_put(map_put(base_opts, 'execution_context', execution_context),
                    'session_id', uuid())
    opts = map_put(opts0, 'cwd', cwd)
    opts2 = map_put(opts, 'todos_table', todos_table)
    opts3 = map_put(opts2, 'perms_table', perms_table)
    opts3a = map_put(opts3, 'memory_table', memory_table)
    opts3b = map_put(opts3a, 'heartbeat_table', heartbeat_table)
    opts3c_stats = map_put(opts3b, 'llm_stats_table', llm_stats_table)
    opts3c = map_put(opts3c_stats, 'bg_table', bg_table)
    opts3c = map_put(opts3c, 'browser_table', browser_table)
    opts3c = map_put(opts3c, 'stream_state_table', stream_state)
    opts3c = map_put(opts3c, 'expand_table', expand_table)
    opts3c = map_put(opts3c, 'write_diff_table', write_diff_table)
    opts3c = map_put(opts3c, 'mcp_table', mcp_table)
    opts3c = map_put(opts3c, 'mcp_schemas', mcp_schemas)
    # Vision: session-scoped ETS queue. read_image tool appends data
    # URLs here; llm.sw drains + clears on each outbound request.
    attachments_table = ets_new()
    opts3c = map_put(opts3c, 'attachments_table', attachments_table)
    # Tool guardrails: per-turn loop/failure/no-progress detector.
    # agent.sw's execute_all consults this table before every
    # dispatch; main.sw owns the lifecycle. Dormant (no-op) if the
    # table key is missing, so subagent contexts that don't share
    # opts inherit the safe-by-default behaviour.
    opts3c = map_put(opts3c, 'guardrails_table', ToolGuardrails.init())
    # Drop a .gitignore into ~/.swarm-code if missing so users who
    # version-control their config don't accidentally commit api_key,
    # session journals, or the live profile override.
    ensure_gitignore()
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
    opts5 = map_put(opts3e, 'settings', settings)

    # Fire SessionStart hook (if configured).
    Config.run_hooks("SessionStart", 'session', "{}", opts5)

    manifesto_section = if (string_length(manifesto_text) == 0) { "" }
        else { "\n\n=== SWARM MANIFESTO (your letter from the previous iteration) ===\n" ++ manifesto_text }

    memory_section = Memory.as_prompt_section(memory_table)
    skills_section = Skills.as_prompt_section(skills_token)
    heartbeat_section = Heartbeat.as_prompt_section(heartbeat_table)
    mcp_section = Mcp.as_prompt_section(mcp_table)

    # Host snapshot is left to the agent — it has a sys_stats tool and can
    # call it when relevant. Capturing at startup costs ~6 swarmrt shell()
    # calls (uptime / uname / vm_stat / df / uptime / free), and each shell()
    # imposes a 1s poll. Eating 6s of startup just for a snapshot the model
    # rarely needs at turn-zero is a bad UX trade.
    telemetry_section = ""

    system_prompt_text = Prompts.system_prompt(cwd, to_string(map_get(base_opts, 'tool_format'))) ++
        (if (string_length(project_ctx) == 0) { "" }
         else { "\n\n=== PROJECT CONTEXT (SWARM.md) ===\n" ++ project_ctx }) ++
        manifesto_section ++
        memory_section ++
        skills_section ++
        heartbeat_section ++
        mcp_section ++
        telemetry_section

    # Load persistent line history (~/.swarm-code/history) once, before the
    # Reader draws the first prompt, so up-arrow recall survives a restart.
    # Interactive only — headless has no Reader/prompt. Safe here (before any
    # read_line/termios setup): rl_history_load only reads the file into the
    # in-memory history array, and is a no-op nil if the file doesn't exist yet.
    if (headless == 'false') {
        hist_home = getenv("HOME")
        if (hist_home != nil) {
            rl_history_load(hist_home ++ "/.swarm-code/history")
        }
    }

    if (headless == 'true') {
        Agent.run_headless(map_put(map_put(opts5, 'no_resume', no_resume), 'result_fd', result_fd),
                           system_prompt_text, headless_prompt, json_mode)
    } else {
        Agent.run(opts5, system_prompt_text)
    }
}

# ============================================================
# CLI flags
# ============================================================
#
# swarm-code is configured almost entirely through environment
# variables (see load_opts/0). The only command-line flags are the
# three every CLI is expected to answer; each prints and exits
# without starting the agent.

# Write a default .gitignore into ~/.swarm-code if one isn't already
# there. Power users sometimes track ~/.swarm-code in git (skills,
# memories, manifesto, settings.json template); without this they'd
# leak api_key / session content / the live profile override on
# the next commit.
fun ensure_gitignore() {
    home = getenv("HOME")
    if (home == nil) { 'ok' }
    else {
        gi = home ++ "/.swarm-code/.gitignore"
        if (file_exists(gi) == 'true') { 'ok' }
        else {
            body =
                "# swarm-code default ignore — keep secrets and session\n" ++
                "# state out of version control.\n" ++
                "settings.json\n" ++
                ".profile_override\n" ++
                "last-body.json\n" ++
                "sessions/\n" ++
                "telemetry/\n" ++
                "exports/\n" ++
                "schedule.json\n" ++
                "mcp-*.log\n" ++
                "arthopod.json\n"
            file_write(gi, body)
            'ok'
        }
    }
}

# Version comes from the VERSION file at the repo root, via the
# src/Version.sw module make generates at build time. Release tags in
# .github/workflows/release.yml should match VERSION.
fun swarm_version() { Version.version() }

# Presence test for a flag anywhere in argv. argv[0] is the binary
# path; position and order of the rest don't matter.
fun has_flag(args, flag) {
    if (length(args) == 0) { 'false' }
    else { if (hd(args) == flag) { 'true' }
    else { has_flag(tl(args), flag) }}
}

# Value of the -p / --print flag — the inline headless prompt — or nil
# (absent, or read the prompt from stdin):
#   -p "prompt"            that argument — even when it starts with "-"
#                          ("-- summarize the diff", "-x ..."): Scheduler and
#                          Flows pass user prompts right after -p
#   -p -                   stdin
#   -p --json "prompt"     a KNOWN flag right after -p: the first positional
#                          argument after it is the prompt (README's form)
#   -p  /  -p --json       no positional argument: stdin
# Only an exact "-" or a known flag is "not the prompt"; any other leading
# "-" used to switch to stdin, so `-p --json "..."` sent nothing and exited 1
# and a prompt starting with "-" was silently dropped.
fun get_print_arg(args) {
    idx = print_arg_index(args)
    if (idx < 0) { nil } else { list_nth(args, idx) }
}

# argv index of the inline -p prompt, or -1.
fun print_arg_index(args) { pai_find(args, 0) }

fun pai_find(args, i) {
    if (length(args) == 0) { 0 - 1 }
    else {
        h = hd(args)
        if (h == "-p" || h == "--print") { pai_after(tl(args), i + 1) }
        else { pai_find(tl(args), i + 1) }
    }
}

# args: what follows -p; i: argv index of hd(args).
fun pai_after(args, i) {
    if (length(args) == 0) { 0 - 1 }
    else {
        cand = hd(args)
        if (cand == "-") { 0 - 1 }
        else { if (is_cli_flag(cand) == 'true') { first_positional(args, i) }
        else { i } }
    }
}

fun first_positional(args, i) {
    if (length(args) == 0) { 0 - 1 }
    else {
        a = hd(args)
        if (a == "-") { 0 - 1 }
        else { if (is_cli_flag(a) == 'true') {
            if (flag_takes_value(a) == 'true' && length(tl(args)) > 0) { first_positional(tl(tl(args)), i + 2) }
            else { first_positional(tl(args), i + 1) }
        } else { i } }
    }
}

# Every flag main() understands — never mistaken for a prompt or a profile.
fun is_cli_flag(a) {
    if (a == "--json" || a == "--no-resume" || a == "-p" || a == "--print") { 'true' }
    else { if (a == "--profile" || a == "-P" || a == "--mcp-server" || a == "--print-config") { 'true' }
    else { if (a == "--help" || a == "-h" || a == "--version" || a == "-V" || a == "--doctor") { 'true' }
    else { 'false' } } }
}

fun flag_takes_value(a) {
    if (a == "--profile" || a == "-P") { 'true' } else { 'false' }
}

fun list_nth(lst, i) {
    if (i <= 0) { hd(lst) } else { list_nth(tl(lst), i - 1) }
}

# Slurp all of stdin into one string (newline-joined). Used for the
# headless prompt when `-p` has no inline argument. read_line returns
# nil at EOF (pipe closed / Ctrl-D), which ends the loop.
fun read_all_stdin(acc) {
    line = read_line("")
    if (line == nil) {
        acc
    } else {
        next = if (string_length(acc) == 0) { line } else { acc ++ "\n" ++ line }
        read_all_stdin(next)
    }
}

fun handle_cli_flags(args) {
    if (has_flag(args, "--help") == 'true' || has_flag(args, "-h") == 'true') {
        print_usage()
        sys_exit(0)
    }
    else { if (has_flag(args, "--version") == 'true' || has_flag(args, "-V") == 'true') {
        print("swarm-code " ++ swarm_version())
        sys_exit(0)
    }
    else { if (has_flag(args, "--print-config") == 'true') {
        print_config()
        sys_exit(0)
    }
    else { if (has_flag(args, "doctor") == 'true' ||
              has_flag(args, "--doctor") == 'true') {
        sys_exit(run_doctor())
    }
    else { if (subcommand(args) == "trust" || subcommand(args) == "untrust") {
        sys_exit(run_trust(subcommand(args), tl(tl(args))))
    }
    else { "ok" }}}}}
}

# First argument after the program name, or nil.
fun subcommand(args) {
    if (length(args) < 2) { nil } else { list_nth(args, 1) }
}

# swarm-code trust [DIR] | untrust [DIR] | trust --list
# A repo's ./.swarm-code.json only applies its safe keys (model,
# max_tokens, …) until its directory is listed in "trusted_projects" in
# ~/.swarm-code/settings.json. This edits that list for the user.
fun run_trust(cmd, rest) {
    if (cmd == "trust" && length(rest) > 0 && hd(rest) == "--list") {
        tp = Config.trusted_list()
        if (length(tp) == 0) { print("no trusted projects") } else { print_lines(tp) }
        0
    } else {
        dir = if (length(rest) > 0) { hd(rest) } else { "." }
        add = if (cmd == "trust") { 'true' } else { 'false' }
        r = Config.set_trusted(dir, add)
        if (elem(r, 0) != 'ok') {
            print("swarm-code " ++ cmd ++ ": " ++ to_string(elem(r, 1)))
            1
        } else {
            abs = elem(r, 1)
            changed = elem(r, 2)
            if (add == 'true') {
                if (changed == 'true') { print("trusted " ++ abs) } else { print("already trusted: " ++ abs) }
                gated = Config.project_gated_keys(abs)
                if (gated == nil) {
                    print("  (no .swarm-code.json there yet — one added later applies in full)")
                } else { if (length(gated) > 0) {
                    print("  its .swarm-code.json now also applies: " ++ Config.join_names(gated, "") ++
                          " — hooks and MCP servers run commands, so only trust repos you control")
                } else { "" } }
            } else {
                if (changed == 'true') { print("untrusted " ++ abs) } else { print("not trusted: " ++ abs) }
            }
            0
        }
    }
}

fun print_lines(xs) {
    if (length(xs) == 0) { 'ok' } else { print(to_string(hd(xs))) ; print_lines(tl(xs)) }
}

fun print_usage() {
    print("swarm-code — a terminal coding agent on the swarmrt runtime")
    print("")
    print("USAGE")
    print("  swarm                  start the interactive agent")
    print("  swarm <profile>        start with a named profile (e.g. swarm gemma)")
    print("  swarm --profile NAME   same, via explicit flag (-P also accepted)")
    print("  swarm -p \"<prompt>\"     run one task headless, then exit")
    print("  swarm -p \"...\" --json   headless + a final JSON result line")
    print("  swarm -p \"...\" --no-resume   start fresh, ignore .active session")
    print("  swarm -p - < prompt.txt       read the headless prompt from stdin")
    print("  swarm doctor           validate config, endpoint, dirs, version")
    print("  swarm trust [DIR]      let DIR's .swarm-code.json apply in full (hooks, endpoint, MCP);")
    print("                         untrust [DIR] reverses it, trust --list shows the list")
    print("  swarm --mcp-server     start as a stdio MCP tool server (JSON-RPC 2.0)")
    print("  swarm --help, -h       show this help and exit")
    print("  swarm --version, -V    print the version and exit")
    print("  swarm --print-config   show the resolved config and exit")
    print("")
    print("CONFIG")
    print("  BYOM — bring your own model. Settings are read in priority")
    print("  order: environment variables, then the selected profile, then")
    print("  ~/.swarm-code/settings.json root, then built-in defaults.")
    print("")
    print("  SWARM_CODE_ENDPOINT      LLM endpoint (OpenAI-compatible)")
    print("  SWARM_CODE_MODEL         model name (default: kimi-k2.7-code)")
    print("  SWARM_CODE_API_KEY       API key for a remote provider")
    print("  SWARM_CODE_TOOL_FORMAT   native | inband (else auto-detected)")
    print("  SWARM_CODE_ALLOW_REMOTE  set to 1 to permit non-local endpoints")
    print("  SWARM_CODE_HEADLESS_APPROVE  set to 1 to auto-approve 'ask' tools in -p runs")
    print("  SWARM_CODE_CWD           working directory shown to the model")
    print("  SWARM_CODE_PLAN=auto|on|off   plan mode (default: auto)")
    print("  SWARM_CODE_EMBED_ENDPOINT   embedding API URL (enables semantic recall)")
    print("  SWARM_CODE_EMBED_KEY        embedding API key (defaults to SWARM_CODE_API_KEY)")
    print("  SWARM_CODE_EMBED_MODEL      embedding model (default: text-embedding-ada-002)")
    print("")
    print("  Profiles: add a \"profiles\" map to settings.json, e.g.")
    print("    \"profiles\": {")
    print("      \"gemma\": {")
    print("        \"endpoint\": \"https://gemma.otonomy.ai/v1\",")
    print("        \"model\": \"google/gemma-4-31B-it\",")
    print("        \"api_key\": \"...\",")
    print("        \"tool_format\": \"native\"")
    print("      }")
    print("    }")
    print("  Then run `swarm gemma` or `swarm --profile gemma`.")
    print("")
    print("  `swarm --print-config` shows what these resolve to right now.")
    print("")
    print("IN-APP")
    print("  Once running, type /help for slash commands and /quit to exit.")
    print("")
    print("  Docs & issues: https://github.com/skyblanket/swarm-code")
}

fun print_config() {
    o = load_opts()
    ak = map_get(o, 'api_key')
    ak_shown = if (ak == nil) { "(not set)" }
               else { if (string_length(to_string(ak)) == 0) { "(empty)" }
               else { "(set)" }}
    prof = map_get(o, 'profile')
    prof_shown = if (prof == nil) { "(none)" } else { to_string(prof) }
    print("swarm-code " ++ swarm_version() ++ " — resolved configuration")
    print("  (env > profile > settings.json root > defaults)")
    print("")
    print("  profile      " ++ prof_shown)
    print("  endpoint     " ++ to_string(map_get(o, 'endpoint')))
    print("  model        " ++ to_string(map_get(o, 'model')))
    print("  api_key      " ++ ak_shown)
    print("  tool_format  " ++ to_string(map_get(o, 'tool_format')))
    print("  temperature  " ++ to_string(map_get(o, 'temperature')))
    print("  max_tokens   " ++ to_string(map_get(o, 'max_tokens')))
    print("  plan_mode    " ++ to_string(map_get(o, 'plan_mode')))
    print("  cwd          " ++ resolve_cwd())
    ee = map_get(o, 'embed_endpoint')
    ee_shown = if (ee == nil) { "(not set — semantic recall disabled)" } else { to_string(ee) }
    eak = map_get(o, 'embed_api_key')
    eak_shown = if (eak == nil) { "(not set)" }
                else { if (string_length(to_string(eak)) == 0) { "(empty)" }
                else { "(set)" }}
    print("  embed_endpoint  " ++ ee_shown)
    print("  embed_api_key   " ++ eak_shown)
    print("  embed_model     " ++ to_string(map_get(o, 'embed_model')))
}

fun load_opts() {
    # Settings.json fallback so users can stash endpoint / model /
    # api_key without re-exporting env vars every session.
    #
    # Resolution per field: env > selected profile > root settings > built-in default.
    # A profile is selected via `--profile NAME` / `-P NAME`, or by passing the
    # profile name as the first positional arg (e.g. `swarm gemma`) when it
    # matches a key under `profiles` in settings.json.
    settings = Config.load()
    args = os_args()
    profiles = if (settings == nil) { nil } else { map_get(settings, 'profiles') }
    profile_name = resolve_profile_name(args, profiles)
    profile = if (profile_name == nil) { nil }
              else { lookup_string_key(profiles, profile_name) }

    ep_env = getenv("SWARM_CODE_ENDPOINT")
    ep_prof = if (profile == nil) { nil } else { map_get(profile, 'endpoint') }
    ep_set = if (settings == nil) { nil } else { map_get(settings, 'endpoint') }
    endpoint = if (ep_env != nil) { ep_env }
               else { if (ep_prof != nil) { to_string(ep_prof) }
               else { if (ep_set != nil) { to_string(ep_set) }
               else { "https://api.moonshot.ai/v1/chat/completions" }}}

    model_env = getenv("SWARM_CODE_MODEL")
    model_prof = if (profile == nil) { nil } else { map_get(profile, 'model') }
    model_set = if (settings == nil) { nil } else { map_get(settings, 'model') }
    model = if (model_env != nil) { model_env }
            else { if (model_prof != nil) { to_string(model_prof) }
            else { if (model_set != nil) { to_string(model_set) }
            else { "kimi-k2.7-code" }}}

    api_env = getenv("SWARM_CODE_API_KEY")
    api_prof = if (profile == nil) { nil } else { map_get(profile, 'api_key') }
    api_set = if (settings == nil) { nil } else { map_get(settings, 'api_key') }
    api_key = if (api_env != nil) { api_env }
              else { if (api_prof != nil) { to_string(api_prof) }
              else { if (api_set != nil) { to_string(api_set) }
              else { nil }}}

    # Tool format: native (OpenAI-native tool_calls) or inband (Gemma 4
    # call:NAME{JSON} text). Env wins; profile can override the
    # endpoint-based auto-detect (e.g. self-hosted vLLM with
    # --enable-auto-tool-choice serves native tool_calls).
    tf_env = getenv("SWARM_CODE_TOOL_FORMAT")
    tf_prof = if (profile == nil) { nil } else { map_get(profile, 'tool_format') }
    tool_format = if (tf_env == "native") { 'native' }
                  else { if (tf_env == "inband") { 'inband' }
                  else { if (tf_prof != nil) {
                      tfs = to_string(tf_prof)
                      if (tfs == "native") { 'native' } else { 'inband' }
                  }
                  else { detect_tool_format(endpoint) }}}

    # max_tokens = maximum output tokens the model will generate per call.
    # Default 32768 assumes a multi-GPU server (e.g. sushi's 2x RTX PRO
    # 6000 Blackwell = 192 GB VRAM running Gemma-4-31B at bf16 with
    # tensor-parallel sharding). This gives ~800 lines of dense code per
    # turn without hitting finish_reason=length. If your server is
    # single-GPU / quantized / tight on VRAM, lower it via
    # SWARM_CODE_MAX_OUTPUT_TOKENS=8192 (or whatever fits).
    # max_tokens: env > profile > settings > 32768 default.
    # Default fits a 131K-context server (Gemma 4 31B on sushi). For
    # 32K-context backends (Qwen3.x default), lower this in the profile.
    mt_env = getenv("SWARM_CODE_MAX_OUTPUT_TOKENS")
    mt_prof = if (profile == nil) { nil } else { map_get(profile, 'max_tokens') }
    mt_set  = if (settings == nil) { nil } else { map_get(settings, 'max_tokens') }
    # Coerce profile/settings values too (not just env): a quoted "8192" in
    # settings.json decodes to a STRING and would flow into the body as
    # max_tokens:"8192" → 400 on every turn. Routing through to_string + the
    # env parser normalizes both int and string (and floors garbage).
    max_tokens = if (mt_env != nil) { parse_max_tokens_env(mt_env, 0, 0, 'false') }
                 else { if (mt_prof != nil) { parse_max_tokens_env(to_string(mt_prof), 0, 0, 'false') }
                 else { if (mt_set != nil) { parse_max_tokens_env(to_string(mt_set), 0, 0, 'false') }
                 else { 32768 }}}

    # Kimi K2.x rejects any temperature other than 1.0 — Moonshot
    # hard-codes their RLHF to one setting. For other providers we keep
    # the snappier 0.2 default that suits coding workflows.
    temperature = if (string_starts_with(model, "kimi") == 'true') { 1.0 }
                  else { 0.2 }

    # Optional passthrough: arbitrary map merged into every request body.
    # Profiles use this to set provider-specific knobs (e.g. Qwen3.x's
    # `chat_template_kwargs: {enable_thinking: false}` to suppress the
    # internal monologue). Profile > settings > nil.
    eb_prof = if (profile == nil) { nil } else { map_get(profile, 'chat_template_kwargs') }
    eb_set  = if (settings == nil) { nil } else { map_get(settings, 'chat_template_kwargs') }
    chat_template_kwargs = if (eb_prof != nil) { eb_prof }
                           else { if (eb_set != nil) { eb_set } else { nil }}

    # Plan mode: controls when a planning step is shown before execution.
    # on   — always show a plan before executing
    # off  — never show a plan
    # auto — show plan only for complex requests (default)
    # Env override: SWARM_CODE_PLAN=on|off|auto
    plan_env = getenv("SWARM_CODE_PLAN")
    plan_mode = if (plan_env == "on") { "on" }
                else { if (plan_env == "off") { "off" }
                else { "auto" }}

    embed_endpoint = getenv("SWARM_CODE_EMBED_ENDPOINT")
    embed_key_raw  = getenv("SWARM_CODE_EMBED_KEY")
    embed_key      = if (embed_key_raw == nil) { api_key } else { embed_key_raw }
    embed_model_raw= getenv("SWARM_CODE_EMBED_MODEL")
    embed_model    = if (embed_model_raw == nil) { "text-embedding-ada-002" } else { embed_model_raw }

    # Fallback profile: when the primary endpoint fails all retries, swap to
    # a secondary profile. Env SWARM_CODE_FALLBACK_ENDPOINT wins; otherwise
    # resolve settings.json "fallback_profile" → that profile's full config.
    fb_ep_env  = getenv("SWARM_CODE_FALLBACK_ENDPOINT")
    fb_pname   = if (settings == nil) { nil } else { map_get(settings, 'fallback_profile') }
    fb_profile = if (fb_pname == nil || profiles == nil) { nil }
                 else { lookup_string_key(profiles, to_string(fb_pname)) }
    fallback_endpoint = if (fb_ep_env != nil) { fb_ep_env }
                        else { if (fb_profile != nil) {
                            fep = map_get(fb_profile, 'endpoint')
                            if (fep != nil) { to_string(fep) } else { nil }
                        } else { nil }}
    fallback_model = if (fb_profile != nil) {
                         fm = map_get(fb_profile, 'model')
                         if (fm != nil) { to_string(fm) } else { nil }
                     } else { nil }
    fallback_key = if (fb_profile != nil) {
                       fk = map_get(fb_profile, 'api_key')
                       if (fk != nil) { to_string(fk) } else { nil }
                   } else { nil }
    fallback_tool_format = if (fb_profile != nil) {
                               ftf = map_get(fb_profile, 'tool_format')
                               if (ftf == nil) { nil }
                               else { tfs = to_string(ftf)
                                      if (tfs == "native") { 'native' } else { 'inband' }}
                           } else { nil }

    # Multi-provider failover chain. SWARM_CODE_PROVIDERS_JSON env var wins;
    # otherwise read "providers" array from settings.json root.
    # Each entry: {"endpoint":"...","model":"...","api_key":"...","tool_format":"native"|"inband"}
    # Max 3 providers. When set, overrides primary endpoint/model/api_key.
    providers_env_raw = getenv("SWARM_CODE_PROVIDERS_JSON")
    providers_settings_raw = if (settings == nil) { nil } else { map_get(settings, 'providers') }
    providers = if (providers_env_raw != nil) { json_decode(providers_env_raw) }
                else { providers_settings_raw }

    %{
        endpoint: endpoint,
        model: model,
        api_key: api_key,
        temperature: temperature,
        max_tokens: max_tokens,
        tool_format: tool_format,
        chat_template_kwargs: chat_template_kwargs,
        profile: profile_name,
        plan_mode: plan_mode,
        embed_endpoint: embed_endpoint,
        embed_api_key:  embed_key,
        embed_model:    embed_model,
        fallback_endpoint:    fallback_endpoint,
        fallback_model:       fallback_model,
        fallback_key:         fallback_key,
        fallback_tool_format: fallback_tool_format,
        providers: providers
    }
}

# Find the selected profile name from argv. Explicit `--profile NAME` /
# `-P NAME` wins; otherwise the first non-flag positional arg counts if
# it matches a key in `profiles`. If the first positional isn't a known
# profile, stop scanning — subsequent positionals are user content
# (e.g. the headless prompt).
fun resolve_profile_name(args, profiles) {
    pn1 = get_flag_value(args, "--profile")
    pn2 = if (pn1 != nil) { pn1 } else { get_flag_value(args, "-P") }
    if (pn2 != nil) { pn2 }
    else { if (profiles == nil) { nil }
    else {
        rest = if (length(args) == 0) { args } else { tl(args) }
        find_positional_profile(rest, 1, print_arg_index(args), profiles)
    }}
}

# i: argv index of hd(args). The -p prompt (prompt_idx, the SAME argument
# get_print_arg returns — `-p --json gemma` means prompt "gemma") and the
# values of --profile / -P are skipped; anything else starting with "-" is a
# flag.
fun find_positional_profile(args, i, prompt_idx, profiles) {
    if (length(args) == 0) { nil }
    else {
        a = hd(args)
        rest = tl(args)
        if (i == prompt_idx) { find_positional_profile(rest, i + 1, prompt_idx, profiles) }
        else { if (string_starts_with(a, "-") == 'true') {
            if (flag_takes_value(a) == 'true' && length(rest) > 0) {
                find_positional_profile(tl(rest), i + 2, prompt_idx, profiles)
            } else {
                find_positional_profile(rest, i + 1, prompt_idx, profiles)
            }
        } else {
            if (lookup_string_key(profiles, a) != nil) { a } else { nil }
        }}
    }
}

# Return the value following `flag` in argv, or nil if absent.
fun get_flag_value(args, flag) {
    if (length(args) == 0) { nil }
    else {
        h = hd(args)
        rest = tl(args)
        if (h == flag && length(rest) > 0) { hd(rest) }
        else { get_flag_value(rest, flag) }
    }
}

# JSON-decoded maps have atom keys, so map_get(m, "gemma") on a map
# saved as {"gemma": ...} won't match. Try direct first, then walk keys
# and compare string forms.
#
# NOTE: config.sw has a parallel pair — map_get_either/find_by_string_key —
# that does the same thing but without the nil-map guard here. The two exist
# in separate modules and serve different callers; keep them in sync if the
# core logic changes. The nil guard here is intentional: profile lookups can
# receive nil when settings.json has no "profiles" key.
fun lookup_string_key(m, key_string) {
    if (m == nil) { nil }
    else {
        direct = map_get(m, key_string)
        if (direct != nil) { direct }
        else { find_key_by_string(map_keys(m), map_values(m), key_string) }
    }
}

fun find_key_by_string(keys, values, target) {
    if (length(keys) == 0) { nil }
    else {
        k = hd(keys)
        if (to_string(k) == target) { hd(values) }
        else { find_key_by_string(tl(keys), tl(values), target) }
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
    if (cwd_env != nil) {
        raw = elem(shell("cd " ++ Util.shell_q(to_string(cwd_env)) ++
                         " && pwd || echo " ++ Util.shell_q(to_string(cwd_env))), 1)
        string_trim(to_string(raw))
    } else {
        # Ask /bin/sh rather than trusting $PWD: a launcher that chdir()s
        # without updating PWD (IDE integrations, subprocess(cwd=...), cron)
        # leaves it naming another directory, and the system prompt would
        # send the model's absolute paths there. sh keeps $PWD only when it
        # really is the current directory, so symlinked paths survive.
        string_trim(elem(shell("pwd"), 1))
    }
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
#
# The URL rules live in Config.is_local_endpoint. This startup check only
# sees the primary endpoint — so the refusal is explained up front — and
# llm.sw applies the same rule at the point of dial to every other URL
# (fallback, providers[], .profile_override).
fun verify_network_isolation(url, in_alt) {
    bypass = getenv("SWARM_CODE_ALLOW_REMOTE")
    if (bypass == "1") {
        print(" " ++ UI.warn_text("⚠ SWARM_CODE_ALLOW_REMOTE=1 — network isolation disabled"))
        "ok"
    }
    else { if (Config.is_local_endpoint(url) == 'true') {
        "ok"
    }
    else {
        host = Config.endpoint_host(url)
        host_shown = if (host == nil) { "(not a plain http(s)://host[:port] URL)" } else { host }
        # Hard refusal — if we're inside the optional alt screen, leave it
        # BEFORE printing: sys_exit would otherwise discard the explanation
        # with the alt buffer and leave the terminal un-restored.
        if (in_alt == 'true') { UI.leave_alt_screen() }
        print("")
        print(UI.brand_color() ++ "\e[1m⏺ swarm-code" ++ UI.reset() ++ " refuses to contact non-local endpoints.")
        print("")
        print(" endpoint : " ++ url)
        print(" host     : " ++ host_shown)
        print("")
        print(" This is to guarantee no conversation data leaves your")
        print(" network. swarm-code only allows http(s) URLs (no user@) to:")
        print("   - loopback:       127.*, ::1, localhost")
        print("   - private RFC1918: 10.*, 172.16-31.*, 192.168.*")
        print("   - Tailscale CGNAT: 100.64.0.0/10")
        print("   - IPv6 ULA / link-local: [fc00::/7], [fe80::/10]")
        print("   - .local hostnames (mDNS)")
        print("   - Tailscale MagicDNS hosts (*.ts.net, bare hostnames)")
        print("")
        print(" Set SWARM_CODE_ALLOW_REMOTE=1 to use a remote endpoint")
        print(" (an API key alone does not lift this check).")
        print("")
        sys_exit(1)
        "denied"
    }}
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

# ============================================================
# swarm doctor — pre-flight health check
# ============================================================
# Validates that everything swarm-code needs is in place + working:
#   * ~/.swarm-code/ directory tree exists
#   * settings.json parses + lists at least one profile
#   * active model / endpoint / api_key resolve via load_opts
#   * endpoint /v1/models responds with HTTP 200 (catches dead URLs,
#     bad api keys, expired auth)
#   * skill + memory + session journal directories present
#
# Returns 0 if all green, 1 if any ⚠ warning, 2 if any ✗ error.
# Designed for `swarm doctor && swarm` chaining.
fun run_doctor() {
    print("")
    print(UI.brand_color() ++ "⏺ swarm-code doctor" ++ UI.reset() ++
          UI.grey_text() ++ "  " ++ swarm_version() ++ UI.reset())
    print("")

    errors = 0
    warnings = 0

    # 1. Binary + version
    print("\e[1m1. binary\e[0m")
    print("   ✓ swarm-code " ++ swarm_version())
    print("")

    # 2. ~/.swarm-code/ tree
    print("\e[1m2. config tree\e[0m")
    home = getenv("HOME")
    if (home == nil) {
        print("   ✗ $HOME is not set — swarm-code has no place to put state")
        errors = errors + 1
    } else {
        base = home ++ "/.swarm-code"
        dirs = ["", "/memory", "/skills", "/sessions", "/telemetry", "/exports"]
        warnings = warnings + check_dirs(base, dirs, 0)
    }
    print("")

    # 3. settings.json
    print("\e[1m3. settings.json\e[0m")
    settings_path = if (home == nil) { "~/.swarm-code/settings.json" } else { home ++ "/.swarm-code/settings.json" }
    settings = Config.load()
    if (settings == nil || length(map_keys(settings)) == 0) {
        print("   ⚠ no settings.json at " ++ settings_path ++ " — defaults will be used")
        warnings = warnings + 1
    } else {
        print("   ✓ " ++ settings_path ++ " parses OK (" ++
              to_string(length(map_keys(settings))) ++ " top-level keys)")
        profiles = map_get(settings, 'profiles')
        if (profiles == nil) {
            print("   ⚠ no `profiles` map — only the root model is reachable")
            warnings = warnings + 1
        } else {
            n_profiles = length(map_keys(profiles))
            print("   ✓ " ++ to_string(n_profiles) ++ " profile(s): " ++
                  doctor_join_keys(map_keys(profiles), ""))
        }
    }
    print("")

    # 4. Active resolved config
    print("\e[1m4. active opts\e[0m")
    opts = load_opts()
    model = to_string(map_get(opts, 'model'))
    endpoint = to_string(map_get(opts, 'endpoint'))
    api_key = map_get(opts, 'api_key')
    print("   ✓ model:    " ++ model)
    print("   ✓ endpoint: " ++ endpoint)
    if (Config.endpoint_refusal(endpoint) != nil) {
        print("   ⚠ endpoint is not on the local network — swarm-code will refuse to start")
        print("     unless SWARM_CODE_ALLOW_REMOTE=1 (an API key alone is not enough)")
        warnings = warnings + 1
    }
    if (api_key == nil || string_length(to_string(api_key)) == 0) {
        print("   ⚠ api_key:  (not set — fine for local endpoints, fatal for remote)")
        warnings = warnings + 1
    } else {
        print("   ✓ api_key:  (set, " ++
              to_string(string_length(to_string(api_key))) ++ " chars)")
    }
    print("")

    # 5. Live endpoint check — /v1/models with auth
    print("\e[1m5. endpoint reachable\e[0m")
    models_url = if (string_ends_with(endpoint, "/chat/completions") == 'true') {
        # Strip /chat/completions, replace with /models
        string_sub(endpoint, 0, string_length(endpoint) - 17) ++ "/models"
    } else { if (string_ends_with(endpoint, "/v1") == 'true') {
        endpoint ++ "/models"
    } else {
        endpoint ++ "/v1/models"
    }}
    hdrs = if (api_key == nil) { [{"Accept", "application/json"}] }
           else { [{"Accept", "application/json"},
                   {"Authorization", "Bearer " ++ to_string(api_key)}] }
    # Same gate as the LLM layer: no request (and no API key) goes to a
    # remote host unless SWARM_CODE_ALLOW_REMOTE=1.
    refused = Config.endpoint_refusal(models_url)
    resp = if (refused != nil) { nil } else { http_get(models_url, hdrs) }
    if (refused != nil) {
        print("   - skipped: not contacting a remote endpoint without SWARM_CODE_ALLOW_REMOTE=1")
    } else { if (resp == nil) {
        print("   ✗ " ++ models_url ++ " — no response (network down? endpoint typo?)")
        errors = errors + 1
    } else {
        decoded = json_decode(resp)
        if (decoded == nil) {
            print("   ⚠ " ++ models_url ++ " — non-JSON reply (HTML error page?)")
            print("   " ++ UI.grey_text() ++ preview_doctor(resp, 100) ++ UI.reset())
            warnings = warnings + 1
        }
        else { if (map_get(decoded, 'error') != nil) {
            err = map_get(decoded, 'error')
            msg = map_get(err, 'message')
            print("   ✗ server returned error: " ++ to_string(msg))
            errors = errors + 1
        }
        else {
            data = map_get(decoded, 'data')
            if (data == nil) {
                print("   ⚠ endpoint responded but with no `data` field")
                warnings = warnings + 1
            } else {
                print("   ✓ " ++ models_url ++ " responded — " ++
                      to_string(length(data)) ++ " model(s) advertised")
            }
        }}
    }}
    print("")

    # 6. Skills / memory inventory
    print("\e[1m6. inventory\e[0m")
    if (home == nil) {
        print("   ✗ $HOME not set — cannot inspect inventory")
    } else {
        sk_dir = home ++ "/.swarm-code/skills"
        if (file_exists(sk_dir) == 'true') {
            sk = file_list(sk_dir)
            n_sk = count_subdirs_with(sk, sk_dir, "/SKILL.md", 0)
            print("   ✓ skills:   " ++ to_string(n_sk))
        } else {
            print("   - skills:   0  (dir not created yet)")
        }
        mem_dir = home ++ "/.swarm-code/memory"
        if (file_exists(mem_dir) == 'true') {
            ms = file_list(mem_dir)
            n_m = count_md_excluding(ms, "MEMORY.md", 0)
            print("   ✓ memories: " ++ to_string(n_m))
        } else {
            print("   - memories: 0  (dir not created yet)")
        }
        sess_dir = home ++ "/.swarm-code/sessions"
        if (file_exists(sess_dir) == 'true') {
            sf = file_list(sess_dir)
            n_s = count_starting_with(sf, "journal-", 0)
            print("   ✓ sessions: " ++ to_string(n_s) ++ " journals")
        }
    }
    print("")

    # Summary
    print("\e[1msummary\e[0m")
    if (errors == 0 && warnings == 0) {
        print(UI.brand_color() ++ "   ✓ all green — swarm-code is ready" ++ UI.reset())
        0
    } else { if (errors == 0) {
        print(UI.grey_text() ++ "   ⚠ " ++ to_string(warnings) ++
              " warning(s) — swarm-code will run, but check the items above" ++ UI.reset())
        1
    } else {
        print(UI.err_text("   ✗ " ++ to_string(errors) ++ " error(s), " ++
              to_string(warnings) ++ " warning(s) — fix the ✗ items before launching"))
        2
    }}
}

fun check_dirs(base, dirs, warns) {
    if (length(dirs) == 0) { warns }
    else {
        suffix = hd(dirs)
        path = base ++ suffix
        new_warns = if (file_exists(path) == 'true') {
            print("   ✓ " ++ path)
            warns
        } else {
            file_mkdir(path)
            if (file_exists(path) == 'true') {
                print("   ✓ " ++ path ++ UI.grey_text() ++ "  (created)" ++ UI.reset())
                warns
            } else {
                print("   ⚠ " ++ path ++ " — could not create")
                warns + 1
            }
        }
        check_dirs(base, tl(dirs), new_warns)
    }
}

fun doctor_join_keys(keys, acc) {
    if (length(keys) == 0) { acc }
    else {
        sep = if (string_length(acc) == 0) { "" } else { ", " }
        doctor_join_keys(tl(keys), acc ++ sep ++ to_string(hd(keys)))
    }
}

fun count_subdirs_with(entries, base, suffix, acc) {
    if (length(entries) == 0) { acc }
    else {
        e = hd(entries)
        new_acc = if (file_exists(base ++ "/" ++ e ++ suffix) == 'true') { acc + 1 }
                  else { acc }
        count_subdirs_with(tl(entries), base, suffix, new_acc)
    }
}

fun count_md_excluding(entries, skip, acc) {
    if (length(entries) == 0) { acc }
    else {
        e = hd(entries)
        new_acc = if (string_ends_with(e, ".md") == 'true' && e != skip) { acc + 1 }
                  else { acc }
        count_md_excluding(tl(entries), skip, new_acc)
    }
}

fun count_starting_with(entries, prefix, acc) {
    if (length(entries) == 0) { acc }
    else {
        e = hd(entries)
        new_acc = if (string_starts_with(e, prefix) == 'true') { acc + 1 } else { acc }
        count_starting_with(tl(entries), prefix, new_acc)
    }
}

fun preview_doctor(s, n) {
    if (string_length(s) <= n) { s }
    else { string_sub(s, 0, n) ++ "…" }
}
