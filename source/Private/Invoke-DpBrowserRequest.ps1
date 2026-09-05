function Invoke-DpBrowserRequest {
    <#
    .SYNOPSIS
        Sends one command to the supervisor and waits for its answer.
    .DESCRIPTION
        Requests carry a monotonic id and are matched to the response bearing the
        same id. Anything arriving with an `event` instead is a refusal the
        supervisor made on its own - a blocked navigation, a closed pop-up, a
        cancelled download - and is collected onto the session so Activity can
        show what the page tried, not only what succeeded.

        A response whose id does not match the request faults the session. Two
        ids in flight would mean an answer could be attributed to the wrong
        action, and every guarantee here rests on knowing which action was
        answered.
    .PARAMETER Session
        The session started by Start-DpBrowserSession.
    .PARAMETER Command
        The supervisor command name.
    .PARAMETER Payload
        Command arguments, already validated by the caller.
    .PARAMETER TimeoutSeconds
        Wall-clock deadline for the whole exchange.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Session,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Command,

        [hashtable]$Payload = @{},

        [ValidateRange(1, 600)]
        [int]$TimeoutSeconds = 60
    )

    if ($Session.faulted) {
        return @{ ok = $false; error = 'The browser session has stopped responding and was closed.' }
    }
    if ($Session.process.HasExited) {
        $Session.faulted = $true
        return @{ ok = $false; error = 'The browser closed unexpectedly.' }
    }

    $id = $Session.nextId
    $Session.nextId = $id + 1

    $request = @{ id = $id; command = $Command }
    foreach ($key in $Payload.Keys) { $request[$key] = $Payload[$key] }

    try {
        $Session.process.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 6 -Compress))
        $Session.process.StandardInput.Flush()
    }
    catch {
        $Session.faulted = $true
        return @{ ok = $false; error = 'The browser stopped accepting commands.' }
    }

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $remaining = [int][math]::Ceiling(($deadline - [datetime]::UtcNow).TotalSeconds)
        if ($remaining -lt 1) {
            $Session.faulted = $true
            return @{ ok = $false; error = "The browser did not answer within $TimeoutSeconds seconds." }
        }

        $message = Read-DpBrowserLine -Session $Session -TimeoutSeconds $remaining
        if ($null -eq $message) {
            return @{ ok = $false; error = 'The browser stopped responding.' }
        }

        if ($message.PSObject.Properties['event']) {
            if ($Session.events.Count -lt 500) { $Session.events.Add($message) }
            continue
        }

        if ($message.id -ne $id) {
            $Session.faulted = $true
            return @{ ok = $false; error = 'The browser answered a different request, so the session was closed.' }
        }

        return @{ ok = [bool]$message.ok; result = $message.result; error = [string]$message.error }
    }
}
