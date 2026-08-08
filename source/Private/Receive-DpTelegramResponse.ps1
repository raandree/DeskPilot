function Receive-DpTelegramResponse {
    <#
    .SYNOPSIS
        Reads a completed Telegram request Task into a plain result record.
    .DESCRIPTION
        Call only once the Task reports IsCompleted. HttpClient buffers the whole
        response body before completing a GetAsync/PostAsync Task, so reading the
        content here does not block the accept thread.

        Never throws: a transport fault, a non-success status, an unparseable body
        and a Bot API error all come back as ok = false with a message that has
        already had the bot token removed.
    .PARAMETER Task
        The completed Task returned by Invoke-DpTelegramRequest.
    .OUTPUTS
        System.Collections.Hashtable with ok, result and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.Threading.Tasks.Task]$Task
    )

    if ($Task.IsFaulted -or $Task.IsCanceled) {
        $reason = if ($Task.Exception) { $Task.Exception.GetBaseException().Message } else { 'The request was cancelled or timed out.' }
        return @{ ok = $false; result = $null; error = (Hide-DpIntercomSecret -Text $reason) }
    }

    try {
        $response = $Task.Result
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
    catch {
        return @{ ok = $false; result = $null; error = (Hide-DpIntercomSecret -Text "$_") }
    }

    if ([string]::IsNullOrWhiteSpace($body)) {
        return @{ ok = $false; result = $null; error = "Telegram returned an empty response (HTTP $([int]$response.StatusCode))." }
    }

    try {
        $parsed = $body | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return @{ ok = $false; result = $null; error = "Telegram returned a response that could not be read (HTTP $([int]$response.StatusCode))." }
    }

    if (-not [bool](Get-DpPropertyValue -InputObject $parsed -Name @('ok') -Default $false)) {
        $description = [string](Get-DpPropertyValue -InputObject $parsed -Name @('description') -Default 'Telegram rejected the request.')
        return @{ ok = $false; result = $null; error = (Hide-DpIntercomSecret -Text $description) }
    }

    @{ ok = $true; result = (Get-DpPropertyValue -InputObject $parsed -Name @('result') -Default $null); error = '' }
}
