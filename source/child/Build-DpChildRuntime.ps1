param(
    [Parameter(Mandatory)]
    [string]$SourceDirectory,

    [Parameter(Mandatory)]
    [string]$OutputAssembly
)

$ErrorActionPreference = 'Stop'
$sources = @(Get-ChildItem -LiteralPath $SourceDirectory -Filter '*.cs' -File | Select-Object -ExpandProperty FullName)
Add-Type -Path $sources -OutputAssembly $OutputAssembly -ErrorAction Stop
