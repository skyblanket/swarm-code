module Mcp

# ============================================================
# Mcp — Model Context Protocol client (stdio transport)
# ============================================================
#
# Connects swarm-code to external MCP servers: long-lived child
# processes that speak JSON-RPC 2.0 over stdin/stdout, one message
# per line. Each server exposes a set of tools; swarm-code discovers
# them at boot and folds them into its own tool surface under
# namespaced names `mcp__<server>__<tool>`.
#
# Configuration — settings.json (user-global or project-local):
#   "mcpServers": {
#     "github": {
#       "command": "npx",
#       "args": ["-y", "@modelcontextprotocol/server-github"],
#       "env": { "GITHUB_TOKEN": "ghp_..." }
#     }
#   }
#
# Architecture — the swarm-code way, everything is a process:
#   * init() runs at boot in Main's process. It spawns every server
#     subprocess, performs the JSON-RPC handshake (initialize →
#     notifications/initialized → tools/list), and records the
#     discovered tools in an ETS table.
#   * Per server, one long-lived `mcp_owner_loop` sw process owns the
#     subprocess handle. ALL tools/call traffic funnels through its
#     mailbox — that serialises concurrent calls (the main agent and
#     any subagents) onto the single stdio pipe, so writes never
#     interleave and no process steals another's response line. This
#     is precisely an Erlang port: a foreign process with exactly one
#     connected owner.
#   * call_tool(), invoked from Tools.exec, messages the owner and
#     blocks on the reply — the same pattern as Agents.ask_tool.
#
# Transport detail: swarmrt's subprocess_* builtins give a
# bidirectional, line-buffered pipe to a child. MCP stdio is
# newline-delimited JSON with no embedded newlines, which maps onto
# subprocess_send_line / subprocess_recv_line with zero impedance.
#
# Mcp imports nothing: Tools imports Mcp (for dispatch), so Mcp must
# not import Tools — the dependency graph stays acyclic.

export [init, call_tool, all_schemas, as_prompt_section, list_servers, shutdown]

# ------------------------------------------------------------
# Tunables
# ------------------------------------------------------------
# Handshake budget per server. Generous because `npx` may download
# the server package from the registry on its first run.
fun mcp_handshake_timeout_ms() { 30000 }
# tools/call budget — an MCP tool may itself reach a slow remote API.
fun mcp_call_timeout_ms() { 120000 }
# MCP protocol revision we advertise; servers negotiate down if older.
fun mcp_protocol_version() { "2025-06-18" }

# ------------------------------------------------------------
# ANSI — local copies (Mcp imports nothing; see header).
# ------------------------------------------------------------
fun mcp_brand()  { "\e[38;5;124m" }
fun mcp_dim()    { "\e[38;5;240m" }
fun mcp_warn_c() { "\e[38;5;208m" }
fun mcp_reset()  { "\e[0m" }

# Per-server stderr log — keeps npm/npx chatter and the server's own
# logging off the JSON-RPC stdout stream and out of the terminal.
fun mcp_log_path(server) {
    getenv("HOME") ++ "/.swarm-code/mcp-" ++ server ++ ".log"
}

