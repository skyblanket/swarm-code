# Security Policy

swarm-code is an autonomous coding agent: it executes shell commands, reads and
writes files, and (with explicit opt-in) reaches the network. It is designed to
do those things on your behalf — so it is built **fail-closed** around them.

## Reporting a vulnerability

Please report security issues **privately**, not in public issues or pull requests.

- Use GitHub's private vulnerability reporting: the repository **Security** tab →
  **Report a vulnerability**.

Include a description, affected version, and a minimal reproduction if possible.
We aim to acknowledge within a few days and to coordinate a fix and disclosure
timeline with you.

## Supported versions

Security fixes target the **latest release** and `main`. Older tags are not
backported.

## Security model

- **Network isolation by default.** Only local-network endpoints are allowed
  unless you explicitly set `SWARM_CODE_ALLOW_REMOTE=1` (an API key is not an
  opt-in). The check runs on every URL the LLM layer dials — primary,
  fallback, `providers`, and the `/profile` override — and parses it the way
  curl does: http(s) only, no `user@` credentials, IP literals only as strict
  dotted quads or bracketed IPv6.
- **Untrusted project config.** A repository's `./.swarm-code.json` can only
  set harmless keys (`model`, `max_tokens`, …) and *tighten* permissions. Its
  hooks, MCP servers, endpoint / API key / providers / profiles, and any
  permission loosening are ignored (with a notice) unless the directory is
  listed under `trusted_projects` in `~/.swarm-code/settings.json` —
  `swarm-code trust` (or `/trust`) adds the current directory for you.
  Trust only repos you control: a trusted repo's hooks and MCP servers run
  commands on your machine.
- **Single policy boundary.** Every tool call — from the main agent, subagents,
  the council, and the MCP server — passes through `ToolExecutor`: context
  allow-lists, argument-rewriting hooks, guardrails, and permissions are applied
  *before* any raw handler runs. Execution **fails closed** when the execution
  context is missing or unknown.
- **No unattended approvals.** In headless mode (`-p`, scheduled jobs, `/flows`
  children) there is nobody to answer a permission prompt, so a call that
  needs one — a dangerous command, a tool you set to `"ask"`, an MCP tool —
  is denied. `SWARM_CODE_HEADLESS_APPROVE=1` opts back into auto-approval
  (`/flows` children still hard-deny dangerous commands).
- **Hardline command blocklist.** Destructive commands (`rm -rf /`, `mkfs`, `dd`
  to a device, fork bombs, and similar) are blocked and **cannot be bypassed by
  environment overrides**. The check covers every tool that runs a shell
  command (`bash`, `background`, `bg_server`, `run_tests`) and parses the
  command like `sh` (quotes, separators, `$(…)`, `sh -c`, wrappers such as
  `sudo`/`env`/`xargs`), so respellings are caught; it is a floor against
  accidents, not a sandbox — a command assembled at runtime can't be judged.
- **Protected paths.** The `write` / `edit` / `multi_edit` tools refuse
  credential locations (`.ssh`, `.gnupg`, `.aws`, `/etc`, …) and swarm-code's
  own control files — everything under `~/.swarm-code/` except the `memory/`
  and `skills/` data dirs (hooks there run on every tool call), plus
  `.swarm-code.json`. Matching is case-insensitive (macOS filesystems are).
  `SWARM_CODE_UNSAFE_WRITES=1` lifts these guards.
- **Restricted contexts.** Subagents, MCP-server, and council-panel contexts run
  under narrowed, often read-only, tool policies.
- **Secret redaction.** Known secret patterns are redacted from session logs and
  trajectory exports. The raw LLM request body is written to disk only with
  `SWARM_CODE_DEBUG=1`, to `~/.swarm-code/last-body.json` with mode 600.

## Known limitations

- Protected paths are enforced by the file tools (`write`, `edit`,
  `multi_edit`, `browser_screenshot`), not by the shell: a `bash` command can
  still write anywhere your user can, so review the commands you approve.
- The council panel's read-only isolation is **tool-level**, not yet a filesystem
  sandbox — panelists inherit the read tool's filesystem visibility.
- swarm-code runs the commands you (or a model you configured) direct it to. Run
  it against code and endpoints you trust, and review the permission prompts.
