param([string]$SnapshotPath='',[switch]$SmokeTest)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::SetHighDpiMode([Windows.Forms.HighDpiMode]::SystemAware)|Out-Null
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'lol-data.ps1')
$pwsh=Join-Path $PSHOME 'pwsh.exe';$worker=Join-Path $PSScriptRoot 'lol-worker.ps1'
$script:guide=@{job=$null;queue=[Collections.Generic.Queue[object]]::new();session=$null;report=$null;sampling=$false;closing=$false;lastPoll=[datetime]::MinValue}
$f=[Windows.Forms.Form]::new();$f.AutoScaleMode='None';$f.Text='LOL 连接诊断助手';$f.ClientSize=[Drawing.Size]::new(1000,790);$f.StartPosition='CenterScreen';$f.Font=[Drawing.Font]::new('Microsoft YaHei UI',10);$f.BackColor=[Drawing.ColorTranslator]::FromHtml('#F4F6FA')
function L($parent,$text,$x,$y,$w,$h,$size=10,$bold=$false){$c=[Windows.Forms.Label]::new();$c.Text=$text;$c.SetBounds($x,$y,$w,$h);$c.Font=[Drawing.Font]::new('Microsoft YaHei UI',$size,$(if($bold){[Drawing.FontStyle]::Bold}else{[Drawing.FontStyle]::Regular}));$parent.Controls.Add($c);return $c}
function B($parent,$text,$x,$y,$w,$primary=$false){$b=[Windows.Forms.Button]::new();$b.Text=$text;$b.SetBounds($x,$y,$w,40);$b.FlatStyle='Flat';$b.BackColor=$(if($primary){[Drawing.ColorTranslator]::FromHtml('#176B57')}else{[Drawing.Color]::White});if($primary){$b.ForeColor=[Drawing.Color]::White};$parent.Controls.Add($b);return $b}
function Note($text,$title='说明'){[void][Windows.Forms.MessageBox]::Show($f,$text,$title)}
$null=L $f 'LOL 连接诊断助手' 24 16 700 43 22 $true
$null=L $f '延迟看起来正常，却进不了游戏？先记录这次启动，看看卡在哪一步。' 26 64 940 28 10
$tabs=[Windows.Forms.TabControl]::new();$tabs.SetBounds(20,106,960,622);$tabs.Anchor='Top,Bottom,Left,Right';$f.Controls.Add($tabs)
$welcomePage=[Windows.Forms.TabPage]::new('开始使用');$watch=[Windows.Forms.TabPage]::new('正在观察');$result=[Windows.Forms.TabPage]::new('诊断结果');$evidence=[Windows.Forms.TabPage]::new('服务明细（高级）');$tabs.TabPages.AddRange(@($welcomePage,$watch,$result,$evidence))
$null=L $welcomePage '不需要代理节点，也可以先诊断' 24 24 880 38 17 $true
$null=L $welcomePage "这个工具会记录 LOL 启动时的连接和错误，帮助你了解卡住的位置。`n它不会提供加速线路，也不能保证修复所有问题。第一次使用不用懂 IP 或代理规则。" 24 72 870 65
$null=L $welcomePage "1  点击下面的「开始诊断」。`n2  像平时一样打开 WeGame / LOL，正常登录或进入练习模式。`n3  卡住时选一个位置并点「卡在这里」，然后查看结果。" 24 151 880 106 12
$null=L $welcomePage '玩的区服（不清楚可以不填）' 24 273 300 25
$region=[Windows.Forms.TextBox]::new();$region.SetBounds(24,306,350,30);$region.PlaceholderText='例如：国服某区，或暂不清楚';$welcomePage.Controls.Add($region)
$null=L $welcomePage '游戏模式' 400 273 250 25
$modeBox=[Windows.Forms.ComboBox]::new();$modeBox.SetBounds(400,306,220,30);$modeBox.DropDownStyle='DropDownList';[void]$modeBox.Items.AddRange(@('LOL','云顶之弈','暂不清楚'));$modeBox.SelectedIndex=0;$welcomePage.Controls.Add($modeBox)
$start=B $welcomePage '开始诊断（不改网络）' 24 365 290 $true;$last=B $welcomePage '查看上次结果' 332 365 210;$advanced=B $welcomePage '使用我自己的节点' 560 365 260
$null=L $welcomePage "想省去找节点和配置的过程？购买成熟的游戏加速器通常更省事。`n本工具适合排查问题，或用自己已有/自行找到的节点转发指定游戏连接。`n作者不提供节点；缩小转发范围不能保证节点可信。" 24 435 890 94 10
$what=B $welcomePage '什么是节点？需要我准备吗？' 24 540 350
$null=L $watch '现在请正常打开游戏' 24 20 880 35 17 $true
$null=L $watch "保持这个窗口打开，照常使用 WeGame / LOL。没有节点也能记录。`n工具不会替你登录、改网络或操作游戏；最多观察 10 分钟，可随时结束。" 24 70 880 65
$watchStatus=L $watch '尚未开始。先在「开始使用」点击开始诊断。' 24 150 880 45 12 $true
$null=L $watch '你目前进行到哪一步？点击对应位置，再标记状态：' 24 216 880 30
$stageBox=[Windows.Forms.ComboBox]::new();$stageBox.SetBounds(24,263,430,32);$stageBox.DropDownStyle='DropDownList';[void]$stageBox.Items.AddRange(@('打开 WeGame / 登录','游戏大厅 / 房间','进入游戏 / 加载画面','已经进入实际对局'));$stageBox.SelectedIndex=0;$watch.Controls.Add($stageBox)
$reached=B $watch '已到达这一步' 24 315 220;$stuck=B $watch '卡在这里' 260 315 220;$stop=B $watch '结束诊断，查看结果' 498 315 330 $true
$folder=B $watch '找不到游戏？选择游戏文件夹' 24 383 390
$null=L $watch "提示：不必等游戏成功。卡在登录或加载时结束诊断，同样可以得到部分结果。`n你标记的位置是重要线索；若日志证据不足，结果页会明确说明。" 24 454 880 83
$summary=L $result '还没有诊断结果' 24 16 895 78 14 $true
$reportBox=[Windows.Forms.RichTextBox]::new();$reportBox.SetBounds(24,100,895,334);$reportBox.ReadOnly=$true;$reportBox.BackColor=[Drawing.Color]::White;$reportBox.BorderStyle='FixedSingle';$result.Controls.Add($reportBox)
$questionTexts=@(
 "大厅与会话：大厅、房间、授权、聊天等多个服务。`n聊天失败不一定影响对局。收到未登录请求的响应，不代表账号登录成功。",
 "启动配置：启动时读取的配置，可能与加载转圈有关。`n测试检查连接、证书和完整下载。它不是所有补丁和资源检查，客户端也可能使用缓存。",
 "对局连接：游戏实时数据，主要关注 UDP、丢包和延迟。`n声明支持 UDP、握手接受、真正能玩是不同等级。没进入对局就明确标未验证。"
)
foreach($i in 0..2){$b=B $result (@('大厅与会话  ?','启动配置  ?','对局连接  ?')[$i]) (24+$i*300) 445 282;$b.Tag=$i;$b.Add_Click({param($sender,$args) $groupCode=@('lobby','config','match')[[int]$sender.Tag];$known=@($script:guide.report.targets|Where-Object group -eq $groupCode);$confirmedCount=@($known|Where-Object confirmed).Count;Note ($questionTexts[[int]$sender.Tag]+"`n本次此组 $($known.Count) 项；已确认 $confirmedCount 项，待确认 $($known.Count-$confirmedCount) 项。未知用途另列在服务明细。"+"`n`n三个分组表示用途，不是三个固定 IP。每组可展开为多个服务。")})}
$details=B $result '查看目标与证据' 24 501 205;$export=B $result '导出脱敏摘要' 246 501 195;$again=B $result '再诊断一次' 458 501 195;$useNodes=B $result '使用自己的节点' 670 501 245
$null=L $result '不必继续配置：你可以只查看结果后退出。更省事的线路方案通常是成熟的游戏加速器。' 24 552 895 34 9
$grid=[Windows.Forms.DataGridView]::new();$grid.SetBounds(16,60,915,365);$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.RowHeadersVisible=$false;$grid.AutoSizeColumnsMode='DisplayedCells';$grid.SelectionMode='FullRowSelect';$grid.MultiSelect=$false;$evidence.Controls.Add($grid)
$null=L $evidence '这里是 LOL 的目的地，不是代理节点。只确认你理解的服务；不确定的保留「待确认」。' 16 16 915 32
$confirm=B $evidence '保存勾选的目标' 16 447 240;$probeCurrent=B $evidence '测试当前网络（无需节点）' 275 447 310;$viewRaw=B $evidence '查看脱敏证据和实际路径' 605 447 326
$null=L $evidence "保存目标只更新待用规则，不会自动切换网络。分组可手动修改。`n当前网络可能经过你已有的 VPN / TUN；不能把它直接称为直连。IP、端口等不懂可以先跳过。" 16 507 915 68 10
$status=L $f '准备就绪。先诊断，再决定是否需要自己的线路。' 24 740 948 32 10
$script:controls=@($start,$last,$advanced,$reached,$stuck,$stop,$folder,$confirm,$probeCurrent,$export,$again,$useNodes)
function Advanced-Window {Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+(Join-Path $PSScriptRoot 'lol-route-lab.ps1')+'"')) -WindowStyle Hidden}
function Queue-Guide($req){$script:guide.queue.Enqueue($req);Start-GuideJob}
function Start-GuideJob {
  if($script:guide.job -or -not $script:guide.queue.Count){return}
  $req=$script:guide.queue.Dequeue();$id=[guid]::NewGuid().ToString('N');$inputFile=Join-Path $labDir ('guide-'+$id+'-in.json');$output=Join-Path $labDir ('guide-'+$id+'-out.json')
  [IO.File]::WriteAllText($inputFile,($req|ConvertTo-Json -Depth 20))
  $proc=Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile','-File',('"'+$worker+'"'),'-RequestPath',('"'+$inputFile+'"'),'-ResultPath',('"'+$output+'"')) -WindowStyle Hidden -PassThru -RedirectStandardError ($output+'.err')
  $script:guide.job=@{process=$proc;input=$inputFile;output=$output;action=$req.action}
  $status.Text=switch($req.action){'session-sample'{'正在观察本次游戏连接…'}'session-probe'{'正在测试已确认的服务，可能需要几十秒…'}'session-stop'{'正在整理诊断结果…'}default{'正在处理…'}}
}
function New-GuideSession {
  if($script:guide.sampling -or $script:guide.job){Note '当前诊断仍在进行，请先结束本次诊断。';return}
  $regionValue=if($region.Text.Trim()){$region.Text.Trim()}else{'暂不清楚'}
  Queue-Guide @{action='session-start';region=$regionValue;mode=$modeBox.Text};$tabs.SelectedTab=$watch
}
function Update-Guide($data){
  if(-not $data.session){return};$script:guide.session=$data.session;$script:guide.report=$data.report
  $s=$data.session;$r=$data.report
  $summary.Text=$r.summary
  $chunks=@('本次卡住位置', $r.stage, '', '已经发现的异常')
  if($r.findings.Count){foreach($x in $r.findings){$chunks+=('• '+$x.text+'  ['+$x.time+']')}}else{$chunks+='还没有足够证据确定具体异常。'}
  $chunks+=@('','已观察到的进展');$chunks+=if($r.passed.Count){@($r.passed|ForEach-Object {'• '+$_})}else{@('尚未观察到可确认的成功阶段。')}
  $chunks+=@('','可能因素（尚未证实）');$chunks+=if($r.possible.Count){@($r.possible|ForEach-Object {'• '+$_})}else{@('证据不足，暂不猜测故障原因。')}
  $chunks+=@('','未检查 / 诊断限制');$chunks+=@($r.unchecked|ForEach-Object {'• '+$_});$chunks+=@('','下一步');$chunks+=@($r.next_actions|ForEach-Object {'• '+$_})
  $reportBox.Text=$chunks -join "`r`n"
  $elapsed=[int]((Get-Date)-[datetime]$s.started_at).TotalSeconds
  $watchStatus.Text="已记录 $($s.observations.Count) 条证据 · $elapsed 秒`n$(if($s.status -eq 'observing'){'可以标记位置，或随时结束查看结果。'}else{'观察已结束，可以查看诊断结果。'})"
  if($s.status -ne 'observing'){$script:guide.sampling=$false}
}
function Fill-Targets {
  $grid.Columns.Clear();$grid.Rows.Clear()
  $check=[Windows.Forms.DataGridViewCheckBoxColumn]::new();$check.Name='confirmed';$check.HeaderText='确认';[void]$grid.Columns.Add($check)
  foreach($pair in @(@('label','用途'),@('host','目标地址'),@('port','端口'))){[void]$grid.Columns.Add($pair[0],$pair[1]);$grid.Columns[$pair[0]].ReadOnly=$true}
  $groupsColumn=[Windows.Forms.DataGridViewComboBoxColumn]::new();$groupsColumn.Name='group';$groupsColumn.HeaderText='所属组';[void]$groupsColumn.Items.AddRange(@('待确认','大厅与会话','启动配置','对局连接'));[void]$grid.Columns.Add($groupsColumn)
  $networkColumn=[Windows.Forms.DataGridViewComboBoxColumn]::new();$networkColumn.Name='network';$networkColumn.HeaderText='传输方式';[void]$networkColumn.Items.AddRange(@('UNKNOWN','TCP','UDP'));[void]$grid.Columns.Add($networkColumn)
  [void]$grid.Columns.Add('confidence','依据');$grid.Columns['confidence'].ReadOnly=$true
  foreach($t in $script:guide.report.targets){$groupText=switch($t.group){'lobby'{'大厅与会话'}'config'{'启动配置'}'match'{'对局连接'}default{'待确认'}};$index=$grid.Rows.Add([object[]]@([bool]$t.confirmed,$t.label,$t.host,$t.port,$groupText,$t.network,$(if($t.confidence -eq 'template_match'){'匹配已知模板，仍需确认'}else{'本次观察，用途待确认'})));$grid.Rows[$index].Tag=$t}
}
function Mark-Stage($kind){if(-not $script:guide.session -or -not $script:guide.sampling){Note '请先开始一次诊断。';return};$stage=@('launcher','lobby','loading','match')[$stageBox.SelectedIndex];Queue-Guide @{action='session-mark';id=$script:guide.session.id;kind=$kind;stage=$stage}}
$start.Add_Click({New-GuideSession});$again.Add_Click({New-GuideSession});$advanced.Add_Click({Advanced-Window});$useNodes.Add_Click({Advanced-Window})
$what.Add_Click({Note "节点可以理解为你自己准备的网络中转站。诊断不需要它。`n`n只有想尝试另一条线路时，才需要你自己提供中转地址和端口。不会找、不想维护节点，可以考虑成熟游戏加速器。`n`n本工具不提供节点，不承诺免费节点安全。仅转发指定游戏连接可缩小范围，但不能消除这些连接的风险。"})
$reached.Add_Click({Mark-Stage 'reached'});$stuck.Add_Click({Mark-Stage 'stuck'})
$stop.Add_Click({if($script:guide.session){$script:guide.sampling=$false;Queue-Guide @{action='session-stop';id=$script:guide.session.id}}})
$last.Add_Click({$lastRecord=Read-Data 'last-session.json' @{};if($lastRecord.id){Queue-Guide @{action='session-view';id=$lastRecord.id};$tabs.SelectedTab=$result}else{Note '还没有诊断记录，先开始一次即可。'}})
$folder.Add_Click({$d=[Windows.Forms.FolderBrowserDialog]::new();$d.Description='选择 LOL 安装文件夹，或包含游戏日志的文件夹';if($d.ShowDialog($f) -eq 'OK'){Queue-Guide @{action='diagnostic-folder';path=$d.SelectedPath}};$d.Dispose()})
$details.Add_Click({Fill-Targets;$tabs.SelectedTab=$evidence})
$tabs.Add_SelectedIndexChanged({if($tabs.SelectedTab -eq $evidence -and $script:guide.report){Fill-Targets}})
$confirm.Add_Click({
  if(-not $script:guide.session){Note '先完成一次诊断。';return};[void]$grid.EndEdit();$items=@()
  foreach($row in $grid.Rows){if($row.Cells['confirmed'].Value){$groupCode=switch([string]$row.Cells['group'].Value){'大厅与会话'{'lobby'}'启动配置'{'config'}'对局连接'{'match'}default{'unknown'}};$items+=@{id=$row.Tag.id;group=$groupCode;network=[string]$row.Cells['network'].Value}}}
  if(-not $items.Count){Note '没有勾选目标。不确定的服务可以先保留待确认。';return}
  Queue-Guide @{action='session-confirm';id=$script:guide.session.id;targets=$items}
})
$probeCurrent.Add_Click({if($script:guide.session){Queue-Guide @{action='session-probe';id=$script:guide.session.id}}})
$export.Add_Click({if($script:guide.session){Queue-Guide @{action='session-export';id=$script:guide.session.id}}})
$viewRaw.Add_Click({
  if(-not $script:guide.session){return};$w=[Windows.Forms.Form]::new();$w.Text='脱敏证据与实际路径（高级）';$w.Size=[Drawing.Size]::new(1000,700);$w.StartPosition='CenterParent'
  $box=[Windows.Forms.TextBox]::new();$box.Multiline=$true;$box.ReadOnly=$true;$box.ScrollBars='Both';$box.Dock='Fill';$w.Controls.Add($box)
  $lines=@();foreach($o in $script:guide.session.observations){$lines+="$($o.observed_at) | $($o.evidence_kind) | $($o.host)$($o.ip):$($o.port) | $($o.transport) | $($o.signal)"};foreach($r in $script:guide.report.routes){$lines+="实际路径：$($r.target) | 预期：$($r.expected) | 观察代理链：$($r.observed_chain -join ' → ') | 命中规则：$($r.observed_rule) | $($r.state) | $($r.reason)"};$box.Text=$lines -join "`r`n";[void]$w.ShowDialog($f);$w.Dispose()
})
$timer=[Windows.Forms.Timer]::new();$timer.Interval=250
$timer.Add_Tick({
  if($script:guide.job -and $script:guide.job.process.HasExited){
    $job=$script:guide.job;$script:guide.job=$null
    try{
      if(-not (Test-Path $job.output)){throw '后台未正常返回。请重试；已有诊断记录仍保存在本机。'}
      $r=Get-Content $job.output -Raw|ConvertFrom-Json;if(-not $r.ok){throw $r.error}
      Update-Guide $r.data
      if($job.action -eq 'session-start'){
        $script:guide.sampling=-not $script:guide.closing;$script:guide.lastPoll=[datetime]::MinValue
        if($script:guide.closing){Queue-Guide @{action='session-stop';id=$script:guide.session.id}}
      }
      if($job.action -in @('session-stop','session-view','session-probe')){$tabs.SelectedTab=$result}
      if($job.action -eq 'session-confirm'){Fill-Targets;$status.Text='目标已确认；可测试当前网络。保存本身不会修改转发。'}
      elseif($job.action -eq 'session-export'){$save=[Windows.Forms.SaveFileDialog]::new();$save.Filter='诊断摘要 (*.json)|*.json';$save.FileName='LOL诊断摘要.json';if($save.ShowDialog($f) -eq 'OK'){Copy-Item -LiteralPath $r.data.export_path -Destination $save.FileName -Force;$status.Text='已保存脱敏摘要。'};$save.Dispose()}
      else{$status.Text='记录已更新。没有节点也可以查看诊断结果。'}
      if($job.action -eq 'session-sample' -and -not $script:guide.sampling){$tabs.SelectedTab=$result}
    }catch{$status.Text='未完成：'+$_.Exception.Message;if($job.action -eq 'session-start'){$script:guide.sampling=$false}}
    finally{if(Test-Path $job.input){Remove-Item -LiteralPath $job.input}}
  }
  if(-not $script:guide.closing -and -not $script:guide.job -and -not $script:guide.queue.Count -and $script:guide.sampling -and ((Get-Date)-$script:guide.lastPoll).TotalSeconds -ge 2){$script:guide.lastPoll=Get-Date;Queue-Guide @{action='session-sample';id=$script:guide.session.id}}
  Start-GuideJob
  $start.Enabled=-not ($script:guide.job -or $script:guide.sampling);$again.Enabled=$start.Enabled
  if($script:guide.closing -and -not $script:guide.job -and -not $script:guide.queue.Count){$script:guide.closing=$false;$f.Close()}
})
$f.Add_FormClosing({param($sender,$e)
  if($script:guide.sampling -or $script:guide.job -or $script:guide.queue.Count){$e.Cancel=$true;if(-not $script:guide.closing){$script:guide.closing=$true;$script:guide.sampling=$false;if($script:guide.session){Queue-Guide @{action='session-stop';id=$script:guide.session.id}};$status.Text='正在保存诊断，完成后自动关闭。'}}
})
$scale=[single]($f.DeviceDpi/96.0);if($scale -ne 1){$f.Scale([Drawing.SizeF]::new($scale,$scale))};$timer.Start()
function Capture-Guide($path){$bitmap=[Drawing.Bitmap]::new($f.Width,$f.Height);$f.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$f.Width,$f.Height));$bitmap.Save($path);$bitmap.Dispose()}
if($SnapshotPath){
  $f.Opacity=0;$f.Show();[Windows.Forms.Application]::DoEvents();Capture-Guide $SnapshotPath
  if($SmokeTest){
    $start.PerformClick();$deadline=(Get-Date).AddSeconds(55)
    while(-not $script:guide.session -and (Get-Date) -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
    if(-not $script:guide.session){throw 'GUIDE smoke: session did not start'}
    $stageBox.SelectedIndex=2;$stuck.PerformClick();$stop.PerformClick()
    while(($script:guide.job -or $script:guide.queue.Count) -and (Get-Date) -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
    if($script:guide.session.status -ne 'finished' -or $tabs.SelectedTab -ne $result){throw 'GUIDE smoke: result page not reached'}
    Capture-Guide ($SnapshotPath+'.result.png');Fill-Targets;$tabs.SelectedTab=$evidence;[Windows.Forms.Application]::DoEvents();Capture-Guide ($SnapshotPath+'.targets.png')
    Write-Output 'PASS: beginner start, stuck marker, stop, and result page without nodes'
  }
  $timer.Stop();$f.Dispose()
}else{[void]$f.ShowDialog();$timer.Dispose();$f.Dispose()}
