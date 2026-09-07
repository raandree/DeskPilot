function Import-DpChildRuntime {
    <#
    .SYNOPSIS
        Loads verified child bytes once per Host Server implementation identity.
    .DESCRIPTION
        PowerShell cannot unload C# types. A prepared implementation whose source
        differs from already loaded types requires a Host Server restart. The
        comparison uses source hashes because compiler assembly identities can
        vary between equivalent explicit preparations.
    .PARAMETER Runtime
        The trusted prepared runtime record with assembly and source hashes.
    .PARAMETER ExactAssembly
        Complete-profile execution also requires identical loaded assembly bytes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Runtime,
        [switch]$ExactAssembly
    )

    $file = Get-Item -LiteralPath $Runtime.assembly -ErrorAction Stop
    if ($file.Length -gt 4194304 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid prepared child assembly.' }
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $Runtime.assemblySha256) {
        throw 'The prepared child assembly changed.'
    }
    $sources = [System.Collections.Generic.SortedDictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($name in $Runtime.hashes.Keys) {
        if ($name -clike '*.cs') {
            if ([IO.Path]::GetFileName($name) -cne $name -or $Runtime.hashes[$name] -cnotmatch '^[A-Fa-f0-9]{64}$') {
                throw 'Invalid prepared child source identity.'
            }
            $sources.Add($name, $Runtime.hashes[$name].ToLowerInvariant())
        }
    }
    if ($sources.Count -lt 3) { throw 'Incomplete prepared child source identity.' }
    $sourceJson = $sources | ConvertTo-Json -Compress
    $sourceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sourceJson)))
    $key = 'DeskPilot.Child.LoadedSourceHash'
    if ('DeskPilot.Child.ToolContainer' -as [type]) {
        if ([AppDomain]::CurrentDomain.GetData($key) -cne $sourceHash) {
            throw 'The loaded child implementation changed; restart the Host Server before running another child.'
        }
        if ($ExactAssembly -and [AppDomain]::CurrentDomain.GetData('DeskPilot.Child.LoadedAssemblyHash') -cne $Runtime.assemblySha256) {
            throw 'The loaded child assembly differs from the proven bytes; restart the Host Server.'
        }
        return
    }
    $null = [Reflection.Assembly]::Load($bytes)
    [AppDomain]::CurrentDomain.SetData($key, $sourceHash)
    [AppDomain]::CurrentDomain.SetData('DeskPilot.Child.LoadedAssemblyHash', $Runtime.assemblySha256)
}
