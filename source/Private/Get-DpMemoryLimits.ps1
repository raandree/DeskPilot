function Get-DpMemoryLimits {
    <#
    .SYNOPSIS
        Returns the character caps for the two Memory stores.
    .DESCRIPTION
        The User Profile and Agent Memory are injected into every Turn's system
        prompt, so they are bounded to keep the token cost honest and to force
        curation. This is the single source of truth for both caps, shared by the
        system-prompt injection, the memory routes, and the extraction cleaner.
        Chosen a few times larger than a minimalist tiny-budget design so a
        knowledge worker's profile and the agent's learned notes have room, while
        the combined worst case (~20,000 chars / ~5,000 tokens) still stays a small
        fraction of a modern model's context window.
    .OUTPUTS
        System.Collections.Hashtable with keys userProfile and agentMemory
        (character counts).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{
        userProfile = 8000
        agentMemory = 12000
    }
}
