#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -LiteralPath $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'Extended Tool approval contract' -Tag 'Unit' {
    BeforeEach {
        $context = @{
            conversationId = 'c_0123456789'; turnId = 'm_abcdef0123'
            project = 'Fixture'; workingDirectory = [string]$TestDrive
            permissions = @{ file = $true; mcp = $true; userTools = $true; terminal = $false }
            terminalApprovalActive = $false
        }
        $bridge = [pscustomobject]@{
            Enabled = $true; Cancelled = $false; Captured = ''; Requests = 0
            Reply = @{ decision = 'approve'; scope = 'once' }
        }
        $bridge | Add-Member -MemberType ScriptMethod -Name CaptureQuestion -Value {
            param($text)
            $this.Captured = $text
        }
        $bridge | Add-Member -MemberType ScriptMethod -Name RequestAnswer -Value {
            param($seconds)
            $this.Requests++
            $this.Reply | ConvertTo-Json -Compress
        }
        $call = @{
            CallId = 'call-1'; Name = 'write_file'; Class = 'FileWrite'
            ArgumentsJson = '{"path":"result.txt","content":"PRIVATE-CONTENT"}'
            Fingerprint = ('a' * 64); Policy = @{ Allowed = $true }
            McpServer = $null; McpTool = $null
        }
    }

    It 'preserves Terminal-only coverage by default and accepts explicit broader coverage' {
        $settings = Get-DpDefaultSettings
        $settings.approvalCoverage | Should -BeExactly 'terminal'
        $updated = Merge-DpSettings -Current $settings -Patch @{ approvalCoverage = 'mutating-tools' }
        $updated.approvalCoverage | Should -BeExactly 'mutating-tools'
        { Merge-DpSettings -Current $settings -Patch @{ approvalCoverage = 'everything-forever' } } | Should -Throw
    }

    It 'asks before allowing a File write and exposes no content in the card' {
        [bool](Get-Command Invoke-DpToolCallApproval -ErrorAction SilentlyContinue) | Should -BeTrue
        $result = Invoke-DpToolCallApproval -Call $call -Context $context -Bridge $bridge
        $result.Allowed | Should -BeTrue
        $bridge.Requests | Should -Be 1
        $request = $bridge.Captured | ConvertFrom-Json
        $request.class | Should -BeExactly 'FileWrite'
        $request.allowedScopes | Should -Be @('once')
        $request.summary.filePath | Should -Match 'result\.txt$'
        $bridge.Captured | Should -Not -Match 'PRIVATE-CONTENT'
    }

    It 'binds the answer to the full arguments rather than just the displayed destination' {
        [bool](Get-Command Invoke-DpToolCallApproval -ErrorAction SilentlyContinue) | Should -BeTrue
        $null = Invoke-DpToolCallApproval -Call $call -Context $context -Bridge $bridge
        $first = ($bridge.Captured | ConvertFrom-Json).fingerprint
        $call.ArgumentsJson = '{"path":"result.txt","content":"DIFFERENT-CONTENT"}'
        $null = Invoke-DpToolCallApproval -Call $call -Context $context -Bridge $bridge
        ($bridge.Captured | ConvertFrom-Json).fingerprint | Should -Not -Be $first
    }

    It 'never treats an MCP read-only annotation as permission to skip the gate' {
        [bool](Get-Command Invoke-DpToolCallApproval -ErrorAction SilentlyContinue) | Should -BeTrue
        $call.Name = 'mcp_fixture_list'
        $call.Class = 'Mcp'
        $call.McpServer = 'fixture'
        $call.McpTool = 'list'
        $call.McpAnnotations = @{ readOnlyHint = $true }
        $call.ArgumentsJson = '{}'
        $bridge.Reply.decision = 'deny'
        (Invoke-DpToolCallApproval -Call $call -Context $context -Bridge $bridge).Allowed | Should -BeFalse
        $bridge.Requests | Should -Be 1
        ($bridge.Captured | ConvertFrom-Json).summary.action | Should -Match 'fixture.*list'
    }

    It 'refuses a revoked Permission without asking or granting anything' {
        [bool](Get-Command Invoke-DpToolCallApproval -ErrorAction SilentlyContinue) | Should -BeTrue
        $context.permissions.file = $false
        (Invoke-DpToolCallApproval -Call $call -Context $context -Bridge $bridge).Allowed | Should -BeFalse
        $bridge.Requests | Should -Be 0
    }

    It 'requires both User Tools and File Permission for an owned edit Tool' {
        $call.Name = 'replace_in_file'
        $call.Class = 'UserTool'
        $context.permissions.userTools = $false
        (Invoke-DpToolCallApproval -Call $call -Context $context -Bridge $bridge).Allowed | Should -BeFalse
        $bridge.Requests | Should -Be 0
    }

    It 'refuses an Engine policy denial or a forged string boolean' -ForEach @($false, 'true') {
        [bool](Get-Command Invoke-DpToolCallApproval -ErrorAction SilentlyContinue) | Should -BeTrue
        $call.Policy.Allowed = $_
        (Invoke-DpToolCallApproval -Call $call -Context $context -Bridge $bridge).Allowed | Should -BeFalse
        $bridge.Requests | Should -Be 0
    }

    It 'does not accept a Turn-wide grant for File writes' {
        [bool](Get-Command Invoke-DpToolCallApproval -ErrorAction SilentlyContinue) | Should -BeTrue
        $bridge.Reply.scope = 'turn'
        (Invoke-DpToolCallApproval -Call $call -Context $context -Bridge $bridge).Allowed | Should -BeFalse
    }

    It 'refuses malformed or oversized argument data before asking' -ForEach @('[1,2]', '{broken', ('x' * 262145)) {
        [bool](Get-Command Invoke-DpToolCallApproval -ErrorAction SilentlyContinue) | Should -BeTrue
        $call.ArgumentsJson = $_
        (Invoke-DpToolCallApproval -Call $call -Context $context -Bridge $bridge).Allowed | Should -BeFalse
        $bridge.Requests | Should -Be 0
    }

    It 'refuses cancellation before approval can become authority' {
        [bool](Get-Command Invoke-DpToolCallApproval -ErrorAction SilentlyContinue) | Should -BeTrue
        $bridge.Cancelled = $true
        (Invoke-DpToolCallApproval -Call $call -Context $context -Bridge $bridge).Allowed | Should -BeFalse
        $bridge.Requests | Should -Be 0
    }
}

