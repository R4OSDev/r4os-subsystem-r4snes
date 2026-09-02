[CmdletBinding()]
param(
    [string]$ReferenceRoot,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot '../../..'))
if ([string]::IsNullOrWhiteSpace($ReferenceRoot)) {
    $ReferenceRoot = Join-Path $workspaceRoot 'ExFiles/Reference/SNES'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $workspaceRoot 'Temp/R4SNES-CX4'
}
$ReferenceRoot = [System.IO.Path]::GetFullPath($ReferenceRoot)
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Native command failed ($LASTEXITCODE): $FilePath $($Arguments -join ' ')"
    }
}

$wlaRevision = '91c52b1f4ef3cc8ba3c0638f7536539579af6a9f'
$wlaSource = Join-Path $ReferenceRoot 'Tools/WLA-DX'
$actualRevision = (& git -C $wlaSource rev-parse HEAD | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0 -or $actualRevision -ne $wlaRevision) {
    throw "Pinned WLA-DX revision mismatch: $actualRevision"
}

if ($IsWindows) {
    $toolRoot = Join-Path $ReferenceRoot 'Tools/WLA-DX-v10.7-Windows-x86_64/wla_dx_v10.7_Win64'
    $assembler = Join-Path $toolRoot 'wla-cx4.exe'
    $linker = Join-Path $toolRoot 'wlalink.exe'
} elseif ($IsLinux) {
    $cmake = (Get-Command cmake -ErrorAction Stop).Source
    $ninja = (Get-Command ninja -ErrorAction Stop).Source
    $toolBuild = Join-Path $workspaceRoot 'Temp/WLA-DX-CX4'
    Invoke-Native -FilePath $cmake -Arguments @(
        '-S', $wlaSource, '-B', $toolBuild, '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release',
        "-DCMAKE_MAKE_PROGRAM=$ninja"
    )
    Invoke-Native -FilePath $cmake -Arguments @('--build', $toolBuild, '--target', 'wla-cx4', 'wlalink')
    $assembler = Join-Path $toolBuild 'binaries/wla-cx4'
    $linker = Join-Path $toolBuild 'binaries/wlalink'
} else {
    throw 'Only Windows and Linux hosts are supported.'
}

foreach ($required in @($assembler, $linker)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required pinned CX4 tool is missing: $required"
    }
}

$programs = @(
    [ordered]@{
        Name = 'wla_hello'
        Origin = 'WLA-DX'
        Source = Join-Path $wlaSource 'tests/cx4/hello_world_test/cx4_prog.s'
    },
    [ordered]@{
        Name = 'wla_hg51b_instructions'
        Origin = 'WLA-DX'
        Source = Join-Path $wlaSource 'tests/cx4/hg51b_instructions_test/cx4_prog.s'
    },
    [ordered]@{
        Name = 'r4snes_geometry'
        Origin = 'R4SNES'
        Source = Join-Path $PSScriptRoot 'Cx4Programs/r4snes_geometry.s'
    },
    [ordered]@{
        Name = 'r4snes_bus'
        Origin = 'R4SNES'
        Source = Join-Path $PSScriptRoot 'Cx4Programs/r4snes_bus.s'
    }
)

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$manifestPrograms = @()
foreach ($program in $programs) {
    if (-not (Test-Path -LiteralPath $program.Source -PathType Leaf)) {
        throw "CX4 source is missing: $($program.Source)"
    }
    $objectPath = Join-Path $OutputDirectory "$($program.Name).o"
    $linkPath = Join-Path $OutputDirectory "$($program.Name).link"
    $binaryPath = Join-Path $OutputDirectory "$($program.Name).bin"
    Invoke-Native -FilePath $assembler -Arguments @('-o', $objectPath, $program.Source)
    [System.IO.File]::WriteAllText($linkPath, "[objects]`n$objectPath`n", [System.Text.UTF8Encoding]::new($false))
    Invoke-Native -FilePath $linker -Arguments @('-b', $linkPath, $binaryPath)
    $file = Get-Item -LiteralPath $binaryPath
    $manifestPrograms += [ordered]@{
        name = $program.Name
        origin = $program.Origin
        source = [System.IO.Path]::GetRelativePath($workspaceRoot, $program.Source).Replace('\', '/')
        source_sha256 = (Get-FileHash -LiteralPath $program.Source -Algorithm SHA256).Hash.ToLowerInvariant()
        binary = $file.Name
        bytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$oracleSources = @(
    [ordered]@{
        name = 'Ares HG51B/HitachiDSP'
        revision = '7b51c8ab719e403a150aa700e0933d9e93a06851'
        files = @(
            'Implementations/Ares/ares/component/processor/hg51b/instruction.cpp',
            'Implementations/Ares/ares/component/processor/hg51b/instructions.cpp',
            'Implementations/Ares/ares/component/processor/hg51b/registers.cpp',
            'Implementations/Ares/ares/sfc/coprocessor/hitachidsp/memory.cpp'
        )
    },
    [ordered]@{
        name = 'Mesen2 CX4'
        revision = 'b9fa69ddc6d0a331fb103fdb5eef6904305703c2'
        files = @(
            'Implementations/Mesen2/Core/SNES/Coprocessors/CX4/Cx4.cpp',
            'Implementations/Mesen2/Core/SNES/Coprocessors/CX4/Cx4.Instructions.cpp'
        )
    }
)
foreach ($oracle in $oracleSources) {
    $repositoryName = if ($oracle.name -like 'Ares*') { 'Ares' } else { 'Mesen2' }
    $repositoryPath = Join-Path $ReferenceRoot "Implementations/$repositoryName"
    $actualOracleRevision = (& git -C $repositoryPath rev-parse HEAD | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualOracleRevision -ne $oracle.revision) {
        throw "Pinned $repositoryName revision mismatch: $actualOracleRevision"
    }
    $oracle.files = @($oracle.files | ForEach-Object {
        $path = Join-Path $ReferenceRoot $_
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "CX4 oracle source is missing: $path" }
        [ordered]@{
            path = $_
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
}

$manifest = [ordered]@{
    schema = 1
    tool = 'WLA-DX 10.7 wla-cx4/wlalink'
    wla_revision = $wlaRevision
    programs = $manifestPrograms
    oracle_sources = $oracleSources
}
[System.IO.File]::WriteAllText(
    (Join-Path $OutputDirectory 'manifest.json'),
    ($manifest | ConvertTo-Json -Depth 8) + "`n",
    [System.Text.UTF8Encoding]::new($false)
)
Write-Host "R4SNES CX4 programs built reproducibly: $($programs.Count) -> $OutputDirectory"
