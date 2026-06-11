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
            Invoke-DpAuthFlow -Stream $Stream
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
                Write-DpResponse -Stream $Stream -Json @{ default = $defaultId; models = @($list) }
            }
            catch {
                Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'engine_unavailable'; message = "Could not list models: $_" } }
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
            $root = $state.Settings.agentsRoot
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
                    $state.Usage = @{ promptTokens = 0; completionTokens = 0; totalTokens = 0; costUSD = 0.0; credits = 0.0; turns = 0; byModel = @{} }
                }
                default {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_scope'; message = "Unknown reset scope '$scope'. Use 'lifetime' or 'session'." } }
                    return
                }
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpUsagePayload)
        }
        'listConversations' {
            $summaries = $state.Conversations.Values |
                Sort-Object @{ Expression = { [bool]$_.pinned }; Descending = $true }, @{ Expression = { $_.updatedUtc }; Descending = $true } |
                ForEach-Object {
                    @{ id = $_.id; title = $_.title; model = $_.model; pinned = [bool]$_.pinned; archived = [bool]$_.archived; createdUtc = $_.createdUtc; updatedUtc = $_.updatedUtc; messageCount = $_.messages.Count }
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
            if ($Body -and $Body.PSObject.Properties['title'] -and $Body.title) { $conversation.title = [string]$Body.title }
            if ($Body -and $Body.PSObject.Properties['model']) { $conversation.model = if ($Body.model) { [string]$Body.model } else { $null } }
            # Pin / archive are organisational flags; they must not reorder the list,
            # so they do not bump updatedUtc (only a title/model edit does).
            $touched = $false
            if ($Body -and ($Body.PSObject.Properties['title'] -or $Body.PSObject.Properties['model'])) { $touched = $true }
            if ($Body -and $Body.PSObject.Properties['pinned']) { $conversation.pinned = [bool]$Body.pinned }
            if ($Body -and $Body.PSObject.Properties['archived']) { $conversation.archived = [bool]$Body.archived }
            if ($touched) { $conversation.updatedUtc = [DateTime]::UtcNow.ToString('o') }
            Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
            Write-DpResponse -Stream $Stream -Json @{
                id = $conversation.id; title = $conversation.title; model = $conversation.model
                pinned = [bool]$conversation.pinned; archived = [bool]$conversation.archived
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
            Invoke-DpTurn -Conversation $conversation -Prompt $prompt -Stream $Stream
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
        'stopTurn' {
            $state.CancelRequested = $true
            Write-DpResponse -Stream $Stream -Status 202 -Json @{ stopping = $true }
        }
        'uploads' {
            $workspace = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($workspace)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'Select or register a Project before uploading files.' } }
                return
            }
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
                    $saved.Add(@{
                            name        = $part.FileName
                            savedAs     = [System.IO.Path]::GetFileName($target)
                            path        = $target
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
            Write-DpResponse -Stream $Stream -Json (Get-DpGitDiff -Root $root -Path $requested)
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
        default {
            Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = "Unknown handler '$Name'." } }
        }
    }
}

