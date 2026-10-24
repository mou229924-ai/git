param([switch]$SkipRecycle, [string]$ScratchBase = '')
$ErrorActionPreference = 'Stop'
$sourceDir = Split-Path $PSScriptRoot -Parent
. (Join-Path $sourceDir 'lib.ps1')
$script:Passed = 0
$script:Failures = New-Object Collections.ArrayList
$tempBase=[IO.Path]::GetTempPath()
$productionVolume=[IO.Path]::GetPathRoot($script:Root)
$runBase=Join-Path $tempBase 'Nailong-code-tests'
if($productionVolume -ne [IO.Path]::GetPathRoot($tempBase)){$runBase=Join-Path $productionVolume '.Nailong.code-tests'}
if ($ScratchBase) { $runBase = $ScratchBase }
$runDir = Join-Path $runBase ([guid]::NewGuid().ToString('N'))
$scratchApp = Join-Path $runDir '_程序'
$scratchRoot = Join-Path $runDir 'library'
New-Item -ItemType Directory -Path $scratchApp,$scratchRoot,(Join-Path $scratchApp 'tests') -Force | Out-Null
$runtimeManifest = Join-Path $sourceDir 'application-files.json'
$runtimeFiles = [IO.File]::ReadAllText($runtimeManifest, $script:Utf8) | ConvertFrom-Json
foreach ($runtimeFile in $runtimeFiles) {
    $destination = Join-Path $scratchApp $runtimeFile
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceDir $runtimeFile) -Destination $destination
}
Copy-Item -LiteralPath $runtimeManifest -Destination $scratchApp
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $scratchApp 'tests\run-tests.ps1')
$script:AppDir = $scratchApp
$script:Root = $scratchRoot
$script:IndexDir = Join-Path $scratchApp '_index'
$script:IndexDataDir = Join-Path $script:IndexDir 'data'
$script:IndexManifest = Join-Path $script:IndexDir 'manifest.json'
$script:LogPath = Join-Path $scratchApp '_classifier.log'
$script:Cfg.inbox = $scratchRoot

function Check([string]$Label, [bool]$Condition) {
    if ($Condition) { $script:Passed++; Write-Output ('PASS ' + $Label) }
    else { [void]$script:Failures.Add($Label); Write-Output ('FAIL ' + $Label) }
}
function Put([string]$Relative, [string]$Text) {
    $p = Join-Path $script:Root $Relative
    New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($p, $Text, $script:Utf8)
    return $p
}
function PlanFor([string]$First, [string]$Second) {
    $hash = (Get-FileHash -LiteralPath $First -Algorithm SHA256).Hash
    return [pscustomobject]@{ Keep=$First; Duplicate=$Second; Hash=$hash; Size=(Get-Item -LiteralPath $First).Length }
}
function Stamp([string]$Directory) {
    $report = @{
        Passed=100; Failed=0; RecycleTest=$true; TestedVolume=[IO.Path]::GetPathRoot($script:Root)
        CodeHash=(Get-ApplicationCodeHash -Directory $Directory)
        TestHash=(Get-FileHash -LiteralPath (Join-Path $Directory 'tests\run-tests.ps1') -Algorithm SHA256).Hash
    }
    $report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Directory 'tests\verified.json') -Encoding UTF8
}

