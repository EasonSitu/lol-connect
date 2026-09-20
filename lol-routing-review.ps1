function Get-RouteAssignments($targetItems,$nodeItems,$selection,$overrides){
  $seen=@{};$out=@()
  foreach($t in @($targetItems|Where-Object enabled)){
    $key="$($t.host):$($t.port)/$($t.network)".ToLower();if($seen.ContainsKey($key)){throw '多个目标重复匹配同一地址和端口，请合并后再应用。'};$seen[$key]=$true
    $id=if($overrides -and $overrides.ContainsKey($t.id) -and $overrides[$t.id]){$overrides[$t.id]}else{$selection[$t.group]}
    $n=$nodeItems|Where-Object id -eq $id|Select-Object -First 1
    if(-not $n -or -not $n.enabled){throw '分流引用了不存在或已停用的节点。'}
    if($t.network -eq 'UDP' -and -not $n.udp){throw '对局 UDP 不能使用仅支持 TCP 的节点。'}
    $out+=@{target_id=$t.id;host=$t.host;port=$t.port;network=$t.network;group=$t.group;label=$t.label;node_id=$n.id;node_name=$n.name;override=[bool]($overrides -and $overrides.ContainsKey($t.id));notice=$(if($t.group -eq 'lobby'){'可能包含授权/聊天/会话数据'}else{'按地址和端口转发，不是 URL 级隔离'})}
  }
  return $out
}
function Compare-ActualRoutes($assignments,$observations,$since=$null){
  $rows=@()
  foreach($a in $assignments){
    $hits=@($observations|Where-Object {$_.evidence_kind -eq 'connection' -and $_.source_id -eq 'clash' -and ($_.host -eq $a.host -or $_.ip -eq $a.host) -and [int]$_.port -eq [int]$a.port -and $_.transport -eq $a.network}|Sort-Object observed_at -Descending)
    $o=$hits|Select-Object -First 1
    $state='not_observed';$reason='尚未看到游戏的新连接，不能判断规则是否实际生效。'
    if($o){
      if($o.process -notmatch '(?i)^(LeagueClient|LeagueClientUx|LeagueClientUxRender|League of Legends|TFTTencentClient|TFTTencentClient-Win64-Shipping)\.exe$' -or ($since -and -not $o.event_time)){$state='insufficient_evidence';$reason='无法确认这是游戏进程在应用配置后建立的新连接。'}
      elseif($since -and $o.event_time -and [datetime]$o.event_time -lt [datetime]$since){$state='old_connection';$reason='连接早于本次应用，重新打开客户端后再核验。'}
      elseif($a.node_name -in $o.chain){$state='matched';$reason='观察到目标连接使用预期路径；业务成功仍需游戏验收。'}
      else{$state='mismatch';$reason='观察到的代理链与预期不同，请核对规则或重新建立连接。'}
    }
    $rows+=@{target_id=$a.target_id;target="$($a.host):$($a.port)";expected=$a.node_name;observed_chain=@($o.chain);observed_rule=$o.rule;seen_at=$o.observed_at;state=$state;reason=$reason}
  }
  return $rows
}
function Suggest-Assignments($targetItems,$history,$nodeItems){
  $result=@{}
  foreach($t in @($targetItems|Where-Object enabled)){
    if($t.network -eq 'UDP'){continue}
    $candidates=@();$seen=@{};foreach($h in @($history|Sort-Object time -Descending)){$n=$nodeItems|Where-Object {$_.id -eq $h.node -and $_.enabled}|Select-Object -First 1;if(-not $n -or $seen.ContainsKey($h.node)){continue};$row=$h.result.rows|Where-Object id -eq $t.id|Select-Object -First 1;if($row -or $h.group -eq $t.group){$seen[$h.node]=$true};if($row -and $row.ok){$candidates+=@{node=$h.node;time=$h.time;seconds=$row.seconds;direct=($h.node -eq 'direct')}}}
    $preferred=$candidates|Sort-Object @{e='direct';Descending=$true},@{e='time';Descending=$true},seconds|Select-Object -First 1
    if($preferred){$result[$t.id]=$preferred.node}
  }
  return $result
}
function Test-RouteContext($context,$network,$sourceHash,$rulesHash,$targetsHash){
  return [bool]($context.active -and $network -ne 'unknown' -and $context.network -eq $network -and $context.source -eq $sourceHash -and $context.rules -eq $rulesHash -and $context.targets -eq $targetsHash)
}
