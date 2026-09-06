<#
.SYNOPSIS
    Runs the deterministic and actual-runtime child storage proofs.
.DESCRIPTION
    Run through the canonical detached PowerShell launcher. Retains exact
    source hashes, runtime versions, NUnit results and explicit open gates.
    Does not authenticate, call a provider, or claim complete child readiness.
.PARAMETER PesterModulePath
    Explicit path to an installed Pester 5 manifest.
.PARAMETER EvidenceDirectory
    New evidence directory outside the Project and build output.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PesterModulePath,

    [string]$EvidenceDirectory = (Join-Path $env:TEMP ('deskpilot-child-proof-' + [guid]::NewGuid().ToString('N')))
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $PSVersionTable.PSVersion -lt [version]'7.4') {
    throw 'The child storage proof requires Windows and PowerShell 7.4 or newer.'
}
Import-Module -Name $PesterModulePath -Force -ErrorAction Stop
if ((Get-Module -Name Pester).Version.Major -ne 5) { throw 'Use Pester 5 for this proof.' }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
if ($evidence.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $evidence)) {
    throw 'Use a new evidence directory outside the Project.'
}
$null = New-Item -ItemType Directory -Path $evidence
$privateRoot = Join-Path $root 'source/Private'
Get-ChildItem -LiteralPath $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
$runtimeVersion = Invoke-DpDockerControl -Argument @('version', '--format', '{{json .Server}}') | ConvertFrom-Json
$sourcePaths = @(
    Get-ChildItem -LiteralPath (Join-Path $root 'source/child') -File
    Get-ChildItem -LiteralPath $privateRoot -File -Filter '*Child*.ps1'
    Get-Item -LiteralPath (Join-Path $root 'source/Private/Get-DpDefaultSettings.ps1')
    Get-Item -LiteralPath (Join-Path $root 'source/Private/Merge-DpSettings.ps1')
)
$sourceHashes = @(foreach ($source in $sourcePaths) {
        @{ path = [IO.Path]::GetRelativePath($root, $source.FullName).Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash }
    })
$configuration = New-PesterConfiguration
$configuration.Run.Path = @(
    (Join-Path $root 'tests/Unit/ChildAgentIsolation.Tests.ps1')
    (Join-Path $root 'tests/Unit/ChildAgentFiles.Tests.ps1')
    (Join-Path $root 'tests/Unit/ChildAgentChannel.Tests.ps1')
    (Join-Path $root 'tests/Integration/ChildAgentStorage.Tests.ps1')
)
$configuration.Run.PassThru = $true
$configuration.Run.Exit = $false
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputPath = Join-Path $evidence 'tests.xml'
$result = Invoke-Pester -Configuration $configuration
$summary = @{
    schemaVersion = 1
    completedUtc = [datetime]::UtcNow.ToString('o')
    powerShellVersion = $PSVersionTable.PSVersion.ToString()
    pesterVersion = (Get-Module -Name Pester).Version.ToString()
    dockerVersion = [string]$runtimeVersion.Version
    source = $sourceHashes
    tests = @{ passed = $result.PassedCount; failed = $result.FailedCount; skipped = $result.SkippedCount; notRun = $result.NotRunCount; total = $result.TotalCount }
    completeChildProfile = $false
    actualRuntimeScope = 'Private Tool storage, export, lease, Stop and recovery only.'
    authenticatedLiveProof = 'Not run; complete-request Engine admission is not available.'
    cleanInstallEngineSupport = 'Not proven.'
    parallelAgents = 'Not implemented.'
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $evidence 'summary.json') -Encoding utf8
if ($result.FailedCount -or $result.SkippedCount -or $result.NotRunCount -or -not $result.TotalCount) {
    throw "Child storage proof did not pass every selected test. Evidence: $evidence"
}
[pscustomobject]@{ EvidenceDirectory = $evidence; Passed = $result.PassedCount; CompleteChildProfile = $false }
