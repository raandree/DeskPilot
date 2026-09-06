function New-DpChildToolContainer {
    <#
    .SYNOPSIS
        Creates a private quota-backed child Tool container.
    .PARAMETER Runtime
        The explicitly prepared runtime record.
    .PARAMETER DataDirectory
        The installation-owned control directory.
    .PARAMETER Policy
        The validated child execution policy.
    .OUTPUTS
        DeskPilot.Child.ToolContainer
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][hashtable]$Runtime,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][hashtable]$Policy
    )

    $validated = ConvertTo-DpChildExecution -InputObject $Policy
    $assemblyBytes = [IO.File]::ReadAllBytes($Runtime.assembly)
    $assemblyHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($assemblyBytes))
    if ($Runtime.image -notmatch '^sha256:[a-f0-9]{64}$' -or
        $assemblyHash -ne $Runtime.assemblySha256) {
        throw 'The prepared child runtime identity could not be verified.'
    }
    if (-not ([System.Management.Automation.PSTypeName]'DeskPilot.Child.ToolContainer').Type) {
        $null = [Reflection.Assembly]::Load($assemblyBytes)
    }
    $docker = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Docker/Docker/resources/bin/docker.exe'
    if ($PSCmdlet.ShouldProcess('Private child Tool storage', 'Create quota-backed container')) {
        [DeskPilot.Child.ToolContainer]::new($docker, $Runtime.image, $DataDirectory, ($validated | ConvertTo-Json -Depth 6 -Compress))
    }
}
