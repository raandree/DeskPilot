BeforeAll {
    $root = Join-Path $PSScriptRoot '../../source/child'
    $script:bridgeAssembly = Join-Path $TestDrive 'Bridge.dll'
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $root 'Build-DpChildRuntime.ps1'), '-SourceDirectory', $root, '-OutputAssembly', $script:bridgeAssembly)) { $start.ArgumentList.Add($argument) }
    $compiler = [Diagnostics.Process]::Start($start)
    try {
        if (-not $compiler.WaitForExit(60000)) { $compiler.Kill($true); throw 'Bridge test compilation timed out.' }
        if ($compiler.ExitCode -ne 0) { throw 'Bridge test compilation failed.' }
    } finally { $compiler.Dispose() }
    if (-not ('DeskPilot.Child.EngineBridge' -as [type])) {
        $null = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($script:bridgeAssembly))
    }
}

Describe 'Credentialless Engine bridge' -Skip:(-not $IsWindows) {
    It 'exchanges correlated requests without exposing control input as a Tool' {
        ('DeskPilot.Child.EngineBridge' -as [type]) | Should -Not -BeNullOrEmpty
        $environment = [System.Collections.Generic.Dictionary[string,string]]::new()
        $environment['SystemRoot'] = $env:SystemRoot
        $environment['TEMP'] = $TestDrive
        $environment['TMP'] = $TestDrive
        $command = "Add-Type -Path '$($script:bridgeAssembly.Replace("'","''"))'; `$bridge = [DeskPilot.Child.EngineBridge]::Start(5,262144); `$null = `$bridge.Configuration; `$reply = `$bridge.Invoke('provider','{`"sample`":`"bounded`"}'); `$bridge.Complete(`$reply); `$bridge.Dispose()"
        $process = $null
        $channel = $null
        try {
            $process = [DeskPilot.Child.OwnedProcess]::new((Join-Path $PSHOME 'pwsh.exe'), @('-NoProfile','-NonInteractive','-Command',$command), $TestDrive, $environment, 268435456, 0.25, 8)
            $key = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
            $channel = [DeskPilot.Child.MessageChannel]::new($process.Output,$process.Input,$key,$true,262144)
            $process.Resume()
            $process.Input.Write($key)
            $process.Input.Flush()
            $channel.Send('{"type":"configure","configuration":{"runId":"test"}}')
            ($channel.ReceiveAsync([Threading.CancellationToken]::None).GetAwaiter().GetResult() | ConvertFrom-Json).type | Should -BeExactly 'ready'
            $messageTask = $channel.ReceiveAsync([Threading.CancellationToken]::None)
            $messageTask.Wait(10000) | Should -BeTrue
            $request = $messageTask.Result | ConvertFrom-Json
            $request.type | Should -BeExactly 'provider'
            $request.payload.sample | Should -BeExactly 'bounded'
            $channel.Send((@{ type = 'reply'; id = $request.id; payload = @{ ok = $true } } | ConvertTo-Json -Compress))
            $final = $channel.ReceiveAsync([Threading.CancellationToken]::None)
            $final.Wait(10000) | Should -BeTrue
            ($final.Result | ConvertFrom-Json).type | Should -BeExactly 'complete'
            $process.WaitForExit(5000) | Should -BeTrue
        } finally { if ($channel) { $channel.Dispose() }; if ($process) { $process.Dispose() } }
    }

    It 'exits after lease expiry while its PowerShell operation is busy' {
        ('DeskPilot.Child.EngineBridge' -as [type]) | Should -Not -BeNullOrEmpty
        $environment = [System.Collections.Generic.Dictionary[string,string]]::new()
        $environment['SystemRoot'] = $env:SystemRoot
        $environment['TEMP'] = $TestDrive
        $environment['TMP'] = $TestDrive
        $command = "Add-Type -Path '$($script:bridgeAssembly.Replace("'","''"))'; `$bridge = [DeskPilot.Child.EngineBridge]::Start(2,262144); `$null = `$bridge.Configuration; [Threading.ManualResetEvent]::new(`$false).WaitOne()"
        $process = $null
        $channel = $null
        try {
            $process = [DeskPilot.Child.OwnedProcess]::new((Join-Path $PSHOME 'pwsh.exe'), @('-NoProfile','-NonInteractive','-Command',$command), $TestDrive, $environment, 268435456, 0.25, 8)
            $key = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
            $channel = [DeskPilot.Child.MessageChannel]::new($process.Output,$process.Input,$key,$true,262144)
            $process.Resume()
            $process.Input.Write($key)
            $process.Input.Flush()
            $channel.Send('{"type":"configure","configuration":{"runId":"test"}}')
            $process.WaitForExit(10000) | Should -BeTrue
            $process.ExitCode | Should -Be 125
        } finally { if ($channel) { $channel.Dispose() }; if ($process) { $process.Dispose() } }
    }
}
