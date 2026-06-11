#requires -Version 7.0
<#
.SYNOPSIS
    Live end-to-end test of DeskPilot against the real GitHub Copilot model.
.DESCRIPTION
    Starts the DeskPilot Host Server on a loopback port, then drives real
    streaming Turns through the Server-Sent-Events message endpoint using
    HttpClient and verifies the full agent loop:

      1. A simple streaming Turn  - confirms start/delta/done SSE events,
         answer content, and token/cost Usage.
      2. Multi-turn history       - confirms -History replay keeps context
         across Turns in one Conversation.
      3. A tool-using Turn        - confirms the agent reads a file and the
         Activity panel reports it.
      4. Usage accrual            - confirms cumulative Usage totals.

    This test SENDS REAL PROMPTS and CONSUMES COPILOT CREDITS. It is kept out of
    the Pester unit suite on purpose. The cheapest available model (preferring a
    Haiku/Mini/Flash id) is used to keep cost low.

    The Host Server is launched as a detached process and stopped by process id
    at the end, so the VS Code terminal never blocks on the accept loop.
.PARAMETER Port
    Loopback port for the Host Server. Default 8479.
.PARAMETER Model
    Force a specific Model id. By default the cheapest discovered Model is used.
.PARAMETER EngineModulePath
    Optional explicit path to the ShellPilot Engine module.
.EXAMPLE
    pwsh -NoProfile -File ./tests/live/Invoke-DeskPilotLiveTest.ps1

    Runs the full live test and writes a transcript to
    output/live-test-results.txt.
#>
[CmdletBinding()]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'This is a standalone diagnostic runner; host output is the intended UX.')]
param(
    [int]$Port = 8479,
    [string]$Model,
    [string]$EngineModulePath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$outputDir = Join-Path $repoRoot 'output'
New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
$resultsPath = Join-Path $outputDir 'live-test-results.txt'
$serverOut = Join-Path $outputDir 'live-test-server.out'
$serverErr = Join-Path $outputDir 'live-test-server.err'
Remove-Item $serverOut, $serverErr, $resultsPath -ErrorAction SilentlyContinue

$results = [System.Collections.Generic.List[string]]::new()
function Add-Result {
    param([string]$Line)
    $results.Add($Line)
    Write-Host $Line
}

# ----- Start the Host Server (detached) -----
$dataDir = Join-Path $env:TEMP 'deskpilot_livetest_data'
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
$startArgs = @('-NoProfile', '-File', (Join-Path $repoRoot 'Start-DeskPilot.ps1'), '-Port', "$Port", '-NoBrowser', '-DataDir', $dataDir)
if ($EngineModulePath) { $startArgs += @('-EngineModulePath', $EngineModulePath) }
$server = Start-Process pwsh -ArgumentList $startArgs -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr -WindowStyle Hidden -PassThru
Add-Result "server: launched pid=$($server.Id) port=$Port dataDir=$dataDir"

# ----- Parse the session token from the banner -----
$token = $null
for ($i = 0; $i -lt 40 -and -not $token; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $serverOut) {
        $banner = Get-Content $serverOut -Raw
        if ($banner -match '\?t=([0-9a-f]{32})') { $token = $Matches[1] }
    }
}

$base = "http://127.0.0.1:$Port"
$headers = @{ 'X-DeskPilot-Token' = $token }

# ----- HttpClient that can read the SSE stream -----
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(240)
$client.DefaultRequestHeaders.ExpectContinue = $false
if ($token) { $client.DefaultRequestHeaders.Add('X-DeskPilot-Token', $token) }

function Invoke-LiveTurn {
    <#
        Sends a prompt to a Conversation and returns the ordered SSE events as
        objects with Event and Data members, plus a DeltaText reassembly.
    #>
    param(
        [string]$ConversationId,
        [string]$Prompt
    )
    $url = "$base/api/conversations/$ConversationId/messages"
    $body = @{ prompt = $Prompt } | ConvertTo-Json -Compress
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $url)
    $req.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')

    $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $reader = [System.IO.StreamReader]::new($stream)

    $events = [System.Collections.Generic.List[object]]::new()
    $deltaText = [System.Text.StringBuilder]::new()
    $curEvent = $null
    $curData = ''
    try {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            if ($line.StartsWith('event:')) { $curEvent = $line.Substring(6).Trim() }
            elseif ($line.StartsWith('data:')) { $curData = $line.Substring(5).Trim() }
            elseif ($line.Length -eq 0) {
                if ($curEvent) {
                    $parsed = $null
                    if ($curData) { try { $parsed = $curData | ConvertFrom-Json } catch { $parsed = $null } }
                    if ($curEvent -eq 'delta' -and $parsed) { [void]$deltaText.Append($parsed.text) }
                    $events.Add([pscustomobject]@{ Event = $curEvent; Data = $parsed })
                    $curEvent = $null; $curData = ''
                }
            }
        }
    }
    finally {
        $reader.Dispose()
        $resp.Dispose()
    }

    [pscustomobject]@{
        Events    = $events
        DeltaText = $deltaText.ToString()
        Done      = ($events | Where-Object Event -EQ 'done' | Select-Object -First 1).Data
        Error     = ($events | Where-Object Event -EQ 'error' | Select-Object -First 1).Data
        Deltas    = @($events | Where-Object Event -EQ 'delta')
        HasStart  = [bool](@($events | Where-Object Event -EQ 'start').Count)
    }
}

