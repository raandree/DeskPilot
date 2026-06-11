#requires -Version 7.0

Set-StrictMode -Version Latest

$privateFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue
$publicFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue

foreach ($file in @($privateFiles) + @($publicFiles)) {
    . $file.FullName
}

Export-ModuleMember -Function @($publicFiles | ForEach-Object { $_.BaseName })
