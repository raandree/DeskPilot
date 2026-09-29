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

        note and noteCount bound the structured store: one fact per note, and a
        store that cannot grow without end. They exist because a note is now
        attributable - it carries its own origin, scope and timestamps - and an
        unbounded note or an unbounded list would make the recall projection, not
        the caps, decide what reaches the Model.
    .OUTPUTS
        System.Collections.Hashtable with keys userProfile, agentMemory, note,
        noteCount and learnedPerScope (character counts, except the counts).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{
        userProfile = 8000
        agentMemory = 12000
        # One durable fact per note. A note longer than this is prose, not a fact,
        # and prose is what made the old single blob impossible to attribute.
        note        = 1000
        # 200 notes x 1,000 chars is far more than the Agent Memory cap, so the
        # recall projection is always the binding limit; this one only stops the
        # store itself from growing without end.
        noteCount   = 200
        # How many learned notes one scope may hold. A single Conversation must
        # not be able to fill the whole store with what it alone inferred.
        learnedPerScope = 50
    }
}
