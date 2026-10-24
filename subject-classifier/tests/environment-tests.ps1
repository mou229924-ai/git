param([string]$SourceDir=(Split-Path $PSScriptRoot -Parent),[string]$Output='')
$ErrorActionPreference='Stop'
$SourceDir=[IO.Path]::GetFullPath($SourceDir)
$stage=$PSScriptRoot
$run=Join-Path $SourceDir ('test-runs\environment-'+[guid]::NewGuid().ToString('N'))
$app=Join-Path $run 'app';New-Item -ItemType Directory -Path $app,(Join-Path $app 'tools') -Force|Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
$before=@(Get-ExecutionPolicy -List|ForEach-Object{[string]$_.Scope+':'+[string]$_.ExecutionPolicy})-join '|'
$sourceConfig=Join-Path $SourceDir 'config.json';$sourceHash='';if([IO.File]::Exists($sourceConfig)){$sourceHash=(Get-FileHash -LiteralPath $sourceConfig).Hash}
$runtime=[IO.File]::ReadAllText((Join-Path $SourceDir 'application-files.json'),$utf8)|ConvertFrom-Json
$runtime=@($runtime)
foreach($relative in @($runtime)+@('application-files.json','search.vbs','奶龙.code.vbs','启动监听.vbs','开机自启-开启.vbs','README.md','tools/doctor.ps1')){
 $from=Join-Path $SourceDir $relative;if(-not [IO.File]::Exists($from)){continue};$to=Join-Path $app $relative;New-Item -ItemType Directory -Path (Split-Path $to -Parent) -Force|Out-Null;Copy-Item -LiteralPath $from -Destination $to
}
$integration=Join-Path $stage 'integrate-environment.ps1'
if([IO.File]::Exists($integration)){& $integration -TargetDirectory $app -Apply|Out-Null}
. (Join-Path $app 'environment.ps1')
. (Join-Path $app 'document-text.ps1')
$checks=New-Object Collections.ArrayList
function Check([string]$Name,[bool]$Passed){[void]$checks.Add(@{Name=$Name;Passed=$Passed});Write-Output ((@('FAIL','PASS')[[int]$Passed])+' '+$Name)}
try{
 $state=Get-ApplicationEnvironment -Directory $app
 Check 'Environment diagnosis needs no local configuration' (-not [IO.File]::Exists((Join-Path $app 'config.json')))
 Check 'Windows PowerShell 5.1 and window components are detected' ($state.SupportedPowerShell-and $state.WinForms)
 Check 'Optional PDF/OCR capabilities return explicit booleans and reasons' ($state.WindowsPdf-is [bool]-and $state.OcrAvailable-is [bool]-and -not [string]::IsNullOrWhiteSpace($state.OcrReason))
 Check 'Unsigned distribution does not claim a trusted signature' ($state.EntrySignature-ne 'Valid'-and $state.SigningNotice.Contains('未使用可信证书签名'))
 Check 'All execution-policy scopes are reported without policy changes' (@($state.ExecutionPolicyScopes).Count-eq @(Get-ExecutionPolicy -List).Count-and -not $state.PolicyChangesMade)
 $unsigned=Join-Path $app 'downloaded-test.ps1';[IO.File]::WriteAllText($unsigned,'# synthetic unsigned download fixture',$utf8)
 Set-Content -LiteralPath $unsigned -Stream Zone.Identifier -Value @('[ZoneTransfer]','ZoneId=3')
 $signature=Get-ApplicationSignatureState $unsigned
 Check 'Internet-origin marker is detected without unblocking the file' ($signature.Downloaded-and $signature.DownloadZone-eq 3-and @(Get-Content -LiteralPath $unsigned -Stream Zone.Identifier).Count-gt 0)
 $missing=Get-ApplicationSignatureState (Join-Path $app 'missing.ps1')
 Check 'Missing entry scripts are reported explicitly' ($missing.Status-eq 'Missing')
 $invalid=Get-PreviewHandlerCapability 'not-an-extension'
 Check 'Invalid preview formats do not probe or launch handlers' (-not $invalid.Registered)
 $script:RegistryFixture=@{'.pdf'='Fixture.Pdf';'Fixture.Pdf\shellex\{8895b1c6-b41f-4c1c-a562-0d564250836f}'='{12345678-1234-1234-1234-123456789abc}'}
 function Get-PreviewRegistryValue {param([string]$SubKey,[string]$ValueName='');return [string]$script:RegistryFixture[$SubKey]}
 $handler=Get-PreviewHandlerCapability '.pdf'
 Check 'ProgID registration is detected without loading its COM server' ($handler.Registered-and $handler.Handler-eq '{12345678-1234-1234-1234-123456789abc}'-and $handler.Reason.Contains('实际预览'))
 $script:RegistryFixture=@{}
 function Get-WindowsPdfCapability{return $false}
 function Get-OcrAvailability{return [pscustomobject]@{Available=$false;Languages=@();Reason='Synthetic unavailable OCR language package.'}}
 $fallback=Get-ApplicationEnvironment -Directory $app
 Check 'Missing preview and OCR components degrade into explicit capability state' (-not $fallback.WindowsPdf-and -not $fallback.OcrAvailable-and -not $fallback.SystemPreviewHandlers['.docx'].Registered)
 Check 'Fallback descriptions preserve default-app opening and filename search' (($fallback.Fallback-join ' ').Contains('默认应用打开')-and ($fallback.Fallback-join ' ').Contains('文件名搜索'))
 $runtime=[IO.File]::ReadAllText((Join-Path $app 'application-files.json'),$utf8)|ConvertFrom-Json
 $runtime=@($runtime)
 $bypass=@()
 foreach($relative in @($runtime)+@('search.vbs','奶龙.code.vbs','启动监听.vbs','开机自启-开启.vbs')){
  $path=Join-Path $app $relative;if([IO.File]::Exists($path)-and [IO.Path]::GetExtension($path)-in @('.ps1','.vbs','.cmd')){
   $text=[IO.File]::ReadAllText($path,$utf8);if($text-match 'ExecutionPolicy\s+Bypass'-or $text-match "'ExecutionPolicy'\s*,\s*'Bypass'"-or $text-match "'-ExecutionPolicy'\s*,\s*'Bypass'"){$bypass+=,$relative}
  }
 }
 Check 'Runtime entry, background, preview and restart paths no longer request Bypass' ($bypass.Count-eq 0)
 $tray=[IO.File]::ReadAllText((Join-Path $app 'classifier-tray.ps1'),$utf8)
 Check 'Tray search opens PowerShell directly without requiring VBS' ($tray.Contains('Start-ApplicationWindow')-and -not $tray.Contains('wscript.exe'))
 $cmd=[IO.File]::ReadAllText((Join-Path $app '奶龙.code.cmd'),[Text.Encoding]::ASCII)
 Check 'Default CMD uses RemoteSigned and catches startup security failures' ($cmd.Contains('RemoteSigned')-and $cmd.Contains('NAILONG_ENTRY')-and $cmd.Contains('-Command')-and $cmd.Contains('catch')-and $cmd.Contains('MessageBox')-and $cmd.Contains('Unblock')-and -not $cmd.Contains('wscript'))
 $startupPath=Join-Path $app '开机自启-开启.vbs'
 if([IO.File]::Exists($startupPath)){
  $startup=[IO.File]::ReadAllText($startupPath,$utf8)
  Check 'Compatibility autostart targets PowerShell with RemoteSigned' ($startup.Contains('RemoteSigned')-and -not $startup.Contains('wscript.exe'))
 }else{
  Check 'No legacy autostart helper is created by the environment integration' (-not [IO.File]::Exists($startupPath))
 }
 $json=Join-Path $run 'doctor.json';$stderr=Join-Path $run 'doctor.stderr.txt'
 $args='-NoProfile -STA -ExecutionPolicy RemoteSigned -File "'+(Join-Path $app 'tools\doctor.ps1')+'" -Json'
 $process=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $args -RedirectStandardOutput $json -RedirectStandardError $stderr -PassThru
 try{$null=$process.Handle;if(-not $process.WaitForExit(20000)){$process.Kill();throw 'doctor test timed out'};$process.WaitForExit();$exit=$process.ExitCode}finally{$process.Dispose()}
 $report=[IO.File]::ReadAllText($json,$utf8)|ConvertFrom-Json
 Check 'Standalone doctor produces JSON without first-run library setup' ($exit-eq 0-and $report.PowerShellVersion-and -not [IO.File]::Exists((Join-Path $app 'config.json')))
 $after=@(Get-ExecutionPolicy -List|ForEach-Object{[string]$_.Scope+':'+[string]$_.ExecutionPolicy})-join '|'
 Check 'Diagnostics and integration leave system execution policies unchanged' ($before-eq $after)
 $afterHash='';if([IO.File]::Exists($sourceConfig)){$afterHash=(Get-FileHash -LiteralPath $sourceConfig).Hash}
 Check 'Environment checks leave source library configuration unchanged' ($sourceHash-eq $afterHash)
}catch{Check ('Unhandled environment test error: '+$_.Exception.Message) $false;Write-Output $_.ScriptStackTrace}
$result=@{Passed=@($checks|Where-Object Passed).Count;Failed=@($checks|Where-Object{-not $_.Passed}).Count;Checks=@($checks.ToArray());Scratch=$run}
if(-not $Output){$Output=Join-Path $PSScriptRoot 'environment-results.json'}
[IO.File]::WriteAllText($Output,($result|ConvertTo-Json -Depth 6),$utf8)
Write-Output ('TOTAL passed='+$result.Passed+' failed='+$result.Failed)
if($result.Failed){exit 1}
