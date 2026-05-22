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
     task_s(),
     browser_launch_s(), browser_navigate_s(), browser_click_s(),
     browser_type_s(), browser_screenshot_s(), browser_get_text_s(),
     browser_get_html_s(), browser_evaluate_s(), browser_close_s()]
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
            content: s("Markdown content of the memory — the actual fact to store")
        }, ["name", "description", "type", "content"]))
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

# ---------- subagent (Claude-Code-shaped Task tool) ----------

fun task_s() {
    tool("task",
        "Spawn an ephemeral subagent to handle a focused subtask. The " ++
        "subagent runs its own LLM-tools loop and returns its final answer " ++
        "as a string. Call this multiple times in one message to delegate " ++
        "independent pieces of a larger task — each call gets its own " ++
        "subagent. Useful for chunks of work you don't want crowding your " ++
        "own context (broad explorations, repetitive checks, focused " ++
        "investigations). Subagents finish, return, and are gone.",
        obj(%{
            description: s("A short (3-5 word) task label, for the UI"),
            prompt: s("The full task instructions for the subagent"),
            subagent_type: s("'general' (all tools) | 'explore' (read-only: read/glob/grep) | 'bash' (shell only)")
        }, ["description", "prompt"]))
}

# ---------- browser (CDP via swarmrt) ----------

fun browser_launch_s() {
    tool("browser_launch",
        "Start (or attach to) a Chromium browser with remote debugging. " ++
        "Lazy: first call spawns; later calls reuse.",
        obj(%{headless: s("Optional 'true' (default) or 'false'")}, []))
}

fun browser_navigate_s() {
    tool("browser_navigate",
        "Load a URL in the current page.",
        obj(%{url: s("Absolute URL")}, ["url"]))
}

fun browser_click_s() {
    tool("browser_click",
        "Click an element by CSS selector via JS .click().",
        obj(%{selector: s("CSS selector")}, ["selector"]))
}

fun browser_type_s() {
    tool("browser_type",
        "Set an input/textarea value and fire input + change events.",
        obj(%{
            selector: s("CSS selector"),
            text: s("Text to enter")
        }, ["selector", "text"]))
}

fun browser_screenshot_s() {
    tool("browser_screenshot",
        "Capture viewport as PNG. Default path /tmp/swc-page.png.",
        obj(%{path: s("Optional output path")}, []))
}

fun browser_get_text_s() {
    tool("browser_get_text",
        "Extract innerText. With selector, that element only; without, " ++
        "the whole document.body.",
        obj(%{selector: s("Optional CSS selector")}, []))
}

fun browser_get_html_s() {
    tool("browser_get_html",
        "Return document.documentElement.outerHTML — full live DOM.",
        obj(%{}, []))
}

fun browser_evaluate_s() {
    tool("browser_evaluate",
        "Run a JS expression and return its value as a string.",
        obj(%{expression: s("JavaScript expression")}, ["expression"]))
}

fun browser_close_s() {
    tool("browser_close",
        "Close the WS session. Chrome stays running for fast re-launch.",
        obj(%{}, []))
}
