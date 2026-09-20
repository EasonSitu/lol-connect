param([Parameter(Mandatory)][string]$RequestPath,[Parameter(Mandatory)][string]$ResultPath)
. (Join-Path $PSScriptRoot 'lol-data.ps1')
. (Join-Path $PSScriptRoot 'lol-core.ps1')
. (Join-Path $PSScriptRoot 'lol-routing-review.ps1')
$request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json -AsHashtable
function Catalog {
  $nodes=@(@{id='direct';name='DIRECT';label='直连';type='direct';udp=$true;enabled=$true})+@($localNodes)
  try{foreach($p in (Core 'GET' '/proxies').proxies.PSObject.Properties){
    if($p.Value.type -notin @('Vless','Vmess','Trojan','Shadowsocks','Hysteria2','Tuic','Socks5','Http','WireGuard') -or $p.Name -like 'LOL-*'){continue}
    $id='ref-'+(Fingerprint $p.Name).Substring(0,12).ToLower()
    $nodes+=@{id=$id;name=$p.Name;label=('Clash · '+$p.Name);type='reference';reference=$p.Name;udp=[bool]$p.Value.udp;enabled=$true}
  }}catch{}
  return $nodes
}
function Pick($id){$n=@(Catalog)|Where-Object id -eq $id|Select-Object -First 1;if(-not $n){throw '节点不存在，请刷新列表。'};return $n}
function Snapshot {
  $nodes=@(Catalog);$selection=@{lobby='direct';config='direct';match='direct'};$active=$false;$online=$false;$cfg=$null;$notice=''
  try{
    $all=(Core 'GET' '/proxies').proxies;$cfg=Core 'GET' '/configs';$online=$true
    $active=[bool]$all.PSObject.Properties[$groups.lobby]
    foreach($g in $groups.Keys){if($active){$name=$all.PSObject.Properties[$groups[$g]].Value.now;$n=$nodes|Where-Object name -eq $name|Select-Object -First 1;$selection[$g]=if($n){$n.id}else{'missing'}}}
    if(-not $active -and $all.PSObject.Properties['LOL-STARTUP-TEST']){$notice='旧开关规则仍存在；请先在旧开关恢复，再用新版接管。'}
  }catch{$notice='Clash 未连接；仍可管理节点、目标和查看历史。'}
  $revision=Fingerprint $targets
  $valid=@((Read-Data 'history.json' @())|Where-Object {$r=$_;$n=$nodes|Where-Object id -eq $r.node|Select-Object -First 1;$n -and $r.nodeRevision -eq (Node-Revision $n) -and $r.targetRevision -eq $revision})
  return @{nodes=@($nodes|ForEach-Object {Public-Node $_});selection=$selection;active=$active;online=$online;mode=$cfg.mode;tun=[bool]$cfg.tun.enable;message=$notice;results=$valid;targets=$targets;settings=$settings;applied=(Read-Data 'applied-assignments.json' @{});observations=@(Read-Data 'observations.json' @());presets=(Read-Data 'presets.json' @{});outcomes=@(Read-Data 'outcomes.json' @());gameRunning=(@(Get-Process -ErrorAction SilentlyContinue|Where-Object ProcessName -match '^(TFTTencentClient|League of Legends)').Count -gt 0)}
}
function Guard-Change($id){$s=Snapshot;$applied=Read-Data 'applied-assignments.json' @{};if($s.active -and ($id -in $s.selection.Values -or $id -in @($applied.assignments.node_id))){throw '节点正在使用，请先应用替代节点或恢复配置。'};if(-not $s.online -and (Test-Path $labStateFile)){throw '无法确认当前分流，请连接 Clash 后再修改已有节点。'}}
function Save-Node($n){
  Validate-Node $n;$old=$localNodes|Where-Object id -eq $n.id|Select-Object -First 1
  if($n.id -and -not $old){throw '不能修改直连或 Clash 引用。'}
  if($old){Guard-Change $old.id;$n.name=$old.name}else{$n.id='node-'+[guid]::NewGuid().ToString('N').Substring(0,12);$n.name='LOL-LAB-'+$n.id}
  foreach($item in $localNodes){if($item.id -ne $n.id -and $item.type -eq $n.type -and $item.server -eq $n.server -and [int]$item.port -eq [int]$n.port){throw '该协议、地址和端口已存在。'}}
  if($n.password){$n.passwordProtected=ConvertTo-SecureString $n.password -AsPlainText -Force|ConvertFrom-SecureString}elseif($old -and -not $n.clearPassword){$n.passwordProtected=$old.passwordProtected}
  $n.Remove('password');$n.Remove('clearPassword');$n.enabled=[bool]$n.enabled
  Write-Data 'nodes.json' @(@($localNodes|Where-Object id -ne $n.id)+@($n));return @{message='节点已保存；重新测试后再应用。'}
}
function Add-Section($text,$key,$insert){$pattern='(?m)^'+[regex]::Escape($key)+':[ \t]*\r?$';if($text -notmatch $pattern){throw "配置需要顶层 $key 列表，暂不支持内联或锚点格式。"};$header=[regex]::Match($text,$pattern);$tail=$text.Substring($header.Index+$header.Length);$indentMatch=[regex]::Match($tail,'(?m)^([ \t]*)- ' );$indent=if($indentMatch.Success){$indentMatch.Groups[1].Value}else{''};$insert=($insert -split "`n"|ForEach-Object {$indent+$_}) -join "`n";return [regex]::Replace($text,$pattern,[Text.RegularExpressions.MatchEvaluator]{param($m) $key+":`n"+$insert})}
function Build-Lab($text){
  Validate-Targets $targets;if($text -match 'LOL-LAB-LOBBY'){throw '配置已含试验台规则，不能重复合并。'}
  $nodes=@(Catalog|Where-Object enabled);$extra=(@($nodes|Where-Object type -in @('http','socks5')|ForEach-Object {Node-Yaml $_}) -join "`n")
  if($extra){$text=Add-Section $text 'proxies' $extra}
  $lines=@();foreach($g in @('lobby','config','match')){$names=@($nodes|Where-Object {$g -ne 'match' -or $_.udp}|ForEach-Object name);$lines+='- '+(ConvertTo-Json -InputObject ([ordered]@{name=$groups[$g];type='select';proxies=$names}) -Compress)}
  $assignment=@(Get-RouteAssignments $targets $nodes $request.selection $request.assignments)
  foreach($a in $assignment|Where-Object override){$lines+='- '+(ConvertTo-Json -InputObject ([ordered]@{name=('LOL-LAB-T-'+(Fingerprint $a.target_id).Substring(0,12));type='select';proxies=@($a.node_name)}) -Compress)}
  $text=Add-Section $text 'proxy-groups' ($lines -join "`n")
  $rules=@();foreach($t in $targets|Where-Object enabled){$ip=$null;$match=if([Net.IPAddress]::TryParse($t.host,[ref]$ip)){if($ip.AddressFamily -eq 'InterNetworkV6'){"IP-CIDR6,$($t.host)/128"}else{"IP-CIDR,$($t.host)/32"}}else{"DOMAIN,$($t.host)"};$a=$assignment|Where-Object target_id -eq $t.id|Select-Object -First 1;$destination=if($a.override){'LOL-LAB-T-'+(Fingerprint $a.target_id).Substring(0,12)}else{$groups[$t.group]};$rules+='- '+("AND,(($match),(DST-PORT,$($t.port)),(NETWORK,$($t.network))),$destination"|ConvertTo-Json -Compress)}
  $rules+='- AND,((NETWORK,UDP),(PROCESS-NAME-REGEX,(?i)^(league of legends|tfttencentclient-win64-shipping)\.exe$)),LOL-LAB-MATCH'
  return Add-Section $text 'rules' ($rules -join "`n")
}
function Validate-File($path){$null=& $coreExe -t -d (Split-Path $source -Parent) -f $path 2>&1;if($LASTEXITCODE -ne 0){throw 'Mihomo 校验失败，当前分流未改变。'}}
function Current-Payload {
  $s=Snapshot;$rules=Rule-Signature ((Core 'GET' '/rules').rules)
  if($s.active){$saved=Read-Data 'active-state.json' @{};if($saved.signature -ne $rules -or $saved.sourceHash -ne (Get-FileHash $source).Hash){throw '运行规则或订阅已变化，请先重新加载订阅，避免覆盖其他修改。'};return [IO.File]::ReadAllText((Join-Path $labDir 'active.yaml'))}
  if($s.message -like '旧开关*'){throw $s.message};return [IO.File]::ReadAllText($source)
}
function Test-Group($key,$id){
  $n=Pick $id;if(-not $n.enabled){throw '节点已停用。'}
  if($key -eq 'match'){return @{passed=$null;rows=@();message=$(if($n.udp){'仅声明支持 UDP；尚未验证双向传输或对局。'}else{'没有声明 UDP，不能用于对局组。'})}}
  $selected=@($targets|Where-Object {$_.enabled -and $_.group -eq $key -and $_.network -eq 'TCP' -and $_.probe -ne 'none'})
  if(-not $selected.Count){throw '此组没有可测试的 TCP 目标。'};Validate-Targets $targets
  if(-not $settings.interface){throw '请先在设置选择物理网卡。'};if(-not (Test-Path $settings.python)){throw '请在设置中指定 Python 3。'}
  $dir=Join-Path $labDir ('probe-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory $dir);$proc=$null
  try{
    $l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$l.Start();$port=$l.LocalEndpoint.Port;$l.Stop()
    if($n.type -eq 'reference'){$text=[IO.File]::ReadAllText($source);$proxies=[regex]::Match($text,'(?ms)^proxies:[ \t]*\r?\n.*?(?=^[A-Za-z][A-Za-z0-9_-]*:|\z)').Value;if(-not $proxies){throw '无法提取引用节点。'}}
    elseif($n.type -eq 'direct'){$proxies="proxies:`n- "+(ConvertTo-Json -InputObject @{name='LAB-DIRECT';type='direct';'interface-name'=$settings.interface} -Compress)}else{$proxies="proxies:`n"+(Node-Yaml $n)}
    $chosen=if($n.type -eq 'direct'){'LAB-DIRECT'}else{$n.name}
    $config="mixed-port: $port`nallow-lan: false`nbind-address: 127.0.0.1`nmode: rule`nlog-level: silent`ninterface-name: $($settings.interface|ConvertTo-Json -Compress)`ntun:`n  enable: false`ndns:`n  enable: false`n$proxies`nrules:`n- "+("MATCH,$chosen"|ConvertTo-Json -Compress)+"`n"
    $file=Join-Path $dir 'probe.yaml';[IO.File]::WriteAllText($file,$config);Validate-File $file
    $proc=Start-Process $coreExe -ArgumentList @('-d',('"'+$dir+'"'),'-f',('"'+$file+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $dir 'core.log') -RedirectStandardError (Join-Path $dir 'error.log')
    $ready=$false;for($i=0;$i -lt 20;$i++){if($proc.HasExited){throw '测试代理启动失败。'};try{$tcp=[Net.Sockets.TcpClient]::new();$tcp.Connect('127.0.0.1',$port);$tcp.Dispose();$ready=$true;break}catch{Start-Sleep -Milliseconds 100}};if(-not $ready){throw '测试代理启动超时。'}
    $inputFile=Join-Path $dir 'request.json';[IO.File]::WriteAllText($inputFile,(@{port=$port;targets=$selected}|ConvertTo-Json -Depth 10))
    $raw=& $settings.python (Join-Path $PSScriptRoot 'lol-probe.py') $inputFile;if($LASTEXITCODE -ne 0){throw '探测程序未正常完成。'};return $raw|ConvertFrom-Json -AsHashtable
  }finally{if($proc -and -not $proc.HasExited){Stop-Process -Id $proc.Id -Force};$private=Join-Path $dir 'probe.yaml';if(Test-Path $private){Remove-Item -LiteralPath $private}}
}
function Record-Test($g,$id,$r){$n=Pick $id;$entry=@{time=(Get-Date).ToString('o');node=$id;group=$g;nodeRevision=(Node-Revision $n);targetRevision=(Fingerprint $targets);result=$r};Write-Data 'history.json' @(@((Read-Data 'history.json' @()))+@($entry)|Select-Object -Last 1000)}
$mutex=[Threading.Mutex]::new($false,('Local\LolRouteLab-'+(Fingerprint $labDir).Substring(0,16)));$locked=$false
try{
  $locked=$mutex.WaitOne(0);if(-not $locked){throw '另一个窗口正在操作，请稍后再试。'}
  $data=switch($request.action){
    {$_ -like 'session-*'} {. (Join-Path $PSScriptRoot 'lol-session.ps1');Session-Action $request}
    'state' {Snapshot}
    'save-node' {Save-Node $request.node}
    'delete-node' {Guard-Change $request.id;if($request.id -notin $localNodes.id){throw '只能删除手动节点。'};Write-Data 'nodes.json' @($localNodes|Where-Object id -ne $request.id);@{message='节点已删除，历史保留。'}}
    'save-targets' {Validate-Targets @($request.targets);Write-Data 'targets.json' @($request.targets);@{message='目标已保存，旧结果失效；点击应用后分流更新。'}}
    'reset-targets' {Write-Data 'targets.json' $defaultTargets;@{message='已恢复 hn10 默认模板；应用后生效。'}}
    'settings' {foreach($path in @($request.settings.core,$request.settings.source,$request.settings.python)){if($path -and -not (Test-Path $path)){throw '填写的程序或配置路径不存在；不使用的依赖可以留空。'}};if($request.settings.pipe -and $request.settings.pipe -notmatch '^[A-Za-z0-9_.-]+$'){throw '管道名无效。'};Write-Data 'settings.json' $request.settings;@{message='设置已保存。'}}
    'diagnostic-folder' {if(-not (Test-Path -LiteralPath $request.path -PathType Container)){throw '文件夹不存在。'};$settings.logRoots=@(@($settings.logRoots)+@($request.path)|Select-Object -Unique);Write-Data 'settings.json' $settings;@{message='已添加游戏文件夹，下次采样会寻找其中的日志。'}}
    'route-preview' {$s=Snapshot;@{assignments=@(Get-RouteAssignments $targets @(Catalog) $request.selection $request.assignments);message='只预览，不修改网络。已有 Clash 其他规则仍生效。'}}
    'route-suggest' {$s=Snapshot;@{assignments=(Suggest-Assignments $targets $s.results $s.nodes);message='基于当前有效测试记录提出建议，缺少证据的接口保持原选择。'}}
    'save-preset' {$p=Read-Data 'presets.json' @{};if(-not $request.name){throw '填写方案名称。'};$p[$request.name]=@{selection=$request.selection;overrides=$(if($request.assignments){$request.assignments}else{@{}})};Write-Data 'presets.json' $p;@{message='方案已保存，不自动应用。'}}
    'outcome' {$s=Snapshot;if(-not $s.active){throw '请先应用组合再记录验收。'};Write-Data 'outcomes.json' @(@(Read-Data 'outcomes.json' @())+@(@{time=(Get-Date).ToString('o');selection=$s.selection;overrides=$s.applied.overrides;outcome=$request.outcome;note=$request.note}));@{message='已记录实际游戏体验。'}}
    'discover' {
      . (Join-Path $PSScriptRoot 'lol-discover.ps1')
      $until=(Get-Date).AddSeconds([Math]::Min(60,[int]$request.durationSeconds));$request.resolveDns=$true
      do {
        $r=Get-LolObservations;$request.includeLogs=$false;$request.resolveDns=$false
        [IO.File]::WriteAllText(($ResultPath+'.progress'),(@{done=$r.observations.Count;total=0;node='识别中';group='';remaining=[Math]::Max(0,[int]($until-(Get-Date)).TotalSeconds)}|ConvertTo-Json))
        if(Test-Path ($ResultPath+'.cancel')){break}
        if((Get-Date) -ge $until){break};Start-Sleep -Seconds 3
      }while((Get-Date) -lt $until)
      $r
    }
    'test' {$r=Test-Group $request.group $request.node;Record-Test $request.group $request.node $r;$r}
    'batch' {
      $jobs=@();foreach($n in @(Catalog|Where-Object enabled)){foreach($g in @('config','lobby')){$jobs+=@{node=$n.id;group=$g}}};if($request.nodes){$jobs=@($jobs|Where-Object node -in $request.nodes)}
      $done=0;$cancelled=$false;foreach($job in $jobs){if(Test-Path ($ResultPath+'.cancel')){$cancelled=$true;break};[IO.File]::WriteAllText(($ResultPath+'.progress'),(@{done=$done;total=$jobs.Count;node=$job.node;group=$job.group}|ConvertTo-Json));try{$r=Test-Group $job.group $job.node}catch{$r=@{passed=$false;rows=@();message=$_.Exception.Message}};Record-Test $job.group $job.node $r;$done++}
      @{message="批量测试完成 $done/$($jobs.Count)，取消=$cancelled。UDP 未实测。";state=(Snapshot)}
    }
    {$_ -in @('plan','apply')} {
      $s=Snapshot;foreach($g in $groups.Keys){$n=Pick $request.selection[$g];if(-not $n.enabled -or ($g -eq 'match' -and -not $n.udp)){throw '节点停用或不支持 UDP。'}}
      $before=Current-Payload;$runtime=Save-Runtime;$base=if($s.active){[IO.File]::ReadAllText((Join-Path $labDir 'baseline.yaml'))}else{$before};$candidate=Build-Lab $base
      $path=Join-Path $labDir 'pending.yaml';[IO.File]::WriteAllText($path,$candidate);Validate-File $path
      if($request.action -eq 'plan'){@{message='配置校验通过，当前分流未改变。'};break}
      if($s.gameRunning -and -not $request.allowDuringGame){throw '请退出对局后应用。'};if($s.mode -ne 'rule' -or -not $s.tun){throw '需要 Clash 规则模式和 TUN。'}
      if(-not $s.active){[IO.File]::WriteAllText((Join-Path $labDir 'baseline.yaml'),$before);Write-Data 'baseline-runtime.json' $runtime}
      try{Load-Payload $candidate $runtime;foreach($g in $groups.Keys){$n=Pick $request.selection[$g];Core 'PUT' ('/proxies/'+$groups[$g]) @{name=$n.name}};$actual=Snapshot;foreach($g in $groups.Keys){if($actual.selection[$g] -ne $request.selection[$g]){throw '读回不一致。'}};[IO.File]::WriteAllText((Join-Path $labDir 'active.yaml'),$candidate);Write-Data 'active-state.json' @{signature=(Rule-Signature ((Core 'GET' '/rules').rules));sourceHash=(Get-FileHash $source).Hash};. (Join-Path $PSScriptRoot 'lol-session.ps1');Write-Data 'applied-assignments.json' @{active=$true;generation=[guid]::NewGuid().ToString('N');network=(Network-Stamp);source=(Get-FileHash $source).Hash;rules=(Fingerprint (Rule-Signature ((Core 'GET' '/rules').rules)));targets=(Fingerprint $targets);time=(Get-Date).ToString('o');assignments=@(Get-RouteAssignments $targets @(Catalog) $request.selection $request.assignments);overrides=$request.assignments};@{message='已应用并读回验证。重启客户端让新连接使用新规则。';state=$actual}}
      catch{Load-Payload $before $runtime;throw '应用失败，已尝试恢复原配置。'}
    }
    'restore' {$s=Snapshot;if($s.gameRunning -and -not $request.allowDuringGame){throw '请退出对局后恢复。'};if($s.active){$null=Current-Payload;$rt=Read-Data 'baseline-runtime.json' @{};$rt.mutable=(Save-Runtime).mutable;Load-Payload ([IO.File]::ReadAllText((Join-Path $labDir 'baseline.yaml'))) $rt;if((Snapshot).active){throw '恢复验证失败。'}};$retired=Read-Data 'applied-assignments.json' @{};$retired.active=$false;Write-Data 'applied-assignments.json' $retired;@{message='已恢复接管前配置。关闭窗口不会自动恢复。';state=(Snapshot)}}
    default {throw '未知操作。'}
  };$response=@{ok=$true;data=$data}
}catch{$response=@{ok=$false;error=$_.Exception.Message}}
finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
[IO.File]::WriteAllText($ResultPath,($response|ConvertTo-Json -Depth 40))
