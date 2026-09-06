#requires -Version 7.4

BeforeAll {
    $sourcePath = Join-Path $PSScriptRoot '../../source/child/ProjectBaseline.cs'
    if (Test-Path -LiteralPath $sourcePath) { Add-Type -Path $sourcePath -ErrorAction Stop }
}

Describe 'Child Agent selected Project baseline' -Tag 'Unit' {
    BeforeEach {
        $project = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $project
        [IO.File]::WriteAllText((Join-Path $project 'selected.txt'), 'uncommitted input')
        [IO.File]::WriteAllText((Join-Path $project 'unselected.txt'), 'not selected')
    }

    It 'captures exactly the selected current bytes and remains immutable after external edits' {
        $baseline = [DeskPilot.Child.ProjectBaseline]::Open($project, @('selected.txt'), 1024, 10)
        try {
            $baseline.Entries.Count | Should -Be 1
            $baseline.Entries[0].Path | Should -BeExactly 'selected.txt'
            [Text.Encoding]::UTF8.GetString($baseline.Entries[0].GetBytes()) | Should -BeExactly 'uncommitted input'
            $baseline.TotalBytes | Should -Be 17
            $baseline.Entries[0].Sha256 | Should -Match '^[0-9a-f]{64}$'

            $copy = $baseline.Entries[0].GetBytes()
            $copy[0] = 0
            $baseline.Entries[0].GetBytes()[0] | Should -Be 117
        }
        finally { $baseline.Dispose() }

        [IO.File]::WriteAllText((Join-Path $project 'selected.txt'), 'later edit')
        [Text.Encoding]::UTF8.GetString($baseline.Entries[0].GetBytes()) | Should -BeExactly 'uncommitted input'
        [IO.File]::ReadAllText((Join-Path $project 'unselected.txt')) | Should -BeExactly 'not selected'
    }

    It 'pins file and ancestor handles so writes and path replacement fail during capture ownership' {
        $baseline = [DeskPilot.Child.ProjectBaseline]::Open($project, @('selected.txt'), 1024, 10)
        try {
            { [IO.File]::WriteAllText((Join-Path $project 'selected.txt'), 'unexpected') } | Should -Throw
            { [IO.Directory]::Move($project, "$project-replaced") } | Should -Throw
            { [IO.File]::Move((Join-Path $project 'selected.txt'), (Join-Path $project 'moved.txt')) } |
                Should -Throw
        }
        finally { $baseline.Dispose() }
    }

    It 'refuses an existing writable handle instead of capturing an unstable file' {
        $writer = [IO.File]::Open((Join-Path $project 'selected.txt'), 'Open', 'ReadWrite', 'ReadWrite')
        try {
            { [DeskPilot.Child.ProjectBaseline]::Open($project, @('selected.txt'), 1024, 10) } |
                Should -Throw -ExpectedMessage '*stable*'
        }
        finally { $writer.Dispose() }
    }

    It 'refuses <Path> rather than widening or silently omitting selected input' -ForEach @(
        @{ Path = '../outside.txt' }
        @{ Path = 'C:/outside.txt' }
        @{ Path = '/outside.txt' }
        @{ Path = 'selected.txt:private' }
        @{ Path = 'CON' }
        @{ Path = 'selected.txt.' }
        @{ Path = '.git/config' }
        @{ Path = '.env' }
    ) {
        { [DeskPilot.Child.ProjectBaseline]::Open($project, @($Path), 1024, 10) } |
            Should -Throw -ExpectedMessage '*selected*'
    }

    It 'refuses selected byte and file-count overflow before returning any baseline' {
        { [DeskPilot.Child.ProjectBaseline]::Open($project, @('selected.txt'), 16, 10) } |
            Should -Throw -ExpectedMessage '*limit*'
        { [DeskPilot.Child.ProjectBaseline]::Open($project, @('selected.txt', 'unselected.txt'), 1024, 1) } |
            Should -Throw -ExpectedMessage '*limit*'
    }

    It 'refuses duplicate case aliases and a missing selected file' {
        { [DeskPilot.Child.ProjectBaseline]::Open($project, @('selected.txt', 'SELECTED.TXT'), 1024, 10) } |
            Should -Throw -ExpectedMessage '*selected*'
        { [DeskPilot.Child.ProjectBaseline]::Open($project, @('missing.txt'), 1024, 10) } |
            Should -Throw -ExpectedMessage '*stable*'
    }

    It 'refuses hard links and alternate streams on selected files' {
        $null = New-Item -ItemType HardLink -Path (Join-Path $project 'linked.txt') -Target (Join-Path $project 'selected.txt')
        { [DeskPilot.Child.ProjectBaseline]::Open($project, @('linked.txt'), 1024, 10) } |
            Should -Throw -ExpectedMessage '*link*'
        Remove-Item -LiteralPath (Join-Path $project 'linked.txt')
        [IO.File]::WriteAllText((Join-Path $project 'selected.txt:private'), 'stream canary')
        { [DeskPilot.Child.ProjectBaseline]::Open($project, @('selected.txt'), 1024, 10) } |
            Should -Throw -ExpectedMessage '*stream*'
    }

    It 'refuses a Project junction and a selected junction without following either' {
        $outside = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $outside
        [IO.File]::WriteAllText((Join-Path $outside 'canary.txt'), 'outside canary')
        $junction = Join-Path $project 'junction'
        $null = New-Item -ItemType Junction -Path $junction -Target $outside

        { [DeskPilot.Child.ProjectBaseline]::Open($junction, @('canary.txt'), 1024, 10) } |
            Should -Throw -ExpectedMessage '*reparse*'
        { [DeskPilot.Child.ProjectBaseline]::Open($project, @('junction/canary.txt'), 1024, 10) } |
            Should -Throw -ExpectedMessage '*reparse*'
        [IO.File]::ReadAllText((Join-Path $outside 'canary.txt')) | Should -BeExactly 'outside canary'
    }

    It 'refuses existing credential file <Path> before reading its contents' -ForEach @(
        @{ Path = 'private.pem' }
        @{ Path = 'identity.cer' }
        @{ Path = 'identity.crt' }
        @{ Path = 'identity.der' }
        @{ Path = '.kubeconfig' }
        @{ Path = '.kube/config' }
        @{ Path = 'secrets.yaml' }
        @{ Path = 'secret.json' }
        @{ Path = 'credentials.json' }
        @{ Path = 'token.json' }
    ) {
        $target = Join-Path $project $Path
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::WriteAllText($target, 'credential fixture')
        {
            $capture = $null
            try { $capture = [DeskPilot.Child.ProjectBaseline]::Open($project, @($Path), 1024, 10) }
            finally { if ($capture) { $capture.Dispose() } }
        } | Should -Throw -ExpectedMessage '*credential*'
    }

    It 'refuses credential-bearing JSON regardless of the selected filename' -ForEach @(
        @{ Content = '{"service":{"apiKey":"credential-canary"}}' }
        @{ Content = '{"configuration":[{"client_secret":"credential-canary"}]}' }
        @{ Content = '{"access_token":"credential-canary"}' }
        @{ Content = '{"ConnectionStrings":{"Primary":"Server=example;Password=credential-canary"}}' }
    ) {
        [IO.File]::WriteAllText((Join-Path $project 'settings.json'), $Content)

        {
            $capture = $null
            try { $capture = [DeskPilot.Child.ProjectBaseline]::Open($project, @('settings.json'), 1024, 10) }
            finally { if ($capture) { $capture.Dispose() } }
        } | Should -Throw -ExpectedMessage '*credential*'
    }

    It 'refuses private-key content under an ordinary text filename' {
        [IO.File]::WriteAllText((Join-Path $project 'notes.txt'), "-----BEGIN PRIVATE KEY-----`nfixture`n-----END PRIVATE KEY-----")

        {
            $capture = $null
            try { $capture = [DeskPilot.Child.ProjectBaseline]::Open($project, @('notes.txt'), 1024, 10) }
            finally { if ($capture) { $capture.Dispose() } }
        } | Should -Throw -ExpectedMessage '*credential*'
    }

    It 'retains ordinary JSON data without credential fields' {
        $content = '{"name":"bounded input","count":3,"enabled":true}'
        [IO.File]::WriteAllText((Join-Path $project 'data.json'), $content)
        $baseline = [DeskPilot.Child.ProjectBaseline]::Open($project, @('data.json'), 1024, 10)
        try {
            [Text.Encoding]::UTF8.GetString($baseline.Entries[0].GetBytes()) | Should -BeExactly $content
        }
        finally { $baseline.Dispose() }
    }
}
