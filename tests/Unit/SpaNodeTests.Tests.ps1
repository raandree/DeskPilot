#requires -Version 7.0

# The SPA's behavior tests are Node test files (tests/Unit/*.test.mjs). Pester
# discovers only *.Tests.ps1 and no build task runs node, so before this file a
# failing SPA test failed no gate at all. It runs them all in one node --test
# process, so the Sampler test task and CI hold them to the same bar.

Describe 'SPA tests under node --test' -Tag 'Unit' {
    BeforeAll {
        $script:spaTestFiles = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.test.mjs' -File | Sort-Object -Property Name)
        $script:node = Get-Command -Name 'node' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    It 'finds the SPA test files' {
        $script:spaTestFiles.Count | Should -BeGreaterThan 0
    }

    It 'passes every SPA test file' {
        if (-not $script:node) {
            # A workstation without Node may skip them; a CI run must not pass that way.
            if ($env:CI -or $env:TF_BUILD) { throw 'Node.js is required to run the SPA tests, and it is not on PATH.' }
            Set-ItResult -Skipped -Because 'Node.js is not on PATH'
            return
        }

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new($script:node.Source)
        # TAP keeps the summary ASCII, so it parses the same on every platform.
        $startInfo.ArgumentList.Add('--test-reporter=tap')
        $startInfo.ArgumentList.Add('--test')
        foreach ($file in $script:spaTestFiles) { $startInfo.ArgumentList.Add($file.FullName) }
        $startInfo.WorkingDirectory = $PSScriptRoot
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $process = [System.Diagnostics.Process]::Start($startInfo)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(180000)) {
                $process.Kill($true)
                throw 'node --test did not finish within three minutes.'
            }
            $process.WaitForExit()
            $exitCode = $process.ExitCode
            $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        }
        finally {
            $process.Dispose()
        }

        $report = if ($output.Length -gt 6000) { $output.Substring($output.Length - 6000) } else { $output }
        $testCount = if ($output -match '(?m)^# tests (\d+)') { [int]$Matches[1] } else { 0 }
        $failCount = if ($output -match '(?m)^# fail (\d+)') { [int]$Matches[1] } else { -1 }

        $testCount | Should -BeGreaterThan 0 -Because "node --test must run tests:`n$report"
        $failCount | Should -Be 0 -Because "node --test reported:`n$report"
        $exitCode | Should -Be 0 -Because "node --test reported:`n$report"
    }
}
