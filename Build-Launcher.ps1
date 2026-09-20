$ErrorActionPreference='Stop'
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not (Test-Path $compiler)){$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
if(-not (Test-Path $compiler)){throw 'Windows .NET Framework C# compiler not found.'}
$target=Join-Path $PSScriptRoot 'LolConnect.exe'
& $compiler /nologo /target:winexe /optimize+ /reference:System.Windows.Forms.dll ("/out:"+$target) (Join-Path $PSScriptRoot 'LolConnectLauncher.cs')
if($LASTEXITCODE -ne 0){throw 'Launcher build failed.'}
Get-Item -LiteralPath $target | Select-Object Name,Length
