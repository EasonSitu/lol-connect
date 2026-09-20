function Get-LolObservations {
  $observed=@(Read-Data 'observations.json' @());$map=@{};$now=(Get-Date).ToString('o');$warnings=@()
  foreach($o in $observed){$map[$o.key]=$o}
  function Observe($hostName,$ip,$port,$network,$process,$evidence){
    if(-not $hostName -and -not $ip){return}
    $key="$hostName|$ip|$port|$network|$evidence"
    $t=$targets|Where-Object {$_.host -eq $hostName -and [int]$_.port -eq [int]$port -and $_.network -eq $network}|Select-Object -First 1
    $category=if($t){$t.group}else{'待确认'}
    if($map.ContainsKey($key)){$map[$key].lastSeen=$now}else{$map[$key]=@{key=$key;host=$hostName;ip=$ip;port=$port;network=$network;process=$process;evidence=$evidence;group=$category;firstSeen=$now;lastSeen=$now}}
  }
  try{foreach($c in (Core 'GET' '/connections').connections){
    $m=$c.metadata
    if($m.host -match '(^|\.)lol\.qq\.com$' -or $m.process -match '(?i)league|tft|riot'){
      $ip=$m.destinationIP
      if($ip -match '^198\.(18|19)\.'){$ip='';$evidence='Clash（Fake-IP 不作真实目标）'}else{$evidence='Clash 当前连接'}
      Observe $m.host $ip $m.destinationPort ([string]$m.network).ToUpper() $m.process $evidence
    }
  }}catch{$warnings+='Clash 连接信息不可用。'}
  $processes=@(Get-Process -ErrorAction SilentlyContinue|Where-Object ProcessName -match '(?i)^(LeagueClient|League of Legends|RiotClient|TFTTencentClient)')
  if($processes.Count){
    try{foreach($c in Get-NetTCPConnection -ErrorAction Stop|Where-Object {$_.OwningProcess -in $processes.Id -and $_.RemotePort -gt 0}){
      if($c.RemoteAddress -in @('0.0.0.0','::','127.0.0.1','::1') -or $c.RemoteAddress -match '^198\.(18|19)\.'){continue}
      $proc=$processes|Where-Object Id -eq $c.OwningProcess|Select-Object -First 1
      Observe '' $c.RemoteAddress $c.RemotePort 'TCP' $proc.ProcessName '系统 TCP（用途待确认）'
    }}catch{$warnings+='系统 TCP 连接读取失败。'}
  }
  # DNS refresh of configured domains gives a current mapping, not proof the game used it.
  foreach($t in $targets|Where-Object {$_.enabled -and $request.resolveDns}){
    $ip=$null;if([Net.IPAddress]::TryParse($t.host,[ref]$ip)){continue}
    try{foreach($r in Resolve-DnsName $t.host -DnsOnly -QuickTimeout -ErrorAction Stop|Where-Object IPAddress){if($r.IPAddress -notmatch '^198\.(18|19)\.'){Observe $t.host $r.IPAddress $t.port $t.network '' 'DNS 解析（非连接证据）'}}}catch{}
  }
  if($request.includeLogs){
    $roots=@($settings.logRoots)+@(Join-Path $env:LOCALAPPDATA 'TFT\Saved\Logs')
    foreach($p in $processes){try{if($p.Path){$roots+=Join-Path (Split-Path $p.Path -Parent) 'Logs'}}catch{}}
    foreach($root in $roots|Where-Object {$_ -and (Test-Path $_)}|Select-Object -Unique){
      $files=Get-ChildItem -LiteralPath $root -Filter '*.log' -File -Recurse -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 5
      foreach($file in $files){
        $stream=$null;try{
          $stream=[IO.File]::Open($file.FullName,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete));$start=[Math]::Max(0,$stream.Length-1048576);$null=$stream.Seek($start,'Begin');$reader=[IO.StreamReader]::new($stream);$text=$reader.ReadToEnd()
          foreach($m in [regex]::Matches($text,'(?i)(?<host>[a-z0-9.-]+\.lol\.qq\.com):(?<port>\d{2,5})')|Select-Object -Last 200){
            $hostName=$m.Groups['host'].Value;$port=[int]$m.Groups['port'].Value
            if($port -le 65535){Observe $hostName '' $port 'UNKNOWN' '' ('历史日志 '+$file.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))}
          }
        }catch{}finally{if($stream){$stream.Dispose()}}
      }
    }
  }
  $result=@($map.Values|Sort-Object lastSeen -Descending|Select-Object -First 1000)
  Write-Data 'observations.json' $result
  return @{message="发现/更新 $($result.Count) 条地址记录。$($warnings -join ' ') 用途待确认的记录不会自动分流。";observations=$result}
}
