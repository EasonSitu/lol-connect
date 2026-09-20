function Modal($title,$width=860,$height=580){
  $f=[Windows.Forms.Form]::new();$f.AutoScaleMode='None';$f.Text=$title;$f.ClientSize=[Drawing.Size]::new($width,$height);$f.StartPosition='CenterParent';$f.Font=[Drawing.Font]::new('Microsoft YaHei UI',10);return $f
}
function Show-Modal($f){$scale=[single]($f.DeviceDpi/96.0);if($scale -ne 1){$f.Scale([Drawing.SizeF]::new($scale,$scale))};return $f.ShowDialog($form)}
function Grid($parent,$y,$height){
  $g=[Windows.Forms.DataGridView]::new();$g.SetBounds(12,$y,($parent.ClientSize.Width-24),$height);$g.Anchor='Top,Bottom,Left,Right';$g.AutoSizeColumnsMode='DisplayedCells';$g.SelectionMode='FullRowSelect';$g.MultiSelect=$false;$g.AllowUserToAddRows=$false;$g.AllowUserToDeleteRows=$false;$g.ReadOnly=$true;$g.RowHeadersVisible=$false;$parent.Controls.Add($g);return $g
}
function Fill-Grid($grid,$rows,$fields){
  $grid.Columns.Clear();$grid.Rows.Clear()
  foreach($field in $fields){
    $options=switch($field){'group'{@('lobby','config','match')}'network'{@('TCP','UDP')}'probe'{@('http','config','tls','none')}'enabled'{@('True','False')}default{@()}}
    if(-not $grid.ReadOnly -and $options.Count){$column=[Windows.Forms.DataGridViewComboBoxColumn]::new();$column.Name=$field;$column.HeaderText=$field;foreach($o in $options){[void]$column.Items.Add($o)};[void]$grid.Columns.Add($column)}else{[void]$grid.Columns.Add($field,$field)}
  }
  foreach($r in $rows){$values=@();foreach($field in $fields){$v=$r.$field;$values+=[string]$v};$index=$grid.Rows.Add([object[]]$values);$grid.Rows[$index].Tag=$r}
  $headers=@{label='名称';type='协议';server='节点地址';port='端口';enabled='启用';udp='UDP 声明';host='目标域名';ip='目标 IP';group='分组';network='传输';probe='测试方式';url='公开测试 URL';expected='预期状态';evidence='证据来源';lastSeen='最近发现';process='进程'}
  foreach($column in $grid.Columns){if($headers.ContainsKey($column.Name)){$column.HeaderText=$headers[$column.Name]};if($column.Name -eq 'url'){$column.AutoSizeMode='None';$column.Width=260}}
}
function Edit-Fields($title,$fields,$values,$passwordField=''){
  $f=Modal $title 740 (80+$fields.Count*42);$boxes=@{};$y=12
  foreach($field in $fields){
    $null=Label $f $field 12 $y 180 25 9
    if($field -like '*true/false*' -or $field -eq '协议 http/socks5'){
      $box=[Windows.Forms.ComboBox]::new();$box.DropDownStyle='DropDownList'
      $options=if($field -eq '协议 http/socks5'){@('http','socks5')}else{@('true','false')};foreach($o in $options){[void]$box.Items.Add($o)};$box.SelectedIndex=0;$box.SelectedItem=([string]$values[$field]).ToLower()
    }else{$box=[Windows.Forms.TextBox]::new();$box.Text=[string]$values[$field];if($field -eq $passwordField){$box.UseSystemPasswordChar=$true}}
    $box.SetBounds(200,$y,525,28);$f.Controls.Add($box);$boxes[$field]=$box;$y+=42
  }
  $ok=Button '保存' 500 $y 100 32;$ok.DialogResult='OK';$f.Controls.Add($ok)
  $no=Button '取消' 615 $y 100 32;$no.DialogResult='Cancel';$f.Controls.Add($no);$f.AcceptButton=$ok;$f.CancelButton=$no
  $result=$null;if((Show-Modal $f) -eq 'OK'){$result=@{};foreach($field in $fields){$result[$field]=$boxes[$field].Text}}
  $f.Dispose();return $result
}
function Edit-Node($node){
  if($node -and $node.type -notin @('http','socks5')){Log 'Clash 引用和直连只读，请在 Clash 中管理引用。';return}
  $values=@{'名称'=$node.label;'协议 http/socks5'=$(if($node){$node.type}else{'http'});'地址/IP/域名'=$node.server;'端口'=$node.port;'启用 true/false'=$(if($node){[string]$node.enabled}else{'true'});'UDP 声明 true/false'=$(if($node){[string]$node.udp}else{'false'});'用户名（可空）'=$node.username;'密码（空保留）'='';'清空密码 true/false'='false';'备注'=$node.note}
  $r=Edit-Fields '手动节点 · 密码用 Windows 当前用户加密保存在本机' @('名称','协议 http/socks5','地址/IP/域名','端口','启用 true/false','UDP 声明 true/false','用户名（可空）','密码（空保留）','清空密码 true/false','备注') $values '密码（空保留）'
  if($r){
    $n=@{id=$node.id;label=$r['名称'];type=$r['协议 http/socks5'];server=$r['地址/IP/域名'];port=$r['端口'];enabled=($r['启用 true/false'] -eq 'true');udp=($r['UDP 声明 true/false'] -eq 'true');username=$r['用户名（可空）'];password=$r['密码（空保留）'];clearPassword=($r['清空密码 true/false'] -eq 'true');note=$r['备注']}
    Start-JobRequest @{action='save-node';node=$n}
  }
}
function Manage-Nodes {
  $f=Modal '节点管理 · 私人节点不随源码发布'
  $search=[Windows.Forms.TextBox]::new();$search.SetBounds(12,12,440,28);$f.Controls.Add($search);$null=Label $f '搜索名称 / 地址 / 协议' 465 15 350 24 9
  $grid=Grid $f 52 450
  $nodeRows=@($script:catalog)
  $refreshRows={Fill-Grid $grid @($nodeRows|Where-Object {($_.label+' '+$_.server+' '+$_.type) -like ('*'+$search.Text+'*')}) @('label','type','server','port','enabled','udp')}.GetNewClosure()
  & $refreshRows;$search.Add_TextChanged($refreshRows)
  $add=Button '添加节点' 12 520 120 34;$edit=Button '编辑选中' 145 520 120 34;$delete=Button '删除选中' 278 520 120 34;$f.Controls.AddRange(@($add,$edit,$delete))
  $f.Tag=$null
  $add.Add_Click({$f.Tag=@{action='add'};$f.Close()}.GetNewClosure())
  $edit.Add_Click({if($grid.SelectedRows.Count){$f.Tag=@{action='edit';node=$grid.SelectedRows[0].Tag};$f.Close()}}.GetNewClosure())
  $delete.Add_Click({if($grid.SelectedRows.Count){$f.Tag=@{action='delete';node=$grid.SelectedRows[0].Tag};$f.Close()}}.GetNewClosure())
  [void](Show-Modal $f);$choice=$f.Tag;$f.Dispose()
  if($choice.action -eq 'add'){Edit-Node $null}elseif($choice.action -eq 'edit'){Edit-Node $choice.node}elseif($choice.action -eq 'delete'){
    if([Windows.Forms.MessageBox]::Show($form,('删除 '+$choice.node.label+'？（本地上一次文件备份保留）'),'删除节点','YesNo') -eq 'Yes'){Start-JobRequest @{action='delete-node';id=$choice.node.id}}
  }
}
function Manage-Targets($prefill=$null){
  $f=Modal 'LOL 目标服务器 · 这是游戏目标，不是代理节点' 1100 600
  $null=Label $f 'host 支持域名或 IP；修改只改变识别/分流，不会强迫 LOL 连接其他服务器。保存后需重新应用。' 12 10 1060 32 9
  $grid=Grid $f 48 455;$grid.ReadOnly=$false;$grid.AllowUserToAddRows=$true;$grid.AllowUserToDeleteRows=$true
  $fields=@('id','label','group','host','port','network','probe','url','expected','enabled')
  Fill-Grid $grid @($script:lastState.targets) $fields
  if($prefill){
    $address=if($prefill.host){$prefill.host}else{$prefill.ip};$network=if($prefill.network -eq 'UDP'){'UDP'}else{'TCP'}
    $category=if($prefill.group -in @('config','lobby','match')){$prefill.group}elseif($network -eq 'UDP'){'match'}else{'lobby'}
    $probeType=if($network -eq 'UDP'){'none'}else{'tls'}
    $idx=$grid.Rows.Add([object[]]@(('manual-'+[guid]::NewGuid().ToString('N').Substring(0,6)),'新目标（请确认用途）',$category,$address,$prefill.port,$network,$probeType,'','','True'));$grid.CurrentCell=$grid.Rows[$idx].Cells['host']
  }
  $null=Label $f 'group: lobby/config/match；network: TCP/UDP；probe: http/config/tls/none；enabled: True/False。UDP 用 none。' 12 512 1060 24 9
  $saveTargets=Button '保存目标' 830 551 120 34;$reset=Button '恢复 hn10 模板' 620 551 190 34;$f.Controls.AddRange(@($saveTargets,$reset))
  $saveTargets.Add_Click({
    [void]$grid.EndEdit();$items=@();foreach($row in $grid.Rows){if($row.IsNewRow){continue};$t=@{};foreach($k in $fields){$t[$k]=[string]$row.Cells[$k].Value};$t.enabled=($t.enabled -eq 'true');$items+=$t};$f.Tag=@{action='save-targets';targets=$items};$f.Close()
  }.GetNewClosure())
  $reset.Add_Click({$f.Tag=@{action='reset-targets'};$f.Close()}.GetNewClosure())
  [void](Show-Modal $f);$r=$f.Tag;$f.Dispose();if($r){Start-JobRequest $r}
}
function Show-Observations($rows){
  $f=Modal 'LOL 服务器识别 · 只读观察，选中后可手动归类' 1080 570
  $grid=Grid $f 12 455
  Fill-Grid $grid $rows @('host','ip','port','network','group','process','evidence','lastSeen')
  $null=Label $f 'DNS 是解析结果；日志是历史证据；加密流量和 UDP 不保证完整识别。未知记录不会自动加入规则。' 12 475 1030 35 9
  $adopt=Button '选中地址 → 目标编辑' 750 518 290 34;$f.Controls.Add($adopt)
  $adopt.Add_Click({if($grid.SelectedRows.Count){$f.Tag=$grid.SelectedRows[0].Tag;$f.Close()}}.GetNewClosure())
  [void](Show-Modal $f);$r=$f.Tag;$f.Dispose();if($r){Manage-Targets $r}
}
function Show-Results {
  $f=Modal '详细测试结果 · 最近记录与真实游戏验收' 1060 610
  $grid=Grid $f 12 540;$rows=@()
  foreach($entry in @($script:lastState.results|Sort-Object time -Descending|Select-Object -First 200)){
    $node=$script:catalog|Where-Object id -eq $entry.node|Select-Object -First 1
    foreach($r in $entry.result.rows){$rows+=@{节点=$node.label;组=$entry.group;目标=$r.name;通过=$r.ok;秒=$r.seconds;说明=$r.detail;时间=$entry.time}}
    if(-not $entry.result.rows.Count){$rows+=@{节点=$node.label;组=$entry.group;目标='整组';通过=$entry.result.passed;说明=$entry.result.message;时间=$entry.time}}
  }
  foreach($o in $script:lastState.outcomes){$rows+=@{节点=($o.selection|ConvertTo-Json -Compress);组='用户验收';目标=$o.outcome;说明=$o.note;时间=$o.time}}
  Fill-Grid $grid $rows @('节点','组','目标','通过','秒','说明','时间');[void](Show-Modal $f);$f.Dispose()
}
function Edit-Settings {
  $s=$script:lastState.settings;$values=@{'核心程序路径'=$s.core;'Clash 配置路径'=$s.source;'Python 3 路径'=$s.python;'Clash 管道名称'=$s.pipe;'物理网卡名称'=$s.interface;'日志文件夹（分号分隔）'=($s.logRoots -join ';')}
  $r=Edit-Fields '本机设置 · 支持 Windows / Clash Verge named pipe' @('核心程序路径','Clash 配置路径','Python 3 路径','Clash 管道名称','物理网卡名称','日志文件夹（分号分隔）') $values
  if($r){Start-JobRequest @{action='settings';settings=@{core=$r['核心程序路径'];source=$r['Clash 配置路径'];python=$r['Python 3 路径'];pipe=$r['Clash 管道名称'];interface=$r['物理网卡名称'];logRoots=@($r['日志文件夹（分号分隔）'] -split ';'|Where-Object {$_})}}}
}
$batch=Button '一键测试全部' 20 795 160 35;$cancel=Button '取消测试' 187 795 115 35;$cancel.Enabled=$false
$manage=Button '节点管理' 309 795 120 35;$targetButton=Button 'LOL 目标' 436 795 120 35;$discover=Button '识别服务器' 563 795 135 35
$details=Button '详细结果' 705 795 120 35;$settingsButton=Button '设置' 832 795 80 35;$help=Button '说明' 919 795 95 35
$form.Controls.AddRange(@($batch,$cancel,$manage,$targetButton,$discover,$details,$settingsButton,$help))
$script:interactive+=@($batch,$manage,$targetButton,$discover,$details,$settingsButton,$help)
$batch.Add_Click({Start-JobRequest @{action='batch'}})
$cancel.Add_Click({if($script:job){[IO.File]::WriteAllText(($script:job.output+'.cancel'),'cancel');Log '已请求取消，正在运行的组会先结束并清理代理。';$cancel.Enabled=$false}})
$manage.Add_Click({Manage-Nodes});$targetButton.Add_Click({Manage-Targets});$discover.Add_Click({Start-JobRequest @{action='discover';includeLogs=$true;durationSeconds=45}})
$details.Add_Click({Show-Results});$settingsButton.Add_Click({Edit-Settings})
$help.Add_Click({[void][Windows.Forms.MessageBox]::Show($form,"LOL 专用诊断与分流工具，用户自带节点。`n`n三组按用途划分：`n1. 大厅/授权/聊天会话`n2. 启动配置完整下载`n3. 对局 UDP 实时数据`n`n并非三个固定 IP，也不是按画面依次切换，服务可同时连接。当前内置 hn10 模板，其他区服需维护目标。`n`n一键测试仅测已添加节点的 TCP 目标；对局需真实游戏验收。结果超过 30 分钟标为待复测。`n`n识别服务器会观察 45 秒，期间正常打开游戏；未确认地址需手动归类。`n`n商业加速器提供线路；本工具仅管理和验证用户自己的线路。关闭窗口保留分流；撤回请点恢复。`n`n本地数据：$labDir",'为什么三组 / 如何使用')})
# Record real play separately from synthetic probes.
$outcomeMenu=[Windows.Forms.ContextMenuStrip]::new();foreach($text in @('大厅成功','进入游戏成功','对局正常','对局失败')){$item=$outcomeMenu.Items.Add($text);$item.Add_Click({param($sender,$args) $r=Edit-Fields '记录当前已应用组合' @('备注') @{'备注'=''};if($r){Start-JobRequest @{action='outcome';outcome=$sender.Text;note=$r['备注']}}})};$details.ContextMenuStrip=$outcomeMenu
$details.Text='结果/右键验收'
function Show-GroupHelp($index){
  $text=@(
    '大厅与会话包含大厅、房间、授权和聊天等多个服务。聊天失败未必影响对局；未登录的探测响应不代表账号登录成功。',
    '启动配置检查启动时的公开配置能否完整下载。它不是所有补丁、资源和游戏文件的检查；客户端也可能使用缓存。',
    '对局连接主要关注 UDP 实时数据。声明支持、代理握手和真实对局成功是不同等级；没有实际对局证据就显示未验证。'
  )[$index]
  $key=@('lobby','config','match')[$index];$count=@($script:lastState.targets|Where-Object group -eq $key).Count
  [void][Windows.Forms.MessageBox]::Show($form,($text+"`n`n当前此组有 $count 条目标规则。三组表示用途，不是三个固定 IP。可在单接口路径中单独分配。"),'这组测试什么？')
}
function Edit-Overrides {
  $f=Modal '单接口路径 · 不懂这些可以保留按组默认' 1000 580;$grid=Grid $f 50 440;$grid.ReadOnly=$false
  $null=Label $f '优先保留可用直连。修改只影响待应用方案；点击应用时会先展示完整转发清单。' 12 10 960 32 9
  foreach($name in @('服务','目标','分组')){[void]$grid.Columns.Add($name,$name);$grid.Columns[$name].ReadOnly=$true}
  $column=[Windows.Forms.DataGridViewComboBoxColumn]::new();$column.Name='路径';$column.HeaderText='准备使用的路径';[void]$grid.Columns.Add($column)
  $lookup=@{'按组默认'=''}
  foreach($n in $script:catalog|Where-Object enabled){$lookup[$n.label+' ['+$n.id+']']=$n.id}
  foreach($t in $script:lastState.targets|Where-Object enabled){
    $idx=$grid.Rows.Add([object[]]@($t.label,"$($t.host):$($t.port)",$t.group,$null));$row=$grid.Rows[$idx];$row.Tag=$t.id
    $cell=$row.Cells['路径'];[void]$cell.Items.Add('按组默认')
    foreach($n in $script:catalog|Where-Object {$_.enabled -and ($t.network -ne 'UDP' -or $_.udp)}){[void]$cell.Items.Add($n.label+' ['+$n.id+']')}
    $row.Cells['路径'].Value='按组默认';foreach($label in $cell.Items){if($script:overrides.ContainsKey($t.id) -and $lookup[$label] -eq $script:overrides[$t.id]){$cell.Value=$label}}
  }
  $save=Button '保存为待应用方案' 735 515 240 35;$f.Controls.Add($save)
  $save.Add_Click({[void]$grid.EndEdit();$o=@{};foreach($row in $grid.Rows){$id=$lookup[[string]$row.Cells['路径'].Value];if($id){$o[$row.Tag]=$id}};$f.Tag=$o;$f.DialogResult='OK';$f.Close()}.GetNewClosure())
  if((Show-Modal $f) -eq 'OK'){$script:overrides=$f.Tag;Log '单接口选择已保存到草稿，尚未应用。'};$f.Dispose()
}
function Confirm-RoutePreview($assignments){
  $f=Modal '应用前确认：哪些游戏连接会被转发' 990 620
  $box=[Windows.Forms.RichTextBox]::new();$box.SetBounds(16,16,954,486);$box.ReadOnly=$true;$f.Controls.Add($box)
  $lines=@('以下只列本工具要设置的游戏连接；已有 Clash 的其他规则仍然生效。','节点可用不代表可信。按地址/端口分流无法区分同一连接内的公开与授权请求。','')
  foreach($a in $assignments){$node=$script:catalog|Where-Object id -eq $a.node_id|Select-Object -First 1;$lines+="$($a.label) · $($a.host):$($a.port) → $($node.label)";$lines+='  '+$a.notice}
  $matchNode=$script:catalog|Where-Object id -eq (Choices).match|Select-Object -First 1;$lines+="`n游戏进程的其他 UDP → $($matchNode.label)（补充分流规则）"
  $box.Text=$lines -join "`r`n"
  $yes=Button '确认应用' 710 540 125 38;$yes.DialogResult='OK';$no=Button '取消' 845 540 125 38;$no.DialogResult='Cancel';$f.Controls.AddRange(@($yes,$no))
  $confirmed=(Show-Modal $f) -eq 'OK';$f.Dispose();return $confirmed
}
$overrideMenu=[Windows.Forms.ContextMenuStrip]::new();$editItem=$overrideMenu.Items.Add('单接口路径（高级）');$editItem.Add_Click({Edit-Overrides});$suggestItem=$overrideMenu.Items.Add('根据当前有效测试提出建议');$suggestItem.Add_Click({Start-JobRequest @{action='route-suggest'}});$apply.ContextMenuStrip=$overrideMenu;$apply.Text='预览并应用组合';$apply.AccessibleDescription='右键可单独分配每个接口，或查看测试建议。'
