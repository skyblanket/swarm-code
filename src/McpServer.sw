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
#   ping                    → {} (MCP basic/utilities/ping)
#   notifications/initialized → (notification, no reply needed)
#   tools/list              → list available tools
#   tools/call              → execute a tool, return text result
#                             (unknown tool → -32602 Invalid params)
#
# Envelope rules (JSON-RPC 2.0 + MCP basic/messages): "jsonrpc" must be
# exactly "2.0"; a request id must be a string or number (never null,
# an object, array or boolean) — violations get -32600 Invalid Request.
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

# tools/call param errors are -32602 Invalid params — including an
# unknown tool name (MCP spec, server/tools "Error Handling": "Unknown
# tools" → -32602). -32601 is reserved for an unknown METHOD.
fun handle_tools_call(id, params, opts) {
    pmap = if (params == nil) { %{} } else { params }
    name = if (is_map(pmap) == 'true') { map_get(pmap, 'name') } else { nil }
    raw_args = if (is_map(pmap) == 'true') { map_get(pmap, 'arguments') } else { nil }
    args = if (raw_args == nil) { %{} } else { raw_args }
    if (is_map(pmap) == 'false') {
        err_response(id, -32602, "invalid params: tools/call params must be an object")
    } else { if (name == nil) {
        err_response(id, -32602, "missing tool name")
    } else { if (typeof(name) != "string") {
        err_response(id, -32602, "invalid params: tool name must be a string")
    } else { if (is_map(args) == 'false') {
        err_response(id, -32602, "invalid params: arguments must be an object")
    } else {
        name_s = to_string(name)
        if (list_member(exposed_tool_names(), name_s) == 'false') {
            err_response(id, -32602, "unknown tool: " ++ name_s)
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
    }}}}
}

# ============================================================
# Dispatch a single parsed request
# ============================================================

# Key presence by name: json_decode keys are atoms and map_has_key
# reports 'false' for a key whose value is JSON null — but `"id": null`
# is a present-and-invalid id, not a Notification.
fun has_member(m, k) { member_scan(map_keys(m), k) }

fun member_scan(keys, k) {
    if (length(keys) == 0) { 'false' }
    else { if (to_string(hd(keys)) == k) { 'true' }
    else { member_scan(tl(keys), k) } }
}

# MCP (basic/messages): a request id MUST be a string or integer and
# MUST NOT be null. Numbers with a fraction are tolerated (JSON-RPC
# 2.0 only says SHOULD NOT); objects / arrays / booleans are rejected.
fun valid_id(v) {
    t = typeof(v)
    if (v == nil) { 'false' }
    else { if (t == "string" || t == "int" || t == "float") { 'true' }
    else { 'false' } }
}

# Validate the JSON-RPC 2.0 envelope. Returns nil when well-formed, or
# the -32600 Invalid Request error line. Per JSON-RPC §5 the error
# carries the request's id when that id was itself valid, else null.
fun envelope_error(msg) {
    has_id = has_member(msg, "id")
    id_raw = map_get(msg, 'id')
    id_ok = if (has_id == 'false') { 'true' } else { valid_id(id_raw) }
    reply_id = if (id_ok == 'true') { id_raw } else { nil }
    jsonrpc = map_get(msg, 'jsonrpc')
    method = map_get(msg, 'method')
    params = map_get(msg, 'params')
    if (jsonrpc != "2.0" || typeof(jsonrpc) != "string") {
        err_response(reply_id, -32600, "invalid request: \"jsonrpc\" must be exactly \"2.0\"")
    } else { if (id_ok == 'false') {
        err_response(nil, -32600, "invalid request: id must be a string or number (not null, object, array or boolean)")
    } else { if (method == nil) {
        # No method member: an Invalid Request, not an unknown method
        # (which would be -32601).
        err_response(reply_id, -32600, "invalid request: missing method")
    } else { if (typeof(method) != "string") {
        err_response(reply_id, -32600, "invalid request: method must be a string")
    } else { if (params != nil && is_map(params) == 'false' && is_list(params) == 'false') {
        err_response(reply_id, -32600, "invalid request: params must be an object or array")
    } else { nil }}}}}
}

fun dispatch(msg, opts) {
    invalid = envelope_error(msg)
    id = map_get(msg, 'id')
    method = map_get(msg, 'method')
    params = map_get(msg, 'params')
    method_s = if (method == nil) { "" } else { to_string(method) }

    if (invalid != nil) {
        invalid
    }
    # JSON-RPC 2.0 §4.1: a well-formed message without an `id` member is
    # a Notification — the server MUST NOT reply. The only notification
    # we act on is "notifications/initialized"; every other notification
    # (including notification-shaped initialize/tools/list/tools/call) is
    # silently ignored, with NO tool side-effects, mirroring the spec.
    # Returning nil suppresses output in server_loop (the `response !=
    # nil` gate).
    else { if (has_member(msg, "id") == 'false') {
        nil
    }
    else { if (method_s == "initialize") {
        handle_initialize(id)
    }
    else { if (method_s == "ping") {
        # MCP basic/utilities/ping: the receiver MUST respond promptly
        # with an empty result.
        ok_response(id, %{})
    }
    else { if (method_s == "notifications/initialized") {
        # A request-shaped (id-bearing) "initialized" is unusual, but
        # every request is owed a response — acknowledge it.
        ok_response(id, %{})
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
    }}}}}}}
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
