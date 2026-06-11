function Import-DpConversationStore {
    <#
    .SYNOPSIS
        Loads the persisted Conversation store from disk.
    .DESCRIPTION
        Reads conversations.json from the given directory and rebuilds the
        Conversation store hashtable (id -> Conversation). Each Conversation's
        messages and history are rehydrated into List[object] so the rest of the
        Host Server can append to them. Returns an empty store when the file is
        missing or unreadable.
    .PARAMETER Directory
        The data directory to read from.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Directory
    )

    $store = @{}
    $path = Join-Path $Directory 'conversations.json'
    if (-not (Test-Path -LiteralPath $path)) { return $store }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $store }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($c in @($parsed.conversations)) {
            if (-not $c.id) { continue }
            $messages = [System.Collections.Generic.List[object]]::new()
            foreach ($m in @($c.messages)) { $messages.Add($m) }
            $history = [System.Collections.Generic.List[object]]::new()
            foreach ($h in @($c.history)) { $history.Add($h) }
            $store[[string]$c.id] = @{
                id         = [string]$c.id
                title      = [string]$c.title
                model      = if ($c.model) { [string]$c.model } else { $null }
                pinned     = [bool]($c.PSObject.Properties['pinned'] -and $c.pinned)
                archived   = [bool]($c.PSObject.Properties['archived'] -and $c.archived)
                createdUtc = ConvertTo-DpIsoString $c.createdUtc
                updatedUtc = ConvertTo-DpIsoString $c.updatedUtc
                messages   = $messages
                history    = $history
            }
        }
    }
    catch {
        Write-Error "Failed to load conversations: $_"
    }
    $store
}
