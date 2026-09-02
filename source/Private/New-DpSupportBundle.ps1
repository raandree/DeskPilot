function New-DpSupportBundle {
    <#
    .SYNOPSIS
        Creates one bounded, redacted DeskPilot support bundle.
    .DESCRIPTION
        Writes three allow-listed text records directly into a ZIP archive under
        <DataDir>/support-bundles. No staging tree is created. The destination is
        a direct child of that directory, existing files are never overwritten,
        reparse-point redirection is refused, and both uncompressed and archive
        byte ceilings are enforced.
    .PARAMETER Directory
        DeskPilot's resolved data directory.
    .PARAMETER Destination
        Optional exact ZIP path, used by tests. It must be a direct child of the
        support-bundles directory. API callers cannot supply it.
    .PARAMETER Record
        Optional allow-listed record from New-DpSupportBundleRecord.
    .PARAMETER MaxUncompressedBytes
        Maximum total UTF-8 bytes before compression.
    .PARAMETER MaxArchiveBytes
        Maximum final ZIP bytes.
    .PARAMETER ReparsePointTester
        Injectable path inspection used to refuse junction and symlink targets.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [string]$Destination,

        [object]$Record,

        [ValidateRange(128, 10485760)]
        [long]$MaxUncompressedBytes = 2097152,

        [ValidateRange(1024, 10485760)]
        [long]$MaxArchiveBytes = 3145728,

        [scriptblock]$ReparsePointTester = {
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path)) { return $false }
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        }
    )

    $result = @{
        ok = $false; code = ''; error = ''; path = ''; name = ''
        createdUtc = ''; bytes = [long]0; uncompressedBytes = [long]0; entries = 0
    }
    $tempPath = $null
    $fileStream = $null
    $archive = $null

    try {
        $dataFull = [System.IO.Path]::GetFullPath($Directory).TrimEnd('\', '/')
        if (-not (Test-Path -LiteralPath $dataFull -PathType Container)) {
            $result.code = 'invalid_data_directory'
            $result.error = 'The DeskPilot data directory is unavailable.'
            return $result
        }
        if (& $ReparsePointTester $dataFull) {
            $result.code = 'redirected_destination'
            $result.error = 'The support-bundle destination passes through a reparse point.'
            return $result
        }

        $bundleDirectory = [System.IO.Path]::GetFullPath((Join-Path $dataFull 'support-bundles')).TrimEnd('\', '/')
        if ([string]::IsNullOrWhiteSpace($Destination)) {
            $fileName = 'DeskPilot-support-{0}-{1}.zip' -f [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N').Substring(0, 8)
            $target = Join-Path $bundleDirectory $fileName
        }
        else {
            $target = [System.IO.Path]::GetFullPath($Destination)
            $fileName = [System.IO.Path]::GetFileName($target)
        }

        $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        $targetParent = [System.IO.Path]::GetFullPath((Split-Path -Path $target -Parent)).TrimEnd('\', '/')
        if (-not $targetParent.Equals($bundleDirectory, $comparison) -or
            [System.IO.Path]::GetExtension($target) -ne '.zip' -or
            $fileName -notmatch '^[A-Za-z0-9._-]+\.zip$') {
            $result.code = 'outside_destination'
            $result.error = 'A support bundle can be created only inside the DeskPilot support-bundles directory.'
            return $result
        }
        if (Test-Path -LiteralPath $target) {
            $result.code = 'already_exists'
            $result.error = 'The support-bundle destination already exists and will not be overwritten.'
            return $result
        }

        if (-not $PSBoundParameters.ContainsKey('Record') -or $null -eq $Record) {
            $Record = New-DpSupportBundleRecord
        }
        $diagnosticsJson = ($Record | ConvertTo-Json -Depth 12) + "`n"
        $logLines = foreach ($entry in @($Record.logs)) { $entry | ConvertTo-Json -Compress -Depth 4 }
        $hostLog = if (@($logLines).Count -gt 0) { (@($logLines) -join "`n") + "`n" } else { '' }

        $summary = [System.Collections.Generic.List[string]]::new()
        $checkStates = @($Record.checks | ForEach-Object {
                [string](Get-DpPropertyValue -InputObject $_ -Name @('state') -Default 'degraded')
            })
        $overallState = if ($checkStates -contains 'unavailable') { 'unavailable' }
            elseif ($checkStates -contains 'degraded') { 'degraded' }
            elseif ($checkStates.Count -gt 0) { 'healthy' }
            else { 'unavailable' }
        $summary.Add('# DeskPilot support bundle')
        $summary.Add('')
        $summary.Add("Created: $($Record.createdUtc)")
        $summary.Add("Overall state: $overallState")
        $summary.Add('')
        $summary.Add('## Versions')
        $summary.Add('')
        foreach ($name in 'deskPilot', 'powerShell', 'engine', 'git', 'operatingSystem') {
            $summary.Add("- ${name}: $($Record.versions[$name])")
        }
        $summary.Add('')
        $summary.Add('## Checks')
        $summary.Add('')
        foreach ($check in @($Record.checks)) {
            $line = "- $($check.label): $($check.state) - $($check.explanation)"
            if ($check.action) { $line += " Next: $($check.action)" }
            $summary.Add($line)
        }
        $summary.Add('')
        $summary.Add('Absolute paths, Messages, prompts, answers, reasoning, file contents, diffs, Tool arguments, credentials, cookies, and environment values are intentionally excluded.')
        $summaryText = ($summary -join "`n") + "`n"

        $content = [ordered]@{
            'summary.md'      = $summaryText
            'diagnostics.json' = $diagnosticsJson
            'host-log.jsonl'  = $hostLog
        }
        $uncompressedBytes = [long]0
        foreach ($value in $content.Values) {
            $uncompressedBytes += [System.Text.Encoding]::UTF8.GetByteCount([string]$value)
        }
        $result.uncompressedBytes = $uncompressedBytes
        if ($uncompressedBytes -gt $MaxUncompressedBytes) {
            $result.code = 'too_large'
            $result.error = "The support bundle would exceed the $MaxUncompressedBytes-byte input limit."
            return $result
        }

        $result.path = $target
        $result.name = $fileName
        if (-not $PSCmdlet.ShouldProcess($target, 'Create redacted support bundle')) { return $result }

        if (-not (Test-Path -LiteralPath $bundleDirectory)) {
            New-Item -ItemType Directory -Path $bundleDirectory -ErrorAction Stop | Out-Null
        }
        if (& $ReparsePointTester $bundleDirectory) {
            $result.code = 'redirected_destination'
            $result.error = 'The support-bundles directory is a reparse point.'
            return $result
        }

        $tempPath = Join-Path $bundleDirectory ('.support-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $fileStream = [System.IO.FileStream]::new(
            $tempPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $archive = [System.IO.Compression.ZipArchive]::new(
            $fileStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        foreach ($entryName in $content.Keys) {
            $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $writer = [System.IO.StreamWriter]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false))
            try { $writer.Write([string]$content[$entryName]) } finally { $writer.Dispose() }
        }
        $archive.Dispose()
        $archive = $null
        $fileStream.Dispose()
        $fileStream = $null

        $archiveBytes = (Get-Item -LiteralPath $tempPath -ErrorAction Stop).Length
        if ($archiveBytes -gt $MaxArchiveBytes) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            $tempPath = $null
            $result.code = 'too_large'
            $result.error = "The support bundle would exceed the $MaxArchiveBytes-byte archive limit."
            return $result
        }

        [System.IO.File]::Move($tempPath, $target, $false)
        $tempPath = $null
        $result.ok = $true
        $result.code = 'created'
        $result.createdUtc = [datetime]::UtcNow.ToString('o')
        $result.bytes = $archiveBytes
        $result.entries = $content.Count
        $result
    }
    catch {
        $bundleError = $_
        if (-not $result.code) {
            $result.code = if (Test-Path -LiteralPath $result.path -ErrorAction SilentlyContinue) { 'already_exists' } else { 'create_failed' }
        }
        $result.error = Protect-DpDiagnosticText -Text $bundleError.Exception.Message
        $result
    }
    finally {
        if ($archive) { try { $archive.Dispose() } catch { $null = $_ } }
        if ($fileStream) { try { $fileStream.Dispose() } catch { $null = $_ } }
        if ($tempPath -and (Test-Path -LiteralPath $tempPath)) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}