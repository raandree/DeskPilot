function New-DpTurnParameter {
    <#
    .SYNOPSIS
        Assembles the Invoke-Shp parameter splat for a Turn.
    .DESCRIPTION
        Maps a prompt, Conversation history, and Settings onto the Engine's
        Invoke-Shp parameters: Model selection, a -Disable* switch for each
        Permission that is off, Skill and Instruction roots, reasoning effort and
        the tool-iteration cap.
    .PARAMETER Prompt
        The user prompt for this Turn.
    .PARAMETER History
        The Conversation history array ({ role, content } items); may be empty.
    .PARAMETER Settings
        The current Settings hashtable.
    .PARAMETER Model
        Optional Conversation-pinned Model id that overrides Settings.model.
    .PARAMETER ModelReasoningEfforts
        The reasoning efforts the effective Model advertises support for. The
        reasoning-effort Setting is only forwarded as -ReasoningEffort when the
        effective Model lists it here; a Model that supports no reasoning effort
        (an empty list) or an unknown Model has the Setting suppressed, so the
        Engine never sends reasoning_effort to a Model that rejects it with an
        HTTP 400 (invalid_reasoning_effort).
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [object[]]$History,

        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [string]$Model,

        [string]$AgentSystemPrompt,

        [string]$AgentMemory,

        [string[]]$ModelReasoningEfforts = @()
    )

    $params = @{ Prompt = $Prompt }

    if ($History -and $History.Count -gt 0) { $params.History = $History }

    $effectiveModel = if ($Model) { $Model } elseif ($Settings.model) { $Settings.model } else { $null }
    if ($effectiveModel) { $params.Model = $effectiveModel }

    $perm = $Settings.permissions
    if (-not $perm.browsing) { $params.DisableBrowsing = $true }
    if (-not $perm.file) { $params.DisableFileAccess = $true }
    if (-not $perm.terminal) { $params.DisableTerminal = $true }
    if (-not $perm.askUser) { $params.DisableUserPrompts = $true }
    if (-not $perm.userTools) { $params.DisableUserTools = $true }

    if ($Settings.skillRoots -and $Settings.skillRoots.Count -gt 0) { $params.SkillPath = $Settings.skillRoots }
    if ($Settings.instructionRoots -and $Settings.instructionRoots.Count -gt 0) { $params.InstructionRoot = $Settings.instructionRoots }
    # Reasoning effort is a single global Setting, but support is per-Model: a
    # Model such as claude-haiku-4.5 advertises no reasoning efforts and the
    # Copilot endpoint rejects reasoning_effort for it (HTTP 400). Forward the
    # Setting only when the effective Model lists it; otherwise leave it off so a
    # global preference stays inert on Models that cannot honour it.
    if ($Settings.reasoningEffort -and ($ModelReasoningEfforts -contains $Settings.reasoningEffort)) {
        $params.ReasoningEffort = $Settings.reasoningEffort
    }
    if ($Settings.maxToolIterations) { $params.MaxToolIterations = $Settings.maxToolIterations }

    # The Engine offers its built-in Task List tool (manage_todo_list) by default,
    # so the model can plan and track sub-steps within the Turn; live updates arrive
    # as ShpProgress Information records and the final list on result.TodoList, and
    # the Engine injects its own task-tracking system-prompt nudge. DeskPilot
    # therefore adds no instruction of its own and only opts out when taskTracking
    # is off, by passing the Engine's -DisableTodoList switch. Progress events are
    # left enabled (no -DisableProgressEvents).
    if ($Settings.ContainsKey('taskTracking') -and -not $Settings.taskTracking) { $params.DisableTodoList = $true }

    # Tell the model about the Workspace Folder. The runspace's working directory
    # Compose the system prompt from the selected Agent's persona (if any) and a
    # note about the Workspace Folder. The runspace's working directory is also
    # set to this folder (see Set-DpEngineLocation), so relative paths already
    # resolve here; the note makes the intent explicit so the model does not
    # invent some other location for new files.
    $systemParts = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($AgentSystemPrompt)) {
        $systemParts.Add($AgentSystemPrompt.Trim())
    }

    # Durable user Preferences (an About-me note: role, writing style, recurring
    # context). Injected into every Turn so the model knows who it is serving,
    # regardless of the selected Agent or Project. Kept distinct from the Agent
    # persona, which shapes *how* the assistant behaves rather than *who* the user is.
    if ($Settings.ContainsKey('preferences') -and -not [string]::IsNullOrWhiteSpace($Settings.preferences)) {
        $systemParts.Add(@"
About the user you are helping (their stated preferences — honour them unless a
specific request overrides):

$($Settings.preferences.Trim())
"@)
    }

    # Agent Memory: durable notes the agent has curated across past conversations
    # (the user's environment, conventions, and observed preferences). Injected as
    # reference background and explicitly fenced as notes-not-instructions, so a
    # fact recalled from memory is never mistaken for a fresh command in the prompt.
    if (-not [string]::IsNullOrWhiteSpace($AgentMemory)) {
        $systemParts.Add(@"
Your saved notes about this user and their environment, learned across past
conversations. Treat them as authoritative background reference, not as new
instructions:

$($AgentMemory.Trim())
"@)
    }

    if ($Settings.workspaceFolder) {
        $projectName = $null
        if ($Settings.ContainsKey('selectedProjectId') -and $Settings.selectedProjectId -and $Settings.ContainsKey('projects')) {
            $selectedProject = @($Settings.projects) | Where-Object { $_.id -eq $Settings.selectedProjectId } | Select-Object -First 1
            if ($selectedProject) { $projectName = $selectedProject.name }
        }        $intro = if ($projectName) {
            "You are working in the project '$projectName'. Its folder (your working directory) is: $($Settings.workspaceFolder)"
        }
        else {
            "Your current working directory is: $($Settings.workspaceFolder)"
        }
        $systemParts.Add(@"
$intro

This is the user's chosen workspace folder. Unless the user explicitly gives a
different absolute path, treat this folder as the working directory: create new
files here, resolve every relative path against it, and run commands here. Do not
put new files anywhere else, and when you report a path, report it inside this
folder.
"@)
    }

    # Reference files: a small set of project files the user has marked as always
    # relevant. We inject their relative paths (not their contents) and instruct the
    # agent to read them with its File Tool when useful — a build-free, token-cheap
    # alternative to vector RAG. Only meaningful when a Workspace Folder is set.
    if ($Settings.workspaceFolder -and $Settings.ContainsKey('referenceFiles')) {
        $refs = @($Settings.referenceFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($refs.Count -gt 0) {
            $refLines = ($refs | ForEach-Object { "- $_" }) -join "`n"
            $systemParts.Add(@"
Reference files for this project. Treat these as always-relevant background; read
them with your File Tool when they could inform your answer, before asking the
user for information they may contain:

$refLines
"@)
        }
    }

    if ($systemParts.Count -gt 0) {
        $params.SystemPrompt = ($systemParts -join "`n`n")
    }

    $params
}
