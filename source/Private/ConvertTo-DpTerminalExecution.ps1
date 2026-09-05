function ConvertTo-DpTerminalExecution {
    <#
    .SYNOPSIS
        Validates and copies the Terminal execution policy.
    .DESCRIPTION
        Returns conservative defaults with a validated partial policy applied.
        Environment grants contain names and secret markers, never values.
    .PARAMETER InputObject
        A partial policy from Settings.
    .PARAMETER Current
        The existing policy to copy before applying the patch.
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
        mode = 'local'
        projectAccess = 'read-only'
        network = 'off'
        allowedHosts = @()
        environment = @()
        timeoutSeconds = 120
        cpuCount = 1.0
        memoryMB = 1024
        processLimit = 64
        outputBytes = 1048576
        tempMB = 128
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
        else { throw 'terminalExecution must be an object.' }

        foreach ($key in $values.Keys) {
            if (-not $policy.ContainsKey($key)) { throw "Unknown terminalExecution field '$key'." }
            $policy[$key] = $values[$key]
        }
    }

    $choices = @{
        mode = @('local', 'isolated')
        projectAccess = @('read-only', 'read-write')
        network = @('off', 'allow-list')
    }
    foreach ($key in $choices.Keys) {
        if ($policy[$key] -isnot [string] -or $choices[$key] -notcontains $policy[$key]) {
            throw "Invalid terminalExecution.$key. Allowed: $($choices[$key] -join ', ')."
        }
        $policy[$key] = $policy[$key].ToLowerInvariant()
    }

    $ranges = @{
        timeoutSeconds = @(1, 3600)
        cpuCount = @(0.1, 8)
        memoryMB = @(256, 8192)
        processLimit = @(16, 256)
        outputBytes = @(1024, 16777216)
        tempMB = @(16, 1024)
    }
    foreach ($key in $ranges.Keys) {
        $value = $policy[$key]
        if ($null -eq $value -or $value -is [string] -or $value -is [bool] -or $value -isnot [ValueType]) {
            throw "terminalExecution.$key must be a number."
        }
        $number = 0.0
        try { $number = [double]$value }
        catch { throw "terminalExecution.$key must be a number." }
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or
            $number -lt $ranges[$key][0] -or $number -gt $ranges[$key][1] -or
            ($key -ne 'cpuCount' -and $number -ne [math]::Truncate($number))) {
            throw "terminalExecution.$key must be between $($ranges[$key][0]) and $($ranges[$key][1])$(if ($key -ne 'cpuCount') { ' and a whole number' })."
        }
        $policy[$key] = if ($key -eq 'cpuCount') { $number } else { [int]$number }
    }

    if ($null -eq $policy.allowedHosts -or $policy.allowedHosts -isnot [System.Collections.IList]) {
        throw 'terminalExecution.allowedHosts must be an array of exact DNS names.'
    }
    if ($policy.allowedHosts.Count -gt 32) { throw 'terminalExecution.allowedHosts is limited to 32 names.' }
    $hosts = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $policy.allowedHosts) {
        $candidate = $null
        if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry) -or
            $entry.Length -gt 253 -or $entry -match '[\x00-\x20\x7f/\\:@?#\[\]*]' -or
            -not [uri]::TryCreate(('https://' + $entry + '/'), [UriKind]::Absolute, [ref]$candidate) -or
            $candidate.HostNameType -ne [UriHostNameType]::Dns) {
            throw 'terminalExecution.allowedHosts accepts exact public DNS names, without URLs, ports or wildcards.'
        }
        $hostname = $candidate.IdnHost.ToLowerInvariant().TrimEnd('.')
        if (-not $hostname.Contains('.') -or $hostname -match '\.(local|internal|localhost|localdomain)$') {
            throw 'terminalExecution.allowedHosts must not name local services.'
        }
        foreach ($label in $hostname.Split('.')) {
            if ($label -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$') {
                throw 'terminalExecution.allowedHosts contains an invalid DNS label.'
            }
        }
        if (-not $hosts.Contains($hostname)) { $hosts.Add($hostname) }
    }
    $policy.allowedHosts = @($hosts.ToArray())
    if ($policy.network -eq 'allow-list' -and $hosts.Count -eq 0) {
        throw 'terminalExecution.allowedHosts must contain at least one name when network is allow-list.'
    }

    if ($null -eq $policy.environment -or $policy.environment -isnot [System.Collections.IList]) {
        throw 'terminalExecution.environment must be an array of name and secret records.'
    }
    if ($policy.environment.Count -gt 32) { throw 'terminalExecution.environment is limited to 32 variables.' }
    $environment = [System.Collections.Generic.List[hashtable]]::new()
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $reserved = '^(PATH|HOME|USERPROFILE|PWD|OLDPWD|TMP|TEMP|TMPDIR|ENV|BASH_ENV|SHELLOPTS|BASHOPTS|PSMODULEPATH|SYSTEMROOT|WINDIR|COMSPEC|SSL_CERT_FILE|SSL_CERT_DIR|CURL_CA_BUNDLE|REQUESTS_CA_BUNDLE|NODE_EXTRA_CA_CERTS|GIT_SSL_CAINFO|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)$|^(DOCKER_|COMPOSE_|LD_|DYLD_|SSH_|DOTNET_|GIT_SSH|GIT_ASKPASS)'
    foreach ($entry in $policy.environment) {
        $fields = @{}
        if ($entry -is [System.Collections.IDictionary]) {
            foreach ($key in $entry.Keys) { $fields[[string]$key] = $entry[$key] }
        }
        elseif ($entry -is [pscustomobject]) {
            foreach ($property in $entry.PSObject.Properties) { $fields[$property.Name] = $property.Value }
        }
        else { throw 'terminalExecution.environment entries must be objects.' }
        foreach ($key in $fields.Keys) {
            if ($key -notin @('name', 'secret')) {
                throw 'terminalExecution.environment accepts names and secret markers only, never values or control options.'
            }
        }
        if ($fields.name -isnot [string] -or $fields.name -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,63}$' -or
            $fields.name -match $reserved -or -not $names.Add($fields.name)) {
            throw 'terminalExecution.environment has an invalid, reserved or duplicate variable name.'
        }
        if ($fields.ContainsKey('secret') -and $fields.secret -isnot [bool]) {
            throw 'terminalExecution.environment secret must be a boolean.'
        }
        $environment.Add(@{ name = $fields.name.ToUpperInvariant(); secret = [bool]$fields.secret })
    }
    $policy.environment = @($environment.ToArray())

    $policy
}
