#requires -Version 7.0

# Guards for the Windows CurrentUser package. They cover the packaging helpers
# the build task actually calls (.build/DeskPilotPackaging.ps1) and the install
# and uninstall scripts that ship inside the artifact.

BeforeAll {
    . (Join-Path $PSScriptRoot '..' '..' '.build' 'DeskPilotPackaging.ps1')
    $script:packagingRoot = Join-Path $PSScriptRoot '..' '..' 'packaging' | Convert-Path
    $script:repoRoot = Join-Path $PSScriptRoot '..' '..' | Convert-Path

    function New-DpFakeModule {
        param([string]$Path, [string]$Version)
        $module = Join-Path $Path 'DeskPilot' $Version
        $null = New-Item -ItemType Directory -Path (Join-Path $module 'web' 'assets') -Force
        Set-Content -LiteralPath (Join-Path $module 'DeskPilot.psm1') -Value 'function Start-DeskPilot { }' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $module 'DeskPilot.psd1') -Value "@{ ModuleVersion = '$Version' }" -Encoding utf8
        Set-Content -LiteralPath (Join-Path $module 'web' 'index.html') -Value '<!doctype html>' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $module 'web' 'assets' 'app.js') -Value 'export {};' -Encoding utf8
        $module
    }
}

Describe 'Package inventory' -Tag 'Unit' {
    It 'records every file with its size and hash, using forward slashes' {
        $root = Join-Path $TestDrive 'inv'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'sub') -Force
        Set-Content -LiteralPath (Join-Path $root 'a.txt') -Value 'a' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $root 'sub' 'b.txt') -Value 'b' -Encoding utf8

        $files = @(New-DpPackageInventory -Path $root)

        $files.Count | Should -Be 2
        $files.path | Should -Contain 'sub/b.txt'
        $files[0].sha256 | Should -Match '^[0-9A-F]{64}$'
        ($files | Where-Object { $_.path -eq 'a.txt' }).bytes | Should -BeGreaterThan 0
    }

    It 'verifies a package that matches its manifest' {
        $root = Join-Path $TestDrive 'verify-ok'
        $null = New-Item -ItemType Directory -Path $root -Force
        Set-Content -LiteralPath (Join-Path $root 'a.txt') -Value 'a' -Encoding utf8
        @{ files = @(New-DpPackageInventory -Path $root) } | ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath (Join-Path $root 'package-manifest.json') -Encoding utf8

        @(Test-DpPackageInventory -Path $root) | Should -BeNullOrEmpty
    }

    It 'fails closed on a changed, missing or undeclared file' {
        $root = Join-Path $TestDrive 'verify-bad'
        $null = New-Item -ItemType Directory -Path $root -Force
        Set-Content -LiteralPath (Join-Path $root 'a.txt') -Value 'a' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $root 'gone.txt') -Value 'g' -Encoding utf8
        @{ files = @(New-DpPackageInventory -Path $root) } | ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath (Join-Path $root 'package-manifest.json') -Encoding utf8

        Set-Content -LiteralPath (Join-Path $root 'a.txt') -Value 'tampered' -Encoding utf8
        Remove-Item -LiteralPath (Join-Path $root 'gone.txt') -Force
        Set-Content -LiteralPath (Join-Path $root 'extra.txt') -Value 'x' -Encoding utf8

        $problems = @(Test-DpPackageInventory -Path $root)
        $problems | Should -Contain 'changed: a.txt'
        $problems | Should -Contain 'missing: gone.txt'
        $problems | Should -Contain 'undeclared: extra.txt'
    }

    It 'reports a package with no manifest at all' {
        $root = Join-Path $TestDrive 'verify-none'
        $null = New-Item -ItemType Directory -Path $root -Force
        @(Test-DpPackageInventory -Path $root) | Should -Contain 'package-manifest.json is missing.'
    }
}

