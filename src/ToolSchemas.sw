module ToolSchemas

# ============================================================
# Tool schemas — OpenAI-compatible function calling
# ============================================================
#
# When a model supports native function calling (GLM, OpenAI, Anthropic,
# Groq, xAI, DeepSeek, etc.), we send tool schemas in the request's
# `tools` array instead of describing them inline as prose. The model
# then emits structured `tool_calls` in the response, which we transcode
# back into swarm-code's internal `call:NAME{JSON}` format so agent.sw
# can keep using the same extraction pipeline.
#
# Schemas describe the argument shape for the 13 core tools. The long
# tail of bg_*, git_*, code_search, heartbeat_status etc. still work —
# they just don't get typed schemas; the model can discover them from
# the prose description in the system prompt. We can add more schemas
# later if we see the model missing them.

export [all_schemas, all_schemas_json]

fun all_schemas() {
    [bash_s(), read_s(), write_s(), edit_s(), multi_edit_s(),
     glob_s(), grep_s(), todo_write_s(), web_search_s(), web_fetch_s(),
     remember_s(), recall_s(), memory_list_s(),
     spawn_agent_s(), ask_s(), tell_s(), list_agents_s(), kill_s(), parallel_s()]
}

# Return the schemas as JSON array string, ready for embedding in a
# request body that's already being json_encode'd. Safer than relying
# on the outer encoder to recurse through atom-keyed maps.
fun all_schemas_json() {
    json_encode(all_schemas())
}

# ---------- helpers ----------

fun tool(name, desc, params) {
    %{
        type: "function",
        function: %{
            name: name,
            description: desc,
            parameters: params
        }
    }
}

fun obj(properties, required) {
    %{
        type: "object",
        properties: properties,
        required: required
    }
}

fun s(desc) { %{type: "string", description: desc} }
fun i(desc) { %{type: "integer", description: desc} }
fun b(desc) { %{type: "boolean", description: desc} }
fun arr(items, desc) { %{type: "array", items: items, description: desc} }

# ---------- schemas ----------

fun bash_s() {
    tool("bash",
        "Execute a shell command. Use for running tests, builds, git, file " ++
        "operations, and any other system task. Commands run in /bin/sh with " ++
        "a 120s default timeout.",
        obj(%{command: s("The shell command to execute")}, ["command"]))
}

fun read_s() {
    tool("read",
        "Read a file from the local filesystem. Returns the full content with " ++
        "line numbers. Prefer this over `cat` in bash when you just need to " ++
        "see file contents.",
        obj(%{
            path: s("Absolute path to the file"),
            offset: i("Optional: start line (1-indexed)"),
            limit: i("Optional: number of lines to read")
        }, ["path"]))
}

fun write_s() {
    tool("write",
        "Write (or overwrite) a file with the given content. Creates parent " ++
        "directories as needed. Use `edit` for targeted changes to existing files.",
        obj(%{
            path: s("Absolute path to the file"),
            content: s("Full content to write")
        }, ["path", "content"]))
}

fun edit_s() {
    tool("edit",
        "Replace an exact string in a file with another. The `old_string` " ++
        "must appear exactly once (or pass replace_all=true). Preserve " ++
        "surrounding whitespace and indentation precisely.",
        obj(%{
            path: s("Absolute path to the file"),
            old_string: s("Exact text to find"),
            new_string: s("Text to replace it with"),
            replace_all: b("Replace every occurrence instead of requiring uniqueness")
        }, ["path", "old_string", "new_string"]))
}

fun multi_edit_s() {
    tool("multi_edit",
        "Apply multiple edits to a single file atomically. Each edit has the " ++
        "same shape as `edit`. Applied in order; all-or-nothing.",
        obj(%{
            path: s("Absolute path to the file"),
            edits: arr(obj(%{
                old_string: s("Text to find"),
                new_string: s("Text to replace"),
                replace_all: b("Replace all occurrences")
            }, ["old_string", "new_string"]), "Ordered list of edits")
        }, ["path", "edits"]))
}

fun glob_s() {
    tool("glob",
        "Find files matching a glob pattern (e.g. `src/**/*.sw`). Returns " ++
        "paths sorted by modification time. Use for file discovery.",
        obj(%{
            pattern: s("Glob pattern"),
            path: s("Optional: directory to search in (defaults to cwd)")
        }, ["pattern"]))
}

fun grep_s() {
    tool("grep",
        "Search file contents with a regex. Returns file paths by default; " ++
        "set output_mode=content to see matching lines.",
        obj(%{
            pattern: s("Regular expression"),
            path: s("Optional: file or directory to search"),
            glob: s("Optional: file glob filter (e.g. *.sw)"),
            output_mode: s("'files_with_matches' | 'content' | 'count'"),
            head_limit: i("Optional: cap results")
        }, ["pattern"]))
}

