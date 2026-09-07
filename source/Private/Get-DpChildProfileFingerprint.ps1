function Get-DpChildProfileFingerprint {
    <#
    .SYNOPSIS
        Binds complete child proof to current Host Server and prepared bytes.
    .DESCRIPTION
        Reads and hashes source or the built Host Server module, bundled child
        assets, copied Engine bytes, the selected original Engine, and images.
        Any mismatch with explicit preparation refuses proof reuse.
    .PARAMETER Runtime
        The prepared immutable runtime record.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Runtime)

    if ($Runtime.schemaVersion -ne 2 -or $Runtime.engineHashes.Count -ne 4) { throw 'Incomplete child preparation.' }
    if (('DeskPilot.Child.ToolContainer' -as [type]) -and
        [AppDomain]::CurrentDomain.GetData('DeskPilot.Child.LoadedAssemblyHash') -cne $Runtime.assemblySha256) {
        throw 'Restart the Host Server to load the current proven child assembly.'
    }
    $assetRoot = Get-DpChildAssetRoot
    $hashes = [System.Collections.Generic.SortedDictionary[string, string]]::new([StringComparer]::Ordinal)
    $hashes['image/tool'] = $Runtime.image
    $hashes['image/engine'] = $Runtime.engineImage
    $hashes['profile'] = 'single-child-v3/provider-estimate/limits-v1'
    foreach ($file in Get-ChildItem -LiteralPath $assetRoot -File) {
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        if ($Runtime.hashes[$file.Name] -cne $hash) { throw 'Child source no longer matches preparation.' }
        $hashes['child/' + $file.Name] = $hash
    }
    foreach ($relative in @('ShellPilot.psd1', 'ShellPilot.psm1', 'ShellPilot.Format.ps1xml', 'data/PriceTable.psd1')) {
        foreach ($root in @((Split-Path $Runtime.engineManifest), (Split-Path $Runtime.engineSourceManifest))) {
            $hash = (Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash
            if ($hash -cne $Runtime.engineHashes[$relative]) { throw 'Engine bytes no longer match preparation.' }
        }
        $hashes['engine/' + $relative] = $Runtime.engineHashes[$relative]
    }
    $hashes['runtime/assembly'] = (Get-FileHash -LiteralPath $Runtime.assembly -Algorithm SHA256).Hash
    if ($hashes['runtime/assembly'] -cne $Runtime.assemblySha256) { throw 'The child assembly changed.' }
    foreach ($name in @('Start-DpChildProvider.ps1', 'ChildTools.ps1')) {
        $hash = (Get-FileHash -LiteralPath (Join-Path (Split-Path $Runtime.providerEntry) $name)).Hash
        if ($hash -cne $Runtime.hashes[$name]) { throw 'The prepared provider implementation changed.' }
    }
    $sourceRoot = Split-Path $assetRoot
    $hostModule = Join-Path $sourceRoot 'DeskPilot.psm1'
    if (Test-Path -LiteralPath (Join-Path $sourceRoot 'Private')) {
        foreach ($folder in @('Private', 'Public')) {
            foreach ($file in Get-ChildItem -LiteralPath (Join-Path $sourceRoot $folder) -Filter '*.ps1' -File) {
                $hashes['host/' + $folder + '/' + $file.Name] = (Get-FileHash -LiteralPath $file.FullName).Hash
            }
        }
    } else {
        $hashes['host/DeskPilot.psm1'] = (Get-FileHash -LiteralPath $hostModule).Hash
    }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'web') -Recurse -File) {
        $relative = [IO.Path]::GetRelativePath($sourceRoot, $file.FullName).Replace('\', '/')
        $hashes[$relative] = (Get-FileHash -LiteralPath $file.FullName).Hash
    }
    $json = $hashes | ConvertTo-Json -Depth 4 -Compress
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}
