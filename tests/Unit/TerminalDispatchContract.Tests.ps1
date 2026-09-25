#requires -Version 7.0

BeforeAll {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'source' 'Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
    function New-DispatchFixture {
        param([bool]$Enforce, [bool]$MentionMarker)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $module = Join-Path $root 'ShellPilot.psm1'
        $template = @'
function Invoke-Shp {
    [CmdletBinding()]
    param(
        $Prompt, $Model, $History, $MaxContextWindowTokens, $MaxToolIterations, $MaxOutputTokens,
        [scriptblock]$RequestTransport, [scriptblock]$ExecutionContract,
        [switch]$DisableTerminal, [switch]$DisableStreaming, [switch]$DisableFileAccess,
        [switch]$DisableBrowsing, [switch]$DisableUserPrompts, [switch]$DisableUserTools,
        [switch]$DisableMcp, [switch]$DisableTodoList, [switch]$NoAutomaticRetry, [bool]$Confirm
    )
    __MARKER__
    $first = & $RequestTransport @{ Model = 'fixture' }
    $denied = @()
    if ($DisableTerminal -and __ENFORCE__) { $denied = @(@{ Name = 'run_command' }) }
    else { $null = & $ExecutionContract @{ Kind = 'Terminal'; Tool = 'run_command' } }
    $null = & $RequestTransport @{ Model = 'fixture' }
    [pscustomobject]@{ Content = 'fixture'; ToolCallsDenied = $denied; ToolCalls = @($first.ToolCalls) }
}
Export-ModuleMember -Function Invoke-Shp
'@
        $enforceText = if ($Enforce) { '$true' } else { '$false' }
        $markerText = if ($MentionMarker) { '# offeredBuiltInTool: only a comment, never enforcement' } else { '# No historical marker' }
        [IO.File]::WriteAllText($module, $template.Replace('__ENFORCE__', $enforceText).Replace('__MARKER__', $markerText))
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $shell = [powershell]::Create(); $shell.Runspace = $runspace
        try {
            $null = $shell.AddCommand('Import-Module').AddParameter('Name', $module).AddParameter('ErrorAction', 'Stop')
            $shell.Invoke() | Out-Null
            if ($shell.HadErrors) { throw $shell.Streams.Error[0] }
        } finally { $shell.Dispose() }
        @{ Runspace = $runspace; Path = $module }
    }
}

Describe 'Disabled Terminal behavioral contract' {
    It 'accepts an enforcing Engine without an internal source marker' {
        $fixture = New-DispatchFixture -Enforce $true -MentionMarker $false
        try { Test-DpTerminalDispatch -Runspace $fixture.Runspace | Should -BeTrue }
        finally { $fixture.Runspace.Dispose() }
    }

    It 'refuses a non-enforcing Engine even if its source contains the old marker' {
        $fixture = New-DispatchFixture -Enforce $false -MentionMarker $true
        try { Test-DpTerminalDispatch -Runspace $fixture.Runspace | Should -BeFalse }
        finally { $fixture.Runspace.Dispose() }
    }

    It 'requires a positive execution control as well as disabled refusal' {
        $fixture = New-DispatchFixture -Enforce $true -MentionMarker $false
        try {
            $text = [IO.File]::ReadAllText($fixture.Path).Replace('else { $null = & $ExecutionContract', 'elseif ($false) { $null = & $ExecutionContract')
            [IO.File]::WriteAllText($fixture.Path, $text)
            $shell = [powershell]::Create(); $shell.Runspace = $fixture.Runspace
            try {
                $null = $shell.AddCommand('Import-Module').AddParameter('Name', $fixture.Path).AddParameter('Force', $true)
                $shell.Invoke() | Out-Null
            } finally { $shell.Dispose() }
            Test-DpTerminalDispatch -Runspace $fixture.Runspace | Should -BeFalse
        } finally { $fixture.Runspace.Dispose() }
    }

    It 'leaves the original Engine Runspace free of probe executors and state' {
        $fixture = New-DispatchFixture -Enforce $true -MentionMarker $false
        try {
            Test-DpTerminalDispatch -Runspace $fixture.Runspace | Should -BeTrue
            $fixture.Runspace.SessionStateProxy.GetVariable('DpDispatchProbeCalls') | Should -BeNullOrEmpty
            Test-DpTerminalDispatch -Runspace $fixture.Runspace | Should -BeTrue
        } finally { $fixture.Runspace.Dispose() }
    }
}