fun todo_write_s() {
    tool("todo_write",
        "Create or update the session todo list. Pass the FULL desired state — " ++
        "this replaces, not appends. Use for multi-step tasks so the user can " ++
        "see progress. Each todo has id, content, and status.",
        obj(%{
            todos: arr(obj(%{
                id: s("Short stable id (e.g. '1', '2')"),
                content: s("Task description"),
                status: s("'pending' | 'in_progress' | 'completed'")
            }, ["id", "content", "status"]), "The complete todo list")
        }, ["todos"]))
}

fun web_search_s() {
    tool("web_search",
        "Search the web for current information. Use when you need up-to-date " ++
        "facts, documentation, or package info not in your training data.",
        obj(%{
            query: s("Search query"),
            max_results: i("Optional: number of results (default 5)")
        }, ["query"]))
}

fun web_fetch_s() {
    tool("web_fetch",
        "Fetch a URL and process its content with a small model using your prompt. " ++
        "Returns the extracted answer. Use after web_search to dig into a specific " ++
        "URL, or directly when you know the page you want.",
        obj(%{
            url: s("Full URL to fetch"),
            prompt: s("Instruction for what to extract from the page")
        }, ["url", "prompt"]))
}

fun remember_s() {
    tool("remember",
        "Save a fact to long-term memory as its own markdown file under " ++
        "~/.swarm-code/memory/. Use when you learn something useful for future " ++
        "sessions (user preferences, project conventions, references).",
        obj(%{
            name: s("Short human name (becomes slug)"),
            description: s("One-line purpose for future recall"),
            type: s("'user' | 'feedback' | 'project' | 'reference'"),
            body: s("Markdown content of the memory")
        }, ["name", "description", "type", "body"]))
}

fun recall_s() {
    tool("recall",
        "Read the full content of a memory by slug. Use memory_list first if " ++
        "you don't know the slug.",
        obj(%{slug: s("The memory's filename without .md")}, ["slug"]))
}

fun memory_list_s() {
    tool("memory_list",
        "List all stored memories with their slug, title, and one-line " ++
        "description. Cheap to call at the start of a session.",
        obj(%{}, []))
}

# ---------- studio / multi-agent ----------

fun spawn_agent_s() {
    tool("spawn_agent",
        "Create a new long-lived subagent process with its own LLM session " ++
        "and full tool set. Returns immediately. Use ask/tell to drive it.",
        obj(%{
            name: s("Unique kebab-case name (e.g. bug-hunter)"),
            role: s("Short role title shown in list_agents"),
            goal: s("One-sentence objective the agent works toward"),
            system_prompt: s("Optional extra context appended to the role+goal frame"),
            model: s("Optional model override; defaults to main agent's model"),
            max_tokens: i("Optional context cap; defaults to 65000")
        }, ["name", "role", "goal"]))
}

fun ask_s() {
    tool("ask",
        "Send a prompt to a named agent and BLOCK until it replies. The " ++
        "agent runs its own LLM-tools loop and returns a concise answer. " ++
        "Emits from other agents queue while you wait.",
        obj(%{
            name: s("Name of the spawned agent"),
            prompt: s("The request to send")
        }, ["name", "prompt"]))
}

fun tell_s() {
    tool("tell",
        "Send a prompt to a named agent fire-and-forget. The reply will " ++
        "surface as an agent_reply notice later without blocking you. Use " ++
        "to fan-out work and keep moving.",
        obj(%{
            name: s("Name of the spawned agent"),
            msg: s("The request")
        }, ["name", "msg"]))
}

fun list_agents_s() {
    tool("list_agents",
        "Print the swarm registry — one row per live agent: name, role, " ++
        "status, tokens used, age. Cheap to call.",
        obj(%{}, []))
}

fun kill_s() {
    tool("kill",
        "Terminate a subagent. Default is graceful (agent finishes current " ++
        "turn). hard:'true' clears the registry slot immediately.",
        obj(%{
            name: s("Name of the agent to kill"),
            hard: s("Optional 'true' for immediate slot release")
        }, ["name"]))
}

fun parallel_s() {
    tool("parallel",
        "Sugar over spawn+ask+kill for fan-out. Spawns N ephemeral " ++
        "subagents, sends each its prompt, waits for all replies, then " ++
        "graceful-kills them. Use for embarrassingly-parallel work.",
        obj(%{
            tasks: arr(
                obj(%{
                    name: s("Unique kebab-case name"),
                    role: s("Short role title"),
                    goal: s("Per-agent objective"),
                    prompt: s("Per-agent first task")
                }, ["name", "role", "goal", "prompt"]),
                "List of agent specs to spawn and ask in parallel")
        }, ["tasks"]))
}