Describe 'Engine pre-dispatch approval integration' -Tag 'Unit' {
    BeforeAll {
        if (-not ('DeskPilot.Tests.ApprovalContractBridge' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
namespace DeskPilot.Tests {
    public sealed class ApprovalContractBridge {
        public bool Enabled = true;
        public bool Cancelled;
        public string Captured;
        public string Reply = "{\"decision\":\"approve\",\"scope\":\"once\"}";
        public List<string> Order = new List<string>();
        public void CaptureQuestion(string text) { Captured = text; }
        public string RequestAnswer(int seconds) { Order.Add("approval"); return Reply; }
    }
}
'@
        }
    }
    BeforeEach {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $bridge = [DeskPilot.Tests.ApprovalContractBridge]::new()
        $context = @{
            conversationId = 'c_0123456789'; turnId = 'm_abcdef0123'
            project = 'Fixture'; workingDirectory = [string]$TestDrive
            permissions = @{ file = $true; mcp = $true; userTools = $true; terminal = $false }
        }
    }
    AfterEach { $runspace.Close(); $runspace.Dispose() }

    It 'refuses an old Engine before any invocation rather than falling back' {
        [bool](Get-Command Initialize-DpToolCallApproval -ErrorAction SilentlyContinue) | Should -BeTrue
        $setup = [powershell]::Create(); $setup.Runspace = $runspace
        $null = $setup.AddScript('function global:Invoke-Shp { param($Prompt) throw "must never be invoked" }')
        $setup.Invoke() | Out-Null; $setup.Dispose()
        { Initialize-DpToolCallApproval -Runspace $runspace -Context $context -Bridge $bridge } |
            Should -Throw -ExpectedMessage '*ToolCallApprover*'
        $bridge.Order.Count | Should -Be 0
    }

    It 'passes a Runspace-owned callback to a producer which acts only after approval' {
        [bool](Get-Command Initialize-DpToolCallApproval -ErrorAction SilentlyContinue) | Should -BeTrue
        $setup = [powershell]::Create(); $setup.Runspace = $runspace
        $null = $setup.AddScript(@'
function global:Invoke-Shp {
    param([scriptblock]$ToolCallApprover)
    $decision = & $ToolCallApprover @{
        Name = 'write_file'; Class = 'FileWrite'; CallId = 'fixture-call'
        ArgumentsJson = '{"path":"result.txt","content":"PRIVATE"}'
        Fingerprint = ('a' * 64); Policy = @{ Allowed = $true }
    }
    if ($decision.Allowed) { $global:FixtureBridge.Order.Add('effect'); 'performed' } else { 'denied' }
}
'@)
        $setup.Invoke() | Out-Null; $setup.Dispose()
        $runspace.SessionStateProxy.SetVariable('FixtureBridge', $bridge)
        $callback = Initialize-DpToolCallApproval -Runspace $runspace -Context $context -Bridge $bridge
        $callback | Should -BeOfType ([scriptblock])
        $invoke = [powershell]::Create(); $invoke.Runspace = $runspace
        try {
            $null = $invoke.AddCommand('Invoke-Shp').AddParameter('ToolCallApprover', $callback)
            @($invoke.Invoke()) | Should -Be @('performed')
            $invoke.HadErrors | Should -BeFalse
        } finally { $invoke.Dispose() }
        @($bridge.Order) | Should -Be @('approval', 'effect')
        $bridge.Captured | Should -Not -Match 'PRIVATE'
    }
}
