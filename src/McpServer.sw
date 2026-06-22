module McpServer

# ============================================================
# McpServer — stdio MCP server mode  (swarm --mcp-server)
# ============================================================
#
# Boots swarm-code as a JSON-RPC 2.0 MCP server over stdin/stdout.
# The client (e.g. Claude Code, another swarm-code instance, or any
# MCP-aware orchestrator) connects via stdin/stdout and calls the
# exposed tools directly — no LLM involved.
#
# Protocol: newline-delimited JSON (one message per line).
#
# Handled methods:
#   initialize              → server capabilities + info
#   notifications/initialized → (notification, no reply needed)
#   tools/list              → list available tools
#   tools/call              → execute a tool, return text result
#
# Exposed tools (a practical subset that covers 95% of coding tasks):
#   bash, read, write, edit, glob, grep, web_fetch
#
# Transport: stdout carries JSON-RPC responses only. The startup
# "ready" banner goes to stderr so it doesn't corrupt the stream.

import ToolExecutor
import ToolSchemas
import ToolRegistry
import Util
import Version

export [run]

# ============================================================
# Server info
# ============================================================
fun server_name()    { "swarm-code" }
fun server_version() { Version.version() }
fun protocol_version() { "2025-06-18" }

# The subset of ToolSchemas tools we expose as an MCP server.
# Omits LLM-centric tools (task, remember, recall, session_search,
# skills, background, browser, todo_write) — those require a live
# agent context. The caller already HAS an agent; it needs execution.
fun exposed_tool_names() {
    ToolRegistry.names_for("mcp_server")
}

# Filter all_schemas() down to the names we expose.
fun exposed_schemas() {
    filter_schemas(ToolSchemas.all_schemas(), exposed_tool_names(), [])
}

fun filter_schemas(schemas, names, acc) {
    if (length(schemas) == 0) { acc }
    else {
        s = hd(schemas)
        fn_map = map_get(s, 'function')
        name = if (fn_map == nil) { nil } else { to_string(map_get(fn_map, 'name')) }
        if (list_member(names, name) == 'true') {
            filter_schemas(tl(schemas), names, acc ++ [s])
        } else {
            filter_schemas(tl(schemas), names, acc)
        }
    }
}

fun list_member(lst, item) {
    if (length(lst) == 0) { 'false' }
    else { if (hd(lst) == item) { 'true' }
    else { list_member(tl(lst), item) }}
}

# ============================================================
# MCP-shaped tool list (tools/list response format)
# ============================================================
# MCP's tools/list returns objects with {name, description, inputSchema}
# while our ToolSchemas use OpenAI's {type, function: {name, desc, parameters}}.
# Convert here so we speak the MCP wire format correctly.

fun to_mcp_tools(schemas, acc) {
    if (length(schemas) == 0) { acc }
    else {
        s = hd(schemas)
        fn_map = map_get(s, 'function')
        if (fn_map == nil) {
            to_mcp_tools(tl(schemas), acc)
        } else {
            name = map_get(fn_map, 'name')
            desc = map_get(fn_map, 'description')
            params = map_get(fn_map, 'parameters')
            mcp_tool = %{
                name: name,
                description: desc,
                inputSchema: params
            }
            to_mcp_tools(tl(schemas), acc ++ [mcp_tool])
        }
    }
}

# ============================================================
# Response builders
# ============================================================

fun ok_response(id, result) {
    json_encode(%{jsonrpc: "2.0", id: id, result: result})
}

fun err_response(id, code, message) {
    json_encode(%{
        jsonrpc: "2.0",
        id: id,
        error: %{code: code, message: message}
    })
}

fun tool_result_response(id, text) {
    json_encode(%{
        jsonrpc: "2.0",
        id: id,
        result: %{
            content: [%{type: "text", text: text}]
        }
    })
}

fun tool_error_response(id, text) {
    json_encode(%{
        jsonrpc: "2.0",
        id: id,
        result: %{
            content: [%{type: "text", text: text}],
            isError: 'true'
        }
    })
}

# ============================================================
# Request handlers
# ============================================================

fun handle_initialize(id) {
    ok_response(id, %{
        protocolVersion: protocol_version(),
        capabilities: %{tools: %{}},
        serverInfo: %{name: server_name(), version: server_version()}
    })
}

