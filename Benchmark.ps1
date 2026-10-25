[CmdletBinding()]
param(
 [ValidateSet('Core','Window')][string]$Profile='Core',
 [ValidateSet('ntsc','pal')][string]$Region='ntsc',
 [ValidateSet('normal','detail','paired')][string]$Mode='normal',
 [ValidateSet('active-v2')][string]$Scene='active-v2',
 [ValidateSet('Small','Maximized')][string]$WindowSize='Small',[switch]$OutputAnalysis,
 [string]$HostId='', [string]$OutputRoot='', [switch]$CheckOnly,
 [ValidateRange(30,1200)][int]$TimeoutSeconds=420
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$Mode=$Mode.ToLowerInvariant();$Region=$Region.ToLowerInvariant()
$moduleRoot=$PSScriptRoot;$workspaceRoot=[IO.Path]::GetFullPath((Join-Path $moduleRoot '../../..'))
. (Join-Path $moduleRoot 'Tools/BenchmarkData.ps1')
function Read-R4SnesFields([string]$Path){
 $fields=@{};foreach($line in Get-Content $Path){$text=$line.Trim();if(!$text -or $text.StartsWith('#')){continue};$i=$text.IndexOf('=');if($i -gt 0){$fields[$text.Substring(0,$i)]=$text.Substring($i+1)}};return $fields
}
function Invoke-R4SnesCommand([string]$Program,[string[]]$Arguments,[string]$Directory,[int]$Seconds=420){
 $start=[Diagnostics.ProcessStartInfo]::new($Program);$start.UseShellExecute=$false;$start.WorkingDirectory=$Directory;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 foreach($arg in $Arguments){$start.ArgumentList.Add($arg)}
 $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
 $timeout=!$process.WaitForExit($Seconds*1000)
 if($timeout){$process.Kill($true);$process.WaitForExit()}
 return [pscustomobject]@{Code=$process.ExitCode;Timeout=$timeout;Output=$stdout.GetAwaiter().GetResult();Error=$stderr.GetAwaiter().GetResult()}
}
function Get-R4SnesHostContext {
 $cpu=$null;$ram=$null
 if($IsLinux){
  $line=Get-Content '/proc/cpuinfo'|Select-String '^model name\s*:'|Select-Object -First 1
  if($line){$cpu=($line.Line.Split(':',2)[1]).Trim()}
  $memory=Get-Content '/proc/meminfo'|Select-String '^MemTotal:\s+(\d+) kB'
  if($memory){$ram=([long]$memory.Matches[0].Groups[1].Value*1024).ToString()}
 }elseif($IsWindows){
  try{$cpu=(Get-CimInstance Win32_Processor|Select-Object -First 1).Name;$ram=([long](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory).ToString()}catch{}
 }
 return [ordered]@{os=[Runtime.InteropServices.RuntimeInformation]::OSDescription;cpu=$cpu;logical_cpus=[Environment]::ProcessorCount;ram_bytes=$ram}
}
$settings=Read-R4SnesFields (Join-Path $moduleRoot 'Settings.R4S')
$artifactsRoot=[IO.Path]::GetFullPath((Join-Path $moduleRoot $settings.ARTIFACTS_ROOT))
$manifest=Read-R4SnesFields (Join-Path $moduleRoot 'module.R4MF')
$release=Read-R4SnesFields (Join-Path $workspaceRoot 'Repositories/Distribution/Injection/R4OS/CONFIG/VERSION.R4S')
$hostSettings=@{}
$hostSettingsPath=Join-Path $workspaceRoot 'Tools/BenchmarkHost.R4S'
if(Test-Path $hostSettingsPath){$hostSettings=Read-R4SnesFields $hostSettingsPath}
if($Profile -eq 'Core' -and ($WindowSize -ne 'Small' -or $OutputAnalysis)){throw 'WindowSize/OutputAnalysis require -Profile Window'}
if(!$HostId){
 $HostId=$env:R4OS_BENCHMARK_HOST_ID
 if(!$HostId -and $hostSettings.ContainsKey('HOST_ID')){$HostId=$hostSettings.HOST_ID}
 if(!$HostId){$HostId=([Net.Dns]::GetHostName().ToLowerInvariant() -replace '[^a-z0-9_-]','-')}
 if($Profile -eq 'Core'){$HostId=$HostId -replace '-qemu$','';$HostId=$HostId.Substring(0,[Math]::Min(57,$HostId.Length))+'-owner'}
}
if($HostId -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$'){throw 'Invalid host_id'}
if(!$OutputRoot){$OutputRoot=Join-Path $workspaceRoot 'Artifacts/Distribution/Diagnostics/SubsystemBenchmarks'}
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot,$workspaceRoot)
$started=[DateTime]::UtcNow.ToString('o');$records=@();$failure=$null;$guest=$null;$used=@()
$environment=[ordered]@{execution=if($Profile -eq 'Core'){'host-owner'}else{'qemu'};host=Get-R4SnesHostContext;vcpus=if($Profile -eq 'Window'){4}else{$null};ram_bytes=if($Profile -eq 'Window'){'1073741824'}else{$null};backend=if($Profile -eq 'Core'){'no-window-pcm-drain'}else{'firmware-framebuffer-ich9-hda-null-sink'};conditions=[ordered]@{contract='snes-benchmark-v2';pacing=if($Profile -eq 'Core'){'unthrottled'}else{'sdk-window-audsvc-target2-catchup16'};audio_sample_rate='48000';audio_channels=2;graphics='software'};clock_note='Elapsed spans include descheduling. Missing hardware output receipts remain null.'}
$versions=[ordered]@{release_version=$release.RELEASE_VERSION;kernel_version=$null;emulator_version=$manifest.VERSION}
try{
 if($Profile -eq 'Core'){
  $build=Invoke-R4SnesCommand 'pwsh' @('-NoLogo','-NoProfile','-File',(Join-Path $moduleRoot 'Build.ps1'),'performance-build') $moduleRoot $TimeoutSeconds
  if($build.Code -ne 0 -or $build.Timeout){throw ('Core benchmark build failed: '+$build.Error)}
  $binary=Join-Path $artifactsRoot ('bin/r4snes-performance-harness'+$(if($IsWindows){'.exe'}else{''}))
  $binaryHash=(Get-FileHash $binary).Hash.ToLowerInvariant()
  $arguments=@('--region',$Region,'--mode',$Mode)
  if($CheckOnly){$arguments+='--check-scene'}
  $result=Invoke-R4SnesCommand $binary $arguments $moduleRoot $TimeoutSeconds
  $combined=$result.Output+"`n"+$result.Error
  foreach($line in $combined.Split("`n")){if($line.TrimStart().StartsWith('{')){$records+=,($line|ConvertFrom-Json -AsHashtable)}}
  if($result.Timeout -or $result.Code -ne 0){throw ('Core benchmark failed/timeout: '+$combined.Substring([Math]::Max(0,$combined.Length-4000)))}
  if($CheckOnly -and $combined -notmatch 'R4SNES scene: OK'){throw 'Core qualification marker missing'}
  if((Get-FileHash $binary).Hash.ToLowerInvariant() -cne $binaryHash){throw 'Host benchmark artifact changed during execution'}
  $used+=@{name='r4snes-performance-harness';role='host-owner';sha256=$binaryHash;optimize='ReleaseFast';target='native-host'}
 }else{
  foreach($buildRoot in @($moduleRoot,(Join-Path $workspaceRoot 'Repositories/Apps/Desktop'),
   (Join-Path $workspaceRoot 'Repositories/Services/WindowService'),(Join-Path $workspaceRoot 'Repositories/Diagnostics/Spectra'))){
   $build=Invoke-R4SnesCommand 'pwsh' @('-NoLogo','-NoProfile','-File',(Join-Path $buildRoot 'Build.ps1')) $buildRoot $TimeoutSeconds
   if($build.Code -ne 0 -or $build.Timeout){throw ('Guest benchmark component build failed: '+$build.Error)}
  }
  . (Join-Path $workspaceRoot 'Repositories/Distribution/Tools/SnesBenchmarkGuest.ps1')
  $guest=Invoke-R4SnesGuestBenchmark -Region $Region -Mode $Mode -WindowSize $WindowSize -OutputAnalysis:$OutputAnalysis -CheckOnly:$CheckOnly -TimeoutSeconds $TimeoutSeconds
  $records=@($guest.Records)
  if($guest.Image){
   $versions.release_version=$guest.Image.installation.releaseVersion;$versions.kernel_version=$guest.Image.installation.kernelVersion
   $environment.image_sha256_before_boot=$guest.Image.sha256
   $used+=@{name='R4SNES.R4X';role='guest-emulator';sha256=$guest.Image.r4snes_sha256;optimize='ReleaseFast';target='r4os-avx2-v1'}
   $desktopRoot=Join-Path $workspaceRoot 'Repositories/Apps/Desktop'
   $desktopManifest=Read-R4SnesFields (Join-Path $desktopRoot 'module.R4MF')
   $desktopOptimization=if($desktopManifest.ContainsKey('OPTIMIZE')){$desktopManifest.OPTIMIZE.ToLowerInvariant()}else{'size'}
   $desktopLabel=switch($desktopOptimization){'size'{'ReleaseSmall'};'speed'{'ReleaseFast'};default{throw 'Invalid built Desktop optimization'}}
   $used+=@{name='R4DESK.R4X';role='guest-output-owner';sha256=$guest.Image.desktop_sha256;optimize=$desktopLabel;target='r4os-avx2-v1'}
   if($desktopManifest.ContainsKey('LANGUAGE') -and $desktopManifest.LANGUAGE -ceq 'Rust'){
    $desktopSettings=Read-R4SnesFields (Join-Path $desktopRoot 'Settings.R4S')
    $desktopReceiptPath=Join-Path ([IO.Path]::GetFullPath($desktopSettings.ARTIFACTS_ROOT.Replace('\',[IO.Path]::DirectorySeparatorChar),$desktopRoot)) 'build.json'
    $desktopReceipt=Get-Content -Raw -LiteralPath $desktopReceiptPath|ConvertFrom-Json -AsHashtable
    if($desktopReceipt.status -cne 'success' -or $desktopReceipt.module.name -cne 'R4DESK' -or $desktopReceipt.artifact.sha256 -cne $guest.Image.desktop_sha256 -or $desktopReceipt.codegen.optimization -cne $desktopOptimization){throw 'Desktop build receipt does not match the measured artifact/profile'}
    $environment.output_owner_build=[ordered]@{language='Rust';manifest_sha256=(Get-FileHash (Join-Path $desktopRoot 'module.R4MF')).Hash.ToLowerInvariant();receipt_sha256=(Get-FileHash $desktopReceiptPath).Hash.ToLowerInvariant();module_version=$desktopReceipt.module.version;rust_target=$desktopReceipt.cargo.target;optimization=$desktopReceipt.codegen.optimization;rust_opt_level=$desktopReceipt.codegen.opt_level;overflow_checks=$desktopReceipt.codegen.overflow_checks;backend_feature_policy=$desktopReceipt.codegen.backend_feature_policy;target_features=$desktopReceipt.codegen.target_features;tools=$desktopReceipt.tools}
   }
   $used+=@{name='SPECTRA.R4X';role='guest-control';sha256=$guest.Image.spectra_sha256;optimize='ReleaseSmall';target='r4os-avx2-v1'}
   $used+=@{name='WINSVC.R4X';role='guest-owner-transport';sha256=$guest.Image.winsvc_sha256;optimize='ReleaseSmall';target='r4os-avx2-v1'}
  }
  if($guest.HostProfile){$environment.accelerator=$guest.HostProfile.Name;$environment.qemu_cpu=$guest.HostProfile.CpuModel}
  if($guest.Failure){throw $guest.Failure}
  Add-R4SnesWindowOutput -Records $records -Output $guest.WindowOutput -WindowSize $WindowSize -Environment $environment
  if($guest.OutputAnalysis){$environment.software_output_analysis=Convert-R4SnesLossless $guest.OutputAnalysis}
  if($guest.Frontend){$environment.frontend=Convert-R4SnesLossless $guest.Frontend}
 }
}catch{$failure=$_.Exception.Message}
if(!$failure -and !$CheckOnly -and $Mode -eq 'paired'){
 foreach($key in @('work_start_master','work_end_master','initial_state_sha256','state_sha256','frame_sha256','pcm_sha256')){
  if($key -eq 'pcm_sha256' -and $records.Count -and $null -eq $records[0][$key]){continue}
  if(@($records|ForEach-Object {$_[$key]}|Sort-Object -Unique).Count -ne 1){$failure='Normal/detail equivalence failed: '+$key;break}
 }
}
$finished=[DateTime]::UtcNow.ToString('o')
if($CheckOnly){if($failure){throw $failure};Write-Host "SNES $Profile $Region qualification: OK";exit 0}
$commit=Invoke-R4SnesCommand 'git' @('-C',$moduleRoot,'rev-parse','HEAD') $moduleRoot
$changes=Invoke-R4SnesCommand 'git' @('-C',$moduleRoot,'diff','--binary','HEAD') $moduleRoot
$environment.source_commit=$commit.Output.Trim();$environment.source_dirty=[bool]$changes.Output
$environment.source_diff_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($changes.Output))).ToLowerInvariant()
$untracked=Invoke-R4SnesCommand 'git' @('-C',$moduleRoot,'ls-files','--others','--exclude-standard','-z') $moduleRoot
$environment.source_untracked=@(foreach($name in $untracked.Output.Split([char]0)){if($name){@{path=$name;sha256=(Get-FileHash (Join-Path $moduleRoot $name)).Hash.ToLowerInvariant()}}})
$environment.source_dirty=$environment.source_dirty -or $environment.source_untracked.Count -gt 0
$environment.components=[ordered]@{}
foreach($component in @('SDK','Contract','Kernel','Distribution','Apps/Desktop')){
 $state=Invoke-R4SnesCommand 'git' @('-C',(Join-Path $workspaceRoot ('Repositories/'+$component)),'rev-parse','HEAD') $moduleRoot
 $environment.components[$component]=$state.Output.Trim()
}
$environment.output_owner_source=[ordered]@{}
foreach($component in @('Apps/Desktop','Distribution')){
 $componentRoot=Join-Path $workspaceRoot ('Repositories/'+$component)
 $diff=Invoke-R4SnesCommand 'git' @('-C',$componentRoot,'diff','--binary','HEAD') $moduleRoot
 $files=Invoke-R4SnesCommand 'git' @('-C',$componentRoot,'ls-files','--others','--exclude-standard','-z') $moduleRoot
 $environment.output_owner_source[$component]=[ordered]@{diff_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($diff.Output))).ToLowerInvariant();dirty=[bool]$diff.Output;untracked=@(foreach($name in $files.Output.Split([char]0)){if($name){@{path=$name;sha256=(Get-FileHash (Join-Path $componentRoot $name)).Hash.ToLowerInvariant()}}})}
}
$devkitRoot=[IO.Path]::GetFullPath((Join-Path $moduleRoot $settings.DEVKIT_ROOT))
$zig=Join-Path (Join-Path $devkitRoot $settings.ZIG_ROOT) $(if($IsWindows){'zig.exe'}else{'zig'})
$compiler=Invoke-R4SnesCommand $zig @('version') $moduleRoot
$environment.compiler_version=$compiler.Output.Trim()
foreach($scriptPath in @($PSCommandPath,(Join-Path $moduleRoot 'Tools/BenchmarkData.ps1'),(Join-Path $workspaceRoot 'Repositories/Distribution/Tools/SnesBenchmarkGuest.ps1'),(Join-Path $workspaceRoot 'Repositories/Distribution/Tools/ReadGuestFile.cs'))){
 $used+=@{name=[IO.Path]::GetFileName($scriptPath);role='host-runner';sha256=(Get-FileHash $scriptPath).Hash.ToLowerInvariant()}
}
if($Profile -eq 'Window'){
 $structuredParser=Join-Path $workspaceRoot 'Repositories/Diagnostics/Spectra/Tools/StructuredOutput.ps1'
 $used+=@{name='StructuredOutput.ps1';role='host-framing';sha256=(Get-FileHash $structuredParser).Hash.ToLowerInvariant()}
}
$failed=$false
foreach($variant in $(if($Mode -eq 'paired'){@('normal','detail')}else{@($Mode)})){
 $selected=@($records|Where-Object {$_.instrumented -eq ($variant -eq 'detail')})
 $run=New-R4SnesExport -Records $selected -Profile $(if($Profile -eq 'Core'){'core-throughput'}else{'window-audio'}) -Region $Region -Mode $variant -HostId $HostId -Started $started -Finished $finished -Environment $environment -Artifacts $used -Versions $versions -Failure $failure
 $directory=Join-Path $OutputRoot $run.run_id;$null=New-Item -ItemType Directory -Force $directory
 $path=Join-Path $directory 'run.json';[IO.File]::WriteAllText($path,($run|ConvertTo-Json -Depth 48)+"`n",[Text.UTF8Encoding]::new($false))
 Write-Host "SNES $($run.status): $path"
 if($run.status -ne 'completed'){$failed=$true;Write-Host $run.failure_reason}
}
if($failed){exit 1}
