[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string]$Path,

    [Parameter(ParameterSetName = 'File')]
    [ValidateRange(1.0, 20000.0)]
    [double]$ExpectedFrequencyHz = 440.0,

    [Parameter(ParameterSetName = 'File')]
    [ValidateRange(0.1, 1000.0)]
    [double]$FrequencyToleranceHz = 15.0,

    [Parameter(ParameterSetName = 'File')]
    [ValidateRange(0.01, 100.0)]
    [double]$ExpectedChannelRatio = (127.0 / 96.0),

    [Parameter(ParameterSetName = 'File')]
    [ValidateRange(0.1, 100.0)]
    [double]$ChannelTolerancePercent = 8.0,

    [Parameter(Mandatory, ParameterSetName = 'SelfTest')]
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$nativeSampleRate = 32000
$outputSampleRate = 48000

function Read-U16([byte[]]$Bytes, [int]$Offset) {
    return [uint16](([uint32]$Bytes[$Offset]) -bor (([uint32]$Bytes[$Offset + 1]) -shl 8))
}

function Read-U32([byte[]]$Bytes, [int]$Offset) {
    return [uint32](([uint32]$Bytes[$Offset]) -bor (([uint32]$Bytes[$Offset + 1]) -shl 8) -bor
        (([uint32]$Bytes[$Offset + 2]) -shl 16) -bor (([uint32]$Bytes[$Offset + 3]) -shl 24))
}

function Measure-SdspSignal(
    [int[]]$Left,
    [int[]]$Right,
    [int]$SampleRate,
    [double]$Frequency,
    [double]$FrequencyTolerance,
    [double]$ChannelRatio,
    [double]$ChannelTolerance
) {
    if ($Left.Length -ne $Right.Length) { throw 'Stereo sample arrays differ in length.' }
    if ($SampleRate -le 0) { throw 'Sample rate must be positive.' }

    $threshold = 64
    $firstActive = -1
    $lastActive = -1
    $activeFrames = 0
    $longestGap = 0
    $alignedFrames = 0
    for ($frame = 0; $frame -lt $Left.Length; $frame++) {
        $leftAbs = [Math]::Abs([int64]$Left[$frame])
        $rightAbs = [Math]::Abs([int64]$Right[$frame])
        if ($leftAbs -lt $threshold -and $rightAbs -lt $threshold) { continue }
        if ($firstActive -lt 0) { $firstActive = $frame }
        if ($lastActive -ge 0) {
            $gap = $frame - $lastActive - 1
            if ($gap -gt $longestGap) { $longestGap = $gap }
        }
        $lastActive = $frame
        $activeFrames++
        if (($Left[$frame] -ge 0) -eq ($Right[$frame] -ge 0)) { $alignedFrames++ }
    }

    if ($firstActive -lt 0) {
        return [pscustomobject]@{
            SampleRate = $SampleRate
            Channels = 2
            Frames = $Left.Length
            SignalFrames = 0
            ActiveFrames = 0
            LongestGapFrames = 0
            FrequencyHz = 0.0
            StereoRatio = 0.0
            AlignedPercent = 0.0
            Valid = $false
        }
    }

    $signalFrames = $lastActive - $firstActive + 1
    $leftEnergy = 0.0
    $rightEnergy = 0.0
    $transitions = 0
    $previousSign = 0
    for ($frame = $firstActive; $frame -le $lastActive; $frame++) {
        $leftSample = $Left[$frame]
        $rightSample = $Right[$frame]
        $leftEnergy += [double]$leftSample * $leftSample
        $rightEnergy += [double]$rightSample * $rightSample
        if ([Math]::Abs([int64]$leftSample) -lt $threshold) { continue }
        $sign = if ($leftSample -lt 0) { -1 } else { 1 }
        if ($previousSign -ne 0 -and $sign -ne $previousSign) { $transitions++ }
        $previousSign = $sign
    }

    $measuredFrequency = ($transitions * $SampleRate) / (2.0 * $signalFrames)
    $measuredRatio = if ($rightEnergy -eq 0.0) { 0.0 } else { [Math]::Sqrt($leftEnergy / $rightEnergy) }
    $alignedPercent = if ($activeFrames -eq 0) { 0.0 } else { 100.0 * $alignedFrames / $activeFrames }
    $density = $activeFrames / [double]$signalFrames
    $minimumRatio = $ChannelRatio * (1.0 - $ChannelTolerance / 100.0)
    $maximumRatio = $ChannelRatio * (1.0 + $ChannelTolerance / 100.0)
    $valid = $SampleRate -eq $outputSampleRate -and
        $signalFrames -ge [int]($SampleRate / 10) -and
        $density -ge 0.98 -and
        $longestGap -le [int][Math]::Ceiling($SampleRate * 0.001) -and
        $alignedPercent -ge 99.0 -and
        $measuredFrequency -ge ($Frequency - $FrequencyTolerance) -and
        $measuredFrequency -le ($Frequency + $FrequencyTolerance) -and
        $measuredRatio -ge $minimumRatio -and $measuredRatio -le $maximumRatio

    return [pscustomobject]@{
        SampleRate = $SampleRate
        Channels = 2
        Frames = $Left.Length
        SignalFrames = $signalFrames
        ActiveFrames = $activeFrames
        LongestGapFrames = $longestGap
        FrequencyHz = [Math]::Round($measuredFrequency, 2)
        StereoRatio = [Math]::Round($measuredRatio, 4)
        AlignedPercent = [Math]::Round($alignedPercent, 2)
        Valid = $valid
    }
}

