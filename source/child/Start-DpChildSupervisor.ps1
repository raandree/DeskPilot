param(
    [Parameter(Mandatory)]
    [ValidateRange(1, 30)]
    [int]$LeaseSeconds,

    [Parameter(Mandatory)]
    [ValidateSet('read-only', 'read-write')]
    [string]$ProjectAccess
)

$ErrorActionPreference = 'Stop'
Add-Type -Path /opt/deskpilot-child/ChildRuntime.dll
[DeskPilot.Child.ToolSupervisor]::Run($LeaseSeconds, $ProjectAccess)
