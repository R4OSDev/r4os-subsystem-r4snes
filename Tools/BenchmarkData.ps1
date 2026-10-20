function Convert-R4SnesLossless($Value) {
 if($null -eq $Value -or $Value -is [bool] -or $Value -is [string]){return $Value}
 if($Value -is [Collections.IDictionary]){
  $copy=[ordered]@{};foreach($key in $Value.Keys){$copy[$key]=Convert-R4SnesLossless $Value[$key]};return $copy
 }
 if($Value -is [Collections.IEnumerable]){return ,@(foreach($item in $Value){Convert-R4SnesLossless $item})}
 if($Value -is [ValueType]){return $Value.ToString([Globalization.CultureInfo]::InvariantCulture)}
 throw 'Unsupported SNES export value'
}
function Get-R4SnesMedian($Values) {
 $sorted=@($Values|Sort-Object);if(!$sorted.Count){return $null}
 if($sorted.Count%2 -eq 0){$middle=[int]($sorted.Count/2);return ([decimal]$sorted[$middle-1]+[decimal]$sorted[$middle])/2}
 return [decimal]$sorted[[int][Math]::Floor($sorted.Count/2)]
}
function Get-R4SnesStatistics($Values) {
 if(!$Values.Count){return $null}
 $median=Get-R4SnesMedian $Values
 $mad=Get-R4SnesMedian @($Values|ForEach-Object {[Math]::Abs([decimal]$_-$median)})
 $sorted=@($Values|Sort-Object)
 return [ordered]@{median_value=$median.ToString([Globalization.CultureInfo]::InvariantCulture);min_value=([decimal]$sorted[0]).ToString([Globalization.CultureInfo]::InvariantCulture);max_value=([decimal]$sorted[-1]).ToString([Globalization.CultureInfo]::InvariantCulture);mad_value=$mad.ToString([Globalization.CultureInfo]::InvariantCulture)}
}
function New-R4SnesExport {
 param([object[]]$Records,[string]$Profile,[string]$Region,[string]$Mode,[string]$HostId,[string]$Started,[string]$Finished,$Environment,$Artifacts,$Versions,[AllowNull()][string]$Failure)
 $samples=@(foreach($record in $Records){
  $copy=Convert-R4SnesLossless $record
  $copy['status']='ok';$copy['failure_reason']=$null
  if($copy['warmup']){$copy['warmup']['status']='ok'}
  if(!$record.instrumented){
   foreach($key in @('sampled_exclusive_wall_ns','sampled_phase_calls','cpu_operations','dma_operations','observed_master_cycles','operations','stage_wall_ns','persistence_time_wall_ns')){if($copy.Contains($key)){$copy[$key]=$null}}
  }
  $copy
 })
 $status=if($Failure){'failed'}elseif($samples.Count -ne 5){'incomplete'}else{'completed'}
 if(!$Failure -and $status -ne 'completed'){$Failure='Expected exactly five complete measured batches'}
 $first=if($samples.Count){$samples[0]}else{$null}
 if($status -eq 'completed'){
  try{
   if(@($samples.sample|Sort-Object -Unique).Count -ne 5){throw 'Duplicate sample indices'}
   foreach($sample in $samples){
    if($sample.scene -cne 'r4snes.active-scene.v2' -or $sample.region -cne $Region -or $sample.qualification_only -or
       $sample.instrumented -ne ($Mode -eq 'detail') -or !$sample.cleanup_verified -or [decimal]$sample.wall_ns -le 0 -or
       [decimal]$sample.work_end_master -le [decimal]$sample.work_start_master -or [decimal]$sample.pending_master_cycles -ne 0 -or
       [decimal]$sample.profile_clock_regressions -ne 0){$sample['status']='failed';$sample['failure_reason']='Invalid measured work, clock, mode or cleanup';throw $sample['failure_reason']}
   }
   foreach($key in @('work_start_master','work_end_master','master_hz','rom_sha256','initial_state_sha256','state_sha256','frame_sha256','pcm_sha256')){
    if($key -eq 'pcm_sha256' -and $null -eq $first[$key]){continue}
    if(@($samples|ForEach-Object {$_[$key]}|Sort-Object -Unique).Count -ne 1){throw ('Fixed batch work/state differs: '+$key)}
   }
  }catch{$status='failed';$Failure=$_.Exception.Message}
 }
 $inputHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('no-events-v1'))).ToLowerInvariant()
 $workload=[ordered]@{scene_id='r4snes.active-scene.v2';work_version='snes-fixed-guest-v2';rom_sha256=if($first){$first.rom_sha256}else{$null};initial_state_sha256=if($first){$first.initial_state_sha256}else{$null};input_contract='no-events-v1';input_sha256=$inputHash;power_on='instance-1-semantic-ipl-no-save-v1';warmup_guest_ns='250000000';measured_guest_ns='3000000000';sample_count=5;enhancement='none'}
 $wall=@();$factors=@()
 foreach($sample in $samples){
  if([decimal]$sample.wall_ns -gt 0 -and [decimal]$sample.master_hz -gt 0){
   $wall+=,[decimal]$sample.wall_ns
   $factors+=,(([decimal]$sample.work_end_master-[decimal]$sample.work_start_master)*[decimal]1000000000/[decimal]$sample.master_hz/[decimal]$sample.wall_ns)
  }
 }
 return [ordered]@{
  schema_version=1;benchmark_family='snes';subsystem_id='r4os.snes';run_id=[guid]::NewGuid().ToString();host_id=$HostId
  started_at_utc=$Started;finished_at_utc=$Finished;status=$status;failure_reason=if($Failure){$Failure}else{$null}
  profile=$Profile;region=$Region;instrumentation_mode=$Mode;workload=$workload;environment=$Environment;artifacts=@($Artifacts);versions=$Versions
  samples=$samples;summary=[ordered]@{wall_ns=Get-R4SnesStatistics $wall;realtime_factor=Get-R4SnesStatistics $factors}
 }
}
