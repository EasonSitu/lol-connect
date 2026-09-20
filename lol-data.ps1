$ErrorActionPreference='Stop'
$baseDir=Split-Path $PSScriptRoot -Parent
$labDir=if($env:LOL_LAB_DATA){$env:LOL_LAB_DATA}else{Join-Path $env:LOCALAPPDATA 'LolRouteLab'}
[void](New-Item -ItemType Directory -Path $labDir -Force)
function Read-Data($name,$fallback){
  $path=Join-Path $labDir $name
  if(Test-Path $path){return Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable}
  return $fallback
}
function Write-Data($name,$value){
  $path=Join-Path $labDir $name
  $tmp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
  [IO.File]::WriteAllText($tmp,(ConvertTo-Json -InputObject $value -Depth 40),[Text.UTF8Encoding]::new($false))
  if(Test-Path $path){Copy-Item -LiteralPath $path -Destination ($path+'.bak') -Force}
  Move-Item -LiteralPath $tmp -Destination $path -Force
}
$settings=Read-Data 'settings.json' @{}
if(-not $settings.pipe){$settings.pipe='verge-mihomo'}
if(-not $settings.source){$settings.source=Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml'}
if(-not $settings.core){
  $command=Get-Command verge-mihomo.exe,mihomo.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  $settings.core=if($command){$command.Source}else{Join-Path $env:ProgramFiles 'Clash Verge\verge-mihomo.exe'}
}
if(-not $settings.python){$cmd=Get-Command python.exe -ErrorAction SilentlyContinue|Where-Object Source -notlike '*WindowsApps*'|Select-Object -First 1;if($cmd){$settings.python=$cmd.Source}}
if(-not $settings.interface){
  try{$settings.interface=(Get-NetAdapter -Physical|Where-Object Status -eq 'Up'|Sort-Object ifIndex|Select-Object -First 1).Name}catch{}
}
$source=$settings.source;$coreExe=$settings.core
$groups=@{lobby='LOL-LAB-LOBBY';config='LOL-LAB-CONFIG';match='LOL-LAB-MATCH'}
$group='LOL-STARTUP-TEST'
$labStateFile=Join-Path $labDir 'active-state.json'
$defaultTargets=@(
 @{id='config';label='公开启动配置';group='config';host='hn10-k8s-cc.lol.qq.com';port=8093;network='TCP';probe='config';enabled=$true;url='https://hn10-k8s-cc.lol.qq.com:8093/api/v1/config/public?os=windows&region=TENCENT&app=LoL&namespace=lol';expected='200'},
 @{id='lobby';label='大厅';group='lobby';host='hn10-k8s-sgp.lol.qq.com';port=21019;network='TCP';probe='http';enabled=$true;url='';expected='401'},
 @{id='auth';label='授权入口';group='lobby';host='hn10-k8s-entitlements.lol.qq.com';port=28088;network='TCP';probe='http';enabled=$true;url='';expected='404'},
 @{id='chat';label='聊天';group='lobby';host='hn10-k8s-ejabberd.lol.qq.com';port=5223;network='TCP';probe='tls';enabled=$true;url='';expected=''},
 @{id='session';label='平台会话';group='lobby';host='hn10-k8s-feapp.lol.qq.com';port=2099;network='TCP';probe='tls';enabled=$true;url='';expected=''}
)
$targets=@(Read-Data 'targets.json' $defaultTargets)
$localNodes=@(Read-Data 'nodes.json' @())
$domains=@($targets|ForEach-Object host)
function Validate-Host([string]$value){
  if(-not $value -or $value.Length -gt 253 -or $value -match '[\s,()"''/\\]'){throw '地址必须为单个 IP 或域名，不能包含协议或规则符号。'}
  $ip=$null
  if([Net.IPAddress]::TryParse($value,[ref]$ip)){return}
  if($value -notmatch '^(?=.{1,253}$)([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'){throw '无效的域名。'}
}
function Validate-Port($value){$p=0;if(-not [int]::TryParse([string]$value,[ref]$p) -or $p -lt 1 -or $p -gt 65535){throw '端口必须在 1–65535 之间。'}}
function Validate-Node($n){
  if($n.type -notin @('http','socks5')){throw '手动节点支持 HTTP 和 SOCKS5。'}
  Validate-Host $n.server;Validate-Port $n.port
  if(-not $n.label -or $n.label.Length -gt 100){throw '请填写 1–100 字的节点名称。'}
  if($n.type -eq 'http' -and $n.udp){throw 'HTTP 节点不能声明 UDP 支持。'}
}
function Validate-Targets($items){
  if(-not @($items).Count){throw '至少保留一条目标规则（可停用）。'}
  $seen=@{}
  foreach($t in $items){
    if($t.id -notmatch '^[a-zA-Z0-9-]+$' -or $seen.ContainsKey($t.id)){throw '目标 ID 必须唯一且仅含字母、数字、连字符。'};$seen[$t.id]=$true
    Validate-Host $t.host;Validate-Port $t.port
    if($t.group -notin $groups.Keys -or $t.network -notin @('TCP','UDP') -or $t.probe -notin @('config','http','tls','none')){throw '目标分组、协议或探测方式无效。'}
    if($t.network -eq 'UDP' -and $t.probe -ne 'none'){throw 'UDP 目标只记录和分流，探测方式请选择 none。'}
    if($t.network -eq 'UDP' -and $t.group -ne 'match'){throw 'UDP 目标必须放入 match 对局组，避免路由到仅 TCP 的节点。'}
    if($t.url){
      $uri=$null;if(-not [uri]::TryCreate($t.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -ne $t.host -or $uri.Port -ne [int]$t.port -or $uri.UserInfo -or $uri.Fragment){throw '测试 URL 必须是当前目标的 HTTPS 地址，不能包含登录信息。'}
      if($t.probe -eq 'config'){
        if($uri.AbsolutePath -ne '/api/v1/config/public'){throw '配置测试只允许公开配置接口。'}
        foreach($part in ($uri.Query.TrimStart('?') -split '&')){if($part -and [uri]::UnescapeDataString(($part -split '=')[0]) -notin @('os','region','app','namespace','version','patchline')){throw '公开配置 URL 含不允许的参数。'}}
      }elseif($uri.Query){throw '普通测试 URL 不允许查询参数。'}
    }elseif($t.probe -eq 'config'){throw '配置探测需要填写公开 URL。'}
    if($t.expected -and $t.expected -notmatch '^\d{3}$'){throw '预期 HTTP 状态应为三位数字或空。'}
  }
}
function Canonical($value){
  if($value -is [Collections.IDictionary]){$o=[ordered]@{};foreach($k in @($value.Keys|Sort-Object)){$o[$k]=Canonical $value[$k]};return $o}
  if($value -is [array]){return ,@($value|ForEach-Object {Canonical $_})}
  return $value
}
function Fingerprint($value){
  $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject (Canonical $value) -Depth 30 -Compress))
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}
function Node-Revision($n){
  if(-not $script:networkRevision){try{$script:networkRevision=Fingerprint @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop|Select-Object InterfaceAlias,IPAddress|Sort-Object InterfaceAlias,IPAddress|ForEach-Object {@($_.InterfaceAlias,$_.IPAddress)})}catch{$script:networkRevision='unknown'}}
  $refHash=if($n.reference -and (Test-Path $source)){(Get-FileHash $source).Hash}else{''};return Fingerprint @($n.type,$n.server,$n.port,$n.udp,$n.username,$n.passwordProtected,$n.reference,$settings.interface,$refHash,$script:networkRevision)
}
function Public-Node($n){$copy=@{};foreach($k in $n.Keys){if($k -ne 'passwordProtected'){$copy[$k]=$n[$k]}};$copy.hasPassword=[bool]$n.passwordProtected;return $copy}
function Node-Yaml($n){
  $obj=[ordered]@{name=$n.name;type=$n.type;server=$n.server;port=[int]$n.port;udp=[bool]$n.udp;'interface-name'=$settings.interface}
  if($n.username){$obj.username=$n.username}
  if($n.passwordProtected){$obj.password=ConvertTo-SecureString $n.passwordProtected|ConvertFrom-SecureString -AsPlainText}
  # JSON is a YAML-compatible flow mapping; strings cannot inject YAML rules.
  return '- '+(ConvertTo-Json -InputObject $obj -Compress)
}