function Remove-CoreTestScratch {
    param([string]$Path,[string]$AllowedParent,[string]$Pattern)
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\');$parent=[IO.Path]::GetFullPath($AllowedParent).TrimEnd('\')
    if([IO.Path]::GetDirectoryName($full) -ne $parent -or [IO.Path]::GetFileName($full) -notmatch $Pattern){throw 'Unsafe safety-test cleanup target.'}
    $ancestor=New-Object IO.DirectoryInfo($parent)
    while($ancestor){if($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked safety-test parent.'};$ancestor=$ancestor.Parent}
    function Remove-CoreTestNode([string]$Node){
        $item=Get-Item -LiteralPath $Node -Force -ErrorAction Stop
        if($item.PSIsContainer){if(-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){foreach($child in @(Get-ChildItem -LiteralPath $Node -Force)){Remove-CoreTestNode $child.FullName}};[IO.Directory]::Delete($Node)}else{[IO.File]::Delete($Node)}
    }
    if(Test-Path -LiteralPath $full){Remove-CoreTestNode $full}
}

$published = Join-Path $sourceDir 'tests\verified.json'
if (Test-Path -LiteralPath $published) { Remove-Item -LiteralPath $published -Force }
try {
    Check 'No verification report keeps recycling disabled' (-not (Test-DedupeVerified))
    $a = Put 'exact\a.docx' 'same-content'
    $b = Put 'exact\b.docx' 'same-content'
    $c = Put 'exact\c.pdf' 'same-content'
    $different = Put 'different\a.pdf' 'other-content'
    $sameName = Put 'different\a.docx' 'word-original'
    $empty1 = Put 'empty\a.txt' ''
    $empty2 = Put 'empty\b.txt' ''
    $temp1 = Put '~WRL0002.tmp.docx' 'same-content'
    $temp2 = Put '~$lock.docx' 'same-content'
    $ignored = Put '_internal\copy.docx' 'same-content'
    $hidden = Put '.cache\copy.docx' 'same-content'
    $notDoc = Put 'private.pem' 'same-content'
    $plan = @(Find-DuplicateDocuments)
    Check 'Three identical documents produce exactly two extra copies' ($plan.Count -eq 2)
    Check 'Same name with different content is preserved' (@($plan | Where-Object Duplicate -eq $different).Count -eq 0 -and @($plan | Where-Object Duplicate -eq $sameName).Count -eq 0)
    Check 'Identical bytes across extensions are detected' (@($plan | Where-Object Duplicate -eq $c).Count -eq 1)
    Check 'Zero byte documents are excluded' (@($plan | Where-Object { $_.Duplicate -in @($empty1,$empty2) }).Count -eq 0)
    Check 'Office temporary files are excluded' (Test-IgnoredDocument $temp1)
    Check 'Office lock files are excluded' (Test-IgnoredDocument $temp2)
    Check 'Internal caches and non-documents are excluded' (@($plan | Where-Object { $_.Duplicate -in @($ignored,$hidden,$notDoc) }).Count -eq 0)
    $before = (Get-FileHash -LiteralPath $b).Hash
    $dryRun = @(Invoke-DuplicateCleanup -Plan $plan)
    Check 'Dry run returns proposed actions' ($dryRun.Count -eq 2)
    Check 'Dry run does not change or remove documents' ((Test-Path -LiteralPath $b) -and (Get-FileHash -LiteralPath $b).Hash -eq $before)
    $blocked = $false
    try { $null = Invoke-DuplicateCleanup -Plan $plan -Execute } catch { $blocked = $true }
    Check 'Execution is blocked before tests are verified' $blocked
    # Bootstrap only the isolated scratch installation. Production stays locked until all tests finish.
    Stamp $scratchApp
    Check 'Verification recognizes matching code and tests' (Test-DedupeVerified)
    [IO.File]::AppendAllText((Join-Path $scratchApp 'operations.ps1'), '# changed')
    Check 'Code changes invalidate verification' (-not (Test-DedupeVerified))
    Copy-Item -LiteralPath (Join-Path $sourceDir 'operations.ps1') -Destination $scratchApp -Force
    Check 'Restored tested code validates again' (Test-DedupeVerified)
    $handle = [IO.File]::Open($b,'Open','ReadWrite','Read')
    try {
        Check 'Files open for writing are not ready' (-not (Test-FileReady $b))
        Check 'Locked duplicate is omitted from scan' (@(Find-DuplicateDocuments | Where-Object Duplicate -eq $b).Count -eq 0)
        $lockedResult = @(Invoke-DuplicateCleanup -Plan @((PlanFor $a $b)) -Execute)
        Check 'Locked duplicate is not recycled' ($lockedResult[0].Status -eq 'skipped' -and (Test-Path -LiteralPath $b))
    } finally { $handle.Dispose() }
    Check 'Closed files are ready' (Test-FileReady $b)
    $modifiedPlan = PlanFor $a $b
    [IO.File]::WriteAllText($b,'changed-after-scan',$script:Utf8)
    $r = @(Invoke-DuplicateCleanup -Plan @($modifiedPlan) -Execute)
    Check 'Duplicate changed after scan is preserved' ($r[0].Status -eq 'skipped' -and (Test-Path -LiteralPath $b))
    [IO.File]::WriteAllText($b,'same-content',$script:Utf8)
    $modifiedPlan = PlanFor $a $b
    [IO.File]::WriteAllText($a,'retained-file-changed',$script:Utf8)
    $r = @(Invoke-DuplicateCleanup -Plan @($modifiedPlan) -Execute)
    Check 'Retained file changed after scan blocks deletion' ($r[0].Status -eq 'skipped' -and (Test-Path -LiteralPath $b))
    [IO.File]::WriteAllText($a,'same-content',$script:Utf8)
    $r = @(Invoke-DuplicateCleanup -Plan @((PlanFor $a $a)) -Execute)
    Check 'Retained file cannot be recycled as its own duplicate' ($r[0].Status -eq 'skipped' -and (Test-Path -LiteralPath $a))
    $missing = PlanFor $a $b; $missing.Keep = Join-Path $scratchRoot 'missing.docx'
    $r = @(Invoke-DuplicateCleanup -Plan @($missing) -Execute)
    Check 'Missing retained file blocks deletion' ($r[0].Status -eq 'skipped' -and (Test-Path -LiteralPath $b))
    $outside = Join-Path $runDir 'outside.docx'
    [IO.File]::WriteAllText($outside,'same-content',$script:Utf8)
    $r = @(Invoke-DuplicateCleanup -Plan @((PlanFor $a $outside)) -Execute)
    Check 'Paths outside library cannot be recycled' ($r[0].Status -eq 'skipped' -and (Test-Path -LiteralPath $outside))
    $r = @(Invoke-DuplicateCleanup -Plan @((PlanFor $a $ignored)) -Execute)
    Check 'Manually forged internal-cache plan is rejected' ($r[0].Status -eq 'skipped' -and (Test-Path -LiteralPath $ignored))
    $r = @(Invoke-DuplicateCleanup -Plan @((PlanFor $a $notDoc)) -Execute)
    Check 'Manually forged non-document plan is rejected' ($r[0].Status -eq 'skipped' -and (Test-Path -LiteralPath $notDoc))
    $wrongHash = PlanFor $a $b; $wrongHash.Hash = '0000'
    $r = @(Invoke-DuplicateCleanup -Plan @($wrongHash) -Execute)
    Check 'Invalid scan hash blocks deletion' ($r[0].Status -eq 'skipped' -and (Test-Path -LiteralPath $b))
    $wrongSize = PlanFor $a $b; $wrongSize.Size = 9999
    $r = @(Invoke-DuplicateCleanup -Plan @($wrongSize) -Execute)
    Check 'Invalid scan size blocks deletion' ($r[0].Status -eq 'skipped' -and (Test-Path -LiteralPath $b))
    $keepLockedPlan = PlanFor $a $b
    $keepLock = [IO.File]::Open($a,'Open','ReadWrite','Read')
    try {
        $r = @(Invoke-DuplicateCleanup -Plan @($keepLockedPlan) -Execute)
        Check 'Retained document open for writing blocks deletion' ($r[0].Status -eq 'skipped' -and (Test-Path -LiteralPath $b))
    } finally { $keepLock.Dispose() }
    $one = New-Object IO.MemoryStream(,[Text.Encoding]::UTF8.GetBytes('abcdef'))
    $two = New-Object IO.MemoryStream(,[Text.Encoding]::UTF8.GetBytes('abcdeg'))
    try { Check 'Byte comparison detects equal-length different content' (-not (Test-StreamsEqual $one $two)) }
    finally { $one.Dispose(); $two.Dispose() }
    $largeText = ('0123456789abcdef' * 8193)
    $large1 = New-Object IO.MemoryStream(,[Text.Encoding]::UTF8.GetBytes($largeText))
    $large2 = New-Object IO.MemoryStream(,[Text.Encoding]::UTF8.GetBytes($largeText))
    try { Check 'Byte comparison crosses multiple read buffers' (Test-StreamsEqual $large1 $large2) }
    finally { $large1.Dispose(); $large2.Dispose() }
    $junction = Join-Path $scratchRoot 'linked'
    New-Item -ItemType Junction -Path $junction -Target $runDir -ErrorAction Stop | Out-Null
    $r = @(Invoke-DuplicateCleanup -Plan @((PlanFor $a (Join-Path $junction 'outside.docx'))) -Execute)
    Check 'Junction paths are rejected and targets survive' ($r[0].Status -eq 'skipped' -and (Test-Path -LiteralPath $outside))
    Check 'Scanner does not recurse into junctions' (@(Get-LibraryFiles | Where-Object FullName -like '*\linked\*').Count -eq 0)
    if (-not $SkipRecycle) {
        $beforeFiles = @{}
        foreach ($file in @(Get-LibraryFiles)) { $beforeFiles[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName).Hash }
        $r = @(Invoke-DuplicateCleanup -Plan @((PlanFor $a $b)) -Execute)
        Check 'Real recycle operation succeeds' ($r[0].Status -eq 'recycled')
        Check 'Only selected duplicate disappears' (-not (Test-Path -LiteralPath $b) -and (Test-Path -LiteralPath $c))
        Check 'Retained document remains byte-identical' ((Test-Path -LiteralPath $a) -and (Get-FileHash -LiteralPath $a).Hash -eq $beforeFiles[$a])
        $unrelatedIntact = $true
        foreach ($file in $beforeFiles.Keys) { if ($file -ne $b -and (-not (Test-Path -LiteralPath $file) -or (Get-FileHash -LiteralPath $file).Hash -ne $beforeFiles[$file])) { $unrelatedIntact = $false } }
        Check 'Every unrelated document remains byte-identical' $unrelatedIntact
        $r = @(Invoke-DuplicateCleanup -Plan @((PlanFor $a $b)) -Execute)
        Check 'Repeated execution safely skips already recycled document' ($r[0].Status -eq 'skipped')
        $journal = Get-Content -LiteralPath (Join-Path $scratchApp '_dedupe-journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
        Check 'Recycle journal records pending and completed actions' (@($journal | Where-Object Status -eq 'pending').Count -ge 1 -and @($journal | Where-Object Status -eq 'recycled').Count -eq 1)
        $r = @(Invoke-DuplicateCleanup -Plan @((PlanFor $a $c)) -Execute)
        Check 'Cross-extension identical copy is recycled' ($r[0].Status -eq 'recycled' -and (Test-Path -LiteralPath $a))
    }
    if (-not $SkipRecycle) {
        $shell = New-Object -ComObject Shell.Application
        $recycleBin = $shell.NameSpace(10)
        $recycledItem = @($recycleBin.Items() | Where-Object {
            @('b','b.docx') -contains $_.Name -and ([string]$_.ExtendedProperty('System.Recycle.DeletedFrom')).TrimEnd('\') -eq (Split-Path $b -Parent).TrimEnd('\')
        }) | Select-Object -First 1
        Check 'Recycled document is present in Windows Recycle Bin' ($null -ne $recycledItem)
        if ($recycledItem) {
            $shell.NameSpace((Split-Path $b -Parent)).MoveHere($recycledItem, 20)
            for ($wait=0; $wait -lt 40 -and -not (Test-Path -LiteralPath $b); $wait++) { Start-Sleep -Milliseconds 100 }
            Check 'Recycled test document can be restored with identical bytes' ((Test-Path -LiteralPath $b) -and (Get-FileHash -LiteralPath $b).Hash -eq (Get-FileHash -LiteralPath $a).Hash)
        }
    }
    $journalPath = Join-Path $scratchApp '_dedupe-journal.jsonl'
    $journalBackup = $journalPath + '.test-backup'
    if (Test-Path -LiteralPath $journalPath) { Move-Item -LiteralPath $journalPath -Destination $journalBackup }
    New-Item -ItemType Directory -Path $journalPath | Out-Null
    try {
        $j1 = Put 'journal\a.txt' 'journal-identical'
        $j2 = Put 'journal\b.txt' 'journal-identical'
        $r = @(Invoke-DuplicateCleanup -Plan @((PlanFor $j1 $j2)) -Execute)
        Check 'Journal failure prevents recycling and preserves both files' ($r[0].Status -eq 'skipped' -and (Test-Path -LiteralPath $j1) -and (Test-Path -LiteralPath $j2))
    } finally {
        [IO.Directory]::Delete($journalPath)
        if (Test-Path -LiteralPath $journalBackup) { Move-Item -LiteralPath $journalBackup -Destination $journalPath }
    }
    $indexResult = Sync-LibraryIndex
    Check 'Index is populated' ($indexResult.Total -gt 0)
    $indexed = Put '数学\更新测试.txt' '函数 oldtoken'
    $null = Sync-LibraryIndex
    Check 'New document becomes searchable' (@(Search-Index -Query 'oldtoken').Count -eq 1)
    [IO.File]::WriteAllText($indexed,'函数 newer-token',$script:Utf8)
    $null = Sync-LibraryIndex
    Check 'Edited document search content refreshes' (@(Search-Index -Query 'newer-token').Count -eq 1 -and @(Search-Index -Query 'oldtoken').Count -eq 0)
    [IO.File]::Delete($indexed)
    $null = Sync-LibraryIndex
    Check 'Deleted document is removed from index' (@(Load-IndexEntries | Where-Object rel -eq '数学\更新测试.txt').Count -eq 0)
    $stampBefore = (Get-Item -LiteralPath $script:IndexManifest).LastWriteTimeUtc.Ticks
    $null = Sync-LibraryIndex
    Check 'Unchanged index is not rewritten' ((Get-Item -LiteralPath $script:IndexManifest).LastWriteTimeUtc.Ticks -eq $stampBefore)
    $top1 = Put 'rank\a.txt' 'target'
    $top2 = Put 'rank\target.txt' 'other'
    $null = Sync-LibraryIndex
    Check 'Search ranks all candidates before applying limit' (@(Search-Index -Query 'target' -Limit 1)[0].full -eq $top2)
    $desktopTestDir = Join-Path $tempBase ('nailong-desktop-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $desktopTestDir -Force | Out-Null
    $source = Join-Path $desktopTestDir 'desktop.txt'
    [IO.File]::WriteAllText($source,'import-unique',$script:Utf8)
    $null = Put 'desktop.txt' 'existing'
    $imported = @(Import-LibraryItems @($source))
    Check 'Dragged file is moved into the library' ($imported[0].Success -and -not (Test-Path -LiteralPath $source) -and (Test-Path -LiteralPath $imported[0].Target))
    Check 'Import avoids overwriting same-name files' (([IO.File]::ReadAllText((Join-Path $scratchRoot 'desktop.txt'))) -eq 'existing' -and [IO.File]::ReadAllText($imported[0].Target) -eq 'import-unique')
    $imported = @(Import-LibraryItems @($a))
    Check 'Importing existing library document leaves it intact' (-not $imported[0].Success -and (Test-Path -LiteralPath $a))
    $workerPath = Join-Path $PSScriptRoot 'index-worker.ps1'
    $workerArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $workerPath + '" -SourceDir "' + $sourceDir + '" -Root "' + $scratchRoot + '" -AppDir "' + $scratchApp + '" -Worker '
    $p1 = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ($workerArgs + 'A') -PassThru
    $p2 = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ($workerArgs + 'B') -PassThru
    $validJson = $true
    $deadline = (Get-Date).AddSeconds(30)
    while ((-not $p1.HasExited -or -not $p2.HasExited) -and (Get-Date) -lt $deadline) {
        try { $null = (Read-AtomicUtf8 $script:IndexManifest) | ConvertFrom-Json } catch { $validJson = $false; Write-Output ('CONCURRENT READ ERROR: '+$_.Exception.Message) }
        Start-Sleep -Milliseconds 20
    }
    Check 'Parallel index writers finish successfully' ($p1.HasExited -and $p2.HasExited -and $p1.ExitCode -eq 0 -and $p2.ExitCode -eq 0)
    Check 'Readers never observe partially written index JSON' $validJson
    Check 'Concurrent writers preserve all sixteen document entries' (@(Load-IndexEntries | Where-Object name -like 'worker-*.txt').Count -eq 16)
    $p1.Dispose(); $p2.Dispose()
    . (Join-Path $sourceDir 'classifier-scan.ps1')
    Check 'Different-length subject keywords are ambiguous' ((Get-FilenameDecision '物理与信息技术综合资料').Ambiguous)
    Check 'Another mixed-subject filename is ambiguous' ((Get-FilenameDecision '历史与自然地理综合练习').Ambiguous)
    Check 'Unambiguous filename classification still works' ((Get-FilenameDecision '2026物理试卷').Rule.name -eq '物理')
    $oldConfigPath=$script:ConfigPath
    $script:ConfigPath=Join-Path $scratchApp 'config.json'
    $script:Cfg.inbox=$script:Root
    Write-AtomicUtf8 $script:ConfigPath ($script:Cfg | ConvertTo-Json -Depth 12)
    $customDirectory=Save-LibraryDirectory -Name '工作资料' -FilenameKeywords @('合同','报告') -ContentKeywords @('发票','报销')
    Check 'Custom directory is created' (Test-Path -LiteralPath $customDirectory -PathType Container)
    Check 'Custom filename keyword classifies into user directory' ((Get-FilenameDecision '年度合同').Rule.name -eq '工作资料')
    Check 'Saved custom directory appears in directory choices' (@(Get-DirectoryChoices) -contains '工作资料')
    $null=Save-LibraryDirectory -Name '工作资料' -FilenameKeywords @('协议') -ContentKeywords @('发票')
    Check 'Updating a directory replaces its keywords without duplicate rules' (@($script:Cfg.subjects | Where-Object name -eq '工作资料').Count -eq 1 -and (Get-FilenameDecision '协议书').Rule.name -eq '工作资料' -and $null -eq (Get-FilenameDecision '年度合同'))
    $invalidDirectory=$false
    try { $null=Save-LibraryDirectory -Name '..\escape' -FilenameKeywords @() -ContentKeywords @() } catch { $invalidDirectory=$true }
    Check 'Custom directory cannot escape library' $invalidDirectory
    $nested=Put '工作资料\2026\协议.txt' 'invoice custom'
    $oldFile=Put '工作资料\old.txt' 'date-filter-needle'
    $newFile=Put '工作资料\new.txt' 'date-filter-needle'
    [IO.File]::SetLastWriteTime($oldFile,[datetime]::Today.AddDays(-40))
    $null=Sync-LibraryIndex
    Check 'Nested-directory search stays within selected directory' (@(Search-Index -Query '' -Subject '工作资料\2026').Count -eq 1)
    Check 'Date filter excludes older documents' (@(Search-Index -Query 'date-filter-needle' -ModifiedSince ([datetime]::Today.AddDays(-6))).Count -eq 1)
    Check 'Extension filter excludes other formats' (@(Search-Index -Query 'date-filter-needle' -Extensions @('.pdf')).Count -eq 0)
    $sorted=@(Search-Index -Query 'date-filter-needle' -SortKey 'mtimeTicks')
    Check 'Modification time descending sort puts newest first' ($sorted[0].full -eq $newFile)
    $sorted=@(Search-Index -Query 'date-filter-needle' -SortKey 'mtimeTicks' -Descending $false)
    Check 'Modification time ascending sort puts oldest first' ($sorted[0].full -eq $oldFile)
    Check 'Negative keyword excludes matching documents' (@(Search-Index -Query 'date-filter-needle -old').Count -eq 1)
    $phraseFile=Put '工作资料\phrase.txt' 'a quoted phrase sample'
    $null=Sync-LibraryIndex
    Check 'Quoted phrase search preserves spaces' (@(Search-Index -Query '"quoted phrase"').Count -eq 1)
    $conflict=Put '物理试题.txt' ('化学 化学 化学 化学 溶液 氧气')
    $classification=Get-DocumentClassification $conflict
    Check 'Filename and body conflict requires manual choice' ($classification.Decision.Ambiguous -and $classification.How -eq 'conflict')
    $renameSource=Put '工作资料\before.txt' 'rename-content'
    $null=Sync-LibraryIndex
    $renamed=Rename-LibraryFile -Path $renameSource -NewName 'after.txt'
    Check 'Rename preserves bytes and removes old path' ((Test-Path -LiteralPath $renamed) -and -not (Test-Path -LiteralPath $renameSource) -and [IO.File]::ReadAllText($renamed) -eq 'rename-content')
    Check 'Rename refreshes search index' (@(Search-Index -Query 'after.txt').Count -eq 1 -and @(Search-Index -Query 'before.txt').Count -eq 0)
    $collision=Put '工作资料\collision.txt' 'keep-collision'
    $renameBlocked=$false
    try { $null=Rename-LibraryFile -Path $renamed -NewName 'collision.txt' } catch { $renameBlocked=$true }
    Check 'Rename refuses to overwrite existing file' ($renameBlocked -and [IO.File]::ReadAllText($collision) -eq 'keep-collision')
    $renameBlocked=$false
    try { $null=Rename-LibraryFile -Path $renamed -NewName '..\escape.txt' } catch { $renameBlocked=$true }
    Check 'Rename refuses path traversal' $renameBlocked
    $exportDir=Join-Path $desktopTestDir 'exported'
    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $exportDir 'after.txt'),'existing-desktop',$script:Utf8)
    $exported=@(Export-LibraryFiles -Paths @($renamed) -Destination $exportDir)
    Check 'Move out preserves existing desktop file and moves selected document' ($exported[0].Success -and -not (Test-Path -LiteralPath $renamed) -and [IO.File]::ReadAllText((Join-Path $exportDir 'after.txt')) -eq 'existing-desktop' -and [IO.File]::ReadAllText($exported[0].Target) -eq 'rename-content')
    Check 'Moved-out document is removed from library index' (@(Search-Index -Query 'after.txt').Count -eq 0)
    $savedCapability=(Get-Command Get-PrintFileCapability).ScriptBlock
    $savedPrint=(Get-Command Start-DocumentPrint).ScriptBlock
    $script:PrintCalls=0
    try {
        function Get-PrintFileCapability { param([string]$Path) [pscustomobject]@{ Path=$Path; Supported=([IO.Path]::GetExtension($Path) -eq '.txt'); Error='unsupported in test' } }
        function Start-DocumentPrint { param([string]$Path) $script:PrintCalls++; if ([IO.Path]::GetFileName($Path) -eq 'collision.txt') { throw 'simulated print handler failure' } }
        $printPlan=@(Invoke-BatchPrint -Paths @($oldFile,$oldFile,$notDoc))
        Check 'Print planning deduplicates selection and sends no actual jobs' ($printPlan.Count -eq 2 -and $script:PrintCalls -eq 0)
        $printResult=@(Invoke-BatchPrint -Paths @($oldFile,$collision,$notDoc) -Execute)
        Check 'Batch print reports submitted and failed files independently' (@($printResult | Where-Object Status -eq 'submitted').Count -eq 1 -and @($printResult | Where-Object Status -eq 'skipped').Count -eq 2)
        Check 'Unsupported print formats never invoke print handler' ($script:PrintCalls -eq 2)
    } finally {
        Set-Item Function:\Get-PrintFileCapability -Value $savedCapability
        Set-Item Function:\Start-DocumentPrint -Value $savedPrint
    }
    $script:ConfigPath=$oldConfigPath
    $script:Root = Join-Path $runDir 'import-classify-flow'
    New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
    $script:IndexDir = Join-Path $scratchApp 'flow-index'
    $script:IndexDataDir = Join-Path $script:IndexDir 'data'
    $script:IndexManifest = Join-Path $script:IndexDir 'manifest.json'
    $script:States=@{}; $script:Skip=@{}; $script:Defer=@{}; $script:FolderStates=@{}; $script:FolderSkip=@{}; $script:Busy=$false
    $script:IgnoreNames=@($script:Cfg.ignoreFiles) + @($script:Cfg.subjects | ForEach-Object { [string]$_.name }) + @([string]$script:Cfg.otherFolderName)
    $script:IgnoreExts=@($script:Cfg.ignoreExtensions)
    $flowSource = Join-Path $desktopTestDir '物理试卷.txt'
    [IO.File]::WriteAllText($flowSource,'physics-identical-test',$script:Utf8)
    $flowImport = @(Import-LibraryItems @($flowSource))
    Check 'Import flow accepts desktop file' ($flowImport[0].Success)
    $null = Put '物理试卷副本.txt' 'physics-identical-test'
    $flowTemp = Put '~WRL0002.tmp.docx' 'physics-identical-test'
    Scan-Once
    Check 'Newly imported files wait for stability before moving' (Test-Path -LiteralPath (Join-Path $script:Root '物理试卷.txt'))
    Scan-Once
    Scan-Once
    $flowKeep = Join-Path $script:Root '物理\物理试卷.txt'
    $flowCopy = Join-Path $script:Root '物理\物理试卷副本.txt'
    Check 'Imported files are automatically classified into target directory' ((Test-Path -LiteralPath $flowKeep) -and (Test-Path -LiteralPath $flowCopy))
    Check 'Classifier leaves Word temporary documents untouched' (Test-Path -LiteralPath $flowTemp)
    Check 'Classified imported document is searchable' (@(Search-Index -Query '物理试卷').Count -eq 2)
    if (-not $SkipRecycle) {
        $flowPlan = @(Find-DuplicateDocuments)
        $flowResult = @(Invoke-DuplicateCleanup -Plan $flowPlan -Execute)
        Check 'Import-classify-dedupe flow recycles exactly one extra copy' ($flowPlan.Count -eq 1 -and @($flowResult | Where-Object Status -eq 'recycled').Count -eq 1)
        Check 'Repeated automatic dedupe scan proposes no further deletions' (@(Find-DuplicateDocuments).Count -eq 0)
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $sourceDir -Filter *.ps1) + @(Get-ChildItem -LiteralPath (Join-Path $sourceDir 'tests') -Filter *.ps1)) {
        $tokens=$null; $syntaxErrors=$null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$syntaxErrors)
        Check ('Syntax: ' + $file.Name) (@($syntaxErrors).Count -eq 0)
    }
} catch { [void]$script:Failures.Add($_.Exception.ToString()); Write-Output $_.ScriptStackTrace; Write-Output $_.Exception.ToString() }
finally {
    if($script:Failures.Count -eq 0){
        try{
            Remove-CoreTestScratch -Path $runDir -AllowedParent $runBase -Pattern '^[a-f0-9]{32}$'
            if($desktopTestDir){Remove-CoreTestScratch -Path $desktopTestDir -AllowedParent $tempBase -Pattern '^nailong-desktop-[a-f0-9]{32}$'}
        }catch{[void]$script:Failures.Add('Scratch cleanup: '+$_.Exception.Message)}
    }
    $report = @{
        Passed=$script:Passed; Failed=$script:Failures.Count; Failures=@($script:Failures.ToArray())
        Time=(Get-Date).ToString('o'); Scratch=$runDir; RecycleTest=(-not $SkipRecycle); TestedVolume=[IO.Path]::GetPathRoot($scratchRoot)
        CrossVolumeTest=([IO.Path]::GetPathRoot($scratchRoot) -ne [IO.Path]::GetPathRoot($desktopTestDir))
        CodeHash=(Get-ApplicationCodeHash -Directory $sourceDir)
        TestHash=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'test-results.json') -Encoding UTF8
    if ($report.Failed -eq 0 -and -not $SkipRecycle) { $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $published -Encoding UTF8 }
    Write-Output ('TOTAL passed=' + $report.Passed + ' failed=' + $report.Failed)
}
if ($script:Failures.Count) { exit 1 }
