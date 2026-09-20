param([Parameter(Mandatory)][string]$CorePath)
$ErrorActionPreference='Stop'
$oldData=$env:LOL_LAB_DATA;$env:LOL_LAB_DATA=Join-Path ([IO.Path]::GetTempPath()) ('lol-core-test-'+[guid]::NewGuid().ToString('N'))
$proc=$null
function Check($ok,$name){if(-not $ok){throw "FAIL: $name"};Write-Output "PASS: $name"}
try{
 . (Join-Path $PSScriptRoot 'lol-data.ps1')
 . (Join-Path $PSScriptRoot 'lol-core.ps1')
 . (Join-Path $PSScriptRoot 'lol-routing-review.ps1')
 $settings.pipe='lol-test-'+[guid]::NewGuid().ToString('N');$settings.core=$CorePath;$coreExe=$CorePath
 $source=Join-Path $labDir 'fixture.yaml';$settings.source=$source
 $baseline="mode: rule`nlog-level: silent`nexternal-controller-pipe: '\\.\pipe\$($settings.pipe)'`ntun:`n  enable: false`nproxies:`n  - {name: 'fixture,proxy', type: http, server: 127.0.0.1, port: 1}`nproxy-groups:`n  - {name: existing, type: select, proxies: [DIRECT]}`nrules:`n  - MATCH,DIRECT`n"
 [IO.File]::WriteAllText($source,$baseline)
 $proc=Start-Process -FilePath $CorePath -ArgumentList @('-d',('"'+$labDir+'"'),'-f',('"'+$source+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $labDir 'core.log') -RedirectStandardError (Join-Path $labDir 'error.log')
 $ready=$false;foreach($attempt in 1..15){try{$null=Core 'GET' '/version';$ready=$true;break}catch{Start-Sleep -Milliseconds 200}}
 Check $ready 'isolated core starts without TUN or system proxy'
 $tokens=$null;$errors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'lol-worker.ps1'),[ref]$tokens,[ref]$errors)
 foreach($name in @('Catalog','Snapshot','Add-Section','Build-Lab','Validate-File','Current-Payload')){$definition=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true);Invoke-Expression $definition.Extent.Text}
 $node=Catalog|Where-Object name -eq 'fixture,proxy'
 $targets=@(@{id='fixture';label='fixture';host='example.invalid';port=443;network='TCP';group='lobby';probe='tls';enabled=$true})
 $request=@{selection=@{lobby='direct';config='direct';match='direct'};assignments=@{fixture=$node.id}}
 $candidate=Build-Lab $baseline;$path=Join-Path $labDir 'candidate.yaml';[IO.File]::WriteAllText($path,$candidate);Validate-File $path
 Check $true 'override with comma in node name passes real core validation'
 $runtime=Save-Runtime;Load-Payload $candidate $runtime
 $rules=(Core 'GET' '/rules').rules
 Check ($rules[0].proxy -like 'LOL-LAB-T-*' -and $rules[-1].type -eq 'Match') 'target overrides precede UDP fallback and original rules'
 Check ($rules[0].payload -match '443' -and $rules[0].payload -match 'example.invalid') 'target rule binds exact destination and port'
 Check (-not (Core 'GET' '/configs').tun.enable) 'isolated load leaves TUN disabled'
 [IO.File]::WriteAllText((Join-Path $labDir 'active.yaml'),$candidate)
 Write-Data 'active-state.json' @{signature=(Rule-Signature $rules);sourceHash='deliberately-stale'}
 $blocked=$false;try{$null=Current-Payload}catch{$blocked=$true};Check $blocked 'external source change prevents stale overwrite'
 Load-Payload $baseline $runtime
 Check (@((Core 'GET' '/rules').rules).Count -eq 1) 'restore removes temporary rules'
 Check (-not ((Core 'GET' '/proxies').proxies.PSObject.Properties['LOL-LAB-LOBBY'])) 'restore removes temporary selectors'
}finally{if($proc -and -not $proc.HasExited){Stop-Process -Id $proc.Id};$env:LOL_LAB_DATA=$oldData}
