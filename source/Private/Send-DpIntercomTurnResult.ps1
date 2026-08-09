function Send-DpIntercomTurnResult {
    <#
    .SYNOPSIS
        Reports how a remote-initiated Turn ended.
    .DESCRIPTION
        Reads the Turn's outcome off the Conversation and pushes it to the phone:
        finished, stopped, or failed before producing anything.

        Every optional field is read through Get-DpPropertyValue. The module runs
        under Set-StrictMode -Version Latest, where a missing hashtable key is a
        terminating error, not $null - so 'stopped', which only a cancelled Turn
        carries, cannot be touched directly. Reading it the direct way threw here
        once, after the Turn had already run, and the operator was told nothing.
    .PARAMETER Conversation
        The Conversation the Turn ran against.
    .PARAMETER MessagesBefore
        How many Messages the Conversation held before the Turn, used to tell a
        Turn that produced nothing from one that answered.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Conversation,

        [int]$MessagesBefore = 0
    )

    $settings = $script:DeskPilot.Settings.intercom
    $title = [string]$Conversation.title
    $last = if ($Conversation.messages.Count -gt 0) { $Conversation.messages[$Conversation.messages.Count - 1] } else { $null }
    $role = [string](Get-DpPropertyValue -InputObject $last -Name @('role') -Default '')

    # Invoke-DpTurn records the user Message first and only adds an assistant
    # Message when the Engine answered, so a trailing user Message means the Turn
    # failed before producing anything.
    if (-not $last -or $role -ne 'assistant' -or $Conversation.messages.Count -le $MessagesBefore) {
        $null = Send-DpIntercomMessage -Title 'The job failed.' -Line @(
            "Conversation: $title",
            'Open DeskPilot to see what went wrong.'
        ) -Kind 'failed'
        return
    }

    if ([bool](Get-DpPropertyValue -InputObject $last -Name @('stopped') -Default $false)) {
        $null = Send-DpIntercomMessage -Title 'The job was stopped.' -Line @("Conversation: $title") -Kind 'stopped'
        return
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Conversation: $title")
    $lines.Add("Took: $([int]([double](Get-DpPropertyValue -InputObject $last -Name @('durationMs') -Default 0) / 1000)) s")

    $activity = Get-DpPropertyValue -InputObject $last -Name @('activity') -Default $null
    if ($activity) {
        $written = @(Get-DpPropertyValue -InputObject $activity -Name @('filesWritten') -Default @()).Count
        $commands = @(Get-DpPropertyValue -InputObject $activity -Name @('commandsRun') -Default @()).Count
        if ($written -gt 0) { $lines.Add("Files changed: $written") }
        if ($commands -gt 0) { $lines.Add("Commands run: $commands") }
    }

    $sendParams = @{
        Title = 'Done.'
        Line  = @($lines.ToArray())
        Kind  = 'done'
    }
    if ([bool]$settings.sendFinalAnswer) {
        $answer = [string](Get-DpPropertyValue -InputObject $last -Name @('text') -Default '')
        if (-not [string]::IsNullOrWhiteSpace($answer)) { $sendParams.Body = $answer }
    }
    $null = Send-DpIntercomMessage @sendParams
}