Describe 'Package SBOM' -Tag 'Unit' {
    It 'names DeskPilot and every declared dependency' {
        $sbom = New-DpPackageSbom -Version '1.2.3' `
            -RequiredModulesPath (Join-Path $script:repoRoot 'RequiredModules.psd1') `
            -ResolvedModulesPath ''

        $sbom.bomFormat | Should -Be 'CycloneDX'
        $names = @($sbom.components | ForEach-Object { $_.name })
        $names | Should -Contain 'DeskPilot'
        $names | Should -Contain 'ShellPilot'
        $names | Should -Contain 'Pester'
        ($sbom.components | Where-Object { $_.name -eq 'DeskPilot' }).version | Should -Be '1.2.3'
    }

    It 'prefers the resolved version over a "latest" declaration' {
        $resolved = Join-Path $TestDrive 'resolved'
        $null = New-Item -ItemType Directory -Path (Join-Path $resolved 'Pester' '5.7.1') -Force

        $sbom = New-DpPackageSbom -Version '1.2.3' `
            -RequiredModulesPath (Join-Path $script:repoRoot 'RequiredModules.psd1') `
            -ResolvedModulesPath $resolved

        ($sbom.components | Where-Object { $_.name -eq 'Pester' }).version | Should -Be '5.7.1'
    }
}

