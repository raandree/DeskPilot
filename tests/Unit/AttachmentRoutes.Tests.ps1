#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'postMessage image Attachments' -Tag 'Unit' {
    BeforeEach {
        $attachmentRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $attachmentRoot | Out-Null

        $conversation = New-DpConversation -Title 'Attachment test'
        $settings = Get-DpDefaultSettings
        $settings.workspaceFolder = $attachmentRoot
        $script:DeskPilot = @{
            Conversations = @{ $conversation.id = $conversation }
            Settings      = $settings
            TurnRunning   = $false
            Attachments   = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
        $script:responseStream = [System.IO.MemoryStream]::new()
        $script:forwardedImages = @()
        $script:forwardedAttachments = @()
        $script:forwardedPrompt = $null

        Mock Invoke-DpTurn {
            param($Conversation, $Prompt, $Stream, $Image, $Attachment)
            $null = $Conversation, $Stream
            $script:forwardedImages = @($Image)
            $script:forwardedAttachments = @($Attachment)
            $script:forwardedPrompt = $Prompt
        }
    }

    AfterEach {
        $script:responseStream.Dispose()
        $script:DeskPilot = $null
    }

    It 'passes an uploaded image Attachment after the selected Project changes' {
        $priorProjectRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $priorProjectRoot | Out-Null
        $imagePath = Join-Path $priorProjectRoot 'clipboard.png'
        Set-Content -LiteralPath $imagePath -Value 'image bytes'
        $script:DeskPilot.Attachments[[System.IO.Path]::GetFullPath($imagePath)] = 'image/png'
        $body = [pscustomobject]@{ prompt = 'Describe this image'; images = @($imagePath) }

        Invoke-DpRouteHandler -Name 'postMessage' -RouteParams @{ id = $conversation.id } -Body $body -Stream $script:responseStream

        $script:forwardedImages | Should -Be @([System.IO.Path]::GetFullPath($imagePath))
        Should -Invoke Invoke-DpTurn -Times 1 -Exactly
    }

    It 'rejects an image path that was not uploaded' {
        $unregisteredPath = Join-Path $TestDrive 'unregistered.png'
        Set-Content -LiteralPath $unregisteredPath -Value 'unregistered'
        $body = [pscustomobject]@{ prompt = 'Describe this image'; images = @($unregisteredPath) }

        Invoke-DpRouteHandler -Name 'postMessage' -RouteParams @{ id = $conversation.id } -Body $body -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 400 Bad Request'
        $json = ($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json
        $json.error.code | Should -Be 'invalid_attachment'
        Should -Invoke Invoke-DpTurn -Times 0 -Exactly
    }

    It 'forwards an Attachment as a Message record and leaves the prompt untouched' {
        # The paths reach the model through the Turn, not by being written into
        # what the user typed - which is what put a sentence nobody wrote into the
        # bubble and into the conversation title.
        $notesPath = Join-Path $attachmentRoot 'notes.docx'
        Set-Content -LiteralPath $notesPath -Value 'notes'
        $script:DeskPilot.Attachments[[System.IO.Path]::GetFullPath($notesPath)] = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
        $body = [pscustomobject]@{ prompt = 'Summarise this'; attachments = @($notesPath) }

        Invoke-DpRouteHandler -Name 'postMessage' -RouteParams @{ id = $conversation.id } -Body $body -Stream $script:responseStream

        $script:forwardedPrompt | Should -Be 'Summarise this'
        $script:forwardedAttachments.Count | Should -Be 1
        $script:forwardedAttachments[0].name | Should -Be 'notes.docx'
        $script:forwardedAttachments[0].path | Should -Be ([System.IO.Path]::GetFullPath($notesPath))
        Should -Invoke Invoke-DpTurn -Times 1 -Exactly
    }

    It 'runs a Turn that is Attachments and nothing else' {
        # Dropping files on the composer and pressing Send without typing is a
        # request about those files, not an empty message.
        $notesPath = Join-Path $attachmentRoot 'report.pdf'
        Set-Content -LiteralPath $notesPath -Value 'report'
        $script:DeskPilot.Attachments[[System.IO.Path]::GetFullPath($notesPath)] = 'application/pdf'
        $body = [pscustomobject]@{ prompt = ''; attachments = @($notesPath) }

        Invoke-DpRouteHandler -Name 'postMessage' -RouteParams @{ id = $conversation.id } -Body $body -Stream $script:responseStream

        Should -Invoke Invoke-DpTurn -Times 1 -Exactly
        $script:forwardedPrompt | Should -BeNullOrEmpty
        $script:forwardedAttachments.Count | Should -Be 1
    }

    It 'refuses a Message with neither a prompt nor an Attachment' {
        $body = [pscustomobject]@{ prompt = '   ' }

        Invoke-DpRouteHandler -Name 'postMessage' -RouteParams @{ id = $conversation.id } -Body $body -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 400 Bad Request'
        $json = ($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json
        $json.error.code | Should -Be 'empty_prompt'
        Should -Invoke Invoke-DpTurn -Times 0 -Exactly
    }

    It 'rejects an Attachment path that was not uploaded' {
        # Without the upload-store gate a crafted Message could name any local
        # file and have the Turn hand its path to the agent.
        $unregisteredPath = Join-Path $TestDrive 'unregistered.docx'
        Set-Content -LiteralPath $unregisteredPath -Value 'unregistered'
        $body = [pscustomobject]@{ prompt = 'Summarise this'; attachments = @($unregisteredPath) }

        Invoke-DpRouteHandler -Name 'postMessage' -RouteParams @{ id = $conversation.id } -Body $body -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 400 Bad Request'
        $json = ($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json
        $json.error.code | Should -Be 'invalid_attachment'
        Should -Invoke Invoke-DpTurn -Times 0 -Exactly
    }

    It 'carries the Attachments of the Message it re-runs' {
        # They belong to the Message rather than to its text, so a Regenerate that
        # replays only the words loses the files the answer was about.
        $conversation.messages.Add(@{
                id          = 'm_1'
                role        = 'user'
                text        = 'Summarise this'
                attachments = @(@{ name = 'notes.docx'; path = (Join-Path $attachmentRoot 'notes.docx') })
            })
        $conversation.messages.Add(@{ id = 'm_2'; role = 'assistant'; text = 'Done.' })

        Invoke-DpRouteHandler -Name 'regenerateTurn' -RouteParams @{ id = $conversation.id } -Body ([pscustomobject]@{}) -Stream $script:responseStream

        Should -Invoke Invoke-DpTurn -Times 1 -Exactly
        $script:forwardedPrompt | Should -Be 'Summarise this'
        $script:forwardedAttachments.Count | Should -Be 1
        $script:forwardedAttachments[0].name | Should -Be 'notes.docx'
    }

    It 'keeps the Attachments when the Message text is edited' {
        $conversation.messages.Add(@{
                id          = 'm_1'
                role        = 'user'
                text        = 'Summarise this'
                attachments = @(@{ name = 'notes.docx'; path = (Join-Path $attachmentRoot 'notes.docx') })
            })
        $body = [pscustomobject]@{ messageId = 'm_1'; prompt = 'Summarise it in German' }

        Invoke-DpRouteHandler -Name 'editTurn' -RouteParams @{ id = $conversation.id } -Body $body -Stream $script:responseStream

        Should -Invoke Invoke-DpTurn -Times 1 -Exactly
        $script:forwardedPrompt | Should -Be 'Summarise it in German'
        $script:forwardedAttachments.Count | Should -Be 1
        $script:forwardedAttachments[0].name | Should -Be 'notes.docx'
    }

    It 'rejects an uploaded non-image file as a Vision input' {
        $textPath = Join-Path $attachmentRoot 'notes.txt'
        Set-Content -LiteralPath $textPath -Value 'notes'
        $script:DeskPilot.Attachments[[System.IO.Path]::GetFullPath($textPath)] = 'text/plain'
        $body = [pscustomobject]@{ prompt = 'Describe this'; images = @($textPath) }

        Invoke-DpRouteHandler -Name 'postMessage' -RouteParams @{ id = $conversation.id } -Body $body -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 400 Bad Request'
        $json = ($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json
        $json.error.code | Should -Be 'invalid_attachment'
        Should -Invoke Invoke-DpTurn -Times 0 -Exactly
    }

    It 'records uploaded Attachment paths and content types' {
        Mock Get-DpMultipartBoundary { 'test-boundary' }
        Mock Read-DpMultipartParts {
            @([pscustomobject]@{
                    FileName   = 'clipboard.png'
                    Content    = [System.Text.Encoding]::UTF8.GetBytes('image bytes')
                    ContentType = 'image/png'
                })
        }
        $request = @{
            Headers   = @{ 'Content-Type' = 'multipart/form-data; boundary=test-boundary' }
            BodyBytes = [byte[]]@(1)
        }

        Invoke-DpRouteHandler -Name 'uploads' -Request $request -Stream $script:responseStream

        $savedPath = [System.IO.Path]::GetFullPath((Join-Path $attachmentRoot 'clipboard.png'))
        $script:DeskPilot.Attachments.ContainsKey($savedPath) | Should -BeTrue
        $script:DeskPilot.Attachments[$savedPath] | Should -Be 'image/png'
    }

    It 'refuses an image Attachment set that would overflow the request body' {
        $hugePath = Join-Path $attachmentRoot 'photo.jpg'
        [System.IO.File]::WriteAllBytes($hugePath, [byte[]]::new(4MB))
        $script:DeskPilot.Attachments[[System.IO.Path]::GetFullPath($hugePath)] = 'image/jpeg'
        $body = [pscustomobject]@{ prompt = 'What is in this photo?'; images = @($hugePath) }

        Invoke-DpRouteHandler -Name 'postMessage' -RouteParams @{ id = $conversation.id } -Body $body -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 413'
        $json = ($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json
        $json.error.code | Should -Be 'too_large'
        $json.error.message | Should -Match 'photo\.jpg'
        # The Turn must never start: a 413 from the Copilot endpoint costs a round
        # trip and surfaces as a raw EndInvoke exception with nothing to act on.
        Should -Invoke Invoke-DpTurn -Times 0 -Exactly
    }

    It 'refuses an image Attachment set whose total would overflow the request body' {
        $paths = foreach ($name in 'a.jpg', 'b.jpg', 'c.jpg') {
            $path = Join-Path $attachmentRoot $name
            [System.IO.File]::WriteAllBytes($path, [byte[]]::new(3MB))
            $script:DeskPilot.Attachments[[System.IO.Path]::GetFullPath($path)] = 'image/jpeg'
            $path
        }
        $body = [pscustomobject]@{ prompt = 'Compare these'; images = @($paths) }

        Invoke-DpRouteHandler -Name 'postMessage' -RouteParams @{ id = $conversation.id } -Body $body -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 413'
        $json = ($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json
        $json.error.code | Should -Be 'too_large'
        $json.error.message | Should -Match '3 images'
        Should -Invoke Invoke-DpTurn -Times 0 -Exactly
    }
}

Describe 'Get-DpVisionBudgetError' -Tag 'Unit' {
    BeforeEach {
        $script:imageRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:imageRoot | Out-Null
    }

    It 'accepts an empty Attachment set' {
        Get-DpVisionBudgetError -Path @() | Should -BeNullOrEmpty
    }

    It 'accepts images inside both budgets' {
        $first = Join-Path $script:imageRoot 'a.png'
        $second = Join-Path $script:imageRoot 'b.png'
        [System.IO.File]::WriteAllBytes($first, [byte[]]::new(400))
        [System.IO.File]::WriteAllBytes($second, [byte[]]::new(400))

        Get-DpVisionBudgetError -Path @($first, $second) -MaxImageBytes 1000 -MaxTotalBytes 1000 |
            Should -BeNullOrEmpty
    }

    It 'names the file and its actual size when one image is over the per-image budget' {
        $path = Join-Path $script:imageRoot 'holiday.jpg'
        [System.IO.File]::WriteAllBytes($path, [byte[]]::new(2MB))

        $message = Get-DpVisionBudgetError -Path @($path) -MaxImageBytes 1MB -MaxTotalBytes 8MB

        $message | Should -Match 'holiday\.jpg'
        # Invariant, not current-culture: on a de-DE host '{0:0.#}' would render
        # '1,5' and an assertion written with a dot would fail there and only there.
        $message | Should -Match '2 MB'
        $message | Should -Match '1 MB'
    }

    It 'formats sizes the same way under a comma-decimal culture' {
        $path = Join-Path $script:imageRoot 'holiday.jpg'
        [System.IO.File]::WriteAllBytes($path, [byte[]]::new(1536KB))

        $previous = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('de-DE')
            $message = Get-DpVisionBudgetError -Path @($path) -MaxImageBytes 1MB -MaxTotalBytes 8MB
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $previous }

        $message | Should -Match '1\.5 MB'
        $message | Should -Not -Match '1,5 MB'
    }

    It 'refuses a set whose total exceeds the budget even when each image fits' {
        $paths = foreach ($name in 'one.png', 'two.png', 'three.png') {
            $path = Join-Path $script:imageRoot $name
            [System.IO.File]::WriteAllBytes($path, [byte[]]::new(400KB))
            $path
        }

        $message = Get-DpVisionBudgetError -Path $paths -MaxImageBytes 1MB -MaxTotalBytes 1MB

        $message | Should -Match '3 images'
        $message | Should -Match '1\.2 MB'
    }

    It 'refuses a camera-sized photo at the shipped defaults' {
        # Guards the numbers that actually ship, not just the comparison: a 4 MB
        # JPEG is ~5.3 MB once base64-encoded into the request body.
        $path = Join-Path $script:imageRoot 'camera.jpg'
        [System.IO.File]::WriteAllBytes($path, [byte[]]::new(4MB))

        Get-DpVisionBudgetError -Path @($path) | Should -Not -BeNullOrEmpty
    }

    It 'accepts a downscaled image at the shipped defaults' {
        $path = Join-Path $script:imageRoot 'downscaled.jpg'
        [System.IO.File]::WriteAllBytes($path, [byte[]]::new(300KB))

        Get-DpVisionBudgetError -Path @($path) | Should -BeNullOrEmpty
    }
}