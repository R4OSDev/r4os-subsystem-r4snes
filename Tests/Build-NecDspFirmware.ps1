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
    $OutputDirectory = Join-Path $workspaceRoot 'Temp/R4SNES-NECDSP'
}
$ReferenceRoot = [System.IO.Path]::GetFullPath($ReferenceRoot)
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

function New-OperationOpcode {
    param(
        [int]$P = 0,
        [int]$Alu = 0,
        [bool]$SelectB = $false,
        [int]$DpLow = 0,
        [int]$DpHigh = 0,
        [bool]$RpDecrement = $false,
        [int]$Source = 0,
        [int]$Destination = 0,
        [bool]$Return = $false
    )
    [uint32]$value = if ($Return) { 0x400000 } else { 0 }
    $value = $value -bor ([uint32]$P -shl 20)
    $value = $value -bor ([uint32]$Alu -shl 16)
    $value = $value -bor ([uint32][int]$SelectB -shl 15)
    $value = $value -bor ([uint32]$DpLow -shl 13)
    $value = $value -bor ([uint32]$DpHigh -shl 9)
    $value = $value -bor ([uint32][int]$RpDecrement -shl 8)
    $value = $value -bor ([uint32]$Source -shl 4)
    return [uint32]($value -bor [uint32]$Destination)
}

function New-LoadOpcode([int]$Value, [int]$Destination) {
    return [uint32](0xC00000 -bor ([uint32]$Value -shl 6) -bor [uint32]$Destination)
}

function New-JumpOpcode([int]$Branch, [int]$Target) {
    return [uint32](0x800000 -bor ([uint32]$Branch -shl 13) -bor ([uint32]$Target -shl 2))
}

$opcodes = [System.Collections.Generic.List[uint32]]::new()
$opcodes.Add((New-LoadOpcode 0x1234 6))
$opcodes.Add((New-JumpOpcode 0x0BE 1))
$opcodes.Add((New-LoadOpcode 0x5678 6))
$opcodes.Add((New-JumpOpcode 0x0BE 3))
$opcodes.Add((New-JumpOpcode 0x100 4))

foreach ($alu in 0..15) { $opcodes.Add((New-OperationOpcode -P 1 -Alu $alu -Source 0 -Destination 0)) }
foreach ($source in 0..15) { $opcodes.Add((New-OperationOpcode -Source $source -Destination 3)) }
foreach ($destination in 0..15) { $opcodes.Add((New-LoadOpcode (0x1000 + $destination) $destination)) }
foreach ($p in 0..3) { $opcodes.Add((New-OperationOpcode -P $p -Alu 5 -Source 0 -Destination 0)) }
foreach ($selectB in @($false, $true)) { $opcodes.Add((New-OperationOpcode -P 1 -Alu 5 -SelectB $selectB -Source 0 -Destination 0)) }
foreach ($dpLow in 0..3) { $opcodes.Add((New-OperationOpcode -DpLow $dpLow)) }
foreach ($dpHigh in 0..15) { $opcodes.Add((New-OperationOpcode -DpHigh $dpHigh)) }
$opcodes.Add((New-OperationOpcode -RpDecrement $false))
$opcodes.Add((New-OperationOpcode -RpDecrement $true))
$opcodes.Add((New-OperationOpcode -Return $true))

$branches = @(
    0x000,
    0x080, 0x082, 0x084, 0x086, 0x088, 0x08A, 0x08C, 0x08E,
    0x090, 0x092, 0x094, 0x096, 0x098, 0x09A, 0x09C, 0x09E,
    0x0A0, 0x0A2, 0x0A4, 0x0A6, 0x0A8, 0x0AA, 0x0AC, 0x0AE,
    0x0B0, 0x0B1, 0x0B2, 0x0B3, 0x0B4, 0x0B6, 0x0B8, 0x0BA, 0x0BC, 0x0BE,
    0x100, 0x101, 0x140, 0x141,
    0x1FF
)
foreach ($branch in $branches) { $opcodes.Add((New-JumpOpcode $branch 0x155)) }
if ($opcodes.Count -gt 2048) { throw 'The open uPD7725 opcode matrix exceeds program ROM.' }

