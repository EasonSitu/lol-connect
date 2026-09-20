param([string]$TestDirectory)
$ErrorActionPreference='Stop'
if(-not $TestDirectory){$TestDirectory=Join-Path ([IO.Path]::GetTempPath()) ('lol-lab-test-'+[guid]::NewGuid().ToString('N'))}
$oldData=$env:LOL_LAB_DATA;$env:LOL_LAB_DATA=$TestDirectory
$pwsh=Join-Path $PSHOME 'pwsh.exe';$worker=Join-Path $PSScriptRoot 'lol-worker.ps1'
function Assert($condition,$message){if(-not $condition){throw "FAIL: $message"};Write-Output "PASS: $message"}
function Invoke-TestAction($request){
  $id=[guid]::NewGuid().ToString('N');$inputFile=Join-Path $TestDirectory ($id+'-input.json');$outputFile=Join-Path $TestDirectory ($id+'-output.json')
  [IO.File]::WriteAllText($inputFile,($request|ConvertTo-Json -Depth 30))
  & $pwsh -NoProfile -File $worker -RequestPath $inputFile -ResultPath $outputFile|Out-Null
  $result=Get-Content $outputFile -Raw|ConvertFrom-Json -AsHashtable
  Remove-Item -LiteralPath $inputFile
  return $result
}
try{
  . (Join-Path $PSScriptRoot 'lol-data.ps1')
  Assert ($localNodes.Count -eq 0) 'clean installation has no user nodes'
  Assert ((Fingerprint @{b=2;a=1}) -eq (Fingerprint @{a=1;b=2})) 'canonical result revision is stable'
  $bad=@{label='test';type='http';server='example.com),(MATCH,evil';port=443;udp=$false};$rejected=$false
  try{Validate-Node $bad}catch{$rejected=$true};Assert $rejected 'rule injection rejected'
  $n=@{label='local test';type='socks5';server='192.0.2.10';port=1080;udp=$false;enabled=$true;username='test';password='not-a-real-password'}
  $r=Invoke-TestAction @{action='save-node';node=$n};Assert $r.ok 'create node'
  $saved=@(Read-Data 'nodes.json' @());$n=$saved[0];Assert ($n.passwordProtected -and -not $n.password) 'password stored encrypted'
  $snapshot=Invoke-TestAction @{action='state'}
  Assert (-not (($snapshot|ConvertTo-Json -Depth 30) -match 'not-a-real-password')) 'state never exposes password'
  $n.label='renamed';$n.Remove('passwordProtected');$r=Invoke-TestAction @{action='save-node';node=$n};Assert $r.ok 'edit node preserves password'
  $saved=@(Read-Data 'nodes.json' @());Assert ([bool]$saved[0].passwordProtected) 'encrypted password preserved when blank'
  $duplicate=@{label='duplicate';type='socks5';server='192.0.2.10';port=1080;udp=$false;enabled=$true}
  $r=Invoke-TestAction @{action='save-node';node=$duplicate};Assert (-not $r.ok) 'duplicate endpoint rejected'
  $r=Invoke-TestAction @{action='delete-node';id=$n.id};Assert $r.ok 'delete unused node'
  $valid=@($defaultTargets);$valid[0].host='example.com';$valid[0].url='https://example.com:8093/api/v1/config/public?token=secret'
  $r=Invoke-TestAction @{action='save-targets';targets=$valid};Assert (-not $r.ok) 'token-bearing probe URL rejected'
  $r=Invoke-TestAction @{action='reset-targets'};Assert $r.ok 'restore target defaults'
  $r=Invoke-TestAction @{action='save-preset';name='with-overrides';selection=@{lobby='direct';config='direct';match='direct'};assignments=@{example='direct'}}
  $preset=Read-Data 'presets.json' @{};Assert ($r.ok -and $preset['with-overrides'].overrides.example -eq 'direct') 'preset preserves interface overrides'
  $cancelOut=Join-Path $TestDirectory 'cancel-result.json';$cancelIn=Join-Path $TestDirectory 'cancel-input.json'
  [IO.File]::WriteAllText($cancelIn,'{"action":"batch"}');[IO.File]::WriteAllText(($cancelOut+'.cancel'),'cancel')
  & $pwsh -NoProfile -File $worker -RequestPath $cancelIn -ResultPath $cancelOut|Out-Null
  $r=Get-Content $cancelOut -Raw|ConvertFrom-Json;Assert ($r.ok -and $r.data.message -match '0/') 'cancel stops queued batch without a probe'
  Write-Output 'All local acceptance checks passed; no live routing was modified.'
}finally{$env:LOL_LAB_DATA=$oldData}
