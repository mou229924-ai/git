param([string]$SourceDir='',[string]$RuntimeDirectory='',[string]$ScratchBase='')
$ErrorActionPreference='Stop'
if(-not $SourceDir){$SourceDir=Split-Path $PSScriptRoot -Parent}
if(-not $RuntimeDirectory){$RuntimeDirectory=$SourceDir}
$SourceDir=[IO.Path]::GetFullPath($SourceDir);$RuntimeDirectory=[IO.Path]::GetFullPath($RuntimeDirectory)
if(-not $ScratchBase){$ScratchBase=Join-Path ([IO.Path]::GetTempPath()) 'Nailong-observability-tests'}
$runDir=Join-Path $ScratchBase ('observability-'+[guid]::NewGuid().ToString('N'))
$script:AppDir=Join-Path $runDir 'app';$script:Root=Join-Path $runDir 'library'
$desktop=Join-Path $runDir 'desktop';$exported=Join-Path $runDir 'exported'
foreach($directory in @($script:AppDir,$script:Root,$desktop,$exported)){[void][IO.Directory]::CreateDirectory($directory)}
$script:Utf8=New-Object Text.UTF8Encoding($false)
$script:Cfg=[IO.File]::ReadAllText((Join-Path $SourceDir 'config.example.json'),$script:Utf8) | ConvertFrom-Json
$script:Cfg.inbox=$script:Root
$script:IndexDir=Join-Path $script:AppDir '_index';$script:IndexDataDir=Join-Path $script:IndexDir 'data';$script:IndexManifest=Join-Path $script:IndexDir 'manifest.json'
$script:LogPath=Join-Path $script:AppDir '_test.log';$script:SearchTextCache=@{};$script:ApplicationLogState=@{}
# No app initialization, real profile config, printer or deletion verification report is used.
. (Join-Path $SourceDir 'index-content.ps1')
. (Join-Path $SourceDir 'index-store.ps1')
. (Join-Path $RuntimeDirectory 'operations.ps1')
. (Join-Path $RuntimeDirectory 'features.ps1')
. (Join-Path $RuntimeDirectory 'observability.ps1')
$script:obsPassed=0;$script:obsFailures=New-Object Collections.ArrayList
function Check-Obs([string]$Name,[bool]$Condition){if($Condition){$script:obsPassed++;Write-Output ('PASS '+$Name)}else{[void]$script:obsFailures.Add($Name);Write-Output ('FAIL '+$Name)}}
function Put-Obs([string]$Directory,[string]$Name,[string]$Text){$file=Join-Path $Directory $Name;[IO.File]::WriteAllText($file,$Text,$script:Utf8);return $file}
function Remove-ObservabilityScratch {
    param([string]$Path,[string]$AllowedParent)
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\');$parent=[IO.Path]::GetFullPath($AllowedParent).TrimEnd('\')
    if([IO.Path]::GetDirectoryName($full) -ne $parent -or [IO.Path]::GetFileName($full) -notmatch '^observability-[a-f0-9]{32}$'){throw 'Unsafe observability-test cleanup target.'}
    $ancestor=New-Object IO.DirectoryInfo($parent)
    while($ancestor){if($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked observability-test parent.'};$ancestor=$ancestor.Parent}
    function Remove-ObservabilityNode([string]$Node){
        $nodeFull=[IO.Path]::GetFullPath($Node)
        if($nodeFull -ne $full -and -not $nodeFull.StartsWith($full+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Scratch child escaped the test tree.'}
        $item=Get-Item -LiteralPath $nodeFull -Force -ErrorAction Stop
        if($item.PSIsContainer){
            if(-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){foreach($child in @(Get-ChildItem -LiteralPath $nodeFull -Force)){Remove-ObservabilityNode $child.FullName}}
            [IO.Directory]::Delete($nodeFull)
        }else{[IO.File]::Delete($nodeFull)}
    }
    if(Test-Path -LiteralPath $full){Remove-ObservabilityNode $full}
}
function Reset-ObsProgress {$script:obsProgress=New-Object Collections.ArrayList;$script:obsCancel=$false}
function Test-ObsProgress([int]$Count,[string]$Operation){
    if($script:obsProgress.Count -ne ($Count+1)){return $false}
    for($i=0;$i -le $Count;$i++){if($script:obsProgress[$i].Done -ne $i -or $script:obsProgress[$i].Total -lt $Count -or $script:obsProgress[$i].Operation -ne $Operation){return $false}}
    return $true
}
$progress={param($done,$total,$name,$operation)[void]$script:obsProgress.Add(@{Done=$done;Total=$total;Name=$name;Operation=$operation})}
$cancelAfterOne={param($done,$total,$name,$operation)[void]$script:obsProgress.Add(@{Done=$done;Total=$total;Name=$name;Operation=$operation});if($done -ge 1){$script:obsCancel=$true}}
$shouldCancel={return $script:obsCancel}
$originalCapability=(Get-Command Get-PrintFileCapability).ScriptBlock
$originalPrint=(Get-Command Start-DocumentPrint).ScriptBlock
try{
    Write-Log 'TICK ERROR actual-failure'
    for($i=0;$i -lt 6;$i++){Write-Log 'TICK ERROR actual-failure'}
    $before=@([IO.File]::ReadAllLines($script:LogPath))
    Check-Obs 'A real error is logged immediately and repeated rows are throttled' ($before.Count -eq 1 -and $before[0] -match '\[ERROR\]' -and $before[0] -match 'actual-failure')
    Flush-ApplicationLogs -Force
    $after=@([IO.File]::ReadAllLines($script:LogPath))
    Check-Obs 'Flush reports suppressed occurrences and the cumulative total' ($after.Count -eq 2 -and $after[1] -match '本轮重复 6 次，累计 7 次')
    Flush-ApplicationLogs -Force
    Check-Obs 'Repeated flushing never reports the same suppression twice' (@([IO.File]::ReadAllLines($script:LogPath)).Count -eq 2)
    Write-Log 'OTHER ERROR separate-failure'
    Check-Obs 'An unrelated error is never hidden by another error throttle' (@([IO.File]::ReadAllLines($script:LogPath)).Count -eq 3)
    $busy=New-Object TimeoutException('资料库正在处理文件，请稍后重试。');$busy.Data['LibraryBusy']=$true
    for($i=0;$i -lt 3;$i++){Write-Log 'TICK ERROR busy' -Exception $busy}
    Flush-ApplicationLogs -Force
    $busyRows=@([IO.File]::ReadAllLines($script:LogPath) | Where-Object {$_ -match 'BUSY'})
    Check-Obs 'Expected lock contention is informational and still has diagnostic counts' ($busyRows.Count -eq 2 -and @($busyRows | Where-Object {$_ -match '\[ERROR\]'}).Count -eq 0 -and $busyRows[1] -match '累计 3 次')
    Write-Log 'PREVIEW ERROR timed-out' -Exception (New-Object TimeoutException('Unexpected preview timeout'))
    Check-Obs 'An unrelated timeout remains a real error' ([IO.File]::ReadAllLines($script:LogPath)[-1] -match '\[ERROR\].*timed-out')
    Write-Log "LINE ERROR first
second"
    Check-Obs 'Multi-line exceptions cannot forge extra log records' ([IO.File]::ReadAllLines($script:LogPath)[-1] -match 'first second')
    $previousLog=$script:LogPath;$script:LogPath=Join-Path $script:AppDir 'rotation.log';$script:ApplicationLogState=@{}
    [IO.File]::WriteAllText($script:LogPath,(('x'*(2MB+256))+[Environment]::NewLine),$script:Utf8)
    $workerPath=Join-Path $PSScriptRoot 'observability-worker.ps1'
    $processes=@()
    foreach($prefix in @('A','B')){
        $arguments='-NoProfile -ExecutionPolicy RemoteSigned -File "'+$workerPath+'" -RuntimeDirectory "'+$RuntimeDirectory+'" -LogPath "'+$script:LogPath+'" -Prefix '+$prefix
        $child=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments -PassThru;$childHandle=$child.Handle;$processes+=$child
    }
    $workerOk=$true
    foreach($process in $processes){if(-not $process.WaitForExit(15000)){$process.Kill();$workerOk=$false}else{if($process.ExitCode -ne 0){$workerOk=$false}};$process.Dispose()}
    Check-Obs 'Concurrent logging processes finish normally' $workerOk
    Check-Obs 'Log rotation keeps the previous file while writers append' ([IO.File]::Exists($script:LogPath+'.old') -and (Get-Item -LiteralPath ($script:LogPath+'.old')).Length -gt 2MB)
    $rows=@([IO.File]::ReadAllLines($script:LogPath) | Where-Object {$_ -match 'WORKER-'})
    Check-Obs 'The shared log loses no rows when concurrent writers rotate it' ($rows.Count -eq 40 -and @($rows | Select-Object -Unique).Count -eq 40)
    $badParent=Put-Obs $script:AppDir 'parent-is-file' 'keep'
    $script:LogPath=Join-Path $badParent 'cannot-write.log';$didThrow=$false
    try{Write-Log 'WRITE ERROR unavailable-log'}catch{$didThrow=$true}
    Check-Obs 'A logging failure cannot break the file operation' (-not $didThrow)
    $script:LogPath=$previousLog;$script:ApplicationLogState=@{}
    $existing=Put-Obs $script:Root 'a.txt' 'keep-existing'
    $a=Put-Obs $desktop 'a.txt' 'import-alpha';$b=Put-Obs $desktop 'b.txt' 'import-beta'
    Reset-ObsProgress
    $imports=@(Import-LibraryItems -Paths @($a,(Join-Path $desktop 'missing.txt'),$b) -Progress $progress)
    Check-Obs 'Import reports real completion even for a failed item' ((Test-ObsProgress 3 'import') -and @($imports | Where-Object Success).Count -eq 2 -and @($imports | Where-Object {-not $_.Success}).Count -eq 1)
    $firstImported=@($imports | Where-Object Success)[0].Target
    Check-Obs 'Progress callbacks do not overwrite same-name documents' ([IO.File]::ReadAllText($existing) -eq 'keep-existing' -and [IO.File]::ReadAllText($firstImported) -eq 'import-alpha')
    $cancelA=Put-Obs $desktop 'cancel-a.txt' 'cancel-first';$cancelB=Put-Obs $desktop 'cancel-b.txt' 'cancel-second'
    Reset-ObsProgress
    $cancelImport=@(Import-LibraryItems -Paths @($cancelA,$cancelB) -Progress $cancelAfterOne -ShouldCancel $shouldCancel)
    Check-Obs 'Import cancellation waits until the current file is complete' ($cancelImport.Count -eq 1 -and (Test-ObsProgress 1 'import') -and -not [IO.File]::Exists($cancelA) -and [IO.File]::Exists($cancelB) -and [IO.File]::ReadAllText($cancelB) -eq 'cancel-second')
    $exportA=Put-Obs $script:Root 'export-a.txt' 'export-alpha';$exportB=Put-Obs $script:Root 'export-b.txt' 'export-beta'
    $exportCollision=Put-Obs $exported 'export-a.txt' 'keep-desktop'
    Reset-ObsProgress
    $exports=@(Export-LibraryFiles -Paths @($exportA,(Join-Path $script:Root 'missing.txt'),$exportB) -Destination $exported -Progress $progress)
    Check-Obs 'Export progress includes failed entries and reaches the real total' ((Test-ObsProgress 3 'export') -and @($exports | Where-Object Success).Count -eq 2)
    Check-Obs 'Export keeps existing destination bytes and reports the moved file' ([IO.File]::ReadAllText($exportCollision) -eq 'keep-desktop' -and [IO.File]::ReadAllText(@($exports | Where-Object Success)[0].Target) -eq 'export-alpha')
    $exportC=Put-Obs $script:Root 'export-c.txt' 'export-first';$exportD=Put-Obs $script:Root 'export-d.txt' 'export-second'
    Reset-ObsProgress
    $stoppedExport=@(Export-LibraryFiles -Paths @($exportC,$exportD) -Destination $exported -Progress $cancelAfterOne -ShouldCancel $shouldCancel)
    Check-Obs 'Export cancellation leaves all not-yet-processed originals in place' ($stoppedExport.Count -eq 1 -and (Test-ObsProgress 1 'export') -and [IO.File]::Exists($exportD) -and [IO.File]::ReadAllText($exportD) -eq 'export-second')
    $printOk=Put-Obs $script:Root 'print-ok.txt' 'print-ok';$printFail=Put-Obs $script:Root 'print-fail.txt' 'print-fail';$printUnsupported=Put-Obs $script:Root 'print.customdoc' 'print-unsupported'
    $script:obsPrintCalls=New-Object Collections.ArrayList
    function Get-PrintFileCapability {param([string]$Path)[pscustomobject]@{Path=$Path;Supported=([IO.Path]::GetExtension($Path) -eq '.txt');Error='unsupported test format'}}
    function Start-DocumentPrint {param([string]$Path)[void]$script:obsPrintCalls.Add($Path);if([IO.Path]::GetFileName($Path) -eq 'print-fail.txt'){throw 'Simulated print-app failure'}}
    Reset-ObsProgress
    $printPlan=@(Invoke-BatchPrint -Paths @($printOk,$printFail,$printUnsupported) -Progress $progress)
    Check-Obs 'Print planning reports progress without contacting a printer' ((Test-ObsProgress 3 'print') -and $printPlan.Count -eq 3 -and $script:obsPrintCalls.Count -eq 0)
    Reset-ObsProgress
    $printResults=@(Invoke-BatchPrint -Paths @($printOk,$printFail,$printUnsupported) -Execute -Progress $progress)
    Check-Obs 'Print submission progress counts unsupported and failed items' ((Test-ObsProgress 3 'print') -and @($printResults | Where-Object Status -eq 'submitted').Count -eq 1 -and @($printResults | Where-Object Status -eq 'skipped').Count -eq 2 -and $script:obsPrintCalls.Count -eq 2)
    $script:obsPrintCalls.Clear();Reset-ObsProgress
    $stoppedPrint=@(Invoke-BatchPrint -Paths @($printOk,$printFail) -Execute -Progress $cancelAfterOne -ShouldCancel $shouldCancel)
    Check-Obs 'Stopping print submission prevents later files from being submitted' ($stoppedPrint.Count -eq 1 -and $script:obsPrintCalls.Count -eq 1 -and (Test-ObsProgress 1 'print'))
    $script:obsPrintCalls.Clear()
    $withBrokenProgress=@(Invoke-BatchPrint -Paths @($printOk) -Execute -Progress {throw 'Progress transport unavailable'})
    Check-Obs 'A failed progress channel cannot turn a submitted item into a failure' ($withBrokenProgress.Count -eq 1 -and $withBrokenProgress[0].Status -eq 'submitted' -and $script:obsPrintCalls.Count -eq 1)
    Check-Obs 'A failed cancellation check stops conservatively before the next file' (Test-OperationCancellation -ShouldCancel {throw 'Unavailable cancellation state'})
    $keep=Put-Obs $script:Root 'keep.txt' 'identical';$copy=Put-Obs $script:Root 'copy.txt' 'identical'
    $plan=[pscustomobject]@{Keep=$keep;Duplicate=$copy;Hash=(Get-FileHash -LiteralPath $keep -Algorithm SHA256).Hash;Size=(Get-Item -LiteralPath $keep).Length}
    Reset-ObsProgress
    $dry=@(Invoke-DuplicateCleanup -Plan @($plan) -Progress $progress)
    Check-Obs 'Cleanup dry runs neither mutate files nor pretend execution progressed' ($dry.Count -eq 1 -and $script:obsProgress.Count -eq 0 -and [IO.File]::Exists($keep) -and [IO.File]::Exists($copy))
    $blocked=$false
    try{$null=Invoke-DuplicateCleanup -Plan @($plan) -Execute -Progress $progress -ShouldCancel {return $true}}catch{$blocked=$_.Exception.Message -match '删除功能已锁定'}
    Check-Obs 'Cancellation and progress cannot bypass the real cleanup verification gate' ($blocked -and -not (Test-DedupeVerified) -and $script:obsProgress.Count -eq 0 -and [IO.File]::ReadAllText($keep) -eq 'identical' -and [IO.File]::ReadAllText($copy) -eq 'identical' -and -not [IO.File]::Exists((Join-Path $script:AppDir '_dedupe-journal.jsonl')))
}catch{[void]$script:obsFailures.Add($_.Exception.ToString());Write-Output $_.ScriptStackTrace;Write-Output $_.Exception.ToString()}
finally{
    Set-Item Function:\Get-PrintFileCapability -Value $originalCapability
    Set-Item Function:\Start-DocumentPrint -Value $originalPrint
    Flush-ApplicationLogs -Force
    $scratchRemoved=$false
    if($obsFailures.Count -eq 0){
        try{Remove-ObservabilityScratch -Path $runDir -AllowedParent $ScratchBase;$scratchRemoved=(-not [IO.Directory]::Exists($runDir))}
        catch{[void]$script:obsFailures.Add('Scratch cleanup: '+$_.Exception.Message)}
    }
    $report=@{Passed=$obsPassed;Failed=$obsFailures.Count;Failures=@($obsFailures.ToArray());Scratch=$runDir;ScratchRemoved=$scratchRemoved;Time=[datetime]::UtcNow.ToString('o')}
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'observability-results.json'),($report | ConvertTo-Json -Depth 5),$script:Utf8)
    Write-Output ('OBSERVABILITY passed='+$obsPassed+' failed='+$obsFailures.Count)
}
if($obsFailures.Count){exit 1}
