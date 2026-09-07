function ConvertTo-DpChildExecution {
    <#
    .SYNOPSIS
        Validates and copies the single-child execution policy.
    .DESCRIPTION
        Applies bounded partial Settings without permitting additional children,
        retries, Tool network access, or unrecognized capabilities.
    .PARAMETER InputObject
        The partial policy to validate.
    .PARAMETER Current
        The existing policy to copy before applying the partial policy.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object]$InputObject,

        [AllowNull()]
        [object]$Current
    )

    $policy = @{
        enabled = $false
        profile = 'single-child-v2'
        budgetMode = 'verified'
        model = 'claude-haiku-4.5'
        requestBytes = 262144
        projectAccess = 'read-only'
        network = 'off'
        maxChildren = 1
        maxRetries = 0
        storageBytes = 134217728
        toolStorageBytes = 100663296
        inodeLimit = 4096
        baselineBytes = 33554432
        baselineFiles = 2000
        proposalBytes = 25165824
        proposalFiles = 200
        retentionBytes = 536870912
        retentionHours = 24
        durationSeconds = 300
        approvalSeconds = 60
        leaseSeconds = 15
        cleanupSeconds = 5
        memoryBytes = 1073741824
        cpuCount = 1.0
        processLimit = 64
        inputTokens = 16384
        totalTokens = 32768
        outputTokens = 4096
        iterations = 8
        costUSD = 0.25
        outputBytes = 1048576
        resultBytes = 262144
        eventBytes = 16384
        eventLimit = 300
    }

    foreach ($source in @($Current, $InputObject)) {
        if ($null -eq $source) { continue }
        $values = @{}
        if ($source -is [System.Collections.IDictionary]) {
            foreach ($key in $source.Keys) { $values[[string]$key] = $source[$key] }
        }
        elseif ($source -is [pscustomobject]) {
            foreach ($property in $source.PSObject.Properties) { $values[$property.Name] = $property.Value }
        }
        else { throw 'childExecution must be an object.' }

        foreach ($key in $values.Keys) {
            if (-not $policy.ContainsKey($key)) { throw "Unknown childExecution field '$key'." }
            $policy[$key] = $values[$key]
        }
    }

    if ($policy.enabled -isnot [bool]) { throw 'childExecution.enabled must be a boolean.' }
    if ($policy.profile -isnot [string] -or $policy.profile -cnotin @('single-child-v2','single-child-v3')) {
        throw 'childExecution.profile is unsupported.'
    }
    $expectedMode = if ($policy.profile -ceq 'single-child-v3') { 'provider-estimate' } else { 'verified' }
    if ($policy.budgetMode -isnot [string] -or $policy.budgetMode -cne $expectedMode) {
        throw 'childExecution.budgetMode must be explicitly paired with its profile.'
    }
    if ($policy.model -isnot [string] -or $policy.model -cne 'claude-haiku-4.5') {
        throw 'childExecution.model is not approved for the child provider profile.'
    }
    if ($policy.projectAccess -isnot [string] -or $policy.projectAccess -cnotin @('read-only', 'read-write')) {
        throw 'childExecution.projectAccess must be read-only or read-write.'
    }
    if ($policy.network -isnot [string] -or $policy.network -cne 'off') {
        throw 'childExecution.network must be off.'
    }

    $ranges = @{
        requestBytes = @(1024, 1048576)
        maxChildren = @(1, 1)
        maxRetries = @(0, 0)
        storageBytes = @(33554432, 268435456)
        toolStorageBytes = @(16777216, 201326592)
        inodeLimit = @(128, 8192)
        baselineBytes = @(1, 67108864)
        baselineFiles = @(1, 4000)
        proposalBytes = @(1, 50331648)
        proposalFiles = @(1, 1000)
        retentionBytes = @(33554432, 1073741824)
        retentionHours = @(1, 168)
        durationSeconds = @(1, 600)
        approvalSeconds = @(1, 120)
        leaseSeconds = @(1, 30)
        cleanupSeconds = @(1, 10)
        memoryBytes = @(1073741824, 2147483648)
        cpuCount = @(1.0, 2.0)
        processLimit = @(64, 64)
        inputTokens = @(1, 32768)
        totalTokens = @(1, 65536)
        outputTokens = @(1, 8192)
        iterations = @(1, 16)
        costUSD = @(0.0, 1.0)
        outputBytes = @(1024, 2097152)
        resultBytes = @(1024, 1048576)
        eventBytes = @(1024, 65536)
        eventLimit = @(1, 1000)
    }
    foreach ($key in $ranges.Keys) {
        $value = $policy[$key]
        if ($null -eq $value -or $value -is [string] -or $value -is [bool] -or $value -isnot [ValueType]) {
            throw "childExecution.$key must be a number."
        }
        try { $number = [double]$value }
        catch { throw "childExecution.$key must be a number." }
        $fractionAllowed = $key -in @('cpuCount', 'costUSD')
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or
            $number -lt $ranges[$key][0] -or $number -gt $ranges[$key][1] -or
            (-not $fractionAllowed -and $number -ne [math]::Truncate($number))) {
            throw "childExecution.$key is outside its supported range or has a fractional count."
        }
        $policy[$key] = if ($fractionAllowed) { [decimal]$number } else { [long]$number }
    }

    $hostStorage = $policy.storageBytes - $policy.toolStorageBytes
    $recordBytes = $policy.resultBytes + ($policy.eventBytes * $policy.eventLimit)
    if ($policy.profile -ceq 'single-child-v3') {
        $bufferReservation = ($policy.requestBytes * 12) + ($policy.outputBytes * 8) + $recordBytes + 65536
        if ($bufferReservation -ge $hostStorage) {
            throw 'childExecution request, response, and record buffers exceed their reserved host storage partition.'
        }
    }
    if ($hostStorage -lt ($policy.proposalBytes + $recordBytes) -or
        $hostStorage -gt 67108864 -or $policy.baselineBytes -ge $policy.toolStorageBytes -or
        $policy.retentionBytes -lt $policy.storageBytes) {
        throw 'childExecution storage partitions cannot accommodate the baseline, proposal and bounded records.'
    }
    if ($policy.baselineFiles -ge $policy.inodeLimit -or $policy.proposalFiles -ge $policy.inodeLimit) {
        throw 'childExecution.inodeLimit must leave capacity for directories and control records.'
    }
    if ($policy.inputTokens + $policy.outputTokens -gt $policy.totalTokens) {
        throw 'childExecution.totalTokens must cover one permitted request including its output.'
    }

    $policy
}
