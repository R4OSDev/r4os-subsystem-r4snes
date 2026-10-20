param(
 [ValidateSet('Core','Window')][string]$Profile='Core',
 [ValidateSet('ntsc','pal')][string]$Region='ntsc',
 [ValidateSet('normal','detail','paired')][string]$Mode='normal',
 [ValidateSet('active-v2')][string]$Scene='active-v2',
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
  foreach($buildRoot in @($moduleRoot,(Join-Path $workspaceRoot 'Repositories/Apps/Desktop'))){
   $build=Invoke-R4SnesCommand 'pwsh' @('-NoLogo','-NoProfile','-File',(Join-Path $buildRoot 'Build.ps1')) $buildRoot $TimeoutSeconds
   if($build.Code -ne 0 -or $build.Timeout){throw ('Guest benchmark component build failed: '+$build.Error)}
  }
  . (Join-Path $workspaceRoot 'Repositories/Distribution/Tools/SnesBenchmarkGuest.ps1')
  $guest=Invoke-R4SnesGuestBenchmark -Region $Region -Mode $Mode -CheckOnly:$CheckOnly -TimeoutSeconds $TimeoutSeconds
  $records=@($guest.Records)
  if($guest.Image){
   $versions.release_version=$guest.Image.installation.releaseVersion;$versions.kernel_version=$guest.Image.installation.kernelVersion
   $environment.image_sha256_before_boot=$guest.Image.sha256
   $used+=@{name='R4SNES.R4X';role='guest-emulator';sha256=$guest.Image.r4snes_sha256;optimize='ReleaseFast';target='r4os-avx2-v1'}
  }
  if($guest.HostProfile){$environment.accelerator=$guest.HostProfile.Name;$environment.qemu_cpu=$guest.HostProfile.CpuModel}
  $environment.global_desktop_presents=$guest.GlobalDesktopPresents
  if($guest.Failure){throw $guest.Failure}
  if($records.Count){$environment.conditions.viewport=Convert-R4SnesLossless $records[0].viewport}
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
$devkitRoot=[IO.Path]::GetFullPath((Join-Path $moduleRoot $settings.DEVKIT_ROOT))
$zig=Join-Path (Join-Path $devkitRoot $settings.ZIG_ROOT) $(if($IsWindows){'zig.exe'}else{'zig'})
$compiler=Invoke-R4SnesCommand $zig @('version') $moduleRoot
$environment.compiler_version=$compiler.Output.Trim()
foreach($scriptPath in @($PSCommandPath,(Join-Path $moduleRoot 'Tools/BenchmarkData.ps1'),(Join-Path $workspaceRoot 'Repositories/Distribution/Tools/SnesBenchmarkGuest.ps1'),(Join-Path $workspaceRoot 'Repositories/Distribution/Tools/ReadGuestFile.cs'))){
 $used+=@{name=[IO.Path]::GetFileName($scriptPath);role='host-runner';sha256=(Get-FileHash $scriptPath).Hash.ToLowerInvariant()}
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
