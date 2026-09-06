# Child execution components

These assets implement the private Tool storage portion of the approved
single-child design. They do not implement a complete child Engine profile.
The Host Server readiness gate remains closed.

## Components

- `ProjectBaseline.cs`: immutable selected bytes and Windows handle ownership.
- `AuthenticatedChannel.cs`: bounded, authenticated, sequenced control records.
- `LinuxToolRuntime.cs`: protected lease supervisor and kernel-resolved File
  operations.
- `ToolContainer.cs`: private storage, command execution, export, and cleanup.
- `Build-DpChildRuntime.ps1`: fresh-process compilation during explicit setup.
- `Start-DpChildSupervisor.ps1` and `Invoke-DpChildFile.ps1`: fixed image entry
  points, never Model-selected host implementations.
- `Dockerfile`: derived image using the prepared pinned Terminal base.

Preparation occurs only through an explicit action. Runtime policy is owned by
the Host Server and cannot be supplied through Tool arguments. No real Project
is mounted or modified by these components.

## Proof and open gates

Use [the operator guide](../../docs/child-agent-isolation.md) for the detached
proof command, demonstrated controls, limitations, and removal guidance.
Engine request admission, the credentialless child Engine process, child
approvals, aggregate Usage, and complete lifecycle integration are not finished.
