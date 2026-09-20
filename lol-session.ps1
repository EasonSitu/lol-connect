# Passive diagnostics. No node, Python, Clash installation, or routing mutation required.
function Session-Roots {
  $roots=@($settings.logRoots)+@(Join-Path $env:LOCALAPPDATA 'TFT\Saved\Logs')
  foreach($p in @(Get-Process -ErrorAction SilentlyContinue|Where-Object ProcessName -match '^(LeagueClient|League of Legends|RiotClient|TFTTencentClient)')){
    try{if($p.Path){$dir=Split-Path $p.Path -Parent;$roots+=Join-Path $dir 'Logs';$roots+=Join-Path (Split-Path $dir -Parent) 'Logs'}}catch{}
  }
  return @($roots|Where-Object {$_ -and (Test-Path -LiteralPath $_ -PathType Container)}|Select-Object -Unique)
}
function Session-Files($roots){
  $files=@();foreach($r in $roots){if(Test-Path -LiteralPath $r -PathType Container){$files+=@(Get-ChildItem -LiteralPath $r -Filter '*.log' -File -Recurse -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 8)}}
  return @($files|Sort-Object FullName -Unique)
}
function Network-Stamp {
  try{$items=@(Get-NetIPConfiguration -ErrorAction Stop|ForEach-Object {@{adapter=$_.InterfaceAlias;ip=@($_.IPv4Address.IPAddress);gateway=@($_.IPv4DefaultGateway.NextHop)}});return Fingerprint $items}catch{return 'unknown'}
}
function New-DiagnosticSession($region,$mode,$roots){
  $s=@{id=[guid]::NewGuid().ToString('N');started_at=(Get-Date).ToString('o');ended_at=$null;status='observing';region_label=$region;mode=$mode;stage='unknown';marks=@();observations=@();warnings=@();checkpoints=@{};roots=@($roots);probes=@();confirmed_targets=@();network_fingerprint='';config_fingerprint='';last_sample=$null}
  foreach($f in Session-Files $roots){$s.checkpoints[$f.FullName]=@{offset=$f.Length;creation=$f.CreationTimeUtc.Ticks;prefix='';encoding=''}}
  return $s
}
function Session-Warn($s,$message){if($message -notin $s.warnings){$s.warnings=@($s.warnings)+@($message)}}
function Add-SessionObservation($s,$o){
  if($o.ip -match '^198\.(18|19)\.'){$o.ip='';$o.fake_ip=$true}
  if(-not $o.host -and -not $o.ip -and -not $o.signal){return}
  $id=Fingerprint @($o.evidence_kind,$o.source_id,$o.offset,$o.host,$o.ip,$o.port,$o.transport,$o.signal)
  $existing=$s.observations|Where-Object id -eq $id|Select-Object -First 1
  if($existing){if($o.evidence_kind -ne 'log'){foreach($key in @('chain','rule','rule_payload','process','event_time','observed_at')){$existing[$key]=$o[$key]};$existing.last_seen=$o.observed_at};return}
  $o.id=$id;$o.last_seen=$o.observed_at
  if(-not $o.stage){$o.stage=$s.stage};$s.observations=@(@($s.observations)+@($o)|Select-Object -Last 1500)
}
function Read-SessionLogs($s){
  $files=@(Session-Files $s.roots)
  if(-not $files.Count){Session-Warn $s '没有找到可读的游戏日志。可以继续观察连接，或在“选择游戏文件夹”补充位置。'}
  foreach($f in $files){
    $stream=$null
    try{
      $stream=[IO.File]::Open($f.FullName,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
      $key=$f.FullName;$cp=$s.checkpoints[$key]
      if(-not $cp){
        $cp=@{offset=0;creation=$f.CreationTimeUtc.Ticks;prefix='';encoding=''}
        if($f.CreationTimeUtc -lt ([datetime]$s.started_at).ToUniversalTime()){$cp.offset=$stream.Length;Session-Warn $s '后来找到的旧日志从当前末尾开始观察，先前内容未作为本次启动证据。'}
        $s.checkpoints[$key]=$cp
      }
      if($stream.Length -lt [long]$cp.offset -or $cp.creation -ne $f.CreationTimeUtc.Ticks){$cp.offset=0;$cp.creation=$f.CreationTimeUtc.Ticks;$cp.encoding='';$cp.prefix=''}
      $head=[byte[]]::new([Math]::Min(128,$stream.Length));$read=$stream.Read($head,0,$head.Length)
      $prefix=if($read -eq 128){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($head))}else{''}
      if($cp.prefix -and $prefix -and $cp.prefix -ne $prefix){$cp.offset=0};$cp.prefix=$prefix
      $enc=[Text.UTF8Encoding]::new($false,$false)
      if($head.Length -ge 2 -and $head[0] -eq 255 -and $head[1] -eq 254){$enc=[Text.Encoding]::Unicode}
      elseif($head.Length -ge 2 -and $head[0] -eq 254 -and $head[1] -eq 255){$enc=[Text.Encoding]::BigEndianUnicode}
      $cp.encoding=$enc.WebName
      if($stream.Length -eq [long]$cp.offset){continue}
      if($stream.Length-[long]$cp.offset -gt 2097152){$cp.offset=[Math]::Max(0,$stream.Length-2097152);Session-Warn $s '单轮日志增长过大，仅读取最近 2MB，部分事件可能缺失。'}
      $start=[long]$cp.offset;$null=$stream.Seek($start,'Begin');$bytes=[byte[]]::new([int]($stream.Length-$start));$count=$stream.Read($bytes,0,$bytes.Length)
      $text=$enc.GetString($bytes,0,$count);$last=$text.LastIndexOf("`n")
      if($last -lt 0){continue}
      $complete=$text.Substring(0,$last+1);$consumed=$enc.GetByteCount($complete);$cp.offset=$start+$consumed
      $lineOffset=$start
      foreach($line in ($complete -split "(?<=`n)")){
        $at=$lineOffset;$lineOffset+=$enc.GetByteCount($line);if(-not $line.Trim()){continue}
        $signal='observed'
        if($line -match '(?i)timed?\s*out|timeout|超时'){$signal='timeout'}elseif($line -match '(?i)connection.*reset|connection.*refused|连接.*拒绝'){$signal='connection_error'}elseif($line -match '(?i)certificate.*(fail|invalid)|SSL.*error'){$signal='tls_error'}
        $eventTime=$null
        $stamp=[regex]::Match($line,'(?<stamp>20\d{2}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))')
        if($stamp.Success){try{$eventTime=([datetimeoffset]::Parse($stamp.Value)).ToString('o');if([datetimeoffset]$eventTime -lt [datetimeoffset]$s.started_at){continue}}catch{}}
        $now=(Get-Date).ToString('o');$matches=[regex]::Matches($line,'(?i)(?:https?://)?(?<host>(?:[a-z0-9-]+\.)+[a-z]{2,}|(?:\d{1,3}\.){3}\d{1,3}):(?<port>\d{2,5})')
        foreach($m in $matches){
          $port=[int]$m.Groups['port'].Value;if($port -gt 65535){continue}
          $address=$m.Groups['host'].Value.ToLower();$ip=$null;$numeric=[Net.IPAddress]::TryParse($address,[ref]$ip)
          if($numeric -and ([Net.IPAddress]::IsLoopback($ip) -or $address -in @('0.0.0.0','::'))){continue}
          $transport=if($m.Value -match '^https?://'){'TCP'}else{'UNKNOWN'}
          Add-SessionObservation $s @{host=$(if($numeric){''}else{$address});ip=$(if($numeric){$address}else{''});port=$port;transport=$transport;process='';evidence_kind='log';source_id=(Fingerprint $key);offset=$at;event_time=$eventTime;observed_at=$now;signal=$signal;stage=$s.stage;confidence='observed'}
        }
        if($line -match 'Welcomed by server|TFTLoadingSubsystem.*Load completed|GAMEFLOW_EVENT\.GAME_LAUNCHED'){
          Add-SessionObservation $s @{host='';ip='';port=0;transport='UNKNOWN';process='';evidence_kind='log';source_id=(Fingerprint $key);offset=$at;event_time=$eventTime;observed_at=$now;signal='launch_progress';stage='loading';confidence='observed'}
        }
      }
    }catch{Session-Warn $s '有游戏日志暂时不可读，诊断可能不完整。'}finally{if($stream){$stream.Dispose()}}
  }
}
function Collect-SessionConnections($s){
  $now=(Get-Date).ToString('o');$script:coreConnectTimeout=250
  try{
    foreach($c in (Core 'GET' '/connections').connections){$m=$c.metadata
      if($m.host -notmatch '(^|\.)lol\.qq\.com$' -and $m.process -notmatch '(?i)^(LeagueClient|League of Legends|RiotClient|TFTTencentClient)'){continue}
      Add-SessionObservation $s @{host=[string]$m.host;ip=[string]$m.destinationIP;port=[int]$m.destinationPort;transport=([string]$m.network).ToUpper();process=[string]$m.process;evidence_kind='connection';source_id='clash';offset=[string]$c.id;event_time=$c.start;observed_at=$now;signal='connection_seen';stage=$s.stage;confidence='observed';chain=@($c.chains);rule=[string]$c.rule;rule_payload=[string]$c.rulePayload}
    }
  }catch{Session-Warn $s '未连接 Clash：基础诊断可继续，无法核对代理链和部分 UDP 目标。'}
  finally{$script:coreConnectTimeout=$null}
  $procs=@(Get-Process -ErrorAction SilentlyContinue|Where-Object ProcessName -match '^(LeagueClient|League of Legends|RiotClient|TFTTencentClient)')
  if(-not $procs.Count){Session-Warn $s '部分采样时尚未看到 LOL 进程；请在观察期间正常打开游戏。';return}
  try{foreach($c in @(Get-NetTCPConnection -ErrorAction Stop|Where-Object {$_.OwningProcess -in $procs.Id -and $_.RemotePort -gt 0 -and $_.RemoteAddress -notin @('127.0.0.1','::1','0.0.0.0','::')})){
    Add-SessionObservation $s @{host='';ip=[string]$c.RemoteAddress;port=[int]$c.RemotePort;transport='TCP';process=($procs|Where-Object Id -eq $c.OwningProcess|Select-Object -First 1).ProcessName;evidence_kind='connection';source_id='windows';offset="$($c.OwningProcess)-$($c.LocalPort)";event_time=$null;observed_at=$now;signal='connection_seen';stage=$s.stage;confidence='unclassified';state=[string]$c.State}
  }}catch{Session-Warn $s '无法读取部分系统连接；可用日志证据继续诊断。'}
}
function Get-SessionTargets($s){
  $map=@{}
  foreach($o in $s.observations){
    $address=if($o.host){$o.host}else{$o.ip};if(-not $address -or -not $o.port){continue}
    $known=$defaultTargets|Where-Object {$_.host -eq $o.host -and [int]$_.port -eq [int]$o.port}|Select-Object -First 1
    $network=if($o.transport -eq 'UNKNOWN' -and $known){'TCP'}else{$o.transport}
    $key="$address|$($o.port)|$network"
    if(-not $map.ContainsKey($key)){
      $id='found-'+(Fingerprint $key).Substring(0,12).ToLower()
      $t=@{id=$id;host=$address;port=[int]$o.port;network=$network;group=$(if($known){$known.group}else{'unknown'});label=$(if($known){$known.label}else{'用途待确认'});probe=$(if($known){$known.probe}elseif($network -eq 'TCP'){'tls'}else{'none'});url=$(if($known){$known.url}else{''});expected=$(if($known){$known.expected}else{''});enabled=$false;confirmed=$false;dependency=$(if($known -and $known.id -eq 'chat'){'optional'}else{'unknown'});evidence_ids=@();confidence=$(if($known){'template_match'}else{'unknown'})}
      $map[$key]=$t
    }
    $map[$key].evidence_ids=@($map[$key].evidence_ids)+@($o.id)
  }
  foreach($t in $map.Values){$saved=$s.confirmed_targets|Where-Object id -eq $t.id|Select-Object -First 1;if($saved){foreach($field in @('confirmed','enabled','group','probe','network','url','expected')){$t[$field]=$saved[$field]}}}
  return @($map.Values|Sort-Object host,port,network)
}
function Get-DiagnosticReport($s){
  $findings=@();$possible=@();$passed=@();$unchecked=@();$next=@();$stuck=@($s.marks|Where-Object kind -eq 'stuck'|Select-Object -Last 1)
  $stageNames=@{unknown='启动位置不确定';launcher='打开 WeGame / 登录';lobby='游戏大厅';loading='进入游戏 / 加载';match='实际对局'}
  $stage=if($stuck.Count){$stageNames[$stuck[0].stage]}else{'未标记卡住位置'}
  foreach($o in @($s.observations|Where-Object {$_.signal -in @('timeout','connection_error','tls_error')})){
    $known=$defaultTargets|Where-Object {$_.host -eq $o.host -and [int]$_.port -eq [int]$o.port}|Select-Object -First 1
    $service=if($known){$known.label}else{'尚未确认用途的连接'}
    $finding=@{text="$service 出现 $(switch($o.signal){'timeout'{'超时'}'tls_error'{'证书或 TLS 错误'}default{'连接错误'}})，尚不能据此确定根因。";evidence_ids=@($o.id);time=$(if($o.event_time){$o.event_time}else{$o.observed_at});target="$($o.host)$($o.ip):$($o.port)"}
    if($finding.text -notin $findings.text){$findings+=$finding}
  }
  foreach($p in $s.probes){foreach($row in $p.result.rows){if($row.ok){$passed+="$($row.name)：$($row.level)，尚未验证账号和游戏流程。"}else{$findings+=@{text="$($row.name)：$($row.detail)";evidence_ids=@();time=$p.time;target=$row.host}}}}
  if(@($s.observations|Where-Object signal -eq 'launch_progress').Count){$passed+='日志出现服务器欢迎或加载进展事件；不等于用户已成功完成对局。'}
  if(@($s.observations|Where-Object signal -eq 'connection_seen').Count){$passed+='观察到游戏连接记录；仅有连接记录不能证明业务成功。'}
  foreach($m in @($s.marks|Where-Object kind -eq 'reached')){$passed+='用户标记已到达：'+$stageNames[$m.stage]}
  if(-not @($s.observations|Where-Object transport -eq 'UDP').Count){$unchecked+='尚未观察到对局 UDP；不能判断对局连接是否可用。'}else{$unchecked+='已观察到 UDP 目标，但未验证双向游戏通信和丢包。'}
  $unchecked+='账号授权是否成功：未重放登录请求，需要客户端实际验证。'
  if(-not $s.probes.Count){$unchecked+='没有进行主动接口探测；当前结论来自连接、日志和用户标记。'}
  $unchecked+=@($s.warnings)
  if($findings.Count){$possible+='发现的错误可能与当前卡顿有关，仍需结合失败阶段和重试结果确认。';$next+='展开服务明细，先确认异常接口是否与本次卡住阶段有关。'}else{$next+='在卡住时标记位置并继续观察；如果仍无证据，可选择游戏安装文件夹。'}
  if($stuck.Count -and $passed.Count){$possible+='部分连接/阶段有进展，但你仍标记卡住；保留两类证据，不直接判断全部正常。'}
  $next+='可先查看结果并退出。若希望省去线路维护，成熟游戏加速器通常更省事。'
  $next+='已有自己的代理节点时，可确认目标后比较线路；本工具不提供节点。'
  $summary=if($findings.Count){"发现 $($findings.Count) 类连接异常；卡住位置：$stage。现象已记录，影响范围与根因尚未确认。"}else{"卡住位置：$stage。目前证据不足以确认具体阻塞接口。"}
  $applied=Read-Data 'applied-assignments.json' @{};$routeReview=@()
  if($applied.assignments -and (Get-Command Compare-ActualRoutes -ErrorAction SilentlyContinue)){
    $current=$false
    try{$current=Test-RouteContext $applied (Network-Stamp) ((Get-FileHash $source -ErrorAction Stop).Hash) (Fingerprint (Rule-Signature ((Core 'GET' '/rules').rules))) (Fingerprint $targets)}catch{}
    if($current){$routeReview=@(Compare-ActualRoutes $applied.assignments $s.observations $applied.time)}else{$unchecked+='先前分流记录已恢复、发生变化或无法确认当前状态，不能作为本次生效证据。'}
  }
  return @{summary=$summary;stage=$stage;findings=$findings;passed=@($passed|Select-Object -Unique);possible=$possible;unchecked=@($unchecked|Select-Object -Unique);next_actions=$next;targets=@(Get-SessionTargets $s);routes=$routeReview;status=$s.status;started_at=$s.started_at;ended_at=$s.ended_at}
}
function Get-DiagnosticExport($s){
  $r=Get-DiagnosticReport $s
  # Strict field allowlist: never export checkpoints, paths, raw lines, routes, or credentials.
  return @{format='lol-diagnostic-1';id=$s.id;started_at=$s.started_at;ended_at=$s.ended_at;summary=$r.summary;stage=$r.stage;findings=@($r.findings|ForEach-Object {@{text=$_.text;time=$_.time}});passed=$r.passed;unchecked=$r.unchecked;next_actions=$r.next_actions}
}
function Session-Path($id){if($id -notmatch '^[a-f0-9]{32}$'){throw '诊断记录编号无效。'};$dir=Join-Path $labDir 'diagnostics';[void](New-Item -ItemType Directory $dir -Force);return Join-Path $dir ($id+'.json')}
function Save-Session($s){$path=Session-Path $s.id;$tmp=$path+'.tmp';[IO.File]::WriteAllText($tmp,($s|ConvertTo-Json -Depth 40));Move-Item -LiteralPath $tmp -Destination $path -Force}
function Load-Session($id){$path=Session-Path $id;if(-not (Test-Path $path)){throw '找不到这次诊断，请重新开始。'};return Get-Content $path -Raw|ConvertFrom-Json -AsHashtable}
function Session-Action($req){
  if($req.action -eq 'session-start'){
    $s=New-DiagnosticSession $req.region $req.mode @(Session-Roots);$s.network_fingerprint=Network-Stamp;$s.config_fingerprint=if(Test-Path $source){(Get-FileHash $source).Hash}else{'unavailable'};Save-Session $s;Write-Data 'last-session.json' @{id=$s.id}
  }else{$s=Load-Session $req.id}
  switch($req.action){
    'session-sample' {
      if($s.status -eq 'observing'){
        $s.roots=@(@($s.roots)+@(Session-Roots)|Select-Object -Unique);Read-SessionLogs $s;Collect-SessionConnections $s;$s.last_sample=(Get-Date).ToString('o')
        if(((Get-Date)-[datetime]$s.started_at).TotalMinutes -ge 10){$s.status='finished';$s.ended_at=(Get-Date).ToString('o')}
        Save-Session $s
      }
    }
    'session-mark' {if($req.stage -notin @('launcher','lobby','loading','match') -or $req.kind -notin @('stuck','reached')){throw '阶段标记无效。'};$s.stage=$req.stage;$s.marks+=@{stage=$req.stage;kind=$req.kind;time=(Get-Date).ToString('o')};Save-Session $s}
    'session-stop' {if($s.status -eq 'observing'){Read-SessionLogs $s;Collect-SessionConnections $s};$s.status='finished';$s.ended_at=(Get-Date).ToString('o');$stamp=Network-Stamp;if($stamp -ne $s.network_fingerprint){Session-Warn $s '诊断期间网络环境发生变化，之前结果需要在新网络重新验证。'};Save-Session $s}
    'session-confirm' {
      $found=@(Get-SessionTargets $s);$selected=@();foreach($pick in $req.targets){$t=$found|Where-Object id -eq $pick.id|Select-Object -First 1;if(-not $t){throw '目标不属于当前诊断。'};if($pick.group -notin @('lobby','config','match') -or $pick.network -notin @('TCP','UDP')){throw '请确认用途和协议。'};$t.group=$pick.group;$t.network=$pick.network;$t.confirmed=$true;$t.enabled=$true
        if($t.network -eq 'UDP'){$t.probe='none';$t.group='match'}elseif($t.probe -eq 'none'){$t.probe='tls'};$selected+=$t
      }
      Validate-Targets $selected;$s.confirmed_targets=$selected;Save-Session $s
      Write-Data 'targets.json' $selected
    }
    'session-probe' {
      $chosen=@($s.confirmed_targets|Where-Object {$_.enabled -and $_.network -eq 'TCP' -and $_.probe -ne 'none'})
      if(-not $chosen.Count){throw '先在服务明细中确认本次目标，再测试当前网络。'}
      if(-not $settings.python -or -not (Test-Path $settings.python)){Session-Warn $s '未配置 Python，跳过主动探测；基础诊断结果仍然有效。';Save-Session $s;break}
      Validate-Targets $chosen
      $inputFile=Join-Path $labDir ('session-probe-'+$s.id+'.json');[IO.File]::WriteAllText($inputFile,(@{port=$null;targets=$chosen}|ConvertTo-Json -Depth 20))
      try{$raw=& $settings.python (Join-Path $PSScriptRoot 'lol-probe.py') $inputFile;if($LASTEXITCODE -ne 0){throw '主动探测程序没有正常完成。'};$result=$raw|ConvertFrom-Json -AsHashtable;$s.probes+=@{time=(Get-Date).ToString('o');path='当前系统网络；现有 VPN/TUN 可能参与，尚未完全确认路径';result=$result};Save-Session $s}finally{if(Test-Path $inputFile){Remove-Item -LiteralPath $inputFile}}
    }
    'session-export' {$path=Join-Path $labDir ('diagnostic-report-'+$s.id+'.json');[IO.File]::WriteAllText($path,((Get-DiagnosticExport $s)|ConvertTo-Json -Depth 30));return @{id=$s.id;export_path=$path;message='已导出本地脱敏摘要，不含地址、节点或日志原文。'}}
  }
  return @{id=$s.id;session=$s;report=(Get-DiagnosticReport $s);count=$s.observations.Count;message='诊断记录已更新。'}
}
