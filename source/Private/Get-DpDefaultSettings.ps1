function Get-DpDefaultSettings {
    <#
    .SYNOPSIS
        Returns the default DeskPilot Settings object.
    .DESCRIPTION
        Produces a fresh hashtable of default Settings used by the Host Server.
        Terminal Permission defaults off because it is the highest-risk Tool for
        a non-technical user.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $copilot = Get-DpCopilotDefaults

    @{
        model             = $null
        permissions       = @{
            browsing  = $true
            file      = $true
            terminal  = $false
            askUser   = $true
            userTools = $true
            # Driving a live page is a different authority from reading one
            # DeskPilot fetched, so it is its own Permission and browsing does
            # not imply it. Off by default: it starts a real browser, and the
            # first workflow should be something the user asked for.
            browserAutomation = $false
            # Attached MCP servers contribute tools to every Turn. On by default
            # because it is inert until the user attaches one: the Engine discovers
            # nothing, so an empty mcpServers list means no MCP tools exist at all.
            mcp       = $true
        }
        projects          = @()
        # MCP servers the user configured. The Engine holds registrations only for
        # the life of a session and refuses to discover a configuration file on its
        # own, so this list is the durable record and Sync-DpMcpServer carries it
        # into the Engine Runspace at startup and on every edit. Environment values
        # are never stored here - only variable names (see ConvertTo-DpMcpServer).
        mcpServers        = @()
        selectedProjectId = $null
        workspaceFolder   = $null
        agentsRoot        = $copilot.agentsRoot
        selectedAgent     = $null
        skillRoots        = @($copilot.skillRoots)
        instructionRoots  = @($copilot.instructionRoots)
        promptRoots       = @($copilot.promptRoots)
        reasoningEffort   = $null
        showThinking      = $false
        taskTracking      = $true
        # The Engine offers instruction files as a catalog and expects the model to
        # fetch a body with load_instruction. For an instruction that applies to
        # everything that is a coin flip the model often loses, so the bodies of
        # unconditional instructions are pushed into the system prompt instead. Off
        # buys back the prompt tokens on a tight context window.
        pushInstructions  = $true
        # The Engine's system prompt names the Workspace Folder and says nothing
        # about what is in it, so the model has to buy the branch, the working-tree
        # state and the file tree back with discovery tool calls - and often does
        # not bother. Off trades the tree's prompt tokens back on a huge monorepo.
        workspaceContext  = $true
        # A per-Turn ordered JSONL record of what actually happened - tool calls,
        # narration and task updates in sequence - for debugging a Turn that went
        # wrong and for measuring one against another. Off because it is a
        # diagnostic and it writes files; retention prunes the folder on every
        # write, so it cannot grow without bound once it is on.
        turnTranscript    = $false
        preferences       = $null
        referenceFiles    = @()
        # File types the user chose to open with their own program instead of
        # DeskPilot's viewer (lowercase, leading dot). Empty by default: the choice
        # is only ever remembered when the user ticks the box in the question, and
        # an executable or script type is never accepted here.
        externalOpenTypes = @()
        # Ask before every Terminal command the safe-list does not cover.
        # DeskPilot removes the Engine's own run_command (-DisableTerminal) and
        # registers its own, which blocks on the same bridge ask_questions uses -
        # so no command has run when the question appears. Off until the browser
        # surface ships: with the Setting on and no way to answer, a Turn would
        # park until the timeout for every unrecognised command.
        perCallApproval   = $false
        terminalExecution = (ConvertTo-DpTerminalExecution -InputObject @{})
        # An unanswered approval holds the single Engine Runspace, so it fails
        # closed after this many minutes rather than blocking every queued run.
        approvalTimeoutMinutes = 15
        # Commands the user added to the shipped safe-list. Added only from
        # Settings, never from an approval prompt: "add to safe list" beside a
        # prompt is the button a tired user presses, and this is a security
        # boundary. Each entry is { command, match } where match is exact or prefix.
        safeCommands      = @()
        costBudgetUSD     = 0.0
        # A serious agentic task - audit a repository, run a build, diagnose what it
        # reports - routinely needs more than the Engine's own default of 25, and
        # running out costs the whole Turn.
        maxToolIterations = 50
        # Repeat a failed Engine call only before any response or Tool Activity has
        # streamed. Two retries preserve the existing three-attempt policy; zero
        # disables automatic retries, while higher values tolerate a noisy service.
        responseRetryCount = 2
        # Memory & context. When autoCompaction is on, a Conversation whose last
        # Turn filled its Model context window to at least compactionThreshold is
        # summarised automatically after the Turn (the same summarise-and-keep-tail
        # the manual Compact action performs), so a long Conversation keeps working
        # instead of overflowing the window. compactionKeepRecent is how many recent
        # history entries stay verbatim (the rest are summarised). Defaults: on, at
        # 80% full, keeping the last 4 entries.
        autoCompaction       = $true
        compactionThreshold  = 0.8
        compactionKeepRecent = 4
        # Persistent memory. When memoryLearning is on, after a Turn DeskPilot runs
        # a throttled, best-effort pure-reasoning pass that folds durable facts from
        # the conversation into the agent's Memory (see Get-DpMemoryLimits). The
        # User Profile is the manual preferences block above; the Agent Memory store
        # lives in agent-memory.json, not in Settings.
        memoryLearning       = $true
        # Updates. The Host Server polls the PowerShell Gallery for a newer
        # DeskPilot every updateCheckIntervalMinutes minutes (and on demand); the
        # newest stable release is offered by default. updateIncludePrereleases
        # opts into preview releases - and a preview update also accepts a preview
        # ShellPilot. The update is only ever applied on explicit user consent and
        # takes effect on the next launch (see Invoke-DpSelfUpdate).
        updateCheckIntervalMinutes = 5
        updateIncludePrereleases   = $false
        # Intercom: remote control from a phone over a Telegram bot (spec 110).
        # Off by default, and inert until a bot token is stored (separately, in
        # intercom.secret - never here) and one chat id is allow-listed. A remote
        # message can only act on a Project whose own intercom flag is on.
        #
        # allowGroupChat widens that allow-list to shared group chats. It is a
        # deliberate second switch rather than just an empty list, because a
        # group's membership is Telegram's to change: everyone in it, now and
        # later, gets the same control as the operator. Both it and at least one
        # groupChatIds entry must be set before a group message is accepted.
        intercom                   = @{
            enabled                = $false
            chatId                 = $null
            allowGroupChat         = $false
            groupChatIds           = @()
            # Whether a group may approve a Terminal command. A third switch, not a
            # consequence of the second: letting a group instruct DeskPilot and
            # letting a group authorise a command it has been warned about are
            # different amounts of trust, and the phone gives the approver less to
            # look at than the window does.
            groupApproval          = $false
            heartbeatMinutes       = 5
            stallMinutes           = 5
            questionTimeoutMinutes = 60
            maxMessagesPerHour     = 60
            notifyOnDone           = $true
            sendFinalAnswer        = $true
            maxAttachmentMB        = 20
        }
    }
}
