param([string]$SourceDir='',[string]$ScratchBase='',[string]$Output='')
$ErrorActionPreference='Stop'
if(-not $SourceDir){$SourceDir=Split-Path $PSScriptRoot -Parent}
$SourceDir=[IO.Path]::GetFullPath($SourceDir)
if(-not $ScratchBase){$ScratchBase=Join-Path $PSScriptRoot 'scratch'}
$runDir=Join-Path $ScratchBase ('check-'+[guid]::NewGuid().ToString('N'))
. (Join-Path $SourceDir 'tests\test-support.ps1')
function Get-IntegrationHash([string]$Path){if([IO.File]::Exists($Path)){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash};return ''}
$sourceConfigHash=Get-IntegrationHash (Join-Path $SourceDir 'config.json')
$sourceGateHash=Get-IntegrationHash (Join-Path $SourceDir 'tests\verified.json')
$isolation=New-IsolatedTestApplication -SourceDir $SourceDir -RunDir $runDir
$testRoot=Join-Path $runDir 'classification-library'
[void][IO.Directory]::CreateDirectory($testRoot)
$configFile=Join-Path $isolation.AppDir 'config.json'
$seed=[IO.File]::ReadAllText($configFile,[Text.Encoding]::UTF8) | ConvertFrom-Json
$seed.inbox=$testRoot;$seed.processExistingOnStartup=$true;$seed.stablePolls=1
if(-not $seed.PSObject.Properties['learning']){$seed|Add-Member -NotePropertyName learning -NotePropertyValue ([pscustomobject]@{enabled=$true;retrainMinutes=15})}
$seed.learning.enabled=$true
$seed.scoring.minScore=2;$seed.scoring.keywordWeight=2;$seed.scoring.dominance=1.5
$seed.subjects=@(
    [pscustomobject]@{name='人工甲';filenameKeywords=@('route-alpha');contentKeywords=@('alpha-content')},
    [pscustomobject]@{name='人工乙';filenameKeywords=@('route-beta');contentKeywords=@('beta-content')}
)
[IO.File]::WriteAllText($configFile,($seed | ConvertTo-Json -Depth 30),[Text.Encoding]::UTF8)
# Only this freshly created application is initialized. Source config and gate are audited below.
. (Join-Path $isolation.AppDir 'lib.ps1')
. (Join-Path $isolation.AppDir 'classifier-scan.ps1')
$checks=New-Object Collections.ArrayList
function Check-Integration([string]$Name,[bool]$Passed){[void]$script:checks.Add(@{Name=$Name;Passed=$Passed});Write-Output ((@('FAIL','PASS')[[int]$Passed])+' '+$Name)}
function Put-Integration([string]$Relative,[string]$Text){$file=Join-Path $script:Root $Relative;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file));[IO.File]::WriteAllText($file,$Text,$script:Utf8);return $file}
function Save-IntegrationEnabled([bool]$Enabled){$script:Cfg.learning.enabled=$Enabled;Write-AtomicUtf8 $script:ConfigPath ($script:Cfg|ConvertTo-Json -Depth 30)}
function Test-IntegrationOriginals($Hashes){foreach($file in $Hashes.Keys){if(-not [IO.File]::Exists($file) -or (Get-IntegrationHash $file) -ne $Hashes[$file]){return $false}};return $true}
$actualFileText=(Get-Command Get-FileText).ScriptBlock
$actualLearned=(Get-Command Get-LearnedClassification).ScriptBlock
$actualFolderProcessor=(Get-Command Process-DroppedFolder).ScriptBlock
$failure=''
try{
    $science='电路 电流 电压 磁场 导体 电磁感应 欧姆定律 线圈 电阻 功率 电子 '
    $garden='植物 园艺 叶片 根系 土壤 发芽 浇水 施肥 阳光 花卉 种子 生长 细胞 '
    for($i=0;$i -lt 6;$i++){
        $null=Put-Integration ('科研资料\电路磁场-'+$i+'.txt') (($science*5)+'独立编号'+$i)
        $null=Put-Integration ('园艺记录\种子土壤-'+$i+'.txt') (($garden*5)+'独立编号'+$i)
    }
    $null=Sync-LibraryIndex
    $trained=Train-LibraryClassifier
    Check-Integration 'A real local model trains without creating explicit directory rules' ($trained.Published -and @($script:Cfg.subjects|Where-Object name -in @('科研资料','园艺记录')).Count -eq 0)
    $modelFile=Join-Path $script:IndexDir 'model.json';$modelHash=Get-IntegrationHash $modelFile
    $probePath=Put-Integration '_integration\unknown.txt' 'neutral fixture'
    $warm=Get-LearnedClassification -Path $probePath -Text $science -TextProvided
    Check-Integration 'A real model is active and cached before testing its disable switch' ($warm.Rule.name -eq '科研资料' -and $null -ne $script:LearnedModelCache)
    Save-IntegrationEnabled $false
    $disabled=Get-LearnedClassification -Path $probePath -Text $science -TextProvided
    Check-Integration 'Disabling learning blocks the real API even with an already cached model' ($null -eq $disabled -and (Get-IntegrationHash $modelFile) -eq $modelHash)
    Save-IntegrationEnabled $true
    Check-Integration 'Re-enabling restores prediction without rewriting or retraining the model' ((Get-LearnedClassification -Path $probePath -Text $science -TextProvided).Rule.name -eq '科研资料' -and (Get-IntegrationHash $modelFile) -eq $modelHash)
    $script:IntegrationMLCalls=0;$script:IntegrationBody='neutral'
    function Get-LearnedClassification {param([string]$Path,[string]$Text,[switch]$TextProvided)$script:IntegrationMLCalls++;return [pscustomobject]@{Ambiguous=$false;Rule=[pscustomobject]@{name='科研资料'};How='learned';Confidence=0.9;Evidence=@('电路','磁场')}}
    function Get-FileText {param([string]$Path,[int]$Max)return $script:IntegrationBody}
    function Classify-Integration([string]$Name,[string]$Body,[string]$Context=''){
        $file=Put-Integration ('_integration\'+$Name) 'routing fixture'
        $script:IntegrationBody=$Body;$script:IntegrationMLCalls=0
        return Get-DocumentClassification -Path $file -Context $Context
    }
    $result=Classify-Integration 'route-alpha.txt' 'neutral'
    Check-Integration 'Explicit filename rules win without invoking the learned classifier' ($result.Decision.Rule.name -eq '人工甲' -and $result.How -eq 'filename' -and $script:IntegrationMLCalls -eq 0)
    $result=Classify-Integration 'plain-content.txt' ('beta-content '*4)
    Check-Integration 'Explicit content rules win without invoking the learned classifier' ($result.Decision.Rule.name -eq '人工乙' -and $result.How -eq 'content' -and $script:IntegrationMLCalls -eq 0)
    $result=Classify-Integration 'route-alpha-route-beta.txt' 'neutral'
    Check-Integration 'Mixed filename rules remain ambiguous instead of falling back to learning' ($result.Decision.Ambiguous -and $result.How -eq 'mixed-filename' -and $script:IntegrationMLCalls -eq 0)
    $result=Classify-Integration 'route-alpha-conflict.txt' ('beta-content '*4)
    Check-Integration 'Filename-content conflicts remain unresolved and never consult learning' ($result.Decision.Ambiguous -and $result.How -eq 'conflict' -and $script:IntegrationMLCalls -eq 0)
    $result=Classify-Integration 'tied-content.txt' ('alpha-content beta-content '*4)
    Check-Integration 'Ambiguous content scores cannot be overridden by a model' ($result.Decision.Ambiguous -and $script:IntegrationMLCalls -eq 0)
    $result=Classify-Integration 'parent-context.txt' 'neutral' '人工乙'
    Check-Integration 'A known parent-directory context wins before learned classification' ($result.Decision.Rule.name -eq '人工乙' -and $result.How -eq 'folder-context' -and $script:IntegrationMLCalls -eq 0)
    $result=Classify-Integration 'custom-context.txt' 'neutral' '现有自定义目录'
    Check-Integration 'Even an unconfigured parent context prevents learning from moving its file' ($null -eq $result.Decision -and $script:IntegrationMLCalls -eq 0)
    $result=Classify-Integration 'genuinely-unknown.txt' 'neutral'
    Check-Integration 'Learning fills only a genuinely empty classification decision' ($result.Decision.Rule.name -eq '科研资料' -and $result.How -eq 'learned' -and $script:IntegrationMLCalls -eq 1)
    Save-IntegrationEnabled $false
    $result=Classify-Integration 'disabled-routing.txt' 'neutral'
    Check-Integration 'Disabled learning restores the original unknown decision without calling ML' ($null -eq $result.Decision -and $result.How -eq 'unknown' -and $script:IntegrationMLCalls -eq 0)
    Set-Item Function:\Get-LearnedClassification -Value $actualLearned
    $script:IntegrationBody=$science
    $result=Get-DocumentClassification -Path $probePath
    Check-Integration 'The real integrated route stays unknown when its warmed model is disabled' ($null -eq $result.Decision -and $result.How -eq 'unknown')
    Save-IntegrationEnabled $true
    $result=Get-DocumentClassification -Path $probePath
    Check-Integration 'The real integrated route uses its valid model after re-enabling' ($result.Decision.Rule.name -eq '科研资料' -and $result.How -eq 'learned')
    Set-Item Function:\Get-FileText -Value $actualFileText
    $historical=Put-Integration '现有用户目录\route-alpha.txt' 'alpha-content original-user-bytes'
    $originals=@{};foreach($file in @(Get-LibraryFiles)){$originals[$file.FullName]=Get-IntegrationHash $file.FullName}
    $script:ExpandedDirectories=New-Object Collections.ArrayList
    function Process-DroppedFolder {param($Dir)[void]$script:ExpandedDirectories.Add($Dir.FullName)}
    Initialize-ClassifierState
    for($i=0;$i -lt 4;$i++){Scan-Once}
    Check-Integration 'Learning mode never expands existing custom folders or model-label samples' ($script:ExpandedDirectories.Count -eq 0 -and (Test-IntegrationOriginals $originals))
    $arrived=Put-Integration '新到达的用户目录\route-alpha.txt' 'keep-new-folder-sample'
    for($i=0;$i -lt 4;$i++){Scan-Once}
    Check-Integration 'New root folders also remain user categories while learning is enabled' ($script:ExpandedDirectories.Count -eq 0 -and [IO.File]::ReadAllText($arrived) -eq 'keep-new-folder-sample')
    $incoming=Put-Integration 'route-alpha-incoming.txt' 'alpha-content incoming-file'
    for($i=0;$i -lt 4;$i++){Scan-Once}
    $incomingTarget=Join-Path $script:Root '人工甲\route-alpha-incoming.txt'
    Check-Integration 'Folder protection still permits classification of newly arrived root files' (-not [IO.File]::Exists($incoming) -and [IO.File]::Exists($incomingTarget) -and [IO.File]::ReadAllText($incomingTarget) -eq 'alpha-content incoming-file')
    $beforeRename=Join-Path $script:Root '现有用户目录';$afterRename=Join-Path $script:Root '重命名后的用户目录'
    [IO.Directory]::Move($beforeRename,$afterRename)
    for($i=0;$i -lt 4;$i++){Scan-Once}
    Check-Integration 'Renaming a category while learning is enabled never imports its contents' ($script:ExpandedDirectories.Count -eq 0 -and [IO.File]::ReadAllText((Join-Path $afterRename 'route-alpha.txt')) -eq 'alpha-content original-user-bytes')
    Save-IntegrationEnabled $false
    Initialize-ClassifierState
    for($i=0;$i -lt 4;$i++){Scan-Once}
    Check-Integration 'Turning learning off still protects all directories present at initialization' ($script:ExpandedDirectories.Count -eq 0 -and [IO.File]::Exists((Join-Path $afterRename 'route-alpha.txt')))
    $future=Put-Integration '关闭学习之后新拖入的目录\route-alpha.txt' 'new-folder-import-fixture'
    for($i=0;$i -lt 4;$i++){Scan-Once}
    Check-Integration 'With learning off only later-arriving folders enter the original folder-processing route' ($script:ExpandedDirectories.Count -eq 1 -and $script:ExpandedDirectories[0] -eq [IO.Path]::GetDirectoryName($future))
    Check-Integration 'Integration checks preserve the source configuration and recycle gate' ((Get-IntegrationHash (Join-Path $SourceDir 'config.json')) -eq $sourceConfigHash -and (Get-IntegrationHash (Join-Path $SourceDir 'tests\verified.json')) -eq $sourceGateHash)
}catch{$failure=$_.Exception.ToString();Write-Output $_.ScriptStackTrace;Write-Output $failure}
finally{
    Set-Item Function:\Get-FileText -Value $actualFileText
    Set-Item Function:\Get-LearnedClassification -Value $actualLearned
    Set-Item Function:\Process-DroppedFolder -Value $actualFolderProcessor
    Flush-ApplicationLogs -Force
    $failed=@($checks|Where-Object {-not $_.Passed}).Count;if($failure){$failed++}
    $cleaned=$false
    if($failed -eq 0){try{Remove-IsolatedTestDirectory -Path $runDir -AllowedParent $ScratchBase;$cleaned=(-not [IO.Directory]::Exists($runDir))}catch{$failure=$_.Exception.ToString();$failed++}}
    $report=@{Passed=@($checks|Where-Object Passed).Count;Failed=$failed;Checks=@($checks.ToArray());Failure=$failure;Scratch=$runDir;ScratchRemoved=$cleaned;Time=[datetime]::UtcNow.ToString('o')}
    if(-not $Output){$Output=Join-Path $PSScriptRoot 'learned-integration-results.json'}
    [IO.File]::WriteAllText($Output,($report|ConvertTo-Json -Depth 8),[Text.Encoding]::UTF8)
    Write-Output ('LEARNED INTEGRATION passed='+$report.Passed+' failed='+$report.Failed)
}
if($report.Failed){exit 1}
