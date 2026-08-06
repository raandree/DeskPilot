function Import-DpChangeStore {
    <#
    .SYNOPSIS
        Loads the pending AI change set from disk.
    .DESCRIPTION
        The change set is the layer above Git that remembers which files DeskPilot
        edited and what they looked like beforehand, so the user can keep or undo
        them long after the Turn ended - across reloads and restarts. It is keyed
        by Project folder rather than by Conversation, because the question "what
        did the AI change here?" is about the folder, not about which chat asked.
        A missing or unreadable file yields an empty store rather than an error.
    .PARAMETER Directory
        The per-user data directory.
    .OUTPUTS
        System.Collections.Hashtable keyed by normalized Project folder.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Directory
    )

    $store = @{}
    $path = Join-Path $Directory 'changes.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $store }

    try { $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop } catch { return $store }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $store }
    try { $parsed = $raw | ConvertFrom-Json -ErrorAction Stop } catch { return $store }
    if ($null -eq $parsed) { return $store }

    foreach ($property in $parsed.PSObject.Properties) {
        $entries = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($entry in @($property.Value)) {
            if (-not $entry) { continue }
            $rel = [string](Get-DpPropertyValue -InputObject $entry -Name @('rel') -Default '')
            if ([string]::IsNullOrWhiteSpace($rel)) { continue }
            $entries.Add(@{
                    rel            = $rel
                    snapshotSha    = [string](Get-DpPropertyValue -InputObject $entry -Name @('snapshotSha') -Default '')
                    conversationId = [string](Get-DpPropertyValue -InputObject $entry -Name @('conversationId') -Default '')
                    firstSeenUtc   = ConvertTo-DpIsoString -Value (Get-DpPropertyValue -InputObject $entry -Name @('firstSeenUtc') -Default $null)
                })
        }
        if ($entries.Count -gt 0) { $store[$property.Name] = @($entries) }
    }

    $store
}
