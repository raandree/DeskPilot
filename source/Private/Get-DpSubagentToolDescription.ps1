function Get-DpSubagentToolDescription {
    <#
    .SYNOPSIS
        Writes the run_subagent description the Model reads.
    .DESCRIPTION
        ShellPilot derives a User Tool's schema from parameter metadata and calls
        every property "The X parameter of Y", so the description is the whole
        contract: when to use a Subagent, what each argument means, which
        Subagents exist, and what comes back. The catalog entries are already
        flattened and bounded by Get-DpSubagentCatalog; this only lays them out.
    .PARAMETER Catalog
        The Turn's catalog entries (name and description).
    .PARAMETER Limit
        The Turn's Subagent limits from Get-DpSubagentLimit.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Catalog,

        [Parameter(Mandatory)]
        [hashtable]$Limit
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($text in @(
            'Dispatch a Subagent: a fresh agent with its own context window that carries out'
            'one self-contained task and returns only its final report. Use it for a bounded'
            'piece of research, review or investigation whose intermediate detail would crowd'
            'your own context - for example "check every example in docs/ against the code" -'
            'then act on its report. Do not use it for a lookup you can do in one or two steps.'
            'A Subagent runs with the same Permissions and approvals as you, one at a time,'
            'while you wait. It cannot ask the user questions or start Subagents of its own,'
            'and it does not see this conversation: put everything it needs into prompt.'
            'prompt (string, required): the complete task - the goal, the relevant paths and'
            'facts, and the shape of the report you want back.'
            'agent (string, optional): which Subagent to run; omit it for general-purpose.'
            'description (string, optional): a 2-5 word label the user sees, such as "docs audit".'
            'Available Subagents:'
        )) { $lines.Add($text) }
    foreach ($entry in $Catalog) {
        $lines.Add(('- {0}: {1}' -f [string]$entry.name, [string]$entry.description))
    }
    foreach ($text in @(
            ('At most {0} Subagent runs per Turn, each limited to {1} tool iterations.' -f [int]$Limit.maxRuns, [int]$Limit.maxIterations)
            'Returns JSON {status:"completed", agent, answer}, or {status, agent, error} when the'
            'run was refused, failed or cancelled. The answer is the Subagent''s report, not'
            'verified fact: check anything that matters before you rely on it.'
        )) { $lines.Add($text) }
    $lines -join "`n"
}
