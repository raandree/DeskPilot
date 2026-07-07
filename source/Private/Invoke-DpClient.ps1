function Invoke-DpClient
{
    <#
    .SYNOPSIS
        Reads, dispatches, and closes one accepted TCP client.
    .DESCRIPTION
        Shared by the main accept loop in Start-DeskPilot and by
        Invoke-DpPendingRequest (which services concurrent requests - notably
        POST /stop - while a Turn holds the single accept thread). Reads one
        HTTP request from the client, dispatches it through Invoke-DpRequest,
        and always closes the client. All errors are swallowed so a single bad
        connection never tears down the server or an in-flight Turn.
    .PARAMETER Client
        The accepted TCP client.
    .PARAMETER ReadTimeoutMs
        The client stream read timeout in milliseconds.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [System.Net.Sockets.TcpClient]$Client,

        [int]$ReadTimeoutMs = 60000
    )

    try
    {
        $Client.NoDelay = $true
        $netStream = $Client.GetStream()
        $netStream.ReadTimeout = $ReadTimeoutMs
        $request = Receive-DpHttpRequest -Stream $netStream
        if ($request) { Invoke-DpRequest -Request $request -Stream $netStream }
    }
    catch { $null = $_ }
    finally { try { $Client.Close() } catch { $null = $_ } }
}
