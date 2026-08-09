function Invoke-DpRouteHandler {
    <#
    .SYNOPSIS
        Executes the named API route handler and writes its response.
    .DESCRIPTION
        Implements every DeskPilot API route. JSON routes write their response
        directly; the streaming routes (authStart, postMessage) hand off to the
        SSE runners.
    .PARAMETER Name
        The route name from the route table.
    .PARAMETER RouteParams
        Captured path parameters (for example the Conversation id).
    .PARAMETER Body
        The parsed JSON request body, or $null.
    .PARAMETER Stream
        The network stream to write the response to.
    .PARAMETER Request
        The raw request hashtable (Headers, BodyBytes); used by handlers that
        need the raw bytes (for example the multipart Upload handler).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [hashtable]$RouteParams = @{},

        [object]$Body,

        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream,

        [hashtable]$Request
    )

    $state = $script:DeskPilot

    switch ($Name) {
        'health' {
            Write-DpResponse -Stream $Stream -Json @{
                status           = 'ok'
                version          = $state.Version
                engineImported   = $state.Engine.Imported
                engineError      = $state.Engine.ImportError
                authenticated    = (Test-Path -LiteralPath $state.Engine.TokenPath)
                model            = $state.Settings.model
                engineModulePath = $state.Engine.ModulePath
            }
        }
        'authStatus' {
            Write-DpResponse -Stream $Stream -Json @{ authenticated = (Test-Path -LiteralPath $state.Engine.TokenPath) }
        }
        'authStart' {
            # force=true re-runs the device flow even when a stale token file is
            # present (an expired sign-in), so a re-auth actually replaces it.
            $force = [bool](Get-DpPropertyValue -InputObject $Body -Name @('force') -Default $false)
            Invoke-DpAuthFlow -Stream $Stream -Force:$force
        }
        'models' {
            try {
                $models = Invoke-DpEngineCommand -Command 'Get-ShpModel'
                $default = $null
                try { $default = Invoke-DpEngineCommand -Command 'Get-ShpDefault' | Select-Object -First 1 } catch { $null = $_ }
                $list = foreach ($model in $models) {
                    @{
                        id                     = [string](Get-DpPropertyValue -InputObject $model -Name @('Id', 'id', 'Name') -Default '')
                        maxContextWindowTokens = [int](Get-DpPropertyValue -InputObject $model -Name @('MaxContextWindowTokens', 'ContextWindow', 'MaxContextWindow') -Default 0)
                        maxOutputTokens        = [int](Get-DpPropertyValue -InputObject $model -Name @('MaxOutputTokens', 'MaxOutput') -Default 0)
                        reasoningEfforts       = @(Get-DpPropertyValue -InputObject $model -Name @('ReasoningEfforts') -Default @())
                        vision                 = [bool](Get-DpPropertyValue -InputObject $model -Name @('Vision', 'SupportsVision') -Default $false)
                    }
                }
                $defaultId = if ($default -is [string]) { $default } else { [string](Get-DpPropertyValue -InputObject $default -Name @('Id', 'Model', 'Name') -Default $state.Settings.model) }
                # Cache the capability list so a Turn can send -ReasoningEffort only
                # to a Model that advertises support (see Get-DpModelReasoningEfforts).
                $state.Models = @($list)
                $state.DefaultModel = $defaultId
                Write-DpResponse -Stream $Stream -Json @{ default = $defaultId; models = @($list) }
            }
            catch {
                # An expired or missing GitHub token surfaces here as a 401/403
                # while the Engine exchanges the token. Answer with an actionable
                # auth_required so the UI can re-trigger the device-code flow,
                # rather than a generic engine error the user cannot act on.
                if (Test-DpAuthError -ErrorRecord $_) {
                    Write-DpResponse -Stream $Stream -Status 401 -Json @{ error = @{ code = 'auth_required'; reauth = $true; message = 'Your GitHub Copilot sign-in has expired or is missing. Sign in again to continue.' } }
                }
                else {
                    Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'engine_unavailable'; message = "Could not list models: $_" } }
                }
            }
        }
        'getSettings' {
            Write-DpResponse -Stream $Stream -Json $state.Settings
        }
        'putSettings' {
            if ($null -eq $Body) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_body'; message = 'A Settings body is required.' } }
                return
            }
            try {
                $merged = Merge-DpSettings -Current $state.Settings -Patch $Body
                $state.Settings = $merged
                if ($state.DataDir) { Save-DpSettings -Settings $merged -Directory $state.DataDir }
                Write-DpResponse -Stream $Stream -Json $merged
            }
            catch {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_settings'; message = "$_" } }
            }
        }
        'agents' {
            # Resolve the effective Agents folder. When none is configured but the
            # conventional ~/.copilot/agents now exists (e.g. after CopilotAtelier
            # setup created the junction), adopt and persist it so the agents
            # appear - and a selected Agent reaches Turn assembly - without a
            # restart. A refresh (manual or the periodic client poll) picks this up.
            $root = Resolve-DpAgentsRoot -Settings $state.Settings
            if ($root -and $root -ne $state.Settings.agentsRoot) {
                $state.Settings.agentsRoot = $root
                if ($state.DataDir) { Save-DpSettings -Settings $state.Settings -Directory $state.DataDir }
            }
            $agentList = @(Get-DpAgentList -Root $root | ForEach-Object { @{ id = $_.id; name = $_.name; description = $_.description } })
            Write-DpResponse -Stream $Stream -Json @{ agents = $agentList; selected = $state.Settings.selectedAgent; root = $root }
        }
        'customizations' {
            Write-DpResponse -Stream $Stream -Json (Get-DpCustomizationList -Settings $state.Settings)
        }
        'createCustomization' {
            if ($null -eq $Body) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_body'; message = 'A category and name are required.' } }
                return
            }
            $category = [string](Get-DpPropertyValue -InputObject $Body -Name @('category') -Default '')
            $name = [string](Get-DpPropertyValue -InputObject $Body -Name @('name') -Default '')
            $root = [string](Get-DpPropertyValue -InputObject $Body -Name @('root') -Default '')
            try {
                $created = if ([string]::IsNullOrWhiteSpace($root)) {
                    New-DpCustomization -Settings $state.Settings -Category $category -Name $name
                }
                else {
                    New-DpCustomization -Settings $state.Settings -Category $category -Name $name -Root $root
                }
                Write-DpResponse -Stream $Stream -Status 201 -Json $created
            }
            catch {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'create_failed'; message = "$_" } }
            }
        }
        'customizationContent' {
            $category = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('category')) { [string]$Request.Query['category'] } else { '' }
            $requested = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('path')) { [string]$Request.Query['path'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($category) -or [string]::IsNullOrWhiteSpace($requested)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_request'; message = 'A category and path are required.' } }
                return
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpCustomizationContent -Settings $state.Settings -Category $category -Path $requested)
        }
        'saveCustomizationContent' {
            if ($null -eq $Body) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_body'; message = 'A category, path and text are required.' } }
                return
            }
            $category = [string](Get-DpPropertyValue -InputObject $Body -Name @('category') -Default '')
            $requested = [string](Get-DpPropertyValue -InputObject $Body -Name @('path') -Default '')
            $text = [string](Get-DpPropertyValue -InputObject $Body -Name @('text') -Default '')
            if ([string]::IsNullOrWhiteSpace($category) -or [string]::IsNullOrWhiteSpace($requested)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_request'; message = 'A category and path are required.' } }
                return
            }
            try {
                $saved = Save-DpCustomizationContent -Settings $state.Settings -Category $category -Path $requested -Text $text
                Write-DpResponse -Stream $Stream -Json $saved
            }
            catch {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'save_failed'; message = "$_" } }
            }
        }
        'fsList' {
            $requested = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('path')) { [string]$Request.Query['path'] } else { '' }
            Write-DpResponse -Stream $Stream -Json (Get-DpDirectoryListing -Path $requested)
        }
        'fsTree' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $requested = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('path')) { [string]$Request.Query['path'] } else { '' }
            Write-DpResponse -Stream $Stream -Json (Get-DpDirectoryEntries -Root $root -Path $requested)
        }
        'fsFile' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $requested = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('path')) { [string]$Request.Query['path'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($requested)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_path'; message = 'A file path is required.' } }
                return
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpFileContent -Root $root -Path $requested)
        }
        'gitStatus' {
            Write-DpResponse -Stream $Stream -Json (Get-DpGitStatus -Path $state.Settings.workspaceFolder)
        }
        'gitInit' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $init = Invoke-DpGitCommand -Path $root -Arguments @('init')
            if (-not $init.Ok) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'git_init_failed'; message = "git init failed: $($init.StdErr.Trim())" } }
                return
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpGitStatus -Path $root)
        }
        'gitCheckout' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $branch = [string](Get-DpPropertyValue -InputObject $Body -Name @('branch') -Default '')
            if ([string]::IsNullOrWhiteSpace($branch)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_branch'; message = 'A branch name is required.' } }
                return
            }
            # Only allow switching to a branch that already exists, validated against
            # the live branch list (the process call already prevents shell injection).
            $status = Get-DpGitStatus -Path $root
            if (-not $status.isRepo) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'not_a_repo'; message = 'This project is not a Git repository.' } }
                return
            }
            if (@($status.branches) -notcontains $branch) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'unknown_branch'; message = "Unknown branch '$branch'." } }
                return
            }
            $checkout = Invoke-DpGitCommand -Path $root -Arguments @('checkout', $branch)
            if (-not $checkout.Ok) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'checkout_failed'; message = $checkout.StdErr.Trim() } }
                return
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpGitStatus -Path $root)
        }
        'gitBranches' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $doFetch = $false
            if ($Request -and $Request.Query -and $Request.Query.ContainsKey('fetch')) {
                $fv = [string]$Request.Query['fetch']
                $doFetch = ($fv -eq '1' -or $fv -eq 'true')
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpBranchList -Path $root -Fetch:$doFetch)
        }
        'gitChanges' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            # The optional filter is newline-separated: a path can contain a comma
            # or a semicolon on every supported platform, but never a newline.
            $rawPaths = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('paths')) { [string]$Request.Query['paths'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($rawPaths)) {
                Write-DpResponse -Stream $Stream -Json (Get-DpGitChanges -Root $root)
            }
            else {
                $wanted = @($rawPaths -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                Write-DpResponse -Stream $Stream -Json (Get-DpGitChanges -Root $root -Paths $wanted)
            }
        }
        'gitCommit' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $message = [string](Get-DpPropertyValue -InputObject $Body -Name @('message') -Default '')
            if ([string]::IsNullOrWhiteSpace($message)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_message'; message = 'A commit message is required.' } }
                return
            }
            $paths = @()
            if ($Body -and $Body.PSObject.Properties['paths'] -and $Body.paths) { $paths = @($Body.paths | ForEach-Object { [string]$_ }) }
            $commit = if ($paths.Count -gt 0) {
                Invoke-DpGitCommit -Root $root -Message $message -Paths $paths
            }
            else {
                Invoke-DpGitCommit -Root $root -Message $message
            }
            if ($commit.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'commit_failed'; message = $commit.error }; result = $commit }
                return
            }
            # A committed file is a reviewed file: leaving it in the pending set
            # would keep telling the user it still needs a decision after they
            # saved it, and would offer an undo that now contradicts history.
            $commit.kept = 0
            if ($commit.committed -and @($commit.files).Count -gt 0) {
                $cleared = Remove-DpChangeEntry -Store $state.Changes -Root $root -Paths @($commit.files)
                $commit.kept = $cleared.cleared
                if ($cleared.cleared -gt 0 -and $state.DataDir) { Save-DpChangeStore -Store $state.Changes -Directory $state.DataDir }
            }
            Write-DpResponse -Stream $Stream -Json $commit
        }
        'gitCommitMessage' {
            # Suggest the one line the Save dialog asks for. A required free-text
            # field is exactly where the target user stalls, so the Model reads the
            # change set and writes it - on an explicit click, never automatically,
            # because it costs a Turn.
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            # This Turn shares the single Engine Runspace.
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'turn_running'; message = 'Another task is running; wait for it to finish.' } }
                return
            }
            $changes = Get-DpGitChanges -Root $root
            if ($changes.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'changes_failed'; message = $changes.error } }
                return
            }
            if ($changes.fileCount -eq 0) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'nothing_to_save'; message = 'Nothing has changed since the last save.' } }
                return
            }
            # Untracked files have no diff against HEAD, and an unborn HEAD has no
            # diff at all; the file list alone still describes those well enough.
            $diffResult = Invoke-DpGitCommand -Path $root -Arguments @('diff', 'HEAD', '--', '.')
            $diffText = if ($diffResult.Ok) { [string]$diffResult.StdOut } else { '' }
            $engineParams = @{
                Prompt             = New-DpCommitMessagePrompt -Files @($changes.files) -Diff $diffText
                DisableBrowsing    = $true
                DisableFileAccess  = $true
                DisableTerminal    = $true
                DisableUserPrompts = $true
                DisableUserTools   = $true
                DisableTodoList    = $true
            }
            if ($state.Settings.model) { $engineParams.Model = $state.Settings.model }
            $state.TurnRunning = $true
            try {
                $engineResult = Invoke-DpEngineCommand -Command 'Invoke-Shp' -Parameter $engineParams | Select-Object -Last 1
            }
            catch {
                $state.TurnRunning = $false
                Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'engine_error'; message = "The model could not suggest a description: $($_.Exception.Message)" } }
                return
            }
            $state.TurnRunning = $false
            $content = if ($engineResult) { [string]$engineResult.Content } else { '' }
            # A commit subject is the same shape as a Conversation title - one clean
            # line, capped - so it goes through the same cleaner.
            $suggestion = ConvertFrom-DpTitleResult -Text $content -MaxWords 12 -MaxLength 72
            if ([string]::IsNullOrWhiteSpace($suggestion)) {
                Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'no_suggestion'; message = 'The model did not return a usable description.' } }
                return
            }
            Write-DpResponse -Stream $Stream -Json @{ message = $suggestion; fileCount = $changes.fileCount }
        }
        'gitBranchCreate' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $branchName = [string](Get-DpPropertyValue -InputObject $Body -Name @('name') -Default '')
            $from = [string](Get-DpPropertyValue -InputObject $Body -Name @('from') -Default '')
            $checkout = [bool](Get-DpPropertyValue -InputObject $Body -Name @('checkout') -Default $true)
            $created = if ([string]::IsNullOrWhiteSpace($from)) {
                New-DpGitBranch -Root $root -Name $branchName -Checkout:$checkout
            }
            else {
                New-DpGitBranch -Root $root -Name $branchName -From $from -Checkout:$checkout
            }
            if ($created.error -and -not $created.created) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'branch_create_failed'; message = $created.error } }
                return
            }
            Write-DpResponse -Stream $Stream -Json $created
        }
        'gitBranchDelete' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $branchName = [string](Get-DpPropertyValue -InputObject $Body -Name @('name', 'branch') -Default '')
            if ([string]::IsNullOrWhiteSpace($branchName)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_branch'; message = 'A branch name is required.' } }
                return
            }
            $force = [bool](Get-DpPropertyValue -InputObject $Body -Name @('force') -Default $false)
            $deleteRemote = [bool](Get-DpPropertyValue -InputObject $Body -Name @('deleteRemote') -Default $false)
            $removed = Remove-DpGitBranch -Root $root -Name $branchName -Force:$force -DeleteRemote:$deleteRemote
            if ($removed.error) {
                # notMerged is a recoverable refusal, not a failure: answer 409 so the
                # UI can offer an explicit force instead of showing a dead end.
                $statusCode = if ($removed.notMerged) { 409 } else { 400 }
                Write-DpResponse -Stream $Stream -Status $statusCode -Json @{ error = @{ code = 'branch_delete_failed'; message = $removed.error; notMerged = $removed.notMerged }; result = $removed }
                return
            }
            Write-DpResponse -Stream $Stream -Json $removed
        }
        'gitSyncStatus' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $doFetch = $false
            if ($Request -and $Request.Query -and $Request.Query.ContainsKey('fetch')) {
                $fv = [string]$Request.Query['fetch']
                $doFetch = ($fv -eq '1' -or $fv -eq 'true')
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpGitSyncStatus -Path $root -Fetch:$doFetch)
        }
        'gitSync' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $action = [string](Get-DpPropertyValue -InputObject $Body -Name @('action') -Default 'sync')
            if ($action -notin @('pull', 'push', 'sync')) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_action'; message = "Unknown sync action '$action'." } }
                return
            }
            $autostash = [bool](Get-DpPropertyValue -InputObject $Body -Name @('autostash') -Default $false)
            $syncResult = Invoke-DpGitSync -Root $root -Action $action -Autostash:$autostash
            Write-DpResponse -Stream $Stream -Json $syncResult
        }
        'gitConflictPrompt' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $sync = Get-DpGitSyncStatus -Path $root
            if (-not $sync.isRepo) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'not_a_repo'; message = 'This project is not a Git repository.' } }
                return
            }
            $conflictFiles = @($sync.conflictFiles)
            $sourceBranch = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('branch')) { [string]$Request.Query['branch'] } else { '' }
            $targetBranch = if ($sync.branch) { $sync.branch } else { '' }
            $promptText = New-DpConflictPrompt -Files $conflictFiles -SourceBranch $sourceBranch -TargetBranch $targetBranch -Root $root
            Write-DpResponse -Stream $Stream -Json @{
                inMerge      = $sync.inMerge
                files        = $conflictFiles
                sourceBranch = $sourceBranch
                targetBranch = $targetBranch
                prompt       = $promptText
            }
        }
        'pendingChanges' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Json @{ files = @(); fileCount = 0; totalAdded = 0; totalDeleted = 0; undoable = $false; error = $null }
                return
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpChangePayload -Root $root -Entries @(Get-DpChangeEntry -Store $state.Changes -Root $root))
        }
        'keepChanges' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $paths = @()
            if ($Body -and $Body.PSObject.Properties['paths'] -and $Body.paths) { $paths = @($Body.paths | ForEach-Object { [string]$_ }) }
            $cleared = if ($paths.Count -gt 0) {
                Remove-DpChangeEntry -Store $state.Changes -Root $root -Paths $paths
            }
            else {
                Remove-DpChangeEntry -Store $state.Changes -Root $root
            }
            if ($state.DataDir) { Save-DpChangeStore -Store $state.Changes -Directory $state.DataDir }
            Write-DpResponse -Stream $Stream -Json @{
                kept      = $cleared.cleared
                remaining = $cleared.remaining
                changes   = (Get-DpChangePayload -Root $root -Entries @(Get-DpChangeEntry -Store $state.Changes -Root $root))
            }
        }
        'undoChanges' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $paths = @()
            if ($Body -and $Body.PSObject.Properties['paths'] -and $Body.paths) { $paths = @($Body.paths | ForEach-Object { [string]$_ }) }
            $entries = @(Get-DpChangeEntry -Store $state.Changes -Root $root)
            $undo = if ($paths.Count -gt 0) {
                Invoke-DpChangeUndo -Root $root -Entries $entries -Paths $paths
            }
            else {
                Invoke-DpChangeUndo -Root $root -Entries $entries
            }
            if ($undo.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'undo_failed'; message = $undo.error } }
                return
            }
            # Only stop tracking what actually went back; a file that could not be
            # restored stays in the set so the user can see it still needs a decision.
            $done = @(@($undo.restored) + @($undo.removed))
            if ($done.Count -gt 0) {
                $null = Remove-DpChangeEntry -Store $state.Changes -Root $root -Paths $done
                if ($state.DataDir) { Save-DpChangeStore -Store $state.Changes -Directory $state.DataDir }
            }
            Write-DpResponse -Stream $Stream -Json @{
                restored = @($undo.restored)
                removed  = @($undo.removed)
                skipped  = @($undo.skipped)
                changes  = (Get-DpChangePayload -Root $root -Entries @(Get-DpChangeEntry -Store $state.Changes -Root $root))
            }
        }
        'gitMergePreview' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $branch = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('branch')) { [string]$Request.Query['branch'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($branch)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_branch'; message = 'A branch name is required.' } }
                return
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpMergePreview -Root $root -Branch $branch)
        }
        'gitMerge' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $branch = [string](Get-DpPropertyValue -InputObject $Body -Name @('branch') -Default '')
            if ([string]::IsNullOrWhiteSpace($branch)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_branch'; message = 'A branch name is required.' } }
                return
            }
            $autofix = [bool](Get-DpPropertyValue -InputObject $Body -Name @('autofix') -Default $false)
            Write-DpResponse -Stream $Stream -Json (Invoke-DpGitMerge -Root $root -Branch $branch -Autofix:$autofix)
        }
        'gitMergePlan' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            # The conflict-resolution Turn runs synchronously on the shared Engine
            # Runspace; refuse to start it while another Turn is in flight.
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'turn_running'; message = 'Another task is running; wait for it to finish.' } }
                return
            }
            $conflict = Get-DpMergeConflict -Root $root
            if ($conflict.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'conflict_read_failed'; message = $conflict.error } }
                return
            }
            if (-not $conflict.inMerge) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'not_in_merge'; message = 'There is no merge in progress.' } }
                return
            }
            $textFiles = @($conflict.files | Where-Object { -not $_.binary })
            $binaryFiles = @($conflict.files | Where-Object { $_.binary })
            $sourceBranch = [string](Get-DpPropertyValue -InputObject $Body -Name @('branch') -Default '')
            if ([string]::IsNullOrWhiteSpace($sourceBranch)) { $sourceBranch = 'the merged branch' }
            $defaultBranch = Get-DpDefaultBranch -Path $root
            $plan = @{ ok = $true; resolutions = @(); notes = $null; error = $null }
            if ($textFiles.Count -gt 0) {
                $defaultForPrompt = if ($defaultBranch) { $defaultBranch } else { 'main' }
                $prompt = New-DpMergePlanPrompt -SourceBranch $sourceBranch -DefaultBranch $defaultForPrompt -Files $textFiles
                $engineParams = @{
                    Prompt             = $prompt
                    DisableBrowsing    = $true
                    DisableFileAccess  = $true
                    DisableTerminal    = $true
                    DisableUserPrompts = $true
                    DisableUserTools   = $true
                    DisableTodoList    = $true
                }
                if ($state.Settings.model) { $engineParams.Model = $state.Settings.model }
                $state.TurnRunning = $true
                try {
                    $engineResult = Invoke-DpEngineCommand -Command 'Invoke-Shp' -Parameter $engineParams | Select-Object -Last 1
                }
                catch {
                    $state.TurnRunning = $false
                    Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'engine_error'; message = "The model could not produce a merge plan: $($_.Exception.Message)" } }
                    return
                }
                $state.TurnRunning = $false
                $content = if ($engineResult) { [string]$engineResult.Content } else { '' }
                $plan = ConvertFrom-DpMergePlan -Text $content
            }
            Write-DpResponse -Stream $Stream -Json @{
                inMerge       = $true
                sourceBranch  = $sourceBranch
                defaultBranch = $defaultBranch
                textFiles     = @($textFiles | ForEach-Object { @{ rel = $_.rel; truncated = $_.truncated } })
                binaryFiles   = @($binaryFiles | ForEach-Object { @{ rel = $_.rel } })
                plan          = @{ ok = $plan.ok; resolutions = $plan.resolutions; notes = $plan.notes; error = $plan.error }
            }
        }
        'gitMergeApply' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $resolutions = @()
            if ($Body -and $Body.PSObject.Properties['resolutions'] -and $Body.resolutions) { $resolutions = @($Body.resolutions) }
            $binaryChoices = @()
            if ($Body -and $Body.PSObject.Properties['binaryChoices'] -and $Body.binaryChoices) { $binaryChoices = @($Body.binaryChoices) }
            $popStash = [bool](Get-DpPropertyValue -InputObject $Body -Name @('popStash') -Default $false)
            $result = Invoke-DpMergeApply -Root $root -Resolutions $resolutions -BinaryChoices $binaryChoices -PopStash:$popStash
            if ($result.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'merge_apply_failed'; message = $result.error }; result = $result }
                return
            }
            Write-DpResponse -Stream $Stream -Json $result
        }
        'gitMergeAbort' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $popStash = [bool](Get-DpPropertyValue -InputObject $Body -Name @('popStash') -Default $false)
            $result = Invoke-DpGitMergeAbort -Root $root -PopStash:$popStash
            if ($result.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'merge_abort_failed'; message = $result.error } }
                return
            }
            Write-DpResponse -Stream $Stream -Json $result
        }
        'gitMergeUndo' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $sha = [string](Get-DpPropertyValue -InputObject $Body -Name @('sha') -Default '')
            if ([string]::IsNullOrWhiteSpace($sha)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_sha'; message = 'A commit id is required.' } }
                return
            }
            $result = Invoke-DpGitMergeUndo -Root $root -Sha $sha
            if ($result.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'merge_undo_failed'; message = $result.error } }
                return
            }
            Write-DpResponse -Stream $Stream -Json $result
        }
        'gitCleanup' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $branch = [string](Get-DpPropertyValue -InputObject $Body -Name @('branch') -Default '')
            if ([string]::IsNullOrWhiteSpace($branch)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_branch'; message = 'A branch name is required.' } }
                return
            }
            $deleteRemote = [bool](Get-DpPropertyValue -InputObject $Body -Name @('deleteRemote') -Default $false)
            $pushDefault = [bool](Get-DpPropertyValue -InputObject $Body -Name @('pushDefaultBranch') -Default $false)
            $force = [bool](Get-DpPropertyValue -InputObject $Body -Name @('force') -Default $false)
            $result = Invoke-DpBranchCleanup -Root $root -Branch $branch -DeleteRemote:$deleteRemote -PushDefaultBranch:$pushDefault -Force:$force
            if ($result.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'cleanup_failed'; message = $result.error } }
                return
            }
            Write-DpResponse -Stream $Stream -Json $result
        }
        'fsMkdir' {
            if ($null -eq $Body) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_body'; message = 'A parent and name are required.' } }
                return
            }
            try {
                $parent = [string](Get-DpPropertyValue -InputObject $Body -Name @('parent') -Default '')
                $folderName = [string](Get-DpPropertyValue -InputObject $Body -Name @('name') -Default '')
                $created = New-DpDirectory -Parent $parent -Name $folderName
                Write-DpResponse -Stream $Stream -Json (Get-DpDirectoryListing -Path $created)
            }
            catch {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'mkdir_failed'; message = "$_" } }
            }
        }
        'usage' {
            Write-DpResponse -Stream $Stream -Json (Get-DpUsagePayload)
        }
        'exportSettings' {
            $backup = @{
                type        = 'deskpilot-settings-backup'
                version     = 1
                exportedUtc = [DateTime]::UtcNow.ToString('o')
                settings    = $state.Settings
            }
            Write-DpResponse -Stream $Stream -Json $backup
        }
        'importSettings' {
            if ($null -eq $Body) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_body'; message = 'A settings backup is required.' } }
                return
            }
            try {
                # Accept either a wrapped backup ({ type, settings }) or a bare
                # settings object. Restore replaces the current settings, so the
                # patch is merged onto the defaults rather than the live state.
                $payload = if ($Body.PSObject.Properties['settings'] -and $Body.settings) { $Body.settings } else { $Body }
                $patch = @{}
                foreach ($prop in $payload.PSObject.Properties) { $patch[$prop.Name] = $prop.Value }
                # version is metadata; workspaceFolder is derived from the selection.
                $patch.Remove('version') | Out-Null
                $patch.Remove('workspaceFolder') | Out-Null
                $restored = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch $patch
                $state.Settings = $restored
                if ($state.DataDir) { Save-DpSettings -Settings $restored -Directory $state.DataDir }
                Write-DpResponse -Stream $Stream -Json $restored
            }
            catch {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_backup'; message = "$_" } }
            }
        }
        'resetUsage' {
            $scope = if ($Body -and $Body.PSObject.Properties['scope'] -and $Body.scope) { [string]$Body.scope } else { 'lifetime' }
            switch ($scope) {
                'lifetime' {
                    $state.LifetimeUsage = New-DpLifetimeUsage
                    if ($state.DataDir) { Save-DpLifetimeUsage -Usage $state.LifetimeUsage -Directory $state.DataDir }
                }
                'session' {
                    $state.Usage = @{ promptTokens = 0; completionTokens = 0; totalTokens = 0; costUSD = 0.0; credits = 0.0; turns = 0; unpricedTurns = 0; byModel = @{} }
                }
                default {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_scope'; message = "Unknown reset scope '$scope'. Use 'lifetime' or 'session'." } }
                    return
                }
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpUsagePayload)
        }
        'getUpdate' {
            Write-DpResponse -Stream $Stream -Json (Get-DpUpdatePayload)
        }
        'checkUpdate' {
            # Manual "Check for updates": force an immediate Gallery check
            # off-thread (Update-DpUpdateCheckState starts a background job unless
            # one is already running) and return the current status; the SPA polls
            # GET /api/update until 'checking' clears.
            try { Update-DpUpdateCheckState -Force } catch { $null = $_ }
            Write-DpResponse -Stream $Stream -Status 202 -Json (Get-DpUpdatePayload)
        }
        'installUpdate' {
            # Consent-gated self-update: the SPA calls this only after the user
            # clicks "Update now" on the notice. It installs the newest DeskPilot
            # and ShellPilot (a preview DeskPilot target also accepts a preview
            # ShellPilot) into the CurrentUser scope, then force-reloads ShellPilot
            # live in the Engine Runspace so the Engine update takes effect at once.
            # The DeskPilot host cannot hot-swap its own running code in-process, so
            # its update applies on a relaunch (POST /api/update/restart). Installing
            # runs inline on this single accept thread - like the Git/atelier routes.
            if ($state.Update.installing) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'already_installing'; message = 'An update is already being installed.' } }
                return
            }
            if ($state.TurnRunning) {
                # Reloading ShellPilot re-imports it in the Engine Runspace, which a
                # running Turn is using - refuse until it finishes.
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A turn is running. Try updating again once it finishes.' } }
                return
            }
            if (-not $state.Update.updateAvailable) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'no_update'; message = 'No newer version is available to install.' } }
                return
            }
            $state.Update.installing = $true
            try {
                $r = Invoke-DpSelfUpdate -IncludePrerelease:([bool]$state.Update.targetIsPrerelease)
                # Reload the Engine live so the new ShellPilot is used without a
                # restart (only DeskPilot's own host code needs the relaunch).
                $engineReload = if ($r.Ok) { Update-DpEngineModule } else { @{ Ok = $false; Version = $null; Error = 'Skipped (install failed).' } }
            }
            finally {
                $state.Update.installing = $false
            }
            $state.Update.installResult = @{
                ok              = [bool]$r.Ok
                restartRequired = [bool]$r.Ok
                modules         = @($r.Modules)
                engineReloaded  = [bool]$engineReload.Ok
                engineVersion   = $engineReload.Version
                error           = $r.Error
                installedUtc    = [DateTime]::UtcNow.ToString('o')
            }
            if (-not $r.Ok) {
                Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'update_failed'; message = $r.Error } }
                return
            }
            $engineNote = if ($engineReload.Ok) { ' The Engine (ShellPilot) reloaded and is active now.' } else { '' }
            Write-DpResponse -Stream $Stream -Json @{
                ok                = $true
                restartRequired   = $true
                includePrerelease = [bool]$r.IncludePrerelease
                modules           = @($r.Modules)
                engineReloaded    = [bool]$engineReload.Ok
                engineVersion     = $engineReload.Version
                message           = "Update installed.$engineNote Restart DeskPilot to finish applying the app update."
            }
        }
        'restartUpdate' {
            # Relaunch DeskPilot in a fresh process (which imports the updated
            # DeskPilot + ShellPilot) and signal this one to stop. This is the only
            # safe way to apply the DeskPilot host update - the running module cannot
            # hot-swap its own executing code. Refuse mid-Turn.
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A turn is running. Try restarting again once it finishes.' } }
                return
            }
            $restart = Restart-DpHost
            if (-not $restart.Ok) {
                Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'restart_failed'; message = $restart.Error } }
                return
            }
            Write-DpResponse -Stream $Stream -Json @{
                ok      = $true
                message = 'DeskPilot is restarting. A new window will open; you can close this tab.'
            }
        }
        'getMemory' {
            Write-DpResponse -Stream $Stream -Json (Get-DpMemoryPayload)
        }
        'updateMemory' {
            # Manual edits to either memory store. User Profile is the preferences
            # Setting (validated + persisted via Merge-DpSettings); Agent Memory is
            # its own store. Either or both may be present in the body.
            if ($null -eq $Body) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_body'; message = 'Nothing to update.' } }
                return
            }
            $limits = Get-DpMemoryLimits
            if ($Body.PSObject.Properties['userProfile']) {
                $profileText = if ($null -eq $Body.userProfile) { $null } else { [string]$Body.userProfile }
                if ($profileText -and $profileText.Length -gt $limits.userProfile) {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'too_long'; message = "The user profile must be $($limits.userProfile) characters or fewer." } }
                    return
                }
                try {
                    $state.Settings = Merge-DpSettings -Current $state.Settings -Patch @{ preferences = $profileText }
                    if ($state.DataDir) { Save-DpSettings -Settings $state.Settings -Directory $state.DataDir }
                }
                catch {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_profile'; message = "$_" } }
                    return
                }
            }
            if ($Body.PSObject.Properties['agentMemory']) {
                $memText = if ($null -eq $Body.agentMemory) { '' } else { ([string]$Body.agentMemory).Trim() }
                if ($memText.Length -gt $limits.agentMemory) {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'too_long'; message = "The agent memory must be $($limits.agentMemory) characters or fewer." } }
                    return
                }
                $state.Memory = @{ text = $memText; updatedUtc = [DateTime]::UtcNow.ToString('o') }
                if ($state.DataDir) { Save-DpMemoryStore -Memory $state.Memory -Directory $state.DataDir }
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpMemoryPayload)
        }
        'learnMemory' {
            # Fold durable facts from a Conversation into the Agent Memory via a
            # pure-reasoning Turn (all Tools off, like auto-title / compaction). The
            # visible transcript is untouched; only the persistent memory changes.
            $conversationId = if ($Body -and $Body.PSObject.Properties['conversationId'] -and $Body.conversationId) { [string]$Body.conversationId } else { $null }
            if (-not $conversationId) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'missing_conversation'; message = 'A conversationId is required.' } }
                return
            }
            $conversation = $state.Conversations[$conversationId]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A Turn is already running.' } }
                return
            }
            $limits = Get-DpMemoryLimits
            $recent = @($conversation.messages | Where-Object { $_.role -in @('user', 'assistant') } | Select-Object -Last 8)
            if ($recent.Count -lt 2) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'too_short'; message = 'This conversation is too short to learn from.' } }
                return
            }
            $current = if ($state.Memory) { [string]$state.Memory.text } else { '' }
            $changed = $false
            $engineParams = @{
                Prompt             = New-DpMemoryPrompt -CurrentMemory $current -Messages $recent -MaxChars $limits.agentMemory
                DisableBrowsing    = $true
                DisableFileAccess  = $true
                DisableTerminal    = $true
                DisableUserPrompts = $true
                DisableUserTools   = $true
                DisableTodoList    = $true
            }
            $effectiveModel = if ($conversation.model) { $conversation.model } elseif ($state.Settings.model) { $state.Settings.model } else { $null }
            if ($effectiveModel) { $engineParams.Model = $effectiveModel }
            $state.TurnRunning = $true
            try {
                $engineResult = Invoke-DpEngineCommand -Command 'Invoke-Shp' -Parameter $engineParams | Select-Object -Last 1
                $content = if ($engineResult) { [string]$engineResult.Content } else { '' }
                $extracted = ConvertFrom-DpMemoryResult -Text $content -MaxLength $limits.agentMemory
                if (-not [string]::IsNullOrWhiteSpace($extracted) -and $extracted -ne $current) {
                    $state.Memory = @{ text = $extracted; updatedUtc = [DateTime]::UtcNow.ToString('o') }
                    if ($state.DataDir) { Save-DpMemoryStore -Memory $state.Memory -Directory $state.DataDir }
                    $changed = $true
                }
            }
            catch {
                # Best-effort: a failed extraction leaves the memory unchanged.
                $null = $_
            }
            finally {
                $state.TurnRunning = $false
            }
            $payload = Get-DpMemoryPayload
            $payload.changed = $changed
            Write-DpResponse -Stream $Stream -Json $payload
        }
        'listConversations' {
            $summaries = $state.Conversations.Values |
                Sort-Object @{ Expression = { [bool]$_.pinned }; Descending = $true }, @{ Expression = { $_.updatedUtc }; Descending = $true } |
                ForEach-Object {
                    @{ id = $_.id; title = $_.title; model = $_.model; pinned = [bool]$_.pinned; archived = [bool]$_.archived; unread = [bool]$_.unread; color = $_.color; compactedUtc = $_.compactedUtc; createdUtc = $_.createdUtc; updatedUtc = $_.updatedUtc; messageCount = $_.messages.Count }
                }
            Write-DpResponse -Stream $Stream -Json @{ conversations = @($summaries) }
        }
        'createConversation' {
            $title = if ($Body -and $Body.PSObject.Properties['title'] -and $Body.title) { [string]$Body.title } else { 'New conversation' }
            $model = if ($Body -and $Body.PSObject.Properties['model'] -and $Body.model) { [string]$Body.model } else { $state.Settings.model }
            $conversation = New-DpConversation -Title $title -Model $model
            $state.Conversations[$conversation.id] = $conversation
            Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
            Write-DpResponse -Stream $Stream -Status 201 -Json @{
                id = $conversation.id; title = $conversation.title; model = $conversation.model
                createdUtc = $conversation.createdUtc; updatedUtc = $conversation.updatedUtc; messageCount = 0
            }
        }
        'getConversation' {
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            Write-DpResponse -Stream $Stream -Json @{
                id = $conversation.id; title = $conversation.title; model = $conversation.model
                compactedUtc = $conversation.compactedUtc
                createdUtc = $conversation.createdUtc; updatedUtc = $conversation.updatedUtc
                messages = @($conversation.messages)
            }
        }
        'patchConversation' {
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            # Validate the colour up-front so an unknown value rejects cleanly
            # before any field is mutated. An empty/absent colour clears it.
            $requestedColor = $null
            if ($Body -and $Body.PSObject.Properties['color']) {
                $requestedColor = if ($Body.color) { [string]$Body.color } else { '' }
                $allowedColors = @('red', 'amber', 'green', 'teal', 'blue', 'purple')
                if ($requestedColor -and $allowedColors -notcontains $requestedColor) {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_color'; message = "Unknown colour '$requestedColor'." } }
                    return
                }
            }
            if ($Body -and $Body.PSObject.Properties['title'] -and $Body.title) {
                $conversation.title = [string]$Body.title
                # A manual rename locks the title so auto-titling never overwrites it.
                $conversation.titleLocked = $true
            }
            if ($Body -and $Body.PSObject.Properties['model']) { $conversation.model = if ($Body.model) { [string]$Body.model } else { $null } }
            # Pin / archive / unread / colour are organisational flags; they must
            # not reorder the list, so they do not bump updatedUtc (only a
            # title/model edit does).
            $touched = $false
            if ($Body -and ($Body.PSObject.Properties['title'] -or $Body.PSObject.Properties['model'])) { $touched = $true }
            if ($Body -and $Body.PSObject.Properties['pinned']) { $conversation.pinned = [bool]$Body.pinned }
            if ($Body -and $Body.PSObject.Properties['archived']) { $conversation.archived = [bool]$Body.archived }
            if ($Body -and $Body.PSObject.Properties['unread']) { $conversation.unread = [bool]$Body.unread }
            if ($null -ne $requestedColor) { $conversation.color = if ($requestedColor) { $requestedColor } else { $null } }
            if ($touched) { $conversation.updatedUtc = [DateTime]::UtcNow.ToString('o') }
            Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
            Write-DpResponse -Stream $Stream -Json @{
                id = $conversation.id; title = $conversation.title; model = $conversation.model
                pinned = [bool]$conversation.pinned; archived = [bool]$conversation.archived
                unread = [bool]$conversation.unread; color = $conversation.color
                createdUtc = $conversation.createdUtc; updatedUtc = $conversation.updatedUtc; messageCount = $conversation.messages.Count
            }
        }
        'deleteConversation' {
            if ($state.Conversations.ContainsKey($RouteParams.id)) {
                $state.Conversations.Remove($RouteParams.id)
                Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
            }
            Write-DpResponse -Stream $Stream -Status 204 -NoBody
        }
        'duplicateConversation' {
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            $copy = Copy-DpConversation -Conversation $conversation
            $state.Conversations[$copy.id] = $copy
            Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
            Write-DpResponse -Stream $Stream -Status 201 -Json @{
                id = $copy.id; title = $copy.title; model = $copy.model
                pinned = [bool]$copy.pinned; archived = [bool]$copy.archived
                unread = [bool]$copy.unread; color = $copy.color; compactedUtc = $copy.compactedUtc
                createdUtc = $copy.createdUtc; updatedUtc = $copy.updatedUtc; messageCount = $copy.messages.Count
            }
        }
        'readAllConversations' {
            $cleared = 0
            foreach ($conversation in $state.Conversations.Values) {
                if ($conversation.unread) { $conversation.unread = $false; $cleared++ }
            }
            if ($cleared -gt 0) {
                Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
            }
            Write-DpResponse -Stream $Stream -Json @{ ok = $true; cleared = $cleared }
        }
        'postMessage' {
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A Turn is already running.' } }
                return
            }
            $prompt = if ($Body -and $Body.PSObject.Properties['prompt']) { [string]$Body.prompt } else { '' }
            if ([string]::IsNullOrWhiteSpace($prompt)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_prompt'; message = 'A prompt is required.' } }
                return
            }

            $imagePaths = @()
            if ($Body -and $Body.PSObject.Properties['images']) {
                $requestedImagePaths = @($Body.images | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($requestedImagePaths.Count -gt 0) {
                    try {
                        $imagePaths = @(Resolve-DpAttachmentPath -Path $requestedImagePaths -AttachmentStore $state.Attachments)
                    }
                    catch {
                        $attachmentError = $_
                        Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'invalid_attachment'; message = $attachmentError.Exception.Message } }
                        return
                    }
                }
            }

            Invoke-DpTurn -Conversation $conversation -Prompt $prompt -Image $imagePaths -Stream $Stream
        }
        'regenerateTurn' {
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A Turn is already running.' } }
                return
            }
            $lastUser = @($conversation.messages | Where-Object { $_.role -eq 'user' }) | Select-Object -Last 1
            if (-not $lastUser) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'nothing_to_regenerate'; message = 'There is no user message to regenerate.' } }
                return
            }
            $prompt = Reset-DpConversationForRerun -Conversation $conversation -FromMessageId ([string]$lastUser.id)
            if ([string]::IsNullOrWhiteSpace($prompt)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'nothing_to_regenerate'; message = 'There is no user message to regenerate.' } }
                return
            }
            Invoke-DpTurn -Conversation $conversation -Prompt $prompt -Stream $Stream
        }
        'editTurn' {
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A Turn is already running.' } }
                return
            }
            $messageId = [string](Get-DpPropertyValue -InputObject $Body -Name @('messageId') -Default '')
            $prompt = if ($Body -and $Body.PSObject.Properties['prompt']) { [string]$Body.prompt } else { '' }
            if ([string]::IsNullOrWhiteSpace($messageId) -or [string]::IsNullOrWhiteSpace($prompt)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_request'; message = 'A messageId and a non-empty prompt are required.' } }
                return
            }
            $removed = Reset-DpConversationForRerun -Conversation $conversation -FromMessageId $messageId
            if ($null -eq $removed) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'not_a_user_message'; message = 'That message cannot be edited (not found or not a user message).' } }
                return
            }
            Invoke-DpTurn -Conversation $conversation -Prompt $prompt -Stream $Stream
        }
        'submitUserPrompt' {
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{
                    error = @{ code = 'not_found'; message = 'Conversation not found.' }
                }
                return
            }

            $questionId = [string](Get-DpPropertyValue -InputObject $Body -Name @('questionId') -Default '')
            $answer = [string](Get-DpPropertyValue -InputObject $Body -Name @('answer') -Default '')
            if ([string]::IsNullOrWhiteSpace($questionId) -or [string]::IsNullOrWhiteSpace($answer)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{
                    error = @{ code = 'bad_answer'; message = 'A questionId and non-empty answer are required.' }
                }
                return
            }

            $bridge = $state.Engine.UserPromptBridge
            $accepted = $state.TurnRunning -and $bridge -and
                $bridge.SubmitAnswer([string]$conversation.id, $questionId, $answer.Trim())
            if (-not $accepted) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{
                    error = @{ code = 'stale_question'; message = 'That question is no longer waiting for an answer.' }
                }
                return
            }

            Write-DpResponse -Stream $Stream -Status 202 -Json @{ accepted = $true }
        }
        'stopTurn' {
            $state.CancelRequested = $true
            $bridge = $state.Engine.UserPromptBridge
            if ($bridge) { $bridge.Cancel() }
            Write-DpResponse -Stream $Stream -Status 202 -Json @{ stopping = $true }
        }
        'titleConversation' {
            # Auto-title a new Conversation from its first prompt, the way GitHub
            # Copilot renames a new chat to a short summary. Best-effort: the caller
            # already shows a fallback title (the truncated prompt), so any failure
            # here just leaves that in place.
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            # A manual rename wins: never overwrite a title the user set themselves.
            if ($conversation.titleLocked) {
                Write-DpResponse -Stream $Stream -Json @{ id = $conversation.id; title = $conversation.title }
                return
            }
            # Only the first exchange is auto-titled. Later Turns leave the title
            # alone, so a caller can safely fire this after every Turn.
            $userMessages = @($conversation.messages | Where-Object { $_.role -eq 'user' })
            if ($userMessages.Count -ne 1) {
                Write-DpResponse -Stream $Stream -Json @{ id = $conversation.id; title = $conversation.title }
                return
            }
            # The title Turn shares the single Engine Runspace, so refuse while a
            # Turn is running rather than corrupting its state.
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A Turn is already running.' } }
                return
            }
            $firstPrompt = [string]$userMessages[0].text
            $newTitle = $conversation.title
            if (-not [string]::IsNullOrWhiteSpace($firstPrompt)) {
                # Pure-reasoning Turn with every Tool disabled (as the Merge Plan does).
                $engineParams = @{
                    Prompt             = New-DpTitlePrompt -Prompt $firstPrompt
                    DisableBrowsing    = $true
                    DisableFileAccess  = $true
                    DisableTerminal    = $true
                    DisableUserPrompts = $true
                    DisableUserTools   = $true
                    DisableTodoList    = $true
                }
                $effectiveModel = if ($conversation.model) { $conversation.model } elseif ($state.Settings.model) { $state.Settings.model } else { $null }
                if ($effectiveModel) { $engineParams.Model = $effectiveModel }
                $state.TurnRunning = $true
                try {
                    $engineResult = Invoke-DpEngineCommand -Command 'Invoke-Shp' -Parameter $engineParams | Select-Object -Last 1
                    $content = if ($engineResult) { [string]$engineResult.Content } else { '' }
                    $cleaned = ConvertFrom-DpTitleResult -Text $content
                    if (-not [string]::IsNullOrWhiteSpace($cleaned)) { $newTitle = $cleaned }
                }
                catch {
                    # A title failure must never surface to the user or break the
                    # Conversation; keep whatever title is already set.
                    $null = $_
                }
                finally {
                    $state.TurnRunning = $false
                }
            }
            if ($newTitle -ne $conversation.title) {
                $conversation.title = $newTitle
                $conversation.updatedUtc = [DateTime]::UtcNow.ToString('o')
                Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
            }
            Write-DpResponse -Stream $Stream -Json @{ id = $conversation.id; title = $conversation.title }
        }
        'compactConversation' {
            # Compact the Conversation's replayed context, the way GitHub Copilot
            # offers "Compact Conversation": summarise the earlier part of the
            # Engine -History into a short briefing and keep only the most recent
            # entries verbatim, so future Turns send far fewer tokens. The visible
            # transcript (messages) is deliberately left untouched - nothing the
            # user can see is lost; only what is replayed to the Engine shrinks.
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            # The compaction Turn shares the single Engine Runspace, so refuse while
            # a Turn is running rather than corrupting its state.
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A Turn is already running.' } }
                return
            }
            # How many recent history entries to keep verbatim comes from Settings
            # (compactionKeepRecent, default 4), so the same knob drives the manual
            # Compact action and the automatic compaction the browser triggers.
            $keepCount = 4
            if ($state.Settings -and $state.Settings.ContainsKey('compactionKeepRecent') -and $state.Settings.compactionKeepRecent) {
                $keepCount = [int]$state.Settings.compactionKeepRecent
            }
            if ($keepCount -lt 2) { $keepCount = 2 } elseif ($keepCount -gt 100) { $keepCount = 100 }
            $history = @($conversation.history)
            # Too little to be worth a summarisation Turn (and its credit cost):
            # there must be at least a few entries to summarise beyond the kept tail.
            if ($history.Count -lt ($keepCount + 3)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'too_short'; message = 'This conversation is too short to compact.' } }
                return
            }
            $summary = ''
            # Pure-reasoning Turn with every Tool disabled (as the auto-title and
            # Merge Plan Turns do): the Model only summarises, it never acts.
            $engineParams = @{
                Prompt             = New-DpCompactionPrompt -History $history
                DisableBrowsing    = $true
                DisableFileAccess  = $true
                DisableTerminal    = $true
                DisableUserPrompts = $true
                DisableUserTools   = $true
                DisableTodoList    = $true
            }
            $effectiveModel = if ($conversation.model) { $conversation.model } elseif ($state.Settings.model) { $state.Settings.model } else { $null }
            if ($effectiveModel) { $engineParams.Model = $effectiveModel }
            $state.TurnRunning = $true
            try {
                $engineResult = Invoke-DpEngineCommand -Command 'Invoke-Shp' -Parameter $engineParams | Select-Object -Last 1
                $content = if ($engineResult) { [string]$engineResult.Content } else { '' }
                $summary = ConvertFrom-DpCompactionResult -Text $content
            }
            catch {
                # A failed summarisation must never corrupt the Conversation; leave
                # the history untouched and report the failure to the caller.
                $summary = ''
                $null = $_
            }
            finally {
                $state.TurnRunning = $false
            }
            if ([string]::IsNullOrWhiteSpace($summary)) {
                Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'compaction_failed'; message = 'The summary could not be generated. Please try again.' } }
                return
            }
            $beforeChars = ([string](@($history) | ConvertTo-Json -Depth 20 -Compress)).Length
            $compact = Compress-DpConversationHistory -History $history -Summary $summary -KeepCount $keepCount
            if (-not $compact.changed) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'too_short'; message = 'This conversation is too short to compact.' } }
                return
            }
            $conversation.history = $compact.history
            # compactedUtc is an organisational marker; it does not bump updatedUtc
            # (compaction changes only the replayed context, not the visible thread).
            $conversation.compactedUtc = [DateTime]::UtcNow.ToString('o')
            Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
            $afterChars = ([string](@($compact.history) | ConvertTo-Json -Depth 20 -Compress)).Length
            $estimatedFreed = [Math]::Max(0, [int][Math]::Round(($beforeChars - $afterChars) / 4.0))
            Write-DpResponse -Stream $Stream -Json @{
                ok             = $true
                summarised     = $compact.summarised
                kept           = $compact.kept
                before         = $compact.before
                after          = $compact.after
                estimatedFreed = $estimatedFreed
                compactedUtc   = $conversation.compactedUtc
            }
        }
        'uploads' {
            # Uploads land in the active Workspace Folder; with no Project selected
            # they fall back to an 'uploads' folder in the per-user data directory,
            # so attaching a file never requires a registered Project.
            $workspace = Get-DpUploadDir -WorkspaceFolder $state.Settings.workspaceFolder
            $boundary = Get-DpMultipartBoundary -ContentType ([string]$Request.Headers['Content-Type'])
            if (-not $boundary -or -not $Request.BodyBytes -or $Request.BodyBytes.Length -eq 0) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_multipart'; message = 'Request must be a non-empty multipart/form-data upload.' } }
                return
            }
            try {
                if (-not (Test-Path -LiteralPath $workspace)) {
                    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
                }
                $parts = Read-DpMultipartParts -Bytes $Request.BodyBytes -Boundary $boundary
                $maxBytes = 25 * 1024 * 1024
                $saved = [System.Collections.Generic.List[object]]::new()
                foreach ($part in $parts) {
                    if (-not $part.FileName) { continue }
                    if ($part.Content.Length -gt $maxBytes) {
                        Write-DpResponse -Stream $Stream -Status 413 -Json @{ error = @{ code = 'too_large'; message = "File '$($part.FileName)' exceeds the 25 MiB upload limit." } }
                        return
                    }
                    $target = Get-DpUniqueFilePath -Directory $workspace -Name $part.FileName
                    [System.IO.File]::WriteAllBytes($target, $part.Content)
                    $registeredPath = [System.IO.Path]::GetFullPath($target)
                    $state.Attachments[$registeredPath] = [string]$part.ContentType
                    $saved.Add(@{
                            name        = $part.FileName
                            savedAs     = [System.IO.Path]::GetFileName($registeredPath)
                            path        = $registeredPath
                            bytes       = $part.Content.Length
                            contentType = $part.ContentType
                        })
                }
                if ($saved.Count -eq 0) {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_files'; message = 'No file parts were found in the upload.' } }
                    return
                }
                Write-DpResponse -Stream $Stream -Json @{ files = @($saved) }
            }
            catch {
                Write-DpResponse -Stream $Stream -Status 500 -Json @{ error = @{ code = 'upload_failed'; message = "$_" } }
            }
        }
        'searchConversations' {
            $query = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('q')) { ([string]$Request.Query['q']).Trim() } else { '' }
            if ([string]::IsNullOrWhiteSpace($query)) {
                Write-DpResponse -Stream $Stream -Json @{ query = ''; results = @() }
                return
            }
            $needle = $query.ToLowerInvariant()
            $results = [System.Collections.Generic.List[hashtable]]::new()
            $ordered = $state.Conversations.Values |
                Sort-Object @{ Expression = { [bool]$_.pinned }; Descending = $true }, @{ Expression = { $_.updatedUtc }; Descending = $true }
            foreach ($conversation in $ordered) {
                $titleHit = $conversation.title -and $conversation.title.ToLowerInvariant().Contains($needle)
                $snippet = $null
                $messageHit = $false
                foreach ($message in @($conversation.messages)) {
                    $text = [string](Get-DpPropertyValue -InputObject $message -Name @('text', 'content') -Default '')
                    if (-not $text) { continue }
                    $idx = $text.ToLowerInvariant().IndexOf($needle)
                    if ($idx -ge 0) {
                        $messageHit = $true
                        $start = [Math]::Max(0, $idx - 30)
                        $len = [Math]::Min($text.Length - $start, $needle.Length + 70)
                        $snippet = $text.Substring($start, $len).Trim() -replace '\s+', ' '
                        if ($start -gt 0) { $snippet = [char]0x2026 + $snippet }
                        break
                    }
                }
                if ($titleHit -or $messageHit) {
                    $results.Add(@{
                            id           = $conversation.id
                            title        = $conversation.title
                            pinned       = [bool]$conversation.pinned
                            archived     = [bool]$conversation.archived
                            unread       = [bool]$conversation.unread
                            color        = $conversation.color
                            updatedUtc   = $conversation.updatedUtc
                            messageCount = $conversation.messages.Count
                            snippet      = $snippet
                            titleHit     = [bool]$titleHit
                        })
                }
            }
            Write-DpResponse -Stream $Stream -Json @{ query = $query; results = @($results) }
        }
        'fsFind' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $query = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('q')) { [string]$Request.Query['q'] } else { '' }
            Write-DpResponse -Stream $Stream -Json (Get-DpFileFind -Root $root -Query $query)
        }
        'gitDiff' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $requested = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('path')) { [string]$Request.Query['path'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($requested)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_path'; message = 'A file path is required.' } }
                return
            }
            # An explicit base is only honoured when it is one of this Project's own
            # snapshots, so the query cannot name an arbitrary commit to read from.
            $base = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('base')) { [string]$Request.Query['base'] } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($base)) {
                $known = @(Get-DpChangeEntry -Store $state.Changes -Root $root | ForEach-Object { [string]$_.snapshotSha })
                if ($known -notcontains $base) { $base = '' }
            }
            if ([string]::IsNullOrWhiteSpace($base)) {
                Write-DpResponse -Stream $Stream -Json (Get-DpGitDiff -Root $root -Path $requested)
            }
            else {
                Write-DpResponse -Stream $Stream -Json (Get-DpGitDiff -Root $root -Path $requested -BaseSha $base)
            }
        }
        'gitRestore' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $paths = @()
            if ($Body -and $Body.PSObject.Properties['paths'] -and $Body.paths) { $paths = @($Body.paths | ForEach-Object { [string]$_ }) }
            if ($paths.Count -eq 0) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_paths'; message = 'At least one file path is required.' } }
                return
            }
            $result = Invoke-DpGitRestore -Root $root -Paths $paths
            if ($result.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'restore_failed'; message = $result.error } }
                return
            }
            Write-DpResponse -Stream $Stream -Json $result
        }
        'atelierHealth' {
            Write-DpResponse -Stream $Stream -Json (Get-DpAtelierHealth -Settings $state.Settings)
        }
        'atelierSetup' {
            # Opt-in and consent-gated: download CopilotAtelier and run its
            # Setup-CopilotSettings.ps1. The SPA requires an explicit confirmation
            # (a modal that spells out what the script changes) before calling
            # this, so it is never a one-click action. Downloading blocks this
            # single accept thread briefly, like the Git routes - acceptable for a
            # deliberate, one-time action.
            $r = Invoke-DpAtelierSetup
            if (-not $r.Ok) {
                $code = if ($r.Code) { $r.Code } else { 'atelier_setup_failed' }
                $status = if ($code -eq 'download_failed') { 502 } else { 500 }
                Write-DpResponse -Stream $Stream -Status $status -Json @{ error = @{ code = $code; message = $r.Error } }
                return
            }
            Write-DpResponse -Stream $Stream -Json @{
                ok         = $true
                launched   = $r.Launched
                windows    = $r.Windows
                sourcePath = $r.SourcePath
                scriptPath = $r.ScriptPath
                message    = $r.Message
            }
        }
        'getIntercom' {
            Write-DpResponse -Stream $Stream -Json (Get-DpIntercomPayload)
        }
        'putIntercom' {
            if ($null -eq $Body) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_body'; message = 'An Intercom settings body is required.' } }
                return
            }

            # botToken is write-only and never a Setting: it is split off here so it
            # cannot reach settings.json, a Settings export, or any response.
            $patch = @{}
            $tokenSupplied = $false
            $token = ''
            foreach ($property in $Body.PSObject.Properties) {
                if ($property.Name -eq 'botToken') {
                    $tokenSupplied = $true
                    $token = [string]$property.Value
                    continue
                }
                $patch[$property.Name] = $property.Value
            }

            if ($tokenSupplied) {
                $trimmed = $token.Trim()
                if ($trimmed -and $trimmed -notmatch '^\d{6,}:[A-Za-z0-9_-]{30,}$') {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_token'; message = 'That does not look like a Telegram bot token. BotFather gives you one shaped like 123456789:AA…' } }
                    return
                }
                try {
                    $configured = Save-DpIntercomSecret -Token $trimmed -Directory $state.DataDir -Confirm:$false
                }
                catch {
                    Write-DpResponse -Stream $Stream -Status 500 -Json @{ error = @{ code = 'token_store_failed'; message = (Hide-DpIntercomSecret -Text "$_") } }
                    return
                }
                $state.Intercom.Token = $trimmed
                $state.Intercom.TokenConfigured = $configured
                # A new credential invalidates everything the old one established.
                $state.Intercom.Running = $false
                $state.Intercom.PollTask = $null
                $state.Intercom.StatusMessageId = 0
                $state.Intercom.PendingQuestion = $null
                Add-DpIntercomLog -Direction 'system' -Kind 'token' -Detail $(if ($configured) { 'A bot token was stored.' } else { 'The bot token was removed.' })
            }

            if ($patch.Count -gt 0) {
                try {
                    $merged = Merge-DpSettings -Current $state.Settings -Patch @{ intercom = $patch }
                    $state.Settings = $merged
                    if ($state.DataDir) { Save-DpSettings -Settings $merged -Directory $state.DataDir }
                }
                catch {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_settings'; message = "$_" } }
                    return
                }
                if ($patch.ContainsKey('chatId')) {
                    # A different allow-listed chat is a different link: close any
                    # pairing window, drop the in-flight poll, and let the pump run
                    # its enable transition again so the backlog is discarded and
                    # the new chat gets the welcome message.
                    $state.Intercom.Running = $false
                    $state.Intercom.PollTask = $null
                    $state.Intercom.StatusMessageId = 0
                    $state.Intercom.PendingQuestion = $null
                    $state.Intercom.Pairing.active = $false
                    $state.Intercom.Pairing.startedUtc = $null
                    $state.Intercom.Pairing.candidates.Clear()
                    Add-DpIntercomLog -Direction 'system' -Kind 'paired' -Detail $(if ($merged.intercom.chatId) { "Chat $($merged.intercom.chatId) is now the only chat allowed to reach DeskPilot." } else { 'The allowed chat was cleared.' })
                }
            }

            # Apply the change now rather than on the next idle tick, so the panel
            # reports the real state instead of the state it is about to be in.
            try { Update-DpIntercomState } catch { $null = $_ }
            Write-DpResponse -Stream $Stream -Json (Get-DpIntercomPayload)
        }
        'testIntercom' {
            $intercom = $state.Intercom
            if (-not $intercom.TokenConfigured -or -not $intercom.Client) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'no_token'; message = 'Store a bot token first.' } }
                return
            }
            $chatId = [string]$state.Settings.intercom.chatId
            if ([string]::IsNullOrWhiteSpace($chatId)) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'no_chat'; message = 'Enter the chat id that is allowed to control DeskPilot.' } }
                return
            }

            # The one place Intercom waits on the network: the user pressed a
            # button and is watching, and it is bounded by the client timeout.
            $identity = Receive-DpTelegramResponse -Task (Invoke-DpTelegramRequest -Client $intercom.Client -Token $intercom.Token -Operation 'getMe')
            if (-not $identity.ok) {
                Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'telegram_error'; message = "Telegram did not accept the token: $($identity.error)" } }
                return
            }

            $testPayload = @{
                chat_id                  = $chatId
                text                     = "DeskPilot Intercom test from $([Environment]::MachineName). If you can read this, you are connected."
                disable_web_page_preview = $true
            }
            $sent = Receive-DpTelegramResponse -Task (Invoke-DpTelegramRequest -Client $intercom.Client -Token $intercom.Token -Operation 'sendMessage' -Payload $testPayload)
            if (-not $sent.ok) {
                Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'telegram_error'; message = "The test message was not delivered: $($sent.error)" } }
                return
            }

            Add-DpIntercomLog -Direction 'out' -Kind 'test' -Detail 'Sent a test message.'
            Write-DpResponse -Stream $Stream -Json @{
                ok      = $true
                botName = [string](Get-DpPropertyValue -InputObject $identity.result -Name @('username') -Default '')
            }
        }
        'pairIntercom' {
            # Without this the setup cannot be completed at all: Intercom will not
            # listen until it knows which chat is the operator's, so the bot cannot
            # answer - not even /start - and there is no way to learn the chat id
            # from it. This opens a five-minute window in which the poller runs with
            # no allow-list, executes nothing, and only collects who messaged the
            # bot. Adoption stays an explicit click at the machine.
            $intercom = $state.Intercom
            if (-not $intercom.TokenConfigured) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'no_token'; message = 'Store a bot token first.' } }
                return
            }
            $stop = [bool](Get-DpPropertyValue -InputObject $Body -Name @('stop') -Default $false)
            if ($stop) {
                $intercom.Pairing.active = $false
                $intercom.Pairing.startedUtc = $null
                $intercom.Pairing.candidates.Clear()
                Add-DpIntercomLog -Direction 'system' -Kind 'pairing' -Detail 'Pairing was cancelled.'
            }
            else {
                if (-not [string]::IsNullOrWhiteSpace([string]$state.Settings.intercom.chatId)) {
                    Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'already_paired'; message = 'A chat is already linked. Clear the chat id first if you want to link a different phone.' } }
                    return
                }
                $intercom.Pairing.active = $true
                $intercom.Pairing.startedUtc = [DateTime]::UtcNow
                $intercom.Pairing.candidates.Clear()
                $intercom.Running = $false
                $intercom.PollTask = $null
                Add-DpIntercomLog -Direction 'system' -Kind 'pairing' -Detail 'Pairing is open for five minutes. Message the bot from your phone.'
            }
            try { Update-DpIntercomState } catch { $null = $_ }
            Write-DpResponse -Stream $Stream -Json (Get-DpIntercomPayload)
        }
        default {
            Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = "Unknown handler '$Name'." } }
        }
    }
}

