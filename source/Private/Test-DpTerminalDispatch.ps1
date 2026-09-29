function Test-DpTerminalDispatch {
    <#
    .SYNOPSIS
        Checks the imported Engine's disabled-Terminal behavioral contract.
    .DESCRIPTION
        Verifies negative and positive inert dispatch in a separate Runspace,
        caching the result by the module path, bytes and loaded command digest.
        Source markers, comments and version numbers are never enforcement proof.
    .PARAMETER Runspace
        The idle Engine Runspace for the next Turn.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [System.Management.Automation.Runspaces.Runspace]$Runspace
    )

    if ($null -eq $Runspace) { return $false }
    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        $null = $shell.AddScript(@'
$engine = Get-Module -Name ShellPilot | Select-Object -First 1
if (-not $engine) { return }
$command = Get-Command -Name Invoke-Shp -Module ShellPilot -CommandType Function -ErrorAction Stop
$sha = [Security.Cryptography.SHA256]::Create()
try { $definitionHash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($command.Definition))).Replace('-', '') }
finally { $sha.Dispose() }
@{
    Path = $engine.Path
    FileHash = (Get-FileHash -LiteralPath $engine.Path -Algorithm SHA256 -ErrorAction Stop).Hash
    DefinitionHash = $definitionHash
}
'@)
        $result = @($shell.Invoke())
        if ($shell.HadErrors -or $result.Count -ne 1) { return $false }
        $identity = $result[0]
        $key = '{0}|{1}|{2}' -f $identity.Path, $identity.FileHash, $identity.DefinitionHash
        $cacheVariable = Get-Variable -Name DpTerminalDispatchCache -Scope Script -ErrorAction SilentlyContinue
        if (-not $cacheVariable) { $script:DpTerminalDispatchCache = @{} }
        if ($script:DpTerminalDispatchCache.ContainsKey($key)) { return [bool]$script:DpTerminalDispatchCache[$key] }
        $verified = Invoke-DpTerminalDispatchProbe -ModulePath $identity.Path -DefinitionHash $identity.DefinitionHash
        if ((Get-FileHash -LiteralPath $identity.Path -Algorithm SHA256 -ErrorAction Stop).Hash -cne $identity.FileHash) {
            Write-Warning 'The Engine module changed during the dispatch proof; restart before Terminal work.'
            return $false
        }
        if ($script:DpTerminalDispatchCache.Count -ge 32) { $script:DpTerminalDispatchCache.Clear() }
        $script:DpTerminalDispatchCache[$key] = $verified
        $verified
    }
    catch { Write-Verbose 'The Engine dispatch capability could not be inspected.'; $false }
    finally { $shell.Dispose() }
}
