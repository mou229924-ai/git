param([string]$SourceDir=(Split-Path $PSScriptRoot -Parent), [string]$Output='')
$ErrorActionPreference='Stop'
. (Join-Path $SourceDir 'lib.ps1')
. (Join-Path $SourceDir 'classification-learning.ps1')
. (Join-Path $SourceDir 'classifier-scan.ps1')
$run=Join-Path ([IO.Path]::GetTempPath()) ('nailong-learning-'+[guid]::NewGuid().ToString('N'))
$script:Root=Join-Path $run 'library'
$script:AppDir=Join-Path $run 'app'
$script:ConfigPath=Join-Path $script:AppDir 'config.json'
$script:LogPath=Join-Path $script:AppDir '_classifier.log'
New-Item -ItemType Directory -Path $script:Root,$script:AppDir,(Join-Path $script:Root '项目'),(Join-Path $script:Root '票据') -Force | Out-Null
$script:Cfg=[pscustomobject]@{inbox=$script:Root;otherFolderName='其他';saveNewSubjects=$true;ignoreFiles=@();ignoreExtensions=@('.tmp');customSetting=[pscustomobject]@{Keep='custom-value'};subjects=@(
[pscustomobject]@{name='项目';filenameKeywords=@('项目');contentKeywords=@('立项');customRuleField='preserve-me'},
[pscustomobject]@{name='票据';filenameKeywords=@('发票');contentKeywords=@('税额')})}
Write-AtomicUtf8 $script:ConfigPath ($script:Cfg | ConvertTo-Json -Depth 30)
function Update-IndexEntry { }
function Digest { return (Get-FileHash -LiteralPath $script:ConfigPath -Algorithm SHA256).Hash }
function Put([string]$Name) { $path=Join-Path $script:Root $Name; [IO.File]::WriteAllText($path,'learning-fixture-bytes',$script:Utf8); return $path }
$script:checks=New-Object Collections.ArrayList
function Check([string]$Name,[bool]$Ok) {[void]$script:checks.Add(@{Name=$Name;Passed=$Ok}); Write-Output ((@('FAIL','PASS')[[int]$Ok])+' '+$Name)}
try {
$initial=Digest
$check=Test-ManualClassificationKeyword -Name '项目' -Keyword '星河计划' -FileName '星河计划_初稿.txt'
Check 'A specific phrase present in the filename is eligible' $check.Valid
foreach($word in @('1','123456','试卷','不存在','a')) {
$check=Test-ManualClassificationKeyword -Name '项目' -Keyword $word -FileName '星河计划_初稿.txt'
Check ('Unusable keyword is refused: '+$word) (-not $check.Valid)
}
$check=Test-ManualClassificationKeyword -Name '项目' -Keyword '发票附件' -FileName '发票附件.txt'
Check 'An overlapping keyword for a different directory is refused' (-not $check.Valid)
$check=Test-ManualClassificationKeyword -Name '不存在' -Keyword '星河计划' -FileName '星河计划.txt'
Check 'An unknown directory cannot acquire a learned rule' (-not $check.Valid)
$unconfirmed=Save-ManualClassificationKeyword -Name '项目' -Keyword '星河计划' -FileName '星河计划.txt' -MovedPath 'missing'
Check 'Missing explicit confirmation leaves configuration unchanged' (-not $unconfirmed.Saved -and (Digest) -eq $initial)
$p=Put '星河计划_不记住.txt'
$fi=Get-Item -LiteralPath $p
$moved=Move-ManualSubjectSelection -FileInfo $fi -Result @{Action='subject';Name='项目';Remember=$false;Keyword='星河计划'} -Text 'fixture' -TextProvided
Check 'An unchecked selection moves the file without learning' ([IO.File]::Exists($moved) -and (Digest) -eq $initial)
$p=Put '星河计划_初稿.txt'
$fi=Get-Item -LiteralPath $p
$moved=Move-ManualSubjectSelection -FileInfo $fi -Result @{Action='subject';Name='项目';Remember=$true;Keyword='星河计划'} -Text 'fixture' -TextProvided
$cfg=Read-AtomicUtf8 $script:ConfigPath | ConvertFrom-Json
Check 'Confirmed successful manual move stores the chosen phrase once' (@($cfg.subjects[0].filenameKeywords | Where-Object {$_ -eq '星河计划'}).Count -eq 1)
Check 'The moved document retains its original bytes' ([IO.File]::ReadAllText($moved) -eq 'learning-fixture-bytes')
Check 'Learning preserves custom global and rule settings' ($cfg.customSetting.Keep -eq 'custom-value' -and $cfg.subjects[0].customRuleField -eq 'preserve-me')
Check 'Learning only changes target filename keywords' ($cfg.subjects[0].contentKeywords[0] -eq '立项' -and $cfg.subjects[1].filenameKeywords[0] -eq '发票' -and $cfg.subjects[1].contentKeywords[0] -eq '税额')
$decision=Get-FilenameDecision '星河计划_二稿'
Check 'Subsequent filenames use the learned directory' ($decision -and -not $decision.Ambiguous -and $decision.Rule.name -eq '项目')
$before=Digest
$saved=Save-ManualClassificationKeyword -Name '项目' -Keyword '星河计划' -FileName '星河计划_初稿.txt' -MovedPath $moved -Confirmed
Check 'Learning an existing phrase does not rewrite configuration' ($saved.Saved -and -not $saved.Changed -and (Digest) -eq $before)
$p=Put '停留文件_提案.txt'
$saved=Save-ManualClassificationKeyword -Name '项目' -Keyword '停留文件' -FileName '停留文件_提案.txt' -MovedPath $p -Confirmed
Check 'A file not moved into the selected directory cannot teach a rule' (-not $saved.Saved -and (Digest) -eq $before)
$p=Put '失效快照_提案.txt'
$fi=Get-Item -LiteralPath $p
$null=$fi.Length; $null=$fi.LastWriteTimeUtc
[IO.File]::AppendAllText($p,'changed')
$failed=$false
try { $null=Move-ManualSubjectSelection -FileInfo $fi -Result @{Action='subject';Name='项目';Remember=$true;Keyword='失效快照'} -Text 'fixture' -TextProvided } catch [IO.IOException] { $failed=$true }
Check 'A changed file cannot move or teach a stale rule' ($failed -and [IO.File]::Exists($p) -and (Digest) -eq $before)
# Simulate another process assigning the proposed phrase after the dialog was built.
$cfg=Read-AtomicUtf8 $script:ConfigPath | ConvertFrom-Json
$cfg.subjects[1].filenameKeywords=@($cfg.subjects[1].filenameKeywords)+@('星河计划')
Write-AtomicUtf8 $script:ConfigPath ($cfg | ConvertTo-Json -Depth 30)
$before=Digest
$saved=Save-ManualClassificationKeyword -Name '项目' -Keyword '星河计划' -FileName '星河计划_初稿.txt' -MovedPath $moved -Confirmed
Check 'Conflict is rechecked against fresh configuration under the lock' (-not $saved.Saved -and (Digest) -eq $before)
$null=Complete-ManualClassificationLearning -Result @{Action='keep';Name='项目';Remember=$true;Keyword='星河计划'} -FileName '星河计划_初稿.txt' -MovedPath $moved -Quiet
Check 'A non-classification action never changes a rule' ((Digest) -eq $before)
} catch {Check ('Unhandled test failure: '+$_.Exception.Message) $false; Write-Output $_.ScriptStackTrace}
$report=@{Passed=@($script:checks | Where-Object Passed).Count;Failed=@($script:checks | Where-Object {-not $_.Passed}).Count;Checks=@($script:checks.ToArray());Scratch=$run}
if(-not $Output){$Output=Join-Path $PSScriptRoot 'learning-results.json'}
[IO.File]::WriteAllText($Output,($report|ConvertTo-Json -Depth 5),[Text.Encoding]::UTF8)
Write-Output ('TOTAL passed='+$report.Passed+' failed='+$report.Failed)
if($report.Failed){exit 1}
