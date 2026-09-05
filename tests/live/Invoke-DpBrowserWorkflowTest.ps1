#requires -Version 7.0

<#
.SYNOPSIS
    Runs the authorised workflow against the real site, end to end.
.DESCRIPTION
    Decision 0003 authorised exactly one workflow: read the forecast for Osorno,
    Chile, by following links through weathercity.com. The hostile-site proof
    shows the boundary holds against an attacker; this shows the boundary does
    not also prevent the task it was built for, which is the other half of a
    control being correct.

    It drives the real Tool through the real supervisor, so the approval bridge
    is exercised too - a stand-in bridge answers, because a script has no window
    to click in. What it does not prove is a real Model choosing the Tool; that
    needs a Copilot session and a person.

    Needs the runtime and a working internet connection:

        pwsh -File tests/live/Invoke-DpBrowserWorkflowTest.ps1
.PARAMETER RuntimeRoot
    Where the browser runtime is installed.
.PARAMETER ScreenshotRoot
    Where to write the screenshots. Defaults to a temp folder.
.OUTPUTS
    System.Collections.Hashtable
#>
[CmdletBinding()]
[OutputType([hashtable])]
param(
    [string]$RuntimeRoot,

    [string]$ScreenshotRoot
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Get-ChildItem -Path (Join-Path $repoRoot 'source' 'Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = Join-Path (Get-DpDataDir) 'browser' }
if ([string]::IsNullOrWhiteSpace($ScreenshotRoot)) {
    $ScreenshotRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-workflow-' + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Path $ScreenshotRoot -Force | Out-Null

$runtime = Get-DpBrowserRuntime -RuntimeRoot $RuntimeRoot
if (-not $runtime.ready) {
    Write-Host 'Browser automation is not set up, so the workflow proof cannot run.' -ForegroundColor Yellow
    foreach ($issue in $runtime.issues) { Write-Host "  - $issue" -ForegroundColor Yellow }
    return @{ ran = $false; reason = 'runtime-not-ready' }
}

$results = [System.Collections.Generic.List[object]]::new()
$record = {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $results.Add(@{ name = $Name; passed = $Passed; detail = $Detail })
    $mark = if ($Passed) { '[+]' } else { '[-]' }
    Write-Host "$mark $Name" -ForegroundColor $(if ($Passed) { 'Green' } else { 'Red' })
    if ($Detail) { Write-Host "    $Detail" -ForegroundColor DarkGray }
}

# Stands in for the window nobody is looking at. It records what it was asked so
# the proof can assert the card would have carried the right thing.
$bridge = [pscustomobject]@{ Enabled = $true; Asked = [System.Collections.Generic.List[string]]::new() }
$bridge | Add-Member -MemberType ScriptMethod -Name CaptureQuestion -Value { param($q) $this.Asked.Add($q) }
$bridge | Add-Member -MemberType ScriptMethod -Name RequestAnswer -Value {
    param($seconds)
    $request = $this.Asked[-1] | ConvertFrom-Json
    @{ decision = 'approve'; note = ''; fingerprint = $request.fingerprint } | ConvertTo-Json -Compress
}

$global:DeskPilotBrowserContext = @{
    conversationId = 'live-1'
    turnId         = 'live-turn-1'
    project        = 'Live proof'
    projectRoot    = $repoRoot
    projectDomains = @()
    actions        = @()
    runtimeRoot    = $RuntimeRoot
    downloadRoot   = (Join-Path (Get-DpDataDir) 'browser-downloads')
    # The user's own message. Scope comes from here, never from the address the
    # Model chooses - see Blocker B-1 in the 2026-09-05 security review.
    userUrl        = 'what is the weather in Osorno? look it up on https://weathercity.com/'
}
$global:DeskPilotBrowserState = @{ session = $null; scope = @(); granted = @(); lastUrl = '' }
$global:DeskPilotBrowserBridge = $bridge
$global:DeskPilotBrowserTimeoutMinutes = 5

try {
    $open = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/' | ConvertFrom-Json
    & $record 'the weather site opens' $open.ok ([string]$open.error)
    if (-not $open.ok) { throw "Could not open the site: $($open.error)" }

    & $record 'no card was raised for the site the user named' ($bridge.Asked.Count -eq 0) "cards: $($bridge.Asked.Count)"
    & $record 'the scope came from the user message' `
    (@($global:DeskPilotBrowserState.scope) -contains 'weathercity.com') ($global:DeskPilotBrowserState.scope -join ', ')

    $chile = Invoke-DpBrowserTool -Action click_link -LinkText 'Chile' | ConvertFrom-Json
    & $record 'the Chile link is followed' ($chile.ok -and $chile.url -match '/cl/') ([string]$chile.url)

    $osorno = Invoke-DpBrowserTool -Action click_link -LinkText 'Osorno' | ConvertFrom-Json
    & $record 'the Osorno link is followed' ($osorno.ok -and $osorno.url -match 'osorno') ([string]$osorno.url)

    $read = Invoke-DpBrowserTool -Action read_page | ConvertFrom-Json
    $forecast = [string]$read.pageText
    & $record 'the forecast is readable' ($read.ok -and $forecast.Length -gt 100) "page text: $($forecast.Length) characters"
    & $record 'the page text is labelled as information, not instructions' `
    ([string]$read.pageTextNote -match 'not instructions') ''

    $summary = ($forecast -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 6) -join ' / '
    Write-Host "    $summary" -ForegroundColor Cyan

    $shot = Invoke-DpBrowserTool -Action screenshot | ConvertFrom-Json
    if ($shot.ok -and $shot.screenshotBase64) {
        $path = Join-Path $ScreenshotRoot 'osorno.png'
        [System.IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($shot.screenshotBase64))
        & $record 'a screenshot of the result is captured' (Test-Path -LiteralPath $path) $path
    }
    else {
        & $record 'a screenshot of the result is captured' $false ([string]$shot.error)
    }

    # The free hop B-1 closed: before the fix, the first open of any Turn was
    # allowed to any host on the internet with no card at all.
    $before = $bridge.Asked.Count
    $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/?leak=D%3A%5CGit%5CDeskPilot'
    & $record 'a model-composed query on the same site still asks' `
    (($bridge.Asked.Count - $before) -eq 1) "cards raised: $($bridge.Asked.Count - $before)"

    # The write actions must stay refused: this Project granted none of them.
    foreach ($case in @(
            @{ Name = 'filling a form is refused for this project'; Action = 'fill_form'; Extra = @{ Fields = '[{"name":"q","value":"x"}]' } }
            @{ Name = 'pressing a button is refused for this project'; Action = 'click_button'; Extra = @{ ButtonText = 'Search' } }
        )) {
        $extra = $case.Extra
        $response = Invoke-DpBrowserTool -Action $case.Action @extra | ConvertFrom-Json
        & $record $case.Name (-not $response.ok -and $response.error -match 'does not allow') ([string]$response.error)
    }
}
finally {
    if ($global:DeskPilotBrowserState.session) {
        Stop-DpBrowserSession -Session $global:DeskPilotBrowserState.session -Confirm:$false
    }
    foreach ($name in 'DeskPilotBrowserContext', 'DeskPilotBrowserState', 'DeskPilotBrowserBridge', 'DeskPilotBrowserTimeoutMinutes') {
        Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
    }
}

$failed = @($results | Where-Object { -not $_.passed })
Write-Host ''
Write-Host "Workflow proof: $($results.Count - $failed.Count)/$($results.Count) passed. Screenshots in $ScreenshotRoot" `
    -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })

@{ ran = $true; total = $results.Count; failed = $failed.Count; results = @($results); screenshots = $ScreenshotRoot }