fun handle_tools_list(id) {
    mcp_tools = to_mcp_tools(exposed_schemas(), [])
    ok_response(id, %{tools: mcp_tools})
}

fun handle_tools_call(id, params, opts) {
    name = if (params == nil) { nil } else { map_get(params, 'name') }
    args = if (params == nil) { %{} } else {
        raw = map_get(params, 'arguments')
        if (raw == nil) { %{} } else { raw }
    }
    if (name == nil) {
        err_response(id, -32602, "missing tool name")
    } else {
        name_s = to_string(name)
        if (list_member(exposed_tool_names(), name_s) == 'false') {
            err_response(id, -32601, "tool not found: " ++ name_s)
        } else {
            # ToolRegistry.atom_for converts "bash" → 'bash' so the shared
            # execution boundary can reach the raw handler registry.
            name_atom = ToolRegistry.atom_for(name_s)
            # Determine isError STRUCTURALLY from the execution outcome, not
            # by sniffing the payload for an "error:" prefix (which mis-flags
            # legitimate file content and misses non-zero bash exits).
            outcome = ToolExecutor.execute_outcome(name_atom, args, opts)
            result_s = to_string(map_get(outcome, 'text'))
            if (map_get(outcome, 'ok') == 'false') {
                tool_error_response(id, result_s)
            } else {
                tool_result_response(id, result_s)
            }
        }
    }
}

# ============================================================
# Dispatch a single parsed request
# ============================================================

fun dispatch(msg, opts) {
    id = map_get(msg, 'id')
    method = map_get(msg, 'method')
    params = map_get(msg, 'params')
    method_s = if (method == nil) { "" } else { to_string(method) }

    # JSON-RPC 2.0 §4.1: a message without `id` is a Notification — the
    # server MUST NOT reply. The only notification we act on is
    # "notifications/initialized"; every other notification (including
    # notification-shaped initialize/tools/list/tools/call) is silently
    # ignored, with NO tool side-effects, mirroring the spec. Returning
    # nil here suppresses output in server_loop (the `response != nil` gate).
    if (id == nil) {
        nil
    }
    else { if (method == nil) {
        # Request with no method member is an Invalid Request, not an
        # unknown method (which would be -32601).
        err_response(id, -32600, "invalid request: missing method")
    }
    else { if (method_s == "initialize") {
        handle_initialize(id)
    }
    else { if (method_s == "notifications/initialized") {
        # A request-shaped (id-bearing) "initialized" is unusual but the
        # notification path above already handles the normal no-id case.
        nil
    }
    else { if (method_s == "tools/list") {
        handle_tools_list(id)
    }
    else { if (method_s == "tools/call") {
        handle_tools_call(id, params, opts)
    }
    else {
        # Known shape, unrecognized method name.
        err_response(id, -32601, "method not found: " ++ method_s)
    }}}}}}
}

# ============================================================
# Main server loop
# ============================================================

fun run(opts) {
    # Signal readiness on stderr so it doesn't corrupt the JSON-RPC stdout.
    shell("echo '[swarm-code mcp-server] ready' 1>&2")
    server_loop(opts)
}

fun server_loop(opts) {
    line = read_line("")
    if (line == nil) {
        # EOF — client disconnected, clean exit
        'ok'
    } else {
        trimmed = string_trim(line)
        if (string_length(trimmed) == 0) {
            # Empty line — ignore and continue
            server_loop(opts)
        } else {
            msg = json_decode(trimmed)
            if (msg == nil) {
                # Non-JSON input — send parse error with null id
                resp = json_encode(%{
                    jsonrpc: "2.0",
                    id: nil,
                    error: %{code: -32700, message: "parse error"}
                })
                print(resp)
                server_loop(opts)
            } else { if (is_map(msg) == 'false') {
                # Structurally-valid JSON that is NOT a request object — a
                # batch array, or a bare scalar. We do not support batching,
                # so per JSON-RPC 2.0 §4.2 reject with a single Invalid
                # Request error rather than silently dropping it (which would
                # hang a client waiting for responses).
                resp = json_encode(%{
                    jsonrpc: "2.0",
                    id: nil,
                    error: %{code: -32600, message: "invalid request: batch requests are not supported"}
                })
                print(resp)
                server_loop(opts)
            } else {
                response = dispatch(msg, opts)
                if (response != nil) {
                    print(to_string(response))
                }
                server_loop(opts)
            }}
        }
    }
}
