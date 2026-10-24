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
function Read-R4SnesSpectraBenchmark {
 param([string]$Text,[string]$Region,[string]$Mode,[bool]$CheckOnly,[bool]$OutputAnalysis,[string]$WindowSize)
 . (Join-Path $PSScriptRoot '../../../Diagnostics/Spectra/Tools/StructuredOutput.ps1')
 $rows=Read-SpectraStructuredOutput $Text
 $samples=@($rows|Where-Object {$_.group -ceq 'SNES' -and $_.kind -ceq 'snes-sample'}|ForEach-Object {$_.data})
 $windows=@($rows|Where-Object {$_.group -ceq 'SNES' -and $_.kind -ceq 'desktop-output'}|ForEach-Object {$_.data})
 $software=@($rows|Where-Object {$_.group -ceq 'DESKTOP' -and $_.kind -ceq 'software-output'}|ForEach-Object {$_.data})
 $contexts=@($rows|Where-Object {$_.group -ceq 'SNES' -and $_.kind -ceq 'context'}|ForEach-Object {$_.data})
 $controls=@($rows|Where-Object {$_.group -ceq 'SNES' -and $_.kind -ceq 'benchmark-control'}|ForEach-Object {$_.data})
 $results=@($rows|Where-Object {$_.group -ceq 'SNES' -and $_.kind -ceq 'result'}|ForEach-Object {$_.data})
 $failure=$null
 try{
  if($results.Count -ne 1){throw 'Missing/duplicate Spectra result'}
  if(!$results[0].success -or [int](Get-SpectraScalar $results[0].exit_code) -ne 0 -or !$results[0].cleanup_acknowledged){
   $reasons=@($rows|Where-Object {$_.group -ceq 'SNES' -and $_.kind -ceq 'unavailable'}|ForEach-Object {$_.data.reason})
   $reasons+=@($rows|Where-Object {$_.group -ceq 'SNES' -and $_.kind -ceq 'snes-error'}|ForEach-Object {$_.data.error_name})
   throw ('Spectra failed/incomplete: '+($reasons -join ', '))
  }
  if($contexts.Count -ne 1 -or $controls.Count -ne 1 -or !$controls[0].snes -or
   $controls[0].options.mode -cne $Mode -or $controls[0].options.pal -ne ($Region -ceq 'pal') -or
   $controls[0].options.maximized -ne ($WindowSize -ceq 'Maximized') -or $controls[0].options.check_only -ne $CheckOnly -or
   $controls[0].output_analysis -ne $OutputAnalysis){throw 'Spectra benchmark control context differs'}
  $expected=if($CheckOnly){1}elseif($Mode -ceq 'paired'){10}else{5}
  if($samples.Count -ne $expected -or [int](Get-SpectraScalar $results[0].original_owner_records) -ne $samples.Count){throw 'Incomplete original SNES samples'}
  foreach($sample in $samples){
   if($sample -isnot [Collections.IDictionary] -or $sample.profile -cne 'r4os-window-audsvc-v2' -or
    $sample.scene -cne 'r4snes.active-scene.v2' -or $sample.region -cne $Region -or
    $sample.qualification_only -ne $CheckOnly -or !$sample.cleanup_verified -or
    ($Mode -cne 'paired' -and $sample.instrumented -ne ($Mode -ceq 'detail'))){throw 'Unexpected original SNES owner record'}
  }
  $completions=@($rows|Where-Object {$_.group -ceq 'SNES' -and $_.kind -ceq 'completion'}|ForEach-Object {$_.data})
  $children=@($rows|Where-Object {$_.group -ceq 'SNES' -and $_.kind -ceq 'benchmark-child'}|ForEach-Object {$_.data})
  if($completions.Count -ne 1 -or $children.Count -ne 1 -or !$completions[0].reaped -or
   [int](Get-SpectraScalar $completions[0].exit_code) -ne 0 -or [int](Get-SpectraScalar $children[0].exit_code) -ne 0 -or
   [ulong](Get-SpectraScalar $completions[0].sequence) -eq 0 -or
   (Get-SpectraScalar $completions[0].sequence) -cne (Get-SpectraScalar $children[0].sequence)){throw 'Missing real SNES completion/reap'}
  if($windows.Count -ne 1){throw 'Missing/duplicate Desktop output owner report'}
  foreach($field in @('instance_id','generation')){
   $identity=Get-SpectraScalar $completions[0].handle[$field]
   if([ulong]$identity -eq 0 -or $identity -cne (Get-SpectraScalar $children[0].handle[$field]) -or
    [ulong]$identity -ne [ulong]$windows[0].process[$field]){throw 'Changed benchmark child generation'}
  }
  if($OutputAnalysis){
   if($software.Count -ne 1 -or $software[0].contract -cne 'desktop-software-output-v1' -or $software[0].records.Count -ne 20){throw 'Incomplete original software output analysis'}
  }elseif($software.Count -ne 0){throw 'Unrequested software output analysis'}
 }catch{$failure=$_.Exception.Message}
 return [pscustomobject]@{Records=$samples;WindowOutput=if($windows.Count -eq 1){$windows[0]}else{$null};
  OutputAnalysis=if($software.Count -eq 1){$software[0]}else{$null};Failure=$failure;
  Frontend=[ordered]@{contract='r4os.spectra/1';context=if($contexts.Count -eq 1){$contexts[0]}else{$null};
   control=if($controls.Count -eq 1){$controls[0]}else{$null};result=if($results.Count -eq 1){$results[0]}else{$null};
   owner_errors=@($rows|Where-Object {$_.group -ceq 'SNES' -and $_.kind -ceq 'snes-error'}|ForEach-Object {$_.data})}}
}

function Add-R4SnesWindowOutput {
 param([object[]]$Records,$Output,[string]$WindowSize,$Environment)
 if(!$Output -or $Output.contract -cne 'desktop-window-output-v1' -or
    $Output.receipt -cnotin @('software-display-copy-present-success','managed-output-context-only') -or
    $Output.window_case -cne $WindowSize.ToLowerInvariant() -or $null -ne $Output.physical_visibility){throw 'Invalid window output context'}
 $managed=$Output.receipt -ceq 'managed-output-context-only'
 if(!$Records.Count -or (!$managed -and !$Output.records.Count) -or
    ($managed -and ($Output.records.Count -ne 0 -or [ulong]$Output.published_generations_observed -eq 0 -or $null -ne $Output.presentation_receipts)) -or
    $Output.client.w -le 0 -or $Output.client.h -le 0 -or
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
  if([decimal]$record.viewport.x -lt 0 -or [decimal]$record.viewport.y -lt 0 -or
     [decimal]$record.viewport.x+[decimal]$record.viewport.w -gt [decimal]$Output.client.w -or
     [decimal]$record.viewport.y+[decimal]$record.viewport.h -gt [decimal]$Output.client.h){throw 'Viewport outside observed client'}
  if($managed){
   $record['desktop_output']=[ordered]@{
    window_generation_copy_observations=$null;full_client_copy_observations=$null
    first_copy_completed_ns=$null;last_copy_completed_ns=$null;owner_wall_ns=$null
    cursor_queued_to_copy_ticks=$null;physical_visible_frames=$null
    scope='Managed output context only; per-generation presentation observations unavailable'
   }
   continue
  }
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
 if($managed){$Environment.conditions.output_receipt=$Output.receipt}
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
