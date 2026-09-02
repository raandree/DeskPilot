function Test-DpIntercomChat {
    <#
    .SYNOPSIS
        Classifies one Telegram chat id against the live Intercom allow-list.
    .DESCRIPTION
        One place answers both questions Intercom asks about a chat: may DeskPilot
        act for it and speak to it at all, and is it the operator's own chat or a
        shared group?

        The allow-list is read from Settings on every call rather than captured
        once, so a chat that was de-authorised while work was in flight fails here
        even when a stale id survived somewhere upstream. That is the point: making
        the addressing layer re-check is cheaper than enumerating every place that
        has to clear stale routing state, because failing to enumerate one is the
        bug.

        An id that is neither the operator's chat nor an allow-listed group is
        refused *and* reported as a group. That is the safe direction - every
        stricter gate keys off 'group', so an unrecognised caller gets the
        narrowest authority rather than the widest.

        An empty id means the operator's own chat: it is what a Turn started at the
        machine carries, and what DeskPilot speaks on its own initiative.
    .PARAMETER ChatId
        The chat id to classify. Empty means the operator's own chat.
    .PARAMETER Settings
        The Settings hashtable to read the allow-list from. Defaults to the live
        one, so callers on the pump path do not have to thread it through.
    .OUTPUTS
        System.Collections.Hashtable with allowed, group and primary.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ChatId,

        [AllowNull()]
        [hashtable]$Settings
    )

    if (-not $Settings) {
        $Settings = if ($script:DeskPilot) { $script:DeskPilot.Settings } else { $null }
    }
    # Every read here is optional. This function sits on the path that reports a
    # finished job, and under StrictMode a missing key throws rather than
    # returning $null - which would lose the result rather than misaddress it.
    $intercom = Get-DpPropertyValue -InputObject $Settings -Name @('intercom') -Default $null

    $primary = ([string](Get-DpPropertyValue -InputObject $intercom -Name @('chatId') -Default '')).Trim()

    # Two gates, not one list: the ids are inert until group access is switched on.
    $groups = @()
    if ([bool](Get-DpPropertyValue -InputObject $intercom -Name @('allowGroupChat') -Default $false)) {
        $groups = @(@(Get-DpPropertyValue -InputObject $intercom -Name @('groupChatIds') -Default @()) |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { ([string]$_).Trim() })
    }

    $id = ([string]$ChatId).Trim()
    if ([string]::IsNullOrWhiteSpace($id)) { return @{ allowed = $true; group = $false; primary = $primary } }
    if ($primary -and $id -eq $primary) { return @{ allowed = $true; group = $false; primary = $primary } }
    if ($groups -contains $id) { return @{ allowed = $true; group = $true; primary = $primary } }

    @{ allowed = $false; group = $true; primary = $primary }
}
