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
# EVERY tool the registry dispatches gets a typed schema here. In native
# mode (the default for Moonshot/Kimi and every cloud provider) the harness
# executes ONLY structured tool_calls — a tool absent from this array cannot
# be called at all, regardless of its prose description, because the system
# prompt explicitly tells native models that text-embedded calls are never
# executed. So the long tail (git_*, bg_*, code_search, sys_stats, forget …)
# MUST be listed here or it is dead for the default user.

export [all_schemas, all_schemas_json]

fun all_schemas() {
    [bash_s(), read_s(), write_s(), edit_s(), multi_edit_s(),
     glob_s(), grep_s(), todo_write_s(), web_search_s(), web_fetch_s(),
     remember_s(), recall_s(), memory_list_s(), forget_s(),
     learn_skill_s(), recall_skill_s(), skill_list_s(), forget_skill_s(),
     session_search_s(), read_image_s(),
     git_status_s(), git_diff_s(), git_commit_s(), run_tests_s(), code_search_s(),
     sw_check_s(),
     log_wait_s(), file_watch_s(),
     background_s(), bg_status_s(), bg_result_s(), bg_tail_s(),
     bg_kill_s(), bg_server_s(), sys_stats_s(), heartbeat_status_s(),
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
        "Fetch a URL and return its text content (HTML stripped). Use after " ++
        "web_search to read a specific page, or directly when you know the URL.",
        obj(%{
            url: s("Full URL to fetch")
        }, ["url"]))
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

# ---------- skills (Hermes-style reusable procedures) ----------

fun learn_skill_s() {
    tool("learn_skill",
        "Save a reusable procedure as a skill under ~/.swarm-code/skills/. " ++
        "Use after you solve a non-trivial recurring task so the next " ++
        "session can re-use the playbook. The skill index lands in your " ++
        "system prompt at startup; you pull the full body via recall_skill " ++
        "when a trigger matches.",
        obj(%{
            name: s("Short title (becomes slug, e.g. 'Deploy mally-otp')"),
            description: s("One-line summary shown in the index"),
            triggers: s("Comma-separated phrases that should activate this skill"),
            instructions: s("Markdown body: the step-by-step playbook")
        }, ["name", "description", "instructions"]))
}

fun recall_skill_s() {
    tool("recall_skill",
        "Read a skill's full SKILL.md body by slug. Use when the index " ++
        "in your system prompt suggests this skill matches the user's " ++
        "request.",
        obj(%{slug: s("Skill slug as shown in the index")}, ["slug"]))
}

fun skill_list_s() {
    tool("skill_list",
        "Return the rendered skills index. Same content that's injected " ++
        "into your system prompt at startup — call this to refresh after " ++
        "you've used learn_skill mid-session.",
        obj(%{}, []))
}

fun forget_skill_s() {
    tool("forget_skill",
        "Delete a skill by slug. Use when a skill is wrong, outdated, or " ++
        "no longer relevant.",
        obj(%{slug: s("Skill slug")}, ["slug"]))
}

# ---------- session search (FTS5 over journals) ----------

fun read_image_s() {
    tool("read_image",
        "Attach a local image file to the NEXT request so you can see it. " ++
        "Call this when the user references an image path (PNG, JPG, JPEG, " ++
        "GIF, WEBP). The image is base64-encoded and prepended to your " ++
        "next user message as a multimodal content block. Continue the " ++
        "turn with your question after attaching — the image becomes " ++
        "visible on the request that ends the turn.",
        obj(%{path: s("Absolute or relative path to the image file")},
            ["path"]))
}

fun session_search_s() {
    tool("session_search",
        "Full-text search over every past conversation turn (user prompts, " ++
        "assistant responses, tool calls, tool outputs). Use to find a " ++
        "solution you've already worked out in a prior session — saves " ++
        "redoing analysis. SQLite FTS5 syntax: bare words for OR; double-" ++
        "quoted phrases for exact match; trailing * for prefix match.",
        obj(%{
            query: s("FTS5 search expression"),
            limit: s("Max hits to return (default 10, max 30)")
        }, ["query"]))
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

# ---------- memory delete ----------

fun forget_s() {
    tool("forget",
        "Delete a memory file by slug. Use when a stored memory is wrong, " ++
        "outdated, or no longer relevant.",
        obj(%{slug: s("The memory's filename without .md")}, ["slug"]))
}

# ---------- git / search / background / system ----------

fun git_status_s() {
    tool("git_status",
        "Show `git status` for the repo (porcelain summary of staged, " ++
        "unstaged, and untracked files).",
        obj(%{cwd: s("Optional: repo directory (defaults to cwd)")}, []))
}

fun git_diff_s() {
    tool("git_diff",
        "Show the working-tree diff. Set staged=true for the staged diff.",
        obj(%{
            staged: b("Optional: show the staged (index) diff instead"),
            cwd: s("Optional: repo directory (defaults to cwd)")
        }, []))
}

fun git_commit_s() {
    tool("git_commit",
        "Stage and commit. Commits the given files (or all changes when " ++
        "omitted) with the provided message.",
        obj(%{
            message: s("Commit message"),
            files: arr(s("A path to stage"), "Optional: paths to stage (defaults to all changes)"),
            cwd: s("Optional: repo directory (defaults to cwd)")
        }, ["message"]))
}

fun run_tests_s() {
    tool("run_tests",
        "Run tests in a repository, auto-detect the test framework (jest, mocha, " ++
        "pytest, vitest, or custom PASS/FAIL/TOTAL output), and return parsed " ++
        "results. ALWAYS call this BEFORE git_commit when you have made code " ++
        "changes. If tests fail, fix them before committing.",
        obj(%{
            repo_path: s("Absolute path to the repository root"),
            command: s("Optional: test command to run (defaults to npm test, pytest, etc)")
        }, ["repo_path"]))
}

fun code_search_s() {
    tool("code_search",
        "Structure-aware code search across the project. Faster than grep " ++
        "for finding definitions/usages.",
        obj(%{
            pattern: s("Search pattern"),
            kind: s("Optional: 'def' (find definitions) | 'type' (find type usages) | 'ref' (find references, default)"),
            lang: s("Optional: language filter (e.g. 'sw', 'py')"),
            path: s("Optional: directory to search (defaults to cwd)")
        }, ["pattern"]))
}

fun sw_check_s() {
    tool("sw_check",
        "Compile-verify a .sw (sw / swarmrt) file and return the compiler's " ++
        "errors. ALWAYS call this after you write or edit a .sw file, before " ++
        "telling the user it's done. sw's compiler is loud and precise — it " ++
        "names the exact src/Module.sw:LINE and gives a did-you-mean fix (e.g. " ++
        "'use ++ to concatenate', 'filter is a global builtin, not Std.filter', " ++
        "'fn is not a keyword'). On a COMPILE ERROR, fix the named line and call " ++
        "sw_check again; loop until it returns OK. This compile-fix loop beats " ++
        "single-shotting sw. Runs `swc emit` (parse + typecheck + codegen, no cc) " ++
        "so it's fast and isolates sw-level mistakes.",
        obj(%{
            path: s("Path to the .sw file to verify (e.g. src/agent.sw)")
        }, ["path"]))
}

fun log_wait_s() {
    tool("log_wait",
        "Block until a pattern appears in a file or a background task's " ++
        "output (or the timeout elapses). Use to wait for a build/server " ++
        "to print a readiness line.",
        obj(%{
            pattern: s("Regex/substring to wait for"),
            path: s("Optional: file to watch"),
            task_id: s("Optional: background task id to watch instead of a file"),
            timeout_sec: i("Optional: max seconds to wait (default 30)")
        }, ["pattern"]))
}

fun file_watch_s() {
    tool("file_watch",
        "Block until a file changes (or the timeout elapses).",
        obj(%{
            path: s("File to watch"),
            timeout_sec: i("Optional: max seconds to wait (default 30)")
        }, ["path"]))
}

fun background_s() {
    tool("background",
        "Run a shell command as a detached background task. Returns a " ++
        "task id immediately; poll with bg_status / bg_result / bg_tail.",
        obj(%{
            command: s("The shell command to run in the background"),
            label: s("Optional: short label for the task")
        }, ["command"]))
}

fun bg_server_s() {
    tool("bg_server",
        "Start a long-running server process in the background (like " ++
        "`background` but intended for processes that don't exit).",
        obj(%{
            command: s("The server command to run"),
            label: s("Optional: short label")
        }, ["command"]))
}

fun bg_status_s() {
    tool("bg_status",
        "Report the status (pending/done/error/killed + exit code) of a " ++
        "background task.",
        obj(%{task_id: s("The background task id")}, ["task_id"]))
}

fun bg_result_s() {
    tool("bg_result",
        "Return the full captured output of a finished background task.",
        obj(%{task_id: s("The background task id")}, ["task_id"]))
}

fun bg_tail_s() {
    tool("bg_tail",
        "Return the last N lines of a background task's output so far.",
        obj(%{
            task_id: s("The background task id"),
            lines: i("Optional: number of trailing lines (default 20)")
        }, ["task_id"]))
}

fun bg_kill_s() {
    tool("bg_kill",
        "Terminate a running background task by id.",
        obj(%{task_id: s("The background task id")}, ["task_id"]))
}

fun sys_stats_s() {
    tool("sys_stats",
        "Report host system stats (CPU, memory, load, disk).",
        obj(%{}, []))
}

fun heartbeat_status_s() {
    tool("heartbeat_status",
        "Report the heartbeat process state: tick count, background tasks " ++
        "tracked, and daemon/cognitive-pulse mode.",
        obj(%{}, []))
}
