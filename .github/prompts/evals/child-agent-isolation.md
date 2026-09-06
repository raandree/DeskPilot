# Child Agent isolation prompt checks

Use these cases to check the prerequisite Prompt File against the actual
2026-09-06 conversation. They are a small initial regression set, not a measured
reliability benchmark or proof that the requested runtime works.

## Recorded cases

| Case | Observed request or outcome | Expected behavior from the new Prompt File |
| --- | --- | --- |
| Build the missing prerequisite | The parallel-Agents request stopped because complete child isolation and quota-backed storage were absent. The operator then asked to tackle those prerequisites in a new chat. | Treat their absence as implementation scope. Obtain approval of a focused single-child design, then implement; do not reapply the parallel prompt's absence gate to the mechanism being built. |
| Preserve the complete boundary | Existing Isolated Terminal left native File Tools available and used a direct Project bind without a total write quota. | Cover every enabled child Tool, isolate credentials and state, and require an OS-enforced storage bound including seed, temporary, and exported data. A second Runspace, Tool schema, Git worktree, or output-size check alone is insufficient. |
| Report the actual deliverable | The operator asked whether the original features had been implemented after a documentation-only closeout. | Distinguish design approval, implementation, deterministic proof, authenticated live proof, and clean-install availability. Never report the parallel feature as implemented by this prerequisite work. |

## Deterministic checks

- The file is in the workspace Prompt File folder with a string description and
  `agent: software-engineer`; do not add runtime configuration to frontmatter.
- The prompt links to the current decision and original parallel-Agents brief.
- It limits execution to one child at a time, leaves the parent idle, and
  forbids automatic application of proposals to the real Project.
- It requires separate state, narrowed Permissions, correlated approvals,
  default-deny Tool egress, hard storage quotas, Stop, and orphan cleanup.
- It requires failing tests, actual-runtime positive and negative controls,
  full-suite validation, and independent security review before release.
- Existing single-Agent behavior and the no-push boundary remain explicit.

## Evaluation limits

Authoring-time schema, rendering, links, and content checks test the Prompt File,
not whether another Agent will execute its workflow reliably. Native
Customization analysis and repeated fresh-chat behavioral execution have not
been run. Do not turn these three recorded cases into a pass-rate claim.

For later behavioral evaluation, give each case and the complete Prompt File
to fresh contexts with runtime writes disabled. Compare against a no-guidance
control over at least five repetitions per case; grade the proposed first
actions and completion claims against the expectations above. Retain all
outputs and failures. A real implementation attempt remains a separate test.
