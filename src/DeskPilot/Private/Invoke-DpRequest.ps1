function Invoke-DpRequest {
    <#
    .SYNOPSIS
        Dispatches one parsed HTTP request: security, static files, or a route.
    .DESCRIPTION
        Enforces the session-token gate on the /api surface, serves static SPA
        assets (with index.html fallback) for everything else, matches API routes,
        parses the JSON body, and invokes the matching route handler. Any
        unhandled error is returned as a 500.
    .PARAMETER Request
        The parsed request hashtable from Receive-DpHttpRequest.
    .PARAMETER Stream
        The network stream to write the response to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Request,

        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream
    )

    $method = $Request.Method
    $path = $Request.Path

    try {
        $isApi = $path.StartsWith('/api/')

        if ($isApi) {
            $token = $Request.Headers['X-DeskPilot-Token']
            if (-not $token) { $token = $Request.Query['t'] }
            if (-not $script:DeskPilot.Token -or $token -ne $script:DeskPilot.Token) {
                Write-DpResponse -Stream $Stream -Status 401 -Json @{ error = @{ code = 'unauthorized'; message = 'Missing or invalid session token.' } }
                return
            }
        }

        if (-not $isApi) {
            $static = Get-DpStaticContent -WebRoot $script:DeskPilot.WebRoot -RequestPath $path
            if (-not $static.Found) {
                $static = Get-DpStaticContent -WebRoot $script:DeskPilot.WebRoot -RequestPath '/index.html'
            }
            if ($static.Found) {
                Write-DpResponse -Stream $Stream -Status 200 -Bytes $static.Bytes -ContentType $static.ContentType
            }
            else {
                Write-DpResponse -Stream $Stream -Status 404 -Text 'Not found' -ContentType 'text/plain; charset=utf-8'
            }
            return
        }

        $match = Get-DpRouteMatch -Method $method -Path $path -Route $script:DeskPilot.Routes
        if (-not $match) {
            Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = "No route for $method $path." } }
            return
        }

        $body = $null
        $contentType = if ($Request.Headers['Content-Type']) { [string]$Request.Headers['Content-Type'] } else { '' }
        $isMultipart = $contentType -match '^multipart/form-data'
        if ($Request.Body -and -not $isMultipart) {
            try { $body = $Request.Body | ConvertFrom-Json -ErrorAction Stop }
            catch {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_json'; message = 'Request body is not valid JSON.' } }
                return
            }
        }

        Invoke-DpRouteHandler -Name $match.Route.Name -RouteParams $match.Params -Body $body -Stream $Stream -Request $Request
    }
    catch {
        $message = "$_"
        try { Write-DpResponse -Stream $Stream -Status 500 -Json @{ error = @{ code = 'server_error'; message = $message } } } catch { $null = $_ }
    }
}
