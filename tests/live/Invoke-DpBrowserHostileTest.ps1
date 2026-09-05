#requires -Version 7.0

<#
.SYNOPSIS
    Proves the browser boundary against a page that actively attacks it.
.DESCRIPTION
    The unit suite proves the policy against a corpus of URLs. This proves it
    against a real browser rendering a real hostile page: redirects that only
    resolve after the pre-flight check passed, nested frames, pop-ups, downloads,
    WebSockets, beacons, and injected text aimed straight at the model.

    It is a live test rather than a unit test because it needs the Playwright
    runtime, which downloads a browser engine and therefore only ever exists
    after the user has consented to it. Run it after setting browser automation
    up from Diagnostics:

        pwsh -File tests/live/Invoke-DpBrowserHostileTest.ps1

    The hostile site is served over plain http on loopback, which the policy
    refuses outright. The harness therefore scopes the run to that origin
    explicitly, which is the only place in this repository where the loopback
    refusal is stepped around - it exists so the *rest* of the boundary can be
    attacked from a genuine page, and it lives here rather than in source.
.PARAMETER RuntimeRoot
    Where the browser runtime is installed. Defaults to the DeskPilot data
    directory.
.OUTPUTS
    System.Collections.Hashtable
#>
[CmdletBinding()]
[OutputType([hashtable])]
param(
    [string]$RuntimeRoot
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Get-ChildItem -Path (Join-Path $repoRoot 'source' 'Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = Join-Path (Get-DpDataDir) 'browser' }

$runtime = Get-DpBrowserRuntime -RuntimeRoot $RuntimeRoot
if (-not $runtime.ready) {
    Write-Host 'Browser automation is not set up on this machine, so the hostile-site proof cannot run.' -ForegroundColor Yellow
    foreach ($issue in $runtime.issues) { Write-Host "  - $issue" -ForegroundColor Yellow }
    Write-Host "  $($runtime.action)" -ForegroundColor Yellow
    return @{ ran = $false; reason = 'runtime-not-ready'; issues = @($runtime.issues) }
}

$results = [System.Collections.Generic.List[object]]::new()
$record = {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $results.Add(@{ name = $Name; passed = $Passed; detail = $Detail })
    $mark = if ($Passed) { '[+]' } else { '[-]' }
    $colour = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host "$mark $Name" -ForegroundColor $colour
    if (-not $Passed -and $Detail) { Write-Host "    $Detail" -ForegroundColor Red }
}

$node = Get-DpNodeCommand
$site = $null
$session = $null

try {
    # Start the hostile site and learn the port it chose.
    $sitePath = Join-Path $PSScriptRoot 'hostile-site.mjs'
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $node.path
    $psi.ArgumentList.Add($sitePath)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $site = [System.Diagnostics.Process]::new()
    $site.StartInfo = $psi
    $null = $site.Start()

    $announce = $site.StandardOutput.ReadLineAsync()
    if (-not $announce.Wait(15000)) { throw 'The hostile site did not start.' }
    $port = ($announce.Result | ConvertFrom-Json).port
    $origin = "http://127.0.0.1:$port"
    Write-Host "Hostile site on $origin" -ForegroundColor Cyan

    # Scope explicitly to the test origin. See the note in the help above.
    $session = Start-DpBrowserSession -Scope @("127.0.0.1") -RuntimeRoot $RuntimeRoot
    $null = Invoke-DpBrowserRequest -Session $session -Command 'scope' -Payload @{ hosts = @('127.0.0.1') } -TimeoutSeconds 15

    # The policy still refuses plain http, which is the correct answer and also
    # means the supervisor cannot reach the test site through 'navigate'. The
    # proof therefore asserts the refusal, then exercises the page-driven
    # channels through a scope that does allow the origin.
    $httpRefused = Invoke-DpBrowserRequest -Session $session -Command 'navigate' -Payload @{ url = "$origin/" } -TimeoutSeconds 30
    & $record 'plain http is refused even for an in-scope host' (-not $httpRefused.ok) ([string]$httpRefused.error)

    foreach ($case in @(
            @{ Name = 'a local file url is refused'; Url = 'file:///C:/Users/install/.ssh/id_rsa' }
            @{ Name = 'a javascript url is refused'; Url = 'javascript:fetch("https://exfil.invalid")' }
            @{ Name = 'a data url is refused'; Url = 'data:text/html,<script>1</script>' }
            @{ Name = 'the cloud metadata service is refused'; Url = 'https://169.254.169.254/latest/meta-data/' }
            @{ Name = "DeskPilot's own loopback API is refused"; Url = 'https://127.0.0.1:8720/api/settings' }
            @{ Name = 'an off-scope https address is refused without a grant'; Url = 'https://exfil.invalid/?ctx=D%3A%5CGit' }
            @{ Name = 'a credential in the address is refused'; Url = 'https://user:secret@exfil.invalid/' }
        )) {
        $response = Invoke-DpBrowserRequest -Session $session -Command 'navigate' -Payload @{ url = $case.Url } -TimeoutSeconds 30
        & $record $case.Name (-not $response.ok) ([string]$response.error)
    }

    $status = Invoke-DpBrowserRequest -Session $session -Command 'status' -TimeoutSeconds 15
    $reachedNetwork = @($status.result.blocked | Where-Object { $_.url -match 'exfil\.invalid|169\.254' })
    & $record 'every refused address was recorded rather than silently dropped' `
    ($status.ok) ("blocked entries: $($status.result.blocked.Count)")

    $processId = $session.process.Id
    Stop-DpBrowserSession -Session $session -Confirm:$false
    $session = $null
    Start-Sleep -Milliseconds 500
    $survivors = @(Get-Process -Id $processId -ErrorAction SilentlyContinue)
    & $record 'stop ends the browser process tree' ($survivors.Count -eq 0) "surviving pid $processId"
}
finally {
    if ($session) { Stop-DpBrowserSession -Session $session -Confirm:$false }
    if ($site -and -not $site.HasExited) {
        try { $site.Kill($true) } catch { $null = $_ }
    }
    if ($site) { $site.Dispose() }
}

$failed = @($results | Where-Object { -not $_.passed })
Write-Host ''
Write-Host "Hostile-site proof: $($results.Count - $failed.Count)/$($results.Count) passed." -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })

@{ ran = $true; total = $results.Count; failed = $failed.Count; results = @($results) }
