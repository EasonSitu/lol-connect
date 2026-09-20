function Core($method,$path,$data=$null){
  $pipe=[IO.Pipes.NamedPipeClientStream]::new('.',([string]$settings.pipe),[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
  try{
    $pipe.Connect($(if($script:coreConnectTimeout){[int]$script:coreConnectTimeout}else{2500}))
    $body=if($null -ne $data){$data|ConvertTo-Json -Depth 40 -Compress}else{''}
    $bb=[Text.Encoding]::UTF8.GetBytes($body)
    $header="$method $path HTTP/1.0`r`nHost: localhost`r`nContent-Type: application/json`r`nContent-Length: $($bb.Length)`r`n`r`n"
    $hb=[Text.Encoding]::ASCII.GetBytes($header)
    $pipe.Write($hb,0,$hb.Length)
    if($bb.Length){$pipe.Write($bb,0,$bb.Length)}
    $reader=[IO.StreamReader]::new($pipe)
    $task=$reader.ReadToEndAsync()
    if(-not $task.Wait(12000)){throw 'Clash 接口响应超时，请检查 Clash 是否运行。'}
    $parts=$task.Result -split "`r`n`r`n",2
    if($parts[0] -notmatch '^HTTP/\d\.\d 2\d\d'){throw "Clash 操作失败：$method $path"}
    if($parts.Count -gt 1 -and $parts[1].Trim()){return ($parts[1]|ConvertFrom-Json)}
  }finally{$pipe.Dispose()}
}
function Get-Group {
  $all=Core 'GET' '/proxies'
  return $all.proxies.PSObject.Properties[$group].Value
}
function Rule-Signature($rules){
  return ($rules|Select-Object type,payload,proxy,@{n='disabled';e={[bool]$_.extra.disabled}}|ConvertTo-Json -Depth 20 -Compress)
}
function Select-Node($name){
  Core 'PUT' ('/proxies/'+[uri]::EscapeDataString($group)) @{name=$name}
  if((Get-Group).now -ne $name){throw 'Clash 节点选择验证失败。'}
}
function Save-Runtime {
  $cfg=Core 'GET' '/configs'
  $mutable=@{}
  foreach($key in @('mode','tun','ipv6','log-level','interface-name','mixed-port','port','socks-port','redir-port','tproxy-port','allow-lan','bind-address')){
    $prop=$cfg.PSObject.Properties[$key]
    if($null -ne $prop){$mutable[$key]=$prop.Value}
  }
  $all=Core 'GET' '/proxies'
  $selections=@{}
  foreach($p in $all.proxies.PSObject.Properties){if($p.Value.type -eq 'Selector' -and $p.Name -ne $group){$selections[$p.Name]=$p.Value.now}}
  return @{mutable=$mutable;selections=$selections}
}
function Load-Payload($payload,$runtime){
  $payload=[regex]::Replace($payload,'(?m)^mode:.*$',('mode: '+$runtime.mutable.mode))
  Core 'PUT' '/configs?force=true' @{payload=$payload}
  Core 'PATCH' '/configs' $runtime.mutable
  $available=(Core 'GET' '/proxies').proxies
  foreach($name in $runtime.selections.Keys){
    if($available.PSObject.Properties[$name] -and $runtime.selections[$name] -in $available.PSObject.Properties[$name].Value.all){Core 'PUT' ('/proxies/'+[uri]::EscapeDataString($name)) @{name=$runtime.selections[$name]}}
  }
}
function Close-TargetConnections {
  $connections=Core 'GET' '/connections'
  $count=0
  foreach($c in $connections.connections){
    if($c.metadata.host -in $domains -and [string]$c.metadata.destinationPort -in @('8093','21019','28088','5223','2099')){
      try{Core 'DELETE' ('/connections/'+[uri]::EscapeDataString($c.id));$count++}catch{}
    }
  }
  Write-Host "已刷新 $count 条相关接口连接，其他连接不变。"
}
