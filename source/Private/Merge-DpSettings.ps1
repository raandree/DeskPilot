function Merge-DpSettings {
    <#
    .SYNOPSIS
        Merges a partial Settings patch onto current Settings with validation.
    .DESCRIPTION
        Returns a new Settings hashtable combining Current with Patch. Validates
        key names and value types; throws on an unknown key or an invalid value so
        the caller can map the failure to an HTTP 400.
    .PARAMETER Current
        The current Settings hashtable.
    .PARAMETER Patch
        A partial Settings object (hashtable or PSCustomObject parsed from JSON).
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Current,

        [Parameter(Mandatory)]
        [object]$Patch
    )

    $validEfforts = @('minimal', 'low', 'medium', 'high', 'xhigh', 'max')
    $permissionKeys = @('browsing', 'file', 'terminal', 'askUser', 'userTools')
    # Bounded numeric Intercom keys: name -> minimum, maximum.
    $intercomRanges = @{
        heartbeatMinutes       = @(1, 1440)
        stallMinutes           = @(1, 1440)
        questionTimeoutMinutes = @(1, 1440)
        maxMessagesPerHour     = @(1, 1000)
        maxAttachmentMB        = @(1, 20)
    }

    # Clone current (nested permissions, intercom and projects) so the input is
    # never mutated.
    $merged = @{}
    foreach ($key in $Current.Keys) { $merged[$key] = $Current[$key] }
    $merged.permissions = @{}
    foreach ($key in $Current.permissions.Keys) { $merged.permissions[$key] = $Current.permissions[$key] }
    $merged.intercom = @{}
    if ($Current.intercom) {
        foreach ($key in $Current.intercom.Keys) { $merged.intercom[$key] = $Current.intercom[$key] }
    }
    $merged.projects = @(foreach ($project in @($Current.projects)) { $clone = ConvertTo-DpProject -InputObject $project; if ($clone) { $clone } })

    # Normalise the patch into a name -> value map.
    $patchMap = @{}
    if ($Patch -is [hashtable]) {
        foreach ($key in $Patch.Keys) { $patchMap[$key] = $Patch[$key] }
    }
    else {
        foreach ($prop in $Patch.PSObject.Properties) { $patchMap[$prop.Name] = $prop.Value }
    }

    # Project selection is tracked here; workspaceFolder is derived from the
    # selected Project at the end (the Turn and Upload code still read it).
    $selectedInPatch = $patchMap.ContainsKey('selectedProjectId')
    $hasLegacyWorkspace = $false
    $legacyWorkspace = $null

    foreach ($key in $patchMap.Keys) {
        $value = $patchMap[$key]
        switch ($key) {
            'model' { $merged.model = if ($null -eq $value) { $null } else { [string]$value } }
            'reasoningEffort' {
                if ($null -ne $value -and $value -ne '' -and $validEfforts -notcontains [string]$value) {
                    throw "Invalid reasoningEffort '$value'. Allowed: $($validEfforts -join ', ')."
                }
                $merged.reasoningEffort = if ($value) { [string]$value } else { $null }
            }
            'showThinking' { $merged.showThinking = [bool]$value }
            'taskTracking' { $merged.taskTracking = [bool]$value }
            'pushInstructions' { $merged.pushInstructions = [bool]$value }
            'workspaceContext' { $merged.workspaceContext = [bool]$value }
            'turnTranscript' { $merged.turnTranscript = [bool]$value }
            'preferences' {
                $text = if ($null -eq $value) { $null } else { ([string]$value).Trim() }
                if ([string]::IsNullOrWhiteSpace($text)) { $merged.preferences = $null }
                elseif ($text.Length -gt 8000) { throw 'preferences must be 8000 characters or fewer.' }
                else { $merged.preferences = $text }
            }
            'referenceFiles' {
                $merged.referenceFiles = @($value | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
            }
            'costBudgetUSD' {
                $amount = [double]$value
                if ($amount -lt 0) { throw 'costBudgetUSD must be zero or greater.' }
                $merged.costBudgetUSD = $amount
            }
            'maxToolIterations' {
                $count = [int]$value
                if ($count -lt 1) { throw 'maxToolIterations must be at least 1.' }
                # 200 is the recommended ceiling and the SPA asks for confirmation past it;
                # this bound only has to stop a typo becoming an unattended runaway, and it
                # stays permissive enough that an approved value still loads from disk.
                if ($count -gt 1000) { throw 'maxToolIterations must be 1000 or fewer.' }
                $merged.maxToolIterations = $count
            }
            'autoCompaction' { $merged.autoCompaction = [bool]$value }
            'compactionThreshold' {
                $fraction = [double]$value
                if ($fraction -lt 0.5 -or $fraction -gt 0.95) {
                    throw 'compactionThreshold must be between 0.5 and 0.95.'
                }
                $merged.compactionThreshold = [math]::Round($fraction, 2)
            }
            'compactionKeepRecent' {
                $keep = [int]$value
                if ($keep -lt 2 -or $keep -gt 100) {
                    throw 'compactionKeepRecent must be between 2 and 100.'
                }
                $merged.compactionKeepRecent = $keep
            }
            'memoryLearning' { $merged.memoryLearning = [bool]$value }
            'updateCheckIntervalMinutes' {
                $minutes = [int]$value
                if ($minutes -lt 1 -or $minutes -gt 1440) {
                    throw 'updateCheckIntervalMinutes must be between 1 and 1440.'
                }
                $merged.updateCheckIntervalMinutes = $minutes
            }
            'updateIncludePrereleases' { $merged.updateIncludePrereleases = [bool]$value }
            'skillRoots' { $merged.skillRoots = @($value | ForEach-Object { [string]$_ }) }
            'instructionRoots' { $merged.instructionRoots = @($value | ForEach-Object { [string]$_ }) }
            'promptRoots' { $merged.promptRoots = @($value | ForEach-Object { [string]$_ }) }
            'agentsRoot' { $merged.agentsRoot = if ($null -eq $value -or "$value" -eq '') { $null } else { ([string]$value).Trim() } }
            'selectedAgent' { $merged.selectedAgent = if ($null -eq $value -or "$value" -eq '') { $null } else { [string]$value } }
            'permissions' {
                $permMap = @{}
                if ($value -is [hashtable]) { foreach ($k in $value.Keys) { $permMap[$k] = $value[$k] } }
                elseif ($null -ne $value) { foreach ($p in $value.PSObject.Properties) { $permMap[$p.Name] = $p.Value } }
                foreach ($permKey in $permMap.Keys) {
                    if ($permissionKeys -notcontains $permKey) { throw "Unknown permission '$permKey'." }
                    $merged.permissions[$permKey] = [bool]$permMap[$permKey]
                }
            }
            'intercom' {
                $intercomMap = @{}
                if ($value -is [hashtable]) { foreach ($k in $value.Keys) { $intercomMap[$k] = $value[$k] } }
                elseif ($null -ne $value) { foreach ($p in $value.PSObject.Properties) { $intercomMap[$p.Name] = $p.Value } }
                foreach ($intercomKey in $intercomMap.Keys) {
                    $intercomValue = $intercomMap[$intercomKey]
                    switch ($intercomKey) {
                        'enabled' { $merged.intercom.enabled = [bool]$intercomValue }
                        'notifyOnDone' { $merged.intercom.notifyOnDone = [bool]$intercomValue }
                        'sendFinalAnswer' { $merged.intercom.sendFinalAnswer = [bool]$intercomValue }
                        'chatId' {
                            $chat = if ($null -eq $intercomValue) { '' } else { ([string]$intercomValue).Trim() }
                            if ($chat -and $chat -notmatch '^-?\d{1,20}$') {
                                throw 'intercom.chatId must be a Telegram chat id (digits, optionally leading -).'
                            }
                            $merged.intercom.chatId = if ($chat) { $chat } else { $null }
                        }
                        # The bot token is never a Setting: it lives in
                        # intercom.secret so a Settings backup cannot carry a
                        # credential that grants control of this machine.
                        'botToken' { throw 'The Intercom bot token is not a setting. Use PUT /api/intercom.' }
                        default {
                            if (-not $intercomRanges.ContainsKey($intercomKey)) { throw "Unknown intercom setting '$intercomKey'." }
                            $range = $intercomRanges[$intercomKey]
                            $number = [int]$intercomValue
                            if ($number -lt $range[0] -or $number -gt $range[1]) {
                                throw "intercom.$intercomKey must be between $($range[0]) and $($range[1])."
                            }
                            $merged.intercom[$intercomKey] = $number
                        }
                    }
                }
            }
            'projects' {
                $normalized = @($value | ForEach-Object { ConvertTo-DpProject -InputObject $_ } | Where-Object { $_ })
                # No two Projects may share a name or a folder path (case-insensitive,
                # trailing separators ignored), so the same Project cannot be added twice.
                $seenNames = @{}
                $seenPaths = @{}
                foreach ($proj in $normalized) {
                    $nameKey = $proj.name.Trim().ToLowerInvariant()
                    $pathKey = ($proj.path -replace '[\\/]+$', '').ToLowerInvariant()
                    if ($seenNames.ContainsKey($nameKey)) { throw "A project named '$($proj.name)' already exists." }
                    if ($seenPaths.ContainsKey($pathKey)) { throw "A project for the folder '$($proj.path)' already exists." }
                    $seenNames[$nameKey] = $true
                    $seenPaths[$pathKey] = $true
                }
                $merged.projects = $normalized
            }
            'selectedProjectId' {
                $merged.selectedProjectId = if ($null -eq $value -or "$value" -eq '') { $null } else { [string]$value }
            }
            'workspaceFolder' {
                # Legacy: a direct workspaceFolder set is migrated to a Project below.
                $hasLegacyWorkspace = $true
                $legacyWorkspace = if ($null -eq $value -or "$value" -eq '') { $null } else { ([string]$value).Trim() }
            }
            default { throw "Unknown setting '$key'." }
        }
    }

    if (-not $merged.ContainsKey('selectedProjectId')) { $merged.selectedProjectId = $null }

    # Legacy migration: a direct workspaceFolder (with no explicit selection in the
    # same patch) becomes a registered Project that is then selected.
    if (-not $selectedInPatch -and $hasLegacyWorkspace) {
        if ($legacyWorkspace) {
            $existing = $merged.projects | Where-Object { $_.path -ieq $legacyWorkspace } | Select-Object -First 1
            if (-not $existing) {
                $existing = @{ id = (New-DpId -Prefix 'p'); name = (Split-Path -Leaf $legacyWorkspace); path = $legacyWorkspace }
                $merged.projects = @($merged.projects) + $existing
            }
            $merged.selectedProjectId = $existing.id
        }
        else {
            $merged.selectedProjectId = $null
        }
    }

    # Validate the selection and derive the active workspaceFolder.
    $selected = $null
    if ($merged.selectedProjectId) {
        $selected = $merged.projects | Where-Object { $_.id -eq $merged.selectedProjectId } | Select-Object -First 1
        if (-not $selected) {
            if ($selectedInPatch) { throw "Unknown project '$($merged.selectedProjectId)'." }
            $merged.selectedProjectId = $null
        }
    }
    $merged.workspaceFolder = if ($selected) { $selected.path } else { $null }

    $merged
}
