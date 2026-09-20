$ErrorActionPreference='Stop'
$env:LOL_LAB_DATA=Join-Path ([IO.Path]::GetTempPath()) ('lol-route-test-'+[guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'lol-data.ps1')
function Check($condition,$name){if(-not $condition){throw "FAIL: $name"};Write-Output "PASS: $name"}
$module=Join-Path $PSScriptRoot 'lol-routing-review.ps1'
Check (Test-Path $module) 'route review module exists'
. $module
$ts=@(@{id='a';host='game.example';port=443;network='TCP';group='lobby';label='大厅';enabled=$true},@{id='b';host='game.example';port=444;network='TCP';group='config';label='配置';enabled=$true})
$ns=@(@{id='direct';name='DIRECT';enabled=$true;udp=$true},@{id='node';name='user-node';enabled=$true;udp=$false})
$selection=@{lobby='node';config='direct';match='direct'}
$list=Get-RouteAssignments $ts $ns $selection @{a='direct'}
Check (($list|Where-Object target_id -eq 'a').node_id -eq 'direct') 'per-interface override takes precedence'
Check (($list|Where-Object target_id -eq 'b').node_id -eq 'direct') 'another port remains unchanged'
$rejected=$false;try{Get-RouteAssignments @(@{id='u';host='game.example';port=9999;network='UDP';group='match';enabled=$true}) $ns $selection @{u='node'}|Out-Null}catch{$rejected=$true}
Check $rejected 'TCP node rejected for UDP override'
$r=Compare-ActualRoutes $list @()
Check (@($r|Where-Object state -ne 'not_observed').Count -eq 0) 'no connection is not a verified route'
$obs=@(@{host='game.example';ip='';port=443;transport='TCP';process='LeagueClient.exe';event_time=(Get-Date).ToString('o');evidence_kind='connection';source_id='clash';chain=@('user-node');observed_at=(Get-Date).ToString('o');rule='Domain'})
$r=Compare-ActualRoutes $list $obs
Check (($r|Where-Object target_id -eq 'a').state -eq 'mismatch') 'actual wrong proxy reported'
$ts+=@{id='c';host='game.example';port=443;network='TCP';group='config';enabled=$true}
$rejected=$false;try{Get-RouteAssignments $ts $ns $selection @{}|Out-Null}catch{$rejected=$true}
Check $rejected 'duplicate conflicting destination rejected'
$history=@(
 @{node='direct';time=(Get-Date).AddMinutes(-2).ToString('o');result=@{rows=@(@{id='a';ok=$true;seconds=1})}},
 @{node='direct';time=(Get-Date).AddMinutes(-1).ToString('o');result=@{rows=@(@{id='a';ok=$false;seconds=6})}},
 @{node='node';time=(Get-Date).ToString('o');result=@{rows=@(@{id='a';ok=$true;seconds=2})}}
)
$suggest=Suggest-Assignments @($ts[0]) $history $ns
Check ($suggest.a -eq 'node') 'latest failure invalidates older direct success'
$browser=@(@{host='game.example';port=443;transport='TCP';process='browser.exe';evidence_kind='connection';source_id='clash';chain=@('DIRECT');observed_at=(Get-Date).ToString('o')})
$r=Compare-ActualRoutes $list $browser
Check (($r|Where-Object target_id -eq 'a').state -ne 'matched') 'browser traffic cannot confirm game routing'
$old=@(@{host='game.example';port=443;transport='TCP';process='LeagueClient.exe';evidence_kind='connection';source_id='clash';chain=@('DIRECT');observed_at=(Get-Date).ToString('o')})
$r=Compare-ActualRoutes $list $old (Get-Date).AddMinutes(-1).ToString('o')
Check (($r|Where-Object target_id -eq 'a').state -ne 'matched') 'missing start time cannot confirm post-apply routing'
Check (-not (Test-RouteContext @{active=$false} 'a' 'a' 'a' 'a')) 'restored context is not current'
Check (-not (Test-RouteContext @{active=$true;network='old';source='a';rules='a';targets='a'} 'new' 'a' 'a' 'a')) 'network change invalidates route context'
