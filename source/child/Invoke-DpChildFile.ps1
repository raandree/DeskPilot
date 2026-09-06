param(
    [Parameter(Mandatory)]
    [ValidateSet('seed', 'read', 'write', 'inspect', 'validate-export')]
    [string]$Operation,

    [string]$PathBase64,
    [int]$Offset = 0,
    [int]$Count = 8192,
    [long]$InputLength = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -Path /opt/deskpilot-child/ChildRuntime.dll
if ($Operation -eq 'inspect') {
    [DeskPilot.Child.LinuxToolFile]::Inspect()
}
elseif ($Operation -eq 'validate-export') {
    [DeskPilot.Child.LinuxToolFile]::ValidateExport($Count)
}
else {
    $relativePath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PathBase64))
    [DeskPilot.Child.LinuxToolFile]::Invoke($Operation, $relativePath, $Offset, $Count, $InputLength)
}
