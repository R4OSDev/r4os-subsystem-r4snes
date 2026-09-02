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
    $OutputDirectory = Join-Path $workspaceRoot 'Temp/R4SNES-ST018'
}
$ReferenceRoot = [System.IO.Path]::GetFullPath($ReferenceRoot)
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

function Set-U32Le {
    param([byte[]]$Bytes, [int]$Offset, [uint32]$Value)
    $Bytes[$Offset] = [byte]($Value -band 0xFF)
    $Bytes[$Offset + 1] = [byte](($Value -shr 8) -band 0xFF)
    $Bytes[$Offset + 2] = [byte](($Value -shr 16) -band 0xFF)
    $Bytes[$Offset + 3] = [byte](($Value -shr 24) -band 0xFF)
}

# This is an original, deterministic test image rather than Nintendo firmware.
# It exercises reset-vector branching, the bidirectional host bridge, an ARMv3
# immediate rotation and ST018 work RAM before settling in a tight branch.
$bytes = [byte[]]::new(0x28000)
Set-U32Le $bytes 0x000 0xEA00003Eu # B 0x100
Set-U32Le $bytes 0x004 0xEAFFFFFEu # undefined-vector fixture: B .
Set-U32Le $bytes 0x008 0xEAFFFFFEu # SWI-vector fixture: B .
Set-U32Le $bytes 0x00C 0xEAFFFFFEu # prefetch-abort fixture: B .
Set-U32Le $bytes 0x010 0xEAFFFFFEu # data-abort fixture: B .
Set-U32Le $bytes 0x018 0xEAFFFFFEu # IRQ-vector fixture: B .
Set-U32Le $bytes 0x01C 0xEAFFFFFEu # FIQ-vector fixture: B .
Set-U32Le $bytes 0x100 0xE3A01101u # MOV r1,#0x40000000
Set-U32Le $bytes 0x104 0xE3A0005Au # MOV r0,#0x5a
Set-U32Le $bytes 0x108 0xE5C10000u # STRB r0,[r1]
Set-U32Le $bytes 0x10C 0xE2811010u # ADD r1,r1,#0x10
Set-U32Le $bytes 0x110 0xE5D12000u # LDRB r2,[r1]
Set-U32Le $bytes 0x114 0xE2411010u # SUB r1,r1,#0x10
Set-U32Le $bytes 0x118 0xE2820001u # ADD r0,r2,#1
Set-U32Le $bytes 0x11C 0xE5C10000u # STRB r0,[r1]
Set-U32Le $bytes 0x120 0xE3A0320Eu # MOV r3,#0xe0000000
Set-U32Le $bytes 0x124 0xE3A040A5u # MOV r4,#0xa5
Set-U32Le $bytes 0x128 0xE5C34123u # STRB r4,[r3,#0x123]
Set-U32Le $bytes 0x12C 0xEAFFFFFEu # B .
for ($index = 0; $index -lt 0x8000; $index++) {
    $bytes[0x20000 + $index] = [byte](($index * 37 + 11) -band 0xFF)
}

$oracleSpecs = @(
    [ordered]@{
        name = 'Ares ARM6/ST018'
        repository = 'Ares'
        revision = '7b51c8ab719e403a150aa700e0933d9e93a06851'
        files = @(
            'Implementations/Ares/ares/sfc/coprocessor/armdsp/armdsp.hpp',
            'Implementations/Ares/ares/sfc/coprocessor/armdsp/memory.cpp',
            'Implementations/Ares/ares/component/processor/arm7tdmi/arm7tdmi.hpp',
            'Implementations/Ares/ares/component/processor/arm7tdmi/instructions-arm.cpp',
            'Implementations/Ares/ares/component/processor/arm7tdmi/registers.cpp',
            'Implementations/Ares/ares/component/processor/arm7tdmi/algorithms.cpp'
        )
    },
    [ordered]@{
        name = 'Mesen2 ARMv3/ST018'
        repository = 'Mesen2'
        revision = 'b9fa69ddc6d0a331fb103fdb5eef6904305703c2'
        files = @(
            'Implementations/Mesen2/Core/SNES/Coprocessors/ST018/ArmV3Cpu.cpp',
            'Implementations/Mesen2/Core/SNES/Coprocessors/ST018/ArmV3Cpu.h',
            'Implementations/Mesen2/Core/SNES/Coprocessors/ST018/ArmV3Types.h',
            'Implementations/Mesen2/Core/SNES/Coprocessors/ST018/St018.cpp',
            'Implementations/Mesen2/Core/SNES/Coprocessors/ST018/St018.h',
            'Implementations/Mesen2/Core/SNES/Coprocessors/ST018/St018Types.h'
        )
    }
)
$oracles = @()
foreach ($spec in $oracleSpecs) {
    $repositoryPath = Join-Path $ReferenceRoot "Implementations/$($spec.repository)"
    $actualRevision = (& git -C $repositoryPath rev-parse HEAD | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualRevision -ne $spec.revision) {
        throw "Pinned $($spec.repository) revision mismatch: $actualRevision"
    }
    $files = @($spec.files | ForEach-Object {
        $path = Join-Path $ReferenceRoot $_
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "ST018 oracle source is missing: $path" }
        [ordered]@{
            path = $_
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $oracles += [ordered]@{
        name = $spec.name
        revision = $spec.revision
        files = $files
    }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$firmwareName = 'r4snes_st018.open.rom'
$firmwarePath = Join-Path $OutputDirectory $firmwareName
[System.IO.File]::WriteAllBytes($firmwarePath, $bytes)
$manifest = [ordered]@{
    schema = 1
    tool = 'R4SNES deterministic ARMv3/ST018 fixture v1'
    source = 'Tests/Build-St018Firmware.ps1'
    source_sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    firmware = [ordered]@{
        file = $firmwareName
        bytes = $bytes.Length
        sha256 = (Get-FileHash -LiteralPath $firmwarePath -Algorithm SHA256).Hash.ToLowerInvariant()
        proprietary = $false
    }
    geometry = [ordered]@{
        program_rom_bytes = 0x20000
        data_rom_bytes = 0x8000
        work_ram_bytes = 0x4000
    }
    coverage = @(
        'reset-vectors', 'pipeline', 'condition-decode', 'alu-shifter',
        'multiply', 'load-store', 'branch-exception', 'host-bridge',
        'timer', 'work-ram', 'slice-partition', 'instance-isolation'
    )
    proprietary_firmware_images = 0
    oracle_sources = $oracles
}
[System.IO.File]::WriteAllText(
    (Join-Path $OutputDirectory 'manifest.json'),
    ($manifest | ConvertTo-Json -Depth 8) + "`n",
    [System.Text.UTF8Encoding]::new($false)
)
[Array]::Clear($bytes, 0, $bytes.Length)
Write-Host "R4SNES open ST018 firmware built reproducibly: bytes=163840 proprietary=0 -> $OutputDirectory"