Describe 'Windows package' -Tag 'Unit' {
    BeforeEach {
        $script:stage = Join-Path $TestDrive ('pkg-' + [guid]::NewGuid().ToString('N'))
        $script:moduleSource = New-DpFakeModule -Path (Join-Path $script:stage 'built') -Version '9.9.9'
        $script:destination = Join-Path $script:stage 'out'
        $null = New-Item -ItemType Directory -Path $script:destination -Force
    }

    It 'assembles a self-verifying package with the module, scripts, manifest and SBOM' {
        $result = New-DpWindowsPackage -ModulePath $script:moduleSource -ScriptPath $script:packagingRoot `
            -Destination $script:destination -Version '9.9.9' `
            -RequiredModulesPath (Join-Path $script:repoRoot 'RequiredModules.psd1') `
            -ResolvedModulesPath '' -Confirm:$false

        Test-Path -LiteralPath (Join-Path $result.PackageRoot 'module' 'DeskPilot' '9.9.9' 'DeskPilot.psd1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $result.PackageRoot 'module' 'DeskPilot' '9.9.9' 'web' 'index.html') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $result.PackageRoot 'Install-DeskPilot.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $result.PackageRoot 'Uninstall-DeskPilot.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $result.PackageRoot 'sbom.json') | Should -BeTrue
        Test-Path -LiteralPath $result.ZipPath | Should -BeTrue
        $result.ZipSha256 | Should -Match '^[0-9A-F]{64}$'
        @(Test-DpPackageInventory -Path $result.PackageRoot) | Should -BeNullOrEmpty
    }

    It 'excludes build leftovers and signing material from the artifact' {
        Set-Content -LiteralPath (Join-Path $script:moduleSource 'scratch.tmp') -Value 'temp' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleSource 'signing.pfx') -Value 'secret' -Encoding utf8

        $result = New-DpWindowsPackage -ModulePath $script:moduleSource -ScriptPath $script:packagingRoot `
            -Destination $script:destination -Version '9.9.9' `
            -RequiredModulesPath (Join-Path $script:repoRoot 'RequiredModules.psd1') `
            -ResolvedModulesPath '' -Confirm:$false

        $manifest = Get-Content -LiteralPath (Join-Path $result.PackageRoot 'package-manifest.json') -Raw | ConvertFrom-Json
        @($manifest.files.path) | Should -Not -Contain 'module/DeskPilot/9.9.9/scratch.tmp'
        @($manifest.files.path) | Should -Not -Contain 'module/DeskPilot/9.9.9/signing.pfx'
        @(Test-DpPackageInventory -Path $result.PackageRoot) | Should -BeNullOrEmpty
    }

    It 'handles a destination path containing spaces and non-ASCII characters' {
        $odd = Join-Path $script:stage 'Ausgabe Ordner mit Umlauten äöü'
        $null = New-Item -ItemType Directory -Path $odd -Force

        $result = New-DpWindowsPackage -ModulePath $script:moduleSource -ScriptPath $script:packagingRoot `
            -Destination $odd -Version '9.9.9' `
            -RequiredModulesPath (Join-Path $script:repoRoot 'RequiredModules.psd1') `
            -ResolvedModulesPath '' -Confirm:$false

        Test-Path -LiteralPath $result.ZipPath | Should -BeTrue
        @(Test-DpPackageInventory -Path $result.PackageRoot) | Should -BeNullOrEmpty
    }

    It 'refuses to package when an install script is missing' {
        $emptyScripts = Join-Path $script:stage 'no-scripts'
        $null = New-Item -ItemType Directory -Path $emptyScripts -Force

        { New-DpWindowsPackage -ModulePath $script:moduleSource -ScriptPath $emptyScripts `
                -Destination $script:destination -Version '9.9.9' `
                -RequiredModulesPath (Join-Path $script:repoRoot 'RequiredModules.psd1') `
                -ResolvedModulesPath '' -Confirm:$false } | Should -Throw '*Install-DeskPilot.ps1*'
    }

    It 'writes a manifest that declares the scope as CurrentUser' {
        $result = New-DpWindowsPackage -ModulePath $script:moduleSource -ScriptPath $script:packagingRoot `
            -Destination $script:destination -Version '9.9.9' `
            -RequiredModulesPath (Join-Path $script:repoRoot 'RequiredModules.psd1') `
            -ResolvedModulesPath '' -Confirm:$false

        $manifest = Get-Content -LiteralPath (Join-Path $result.PackageRoot 'package-manifest.json') -Raw | ConvertFrom-Json
        $manifest.scope | Should -Be 'CurrentUser'
        $manifest.version | Should -Be '9.9.9'
        $manifest.fileCount | Should -Be $result.FileCount
    }
}

Describe 'Install and uninstall scripts' -Tag 'Unit' {
    BeforeAll {
        $script:installSource = Get-Content -LiteralPath (Join-Path $script:packagingRoot 'Install-DeskPilot.ps1') -Raw
        $script:uninstallSource = Get-Content -LiteralPath (Join-Path $script:packagingRoot 'Uninstall-DeskPilot.ps1') -Raw
    }

    It 'parses without error' {
        foreach ($name in 'Install-DeskPilot.ps1', 'Uninstall-DeskPilot.ps1') {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $script:packagingRoot $name), [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty
        }
    }

    It 'never elevates and never installs machine-wide' {
        foreach ($source in $script:installSource, $script:uninstallSource) {
            $source | Should -Not -Match 'RunAs'
            $source | Should -Not -Match 'ProgramFiles'
            $source | Should -Not -Match 'HKLM'
        }
    }

    It 'verifies the package before copying anything' {
        # The verification loop has to precede the copy, or a damaged payload is
        # already on disk by the time it is rejected.
        $verifyAt = $script:installSource.IndexOf('does not match its checksum')
        $copyAt = $script:installSource.IndexOf('Install the DeskPilot module for the current user')
        $verifyAt | Should -BeGreaterThan 0
        $copyAt | Should -BeGreaterThan $verifyAt
    }

    It 'resolves the CurrentUser module path from PSModulePath under the home folder' {
        $script:installSource | Should -Match 'PSModulePath -split'
        $script:installSource | Should -Match ([regex]::Escape('$_.StartsWith($HOME'))
    }

    It 'keeps user data on uninstall unless removal is asked for explicitly' {
        $script:uninstallSource | Should -Match '\[switch\]\$RemoveData'
        $script:uninstallSource | Should -Match 'ConfirmImpact = ''High'''
        $script:uninstallSource | Should -Match 'were kept in'
        # The data directory may only be deleted inside the -RemoveData branch.
        $removeDataAt = $script:uninstallSource.IndexOf('if ($RemoveData)')
        $deleteAt = $script:uninstallSource.IndexOf('Remove-Item -LiteralPath $dataDir')
        $removeDataAt | Should -BeGreaterThan 0
        $deleteAt | Should -BeGreaterThan $removeDataAt
    }

    It 'is wired into the build as a separate workflow that does not change build or test' {
        $buildYaml = Get-Content -LiteralPath (Join-Path $script:repoRoot 'build.yaml') -Raw
        $buildYaml | Should -Match '(?m)^\s+packwin:'
        $buildYaml | Should -Match '(?m)^\s+- pack_windows'
        # The default workflows must still be exactly build + test.
        $buildYaml | Should -Match "(?ms)^  '\.':\r?\n    - build\r?\n    - test"
        $buildYaml | Should -Not -Match "(?ms)^  build:(?:(?!^  \w).)*pack_windows"
    }
}