# ============================================================
# init — boot-time spawn, handshake, tool discovery
# ============================================================
# Returns an ETS table that becomes opts['mcp_table']. When no
# mcpServers are configured it returns an empty table silently — MCP
# must be zero-cost and invisible when unused.
#
# Table layout:
#   'all_servers'        → [server_name, ...]  (every configured one)
#   <server>/status      → "ok" | "failed"
#   <server>/error       → failure reason (when failed)
#   <server>/handle      → subprocess handle int (when ok)
#   <server>/pid         → owner process pid    (when ok)
#   <server>/tools       → raw tool maps from tools/list (when ok)
#   "tool/" ++ prefixed  → %{server, tool}  reverse map for dispatch
fun init(settings) {
    table = ets_new()
    ets_put(table, 'all_servers', [])
    servers = if (settings == nil) { nil } else { map_get(settings, 'mcpServers') }
    if (servers == nil) {
        table
    } else {
        names = map_keys(servers)
        specs = map_values(servers)
        if (length(names) == 0) {
            table
        } else {
            print("")
            print("  " ++ mcp_brand() ++ "⏺" ++ mcp_reset() ++ " \e[1mMCP\e[0m " ++
                  mcp_dim() ++ "— starting " ++ to_string(length(names)) ++
                  " server(s)…" ++ mcp_reset())
            # Pass 1: spawn every subprocess and fire its initialize
            # request. Doing all spawns up front overlaps the slow
            # part — an npx package download — across servers.
            handles = mcp_spawn_all(names, specs, [])
            # Pass 2: finish each handshake, list tools, spawn owners.
            mcp_handshake_all(table, handles)
            table
        }
    }
}

# Pass 1 — spawn + send initialize. Returns [{name, handle}, ...];
# handle is -1 if the spawn could not even start.
fun mcp_spawn_all(names, specs, acc) {
    if (length(names) == 0) { acc }
    else {
        name = to_string(hd(names))
        spec = hd(specs)
        cmd = mcp_build_command(name, spec)
        handle = if (cmd == nil) { 0 - 1 } else { subprocess_spawn(cmd) }
        if (handle >= 0) {
            subprocess_send_line(handle, mcp_initialize_request())
        }
        mcp_spawn_all(tl(names), tl(specs), list_append(acc, {name, handle}))
    }
}

fun mcp_initialize_request() {
    json_encode(%{
        jsonrpc: "2.0",
        id: 0,
        method: "initialize",
        params: %{
            protocolVersion: mcp_protocol_version(),
            capabilities: %{},
            clientInfo: %{ name: "swarm-code", version: "0.1.0" }
        }
    })
}

# Build the /bin/sh command line for a server spec:
#   KEY='val' … command arg1 arg2 … 2>>~/.swarm-code/mcp-<name>.log
fun mcp_build_command(name, spec) {
    command = if (spec == nil) { nil } else { map_get(spec, 'command') }
    if (command == nil) { nil }
    else {
        args = map_get(spec, 'args')
        env = map_get(spec, 'env')
        env_part = if (env == nil) { "" }
                   else { mcp_env_prefix(map_keys(env), map_values(env), "") }
        args_part = if (args == nil) { "" } else { mcp_args_str(args, "") }
        env_part ++ mcp_shq(to_string(command)) ++ args_part ++
            " 2>>" ++ mcp_shq(mcp_log_path(name))
    }
}

fun mcp_env_prefix(keys, vals, acc) {
    if (length(keys) == 0) { acc }
    else {
        k = to_string(hd(keys))
        v = to_string(hd(vals))
        mcp_env_prefix(tl(keys), tl(vals), acc ++ k ++ "=" ++ mcp_shq(v) ++ " ")
    }
}

fun mcp_args_str(args, acc) {
    if (length(args) == 0) { acc }
    else { mcp_args_str(tl(args), acc ++ " " ++ mcp_shq(to_string(hd(args)))) }
}

# Single-quote shell escape (local — Mcp can't import Tools).
fun mcp_shq(s) {
    "'" ++ string_replace(s, "'", "'\\''") ++ "'"
}

# Pass 2 — finish each server's handshake.
fun mcp_handshake_all(table, handles) {
    if (length(handles) == 0) { 'ok' }
    else {
        entry = hd(handles)
        mcp_handshake_one(table, elem(entry, 0), elem(entry, 1))
        mcp_handshake_all(table, tl(handles))
    }
}

