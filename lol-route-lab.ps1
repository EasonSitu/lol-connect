param([string]$SnapshotPath='',[switch]$SmokeTest)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::SetHighDpiMode([Windows.Forms.HighDpiMode]::SystemAware)|Out-Null
[Windows.Forms.Application]::EnableVisualStyles()
$script:job=$null;$script:initialized=$false;$script:overrides=@{};$script:pendingApply=$null
$script:catalog=@();$script:lastState=$null
. (Join-Path $PSScriptRoot 'lol-data.ps1')
$root=$baseDir
$dataDir=$labDir
[void](New-Item -ItemType Directory $dataDir -Force)
$presetPath=Join-Path $dataDir 'presets.json'
$script:presets=@{}
if(Test-Path $presetPath){try{$script:presets=Get-Content $presetPath -Raw|ConvertFrom-Json -AsHashtable}catch{}}
$pwsh=Join-Path $PSHOME 'pwsh.exe'
$backend=Join-Path $PSScriptRoot 'lol-worker.ps1'
$form=[Windows.Forms.Form]::new()
$form.AutoScaleMode='None'
$form.Text='LOL 线路试验台'
$form.ClientSize=[Drawing.Size]::new(1040,850)
$form.MinimumSize=[Drawing.Size]::new(1056,889)
$form.StartPosition='CenterScreen'
$form.BackColor=[Drawing.ColorTranslator]::FromHtml('#F3F5F7')
$form.Font=[Drawing.Font]::new('Microsoft YaHei UI',10)
function Label($parent,$text,$x,$y,$w,$h,$size=10,$bold=$false){
  $c=[Windows.Forms.Label]::new();$c.Text=$text;$c.SetBounds($x,$y,$w,$h)
  $style=if($bold){[Drawing.FontStyle]::Bold}else{[Drawing.FontStyle]::Regular}
  $c.Font=[Drawing.Font]::new('Microsoft YaHei UI',$size,$style)
  $c.ForeColor=[Drawing.ColorTranslator]::FromHtml('#243247');$parent.Controls.Add($c);return $c
}
function Button($text,$x,$y,$w,$h){
  $b=[Windows.Forms.Button]::new();$b.Text=$text;$b.SetBounds($x,$y,$w,$h)
  $b.FlatStyle='Flat';$b.BackColor=[Drawing.Color]::White;$b.FlatAppearance.BorderColor=[Drawing.ColorTranslator]::FromHtml('#CBD3DD')
  return $b
}
$null=Label $form 'LOL 线路试验台' 20 18 600 38 21 $true
$null=Label $form 'LOL 专用网络诊断与分流 · 用户自带节点 · 三组服务，不是三个固定 IP' 22 63 990 25 10
$script:status=Label $form '正在读取 Clash 状态……' 22 96 996 28 10 $true
$null=Label $form '服务组与当前路径' 25 133 390 22 9 $true
$null=Label $form '准备尝试的选择（点击应用前不生效）' 443 133 560 22 9 $true
$script:combos=@();$script:resultLabels=@();$script:currentLabels=@();$script:testButtons=@()
$keys=@('lobby','config','match')
$titles=@('1  大厅与账号会话','2  进入游戏前的配置','3  对局 UDP 数据')
$descriptions=@("登录、房间、聊天、平台会话`n实际服务以本次诊断识别的目标为准","启动时读取的配置`n完整下载不等于游戏一定能进入","对局地址和端口会变化`n按已识别的游戏目标 / 游戏进程分流")
for($i=0;$i -lt 3;$i++){
  $panel=[Windows.Forms.Panel]::new();$panel.SetBounds(20,(160+$i*123),1000,115);$panel.BackColor=[Drawing.Color]::White;$panel.BorderStyle='FixedSingle';$form.Controls.Add($panel)
  $null=Label $panel $titles[$i] 16 10 380 27 12 $true
  $helpGroup=Button '?' 366 8 35 30;$helpGroup.Tag=$i;$panel.Controls.Add($helpGroup)
  $helpGroup.Add_Click({param($sender,$args) Show-GroupHelp ([int]$sender.Tag)})
  $null=Label $panel $descriptions[$i] 18 41 375 43 9
  $c=Label $panel '当前：读取中' 18 86 395 21 9;$c.ForeColor=[Drawing.ColorTranslator]::FromHtml('#526277');$script:currentLabels+=$c
  $combo=[Windows.Forms.ComboBox]::new();$combo.SetBounds(420,15,300,30);$combo.DropDownStyle='DropDownList';$combo.DropDownWidth=700;$combo.DisplayMember='display';$combo.Tag=$i;$panel.Controls.Add($combo);$script:combos+=$combo
  $b=Button $(if($i -eq 2){'检查 UDP 能力'}else{'测试这一组'}) 735 12 245 36;$b.Tag=$i;$panel.Controls.Add($b);$script:testButtons+=$b
  $r=Label $panel '未测试此选择' 420 60 555 43 9;$script:resultLabels+=$r
  $combo.Add_SelectedIndexChanged({param($sender,$eventArgs) $index=[int]$sender.Tag;if($sender.SelectedItem){$script:resultLabels[$index].Text=$sender.SelectedItem.summary};$script:resultLabels[$index].ForeColor=[Drawing.ColorTranslator]::FromHtml('#526277')})
  $b.Add_Click({param($sender,$eventArgs) $index=[int]$sender.Tag;$item=$script:combos[$index].SelectedItem;if($item){Start-JobRequest @{action='test';group=@('lobby','config','match')[$index];node=$item.id} $index}})
}
$null=Label $form '方案名称' 22 546 95 25 10
$preset=[Windows.Forms.ComboBox]::new();$preset.SetBounds(112,542,302,30);$preset.DropDownStyle='DropDown';$form.Controls.Add($preset)
foreach($name in $script:presets.Keys){[void]$preset.Items.Add($name)}
$save=Button '保存选择' 429 540 110 35;$form.Controls.Add($save)
$load=Button '载入方案' 550 540 110 35;$form.Controls.Add($load)
$refresh=Button '刷新当前状态' 805 540 215 35;$form.Controls.Add($refresh)
$single=Button '单独分配' 670 540 125 35;$form.Controls.Add($single);$single.Add_Click({Edit-Overrides})
$allow=[Windows.Forms.CheckBox]::new();$allow.SetBounds(23,591,490,27);$allow.Text='允许运行中切换（可能断线，通常保持不勾选）';$form.Controls.Add($allow)
$apply=Button '应用这套组合' 595 584 185 42;$apply.BackColor=[Drawing.ColorTranslator]::FromHtml('#176B57');$apply.ForeColor=[Drawing.Color]::White;$form.Controls.Add($apply)
$restore=Button '恢复接管前配置' 795 584 225 42;$form.Controls.Add($restore)
$script:log=[Windows.Forms.RichTextBox]::new();$script:log.SetBounds(20,641,1000,103);$script:log.ReadOnly=$true;$script:log.BackColor=[Drawing.ColorTranslator]::FromHtml('#142338');$script:log.ForeColor=[Drawing.ColorTranslator]::FromHtml('#E8EDF5');$script:log.Font=[Drawing.Font]::new('Microsoft YaHei UI',9);$form.Controls.Add($script:log)
$null=Label $form '共享接口按服务分组，不代表固定 3 个 IP。公开节点会变化；每次只改一组，便于比较。' 22 754 995 25 9
$script:interactive=@($save,$load,$single,$refresh,$apply,$restore,$allow,$preset)+$script:combos+$script:testButtons
function Log($text){$script:log.AppendText(('['+(Get-Date -Format 'HH:mm:ss')+'] '+$text+"`r`n"));$script:log.SelectionStart=$script:log.Text.Length;$script:log.ScrollToCaret()}
function Choices {
  return @{lobby=$script:combos[0].SelectedItem.id;config=$script:combos[1].SelectedItem.id;match=$script:combos[2].SelectedItem.id}
}
function Set-Choices($values){
  for($i=0;$i -lt 3;$i++){
    $value=$values.(@('lobby','config','match')[$i]);$combo=$script:combos[$i]
    for($j=0;$j -lt $combo.Items.Count;$j++){if($combo.Items[$j].id -eq $value){$combo.SelectedIndex=$j;break}}
  }
}
function Show-State($s,$reset=$false){
  $draft=if($script:initialized -and -not $reset){Choices}else{$s.selection}
  $script:lastState=$s;$script:catalog=@($s.nodes)
  if(-not $script:initialized -and $s.active -and $s.applied.overrides){foreach($prop in $s.applied.overrides.PSObject.Properties){$script:overrides[$prop.Name]=$prop.Value}}
  for($i=0;$i -lt 3;$i++){
    $combo=$script:combos[$i];$combo.Items.Clear();$g=@('lobby','config','match')[$i];$items=@()
    foreach($n in $script:catalog|Where-Object enabled){
      if($i -eq 2 -and -not $n.udp){continue}
      $history=@($s.results|Where-Object {$_.node -eq $n.id -and $_.group -eq $g}|Sort-Object time)
      $last=$history|Select-Object -Last 1;$rank=2;$summary='未测试 / 地址或规则已变化'
      if($g -eq 'match'){$summary='声明支持 UDP；实际对局未验证'}
      elseif($last){
        $good=@($history|Where-Object {$_.result.passed -eq $true}).Count;$sec=($last.result.rows|Measure-Object seconds -Maximum).Maximum
        $stamp=([datetime]$last.time).ToLocalTime().ToString('MM-dd HH:mm');$stale=((Get-Date)-[datetime]$last.time).TotalMinutes -gt 30
        $rank=if($last.result.passed -eq $true){0}else{1};$summary="最近 $(if($last.result.passed){'通过'}else{'失败'}) · $good/$($history.Count) 次 · 最慢 $sec 秒 · $stamp$(if($stale){' 待复测'})"
      }
      $items+=[pscustomobject]@{id=$n.id;label=$n.label;display=($n.label+'  |  '+$summary);summary=$summary;rank=$rank}
    }
    foreach($n in $items|Sort-Object rank,label){[void]$combo.Items.Add($n)};if($combo.Items.Count){$combo.SelectedIndex=0}
  }
  Set-Choices $draft;$script:initialized=$true
  $script:presets=@{};foreach($p in $s.presets.PSObject.Properties){$script:presets[$p.Name]=$p.Value}
  $preset.Items.Clear();foreach($name in $script:presets.Keys){[void]$preset.Items.Add($name)}
  for($i=0;$i -lt 3;$i++){
    $id=$s.selection.(@('lobby','config','match')[$i]);$n=$script:catalog|Where-Object id -eq $id|Select-Object -First 1
    $script:currentLabels[$i].Text=if(-not $s.online){'当前：无法读取 Clash，路径未确认'}elseif(-not $s.active){'当前：沿用已有网络，未由本工具接管'}else{'当前组默认：'+$n.label+'（单接口覆盖见预览）'}
  }
  $owner=if($s.active){'正在管理三组路径'}else{'尚未应用界面组合'}
  $running=if($s.gameRunning){'游戏运行中'}else{'未检测到对局进程'}
  $script:status.Text="Clash：$(if($s.online){$s.mode}else{'未连接'}) / TUN=$($s.tun)    $owner    $running"
  if($s.message){Log $s.message}
}
function Start-JobRequest($payload,$index=-1){
  if($script:job){return}
  $id=[guid]::NewGuid().ToString('N');$jobInput=Join-Path $dataDir ($id+'-request.json');$output=Join-Path $dataDir ($id+'-result.json')
  $payload|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $jobInput -Encoding utf8
  $processArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$backend+'"'),'-RequestPath',('"'+$jobInput+'"'),'-ResultPath',('"'+$output+'"'))
  $process=Start-Process -FilePath $pwsh -ArgumentList $processArgs -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $dataDir ($id+'-error.log')) -RedirectStandardOutput (Join-Path $dataDir ($id+'-out.log'))
  $script:job=@{process=$process;output=$output;input=$jobInput;action=$payload.action;index=$index;started=Get-Date;error=(Join-Path $dataDir ($id+'-error.log'))}
  foreach($c in $script:interactive){$c.Enabled=$false}
  if($payload.action -in @('batch','discover')){$cancel.Enabled=$true}
  if($index -ge 0){$script:resultLabels[$index].Text='测试中，请稍候……'}
  $message=switch($payload.action){'state'{'读取当前配置'}'test'{'独立测试所选路径'}'apply'{'应用并验证组合'}'restore'{'恢复界面接管前的配置'}'batch'{'开始批量测试；可取消，当前正在运行的一组完成后停止'}'discover'{'识别 LOL 连接与域名，未知用途保留待确认'}default{'正在保存或验证…'}}
  Log $message
}
$timer=[Windows.Forms.Timer]::new();$timer.Interval=200
$timer.Add_Tick({
  if($script:job -and $script:job.action -eq 'batch' -and (Test-Path ($script:job.output+'.progress'))){try{$p=Get-Content ($script:job.output+'.progress') -Raw|ConvertFrom-Json;$batch.Text="测试 $($p.done)/$($p.total) · $($p.node)"}catch{}}
  if($script:job -and $script:job.action -eq 'discover' -and (Test-Path ($script:job.output+'.progress'))){try{$p=Get-Content ($script:job.output+'.progress') -Raw|ConvertFrom-Json;$discover.Text="发现 $($p.done) · $($p.remaining)s"}catch{}}
  if(-not $script:job -or -not $script:job.process.HasExited){return}
  $job=$script:job;$script:job=$null
  foreach($c in $script:interactive){$c.Enabled=$true}
  $cancel.Enabled=$false;$batch.Text='一键测试全部';$discover.Text='识别服务器'
  if(Test-Path $job.input){Remove-Item -LiteralPath $job.input}
  try{
    if(-not (Test-Path $job.output)){throw '后台未返回结果，请查看本地诊断记录。'}
    $r=Get-Content $job.output -Raw|ConvertFrom-Json
    if(-not $r.ok){throw $r.error}
    if($job.action -eq 'state'){Show-State $r.data;Log '已读取真实运行状态。'}
    elseif($job.action -eq 'test'){
      $text=if($null -eq $r.data.passed){'能力检查完成；UDP 对局尚未实测'}elseif($r.data.passed){'本次探测通过；仍需客户端验收'}else{'本次探测未全部通过'}
      $script:resultLabels[$job.index].Text=$text+'  '+(Get-Date -Format 'HH:mm:ss')
      $script:resultLabels[$job.index].ForeColor=if($r.data.passed){[Drawing.ColorTranslator]::FromHtml('#176B57')}else{[Drawing.ColorTranslator]::FromHtml('#9A4E14')}
      Log $text
      if($r.data.message){Log $r.data.message}
      foreach($row in $r.data.rows){Log "$($row.name)：通过=$($row.ok)，$($row.seconds) 秒；$($row.detail)"}
      if($job.index -ne 2){Start-JobRequest @{action='state'}}
    }elseif($job.action -eq 'route-preview'){
      if(Confirm-RoutePreview $r.data.assignments){Start-JobRequest $script:pendingApply}else{Log '未应用，当前网络保持不变。'}
    }elseif($job.action -eq 'route-suggest'){
      foreach($prop in $r.data.assignments.PSObject.Properties){$script:overrides[$prop.Name]=$prop.Value};Log $r.data.message;Edit-Overrides
    }elseif($job.action -eq 'discover'){Log $r.data.message;$script:lastState.observations=$r.data.observations;Show-Observations $r.data.observations}
    else{Log $r.data.message;if($r.data.state){Show-State $r.data.state ($job.action -in @('apply','restore'))}else{Start-JobRequest @{action='state'}}}
  }catch{
    Log ('未完成：'+$_.Exception.Message)
    if($job.index -ge 0){$script:resultLabels[$job.index].Text='测试未完成，见下方原因'}
  }
})
$timer.Start()
$refresh.Add_Click({Start-JobRequest @{action='state'}})
$apply.Add_Click({if($script:initialized){$script:pendingApply=@{action='apply';selection=(Choices);assignments=$script:overrides;allowDuringGame=$allow.Checked};Start-JobRequest @{action='route-preview';selection=(Choices);assignments=$script:overrides}}})
$restore.Add_Click({Start-JobRequest @{action='restore';allowDuringGame=$allow.Checked}})
$save.Add_Click({
  if(-not $script:initialized){return}
  $name=$preset.Text.Trim();if(-not $name){Log '先输入一个方案名称，例如“宁波前置＋对局直连”。';return}
  Start-JobRequest @{action='save-preset';name=$name;selection=(Choices);assignments=$script:overrides}
})
$load.Add_Click({$name=$preset.Text.Trim();if($script:presets.ContainsKey($name)){$entry=$script:presets[$name];$script:overrides=@{};if($entry.selection){Set-Choices $entry.selection;foreach($prop in $entry.overrides.PSObject.Properties){$script:overrides[$prop.Name]=$prop.Value}}else{Set-Choices $entry};Log "已载入草稿：$name；点击应用后生效。"}else{Log '未找到这个已保存方案。'}})
$form.Add_FormClosing({param($sender,$e) if($script:job){$e.Cancel=$true;Log '操作进行中，完成后可关闭窗口。'}})
. (Join-Path $PSScriptRoot 'lol-ui-tools.ps1')
$scale=[single]($form.DeviceDpi/96.0)
if($scale -ne 1){$form.Scale([Drawing.SizeF]::new($scale,$scale))}
Start-JobRequest @{action='state'}
if($SnapshotPath){
  $form.Opacity=0;$form.Show()
  $deadline=(Get-Date).AddSeconds(25)
  while($script:job -and (Get-Date) -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
  if($SmokeTest){
    if(-not $script:initialized){throw '界面未完成初始化'}
    $script:testButtons[2].PerformClick()
    $deadline=(Get-Date).AddSeconds(25)
    while($script:job -and (Get-Date) -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
    if($script:resultLabels[2].Text -notlike '能力检查完成*'){throw '界面测试按钮未完成预期操作'}
    Write-Output 'GUI smoke passed: startup state, test button, async result rendered.'
    foreach($view in @('nodes','targets','results')){
      $script:previewFile=$SnapshotPath+'.'+$view+'.png'
      $closeTimer=[Windows.Forms.Timer]::new();$closeTimer.Interval=700
      $closeTimer.Add_Tick({
        $f=[Windows.Forms.Application]::OpenForms|Where-Object {$_ -ne $form}|Select-Object -Last 1
        if($f){$b=[Drawing.Bitmap]::new($f.Width,$f.Height);$f.DrawToBitmap($b,[Drawing.Rectangle]::new(0,0,$f.Width,$f.Height));$b.Save($script:previewFile);$b.Dispose();$f.Close()}
      });$closeTimer.Start()
      switch($view){'nodes'{Manage-Nodes}'targets'{Manage-Targets}'results'{Show-Results}}
      $closeTimer.Stop();$closeTimer.Dispose();Write-Output "Rendered dialog: $view"
    }
  }
  $form.PerformLayout();$bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height);$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save($SnapshotPath);$bitmap.Dispose();$timer.Stop();$form.Dispose()
}else{[void]$form.ShowDialog();$timer.Dispose();$form.Dispose()}
