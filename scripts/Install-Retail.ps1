param(
    [string]$AddOnsPath = 'C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns'
)
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Emberlight'))
$addonsRoot = (Resolve-Path -LiteralPath $AddOnsPath).Path
$targetRoot = [IO.Path]::GetFullPath((Join-Path $addonsRoot 'Emberlight'))
if (-not $targetRoot.StartsWith($addonsRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Install target must remain inside the selected AddOns directory.'
}
foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File) {
    $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
    $destination = Join-Path $targetRoot $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $destination).Hash) {
        throw "Verification failed for $relative"
    }
}
Write-Output "Installed and hash-verified Emberlight at $targetRoot"
Write-Output 'First installation: fully restart WoW. Subsequent Lua edits: /reload.'
