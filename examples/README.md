# examples

Starting points you can copy and adapt — a skill and a multi-agent flow.

## Skills

A skill is a `SKILL.md` playbook (frontmatter + markdown) that the agent recalls
on demand. Install one by dropping its folder into `~/.swarm-code/skills/`:

```bash
cp -r examples/skills/code-review ~/.swarm-code/skills/
```

Then, in a session:

```
> recall_skill code-review     # load the playbook
> review my diff               # a trigger phrase from the frontmatter
```

`SKILL.md` frontmatter:

```markdown
---
name: Code Review
description: One line, shown in the skill index
triggers: comma, separated, phrases that surface this skill
---
<the playbook body — instructions the agent follows>
```

You can co-locate scripts/configs/prompts next to `SKILL.md`; the body is loaded
lazily so the index stays small.

## Flows

A flow is a JSON workflow that fans agents out in parallel with a live TUI:

```bash
swarm-code            # then, in the REPL:
> /flows examples/flows/review.json
```

Flow schema:

```json
{
  "name": "review",
  "description": "what this flow does",
  "phases": [
    { "name": "Review", "tasks": [
      { "label": "bugs", "prompt": "what this agent should do", "model": "optional-profile" }
    ] }
  ]
}
```

[`review.json`](flows/review.json) runs three reviewers over `git diff` — bugs,
security, and simplification — each from its own angle.
