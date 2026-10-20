# Read JSON without floating-point or automatic timestamp conversion on PS7.
function ConvertFrom-R4SnesJsonElement([Text.Json.JsonElement]$Element) {
 switch($Element.ValueKind.ToString()) {
  'Object' {
   $map=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
   foreach($property in $Element.EnumerateObject()) {
    if($map.ContainsKey($property.Name)){throw 'Duplicate JSON field'}
    $map.Add($property.Name,(ConvertFrom-R4SnesJsonElement $property.Value))
   }
   return ,$map
  }
  'Array' {return ,@(foreach($child in $Element.EnumerateArray()){ConvertFrom-R4SnesJsonElement $child})}
  'String' {return $Element.GetString()}
  'Number' {
   $raw=$Element.GetRawText()
   # DevCenter converts numeric metadata to decimal strings. Normalize exponent
   # notation with text/BigInteger only; no double/decimal precision boundary.
   if($raw -cnotmatch '^(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$'){throw 'Invalid JSON number'}
   $negative=$Matches[1];$digits=$Matches[2];$fraction=if($Matches.ContainsKey(3)){$Matches[3]}else{''}
   $exponent=if($Matches.ContainsKey(4)){[int]$Matches[4]}else{0}
   if([Math]::Abs([long]$exponent) -gt 300 -or $digits.Length+$fraction.Length -gt 4096){throw 'JSON number exceeds benchmark metadata limits'}
   $digits=($digits+$fraction).TrimStart('0');if(!$digits){return '0'}
   $scale=$fraction.Length-$exponent
   if($scale -le 0){return $negative+$digits+('0'*(-$scale))}
   if($scale -ge $digits.Length){$digits='0.'+('0'*($scale-$digits.Length))+$digits}else{$digits=$digits.Insert($digits.Length-$scale,'.')}
   return $negative+$digits.TrimEnd('0').TrimEnd('.')
  }
  'True' {return $true}
  'False' {return $false}
  'Null' {return $null}
  default {throw 'Unsupported JSON value'}
 }
}
function Read-R4SnesJson([byte[]]$Bytes) {
 $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=64
 $document=[Text.Json.JsonDocument]::Parse([Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xFEFF),$options)
 try{return ,(ConvertFrom-R4SnesJsonElement $document.RootElement)}finally{$document.Dispose()}
}
function Convert-R4SnesImportPayload($Payload) {
 $Payload['run_id']=$Payload['run_id'].ToLowerInvariant()
 foreach($field in @('started_at_utc','finished_at_utc')) {
  if($null -eq $Payload[$field]){continue}
  if($Payload[$field] -cnotmatch '^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.([0-9]{1,9}))?(?:Z|\+00:00)$'){throw 'Invalid UTC benchmark timestamp'}
  $seconds=$Matches[1];$fraction=if($Matches.ContainsKey(2)){$Matches[2]}else{''}
  $Payload[$field]=$seconds+'.'+$fraction.PadRight(9,'0')+'Z'
 }
 if(!$Payload.ContainsKey('failure_reason')){$Payload['failure_reason']=$null}
 if($Payload['workload']['input_contract'] -ceq 'no-events-v1' -and !$Payload['workload'].ContainsKey('input_sha256')) {
  $Payload['workload']['input_sha256']=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('no-events-v1'))).ToLowerInvariant()
 }
 foreach($sample in $Payload['samples']) {
  if(!$sample.ContainsKey('status')){$sample['status']='ok'}
  if(!$sample.ContainsKey('failure_reason')){$sample['failure_reason']=$null}
  if($sample.ContainsKey('warmup') -and $null -ne $sample['warmup'] -and !$sample['warmup'].ContainsKey('status')){$sample['warmup']['status']='ok'}
 }
 return ,$Payload
}
function Assert-R4SnesSameValue($Expected,$Actual,[string]$Path='run') {
 if($null -eq $Expected -or $null -eq $Actual) {
  if($null -ne $Expected -or $null -ne $Actual){throw "DevCenter readback differs at $Path"};return
 }
 if($Expected -is [Collections.IDictionary]) {
  if($Actual -isnot [Collections.IDictionary] -or $Expected.Count -ne $Actual.Count){throw "DevCenter readback fields differ at $Path"}
  foreach($key in $Expected.Keys) {
   if(!$Actual.ContainsKey($key)){throw "DevCenter readback field missing at $Path.$key"}
   Assert-R4SnesSameValue $Expected[$key] $Actual[$key] "$Path.$key"
  }
  return
 }
 if($Expected -is [Collections.IList]) {
  if($Actual -isnot [Collections.IList] -or $Expected.Count -ne $Actual.Count){throw "DevCenter readback array differs at $Path"}
  for($i=0;$i -lt $Expected.Count;$i++){Assert-R4SnesSameValue $Expected[$i] $Actual[$i] "$Path[$i]"};return
 }
 if($Expected.GetType() -ne $Actual.GetType() -or $Expected -cne $Actual){throw "DevCenter readback differs at $Path"}
}
function Publish-R4SnesExport {
 param([string]$Path,[string]$WorkspaceRoot,[string]$ApiUrl)
 $resolved=[IO.Path]::GetFullPath($Path,$WorkspaceRoot)
 $bytes=[IO.File]::ReadAllBytes($resolved)
 $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
 $expected=Convert-R4SnesImportPayload (Read-R4SnesJson $bytes)
 if($expected['benchmark_family'] -cne 'snes' -or $expected['subsystem_id'] -cne 'r4os.snes' -or $expected['schema_version'] -cne '1'){throw 'Expected a schema-1 SNES export'}
 $runId=$expected['run_id'];$hostId=$expected['host_id']
 if($runId -cnotmatch '^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -or $hostId -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$'){throw 'Invalid run_id or host_id'}
 $endpoint=$null
 if(![Uri]::TryCreate($ApiUrl,[UriKind]::Absolute,[ref]$endpoint) -or $endpoint.Scheme -notin @('http','https')){throw 'Set R4OS_DEVCENTER_API_URL or DEVCENTER_API_URL in Tools/BenchmarkHost.R4S'}
 $token=$env:R4OS_DEVCENTER_API_TOKEN
 if(!$token) {
  $tokenPath=$env:R4OS_DEVCENTER_API_TOKEN_FILE
  if(!$tokenPath){$tokenPath=Join-Path $WorkspaceRoot 'DevCenter/Runtime/api-token'}
  if(Test-Path -LiteralPath $tokenPath){$token=[IO.File]::ReadAllText($tokenPath).Trim()}
 }
 if(!$token -or $token.Length -lt 24 -or $token -match '\s'){throw 'Set the locally provisioned R4OS_DEVCENTER_API_TOKEN or R4OS_DEVCENTER_API_TOKEN_FILE'}
 $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false
 $client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(35)
 function Invoke-R4SnesApi([string]$Method,[string]$Route,[AllowNull()][byte[]]$Body=$null) {
  $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),$ApiUrl.TrimEnd('/')+$Route)
  if($Method -eq 'PUT'){$request.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$token)}
  if($null -ne $Body){$request.Content=[Net.Http.ByteArrayContent]::new($Body);$request.Content.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')}
  $response=$null
  try {
   $response=$client.SendAsync($request).GetAwaiter().GetResult()
   $raw=$response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
   if([int]$response.StatusCode -eq 404 -and $Method -eq 'GET'){return $null}
   if(!$response.IsSuccessStatusCode){throw ('DevCenter HTTP '+[int]$response.StatusCode+' at '+$Route+'; original export retained')}
   return ,(Read-R4SnesJson $raw)
  }finally{if($response){$response.Dispose()};$request.Dispose()}
 }
 try {
  $hostRecord=Invoke-R4SnesApi 'GET' ('/api/v1/hosts/'+$hostId)
  if($null -eq $hostRecord) {
   $context=$expected['environment']['host']
   if($null -eq $context){$context=@{}}
   $registration=[ordered]@{host_id=$hostId;display_name=$hostId;description='SNES benchmark host; actual execution context is bound to each run';hardware=[ordered]@{cpu=@{model=$context['cpu']};logical_cpus=$context['logical_cpus'];ram_bytes=$context['ram_bytes']};metadata=@{operating_system=$context['os'];benchmark_execution=$expected['environment']['execution']};tags=@('snes')}
   $null=Invoke-R4SnesApi 'PUT' ('/api/v1/hosts/'+$hostId) ([Text.Encoding]::UTF8.GetBytes(($registration|ConvertTo-Json -Depth 16)))
  }
  $route='/api/v1/subsystem-benchmark-runs/'+$runId
  $imported=Invoke-R4SnesApi 'PUT' $route $bytes
  if($imported['run_id'] -cne $runId -or $imported['stored'] -ne $true){throw 'DevCenter did not confirm the exact run_id'}
  $saved=Invoke-R4SnesApi 'GET' $route
  if($null -eq $saved -or $saved['host_snapshot']['host_id'] -cne $hostId -or $saved['sample_total'] -cne [string]$expected['samples'].Count){throw 'DevCenter run/host/sample receipt differs'}
  $validation=$saved['validation']
  foreach($metadata in @('host_snapshot','imported_at_utc','sample_total','validation')){$null=$saved.Remove($metadata)}
  Assert-R4SnesSameValue $expected $saved
  if((Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash){throw 'Original export changed during import'}
  if($expected['status'] -ceq 'completed' -and ($validation['status'] -cne 'valid' -or $expected['samples'].Count -ne 5)){throw 'DevCenter retained the export but did not qualify all five batches'}
  Write-Host "SNES DevCenter full readback: $runId / $($validation['status']) / $($expected['samples'].Count) batches / duplicate=$($imported['duplicate'])"
  return [pscustomobject]@{RunId=$runId;Status=$expected['status'];Validation=$validation['status'];Sha256=$hash;Path=$resolved}
 }finally{$client.Dispose()}
}
