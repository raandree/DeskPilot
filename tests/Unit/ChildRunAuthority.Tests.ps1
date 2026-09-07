BeforeAll {
    $source = Join-Path $PSScriptRoot '../../source/child/RunAuthority.cs'
    if (-not ('DeskPilot.Child.RunAuthority' -as [type]) -and (Test-Path -LiteralPath $source)) { Add-Type -Path $source -ErrorAction Stop }
    if (-not ('ChildAuthorityBackpressureProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
public sealed class ChildAuthorityBackpressureProbe : IDisposable
{
    public ManualResetEventSlim Entered { get; } = new ManualResetEventSlim(false);
    public ManualResetEventSlim Release { get; } = new ManualResetEventSlim(false);
    public Task Dispatch(object authority) => Task.Run(() => authority.GetType().GetMethod("Commit", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(authority,
        new object[] { "provider", new Action(() => { Entered.Set(); Release.Wait(); }) }));
    public Task Stop(object authority) => Task.Run(() => authority.GetType().GetMethod("Close").Invoke(authority, new object[] { "stopped" }));
    public void Dispose() { Release.Set(); }
}
'@ -ErrorAction Stop
    }
}

Describe 'Child run authority' {
    BeforeEach {
        $script:authority = $null
        if ('DeskPilot.Child.RunAuthority' -as [type]) {
            $script:authority = [DeskPilot.Child.RunAuthority]::new('launch', 'conversation', 'parent-turn', 'child', ('d' * 64), $true, $true, $true, 60, 5)
        }
    }

    AfterEach { if ($script:authority) { $script:authority.Dispose() } }

    It 'binds one approval to the exact run, policy, and action and consumes it once' {
        $script:authority | Should -Not -BeNullOrEmpty
        $approval = $script:authority.Prepare('request', 'terminal', '{"command":"Write-Output bounded"}') | ConvertFrom-Json
        $approval.conversationId | Should -BeExactly 'conversation'
        $approval.parentTurnId | Should -BeExactly 'parent-turn'
        $approval.childId | Should -BeExactly 'child'
        $approval.profile | Should -BeExactly 'single-child-v3'
        $approval.budgetMode | Should -BeExactly 'provider-estimate'
        $script:authority.Submit('conversation', 'child', $approval.id, $approval.fingerprint, $true) | Should -BeTrue
        $script:authority.Consume('request', $approval.fingerprint) | Should -BeTrue
        $script:authority.Consume('request', $approval.fingerprint) | Should -BeFalse
        $script:authority.Submit('conversation', 'child', $approval.id, $approval.fingerprint, $true) | Should -BeFalse
    }

    It 'refuses cross-run, stale, and changed-action approval answers' {
        $script:authority | Should -Not -BeNullOrEmpty
        $approval = $script:authority.Prepare('request', 'terminal', '{"command":"Write-Output bounded"}') | ConvertFrom-Json
        $script:authority.Submit('other', 'child', $approval.id, $approval.fingerprint, $true) | Should -BeFalse
        $script:authority.Submit('conversation', 'other', $approval.id, $approval.fingerprint, $true) | Should -BeFalse
        $script:authority.Submit('conversation', 'child', $approval.id, ('e' * 64), $true) | Should -BeFalse
        $script:authority.Consume('request', $approval.fingerprint) | Should -BeFalse
    }

    It 'invalidates an accepted approval when Permission is revoked before dispatch' {
        $script:authority | Should -Not -BeNullOrEmpty
        $approval = $script:authority.Prepare('request', 'terminal', '{"command":"Write-Output bounded"}') | ConvertFrom-Json
        $script:authority.Submit('conversation', 'child', $approval.id, $approval.fingerprint, $true) | Should -BeTrue
        $script:authority.UpdatePermissions($true, $false, $true)
        $script:authority.Consume('request', $approval.fingerprint) | Should -BeFalse
        $script:authority.Open | Should -BeFalse
        $script:authority.Reason | Should -BeExactly 'permission-revoked'
    }

    It 'retains a denial and refuses a second decision or subsequent use of that request id' {
        $script:authority | Should -Not -BeNullOrEmpty
        $approval = $script:authority.Prepare('request', 'write', '{"path":"result.txt","sha256":"digest"}') | ConvertFrom-Json
        $script:authority.Submit('conversation', 'child', $approval.id, $approval.fingerprint, $false) | Should -BeTrue
        $script:authority.Submit('conversation', 'child', $approval.id, $approval.fingerprint, $true) | Should -BeFalse
        $script:authority.Consume('request', $approval.fingerprint) | Should -BeFalse
        { $script:authority.Prepare('request', 'write', '{"path":"result.txt","sha256":"digest"}') } | Should -Throw
    }

    It 'does not widen captured File, Terminal, or writable scope' {
        $script:authority | Should -Not -BeNullOrEmpty
        $narrow = [DeskPilot.Child.RunAuthority]::new('launch', 'conversation', 'turn', 'child', ('d' * 64), $true, $false, $false, 60, 5)
        try {
            $narrow.UpdatePermissions($true, $true, $true)
            { $narrow.Prepare('request', 'terminal', '{"command":"anything"}') } | Should -Throw
            { $narrow.Prepare('request', 'write', '{"path":"result"}') } | Should -Throw
        } finally { $narrow.Dispose() }
    }

    It 'closes admission immediately on Stop and releases a waiting approval' {
        $script:authority | Should -Not -BeNullOrEmpty
        $approval = $script:authority.Prepare('request', 'terminal', '{"command":"Write-Output bounded"}') | ConvertFrom-Json
        $wait = $script:authority.WaitForDecisionAsync()
        $script:authority.Close('stopped')
        $wait.Wait(1000) | Should -BeTrue
        $wait.Result | Should -BeFalse
        $script:authority.Open | Should -BeFalse
        $script:authority.Consume('request', $approval.fingerprint) | Should -BeFalse
    }

    It 'does not wait for a blocked committed send to close authority' {
        $probe = [ChildAuthorityBackpressureProbe]::new()
        $dispatch = $null
        $stop = $null
        try {
            $dispatch = $probe.Dispatch($script:authority)
            $probe.Entered.Wait(1000) | Should -BeTrue
            $stop = $probe.Stop($script:authority)
            $stop.Wait(500) | Should -BeTrue
            $script:authority.Open | Should -BeFalse
        } finally {
            $probe.Dispose()
            if ($dispatch) { $null = $dispatch.Wait(1000) }
            if ($stop) { $null = $stop.Wait(1000) }
        }
    }

    It 'revokes writable authority when live Project access becomes read-only' {
        $script:authority.UpdatePermissions($true, $true, $true, $false)
        $script:authority.Open | Should -BeFalse
        $script:authority.Reason | Should -BeExactly 'permission-revoked'
    }

    It 'admits a child request identity once and rejects replay before any operation' {
        $script:authority.AdmitRequest(('a' * 32))
        { $script:authority.AdmitRequest(('a' * 32)) } | Should -Throw
        { $script:authority.AdmitRequest('invalid') } | Should -Throw
    }
}
