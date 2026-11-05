function Protect-DpUserTool {
    <#
    .SYNOPSIS
        Puts a plain function in front of a registered User Tool, so a Tool call
        can bind only the Tool's own parameters.
    .DESCRIPTION
        The Engine dispatches a User Tool by splatting the Model's JSON arguments
        onto the registered command, in the Engine's own scope. An advanced
        function also accepts the PowerShell common parameters, their aliases and
        their prefixes. -OutVariable, -ErrorVariable and their siblings then write
        into the Engine's own variables - among them the list that keeps a
        disabled Tool from running and the approval control - and
        -InformationAction Ignore silences the records the Host Server accounts
        from. A plain function has no common parameters.

        The schema the Model is offered is built once, at registration, from the
        advanced function, so it keeps its required and enum markers. This moves
        that function to <Name>Core and puts a plain function under the
        registered name, which the Engine resolves at every dispatch. The plain
        function binds only the Tool's own parameters, refuses any other argument
        without running anything, and forwards what was bound, so the Tool still
        applies its own defaults and validation.

        Call it in the Engine Runspace after Register-ShpTool, every time the Tool
        is declared again. A name that already holds a plain function is left as
        it is, so a second call cannot make the guard call itself.
    .PARAMETER Name
        The command registered with Register-ShpTool.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Re-declares a Tool function inside the Engine Runspace during per-Turn registration, like the registration itself; there is no user to confirm it.')]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z][A-Za-z0-9]*(-[A-Za-z0-9]+)*$')]
        [string]$Name
    )

    $command = Get-Command -Name $Name -CommandType Function -ErrorAction Stop
    if (-not $command.CmdletBinding) { return }

    $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
        @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
    $declared = @($command.Parameters.Keys | Where-Object { $_ -notin $common })
    foreach ($parameter in $declared) {
        if ($parameter -notmatch '^[A-Za-z][A-Za-z0-9]*$') {
            throw "The parameter '$parameter' of $Name cannot be guarded, so the Tool was not made available."
        }
    }

    $core = $Name + 'Core'
    Set-Item -LiteralPath "function:global:$core" -Value $command.ScriptBlock

    $parameterList = ($declared | ForEach-Object { '$' + $_ }) -join ', '
    $guard = @"
param($parameterList)
if (`$args.Count -gt 0) {
    `$refused = @(`$args | Where-Object { `$_ -is [string] -and `$_ -match '^-[^:]+:?$' } |
        ForEach-Object { `$name = `$_.TrimStart('-').TrimEnd(':'); if (`$name.Length -gt 40) { `$name.Substring(0, 40) } else { `$name } } |
        Select-Object -First 10)
    if (`$refused.Count -eq 0) { `$refused = @('an unnamed value') }
    return ([ordered]@{
            status = 'refused'
            error  = ('This Tool takes only its own arguments, so nothing was run. Refused: {0}.' -f (`$refused -join ', '))
        } | ConvertTo-Json -Compress)
}
`$forward = @{}
foreach (`$key in `$PSBoundParameters.Keys) { `$forward[`$key] = `$PSBoundParameters[`$key] }
& '$core' @forward
"@
    Set-Item -LiteralPath "function:global:$Name" -Value ([scriptblock]::Create($guard))
}