function Read-SdspWav([string]$FilePath) {
    $fullPath = [IO.Path]::GetFullPath($FilePath)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "WAV file not found: $fullPath" }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($fullPath)
    if ($bytes.Length -lt 44 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'RIFF' -or
        [Text.Encoding]::ASCII.GetString($bytes, 8, 4) -cne 'WAVE') {
        throw "Not a RIFF/WAVE file: $fullPath"
    }

    $formatOffset = -1
    $formatBytes = 0
    $dataOffset = -1
    $dataBytes = 0
    $cursor = 12
    while ($cursor + 8 -le $bytes.Length) {
        $chunk = [Text.Encoding]::ASCII.GetString($bytes, $cursor, 4)
        $length = [int](Read-U32 $bytes ($cursor + 4))
        $payload = $cursor + 8
        if ($payload + $length -gt $bytes.Length) { throw "Truncated WAV chunk: $chunk" }
        if ($chunk -ceq 'fmt ') {
            $formatOffset = $payload
            $formatBytes = $length
        } elseif ($chunk -ceq 'data') {
            $dataOffset = $payload
            $dataBytes = $length
        }
        $cursor = $payload + $length + ($length -band 1)
    }
    if ($formatOffset -lt 0 -or $formatBytes -lt 16 -or $dataOffset -lt 0) { throw 'WAV fmt or data chunk missing.' }

    $format = Read-U16 $bytes $formatOffset
    $channels = Read-U16 $bytes ($formatOffset + 2)
    $sampleRate = [int](Read-U32 $bytes ($formatOffset + 4))
    $bitsPerSample = Read-U16 $bytes ($formatOffset + 14)
    if ($format -ne 1 -or $channels -ne 2 -or $sampleRate -ne $outputSampleRate -or $bitsPerSample -ne 16) {
        throw "S-DSP capture requires 48 kHz stereo PCM S16LE: format=$format channels=$channels rate=$sampleRate bits=$bitsPerSample"
    }
    if (($dataBytes % 4) -ne 0) { throw 'Stereo PCM data is not frame aligned.' }

    $frameCount = [int]($dataBytes / 4)
    [int[]]$left = New-Object int[] $frameCount
    [int[]]$right = New-Object int[] $frameCount
    for ($frame = 0; $frame -lt $frameCount; $frame++) {
        $left[$frame] = [BitConverter]::ToInt16($bytes, $dataOffset + $frame * 4)
        $right[$frame] = [BitConverter]::ToInt16($bytes, $dataOffset + $frame * 4 + 2)
    }
    return Measure-SdspSignal $left $right $sampleRate $ExpectedFrequencyHz $FrequencyToleranceHz $ExpectedChannelRatio $ChannelTolerancePercent
}

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

