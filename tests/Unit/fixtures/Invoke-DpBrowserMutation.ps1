#requires -Version 7.0

<#
.SYNOPSIS
    Disables one control at a time and reports whether the suite notices.
.DESCRIPTION
    The measurement the fifth review round made and this repository could not: an
    assertion that reads source text as a string still passes when the control it
    names is deleted. Nineteen of them did.

    Each mutation below removes or inverts exactly one control, applies it to a
    copy of the source tree, and runs only the tests that claim to cover it. A
    mutation nothing notices is a control with no test, however many assertions
    mention it. Naming the test matters: a mutation that reddens some unrelated
    assertion proves nothing about the control it disabled.

    Single-quoted here-strings throughout, so the mutation text is byte-for-byte
    what is in the file.
.PARAMETER RepositoryRoot
    The repository root. Defaults to the one this script lives in.
.OUTPUTS
    One object per mutation with Id, Control, Applied, Noticed and Ran.
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [ValidateNotNullOrEmpty()]
    [string]$RepositoryRoot = (Join-Path $PSScriptRoot '..' '..' '..' | Convert-Path)
)

$mutations = @(
    @{
        Id      = 'scope-match-not-ordinal'
        Control = 'the scope host match is ordinal, not culture-sensitive'
        File    = 'source/Private/Resolve-DpBrowserUrlDecision.ps1'
        From    = @'
        if ([string]::Equals($hostName, $allowed, [System.StringComparison]::Ordinal) -or
            $hostName.EndsWith('.' + $allowed, [System.StringComparison]::Ordinal)) {
'@
        To      = @'
        if ($hostName -eq $allowed -or $hostName.EndsWith('.' + $allowed)) {
'@
        Test    = '*matches the scope host ordinally*'
    }
    @{
        Id      = 'provenance-not-ordinal'
        Control = 'the path comparison is case-sensitive'
        File    = 'source/Private/Test-DpBrowserUrlFromPage.ps1'
        From    = @'
        [string]::Equals(($other.PathAndQuery + $other.Fragment), $wantedPath, [System.StringComparison]::Ordinal)
'@
        To      = @'
        ($other.PathAndQuery + $other.Fragment) -eq $wantedPath
'@
        Test    = '*B4-1*'
    }
    @{
        Id      = 'provenance-ignores-host'
        Control = 'a candidate must be on the same host'
        File    = 'source/Private/Test-DpBrowserUrlFromPage.ps1'
        From    = @'
        if (-not [string]::Equals((& $hostOf $other), $wantedHost, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
'@
        To      = @'
        if ($false) { return $false }
'@
        Test    = '*B4-1*'
    }
    @{
        Id      = 'root-exemption-unbounded'
        Control = 'the site root is authored only for a host somebody named'
        File    = 'source/Private/Test-DpBrowserUrlFromPage.ps1'
        From    = @'
    if ($bare -and $authored.Contains((& $hostOf $uri))) { return $true }
'@
        To      = @'
    if ($bare) { return $true }
'@
        Test    = '*B3-1*'
    }
    @{
        Id      = 'truncation-guard-removed'
        Control = 'a url cut by the length bound is discarded'
        File    = 'source/Private/Get-DpBrowserUserUrl.ps1'
        From    = @'
        if ($truncated -and ($match.Index + $match.Length) -ge $bounded.Length) { continue }
'@
        To      = @'
        if ($false) { continue }
'@
        Test    = '*B4-2*'
    }
    @{
        Id      = 'scheme-match-unanchored'
        Control = 'the scheme must start a token'
        File    = 'source/Private/Get-DpBrowserUserUrl.ps1'
        From    = @'
'(?<![A-Za-z0-9+.\-])https://[^\s"''<>)\]]+'
'@
        To      = @'
'https://[^\s"''<>)\]]+'
'@
        Test    = '*B3-2*'
    }
    @{
        Id      = 'url-run-splitter-restored'
        Control = 'a url inside a url is not promoted into scope'
        File    = 'source/Private/Get-DpBrowserUserUrl.ps1'
        From    = @'
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { $found.Add($candidate) }
'@
        To      = @'
        foreach ($piece in [regex]::Split($candidate, '(?<=.)(?=https://)')) {
            if (-not [string]::IsNullOrWhiteSpace($piece)) { $found.Add($piece) }
        }
'@
        Test    = '*does not promote a url inside a url*'
    }
    @{
        Id      = 'scope-seeds-denied-forms'
        Control = 'scope admits only what the classifier would offer a card for'
        File    = 'source/Private/Get-DpBrowserScope.ps1'
        From    = @'
        if ($decision.decision -ne 'deny') { & $add $decision.host }
'@
        To      = @'
        & $add $decision.host
'@
        Test    = '*B3-3*'
    }
    @{
        Id      = 'fingerprint-not-ordinal'
        Control = 'the approval fingerprint is compared ordinally'
        File    = 'source/Private/Request-DpBrowserApproval.ps1'
        From    = @'
        -not [string]::Equals($returned, $request.fingerprint, [System.StringComparison]::Ordinal)) {
'@
        To      = @'
        $returned -ne $request.fingerprint) {
'@
        Test    = '*refuses an approval whose fingerprint differs only in case*'
    }
    @{
        Id      = 'sends-the-model-string'
        Control = 'the browser is sent the rebuilt address'
        File    = 'source/Private/Invoke-DpBrowserTool.ps1'
        From    = @'
-Payload @{ url = [string]$decision.url }
'@
        To      = @'
-Payload @{ url = [string]$Url }
'@
        Test    = '*opens the rebuilt address*'
    }
    @{
        Id      = 'authored-hosts-not-passed'
        Control = 'the Project and granted hosts reach the provenance test'
        File    = 'source/Private/Invoke-DpBrowserTool.ps1'
        From    = @'
                    -AuthoredHost @(@($context.projectDomains) + @($state.granted)))) {
'@
        To      = @'
                    -AuthoredHost @())) {
'@
        Test    = '*asks nothing when the project already allows the host*'
    }
    @{
        Id      = 'missing-asset-skipped'
        Control = 'an asset that did not ship is an error'
        File    = 'source/Private/Copy-DpBrowserAsset.ps1'
        From    = @'
            throw "The browser runtime is incomplete: '$required' was not installed."
'@
        To      = @'
            $null = $required
'@
        Test    = '*refuses to leave a browser module behind*'
    }
)

$temp = Join-Path ([System.IO.Path]::GetTempPath()) "dp-mutate-$([guid]::NewGuid().ToString('n'))"
try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'source') -Destination (Join-Path $temp 'source') -Recurse -Force
    $testDir = Join-Path $temp 'tests' 'Unit'
    New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'tests' 'Unit' 'BrowserAutomation.Tests.ps1') -Destination $testDir -Force
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'tests' 'Unit' 'fixtures') -Destination (Join-Path $testDir 'fixtures') -Recurse -Force

    $testFile = Join-Path $testDir 'BrowserAutomation.Tests.ps1'
    $pristine = @{}
    foreach ($mutation in $mutations) {
        if (-not $pristine.ContainsKey($mutation.File)) {
            $pristine[$mutation.File] = Get-Content -LiteralPath (Join-Path $temp $mutation.File) -Raw
        }
    }

    foreach ($mutation in $mutations) {
        $target = Join-Path $temp $mutation.File
        $original = $pristine[$mutation.File]
        $from = $mutation.From.TrimEnd("`r", "`n")
        $applied = $original.Contains($from)
        $noticed = $false
        $ran = 0

        if ($applied) {
            Set-Content -LiteralPath $target -Value $original.Replace($from, $mutation.To.TrimEnd("`r", "`n")) -Encoding utf8NoBOM
            try {
                $configuration = New-PesterConfiguration
                $configuration.Run.Path = $testFile
                $configuration.Filter.FullName = $mutation.Test
                $configuration.Output.Verbosity = 'None'
                $configuration.Run.PassThru = $true
                $result = Invoke-Pester -Configuration $configuration
                $noticed = $result.FailedCount -gt 0
                # A filter that matched nothing proves nothing either.
                $ran = $result.PassedCount + $result.FailedCount
            }
            catch { $noticed = $true; $ran = -1 }
            finally { Set-Content -LiteralPath $target -Value $original -Encoding utf8NoBOM }
        }

        [pscustomobject]@{
            Id      = $mutation.Id
            Control = $mutation.Control
            Applied = $applied
            Noticed = $noticed
            Ran     = $ran
        }
    }
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
