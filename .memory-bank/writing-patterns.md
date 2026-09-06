---
schema-version: 1
status: accepted
owner: technical-writer
last-verified: 2026-09-06
source: isolated Terminal documentation closeout
---

# Writing patterns

Maintainable operator-guide structures used in this repository.

## Optional execution features

1. State which Tool changes, which Tools do not, and the existing-user default.
2. Summarize visible workflow differences before technical implementation detail.
3. Separate preparing dependencies, selecting a mode, and enabling Permissions.
4. Explain environment compatibility and when a policy change takes effect.
5. Document resource and network boundaries alongside their limits.
6. Separate stopping execution, restoring files, selecting the previous mode,
   removing an owned runtime, and uninstalling shared dependencies.
7. Label local and scripted verification, and keep unverified release gates open.

Applied in the [Isolated Terminal guide](../docs/isolated-terminal.md).
Cycle evidence and publication status belong in the
[documentation registry](article-registry.md), not in the operator procedure.
