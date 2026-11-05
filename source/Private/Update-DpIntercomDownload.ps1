function Update-DpIntercomDownload {
    <#
    .SYNOPSIS
        Advances the Intercom file batch by one non-blocking step.
    .DESCRIPTION
        Fetching a file takes two Telegram calls - getFile for its path, then the
        content itself - and neither may be awaited on the Host Server's single
        accept thread. Both are started on one pump tick and reaped on a later
        one, exactly like the update poll. The batch's files are fetched one at
        a time, in the order they arrived.

        Each file is written into the same folder browser uploads use and
        registered in the same Attachment registry, so the Engine sees it the way
        it sees any other Attachment.

        Once every file has landed or failed, the batch becomes one queued
        prompt: the words sent with the files, then a line naming each saved
        file, with every image also handed to the Engine's native Vision input.
        A batch holding an Album, or more than one file, first waits until no
        file has arrived for a few seconds, because Telegram never says how many
        files an Album holds. A file sent on its own runs as soon as it lands.
        An instruction that is already queued is never replaced.

        The files themselves are untrusted content the agent will read - the
        same accepted risk as any file in a Project (spec 110, A1). What is
        guarded here is everything around them: the size, the name, the path
        Telegram asked us to fetch, and how many files one batch takes.
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
    $now = [DateTime]::UtcNow

    # Telegram sends an Album's files together, so they arrive within moments of
    # each other; this is how long an Album must be quiet to count as whole.
    $settleSeconds = 3
    # How long a file of an unmentioned group Album waits to be claimed.
    $holdSeconds = 30

    for ($index = $download.held.Count - 1; $index -ge 0; $index--) {
        if (($now - [DateTime]$download.held[$index].receivedUtc).TotalSeconds -ge $holdSeconds) {
            $download.held.RemoveAt($index)
        }
    }

    $maxMB = 20
    if ($state.Settings.intercom) { $maxMB = [int]$state.Settings.intercom.maxAttachmentMB }

    # A file that cannot be fetched is reported with the rest of the batch, so
    # one bad file never costs the others.
    $fail = {
        param([string]$Name, [string]$Reason)
        $intercom.Counters.errors++
        Add-DpIntercomLog -Direction 'in' -Kind 'attachment-error' -Detail "$Name could not be fetched: $Reason" -Accepted $false
        $download.failed.Add(@{
                title   = 'I could not fetch that file.'
                lines   = @($Reason, 'Try sending it again.')
                summary = "$Name could not be fetched: $Reason"
                kind    = 'failed'
            })
        $download.stage = ''
        $download.task = $null
    }

    # 1. Advance the file in flight.
    if ($download.stage) {
        if (-not $download.task -or -not $download.task.IsCompleted) { return }

        if ($download.stage -eq 'lookup') {
            $response = Receive-DpTelegramResponse -Task $download.task
            $download.task = $null
            $filePath = ''
            if ($response.ok) { $filePath = [string](Get-DpPropertyValue -InputObject $response.result -Name @('file_path') -Default '') }
            if (-not $response.ok) { & $fail $download.fileName $response.error }
            elseif ([string]::IsNullOrWhiteSpace($filePath)) { & $fail $download.fileName 'Telegram did not say where the file is.' }
            else {
                try {
                    $download.task = Invoke-DpTelegramFileRequest -Client $intercom.Client -Token $intercom.Token -FilePath $filePath
                    $download.stage = 'fetch'
                    return
                }
                catch { & $fail $download.fileName (Hide-DpIntercomSecret -Text "$_") }
            }
        }
        else {
            # 'fetch': the content itself, which is not a Bot API envelope.
            $task = $download.task
            $download.stage = ''
            $download.task = $null
            $bytes = $null

            if ($task.IsFaulted -or $task.IsCanceled) {
                $reason = if ($task.Exception) { $task.Exception.GetBaseException().Message } else { 'The download was cancelled or timed out.' }
                & $fail $download.fileName (Hide-DpIntercomSecret -Text $reason)
            }
            else {
                try {
                    $httpResponse = $task.Result
                    if ($httpResponse.IsSuccessStatusCode) {
                        $bytes = $httpResponse.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                    }
                    else {
                        & $fail $download.fileName "Telegram returned HTTP $([int]$httpResponse.StatusCode) for the file."
                    }
                }
                catch { & $fail $download.fileName (Hide-DpIntercomSecret -Text "$_") }
            }

            if ($null -ne $bytes -and $bytes.Length -gt ([long]$maxMB * 1MB)) {
                & $fail $download.fileName "The file is larger than the $maxMB MB limit."
            }
            elseif ($null -ne $bytes) {
                try {
                    $directory = Get-DpUploadDir -WorkspaceFolder $state.Settings.workspaceFolder
                    if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory -Force }
                    $target = Get-DpUniqueFilePath -Directory $directory -Name $download.fileName
                    [System.IO.File]::WriteAllBytes($target, $bytes)
                    $saved = [System.IO.Path]::GetFullPath($target)
                    # The same registry a browser upload writes to, so the Engine's
                    # Vision input accepts it and an arbitrary local path still cannot.
                    $state.Attachments[$saved] = [string]$download.mimeType
                    $download.saved.Add(@{ path = $saved; isImage = [bool]$download.isImage })
                    Add-DpIntercomLog -Direction 'in' -Kind 'attachment' -Detail "Saved $([System.IO.Path]::GetFileName($saved)) ($([int]($bytes.Length / 1KB)) KB)."
                }
                catch { & $fail $download.fileName (Hide-DpIntercomSecret -Text "$_") }
            }
        }
    }

    # 2. Start the next file. One that cannot be fetched at all - no file id, or
    #    over the size limit - is reported without a request.
    while (-not $download.stage -and $download.pending.Count -gt 0) {
        $next = $download.pending[0]
        $download.pending.RemoveAt(0)
        $name = [string]$next.fileName

        if ([string]::IsNullOrWhiteSpace([string]$next.fileId)) {
            $download.failed.Add(@{
                    title   = 'I could not read that attachment.'
                    lines   = @('Try sending it as a file.')
                    summary = "$name could not be read."
                    kind    = 'failed'
                })
            continue
        }
        # The size Telegram reports is checked before anything is fetched, so an
        # oversized file costs nothing rather than a download that is thrown away.
        if ([long]$next.size -gt ([long]$maxMB * 1MB)) {
            $download.failed.Add(@{
                    title   = 'That file is too big.'
                    lines   = @("$name is larger than the $maxMB MB limit.", 'Put it in the project folder and tell me where to look instead.')
                    summary = "$name is larger than the $maxMB MB limit."
                    kind    = 'refused'
                })
            continue
        }

        $download.fileId = [string]$next.fileId
        $download.fileName = $name
        $download.mimeType = [string]$next.mimeType
        $download.isImage = [bool]$next.isImage
        try {
            $requestParams = @{
                Client    = $intercom.Client
                Token     = $intercom.Token
                Operation = 'getFile'
                Payload   = @{ file_id = [string]$next.fileId }
            }
            $download.task = Invoke-DpTelegramRequest @requestParams
            $download.stage = 'lookup'
            Add-DpIntercomLog -Direction 'in' -Kind 'attachment' -Detail "Fetching $name."
        }
        catch { & $fail $name (Hide-DpIntercomSecret -Text "$_") }
    }
    if ($download.stage) { return }

    # 3. Nothing is left to fetch: the batch becomes one prompt, once an Album
    #    has gone quiet.
    $fileCount = $download.saved.Count + $download.failed.Count
    if ($fileCount -eq 0) { return }
    if (($download.albums.Count -gt 0 -or $fileCount -gt 1) -and $null -ne $download.lastItemUtc -and
        ($now - [DateTime]$download.lastItemUtc).TotalSeconds -lt $settleSeconds) { return }

    $savedFiles = @($download.saved.ToArray())
    $failures = @($download.failed.ToArray())
    $refused = [int]$download.refused
    $maxFiles = [int]$download.maxFiles
    $caption = [string]$download.caption
    $batchChat = [string]$download.chatId
    Clear-DpIntercomDownload -KeepHeld

    $names = @($savedFiles | ForEach-Object { [System.IO.Path]::GetFileName([string]$_.path) })
    $notes = [System.Collections.Generic.List[string]]::new()
    foreach ($failure in $failures) { $notes.Add([string]$failure.summary) }
    if (@($failures | Where-Object { $_.kind -eq 'refused' }).Count -gt 0) {
        $notes.Add('Put a file that is too big in the project folder and tell me where to look instead.')
    }
    if (@($failures | Where-Object { $_.kind -ne 'refused' }).Count -gt 0) {
        $notes.Add('Send the files I could not fetch again.')
    }
    if ($refused -eq 1) {
        $notes.Add("1 more file was not taken: I take at most $maxFiles files at a time, so send it again separately.")
    }
    elseif ($refused -gt 1) {
        $notes.Add("$refused more files were not taken: I take at most $maxFiles files at a time, so send them again separately.")
    }

    if ($savedFiles.Count -eq 0) {
        # A file sent on its own keeps the exact message it always had.
        if ($failures.Count -eq 1 -and $refused -eq 0) {
            $null = Send-DpIntercomMessage -Title ([string]$failures[0].title) -Line @($failures[0].lines) -Kind ([string]$failures[0].kind)
        }
        else {
            $null = Send-DpIntercomMessage -Title 'I could not fetch those files.' -Line $notes.ToArray() -Kind 'failed'
        }
        return
    }

    $pronoun = if ($savedFiles.Count -eq 1) { 'it' } else { 'them' }

    # maxAttachmentMB bounds what may be written to disk; Vision has its own,
    # much smaller budget, because an image is inlined into the Turn as base64
    # and an oversized set fails the whole request at the Copilot endpoint. There
    # is no browser here to downscale it first, so it is refused with the reason.
    $images = @($savedFiles | Where-Object { $_.isImage } | ForEach-Object { [string]$_.path })
    if ($images.Count -gt 0) {
        $visionBudgetError = Get-DpVisionBudgetError -Path $images
        if ($visionBudgetError) {
            $intercom.Counters.errors++
            Add-DpIntercomLog -Direction 'in' -Kind 'attachment-error' -Detail $visionBudgetError -Accepted $false
            $savedAs = if ($names.Count -eq 1) { "It is saved as $($names[0]), so I can still read it as a file." }
            else { "They are saved as $($names -join ', '), so I can still read them as files." }
            $null = Send-DpIntercomMessage -Title $(if ($images.Count -eq 1) { 'That image is too large to show the model.' } else { 'Those images are too large to show the model.' }) -Line (@($visionBudgetError, $savedAs) + $notes.ToArray()) -Kind 'failed'
            return
        }
    }

    # Replacing a queued instruction would silently drop it.
    if ($intercom.QueuedPrompt) {
        $null = Send-DpIntercomMessage -Title 'One instruction is already queued.' -Line (@(
                "I saved $($names -join ', '), but did not start anything with $pronoun.",
                "Ask me about $pronoun once that instruction has run."
            ) + $notes.ToArray()) -Kind 'notice'
        return
    }

    if ([string]::IsNullOrWhiteSpace($caption)) {
        $caption = if ($savedFiles.Count -eq 1) { 'Have a look at this file and tell me what it is.' } else { 'Have a look at these files and tell me what they are.' }
    }
    $fileLines = @($savedFiles | ForEach-Object { "[Attached file: $([string]$_.path)]" })
    $intercom.QueuedPrompt = "$caption`n`n$($fileLines -join "`n")"
    $intercom.QueuedChatId = $batchChat
    $intercom.QueuedImage = $null
    if ($images.Count -gt 0) { $intercom.QueuedImage = [string[]]$images }

    $working = "Working on $pronoun."
    $title = if ($failures.Count -gt 0) { "Got $($savedFiles.Count) of $fileCount files. $working" }
    elseif ($savedFiles.Count -eq 1) { "Got the file. $working" }
    else { "Got $($savedFiles.Count) files. $working" }
    $null = Send-DpIntercomMessage -Title $title -Line (@($names) + $notes.ToArray()) -Kind 'ack'
}
