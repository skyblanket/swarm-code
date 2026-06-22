module ToolRegistry

# ============================================================
# ToolRegistry — single source of truth for tool metadata
# ============================================================
#
# The old layout had parallel if/else chains over the same tool names:
#
#   * agent.sw    string_to_atom   (name → atom for dispatch)
#   * tools.sw    exec_raw         (atom → handler function)
#   * ToolSchemas.sw   all_schemas (atom → OpenAI tool schema)
#   * prompts.sw  tool_desc        (atom → inband description)
#
# Adding a new tool required touching all four in lockstep. This
# registry collapses the first job (string ↔ atom mapping) into a
# single table. Handlers, schemas, and prompt-text are still owned
# by their respective modules — sw's function-storage in maps isn't
# yet validated at our needed depth — but at least the name list
# itself lives in ONE place now.
#
# Migration path for the remaining duplications:
#   1. Extend each entry below with `schema` + `desc` fields.
#   2. Wire ToolSchemas.all_schemas to read entries[].schema.
#   3. Drive prompts.sw tool docs from entries[].desc.
#   4. (Hardest) confirm sw allows storing handler funs in a map,
#      then drive Tools.exec_raw() from entries[].handler.

export [
    all_tools, atom_for, knows,
    allowed_in, names_for, subagent_blocked_tools, council_panel_tools
]

fun all_tools() {
    [
        # core file/shell tools
        %{name: "bash",                 atom: 'bash'},
        %{name: "read",                 atom: 'read'},
        %{name: "write",                atom: 'write'},
        %{name: "edit",                 atom: 'edit'},
        %{name: "multi_edit",           atom: 'multi_edit'},
        %{name: "glob",                 atom: 'glob'},
        %{name: "grep",                 atom: 'grep'},

        # planning + web
        %{name: "todo_write",           atom: 'todo_write'},
        %{name: "web_fetch",            atom: 'web_fetch'},
        %{name: "web_search",           atom: 'web_search'},
        %{name: "task",                 atom: 'task'},

        # memory crumbs
        %{name: "remember",             atom: 'remember'},
        %{name: "recall",               atom: 'recall'},
        %{name: "memory_list",          atom: 'memory_list'},
        %{name: "forget",               atom: 'forget'},

        # skills (Hermes-style)
        %{name: "learn_skill",          atom: 'learn_skill'},
        %{name: "recall_skill",         atom: 'recall_skill'},
        %{name: "skill_list",           atom: 'skill_list'},
        %{name: "forget_skill",         atom: 'forget_skill'},

        # background jobs
        %{name: "background",           atom: 'background'},
        %{name: "bg_status",            atom: 'bg_status'},
        %{name: "bg_result",            atom: 'bg_result'},
        %{name: "bg_server",            atom: 'bg_server'},
        %{name: "bg_tail",              atom: 'bg_tail'},
        %{name: "bg_kill",              atom: 'bg_kill'},

        # telemetry / git / search
        %{name: "sys_stats",            atom: 'sys_stats'},
        %{name: "heartbeat_status",     atom: 'heartbeat_status'},
        %{name: "git_status",           atom: 'git_status'},
        %{name: "git_diff",             atom: 'git_diff'},
        %{name: "git_commit",           atom: 'git_commit'},
        %{name: "run_tests",            atom: 'run_tests'},
        %{name: "code_search",          atom: 'code_search'},
        %{name: "sw_check",             atom: 'sw_check'},
        %{name: "log_wait",             atom: 'log_wait'},
        %{name: "file_watch",           atom: 'file_watch'},

        # session FTS
        %{name: "session_search",       atom: 'session_search'},

        # vision
        %{name: "read_image",           atom: 'read_image'},

        # browser (CDP)
        %{name: "browser_launch",       atom: 'browser_launch'},
        %{name: "browser_navigate",     atom: 'browser_navigate'},
        %{name: "browser_click",        atom: 'browser_click'},
        %{name: "browser_type",         atom: 'browser_type'},
        %{name: "browser_screenshot",   atom: 'browser_screenshot'},
        %{name: "browser_get_text",     atom: 'browser_get_text'},
        %{name: "browser_get_html",     atom: 'browser_get_html'},
        %{name: "browser_evaluate",     atom: 'browser_evaluate'},
        %{name: "browser_close",        atom: 'browser_close'}
    ]
}

# Map a string name to its dispatcher atom. Returns the original
# string if unknown — that's how MCP tools (mcp__*) flow through
# without explicit registration; tools.sw exec_raw() detects the prefix.
fun atom_for(name) {
    s = to_string(name)
    atom_lookup(all_tools(), s)
}

fun atom_lookup(entries, name) {
    if (length(entries) == 0) { name }
    else {
        e = hd(entries)
        if (to_string(map_get(e, 'name')) == name) {
            map_get(e, 'atom')
        } else {
            atom_lookup(tl(entries), name)
        }
    }
}

# Is `name` a registered built-in tool? (Useful for permission UI
# that wants to enumerate the known tool set.)
fun knows(name) {
    s = to_string(name)
    knows_lookup(all_tools(), s)
}

fun knows_lookup(entries, name) {
    if (length(entries) == 0) { 'false' }
    else {
        e = hd(entries)
        if (to_string(map_get(e, 'name')) == name) { 'true' }
        else { knows_lookup(tl(entries), name) }
    }
}

# Context policy lives beside tool identity so new entry points do not
# invent their own allow/block lists. The main agent can use every tool.
fun allowed_in(context, name) {
    if (context == "mcp_server") {
        in_list(mcp_server_tools(), to_string(name))
    } else { if (context == "council_panel") {
        in_list(council_panel_tools(), to_string(name))
    } else { if (context == "council_judge") {
        'false'
    } else { if (context == "subagent") {
        if (in_list(subagent_blocked_tools(), to_string(name)) == 'true') {
            'false'
        } else { 'true' }
    } else { if (context == "main") { 'true' }
    else { 'false' }}}}}
}

fun names_for(context) {
    if (context == "mcp_server") { mcp_server_tools() }
    else { if (context == "council_panel") { council_panel_tools() }
    else { if (context == "council_judge") { [] }
    else { if (context == "main" || context == "subagent") {
        all_names(all_tools(), [])
    } else { [] }}}}
}

fun all_names(entries, acc) {
    if (length(entries) == 0) { acc }
    else {
        all_names(tl(entries), list_append(acc, to_string(map_get(hd(entries), 'name'))))
    }
}

fun mcp_server_tools() {
    ["bash", "read", "write", "edit", "glob", "grep", "web_fetch"]
}

fun subagent_blocked_tools() {
    ["task", "remember", "forget", "learn_skill", "forget_skill",
     "bg_server", "browser_launch", "git_commit", "todo_write"]
}

# Council panelists inspect the repository independently. Keep the first
# prototype read-only and non-recursive: no shell, writes, background work,
# memory mutation, browser control, or nested task delegation.
fun council_panel_tools() {
    ["read", "glob", "grep", "git_status", "git_diff", "code_search"]
}

fun in_list(lst, item) {
    if (length(lst) == 0) { 'false' }
    else { if (hd(lst) == item) { 'true' }
    else { in_list(tl(lst), item) }}
}
