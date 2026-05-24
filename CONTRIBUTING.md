# Contributing to swarm-code

## 1. Project layout (src/*.sw)

| File | Owns |
|------|------|
| `main.sw` | CLI flags, env config, headless mode, the main loop |
| `agent.sw` | Prompt assembly, tool-call parsing/serialising, turn loop |
| `tools.sw` | Tool handlers (`do_bash`, `do_read`, …) and `exec()` dispatch |
| `ToolRegistry.sw` | Single source of truth: name → atom mapping (`all_tools`) |
| `ToolSchemas.sw` | OpenAI-compatible function schemas for native tool calling |
| `prompts.sw` | System prompt template and prose tool descriptions |
| `llm.sw` | HTTP requests to the inference endpoint, response streaming |
| `reader.sw` | Terminal input handling (line editor, history) |
| `ui.sw` | TUI layout, status bar, spinner, markdown rendering |
| `config.sw` | Env-var parsing, config map construction |
| `background.sw` | Async job spawning (`background`, `bg_server`, tail/kill) |
| `heartbeat.sw` | Background pulse process (swarmrt tick loop) |
| `memory.sw` | CRUD for `~/.swarm-code/memory/*.md` crumb files |
| `skills.sw` | CRUD for `~/.swarm-code/skills/<slug>/SKILL.md` |
| `SessionSearch.sw` | SQLite FTS5 search over past conversation turns |
| `browser.sw` | CDP browser automation wrapper |
| `vision.sw` | Image read / multimodal content assembly |
| `telemetry.sw` | System stats, log collection |
| `mcp.sw` | MCP (Model Context Protocol) server integration |
| `scheduler.sw` | Delayed / periodic task scheduling |
| `arthopod.sw` | Internal sw runtime helpers |
| `markdown.sw` | Markdown → plain-text stripper |
| `log.sw` | Structured logging primitives |
| `trajectory.sw` | Conversation trajectory storage |
| `test_runner.sw` | Unit-test entry point (`make test`) |

## 2. How to add a new tool

Four files, lock-step:

1. **`ToolRegistry.sw`** — add a line to `all_tools()` (~line 35):
   ```sw
   %{name: "my_tool", atom: 'my_tool'},
   ```

2. **`tools.sw`** — add an entry to `all_tools()` in `tools.sw` (~line 60) and implement the handler:
   ```sw
   %{atom: 'my_tool', handler: fun(args, opts) { do_my_tool(args) }},
   ```
   Then define `do_my_tool(args)` near the other `do_*` functions.  Use `map_get(args, 'arg_name')` to pull parameters.

3. **`ToolSchemas.sw`** — if the model should call the tool natively, add a schema function and wire it into `all_schemas()` (~line 18):
   ```sw
   fun my_tool_s() {
       tool("my_tool", "One-line description.",
           obj(%{path: s("File path")}, ["path"]))
   }
   ```

4. **`prompts.sw`** — if you skipped the schema, add a prose description in `tool_desc()` so the model sees it in the system prompt.

Run `make test` before committing.

## 3. Build & test

```sh
cd /Users/sky/swarm-code
make          # builds bin/swarm-code
make test     # builds and runs bin/swarm-code-test
make run      # build + launch interactively
```

**Headless smoke-test pattern** (from `main.sw`):
```sh
./bin/swarm-code -p "list files in /tmp"
```
Runs one task, prints result, exits — no TUI, no Reader.  Pipe-friendly:
```sh
cat prompt.txt | ./bin/swarm-code -p -
```

## 4. Coding conventions

**Atom keys vs string keys**
- Use atom keys for every map you construct: `%{name: "foo"}` or `map_get(m, 'name')`.
- String keys appear only when escaping from `json_decode` or `os_env`.

**Prefer `file_*` builtins over `shell()`**
- `file_read(path)` instead of `shell("cat " ++ path)`.
- `file_write(path, text)` instead of `shell("echo ... > ...")`.
- `string_replace(text, old, new)` instead of `shell("sed ...")`.
- `shell()` is for things that genuinely need a subprocess (git, ripgrep, builds).

**Avoid the bracket-counting trap**
sw has no `return` statement; `if` is an expression and every branch must close.  A six-level nested `if/else` ends with `}}}}}}` — humans miscount.
- Extract guard clauses into small named functions.
- Reverse the condition so the short/error branch comes first:
  ```sw
  if (bad == 'true') { "error" }
  else { /* happy path, one less level of nesting */ }
  ```
- If you need more than three levels of nesting, refactor.

**General style**
- 4-space indent.
- `snake_case` for functions and variables.
- Keep tool handlers under ~40 lines; extract helpers for parsing or formatting.

## 5. Reporting bugs / opening PRs

- **Bug reports**: Open an issue with (a) the command you ran, (b) the output you got, (c) what you expected, (d) `swarm-code --version` or commit hash.
- **PRs**: Branch from `main`, keep changes focused, run `make test`, and include a headless smoke test if you added a tool.
- **No marketing prose** in docs or comments — be terse.
