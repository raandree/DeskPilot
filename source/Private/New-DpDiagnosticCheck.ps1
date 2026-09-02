function New-DpDiagnosticCheck {
    <#
    .SYNOPSIS
        Creates one bounded diagnostic check record.
    .PARAMETER Id
        Stable machine-readable check identifier.
    .PARAMETER Label
        Human-readable dependency name.
    .PARAMETER State
        One of the four diagnostic states.
    .PARAMETER Explanation
        Bounded explanation of the observed state.
    .PARAMETER Action
        One safe next action, or an empty string when none is needed.
    .PARAMETER Detail
        Optional allow-listed scalar metadata supplied by the caller.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs and returns an in-memory record; it changes no external state.')]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9][a-z0-9-]{0,39}$')]
        [string]$Id,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Label,

        [Parameter(Mandatory)]
        [ValidateSet('healthy', 'degraded', 'unavailable', 'not configured')]
        [string]$State,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Explanation,

        [AllowEmptyString()]
        [string]$Action = '',

        [hashtable]$Detail
    )

    $record = [ordered]@{
        id          = $Id
        label       = (Protect-DpDiagnosticText -Text $Label -MaxLength 80)
        state       = $State
        explanation = (Protect-DpDiagnosticText -Text $Explanation -MaxLength 300)
        action      = (Protect-DpDiagnosticText -Text $Action -MaxLength 200)
    }
    if ($Detail) {
        $allowedDetail = @('version', 'configuredCount', 'enabledCount', 'healthyCount', 'degradedCount')
        foreach ($key in $allowedDetail) {
            if (-not $Detail.ContainsKey($key)) { continue }
            $value = $Detail[$key]
            $record[$key] = if ($value -is [bool] -or $value -is [int] -or $value -is [long]) {
                $value
            }
            else {
                Protect-DpDiagnosticText -Text ([string]$value) -MaxLength 120
            }
        }
    }
    $record
}