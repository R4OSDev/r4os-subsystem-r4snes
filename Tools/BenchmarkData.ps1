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
function Add-R4SnesWindowOutput {
 param([object[]]$Records,$Output,[string]$WindowSize,$Environment)
 if(!$Output -or $Output.contract -cne 'desktop-window-output-v1' -or
    $Output.receipt -cne 'software-display-copy-present-success' -or
    $Output.window_case -cne $WindowSize.ToLowerInvariant() -or $null -ne $Output.physical_visibility){throw 'Invalid software output context'}
 if(!$Records.Count -or !$Output.records.Count -or $Output.client.w -le 0 -or $Output.client.h -le 0 -or
    $Output.session_end_ns -le $Output.session_start_ns){throw 'Incomplete output geometry/time'}
 if($WindowSize -eq 'Small' -and ($Output.client.w -ne 414 -or $Output.client.h -ne 224)){throw 'Small client geometry changed'}
 if($WindowSize -eq 'Maximized' -and ($Output.frame.w -ne $Output.screen.w -or $Output.client.w -le 414 -or $Output.client.h -le 224)){throw 'Maximized client geometry missing'}
 $lastGeneration=[ulong]0;$lastTime=[ulong]0
 foreach($copy in $Output.records){
  if([ulong]$copy.generation -le $lastGeneration -or [ulong]$copy.completed_ns -lt $lastTime -or
     [ulong]$copy.frame_wall_ns -lt [ulong]$copy.compose_wall_ns -or [ulong]$copy.frame_wall_ns -lt [ulong]$copy.present_wall_ns){throw 'Invalid copy trace order/time'}
  $lastGeneration=[ulong]$copy.generation;$lastTime=[ulong]$copy.completed_ns
 }
 $viewport=Convert-R4SnesLossless $Records[0].viewport
 $viewportText=$viewport|ConvertTo-Json -Compress -Depth 8
 foreach($record in $Records){
  if(((Convert-R4SnesLossless $record.viewport)|ConvertTo-Json -Compress -Depth 8) -cne $viewportText){throw 'Viewport changed during fixed-size run'}
  if($record.viewport.x -lt 0 -or $record.viewport.y -lt 0 -or
     $record.viewport.x+$record.viewport.w -gt $Output.client.w -or $record.viewport.y+$record.viewport.h -gt $Output.client.h){throw 'Viewport outside observed client'}
  $selected=@($Output.records|Where-Object {[ulong]$_.generation -gt [ulong]$record.generation_start_exclusive -and [ulong]$_.generation -le [ulong]$record.generation_end_inclusive})
  if(!$selected.Count -or $selected.Count -gt [ulong]$record.submitted_frames){throw 'Measured generation cohort has missing/inconsistent copy observations'}
  $stats=[ordered]@{}
  foreach($field in @('frame_wall_ns','compose_wall_ns','present_wall_ns')){
   $stats[$field]=Get-R4SnesStatistics @($selected|ForEach-Object {[decimal]$_[$field]})
  }
  $cursor=@($selected|Where-Object {$null -ne $_.cursor_queued_to_copy_ticks})
  $record['desktop_output']=[ordered]@{
   window_generation_copy_observations=$selected.Count
   full_client_copy_observations=@($selected|Where-Object {$_.full_client_copy}).Count
   first_copy_completed_ns=$selected[0].completed_ns;last_copy_completed_ns=$selected[-1].completed_ns
   owner_wall_ns=$stats
   cursor_queued_to_copy_ticks=if($cursor.Count){Get-R4SnesStatistics @($cursor|ForEach-Object {[decimal]$_.cursor_queued_to_copy_ticks})}else{$null}
   physical_visible_frames=$null
  }
 }
 $Environment.window_output=Convert-R4SnesLossless $Output
 $Environment.global_desktop_presents=$Output.global_desktop_presents
 $Environment.conditions.viewport=$viewport
 $Environment.conditions.window_case=$Output.window_case
 $Environment.conditions.output_context_contract=$Output.contract
 $Environment.conditions.screen=Convert-R4SnesLossless $Output.screen
 $Environment.conditions.window_frame=Convert-R4SnesLossless $Output.frame
 $Environment.conditions.window_client=Convert-R4SnesLossless $Output.client
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