$workspace = $null
$workspace2 = $null
$server2 = $null
try {
    if (-not $token) {
        Add-Result 'FAIL: Host Server did not start or no token was printed.'
        if (Test-Path $serverOut) { Add-Result "--- server stdout ---`n$(Get-Content $serverOut -Raw)" }
        if (Test-Path $serverErr) { Add-Result "--- server stderr ---`n$(Get-Content $serverErr -Raw)" }
        return
    }
    Add-Result "server: token acquired ($($token.Substring(0,6))...)"

    # ----- Health & auth -----
    $health = Invoke-RestMethod "$base/api/health" -Headers $headers
    Add-Result "health: status=$($health.status) engineImported=$($health.engineImported) authenticated=$($health.authenticated)"
    if (-not $health.authenticated) {
        Add-Result 'FAIL: Engine is not authenticated. Run Initialize-Shp once, then retry.'
        return
    }

    # ----- Models: pick the cheapest -----
    $modelsResp = Invoke-RestMethod "$base/api/models" -Headers $headers
    $modelIds = @($modelsResp.models.id)
    $useModel = if ($Model) {
        $Model
    }
    else {
        # Explicit preference order, cheapest-first, then any small-model id.
        $preferred = @('claude-haiku-4.5', 'gpt-4o-mini', 'gpt-4.1-mini', 'o4-mini', 'gemini-2.5-flash')
        $pick = $preferred | Where-Object { $modelIds -contains $_ } | Select-Object -First 1
        if (-not $pick) { $pick = $modelIds | Where-Object { $_ -match 'haiku|mini|flash|lite|small|nano' } | Select-Object -First 1 }
        if (-not $pick) { $pick = $modelsResp.default }
        if (-not $pick) { $pick = $modelIds | Select-Object -First 1 }
        $pick
    }
    $smallCandidates = @($modelIds | Where-Object { $_ -match 'haiku|mini|flash|lite|small|nano' })
    Add-Result "models: discovered=$($modelIds.Count) default='$($modelsResp.default)' using='$useModel'"
    Add-Result "models: small-candidates=[$($smallCandidates -join ', ')]"


    # ----- TEST 1: simple streaming Turn -----
    $conv = Invoke-RestMethod "$base/api/conversations" -Method Post -Headers $headers -ContentType 'application/json' -Body (@{ title = 'Live test'; model = $useModel } | ConvertTo-Json)
    $t1 = Invoke-LiveTurn -ConversationId $conv.id -Prompt 'Reply with exactly one word: pong'
    if ($t1.Error) {
        Add-Result "TEST1 simple-turn: FAIL - error: $($t1.Error.message)"
    }
    else {
        $content = [string]$t1.Done.text
        $pass1 = $t1.HasStart -and ($t1.Deltas.Count -ge 1) -and ($content -match 'pong')
        Add-Result ("TEST1 simple-turn: {0} | start={1} deltas={2} streamed='{3}' final='{4}' tokens={5} costUSD={6}" -f `
            ($(if ($pass1) { 'PASS' } else { 'FAIL' })), $t1.HasStart, $t1.Deltas.Count, $t1.DeltaText.Trim(), $content.Trim(), $t1.Done.usage.totalTokens, $t1.Done.usage.costUSD)
    }

    # ----- TEST 2: multi-turn history -----
    $null = Invoke-LiveTurn -ConversationId $conv.id -Prompt 'Please remember this number for later: 4273. Just acknowledge briefly.'
    $t2 = Invoke-LiveTurn -ConversationId $conv.id -Prompt 'What number did I ask you to remember? Reply with only the number.'
    if ($t2.Error) {
        Add-Result "TEST2 history: FAIL - error: $($t2.Error.message)"
    }
    else {
        $answer2 = [string]$t2.Done.text
        $pass2 = $answer2 -match '4273'
        Add-Result ("TEST2 history: {0} | answer='{1}'" -f ($(if ($pass2) { 'PASS' } else { 'FAIL' })), $answer2.Trim())
    }

    # ----- TEST 3: tool-using Turn (read a file) -----
    $workspace = Join-Path $env:TEMP 'deskpilot_livetest_ws'
    New-Item -Path $workspace -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path $workspace 'note.txt') -Value 'The secret passphrase is blue-elephant-88.' -NoNewline
    Invoke-RestMethod "$base/api/settings" -Method Put -Headers $headers -ContentType 'application/json' -Body (@{ workspaceFolder = $workspace } | ConvertTo-Json) | Out-Null

    $conv2 = Invoke-RestMethod "$base/api/conversations" -Method Post -Headers $headers -ContentType 'application/json' -Body (@{ title = 'Tool test'; model = $useModel } | ConvertTo-Json)
    $t3 = Invoke-LiveTurn -ConversationId $conv2.id -Prompt 'Read the file note.txt in the current directory and tell me the secret passphrase it contains.'
    if ($t3.Error) {
        Add-Result "TEST3 tool-read: FAIL - error: $($t3.Error.message)"
    }
    else {
        $answer3 = [string]$t3.Done.text
        $filesRead = @($t3.Done.activity.filesRead)
        $pass3 = ($filesRead.Count -ge 1) -and ($answer3 -match 'blue-elephant-88')
        Add-Result ("TEST3 tool-read: {0} | filesRead=[{1}] secretFound={2} answer='{3}'" -f `
            ($(if ($pass3) { 'PASS' } else { 'FAIL' })), ($filesRead -join '; '), ($answer3 -match 'blue-elephant-88'), $answer3.Trim())
    }

    # ----- TEST 4: write to the Workspace Folder WITHOUT naming the path -----
    # Regression for the bug where the agent ignored the configured Workspace
    # Folder and wrote into the server's launch directory instead. The folder is
    # deliberately NOT pre-created, to also exercise auto-creation.
    $workspace2 = Join-Path $env:TEMP 'deskpilot_livetest_ws2'
    Remove-Item $workspace2 -Recurse -Force -ErrorAction SilentlyContinue
    # Register a Project for this folder (exercises the Projects path) and flip a
    # permission off so TEST7 can verify both survive the restart.
    $liveProjectId = 'p_live' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $putBody = @{ projects = @(@{ id = $liveProjectId; name = 'Live Test'; path = $workspace2 }); selectedProjectId = $liveProjectId; permissions = @{ terminal = $true } } | ConvertTo-Json -Depth 6
    $settingsAfterPut = Invoke-RestMethod "$base/api/settings" -Method Put -Headers $headers -ContentType 'application/json' -Body $putBody
    $derivedOk = [string]$settingsAfterPut.workspaceFolder -eq $workspace2
    Add-Result ("TEST4b project-derived-workspace: {0} | selected={1} derivedWorkspace={2}" -f ($(if ($derivedOk) { 'PASS' } else { 'FAIL' })), $settingsAfterPut.selectedProjectId, $settingsAfterPut.workspaceFolder)

    $conv3 = Invoke-RestMethod "$base/api/conversations" -Method Post -Headers $headers -ContentType 'application/json' -Body (@{ title = 'Workspace write'; model = $useModel } | ConvertTo-Json)
    $t4 = Invoke-LiveTurn -ConversationId $conv3.id -Prompt 'Create a new text file named report.txt containing exactly the text WORKSPACE_OK. Then tell me the full path of the file you created.'
    if ($t4.Error) {
        Add-Result "TEST4 workspace-write: FAIL - error: $($t4.Error.message)"
    }
    else {
        $answer4 = [string]$t4.Done.text
        $expectedFile = Join-Path $workspace2 'report.txt'
        $fileExists = Test-Path -LiteralPath $expectedFile
        $landedInWorkspace = $false
        if ($fileExists) {
            $content = (Get-Content -LiteralPath $expectedFile -Raw).Trim()
            $landedInWorkspace = $content -match 'WORKSPACE_OK'
        }
        $filesWritten = @($t4.Done.activity.filesWritten)
        $reportedInsideWs = $answer4 -match [regex]::Escape($workspace2)
        $pass4 = $fileExists -and $landedInWorkspace
        Add-Result ("TEST4 workspace-write: {0} | fileInWorkspace={1} folderAutoCreated={2} filesWritten=[{3}] reportedPathInWs={4}" -f `
            ($(if ($pass4) { 'PASS' } else { 'FAIL' })), $fileExists, ($fileExists), ($filesWritten -join '; '), $reportedInsideWs)
        Add-Result ("TEST4 answer: '{0}'" -f $answer4.Trim())
    }

    # ----- Usage accrual (session + lifetime) -----
    $usage = Invoke-RestMethod "$base/api/usage" -Headers $headers
    Add-Result ("usage: session.turns={0} session.credits={1} lifetime.credits={2} lifetime.since={3}" -f `
            $usage.session.turns, $usage.session.credits, $usage.lifetime.credits, $usage.lifetime.sinceUtc)
    $convCountBefore = @((Invoke-RestMethod "$base/api/conversations" -Headers $headers).conversations).Count
    $lifetimeBefore = [double]$usage.lifetime.credits

    # ----- TEST 8: upload + agent reads attached file -----
    $marker = 'UPLOAD_MARKER_' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $savedAs = 'attached.txt'
    $uploadResp = $null
    try {
        # Build the multipart body by hand and POST it over a raw socket. The
        # built-in receiver speaks Content-Length HTTP/1.1; Invoke-RestMethod
        # -Form uses chunked transfer encoding, which the receiver does not decode.
        $boundary = '----DeskPilotLive'
        $enc = [System.Text.Encoding]::UTF8
        $payload = $enc.GetBytes("The secret marker is $marker.")
        $ms = [System.IO.MemoryStream]::new()
        $head = "--$boundary`r`nContent-Disposition: form-data; name=`"files`"; filename=`"$savedAs`"`r`nContent-Type: text/plain`r`n`r`n"
        $hb = $enc.GetBytes($head); $ms.Write($hb, 0, $hb.Length)
        $ms.Write($payload, 0, $payload.Length)
        $tail = $enc.GetBytes("`r`n--$boundary--`r`n"); $ms.Write($tail, 0, $tail.Length)
        $bodyBytes = $ms.ToArray()
        $reqHead = "POST /api/uploads HTTP/1.1`r`nHost: 127.0.0.1:$Port`r`nX-DeskPilot-Token: $token`r`nContent-Type: multipart/form-data; boundary=$boundary`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
        $tcp = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $Port)
        $ns = $tcp.GetStream()
        $rh = $enc.GetBytes($reqHead); $ns.Write($rh, 0, $rh.Length); $ns.Write($bodyBytes, 0, $bodyBytes.Length); $ns.Flush()
        $sr = [System.IO.StreamReader]::new($ns)
        $rawResp = $sr.ReadToEnd()
        $tcp.Close()
        $jsonPart = $rawResp.Substring($rawResp.IndexOf("`r`n`r`n") + 4)
        $uploadResp = $jsonPart | ConvertFrom-Json
    }
    catch {
        Add-Result "TEST8 upload: FAIL - upload error: $($_.Exception.Message)"
    }
    if ($uploadResp -and $uploadResp.files) {
        $savedAs = ($uploadResp.files | Select-Object -First 1).savedAs
        $savedPath = Join-Path $workspace2 $savedAs
        $landed = Test-Path -LiteralPath $savedPath
        $conv4 = Invoke-RestMethod "$base/api/conversations" -Method Post -Headers $headers -ContentType 'application/json' -Body (@{ title = 'Upload read'; model = $useModel } | ConvertTo-Json)
        $t8 = Invoke-LiveTurn -ConversationId $conv4.id -Prompt ("I attached one file in the Workspace Folder named '$savedAs'. Open it with your file tool and tell me the secret marker it contains.")
        $ans8 = if ($t8.Done) { [string]$t8.Done.text } else { '' }
        $markerSeen = $ans8 -match [regex]::Escape($marker)
        $pass8 = $landed -and $markerSeen
        Add-Result ("TEST8 upload: {0} | savedAs={1} fileOnDisk={2} markerEcho={3}" -f ($(if ($pass8) { 'PASS' } else { 'FAIL' })), $savedAs, $landed, $markerSeen)
        Add-Result ("TEST8 answer: '{0}'" -f $ans8.Trim())
    }

    # ----- TEST 5: persistence across a restart + lifetime reset -----
    # Stop the server and start a fresh one against the SAME data directory.
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $port2 = $Port + 1
    $serverOut2 = Join-Path $outputDir 'live-test-server2.out'
    Remove-Item $serverOut2 -ErrorAction SilentlyContinue
    $restartArgs = @('-NoProfile', '-File', (Join-Path $repoRoot 'Start-DeskPilot.ps1'), '-Port', "$port2", '-NoBrowser', '-DataDir', $dataDir)
    if ($EngineModulePath) { $restartArgs += @('-EngineModulePath', $EngineModulePath) }
    $server2 = Start-Process pwsh -ArgumentList $restartArgs -RedirectStandardOutput $serverOut2 -RedirectStandardError $serverErr -WindowStyle Hidden -PassThru
    $token2 = $null
    for ($i = 0; $i -lt 40 -and -not $token2; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $serverOut2) { if ((Get-Content $serverOut2 -Raw) -match '\?t=([0-9a-f]{32})') { $token2 = $Matches[1] } }
    }
    $base2 = "http://127.0.0.1:$port2"
    $headers2 = @{ 'X-DeskPilot-Token' = $token2 }
    if (-not $token2) {
        Add-Result 'TEST5 persistence: FAIL - restarted server did not start.'
    }
    else {
        $convCountAfter = @((Invoke-RestMethod "$base2/api/conversations" -Headers $headers2).conversations).Count
        $usage2 = Invoke-RestMethod "$base2/api/usage" -Headers $headers2
        $convPersisted = $convCountAfter -ge $convCountBefore -and $convCountBefore -gt 0
        $sessionReset = [int]$usage2.session.turns -eq 0
        $lifetimeKept = [double]$usage2.lifetime.credits -ge $lifetimeBefore -and $lifetimeBefore -gt 0
        $pass5 = $convPersisted -and $sessionReset -and $lifetimeKept
        Add-Result ("TEST5 persistence: {0} | convBefore={1} convAfter={2} sessionTurnsAfter={3} lifetimeBefore={4} lifetimeAfter={5}" -f `
            ($(if ($pass5) { 'PASS' } else { 'FAIL' })), $convCountBefore, $convCountAfter, $usage2.session.turns, $lifetimeBefore, $usage2.lifetime.credits)

        # ----- TEST 6: manual lifetime reset -----
        $afterReset = Invoke-RestMethod "$base2/api/usage/reset" -Method Post -Headers $headers2 -ContentType 'application/json' -Body (@{ scope = 'lifetime' } | ConvertTo-Json)
        $pass6 = [double]$afterReset.lifetime.credits -eq 0
        Add-Result ("TEST6 lifetime-reset: {0} | lifetimeCreditsAfterReset={1}" -f ($(if ($pass6) { 'PASS' } else { 'FAIL' })), $afterReset.lifetime.credits)

        # ----- TEST 7: settings + Project persisted across the restart -----
        $settings2 = Invoke-RestMethod "$base2/api/settings" -Headers $headers2
        $wsKept = [string]$settings2.workspaceFolder -eq $workspace2
        $permKept = [bool]$settings2.permissions.terminal -eq $true
        $projectKept = ([string]$settings2.selectedProjectId -eq $liveProjectId) -and (@($settings2.projects | Where-Object { $_.id -eq $liveProjectId }).Count -eq 1)
        $pass7 = $wsKept -and $permKept -and $projectKept
        Add-Result ("TEST7 settings-persist: {0} | workspaceKept={1} terminalPermissionKept={2} projectKept={3}" -f ($(if ($pass7) { 'PASS' } else { 'FAIL' })), $wsKept, $permKept, $projectKept)
    }
    if ($server2) { Stop-Process -Id $server2.Id -Force -ErrorAction SilentlyContinue }
}
catch {
    Add-Result "UNEXPECTED ERROR: $($_.Exception.Message)"
    Add-Result $_.ScriptStackTrace
}
finally {
    if ($client) { $client.Dispose() }
    if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    if ($server2) { Stop-Process -Id $server2.Id -Force -ErrorAction SilentlyContinue }
    if ($workspace) { Remove-Item $workspace -Recurse -Force -ErrorAction SilentlyContinue }
    if ($workspace2) { Remove-Item $workspace2 -Recurse -Force -ErrorAction SilentlyContinue }
    if ($dataDir) { Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue }
    $errText = if (Test-Path $serverErr) { Get-Content $serverErr -Raw } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($errText)) { Add-Result "--- server stderr ---`n$($errText.Trim())" }
    Add-Result '=== DONE ==='
    $results -join "`n" | Out-File -FilePath $resultsPath -Encoding utf8
}