fun mcp_handshake_one(table, name, handle) {
    # Record the server as configured regardless of outcome, so /mcp
    # can surface failures.
    cur = ets_get(table, 'all_servers')
    ets_put(table, 'all_servers', cur ++ [name])

    if (handle < 0) {
        mcp_fail(table, name, handle, "could not spawn subprocess")
    } else {
        deadline = timestamp() + mcp_handshake_timeout_ms()
        init_resp = mcp_read_response(handle, 0, deadline)
        if (init_resp == nil) {
            mcp_fail(table, name, handle,
                "no response to initialize — see " ++ mcp_log_path(name))
        } else {
            ierr = map_get(init_resp, 'error')
            if (ierr != nil) {
                mcp_fail(table, name, handle,
                    "initialize rejected: " ++ to_string(map_get(ierr, 'message')))
            } else {
                # Handshake step 2: announce we're initialised.
                subprocess_send_line(handle,
                    json_encode(%{jsonrpc: "2.0", method: "notifications/initialized"}))
                # Step 3: discover tools (follows nextCursor pagination).
                tools = mcp_list_tools(handle, 1, nil, [])
                if (tools == nil) {
                    mcp_fail(table, name, handle, "tools/list failed")
                } else {
                    mcp_register(table, name, handle, tools)
                }
            }
        }
    }
}

fun mcp_fail(table, name, handle, why) {
    if (handle >= 0) { subprocess_close(handle) }
    ets_put(table, name ++ "/status", "failed")
    ets_put(table, name ++ "/error", why)
    print("  " ++ mcp_warn_c() ++ "⚠ MCP server '" ++ name ++ "' — " ++ why ++ mcp_reset())
    'failed'
}

# tools/list with cursor pagination. Returns the full tool list, or
# nil on a transport / protocol failure.
fun mcp_list_tools(handle, id, cursor, acc) {
    params = if (cursor == nil) { %{} } else { %{cursor: cursor} }
    req = %{jsonrpc: "2.0", id: id, method: "tools/list", params: params}
    sent = subprocess_send_line(handle, json_encode(req))
    if (sent != 'ok') { nil }
    else {
        resp = mcp_read_response(handle, id, timestamp() + mcp_handshake_timeout_ms())
        if (resp == nil) { nil }
        else {
            err = map_get(resp, 'error')
            if (err != nil) { nil }
            else {
                result = map_get(resp, 'result')
                if (result == nil) { acc }
                else {
                    page = map_get(result, 'tools')
                    acc2 = if (page == nil) { acc } else { acc ++ page }
                    nxt = map_get(result, 'nextCursor')
                    if (nxt == nil) { acc2 }
                    else { mcp_list_tools(handle, id + 1, nxt, acc2) }
                }
            }
        }
    }
}

# Register a successfully-handshaken server: store its tools, build
# the prefixed-name reverse map, spawn the owner process.
fun mcp_register(table, name, handle, tools) {
    owner = spawn(mcp_owner_loop(name, handle, 100))
    ets_put(table, name ++ "/status", "ok")
    ets_put(table, name ++ "/handle", handle)
    ets_put(table, name ++ "/pid", owner)
    ets_put(table, name ++ "/tools", tools)
    mcp_index_tools(table, name, tools)
    print("  " ++ mcp_brand() ++ "⏺" ++ mcp_reset() ++ " " ++ name ++
          mcp_dim() ++ " — " ++ to_string(length(tools)) ++ " tool(s) ready" ++ mcp_reset())
    'ok'
}

# Store, per tool, a reverse mapping prefixed-name → %{server, tool}.
# call_tool resolves the model's prefixed call back through this — so
# it stays correct even if a tool's own name happens to contain '__'.
fun mcp_index_tools(table, server, tools) {
    if (length(tools) == 0) { 'ok' }
    else {
        tool = hd(tools)
        bare = map_get(tool, 'name')
        if (bare != nil) {
            prefixed = mcp_prefixed(server, to_string(bare))
            ets_put(table, "tool/" ++ prefixed, %{server: server, tool: to_string(bare)})
        }
        mcp_index_tools(table, server, tl(tools))
    }
}

fun mcp_prefixed(server, bare) { "mcp__" ++ server ++ "__" ++ bare }

