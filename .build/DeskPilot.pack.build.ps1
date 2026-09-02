# Windows packaging task. Added alongside the normal module build rather than
# inside it: `build` and `test` behave exactly as before, and packaging is an
# explicit extra step (./build.ps1 -Tasks build, pack_windows).

task pack_windows {
    . Set-SamplerTaskVariable -AsNewBuild

    # Set-SamplerTaskVariable already resolves BuiltModuleSubdirectory to an
    # absolute path, and VersionedOutputDirectory puts the module one level
    # deeper under its version folder.
    $moduleParent = Join-Path $BuiltModuleSubdirectory 'DeskPilot'
    $moduleRoot = Join-Path $moduleParent $ModuleVersion
    if (-not (Test-Path -LiteralPath $moduleRoot -PathType Container)) {
        $newest = Get-ChildItem -LiteralPath $moduleParent -Directory -ErrorAction Ignore |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($newest) { $moduleRoot = $newest.FullName }
    }
    if (-not (Test-Path -LiteralPath $moduleRoot -PathType Container)) {
        throw "The built module was not found at '$moduleRoot'. Run the build task first."
    }

    $destination = Join-Path $OutputDirectory 'package'
    if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $destination -Force
    }

    $result = New-DpWindowsPackage `
        -ModulePath $moduleRoot `
        -ScriptPath (Join-Path $BuildRoot 'packaging') `
        -Destination $destination `
        -Version $ModuleVersion `
        -RequiredModulesPath (Join-Path $BuildRoot 'RequiredModules.psd1') `
        -ResolvedModulesPath (Join-Path $OutputDirectory 'RequiredModules') `
        -Confirm:$false

    $problems = @(Test-DpPackageInventory -Path $result.PackageRoot)
    if ($problems.Count -gt 0) {
        throw "The package does not match its own manifest:`n$($problems -join "`n")"
    }

    Write-Build Green "Package: $($result.ZipPath)"
    Write-Build DarkGray "  files : $($result.FileCount)"
    Write-Build DarkGray "  sha256: $($result.ZipSha256)"

    # The hash goes beside the artifact so a release can publish it without
    # re-reading the ZIP, and so a mismatch is checkable offline.
    "$($result.ZipSha256)  $(Split-Path -Leaf $result.ZipPath)" |
        Set-Content -LiteralPath "$($result.ZipPath).sha256" -Encoding utf8
}
