#requires -Version 7.0
<#
.SYNOPSIS
    Starts one throwaway DeskPilot Host Server for a single eval trial from a
    configuration file.
.DESCRIPTION
    This script is the *fixed* launcher the harness runs. It is committed code:
    the harness never generates a script, never encodes one and never
    interpolates a path into anything that will be executed. Everything a trial
    needs arrives as data - one JSON file named by one argument - and every
    value in it is passed to Start-DeskPilot as a parameter value, never as
    text that is parsed again.

    That is the whole point. A sandbox path, a repository root or an Engine
    path can legitimately contain a space, an apostrophe or a character that
    looks like PowerShell. Under the previous launcher those characters ended
    up inside a generated command line, where a path stopped being a path. Here
    they are strings in a JSON file, and a string is never code.

    The configuration is a closed schema. An unknown key is refused rather than
    ignored, so nothing - a case manifest, a corpus, an operator - can name a
    script for this process to run.

    It calls no Model by itself. It starts the Host Server, which the harness
    then drives over loopback.
.PARAMETER ConfigPath
    The launch configuration written by the harness. A JSON object with
    schemaVersion, repositoryRoot, modulePath, port, dataDirectory and an
    optional engineModulePath. No other key is accepted.
.PARAMETER ValidateOnly
    Validate the configuration, report the parameters that would be passed to
    Start-DeskPilot, and exit without importing the module or starting a
    server. This is how the transport is tested without a Host Server, an
    Engine or a Model.
.EXAMPLE
    pwsh -NoProfile -File ./Start-DpEvalHost.ps1 -ConfigPath /tmp/trial/host-launch.json

    Starts the Host Server described by the configuration file.
.EXAMPLE
    pwsh -NoProfile -File ./Start-DpEvalHost.ps1 -ConfigPath /tmp/trial/host-launch.json -ValidateOnly

    Prints what it would launch and exits. Starts nothing and spends nothing.
#>
[CmdletBinding()]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The child process writes to its own console stream; the harness captures it as the trial log.')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath,

    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# The closed schema. Anything else in the file is a refusal, not a warning: an
# ignored key is an instruction somebody believed was honoured.
$knownKeys = @('schemaVersion', 'repositoryRoot', 'modulePath', 'port', 'dataDirectory', 'engineModulePath')

function Write-DpEvalHostLine {
    <#
    .SYNOPSIS
        Writes one line of the trial log.
    .PARAMETER Message
        The line to write.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    Write-Host "dp-eval-host: $Message"
}

function Get-DpEvalHostConfiguration {
    <#
    .SYNOPSIS
        Reads and validates the launch configuration.
    .DESCRIPTION
        Fails closed on everything: a missing file, a malformed document, an
        unknown key, a missing value, a value of the wrong type and a port that
        is not a port. A launcher that guesses is a launcher that can be
        steered.
    .PARAMETER Path
        The configuration file.
    .OUTPUTS
        System.Collections.Hashtable with ok, configuration and reason.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{ ok = $false; configuration = $null; reason = "the launch configuration '$Path' does not exist." }
    }

    try { $document = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { return @{ ok = $false; configuration = $null; reason = "the launch configuration '$Path' is not valid JSON: $_" } }

    if ($null -eq $document -or $document -isnot [System.Management.Automation.PSCustomObject]) {
        return @{ ok = $false; configuration = $null; reason = 'the launch configuration is not a JSON object.' }
    }

    $present = @($document.PSObject.Properties.Name)
    $unknown = @($present | Where-Object { $_ -notin $knownKeys })
    if ($unknown.Count) {
        return @{
            ok            = $false
            configuration = $null
            reason        = "the launch configuration carries unknown keys: $($unknown -join ', '). This launcher runs a Host Server and nothing else."
        }
    }

    $configuration = @{}
    foreach ($name in @('repositoryRoot', 'modulePath', 'dataDirectory')) {
        $value = $document.$name
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            return @{ ok = $false; configuration = $null; reason = "the launch configuration needs a non-empty string '$name'." }
        }
        $configuration[$name] = [string]$value
    }

    $port = 0
    if ($null -eq $document.port -or -not [int]::TryParse([string]$document.port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        return @{ ok = $false; configuration = $null; reason = "the launch configuration needs a port between 1 and 65535; got '$($document.port)'." }
    }
    $configuration['port'] = $port

    $schema = 0
    if ($null -eq $document.schemaVersion -or -not [int]::TryParse([string]$document.schemaVersion, [ref]$schema) -or $schema -ne 1) {
        return @{ ok = $false; configuration = $null; reason = "the launch configuration declares schemaVersion '$($document.schemaVersion)'; this launcher speaks version 1." }
    }
    $configuration['schemaVersion'] = $schema

    if ($document.PSObject.Properties['engineModulePath']) {
        $engine = $document.engineModulePath
        if ($engine -isnot [string] -or [string]::IsNullOrWhiteSpace($engine)) {
            return @{ ok = $false; configuration = $null; reason = "'engineModulePath' is present but is not a non-empty string. Omit it to use the Host Server default." }
        }
        $configuration['engineModulePath'] = [string]$engine
    }

    @{ ok = $true; configuration = $configuration; reason = '' }
}

$decision = Get-DpEvalHostConfiguration -Path $ConfigPath
if (-not $decision.ok) {
    Write-DpEvalHostLine -Message "configuration refused: $($decision.reason)"
    [Console]::Error.WriteLine("dp-eval-host: configuration refused: $($decision.reason)")
    exit 2
}
$configuration = $decision.configuration

# Every value below is a parameter value, never text that is parsed again.
$parameters = @{
    NoBrowser = $true
    Port      = $configuration['port']
    DataDir   = $configuration['dataDirectory']
}
if ($configuration.ContainsKey('engineModulePath')) {
    $parameters['EngineModulePath'] = $configuration['engineModulePath']
}

Write-DpEvalHostLine -Message 'configuration valid'
Write-DpEvalHostLine -Message "repositoryRoot = $($configuration['repositoryRoot'])"
Write-DpEvalHostLine -Message "modulePath = $($configuration['modulePath'])"
Write-DpEvalHostLine -Message "parameter Port = $($parameters['Port'])"
Write-DpEvalHostLine -Message "parameter DataDir = $($parameters['DataDir'])"
if ($parameters.ContainsKey('EngineModulePath')) {
    Write-DpEvalHostLine -Message "parameter EngineModulePath = $($parameters['EngineModulePath'])"
}

if ($ValidateOnly) {
    Write-DpEvalHostLine -Message 'validate only: nothing was started.'
    exit 0
}

foreach ($name in @('repositoryRoot', 'modulePath')) {
    if (-not (Test-Path -LiteralPath $configuration[$name] -PathType Container)) {
        $problem = "'$name' points at '$($configuration[$name])', which is not a directory. Build the module before a live run."
        Write-DpEvalHostLine -Message "launch refused: $problem"
        [Console]::Error.WriteLine("dp-eval-host: launch refused: $problem")
        exit 3
    }
}

try {
    # The working directory is set by the parent through the process start
    # information; this keeps the child's own location in step with it for code
    # that resolves a relative path.
    Set-Location -LiteralPath $configuration['repositoryRoot']
    Import-Module -Name $configuration['modulePath'] -Force -ErrorAction Stop
    Start-DeskPilot @parameters
}
catch {
    Write-DpEvalHostLine -Message "the Host Server stopped: $_"
    [Console]::Error.WriteLine("dp-eval-host: the Host Server stopped: $_")
    exit 4
}
