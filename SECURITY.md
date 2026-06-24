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
  unless you explicitly set `SWARM_CODE_ALLOW_REMOTE=1`.
- **Single policy boundary.** Every tool call — from the main agent, subagents,
  the council, and the MCP server — passes through `ToolExecutor`: context
  allow-lists, argument-rewriting hooks, guardrails, and permissions are applied
  *before* any raw handler runs. Execution **fails closed** when the execution
  context is missing or unknown.
- **Hardline command blocklist.** Destructive commands (`rm -rf /`, `mkfs`, `dd`
  to a device, fork bombs, and similar) are blocked and **cannot be bypassed by
  environment overrides**.
- **Restricted contexts.** Subagents, MCP-server, and council-panel contexts run
  under narrowed, often read-only, tool policies.
- **Secret redaction.** Known secret patterns are redacted from session logs and
  trajectory exports.

## Known limitations

- The council panel's read-only isolation is **tool-level**, not yet a filesystem
  sandbox — panelists inherit the read tool's filesystem visibility.
- swarm-code runs the commands you (or a model you configured) direct it to. Run
  it against code and endpoints you trust, and review the permission prompts.
