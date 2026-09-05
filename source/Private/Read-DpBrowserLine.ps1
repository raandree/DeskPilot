function Read-DpBrowserLine {
    <#
    .SYNOPSIS
        Reads one protocol line from the supervisor under a deadline.
    .DESCRIPTION
        A blocking read on a child that has stopped answering would hang the Turn
        and, behind it, the single Engine Runspace. So every read carries a
        deadline, and a deadline that expires faults the session rather than
        retrying.

        Faulting is deliberate and permanent for that session. A timed-out read
        leaves a pending read on the stream, so the next line - whenever it
        arrives - would be consumed out of band and answered against the wrong
        request. Correlating a response to the wrong action is exactly the class
        of failure an approval boundary exists to prevent, so the session is
        finished instead of resynchronised.
    .PARAMETER Session
        The session started by Start-DpBrowserSession.
    .PARAMETER TimeoutSeconds
        How long to wait for a line.
    .OUTPUTS
        System.Management.Automation.PSCustomObject, or $null on timeout or exit.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Session,

        [ValidateRange(1, 600)]
        [int]$TimeoutSeconds = 60
    )

    $maxLineChars = 8000000

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        $remaining = [int][math]::Max(1, ($deadline - [datetime]::UtcNow).TotalMilliseconds)

        $task = $Session.process.StandardOutput.ReadLineAsync()
        if (-not $task.Wait($remaining)) {
            $Session.faulted = $true
            return $null
        }

        $line = $task.Result
        if ($null -eq $line) {
            # The stream ended: the child exited.
            $Session.faulted = $true
            return $null
        }

        $line = $line.Trim()
        if (-not $line) { continue }
        if ($line.Length -gt $maxLineChars) {
            $Session.faulted = $true
            return $null
        }

        try { return ($line | ConvertFrom-Json -ErrorAction Stop) }
        catch {
            # Anything the supervisor writes that is not protocol is treated as
            # noise from a broken child, not as data to interpret.
            $Session.faulted = $true
            return $null
        }
    }

    $Session.faulted = $true
    $null
}
