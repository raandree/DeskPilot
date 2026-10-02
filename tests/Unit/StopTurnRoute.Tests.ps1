#requires -Version 7.0

# Regression coverage for POST /api/conversations/{id}/stop (route 'stopTurn'),
# recorded as an open Minor finding on 2026-09-07: Stop must release every place
# a running Turn can be parked, and an active child run must be stopped through
# its own controller without touching the parent's bridges.

BeforeAll {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'source' 'Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }

    function script:New-StopProbe {
        param([string]$Name)
        $probe = [pscustomobject]@{ Name = $Name; Calls = 0 }
        $probe | Add-Member -MemberType ScriptMethod -Name Cancel -Value { $this.Calls++ }
        $probe | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.Calls++ }
        $probe
    }

    function script:Invoke-StopRoute {
        $stream = [System.IO.MemoryStream]::new()
        try {
            Invoke-DpRouteHandler -Name stopTurn -RouteParams @{ id = 'c_0123456789' } -Stream $stream
            [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
        }
        finally { $stream.Dispose() }
    }
}

Describe 'stopTurn route' -Tag 'Unit' {
    BeforeEach {
        $script:prior = Get-Variable -Name DeskPilot -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        $script:terminal = New-StopProbe -Name 'terminal'
        $script:userPrompts = New-StopProbe -Name 'user-prompts'
        $script:approvals = New-StopProbe -Name 'approvals'
        $script:browserState = @{ Session = 'live' }
        $script:DeskPilot = @{
            TurnRunning     = $true
            CancelRequested = $false
            Settings        = Get-DpDefaultSettings
            Engine          = @{
                TerminalSession  = $script:terminal
                UserPromptBridge = $script:userPrompts
                ApprovalBridge   = $script:approvals
                BrowserState     = $script:browserState
            }
        }
        Mock Close-DpBrowserSession {}
    }

    AfterEach { $script:DeskPilot = $script:prior }

    It 'releases every place a running Turn can be parked and answers 202' {
        $response = Invoke-StopRoute

        $response | Should -Match '^HTTP/1.1 202'
        $response | Should -Match '"stopping":\s*true'
        $script:DeskPilot.CancelRequested | Should -BeTrue
        $script:terminal.Calls | Should -Be 1
        $script:userPrompts.Calls | Should -Be 1
        $script:approvals.Calls | Should -Be 1 -Because 'a Turn parked on an approval never unwinds otherwise'
        Should -Invoke Close-DpBrowserSession -Times 1 -Exactly -ParameterFilter { [object]::ReferenceEquals($State, $script:browserState) }
    }

    It 'still stops the Turn when the browser cannot be closed' {
        Mock Close-DpBrowserSession { throw 'browser already gone' }

        $response = Invoke-StopRoute

        $response | Should -Match '^HTTP/1.1 202'
        $script:DeskPilot.CancelRequested | Should -BeTrue
        $script:approvals.Calls | Should -Be 1
    }

    It 'stops an Engine with nothing parked' {
        $script:DeskPilot.Engine = @{ TerminalSession = $null; UserPromptBridge = $null; ApprovalBridge = $null; BrowserState = $null }

        $response = Invoke-StopRoute

        $response | Should -Match '^HTTP/1.1 202'
        $script:DeskPilot.CancelRequested | Should -BeTrue
    }

    It 'stops an active child run through its own controller, leaving the parent''s bridges alone' {
        $controller = New-StopProbe -Name 'child'
        $script:DeskPilot.Child = @{ Controller = $controller }

        $response = Invoke-StopRoute

        $response | Should -Match '^HTTP/1.1 202'
        $script:DeskPilot.CancelRequested | Should -BeTrue
        $controller.Calls | Should -Be 1
        $script:terminal.Calls | Should -Be 0
        $script:userPrompts.Calls | Should -Be 0
        $script:approvals.Calls | Should -Be 0
        Should -Invoke Close-DpBrowserSession -Times 0
    }
}