if ($SelfTest) {
    $frames = $outputSampleRate
    [int[]]$left = New-Object int[] $frames
    [int[]]$right = New-Object int[] $frames
    for ($frame = 0; $frame -lt $frames; $frame++) {
        $sample = if ([Math]::Sin(2.0 * [Math]::PI * 440.0 * $frame / $outputSampleRate) -ge 0.0) { 12000 } else { -12000 }
        $left[$frame] = $sample
        $right[$frame] = [int][Math]::Round($sample * 96.0 / 127.0)
    }
    $continuous = Measure-SdspSignal $left $right $outputSampleRate 440.0 15.0 (127.0 / 96.0) 8.0
    Assert-Condition $continuous.Valid 'Continuous 48 kHz S-DSP fixture was rejected.'

    [int[]]$gapLeft = [int[]]$left.Clone()
    [int[]]$gapRight = [int[]]$right.Clone()
    for ($frame = 20000; $frame -lt 20480; $frame++) {
        $gapLeft[$frame] = 0
        $gapRight[$frame] = 0
    }
    $broken = Measure-SdspSignal $gapLeft $gapRight $outputSampleRate 440.0 15.0 (127.0 / 96.0) 8.0
    Assert-Condition (-not $broken.Valid) 'S-DSP fixture with a missing 10 ms quantum was accepted.'

    [int[]]$wrongRight = [int[]]$left.Clone()
    $wrongChannels = Measure-SdspSignal $left $wrongRight $outputSampleRate 440.0 15.0 (127.0 / 96.0) 8.0
    Assert-Condition (-not $wrongChannels.Valid) 'S-DSP fixture with the wrong channel ratio was accepted.'

    [int[]]$wrongFrequencyLeft = New-Object int[] $frames
    [int[]]$wrongFrequencyRight = New-Object int[] $frames
    for ($frame = 0; $frame -lt $frames; $frame++) {
        $sample = if ([Math]::Sin(2.0 * [Math]::PI * 880.0 * $frame / $outputSampleRate) -ge 0.0) { 12000 } else { -12000 }
        $wrongFrequencyLeft[$frame] = $sample
        $wrongFrequencyRight[$frame] = [int][Math]::Round($sample * 96.0 / 127.0)
    }
    $wrongFrequency = Measure-SdspSignal $wrongFrequencyLeft $wrongFrequencyRight $outputSampleRate 440.0 15.0 (127.0 / 96.0) 8.0
    Assert-Condition (-not $wrongFrequency.Valid) 'S-DSP fixture with the wrong frequency was accepted.'

    Write-Host "R4SNES S-DSP WAV analyzer self-test OK: 32->$outputSampleRate Hz contract, frequency, continuity and stereo ratio validated."
    exit 0
}

$result = Read-SdspWav $Path
$result | Format-List
if (-not $result.Valid) {
    Write-Host ("R4SNES S-DSP WAV analysis FAILED: rate=$($result.SampleRate) signal=$($result.SignalFrames) active=$($result.ActiveFrames) gap=$($result.LongestGapFrames) ratio=$($result.StereoRatio) aligned=$($result.AlignedPercent)% frequency=$($result.FrequencyHz)")
    exit 1
}
Write-Host ("R4SNES S-DSP WAV analysis OK: rate=$($result.SampleRate) signal=$($result.SignalFrames) active=$($result.ActiveFrames) gap=$($result.LongestGapFrames) ratio=$($result.StereoRatio) aligned=$($result.AlignedPercent)% frequency=$($result.FrequencyHz)")
exit 0
