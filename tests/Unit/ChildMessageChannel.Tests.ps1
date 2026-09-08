BeforeAll {
    $root = Join-Path $PSScriptRoot '../../source/child'
    $sources = @((Join-Path $root 'AuthenticatedChannel.cs'), (Join-Path $root 'MessageChannel.cs'))
    if (-not ('DeskPilot.Child.MessageChannel' -as [type])) { Add-Type -Path $sources -ErrorAction Stop }
}

Describe 'Child bounded message IPC' {
    It 'round-trips a request larger than one authenticated frame' {
        $wire = [IO.MemoryStream]::new()
        $unused = [IO.MemoryStream]::new()
        $key = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
        $sender = $null
        $receiver = $null
        try {
            $sender = [DeskPilot.Child.MessageChannel]::new($unused, $wire, $key, $true, 262144)
            $body = @{ type = 'request'; text = ('bounded ' * 16000) } | ConvertTo-Json -Compress
            $sender.Send($body)
            $wire.Position = 0
            $receiver = [DeskPilot.Child.MessageChannel]::new($wire, $unused, $key, $false, 262144)
            $receiver.Receive() | Should -BeExactly $body
        } finally { if ($receiver) { $receiver.Dispose() }; if ($sender) { $sender.Dispose() } }
    }

    It 'refuses an oversized complete message before writing frames' {
        $wire = [IO.MemoryStream]::new()
        $channel = $null
        try {
            $channel = [DeskPilot.Child.MessageChannel]::new([IO.MemoryStream]::new(), $wire, [byte[]]::new(32), $true, 1024)
            { $channel.Send(('{"text":"' + ('x' * 1100) + '"}')) } | Should -Throw
            $wire.Length | Should -Be 0
        } finally { if ($channel) { $channel.Dispose() } }
    }

    It 'refuses duplicate properties in the reassembled message' {
        $wire = [IO.MemoryStream]::new()
        $channel = $null
        try {
            $channel = [DeskPilot.Child.MessageChannel]::new([IO.MemoryStream]::new(), $wire, [byte[]]::new(32), $true, 1024)
            { $channel.Send('{"id":"one","ID":"two"}') } | Should -Throw
            $wire.Length | Should -Be 0
        } finally { if ($channel) { $channel.Dispose() } }
    }
}
