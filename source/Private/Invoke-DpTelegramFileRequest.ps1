function Invoke-DpTelegramFileRequest {
    <#
    .SYNOPSIS
        Starts a non-blocking download of a Telegram file and returns its Task.
    .DESCRIPTION
        Telegram serves file content from a different base than the Bot API, so
        this is a separate boundary from Invoke-DpTelegramRequest. Same rule
        applies: the call is started here and reaped on a later pump tick, because
        the Host Server accepts on a single thread and a multi-megabyte download
        executed inline would freeze the whole window.

        The path comes from Telegram's getFile response, which means it is data
        rather than something we chose. It is validated here so it can only ever
        address a file below the bot's own file root - no traversal, no scheme, no
        host of its own.
    .PARAMETER Client
        The shared HttpClient.
    .PARAMETER Token
        The bot token.
    .PARAMETER FilePath
        The relative file path from getFile, for example 'documents/file_5.pdf'.
    .OUTPUTS
        System.Threading.Tasks.Task[System.Net.Http.HttpResponseMessage]
    #>
    [CmdletBinding()]
    [OutputType([System.Threading.Tasks.Task])]
    param(
        [Parameter(Mandatory)]
        [System.Net.Http.HttpClient]$Client,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Token,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath
    )

    $relative = $FilePath.Trim().Replace('\', '/').TrimStart('/')
    if ($relative -match '(^|/)\.\.(/|$)' -or $relative -match '^[A-Za-z]+:' -or $relative.Contains('//')) {
        throw "Telegram returned a file path that will not be fetched: '$relative'."
    }

    $segments = @($relative -split '/' | ForEach-Object { [System.Uri]::EscapeDataString($_) })
    $Client.GetAsync(('https://api.telegram.org/file/bot{0}/{1}' -f $Token, ($segments -join '/')))
}
