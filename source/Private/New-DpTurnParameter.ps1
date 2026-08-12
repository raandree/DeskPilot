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
    .PARAMETER Image
        Paths to image Attachments passed through the Engine's native Image
        parameter for Vision-capable Models.
    .PARAMETER History
        The Conversation history array ({ role, content } items); may be empty.
    .PARAMETER Settings
        The current Settings hashtable.
    .PARAMETER Model
        Optional Conversation-pinned Model id that overrides Settings.model.
    .PARAMETER AgentMemory
        Durable notes the agent has curated across past conversations, injected as
        fenced reference background rather than as fresh instructions.
    .PARAMETER AlwaysOnInstruction
        The composed bodies of instruction files whose applyTo is unconditional,
        from Get-DpAlwaysOnInstruction. Passed in rather than read here so this
        function stays free of disk I/O and the read happens once per Turn.
    .PARAMETER WorkspaceContext
        The composed description of the Workspace Folder - branch, working-tree
        state and a bounded file tree - from Get-DpWorkspaceContext. Passed in for
        the same reason as AlwaysOnInstruction: the disk and git reads happen once
        per Turn, in Invoke-DpTurn, while the Engine Runspace is idle.
    .PARAMETER ModelReasoningEfforts
        The reasoning efforts the effective Model advertises support for. The
        reasoning-effort Setting is only forwarded as -ReasoningEffort when the
        effective Model lists it here; a Model that supports no reasoning effort
        (an empty list) or an unknown Model has the Setting suppressed, so the
        Engine never sends reasoning_effort to a Model that rejects it with an
        HTTP 400 (invalid_reasoning_effort).
    .PARAMETER McpSupported
        Whether the resolved Engine understands MCP at all. -DisableMcp arrived in
        ShellPilot 0.4.0-preview0007 and DeskPilot runs against whichever Engine
        the machine has, so the switch is only ever sent to an Engine that has it -
        an unknown parameter name would fail the whole Turn.
    .PARAMETER McpContext
        DeskPilot's own MCP position, from Get-DpMcpContext. Passed in for the same
        reason as WorkspaceContext: the Engine is asked once per Turn, in
        Invoke-DpTurn, while its Runspace is idle.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [AllowEmptyCollection()]
        [string[]]$Image = @(),

        [object[]]$History,

        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [string]$Model,

        [string]$AgentSystemPrompt,

        [string]$AgentMemory,

        [string]$AlwaysOnInstruction,

        [string]$WorkspaceContext,

        [string[]]$ModelReasoningEfforts = @(),

        [switch]$McpSupported,

        [string]$McpContext
    )

    $params = @{ Prompt = $Prompt }

    if ($Image.Count -gt 0) { $params.Image = $Image }
    if ($History -and $History.Count -gt 0) { $params.History = $History }

    $effectiveModel = if ($Model) { $Model } elseif ($Settings.model) { $Settings.model } else { $null }
    if ($effectiveModel) { $params.Model = $effectiveModel }

    $perm = $Settings.permissions
    if (-not $perm.browsing) { $params.DisableBrowsing = $true }
    if (-not $perm.file) { $params.DisableFileAccess = $true }
    if (-not $perm.terminal) { $params.DisableTerminal = $true }
    if (-not $perm.askUser) { $params.DisableUserPrompts = $true }
    if (-not $perm.userTools) { $params.DisableUserTools = $true }
    # Attached MCP servers stay attached; -DisableMcp withholds their tools for this
    # one Turn. Suppressing the Permission is deliberately not the same as detaching
    # the server: the process the user started keeps running and the panel keeps
    # reporting it, which is what the Permission switches are for everywhere else.
    if ($McpSupported -and $Settings.permissions.ContainsKey('mcp') -and -not $perm.mcp) { $params.DisableMcp = $true }

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

    # Instruction files whose applyTo is unconditional. The Engine offers every
    # instruction as a catalog entry plus a load_instruction tool, which works for
    # an instruction that only sometimes applies and fails for one that always
    # does: the model has to choose to fetch the body, and measurably often does
    # not, so a mandatory instruction silently stops being in force. Pushing the
    # body is what puts it back in force. Scoped instructions stay in the catalog.
    if (-not [string]::IsNullOrWhiteSpace($AlwaysOnInstruction)) {
        $systemParts.Add($AlwaysOnInstruction.Trim())
    }

    # The model cannot ration what it cannot see: without this it works as if the
    # budget were infinite and is then cut off mid-investigation.
    if ($Settings.maxToolIterations) {
        $systemParts.Add(('You have at most {0} tool-calling iterations for this task. Prefer decisive checks over exhaustive exploration, and if you are running short, report what you have established and what remains rather than stopping mid-investigation.' -f [int]$Settings.maxToolIterations))
    }

    # Same reason, for a question the model otherwise answers from whatever
    # mcp.json it can find on disk - which belongs to some other program.
    if ($McpSupported -and -not [string]::IsNullOrWhiteSpace($McpContext)) {
        $systemParts.Add($McpContext.Trim())
    }

    if ([bool]$perm.askUser -and [bool]$perm.userTools) {
        $systemParts.Add(@'
When you need two or more related pieces of information, or one question with
known answer choices, call ask_questions. Always bundle related questions that
are currently known into ONE call. Do not call ask_user repeatedly. Use the
built-in ask_user only for one spontaneous, free-text clarification.

Also call ask_questions when the user asks to be offered a choice rather than
told something - "give me a list to choose from", "what are my options", "which
should I use". A list written out in your answer is only readable; asking it as a
Questionnaire is what makes it selectable, and the user is asking to select. Do
not use it to confirm something you can simply do, or to ask what you can
reasonably infer - a wizard in place of an answer is worse than the answer.

Put this compact JSON string in the ask_questions Questionnaire argument:
{"title":"Optional short title","questions":[{"header":"Short topic","question":"Complete question","options":[{"label":"Choice","description":"Optional detail"}],"multiSelect":false,"allowFreeformInput":true}]}

Use 1-10 questions. Use options when the answer has useful known choices. Set
multiSelect true only when several choices may be selected. Set
allowFreeformInput true only when a custom answer is valid; for a text-only
question use an empty options array and true. The returned answer is either a
plain string for a legacy one-question prompt or JSON shaped as
{"answers":[{"header":"...","selectedOptions":["..."],"freeText":"..."}]}.
'@)
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

    # What is actually in that folder. Naming the path tells the model where it is
    # standing but nothing about what is there, so the branch, the working-tree
    # state and a bounded file tree are stated up front rather than left to be
    # bought back one discovery tool call at a time.
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceContext)) {
        $systemParts.Add($WorkspaceContext.Trim())
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
