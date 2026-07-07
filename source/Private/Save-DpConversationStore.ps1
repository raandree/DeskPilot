function Save-DpConversationStore {
    <#
    .SYNOPSIS
        Persists the Conversation store to disk as JSON.
    .DESCRIPTION
        Writes all Conversations to conversations.json in the given directory.
        The write is atomic (temp file then move) and best-effort: any failure is
        written to the error stream but not thrown, so a disk problem never aborts
        a Turn.
    .PARAMETER Store
        The Conversation store hashtable (id -> Conversation).
    .PARAMETER Directory
        The data directory to write into.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Store,

        [Parameter(Mandatory)]
        [string]$Directory
    )

    try {
        if (-not (Test-Path -LiteralPath $Directory)) {
            New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null
        }
        $ordered = $Store.Values | Sort-Object updatedUtc -Descending | ForEach-Object {
            @{
                id          = $_.id
                title       = $_.title
                titleLocked = [bool]$_.titleLocked
                model       = $_.model
                pinned      = [bool]$_.pinned
                archived    = [bool]$_.archived
                unread      = [bool]$_.unread
                color       = $_.color
                createdUtc  = $_.createdUtc
                updatedUtc  = $_.updatedUtc
                messages    = @($_.messages)
                history     = @($_.history)
            }
        }
        $payload = @{ version = 1; conversations = @($ordered) } | ConvertTo-Json -Depth 20 -Compress
        $target = Join-Path $Directory 'conversations.json'
        $temp = "$target.tmp"
        [System.IO.File]::WriteAllText($temp, $payload, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $target -Force -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to persist conversations: $_"
    }
}
