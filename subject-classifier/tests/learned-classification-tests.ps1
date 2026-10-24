param([string]$SourceDir='',[string]$ModulePath='',[string]$ScratchBase='')
$ErrorActionPreference='Stop'
if(-not $SourceDir){$SourceDir=Split-Path $PSScriptRoot -Parent}
if(-not $ModulePath){$ModulePath=Join-Path $SourceDir 'learned-classification.ps1'}
. (Join-Path $SourceDir 'lib.ps1')
. $ModulePath
if(-not $ScratchBase){$ScratchBase=Join-Path $SourceDir 'test-runs'}
$runDir=Join-Path $ScratchBase ('learning-'+[guid]::NewGuid().ToString('N'))
$script:AppDir=Join-Path $runDir 'app'
$script:Root=Join-Path $runDir 'library'
[void][IO.Directory]::CreateDirectory($script:AppDir)
[void][IO.Directory]::CreateDirectory($script:Root)
$script:IndexDir=Join-Path $script:AppDir '_index'
$script:IndexDataDir=Join-Path $script:IndexDir 'data'
$script:IndexManifest=Join-Path $script:IndexDir 'manifest.json'
$script:LogPath=Join-Path $script:AppDir '_classifier.log'
$script:Cfg.inbox=$script:Root
$script:SearchTextCache=@{};$script:LearnedModelCache=$null
$script:learningPassed=0;$script:learningFailures=New-Object Collections.ArrayList
function Check-Learning([string]$Name,[bool]$Condition){if($Condition){$script:learningPassed++;Write-Output ('PASS '+$Name)}else{[void]$script:learningFailures.Add($Name);Write-Output ('FAIL '+$Name)}}
function Put-Learning([string]$Relative,[string]$Text){$path=Join-Path $script:Root $Relative;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path));[IO.File]::WriteAllText($path,$Text,$script:Utf8);return $path}
$savedFileText=(Get-Command Get-FileText).ScriptBlock
try{
    Check-Learning 'A new library has no active learned classifier' (-not (Get-LearnedModelStatus).Enabled)
    $science='电路 电流 电压 磁场 导体 电磁感应 欧姆定律 线圈 电阻 功率 电子 '
    $garden='植物 园艺 叶片 根系 土壤 发芽 浇水 施肥 阳光 花卉 种子 生长 细胞 '
    for($i=0;$i -lt 6;$i++){
        $null=Put-Learning ('科研资料\电路磁场-'+$i+'.txt') (($science*5)+'样本编号'+$i)
        $null=Put-Learning ('园艺记录\种子土壤-'+$i+'.txt') (($garden*5)+'样本编号'+$i)
    }
    $rootFile=Put-Learning 'root-document.txt' 'root samples must not form a class'
    $otherFile=Put-Learning (([string]$script:Cfg.otherFolderName)+'\other.txt') 'other samples must not form a class'
    $empty=Put-Learning '科研资料\empty.txt' ''
    $null=Put-Learning '_private\ignored.txt' 'internal samples must not form a class'
    $null=Sync-LibraryIndex
    $hashes=@{};foreach($file in @(Get-LibraryFiles)){$hashes[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
    Set-Item Function:\Get-FileText -Value {throw 'Training must reuse cached text and never invoke OCR.'}
    $trained=Train-LibraryClassifier
    Check-Learning 'Distinct existing folders train a model with held-out validation' ($trained.Published -and $trained.Validation.Tested -ge 2 -and $trained.Validation.Accuracy -eq 1 -and $trained.Validation.Coverage -eq 1)
    Check-Learning 'Training ignores root, other, internal and empty documents' ($trained.SampleCount -eq 12 -and $trained.Labels.Count -eq 2)
    Check-Learning 'The validated model is bound to the current library' (Get-LearnedModelStatus).Enabled
    $prediction=Get-LearnedClassification -Path (Join-Path $script:Root '未命名.txt') -Text '电子在电路中形成电流，线圈产生磁场，导体具有电阻，电压决定功率。' -TextProvided
    Check-Learning 'Cached-content learning predicts the correct directory with evidence' ($prediction.Rule.name -eq '科研资料' -and $prediction.Evidence.Count -ge 2 -and $prediction.Confidence -ge 0.4 -and $prediction.How -eq 'learned')
    $prediction=Get-LearnedClassification -Path (Join-Path $script:Root '未命名.txt') -Text '种子在土壤中发芽，植物根系需要浇水和施肥，阳光使叶片生长。' -TextProvided
    Check-Learning 'A different content class selects its own folder' ($prediction.Rule.name -eq '园艺记录')
    $prediction=Get-LearnedClassification -Path (Join-Path $script:Root '种子土壤植物生长.txt') -Text '' -TextProvided
    Check-Learning 'Filename evidence can classify documents without indexed bodies' ($prediction.Rule.name -eq '园艺记录')
    Check-Learning 'Unknown content remains unclassified' ($null -eq (Get-LearnedClassification -Path '未命名.txt' -Text '会议安排与旅行行程，午餐和住宿预约。' -TextProvided))
    Check-Learning 'Mixed classes remain unclassified when confidence margins are small' ($null -eq (Get-LearnedClassification -Path '未命名.txt' -Text ($science+$garden) -TextProvided))
    Check-Learning 'One matching fragment is insufficient evidence' ($null -eq (Get-LearnedClassification -Path '未命名.txt' -Text '植物' -TextProvided))
    $originalRoot=$script:Root;$script:Root=Join-Path $runDir 'another-library'
    [void][IO.Directory]::CreateDirectory($script:Root)
    Check-Learning 'A model from another library cannot classify files' ($null -eq (Get-LearnedClassification -Path '未命名.txt' -Text $science -TextProvided))
    $script:Root=$originalRoot
    $intact=$true;foreach($path in $hashes.Keys){if(-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $hashes[$path]){$intact=$false}}
    Check-Learning 'Training never moves, rewrites or deletes source documents' $intact
    Set-Item Function:\Get-FileText -Value $savedFileText
    $crossText='相同原始字节的跨目录副本不能成为训练证据。'
    $null=Put-Learning '科研资料\污染样本.txt' $crossText
    $null=Put-Learning '园艺记录\污染样本.txt' $crossText
    Copy-Item -LiteralPath (Join-Path $script:Root '科研资料\电路磁场-0.txt') -Destination (Join-Path $script:Root '科研资料\电路副本.txt')
    $null=Sync-LibraryIndex
    Set-Item Function:\Get-FileText -Value {throw 'Training must not extract document text.'}
    $retrained=Train-LibraryClassifier
    Check-Learning 'Byte-identical samples in different folders are excluded entirely' ($retrained.Published -and $retrained.ExcludedCrossLabelDuplicates -eq 2)
    Check-Learning 'Same-folder copies count as one independent sample' ($retrained.DuplicateCopies -eq 1 -and $retrained.SampleCount -eq 12)
    $allEntries=@(Load-IndexEntries)
    $modelPath=Join-Path $script:IndexDir 'model.json'
    $modelHash=(Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash
    $few=@($allEntries | Where-Object {$_.rel -match '^科研资料\\电路磁场-[01]\.txt$|^园艺记录\\种子土壤-[01]\.txt$'})
    Invoke-IndexLock {$null=Save-IndexEntries -Entries $few}
    $insufficient=Train-LibraryClassifier
    Check-Learning 'Too few independent examples cannot replace a valid model' (-not $insufficient.Published -and $insufficient.Enabled -and (Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash -eq $modelHash)
    Invoke-IndexLock {$null=Save-IndexEntries -Entries $allEntries}
    Set-Item Function:\Get-FileText -Value $savedFileText
    for($i=0;$i -lt 5;$i++){
        $null=Put-Learning ('混合甲\report-'+$i+'.txt') ('公共说明 所有目录使用相同内容 常规文字 '+[guid]::NewGuid().ToString('N'))
        $null=Put-Learning ('混合乙\report-'+$i+'.txt') ('公共说明 所有目录使用相同内容 常规文字 '+[guid]::NewGuid().ToString('N'))
    }
    $null=Sync-LibraryIndex
    $poorEntries=@(Load-IndexEntries | Where-Object {$_.rel -match '^混合[甲乙]\\'})
    Invoke-IndexLock {$null=Save-IndexEntries -Entries $poorEntries}
    Set-Item Function:\Get-FileText -Value {throw 'Training must reuse indexed text.'}
    $poor=Train-LibraryClassifier
    Check-Learning 'Low-quality folders fail validation and preserve the existing model' (-not $poor.Published -and $poor.Enabled -and (Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash -eq $modelHash)
    Check-Learning 'A rejected retraining does not disable previously valid predictions' ((Get-LearnedClassification -Path '未命名.txt' -Text $science -TextProvided).Rule.name -eq '科研资料')
    $status=Get-LearnedModelStatus
    Check-Learning 'Model status exposes sample and validation information' ($status.Samples -eq 12 -and $status.Validation.Tested -ge 2 -and $status.Labels.Count -eq 2)
    $modelText=Read-AtomicUtf8 $modelPath
    Check-Learning 'Stored model contains features and no complete training document body' ($modelText -notmatch [regex]::Escape($science*2))
    Write-AtomicUtf8 $modelPath '{broken model'
    $script:LearnedModelCache=$null
    Check-Learning 'A damaged model is safely disabled without throwing' (-not (Get-LearnedModelStatus).Enabled)
    Write-AtomicUtf8 $modelPath $modelText
    $weakened=ConvertTo-LearnedMap ($modelText | ConvertFrom-Json)
    $weakened.Thresholds.MinEvidence=0
    Write-AtomicUtf8 $modelPath ($weakened | ConvertTo-Json -Depth 15 -Compress)
    $script:LearnedModelCache=$null
    Check-Learning 'A model cannot weaken the minimum evidence safety threshold' (-not (Get-LearnedModelStatus).Enabled)
    Write-AtomicUtf8 $modelPath $modelText
    $script:LearnedModelCache=$null
    $savedLocations=@{Root=$script:Root;IndexDir=$script:IndexDir;IndexDataDir=$script:IndexDataDir;IndexManifest=$script:IndexManifest}
    $script:Root=Join-Path $runDir 'filename-library'
    [void][IO.Directory]::CreateDirectory($script:Root)
    $script:IndexDir=Join-Path $script:AppDir 'filename-index'
    $script:IndexDataDir=Join-Path $script:IndexDir 'data'
    $script:IndexManifest=Join-Path $script:IndexDir 'manifest.json'
    Set-Item Function:\Get-FileText -Value $savedFileText
    for($i=0;$i -lt 3;$i++){
        $null=Put-Learning ('太阳发电\solar photon panel '+$i+'.customdoc') ('source-alpha-'+$i)
        $null=Put-Learning ('果园管理\garden seed soil '+$i+'.customdoc') ('source-beta-'+$i)
    }
    $null=Sync-LibraryIndex
    Set-Item Function:\Get-FileText -Value {throw 'Filename-only training must not extract bodies.'}
    $nameOnly=Train-LibraryClassifier
    Check-Learning 'Unknown document formats can train from informative filenames alone' ($nameOnly.Published -and @((Load-IndexEntries) | Where-Object hasText).Count -eq 0)
    $namePrediction=Get-LearnedClassification -Path 'solar photon panel.customdoc' -Text '' -TextProvided
    Check-Learning 'A filename-only model predicts a held-out filename category' ($namePrediction.Rule.name -eq '太阳发电')
    $script:Root=$savedLocations.Root;$script:IndexDir=$savedLocations.IndexDir;$script:IndexDataDir=$savedLocations.IndexDataDir;$script:IndexManifest=$savedLocations.IndexManifest

} catch{[void]$learningFailures.Add($_.Exception.ToString());Write-Output $_.ScriptStackTrace;Write-Output $_.Exception.ToString()}
finally{
    Set-Item Function:\Get-FileText -Value $savedFileText
    $report=@{Passed=$learningPassed;Failed=$learningFailures.Count;Failures=@($learningFailures.ToArray());Scratch=$runDir;Time=[datetime]::UtcNow.ToString('o')}
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'learned-results.json'),($report | ConvertTo-Json -Depth 5),$script:Utf8)
    Write-Output ('LEARNING passed='+$learningPassed+' failed='+$learningFailures.Count)
}
if($learningFailures.Count){exit 1}