# ============================================================
# Owner process — one per server, owns the stdio handle
# ============================================================
# Serialises tools/call traffic. Between calls it parks in receive;
# during a call it blocks reading the pipe (occupying one of swarmrt's
# scheduler threads, released the moment the call returns).
fun mcp_owner_loop(name, handle, next_id) {
    receive {
        {'mcp_call', tool_name, args, reply_pid} ->
            result = mcp_do_call(handle, next_id, tool_name, args)
            if (reply_pid != nil) { send(reply_pid, {'mcp_result', result}) }
            mcp_owner_loop(name, handle, next_id + 1)
        _other ->
            mcp_owner_loop(name, handle, next_id)
    }
}

# Issue one tools/call and return the result as a tool-result string.
fun mcp_do_call(handle, id, tool_name, args) {
    args_obj = if (args == nil) { %{} } else { args }
    req = %{
        jsonrpc: "2.0",
        id: id,
        method: "tools/call",
        params: %{ name: tool_name, arguments: args_obj }
    }
    sent = subprocess_send_line(handle, json_encode(req))
    if (sent != 'ok') {
        "error: MCP server connection lost (write failed)"
    } else {
        resp = mcp_read_response(handle, id, timestamp() + mcp_call_timeout_ms())
        if (resp == nil) {
            "error: MCP server did not respond (timed out or connection closed)"
        } else {
            mcp_format_result(resp)
        }
    }
}

# Drain JSON-RPC lines off the pipe until the response with `want_id`
# arrives, skipping notifications and server→client requests (whose
# id won't match). Bounded by `deadline` (a timestamp() value).
fun mcp_read_response(handle, want_id, deadline) {
    now = timestamp()
    if (now >= deadline) { nil }
    else {
        line = subprocess_recv_line(handle, deadline - now)
        if (line == nil) {
            nil
        } else {
            decoded = json_decode(line)
            if (decoded == nil) {
                # Non-JSON line on stdout (a stray banner) — skip it.
                mcp_read_response(handle, want_id, deadline)
            } else {
                rid = map_get(decoded, 'id')
                if (rid == want_id) { decoded }
                else { mcp_read_response(handle, want_id, deadline) }
            }
        }
    }
}

# Turn a JSON-RPC tools/call response into a string for the model.
fun mcp_format_result(resp) {
    err = map_get(resp, 'error')
    if (err != nil) {
        em = map_get(err, 'message')
        "error: MCP — " ++ (if (em == nil) { "call failed" } else { to_string(em) })
    } else {
        result = map_get(resp, 'result')
        if (result == nil) {
            "error: MCP response carried no result"
        } else {
            content = map_get(result, 'content')
            text = if (content == nil) { "" } else { mcp_extract_text(content, "") }
            body = if (string_length(string_trim(text)) == 0) { "(tool returned no text content)" }
                   else { text }
            is_err = map_get(result, 'isError')
            if (is_err == 'true') { "error: " ++ body } else { body }
        }
    }
}

# Concatenate the text blocks of an MCP content array. Non-text
# blocks (image / audio / resource) are noted, not dropped silently.
fun mcp_extract_text(items, acc) {
    if (length(items) == 0) { acc }
    else {
        item = hd(items)
        t = map_get(item, 'type')
        piece = if (t == "text") {
            tx = map_get(item, 'text')
            if (tx == nil) { "" } else { to_string(tx) }
        } else {
            "[" ++ (if (t == nil) { "non-text" } else { to_string(t) }) ++ " content omitted]"
        }
        sep = if (string_length(acc) == 0) { "" } else { "\n" }
        mcp_extract_text(tl(items), acc ++ sep ++ piece)
    }
}

