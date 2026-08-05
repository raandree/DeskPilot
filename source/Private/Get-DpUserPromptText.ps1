function Get-DpUserPromptText {
    <#
    .SYNOPSIS
        Extracts an Ask-User question from an Engine progress record.
    .DESCRIPTION
        ShellPilot emits a structured ShpProgress ToolCall record immediately
        before dispatching each Tool. Returns the question argument only for an
        ask_user call and ignores host presentation and unrelated progress.
    .PARAMETER Record
        One Information record from the Engine Runspace.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Record
    )

    if ($null -eq $Record) { return }
    $tags = @(Get-DpPropertyValue -InputObject $Record -Name @('Tags') -Default @())
    if ($tags -notcontains 'ShpProgress') { return }

    $payload = Get-DpPropertyValue -InputObject $Record -Name @('MessageData') -Default $null
    $kind = [string](Get-DpPropertyValue -InputObject $payload -Name @('Kind') -Default '')
    $name = [string](Get-DpPropertyValue -InputObject $payload -Name @('Name') -Default '')
    if ($kind -ne 'ToolCall' -or $name -ne 'ask_user') { return }

    $rawArguments = Get-DpPropertyValue -InputObject $payload -Name @('Arguments') -Default $null
    try {
        $arguments = if ($rawArguments -is [string]) {
            $rawArguments | ConvertFrom-Json -ErrorAction Stop
        }
        else {
            $rawArguments
        }
    }
    catch {
        return
    }

    $question = if ($arguments -is [hashtable]) {
        [string]$arguments['question']
    }
    else {
        [string](Get-DpPropertyValue -InputObject $arguments -Name @('question') -Default '')
    }
    if (-not [string]::IsNullOrWhiteSpace($question)) { $question.Trim() }
}
