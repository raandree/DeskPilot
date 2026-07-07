function Invoke-DpAuthFlow {
    <#
    .SYNOPSIS
        Runs the Engine device-code sign-in and streams progress over SSE.
    .DESCRIPTION
        Invokes Initialize-Shp on the Engine Runspace, forwarding the host output
        (the device code and verification URL, then progress) to the client as SSE
        code frames, and emits a final done frame when authentication completes.
    .PARAMETER Stream
        The network stream to write SSE frames to.
    .PARAMETER Force
        Re-run the device-code flow even when a token file already exists (an
        expired sign-in). Passed through to Initialize-Shp -Force so a stale
        token is replaced instead of short-circuiting as "already signed in".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream,

        [switch]$Force
    )

    $writer = New-DpSseWriter -Stream $Stream
    $ansi = "$([char]27)\[[0-9;]*m"
    $shell = $null
    try {
        # If the Engine never imported, Initialize-Shp does not exist on the
        # runspace; fail with a clear, actionable message instead of a cryptic
        # "term not recognized" so the user knows to fix the Engine first.
        if (-not $script:DeskPilot.Engine.Imported) {
            $detail = if ($script:DeskPilot.Engine.ImportError) { $script:DeskPilot.Engine.ImportError } else { 'The ShellPilot engine is not loaded.' }
            $writer.Write((ConvertTo-DpSseFrame -EventName 'error' -Data @{ message = "Cannot sign in: $detail Install or point DeskPilot at the ShellPilot module, then restart." }))
            return
        }

        # Already signed in (for example the user ran Initialize-Shp in a terminal):
        # report success immediately rather than starting a second device-code flow.
        # Skipped under -Force so an expired token is actually re-issued.
        if (-not $Force -and (Test-Path -LiteralPath $script:DeskPilot.Engine.TokenPath)) {
            $writer.Write((ConvertTo-DpSseFrame -EventName 'done' -Data @{ authenticated = $true }))
            return
        }

        $writer.Write((ConvertTo-DpSseFrame -EventName 'waiting' -Data @{ message = 'Starting GitHub sign-in…' }))

        $shell = [powershell]::Create()
        $shell.Runspace = $script:DeskPilot.Engine.Runspace
        $null = $shell.AddCommand('Initialize-Shp')
        if ($Force) { $null = $shell.AddParameter('Force', $true) }

        $info = $shell.Streams.Information
        $lastIndex = 0
        $async = $shell.BeginInvoke()
        while ($true) {
            while ($lastIndex -lt $info.Count) {
                $record = $info[$lastIndex]
                $lastIndex++
                $messageData = $record.MessageData
                $text = if ($messageData -is [System.Management.Automation.HostInformationMessage]) { $messageData.Message }
                    elseif ($messageData -is [string]) { $messageData } else { "$($record.MessageData)" }
                if ($null -eq $text) { continue }
                $clean = ($text -replace $ansi, '').Trim()
                if ($clean.Length -gt 0) {
                    $writer.Write((ConvertTo-DpSseFrame -EventName 'code' -Data @{ message = $clean }))
                }
            }
            if ($async.IsCompleted) { break }
            Start-Sleep -Milliseconds 150
        }
        while ($lastIndex -lt $info.Count) {
            $record = $info[$lastIndex]
            $lastIndex++
            $messageData = $record.MessageData
            $text = if ($messageData -is [System.Management.Automation.HostInformationMessage]) { $messageData.Message } else { "$($record.MessageData)" }
            $clean = ($text -replace $ansi, '').Trim()
            if ($clean) { $writer.Write((ConvertTo-DpSseFrame -EventName 'code' -Data @{ message = $clean })) }
        }

        $shell.EndInvoke($async) | Out-Null
        if ($shell.HadErrors) {
            $firstError = $shell.Streams.Error | Select-Object -First 1
            throw ($(if ($firstError) { $firstError.ToString() } else { 'Sign-in failed.' }))
        }

        $authenticated = Test-Path -LiteralPath $script:DeskPilot.Engine.TokenPath
        $writer.Write((ConvertTo-DpSseFrame -EventName 'done' -Data @{ authenticated = $authenticated }))
    }
    catch {
        $message = "$_"
        try { $writer.Write((ConvertTo-DpSseFrame -EventName 'error' -Data @{ message = $message })) } catch { $null = $_ }
    }
    finally {
        if ($shell) { try { $shell.Dispose() } catch { $null = $_ } }
        try { $writer.Flush(); $writer.Dispose() } catch { $null = $_ }
    }
}