# ============================================================
# call_tool — dispatch entry, invoked from Tools.exec
# ============================================================
# `prefixed` is the full mcp__<server>__<tool> name the model called.
fun call_tool(prefixed, args, opts) {
    table = map_get(opts, 'mcp_table')
    if (table == nil) {
        "error: MCP is not initialised"
    } else {
        info = ets_get(table, "tool/" ++ to_string(prefixed))
        if (info == nil) {
            "error: unknown MCP tool '" ++ to_string(prefixed) ++
                "' (run /mcp to see available servers and tools)"
        } else {
            server = to_string(map_get(info, 'server'))
            tool = to_string(map_get(info, 'tool'))
            status = ets_get(table, server ++ "/status")
            if (status != "ok") {
                "error: MCP server '" ++ server ++ "' is not running"
            } else {
                owner = ets_get(table, server ++ "/pid")
                if (owner == nil) {
                    "error: MCP server '" ++ server ++ "' has no owner process"
                } else {
                    send(owner, {'mcp_call', tool, args, self()})
                    receive {
                        {'mcp_result', r} -> r
                        after 130000 {
                            "error: MCP call to '" ++ server ++ "' got no reply (owner stalled)"
                        }
                    }
                }
            }
        }
    }
}

# ============================================================
# all_schemas — OpenAI function schemas for native tool-calling
# ============================================================
# Called once after init(); the result is stashed in opts and merged
# into the request `tools` array by llm.sw's native_req. Every MCP
# tool already self-describes with a JSON Schema (inputSchema), which
# drops straight into the OpenAI function `parameters`.
fun all_schemas(table) {
    if (table == nil) { [] }
    else {
        servers = ets_get(table, 'all_servers')
        if (servers == nil) { [] }
        else { mcp_schemas_for(table, servers, []) }
    }
}

fun mcp_schemas_for(table, servers, acc) {
    if (length(servers) == 0) { acc }
    else {
        server = to_string(hd(servers))
        status = ets_get(table, server ++ "/status")
        next = if (status != "ok") { acc }
               else {
                   tools = ets_get(table, server ++ "/tools")
                   if (tools == nil) { acc }
                   else { mcp_tool_schemas(server, tools, acc) }
               }
        mcp_schemas_for(table, tl(servers), next)
    }
}

fun mcp_tool_schemas(server, tools, acc) {
    if (length(tools) == 0) { acc }
    else {
        tool = hd(tools)
        bare = map_get(tool, 'name')
        if (bare == nil) {
            mcp_tool_schemas(server, tl(tools), acc)
        } else {
            desc = map_get(tool, 'description')
            schema = map_get(tool, 'inputSchema')
            params = if (schema == nil) { %{type: "object", properties: %{}} } else { schema }
            entry = %{
                type: "function",
                function: %{
                    name: mcp_prefixed(server, to_string(bare)),
                    description: (if (desc == nil) { "MCP tool " ++ to_string(bare) }
                                  else { to_string(desc) }),
                    parameters: params
                }
            }
            mcp_tool_schemas(server, tl(tools), list_append(acc, entry))
        }
    }
}

# ============================================================
# as_prompt_section — prose tool list for the system prompt
# ============================================================
fun as_prompt_section(table) {
    if (table == nil) { "" }
    else {
        servers = ets_get(table, 'all_servers')
        if (servers == nil || length(servers) == 0) { "" }
        else {
            body = mcp_prompt_servers(table, servers, "")
            if (string_length(body) == 0) { "" }
            else {
                "\n\n=== MCP TOOLS ===\n" ++
                "Beyond your built-in tools, these come from external MCP " ++
                "servers the user configured. Call them exactly like any " ++
                "other tool, by their full prefixed name. Each one's argument " ++
                "shape is its own — pass arguments as a JSON object.\n\n" ++ body
            }
        }
    }
}

fun mcp_prompt_servers(table, servers, acc) {
    if (length(servers) == 0) { acc }
    else {
        server = to_string(hd(servers))
        status = ets_get(table, server ++ "/status")
        next = if (status != "ok") { acc }
               else {
                   tools = ets_get(table, server ++ "/tools")
                   if (tools == nil) { acc }
                   else {
                       hdr = acc ++ "From MCP server \"" ++ server ++ "\":\n"
                       mcp_prompt_tools(server, tools, hdr) ++ "\n"
                   }
               }
        mcp_prompt_servers(table, tl(servers), next)
    }
}

