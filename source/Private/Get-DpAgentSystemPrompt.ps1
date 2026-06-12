function Get-DpAgentSystemPrompt {
    <#
    .SYNOPSIS
        Returns the system-prompt body of a selected Agent.
    .DESCRIPTION
        Resolves the Agent whose id (file name) matches Id under Root and returns
        its Markdown body (the frontmatter stripped) to use as the Turn's system
        prompt. Returns $null when the root or Agent is missing, so a stale
        selection simply yields no system prompt rather than an error.
    .PARAMETER Root
        The Agents folder.
    .PARAMETER Id
        The Agent id (its file name, for example 'tax-researcher.agent.md').
    .OUTPUTS
        System.String, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Root,
        [string]$Id
    )

    if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($Id)) { return $null }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $null }

    $path = Join-Path $Root $Id
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }

    $meta = Read-DpAgentFile -Path $path
    if ($meta.body) { $meta.body } else { $null }
}
