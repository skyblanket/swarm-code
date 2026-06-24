---
name: Code Review
description: Review the current git changes for bugs and report findings by severity
triggers: review my diff, code review, review the changes, check my changes
---

When asked to review changes:

1. Run `git diff --staged`; if it's empty, run `git diff` (unstaged working changes).
2. Read each changed hunk in the context of the file (open the file if needed —
   don't review a hunk blind).
3. Look for, in priority order:
   - **Correctness** — logic bugs, off-by-one, nil/undefined, wrong conditions
   - **Error handling** — unchecked failures, swallowed errors, missing guards
   - **Security** — injection, leaked secrets, unsafe shell, path traversal
   - **Reuse / simplification** — duplicated logic, an existing helper that fits
4. Report findings grouped **High / Medium / Low**, each as `file:line — issue`.
   Say "none" for an empty group.
5. End with a one-line verdict: **ship** or **fix-first**.

Be terse. No praise, no restating the diff — just the findings.
