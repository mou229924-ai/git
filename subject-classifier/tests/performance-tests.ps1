param([int]$DocumentCount=3205)
$ErrorActionPreference='Stop'
$sourceDir=Split-Path $PSScriptRoot -Parent
. (Join-Path $sourceDir 'lib.ps1')
$runDir=Join-Path $sourceDir ('test-runs\performance-'+[guid]::NewGuid().ToString('N'))
$scratchApp=Join-Path $runDir 'app'
$scratchRoot=Join-Path $runDir 'library'
[void][IO.Directory]::CreateDirectory($scratchApp)
[void][IO.Directory]::CreateDirectory($scratchRoot)
$runtimeFiles=[IO.File]::ReadAllText((Join-Path $sourceDir 'application-files.json'),$script:Utf8) | ConvertFrom-Json
foreach($runtimeFile in $runtimeFiles){
    $destination=Join-Path $scratchApp $runtimeFile
    [void][IO.Directory]::CreateDirectory((Split-Path $destination -Parent))
    Copy-Item -LiteralPath (Join-Path $sourceDir $runtimeFile) -Destination $destination
}
Copy-Item -LiteralPath (Join-Path $sourceDir 'application-files.json') -Destination $scratchApp
$script:AppDir=$scratchApp
$script:Root=$scratchRoot
$script:IndexDir=Join-Path $scratchApp '_index'
$script:IndexDataDir=Join-Path $script:IndexDir 'data'
$script:IndexManifest=Join-Path $script:IndexDir 'manifest.json'
$script:LogPath=Join-Path $scratchApp '_classifier.log'
$script:ConfigPath=Join-Path $scratchApp 'config.json'
$script:Cfg.inbox=$scratchRoot
Write-AtomicUtf8 $script:ConfigPath ($script:Cfg | ConvertTo-Json -Depth 15)
$script:SearchTextCache=@{}
$script:IndexTextCacheBytes=0
$performancePassed=0
$performanceFailures=New-Object Collections.ArrayList
function Check-Performance([string]$Name,[bool]$Condition){
    if($Condition){$script:performancePassed++;Write-Output ('PASS '+$Name)}else{[void]$script:performanceFailures.Add($Name);Write-Output ('FAIL '+$Name)}
}
$savedLibraryFiles=(Get-Command Get-LibraryFiles).ScriptBlock
$savedFileText=(Get-Command Get-FileText).ScriptBlock
try{
    $documents=Join-Path $scratchRoot 'documents'
    [void][IO.Directory]::CreateDirectory($documents)
    $body='shared-body-needle '+('compressible text '+('sample '*12)+' ')*64
    for($i=0;$i -lt $DocumentCount;$i++){
        [IO.File]::WriteAllText((Join-Path $documents ('page-'+$i.ToString('D5')+'.txt')),$body,$script:Utf8)
    }
    $initial=Sync-LibraryIndex
    Check-Performance 'Initial snapshot indexes more than 3000 documents' ($initial.Total -eq $DocumentCount -and $DocumentCount -gt 3000)
    $seen=@{}
    for($offset=0;$offset -lt $DocumentCount;$offset+=200){
        $page=Search-Index -Query 'page-' -IncludeContent $false -SortKey name -Descending $false -AsPage -Offset $offset -Limit 200
        foreach($result in $page.Results){$seen[$result.rel]=$true}
        if($page.TotalMatches -ne $DocumentCount){throw 'Incorrect paging total.'}
    }
    Check-Performance 'Paging reaches every result beyond the former 3000 cutoff' ($seen.Count -eq $DocumentCount)
    $tail=Search-Index -Query 'page-' -IncludeContent $false -AsPage -Offset 3200 -Limit 200
    Check-Performance 'Last page reports exact total and no further page' ($tail.TotalMatches -eq $DocumentCount -and $tail.Results.Count -eq ($DocumentCount-3200) -and -not $tail.HasMore)
    Check-Performance 'Legacy array calls still honor an explicit limit' (@(Search-Index -Query 'page-' -IncludeContent $false -Limit 7).Count -eq 7)
    Check-Performance 'An unlimited call has no hidden result cap' (@(Search-Index -Query 'page-' -IncludeContent $false -Limit 0).Count -eq $DocumentCount)
    $unannounced=Join-Path $scratchRoot 'unannounced.txt'
    [IO.File]::WriteAllText($unannounced,'unannounced-needle',$script:Utf8)
    Set-Item Function:\Get-LibraryFiles -Value {throw 'Unexpected full-tree enumeration.'}
    Set-Item Function:\Get-FileText -Value {throw 'Unexpected body extraction.'}
    $stamp=(Get-Item -LiteralPath $script:IndexManifest).LastWriteTimeUtc.Ticks
    $page=Search-Index -Query 'page-' -IncludeContent $false -AsPage -Limit 20
    Check-Performance 'Search reads a snapshot without enumerating or extracting files' ($page.TotalMatches -eq $DocumentCount)
    Check-Performance 'Unannounced files remain outside the snapshot until indexing' (@(Search-Index -Query 'unannounced-needle').Count -eq 0)
    $unchanged=Sync-LibraryIndex -Incremental
    Check-Performance 'Unchanged incremental maintenance skips full-tree enumeration' (-not $unchanged.FullReconcile -and -not $unchanged.Changed -and (Get-Item -LiteralPath $script:IndexManifest).LastWriteTimeUtc.Ticks -eq $stamp)
    Set-Item Function:\Get-FileText -Value $savedFileText
    $before=Join-Path $documents 'page-00001.txt'
    $after=Join-Path $documents 'renamed-paper.txt'
    [IO.File]::Move($before,$after)
    Request-IndexRefresh -Paths @($before,$after,$unannounced)
    $rename=Sync-LibraryIndex -Incremental
    Check-Performance 'A queued rename updates only affected paths' (-not $rename.FullReconcile -and @(Search-Index -Query 'page-00001').Count -eq 0 -and @(Search-Index -Query 'renamed-paper').Count -eq 1)
    $deleted=Join-Path $documents 'page-00002.txt'
    [IO.File]::Delete($deleted)
    Request-IndexRefresh -Paths @($deleted)
    $null=Sync-LibraryIndex -Incremental
    Check-Performance 'A queued deletion removes its snapshot entry' (@(Search-Index -Query 'page-00002').Count -eq 0)
    $crossPath=Join-Path $scratchRoot 'cross-process.txt'
    [IO.File]::WriteAllText($crossPath,'cross-process-queue-needle',$script:Utf8)
    $producer=Join-Path $scratchApp 'queue-producer.ps1'
    $producerCode=@'
param([string]$App,[string]$Document)
$ErrorActionPreference='Stop'
. (Join-Path $App 'lib.ps1')
Request-IndexRefresh -Paths @($Document)
'@
    [IO.File]::WriteAllText($producer,$producerCode,[Text.Encoding]::UTF8)
    $process=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy RemoteSigned -File "'+$producer+'" -App "'+$scratchApp+'" -Document "'+$crossPath+'"') -PassThru
    if(-not $process.WaitForExit(15000)){ $process.Kill();throw 'Queue producer timed out.' }
    Check-Performance 'A separate process can persist an invalidation batch' ($process.ExitCode -eq 0)
    $process.Dispose()
    $null=Sync-LibraryIndex -Incremental
    Check-Performance 'Incremental maintenance consumes another process change batch' (@(Search-Index -Query 'cross-process-queue-needle').Count -eq 1)
    Set-Item Function:\Get-LibraryFiles -Value $savedLibraryFiles
    $nestedBefore=Join-Path $scratchRoot 'nested-before'
    $nestedAfter=Join-Path $scratchRoot 'nested-after'
    [void][IO.Directory]::CreateDirectory($nestedBefore)
    [IO.File]::WriteAllText((Join-Path $nestedBefore 'child.txt'),'nested-subtree-needle',$script:Utf8)
    Request-IndexRefresh -Paths @($nestedBefore)
    $null=Sync-LibraryIndex -Incremental
    [IO.Directory]::Move($nestedBefore,$nestedAfter)
    Request-IndexRefresh -Paths @($nestedBefore,$nestedAfter)
    $directoryResult=Sync-LibraryIndex -Incremental
    Check-Performance 'A directory rename reconciles only its old and new subtrees' (-not $directoryResult.FullReconcile -and @(Search-Index -Query 'nested-subtree-needle' -Subject 'nested-after').Count -eq 1 -and @(Search-Index -Query 'nested-subtree-needle' -Subject 'nested-before').Count -eq 0)
    [IO.File]::Delete((Join-Path $nestedAfter 'child.txt'))
    [IO.Directory]::Delete($nestedAfter)
    Request-IndexRefresh -Paths @($nestedAfter)
    $null=Sync-LibraryIndex -Incremental
    Check-Performance 'A deleted directory removes all stale descendant entries' (@(Search-Index -Query 'nested-subtree-needle').Count -eq 0)
    $legacy=Join-Path $scratchRoot 'legacy.txt'
    $legacyText='legacy-migration-needle '+('old cache text '*2000)
    [IO.File]::WriteAllText($legacy,$legacyText,$script:Utf8)
    $legacyFile=Get-Item -LiteralPath $legacy
    $legacyId=Get-IndexId 'legacy.txt'
    $plain=Join-Path $script:IndexDataDir ($legacyId+'.txt')
    [IO.File]::WriteAllText($plain,$legacyText,$script:Utf8)
    $legacyEntry=[pscustomobject]@{id=$legacyId;rel='legacy.txt';name='legacy.txt';subject='未分类';size=$legacyFile.Length;mtime=$legacyFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss');mtimeTicks=$legacyFile.LastWriteTime.Ticks;hasText=$true}
    Invoke-IndexLock {$existing=@(Load-IndexEntries);$null=Save-IndexEntries -Entries @($existing+$legacyEntry)}
    Check-Performance 'Old plain-text index bodies remain searchable' (@(Search-Index -Query 'legacy-migration-needle').Count -eq 1)
    Set-Item Function:\Get-FileText -Value {throw 'Migration must reuse cached text.'}
    $null=Sync-LibraryIndex
    Set-Item Function:\Get-FileText -Value $savedFileText
    $migrated=@(Load-IndexEntries | Where-Object rel -eq 'legacy.txt')[0]
    Check-Performance 'Legacy bodies migrate to gzip without reopening documents' ($migrated.textKey -match '^[a-f0-9]{64}$' -and [IO.File]::Exists((Get-IndexContentPath $migrated)))
    Check-Performance 'Migration preserves full-text search and removes old bodies' (@(Search-Index -Query 'legacy-migration-needle').Count -eq 1 -and -not [IO.File]::Exists($plain))
    $cacheFiles=@(Get-ChildItem -LiteralPath $script:IndexDataDir -File -Filter '*.gz')
    $compressedBytes=($cacheFiles | Measure-Object Length -Sum).Sum
    $sourceBytes=($DocumentCount*$script:Utf8.GetByteCount($body))+$script:Utf8.GetByteCount($legacyText)
    Check-Performance 'Shared compressed bodies use less than one tenth of raw text space' ($compressedBytes -lt ($sourceBytes/10) -and $cacheFiles.Count -lt 10)
    Check-Performance 'Manifest stores compact metadata without document bodies' ((Read-AtomicUtf8 $script:IndexManifest) -notmatch '[\r\n]' -and (Read-AtomicUtf8 $script:IndexManifest) -notmatch 'shared-body-needle')
    $orphan=Join-Path $script:IndexDataDir (('0'*64)+'.gz')
    [IO.File]::WriteAllText($orphan,'orphan cache',$script:Utf8)
    $lease=Open-IndexReadLease
    try{$null=Invoke-IndexLock {Remove-OrphanIndexContent -Entries @(Load-IndexEntries)};Check-Performance 'Active searches protect bodies referenced by an older snapshot' ([IO.File]::Exists($orphan))}finally{Close-IndexReadLease $lease}
    $null=Invoke-IndexLock {Remove-OrphanIndexContent -Entries @(Load-IndexEntries)}
    Check-Performance 'Orphan cache objects are removed after readers finish' (-not [IO.File]::Exists($orphan))
    Start-IndexChangeMonitor
    $initialEvents=Flush-IndexChangeMonitor
    Check-Performance 'Monitor startup requests a reconciliation for offline changes' ($initialEvents -ge 1)
    $null=Sync-LibraryIndex -Incremental
    $watched=Join-Path $scratchRoot 'watched.txt'
    [IO.File]::WriteAllText($watched,'watcher-event-needle',$script:Utf8)
    $events=0;$deadline=[datetime]::UtcNow.AddSeconds(8)
    do{Start-Sleep -Milliseconds 100;$events+=Flush-IndexChangeMonitor}while($events -eq 0 -and [datetime]::UtcNow -lt $deadline)
    $null=Sync-LibraryIndex -Incremental
    Check-Performance 'Watcher events become incremental searchable changes' ($events -gt 0 -and @(Search-Index -Query 'watcher-event-needle').Count -eq 1)
    Check-Performance 'Watcher flush returns zero when nothing changed' ((Flush-IndexChangeMonitor) -eq 0)
    $statePath=Join-Path $script:IndexDir 'state.json'
    $state=(Read-AtomicUtf8 $statePath) | ConvertFrom-Json
    $state.LastFullUtc=[datetime]::UtcNow.AddMinutes(-6).ToString('o')
    Write-AtomicUtf8 $statePath ($state | ConvertTo-Json -Compress)
    $periodic=Sync-LibraryIndex -Incremental
    Check-Performance 'Expired snapshots receive the five-minute full reconciliation' $periodic.FullReconcile

} catch{[void]$performanceFailures.Add($_.Exception.ToString());Write-Output $_.ScriptStackTrace;Write-Output $_.Exception.ToString()}
finally{
    Stop-IndexChangeMonitor
    Set-Item Function:\Get-LibraryFiles -Value $savedLibraryFiles
    Set-Item Function:\Get-FileText -Value $savedFileText
    $report=@{Passed=$performancePassed;Failed=$performanceFailures.Count;Failures=@($performanceFailures.ToArray());Scratch=$runDir;Time=[datetime]::UtcNow.ToString('o')}
    Write-AtomicUtf8 (Join-Path $PSScriptRoot 'performance-results.json') ($report | ConvertTo-Json -Depth 5)
    Write-Output ('PERFORMANCE passed='+$performancePassed+' failed='+$performanceFailures.Count)
}
if($performanceFailures.Count){exit 1}
