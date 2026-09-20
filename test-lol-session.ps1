param([string]$TestDirectory)
$ErrorActionPreference='Stop'
if(-not $TestDirectory){$TestDirectory=Join-Path ([IO.Path]::GetTempPath()) ('lol-session-'+[guid]::NewGuid().ToString('N'))}
$env:LOL_LAB_DATA=$TestDirectory
. (Join-Path $PSScriptRoot 'lol-data.ps1')
function Check($condition,$name){if(-not $condition){throw "FAIL: $name"};Write-Output "PASS: $name"}
$module=Join-Path $PSScriptRoot 'lol-session.ps1'
Check (Test-Path $module) 'diagnostic module exists'
. $module
$logDir=Join-Path $TestDirectory 'logs';[void](New-Item -ItemType Directory $logDir -Force)
$log=Join-Path $logDir 'game.log';[IO.File]::WriteAllText($log,"old hn10-k8s-cc.lol.qq.com:8093 timeout token=SECRET`n")
$s=New-DiagnosticSession '暂不清楚' 'LOL' @($logDir)
Read-SessionLogs $s
Check ($s.observations.Count -eq 0) 'preexisting log not treated as this launch'
[IO.File]::AppendAllText($log,"GET https://hn10-k8s-cc.lol.qq.com:8093/api/v1/config/public?token=SECRET timed out`n")
Read-SessionLogs $s
Check ($s.observations.Count -eq 1) 'new failure observed'
Read-SessionLogs $s
Check ($s.observations.Count -eq 1) 'incremental read does not duplicate old events'
Check (-not (($s.observations|ConvertTo-Json -Depth 20) -match 'SECRET|token=')) 'raw credentials never stored in observations'
$report=Get-DiagnosticReport $s
Check ($report.findings.Count -gt 0) 'report explains observed timeout'
Check ($report.summary -notmatch '一定|必定|根因已') 'no unsupported certainty'
$empty=New-DiagnosticSession '未知区服' 'LOL' @()
$empty.marks+=@{stage='loading';kind='stuck';time=(Get-Date).ToString('o')}
$r=Get-DiagnosticReport $empty
Check ($r.summary -match '证据|确认') 'no evidence returns honest inconclusive page'
Check ($r.unchecked -match '对局') 'missing UDP is unchecked'
$chat=New-DiagnosticSession '未知' 'LOL' @()
Add-SessionObservation $chat @{host='hn10-k8s-ejabberd.lol.qq.com';ip='';port=5223;transport='TCP';evidence_kind='log';source_id='fixture';offset=0;event_time=$null;observed_at=(Get-Date).ToString('o');signal='timeout';stage='unknown';confidence='observed'}
$r=Get-DiagnosticReport $chat
Check ($r.summary -notmatch '无法进入|不能进入|阻塞') 'chat failure never asserts global blocker'
$newFile=Join-Path $logDir 'rotated.log';[IO.File]::WriteAllText($newFile,"https://hn10-k8s-sgp.lol.qq.com:21019 timeout`n",[Text.Encoding]::Unicode)
Read-SessionLogs $s
Check (@($s.observations|Where-Object port -eq 21019).Count -eq 1) 'new UTF16 log is read'
[IO.File]::WriteAllText($log,"hn10-k8s-feapp.lol.qq.com:2099 reset`n")
Read-SessionLogs $s
Check (@($s.observations|Where-Object port -eq 2099).Count -eq 1) 'truncated log resets checkpoint'
$export=Get-DiagnosticExport $s
Check (-not (($export|ConvertTo-Json -Depth 30) -match [regex]::Escape($TestDirectory))) 'export excludes local log paths'
Check ($localNodes.Count -eq 0) 'diagnostics does not require or add proxy nodes'
$conn=@{host='game.example';ip='';port=443;transport='TCP';evidence_kind='connection';source_id='clash';offset='same-connection';signal='connection_seen';observed_at=(Get-Date).ToString('o');chain=@('old')}
Add-SessionObservation $empty $conn
$updated=$conn.Clone();$updated.chain=@('new');$updated.observed_at=(Get-Date).AddSeconds(2).ToString('o')
Add-SessionObservation $empty $updated
Check (($empty.observations|Where-Object host -eq 'game.example').chain[0] -eq 'new') 'repeated live observation refreshes route chain'
Write-Output 'Session acceptance passed.'
