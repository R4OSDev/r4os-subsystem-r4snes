[CmdletBinding()]
param(
    [string]$ReferenceRoot,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot '../../..'))
if ([string]::IsNullOrWhiteSpace($ReferenceRoot)) {
    $ReferenceRoot = Join-Path $workspaceRoot 'ExFiles/Reference/SNES'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $workspaceRoot 'Temp/R4SNES-SuperFX'
}
$ReferenceRoot = [System.IO.Path]::GetFullPath($ReferenceRoot)
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

if ($IsWindows) {
    $toolRoot = Join-Path $ReferenceRoot 'Tools/WLA-DX-v10.7-Windows-x86_64/wla_dx_v10.7_Win64'
    $assembler = Join-Path $toolRoot 'wla-superfx.exe'
    $linker = Join-Path $toolRoot 'wlalink.exe'
} elseif ($IsLinux) {
    $toolRoot = Join-Path $ReferenceRoot 'Tools/WLA-DX-v10.7-Linux-x86_64'
    $assembler = Join-Path $toolRoot 'wla-superfx'
    $linker = Join-Path $toolRoot 'wlalink'
} else {
    throw 'Only Windows and Linux hosts are supported.'
}

$templateRoot = Join-Path $ReferenceRoot 'Documentation/OpenSNES/templates'
$openSnesRoot = Join-Path $ReferenceRoot 'Documentation/OpenSNES/examples/chips'
foreach ($required in @($assembler, $linker, (Join-Path $templateRoot 'memmap_gsu.inc'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required pinned Super FX build input is missing: $required"
    }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$programs = @(
    @{ Name = 'opensnes_hello'; Source = Join-Path $openSnesRoot 'superfx_hello/gsu_hello.sfx'; Origin = 'OpenSNES' },
    @{ Name = 'opensnes_3d'; Source = Join-Path $openSnesRoot 'superfx_3d/gsu_3d.sfx'; Origin = 'OpenSNES' },
    @{ Name = 'r4snes_opcode'; Source = Join-Path $PSScriptRoot 'SuperFxPrograms/r4snes_opcode.sfx'; Origin = 'R4SNES' },
    @{ Name = 'r4snes_cache'; Source = Join-Path $PSScriptRoot 'SuperFxPrograms/r4snes_cache.sfx'; Origin = 'R4SNES' },
    @{ Name = 'r4snes_pixel'; Source = Join-Path $PSScriptRoot 'SuperFxPrograms/r4snes_pixel.sfx'; Origin = 'R4SNES' },
    @{ Name = 'r4snes_bus'; Source = Join-Path $PSScriptRoot 'SuperFxPrograms/r4snes_bus.sfx'; Origin = 'R4SNES' }
)

$manifestPrograms = @()
foreach ($program in $programs) {
    if (-not (Test-Path -LiteralPath $program.Source -PathType Leaf)) {
        throw "Super FX source is missing: $($program.Source)"
    }
    $objectPath = Join-Path $OutputDirectory "$($program.Name).o"
    $linkPath = Join-Path $OutputDirectory "$($program.Name).link"
    $binaryPath = Join-Path $OutputDirectory "$($program.Name).bin"
    & $assembler -I $templateRoot -o $objectPath $program.Source
    if ($LASTEXITCODE -ne 0) { throw "wla-superfx failed for $($program.Name) with exit code $LASTEXITCODE" }
    [System.IO.File]::WriteAllText($linkPath, "[objects]`n$objectPath`n", [System.Text.UTF8Encoding]::new($false))
    & $linker -b $linkPath $binaryPath
    if ($LASTEXITCODE -ne 0) { throw "wlalink failed for $($program.Name) with exit code $LASTEXITCODE" }
    $file = Get-Item -LiteralPath $binaryPath
    $manifestPrograms += [ordered]@{
        name = $program.Name
        origin = $program.Origin
        source = [System.IO.Path]::GetRelativePath($workspaceRoot, $program.Source).Replace('\', '/')
        binary = $file.Name
        bytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$manifest = [ordered]@{
    schema = 1
    tool = 'WLA-DX 10.7 wla-superfx/wlalink'
    programs = $manifestPrograms
}
$manifestPath = Join-Path $OutputDirectory 'manifest.json'
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5) + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "R4SNES Super FX programs built reproducibly: $($programs.Count) -> $OutputDirectory"
