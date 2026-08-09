function Invoke-DpTelegramRequest {
    <#
    .SYNOPSIS
        Starts a non-blocking Telegram Bot API call and returns its Task.
    .DESCRIPTION
        The single Telegram boundary. It starts the HTTP call and returns
        immediately with the in-flight Task; the caller reaps it on a later pump
        tick with Receive-DpTelegramResponse.

        This is not an optimisation. The Host Server accepts requests inline on
        one thread, so a 25-second long-poll executed synchronously would freeze
        the entire UI - the same failure Invoke-DpGitCommand exists to prevent.
        Nothing in Intercom is ever awaited on the accept thread.

        The host is fixed to api.telegram.org and only the operation name and
        parameters vary, so no caller can redirect the request. The bot token
        travels in the URL path, which is why every error path in Intercom passes
        its text through Hide-DpIntercomSecret before it is logged or returned.
    .PARAMETER Client
        The shared HttpClient. Its Timeout must exceed the long-poll timeout.
    .PARAMETER Token
        The bot token.
    .PARAMETER Operation
        The Bot API method name, for example getMe, getUpdates or sendMessage.
    .PARAMETER Payload
        Parameters to send as a JSON body (POST). Omit for a bare GET.
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
        [ValidatePattern('^[A-Za-z]+$')]
        [string]$Operation,

        [AllowNull()]
        [hashtable]$Payload
    )

    $url = 'https://api.telegram.org/bot{0}/{1}' -f $Token, $Operation

    if ($null -eq $Payload -or $Payload.Count -eq 0) {
        return $Client.GetAsync($url)
    }

    $json = $Payload | ConvertTo-Json -Depth 10 -Compress
    $content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
    $Client.PostAsync($url, $content)
}
