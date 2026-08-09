function Update-DpIntercomDownload {
    <#
    .SYNOPSIS
        Advances an in-flight Telegram file download by one non-blocking step.
    .DESCRIPTION
        Fetching a file takes two Telegram calls - getFile for its path, then the
        content itself - and neither may be awaited on the Host Server's single
        accept thread. Both are started on one pump tick and reaped on a later
        one, exactly like the update poll.

        When the content arrives it is written into the same folder browser
        uploads use and registered in the same Attachment registry, so the Engine
        sees it the way it sees any other Attachment. The prompt then names the
        file, and an image is also handed to the Engine's native Vision input.

        The file itself is untrusted content the agent will read - the same
        accepted risk as any file in a Project (spec 110, A1). What is guarded
        here is everything around it: the size, the name, and the path Telegram
        asked us to fetch.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A pump step driven by the accept loop; a prompt there would hang the Host Server.')]
    param()

    $state = $script:DeskPilot
    $intercom = $state.Intercom
    $download = $intercom.Download
    if (-not $download.stage -or -not $download.task) { return }
    if (-not $download.task.IsCompleted) { return }

    $fail = {
        param([string]$Reason)
        $intercom.Counters.errors++
        Add-DpIntercomLog -Direction 'in' -Kind 'attachment-error' -Detail $Reason -Accepted $false
        $null = Send-DpIntercomMessage -Title 'I could not fetch that file.' -Line @($Reason, 'Try sending it again.') -Kind 'failed'
        $download.stage = ''
        $download.task = $null
    }

    $response = Receive-DpTelegramResponse -Task $download.task

    if ($download.stage -eq 'lookup') {
        $download.task = $null
        if (-not $response.ok) { & $fail $response.error; return }
        $filePath = [string](Get-DpPropertyValue -InputObject $response.result -Name @('file_path') -Default '')
        if ([string]::IsNullOrWhiteSpace($filePath)) { & $fail 'Telegram did not say where the file is.'; return }
        try {
            $download.task = Invoke-DpTelegramFileRequest -Client $intercom.Client -Token $intercom.Token -FilePath $filePath
            $download.stage = 'fetch'
        }
        catch { & $fail (Hide-DpIntercomSecret -Text "$_") }
        return
    }

    # stage 'fetch': the content itself, which is not a Bot API envelope.
    $download.stage = ''
    $task = $download.task
    $download.task = $null

    if ($task.IsFaulted -or $task.IsCanceled) {
        $reason = if ($task.Exception) { $task.Exception.GetBaseException().Message } else { 'The download was cancelled or timed out.' }
        & $fail (Hide-DpIntercomSecret -Text $reason)
        return
    }

    try {
        $httpResponse = $task.Result
        if (-not $httpResponse.IsSuccessStatusCode) {
            & $fail "Telegram returned HTTP $([int]$httpResponse.StatusCode) for the file."
            return
        }
        $bytes = $httpResponse.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    }
    catch {
        & $fail (Hide-DpIntercomSecret -Text "$_")
        return
    }

    $maxBytes = 20MB
    if ($state.Settings.intercom) { $maxBytes = [long]$state.Settings.intercom.maxAttachmentMB * 1MB }
    if ($bytes.Length -gt $maxBytes) {
        & $fail "The file is larger than the $([int]($maxBytes / 1MB)) MB limit."
        return
    }

    try {
        $directory = Get-DpUploadDir -WorkspaceFolder $state.Settings.workspaceFolder
        if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory -Force }
        $target = Get-DpUniqueFilePath -Directory $directory -Name $download.fileName
        [System.IO.File]::WriteAllBytes($target, $bytes)
        $saved = [System.IO.Path]::GetFullPath($target)
        # The same registry a browser upload writes to, so the Engine's Vision
        # input accepts it and an arbitrary local path still cannot.
        $state.Attachments[$saved] = [string]$download.mimeType
    }
    catch {
        & $fail (Hide-DpIntercomSecret -Text "$_")
        return
    }

    Add-DpIntercomLog -Direction 'in' -Kind 'attachment' -Detail "Saved $([System.IO.Path]::GetFileName($saved)) ($([int]($bytes.Length / 1KB)) KB)."

    $caption = [string]$download.caption
    if ([string]::IsNullOrWhiteSpace($caption)) { $caption = 'Have a look at this file and tell me what it is.' }
    $intercom.QueuedPrompt = "$caption`n`n[Attached file: $saved]"
    $intercom.QueuedImage = $(if ($download.isImage) { $saved } else { $null })

    $null = Send-DpIntercomMessage -Title 'Got the file. Working on it.' -Line @(
        [System.IO.Path]::GetFileName($saved)
    ) -Kind 'ack'
}
