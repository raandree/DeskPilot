#requires -Version 7.4

BeforeAll {
    $root = Join-Path $PSScriptRoot '../../source/child'
    $sources = @((Join-Path $root 'AuthenticatedChannel.cs'), (Join-Path $root 'MessageChannel.cs'))
    if (-not ('DeskPilot.Child.AuthenticatedChannel' -as [type])) { Add-Type -Path $sources -ErrorAction Stop }

    function New-DpChannelFrame {
        param([string]$Message = '{"type":"ready"}', [byte[]]$Key = [byte[]](1..32))
        $output = [IO.MemoryStream]::new()
        $sender = [DeskPilot.Child.AuthenticatedChannel]::new([IO.Stream]::Null, $output, $Key, $true, 128)
        try {
            $sender.Send($Message)
            ,$output.ToArray()
        }
        finally { $sender.Dispose() }
    }
}

Describe 'Child Agent authenticated channel' -Tag 'Unit' {
    It 'authenticates and preserves exact bounded JSON bytes' {
        $packet = New-DpChannelFrame
        $input = [IO.MemoryStream]::new($packet)
        $receiver = [DeskPilot.Child.AuthenticatedChannel]::new($input, [IO.Stream]::Null, [byte[]](1..32), $false, 128)
        try { $receiver.Receive() | Should -BeExactly '{"type":"ready"}' }
        finally { $receiver.Dispose() }
    }

    It 'refuses changed bytes, another run key, and reflected direction' -ForEach @(
        @{ Attack = 'bytes' }
        @{ Attack = 'key' }
        @{ Attack = 'direction' }
    ) {
        $packet = New-DpChannelFrame
        if ($Attack -eq 'bytes') { $packet[13] = $packet[13] -bxor 1 }
        $key = if ($Attack -eq 'key') { [byte[]](2..33) } else { [byte[]](1..32) }
        $input = [IO.MemoryStream]::new($packet)
        $receiver = [DeskPilot.Child.AuthenticatedChannel]::new($input, [IO.Stream]::Null, $key, ($Attack -eq 'direction'), 128)
        try { { $receiver.Receive() } | Should -Throw -ExpectedMessage '*authentication*' }
        finally { $receiver.Dispose() }
    }

    It 'consumes a sequence once and refuses replayed records' {
        $packet = New-DpChannelFrame
        $input = [IO.MemoryStream]::new([byte[]]($packet + $packet))
        $receiver = [DeskPilot.Child.AuthenticatedChannel]::new($input, [IO.Stream]::Null, [byte[]](1..32), $false, 128)
        try {
            $receiver.Receive() | Should -BeExactly '{"type":"ready"}'
            { $receiver.Receive() } | Should -Throw -ExpectedMessage '*sequence*'
        }
        finally { $receiver.Dispose() }
    }

    It 'refuses an oversized header before allocating or reading its body' {
        $input = [IO.MemoryStream]::new([byte[]](127, 255, 255, 255))
        $receiver = [DeskPilot.Child.AuthenticatedChannel]::new($input, [IO.Stream]::Null, [byte[]](1..32), $false, 128)
        try {
            { $receiver.Receive() } | Should -Throw -ExpectedMessage '*limit*'
            $input.Position | Should -Be 4
        }
        finally { $receiver.Dispose() }
    }

    It 'refuses ambiguous or oversized output before writing a record' -ForEach @(
        @{ Message = '{"type":"ready","type":"execute"}' }
        @{ Message = ('{"data":"' + ('a' * 128) + '"}') }
        @{ Message = '[]' }
    ) {
        $output = [IO.MemoryStream]::new()
        $sender = [DeskPilot.Child.AuthenticatedChannel]::new([IO.Stream]::Null, $output, [byte[]](1..32), $true, 128)
        try {
            { $sender.Send($Message) } | Should -Throw
            $output.Length | Should -Be 0
        }
        finally { $sender.Dispose() }
    }
}
