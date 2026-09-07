BeforeAll {
    $sourcePath = Join-Path $PSScriptRoot '../../source/child/OwnedProcess.cs'
    if (Test-Path -LiteralPath $sourcePath) { Add-Type -Path $sourcePath -ErrorAction Stop }
}

Describe 'Child trusted process ownership' -Skip:(-not $IsWindows) {
    It 'shares one job budget without stopping its owner when a sibling exits' {
        $environment = [System.Collections.Generic.Dictionary[string,string]]::new()
        $environment['SystemRoot'] = $env:SystemRoot
        $environment['TEMP'] = $TestDrive
        $environment['TMP'] = $TestDrive
        $owner = $null
        $sibling = $null
        try {
            $owner = [DeskPilot.Child.OwnedProcess]::new((Join-Path $PSHOME 'pwsh.exe'), @('-NoProfile','-NonInteractive','-Command','[Console]::ReadLine() | Out-Null'), $TestDrive, $environment, 536870912, 0.5, 8)
            $owner.Resume()
            $sibling = $owner.CreateSibling((Join-Path $PSHOME 'pwsh.exe'), @('-NoProfile','-NonInteractive','-Command','[Console]::WriteLine("sibling")'), $TestDrive, $environment)
            $sibling.Resumed | Should -BeFalse
            $sibling.IsInOwnedJob | Should -BeTrue
            $sibling.Resume()
            $sibling.WaitForExit(10000) | Should -BeTrue
            $sibling.Dispose()
            $sibling = $null
            $owner.HasExited | Should -BeFalse
            $owner.Stop()
            $owner.HasExited | Should -BeTrue
        } finally { if ($sibling) { $sibling.Dispose() }; if ($owner) { $owner.Dispose() } }
    }

    It 'applies the Job Object before resume and uses an explicit environment' {
        $environment = [System.Collections.Generic.Dictionary[string,string]]::new()
        $environment['SystemRoot'] = $env:SystemRoot
        $environment['TEMP'] = $TestDrive
        $environment['TMP'] = $TestDrive
        $environment['DP_ALLOWED'] = 'selected-value'
        $before = $env:DP_PRIVATE_CANARY
        $env:DP_PRIVATE_CANARY = 'private-value'
        $process = $null
        try {
            $process = [DeskPilot.Child.OwnedProcess]::new((Join-Path $PSHOME 'pwsh.exe'), @('-NoProfile','-NonInteractive','-Command','[Console]::WriteLine($env:DP_ALLOWED + "|" + $env:DP_PRIVATE_CANARY); [Console]::ReadLine() | Out-Null'), $TestDrive, $environment, 268435456, 0.25, 8)
            $process.Resumed | Should -BeFalse
            $process.IsInOwnedJob | Should -BeTrue
            $process.MemoryLimit | Should -Be 268435456
            $process.ActiveProcessLimit | Should -Be 8
            $reader = [IO.StreamReader]::new($process.Output)
            $process.Resume()
            $line = $reader.ReadLineAsync()
            $line.Wait(15000) | Should -BeTrue
            $line.Result | Should -BeExactly 'selected-value|'
            $process.Stop()
            $process.HasExited | Should -BeTrue
        } finally {
            if ($process) { $process.Dispose() }
            $env:DP_PRIVATE_CANARY = $before
        }
    }

    It 'terminates all descendants through the owned job' {
        $environment = [System.Collections.Generic.Dictionary[string,string]]::new()
        $environment['SystemRoot'] = $env:SystemRoot
        $environment['TEMP'] = $TestDrive
        $environment['TMP'] = $TestDrive
        $command = '$child = Start-Process -FilePath (Join-Path $PSHOME "pwsh.exe") -ArgumentList @("-NoProfile", "-NonInteractive", "-Command", "[Threading.ManualResetEvent]::new(`$false).WaitOne()") -PassThru; [Console]::WriteLine($child.Id); [Console]::ReadLine() | Out-Null'
        $process = $null
        try {
            $process = [DeskPilot.Child.OwnedProcess]::new((Join-Path $PSHOME 'pwsh.exe'), @('-NoProfile','-NonInteractive','-Command',$command), $TestDrive, $environment, 536870912, 0.5, 8)
            $reader = [IO.StreamReader]::new($process.Output)
            $process.Resume()
            $line = $reader.ReadLineAsync()
            $line.Wait(15000) | Should -BeTrue
            $descendant = Get-Process -Id ([int]$line.Result) -ErrorAction Stop
            $process.Stop()
            $descendant.WaitForExit(5000) | Should -BeTrue
            $process.HasExited | Should -BeTrue
        } finally { if ($process) { $process.Dispose() } }
    }
}