fun mcp_prompt_tools(server, tools, acc) {
    if (length(tools) == 0) { acc }
    else {
        tool = hd(tools)
        bare = map_get(tool, 'name')
        if (bare == nil) {
            mcp_prompt_tools(server, tl(tools), acc)
        } else {
            desc = map_get(tool, 'description')
            d = if (desc == nil) { "" } else { mcp_truncate(to_string(desc), 200) }
            line = "- " ++ mcp_prefixed(server, to_string(bare)) ++
                   (if (string_length(d) == 0) { "" } else { ": " ++ d }) ++ "\n"
            mcp_prompt_tools(server, tl(tools), acc ++ line)
        }
    }
}

fun mcp_truncate(s, cap) {
    if (string_length(s) <= cap) { s }
    else { string_sub(s, 0, cap) ++ "…" }
}

# ============================================================
# list_servers — rendered for the /mcp slash command
# ============================================================
fun list_servers(table) {
    if (table == nil) { "MCP not initialised" }
    else {
        servers = ets_get(table, 'all_servers')
        if (servers == nil || length(servers) == 0) {
            "no MCP servers configured\n" ++
            "  add an \"mcpServers\" block to ~/.swarm-code/settings.json"
        } else {
            mcp_list_loop(table, servers, "")
        }
    }
}

fun mcp_list_loop(table, servers, acc) {
    if (length(servers) == 0) { acc }
    else {
        server = to_string(hd(servers))
        status = ets_get(table, server ++ "/status")
        line = if (status == "ok") {
            tools = ets_get(table, server ++ "/tools")
            n = if (tools == nil) { 0 } else { length(tools) }
            "  " ++ mcp_brand() ++ "⏺" ++ mcp_reset() ++ " " ++ server ++
                mcp_dim() ++ "  ok · " ++ to_string(n) ++ " tools" ++ mcp_reset() ++ "\n" ++
                mcp_list_tool_names(server, tools, "")
        } else {
            err = ets_get(table, server ++ "/error")
            "  " ++ mcp_warn_c() ++ "⚠" ++ mcp_reset() ++ " " ++ server ++
                mcp_dim() ++ "  failed — " ++
                (if (err == nil) { "unknown" } else { to_string(err) }) ++
                mcp_reset() ++ "\n"
        }
        mcp_list_loop(table, tl(servers), acc ++ line)
    }
}

fun mcp_list_tool_names(server, tools, acc) {
    if (tools == nil || length(tools) == 0) { acc }
    else {
        tool = hd(tools)
        bare = map_get(tool, 'name')
        line = if (bare == nil) { "" }
               else { "      " ++ mcp_dim() ++ mcp_prefixed(server, to_string(bare)) ++
                       mcp_reset() ++ "\n" }
        mcp_list_tool_names(server, tl(tools), acc ++ line)
    }
}

# ============================================================
# shutdown — close every server subprocess (called on /quit)
# ============================================================
# Closes the stdio handles directly rather than messaging the owner
# processes: handle_eof calls sys_exit(0) right after, which would
# kill the owners before they could be scheduled. subprocess_close
# closes the child's stdin (graceful for MCP servers) then SIGTERMs
# it, so the servers don't leak as orphans.
fun shutdown(table) {
    if (table == nil) { 'ok' }
    else {
        servers = ets_get(table, 'all_servers')
        if (servers == nil) { 'ok' }
        else { mcp_shutdown_loop(table, servers) }
    }
}

fun mcp_shutdown_loop(table, servers) {
    if (length(servers) == 0) { 'ok' }
    else {
        server = to_string(hd(servers))
        handle = ets_get(table, server ++ "/handle")
        if (handle != nil && handle >= 0) { subprocess_close(handle) }
        mcp_shutdown_loop(table, tl(servers))
    }
}
