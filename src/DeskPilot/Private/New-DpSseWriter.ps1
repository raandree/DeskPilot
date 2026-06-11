function New-DpSseWriter {
    <#
    .SYNOPSIS
        Writes SSE response headers and returns a writer for streaming frames.
    .DESCRIPTION
        Emits an HTTP/1.1 200 response head with a text/event-stream content type,
        then returns an auto-flushing UTF-8 StreamWriter the caller uses to write
        SSE frames produced by ConvertTo-DpSseFrame.
    .PARAMETER Stream
        The network stream to write to.
    .OUTPUTS
        System.IO.StreamWriter
    #>
    [CmdletBinding()]
    [OutputType([System.IO.StreamWriter])]
    param(
        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream
    )

    $head = "HTTP/1.1 200 OK`r`n" +
        "Content-Type: text/event-stream`r`n" +
        "Cache-Control: no-store`r`n" +
        "Connection: close`r`n" +
        "X-Accel-Buffering: no`r`n`r`n"
    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($headBytes, 0, $headBytes.Length)
    $Stream.Flush()

    $writer = [System.IO.StreamWriter]::new($Stream, [System.Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true
    $writer
}