$variants = @(
    [ordered]@{ id = 'dsp1'; revision = 'DSP-1'; signature = 0x11 },
    [ordered]@{ id = 'dsp1a'; revision = 'DSP-1A'; signature = 0x1A },
    [ordered]@{ id = 'dsp1b'; revision = 'DSP-1B'; signature = 0x1B },
    [ordered]@{ id = 'dsp2'; revision = 'DSP-2'; signature = 0x22 },
    [ordered]@{ id = 'dsp3'; revision = 'DSP-3'; signature = 0x33 },
    [ordered]@{ id = 'dsp4'; revision = 'DSP-4'; signature = 0x44 }
)

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$manifestFirmware = @()
foreach ($variant in $variants) {
    $bytes = [byte[]]::new(0x2000)
    for ($index = 0; $index -lt $opcodes.Count; $index++) {
        [uint32]$opcode = $opcodes[$index]
        $offset = $index * 3
        $bytes[$offset] = [byte]($opcode -band 0xFF)
        $bytes[$offset + 1] = [byte](($opcode -shr 8) -band 0xFF)
        $bytes[$offset + 2] = [byte](($opcode -shr 16) -band 0xFF)
    }
    for ($index = 0; $index -lt 1024; $index++) {
        [uint16]$word = [uint16](($index * 257 + $variant.signature) -band 0xFFFF)
        $offset = 0x1800 + $index * 2
        $bytes[$offset] = [byte]($word -band 0xFF)
        $bytes[$offset + 1] = [byte](($word -shr 8) -band 0xFF)
    }
    $name = "r4snes_$($variant.id).open.rom"
    $path = Join-Path $OutputDirectory $name
    [System.IO.File]::WriteAllBytes($path, $bytes)
    $manifestFirmware += [ordered]@{
        id = $variant.id
        revision = $variant.revision
        file = $name
        bytes = $bytes.Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    [Array]::Clear($bytes, 0, $bytes.Length)
}

$oracleSources = @(
    [ordered]@{
        name = 'Ares uPD7725'
        repository = 'Ares'
        revision = '7b51c8ab719e403a150aa700e0933d9e93a06851'
        files = @(
            'Implementations/Ares/ares/component/processor/upd96050/upd96050.hpp',
            'Implementations/Ares/ares/component/processor/upd96050/instructions.cpp',
            'Implementations/Ares/ares/component/processor/upd96050/memory.cpp',
            'Implementations/Ares/ares/sfc/coprocessor/necdsp/memory.cpp'
        )
    },
    [ordered]@{
        name = 'Mesen2 NEC DSP'
        repository = 'Mesen2'
        revision = 'b9fa69ddc6d0a331fb103fdb5eef6904305703c2'
        files = @(
            'Implementations/Mesen2/Core/SNES/Coprocessors/DSP/NecDsp.cpp',
            'Implementations/Mesen2/Core/SNES/Coprocessors/DSP/NecDsp.h',
            'Implementations/Mesen2/Core/SNES/Coprocessors/DSP/NecDspTypes.h'
        )
    }
)
foreach ($oracle in $oracleSources) {
    $repositoryPath = Join-Path $ReferenceRoot "Implementations/$($oracle.repository)"
    $actualRevision = (& git -C $repositoryPath rev-parse HEAD | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualRevision -ne $oracle.revision) {
        throw "Pinned $($oracle.repository) revision mismatch: $actualRevision"
    }
    $oracle.files = @($oracle.files | ForEach-Object {
        $path = Join-Path $ReferenceRoot $_
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "NEC-DSP oracle source is missing: $path" }
        [ordered]@{
            path = $_
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $oracle.Remove('repository')
}

$manifest = [ordered]@{
    schema = 1
    tool = 'R4SNES deterministic uPD7725 encoder v1'
    source = [System.IO.Path]::GetRelativePath($workspaceRoot, $PSCommandPath).Replace('\', '/')
    source_sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    program_words = 2048
    data_words = 1024
    emitted_matrix_words = $opcodes.Count
    coverage = [ordered]@{
        instruction_classes = 4
        alu_modes = 16
        sources = 16
        destinations = 16
        p_selects = 4
        accumulator_selects = 2
        dp_low_modes = 4
        dp_high_masks = 16
        rp_modes = 2
        defined_branch_modes = 39
        reserved_branch_modes = 1
        host_handshake_words = 5
    }
    proprietary_firmware_images = 0
    firmware = $manifestFirmware
    oracle_sources = $oracleSources
}
[System.IO.File]::WriteAllText(
    (Join-Path $OutputDirectory 'manifest.json'),
    ($manifest | ConvertTo-Json -Depth 8) + "`n",
    [System.Text.UTF8Encoding]::new($false)
)
Write-Host "R4SNES open NEC-DSP firmware built reproducibly: variants=$($variants.Count) matrix-words=$($opcodes.Count) -> $OutputDirectory"
