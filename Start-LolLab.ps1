Add-Type -AssemblyName System.Windows.Forms
$cmd=Get-Command pwsh.exe -ErrorAction SilentlyContinue
$runtime=if($cmd){$cmd.Source}else{Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'}
if(-not (Test-Path $runtime)){
  [void][Windows.Forms.MessageBox]::Show('首次使用需要安装 PowerShell 7.2 或更新版本。安装后再双击 Start.cmd。诊断不需要代理节点；Python 和 Clash 仅在主动测试或分流时需要。','LOL 连接诊断助手');exit 1
}
Start-Process -FilePath $runtime -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+(Join-Path $PSScriptRoot 'lol-guide.ps1')+'"')) -WindowStyle Hidden
