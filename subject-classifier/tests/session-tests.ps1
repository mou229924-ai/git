param([string]$SourceDir=(Split-Path $PSScriptRoot -Parent),[switch]$RequireEncryptedState)
$ErrorActionPreference='Stop'
. (Join-Path $SourceDir 'tests\test-support.ps1')
$sessionParent=Join-Path ([IO.Path]::GetTempPath()) 'Nailong-session-tests'
$run=Join-Path $sessionParent ('check-'+[guid]::NewGuid().ToString('N'))
$app=Join-Path $run '程序 中文目录';$library=Join-Path $run '资料库 中文目录'
New-Item -ItemType Directory -Path $app,$library -Force|Out-Null
$utf8=New-Object Text.UTF8Encoding($false);$passed=0
function Check([string]$Name,[bool]$Condition){if(-not $Condition){throw ('FAIL '+$Name)};$script:passed++;Write-Output ('PASS '+$Name)}
function Wait-Status([string]$Expected){$until=[datetime]::UtcNow.AddSeconds(25);do{if((Get-ManagedLibraryWatcherStatus) -eq $Expected){return $true};Start-Sleep -Milliseconds 100}while([datetime]::UtcNow -lt $until);return $false}

function Get-SessionSourceHash([string]$Path){if([IO.File]::Exists($Path)){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash};return ''}
$sessionOriginalConfig=Get-SessionSourceHash (Join-Path $SourceDir 'config.json')
$sessionOriginalGate=Get-SessionSourceHash (Join-Path $SourceDir 'tests\verified.json')
$sessionEfsFixture=''
$sessionEfsParent=''
function Assert-SessionNoLinks([string]$Path){
    $sessionNode=New-Object IO.DirectoryInfo([IO.Path]::GetFullPath($Path))
    while($sessionNode){if($sessionNode.Exists -and ($sessionNode.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Session state test cannot use linked directories.'};$sessionNode=$sessionNode.Parent}
}
function Watch-SessionHeartbeats([bool]$Paused,[double]$Seconds,[int]$ExpectedProcessId){
    $sessionTimes=@{}
    $sessionWatch=[Diagnostics.Stopwatch]::StartNew()
    $sessionStatusPath=$script:ManagedWatcher.Control+'.status'
    try{
        do{
            if(-not $script:ManagedWatcher -or $script:ManagedWatcher.Process.Id -ne $ExpectedProcessId){throw 'The continuous session silently changed worker identity.'}
            $script:ManagedWatcher.Process.Refresh()
            if($script:ManagedWatcher.Process.HasExited){throw 'The continuous session worker exited before completing its heartbeat checks.'}
            $sessionStatus=Read-SessionStateUtf8 -Path $sessionStatusPath|ConvertFrom-Json
            if($sessionStatus.Token -ne $script:ManagedWatcher.Data.Token -or [int]$sessionStatus.ProcessId -ne $ExpectedProcessId -or [bool]$sessionStatus.Paused -ne $Paused){throw 'A repeated heartbeat does not acknowledge the expected session state.'}
            $sessionStatusFile=Get-Item -LiteralPath $sessionStatusPath -Force
            if($RequireEncryptedState -and -not ($sessionStatusFile.Attributes -band [IO.FileAttributes]::Encrypted)){throw 'A repeated session heartbeat lost its real EFS encryption.'}
            $sessionTimes[$sessionStatusFile.LastWriteTimeUtc.Ticks.ToString()]=$true
            Start-Sleep -Milliseconds 100
        }while($sessionWatch.Elapsed.TotalSeconds -lt $Seconds)
        return [pscustomobject]@{Seconds=$sessionWatch.Elapsed.TotalSeconds;Updates=$sessionTimes.Count}
    }finally{$sessionWatch.Stop()}
}
function Remove-SessionStateFixture {
    if(-not $sessionEfsFixture -or -not [IO.Directory]::Exists($sessionEfsFixture)){return}
    $sessionFull=[IO.Path]::GetFullPath($sessionEfsFixture).TrimEnd('\')
    if([IO.Path]::GetDirectoryName($sessionFull) -ne $sessionEfsParent -or [IO.Path]::GetFileName($sessionFull) -notmatch '^check-[a-f0-9]{32}$'){throw 'Refusing cleanup of an unrecognized LocalAppData fixture.'}
    Assert-SessionNoLinks $sessionFull
    $sessionItems=@(Get-ChildItem -LiteralPath $sessionFull -Force)
    foreach($sessionItem in $sessionItems){if($sessionItem.PSIsContainer -or ($sessionItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unexpected nested or linked content in the exact session state fixture.'}}
    foreach($sessionItem in $sessionItems){[IO.File]::Delete($sessionItem.FullName)}
    try{[IO.Directory]::Delete($sessionFull)}catch{
        $sessionCleanupError=$_.Exception.GetBaseException()
        if((($sessionCleanupError -is [UnauthorizedAccessException]) -or ($sessionCleanupError -is [IO.IOException])) -and @(Get-ChildItem -LiteralPath $sessionFull -Force).Count -eq 0){Write-Output ('SESSION CLEANUP empty EFS directory retained: '+$sessionFull)}else{throw}
    }
}

try{
    $manifest=[IO.File]::ReadAllText((Join-Path $SourceDir 'application-files.json'),$utf8)|ConvertFrom-Json
    foreach($relative in $manifest){$to=Join-Path $app $relative;[void][IO.Directory]::CreateDirectory((Split-Path $to -Parent));Copy-Item -LiteralPath (Join-Path $SourceDir $relative) -Destination $to}
    Copy-Item -LiteralPath (Join-Path $SourceDir 'application-files.json') -Destination $app
    $cfg=[IO.File]::ReadAllText((Join-Path $app 'config.example.json'),$utf8)|ConvertFrom-Json;$cfg.inbox=$library;$cfg.processExistingOnStartup=$false
    [IO.File]::WriteAllText((Join-Path $app 'config.json'),($cfg|ConvertTo-Json -Depth 16),$utf8)
    $originalDocument=Join-Path $library '原始资料.txt'
    $originalBytes=$utf8.GetBytes('原始资料保留 · original bytes must not change')
    [IO.File]::WriteAllBytes($originalDocument,$originalBytes)
    . (Join-Path $app 'lib.ps1');$script:StateDir=Join-Path $run 'state'
    $owner=[Diagnostics.Process]::GetCurrentProcess();$ticks=$owner.StartTime.ToUniversalTime().Ticks;$owner.Dispose()
    Check 'Correct owner process identity is accepted' (Test-ApplicationOwnerAlive -ProcessId $PID -StartTicks $ticks)
    Check 'Reused PID with a different start time is rejected' (-not (Test-ApplicationOwnerAlive -ProcessId $PID -StartTicks ($ticks-1)))
    Start-ManagedLibraryWatcher
    Check 'Opening the application starts its classifier' (Wait-Status '运行中')
    $first=$script:ManagedWatcher.Process.Id;Start-ManagedLibraryWatcher
    Check 'Repeated start keeps one owned classifier' ($script:ManagedWatcher.Process.Id -eq $first)
    Set-ManagedLibraryWatcherPaused $true
    Check 'Application can pause classification' (Wait-Status '已暂停')
    Set-ManagedLibraryWatcherPaused $false
    Check 'Application can resume classification' (Wait-Status '运行中')
    $control=$script:ManagedWatcher.Control
    Stop-ManagedLibraryWatcher
    $alive=$true;try{$child=[Diagnostics.Process]::GetProcessById($first);$alive=-not $child.HasExited;$child.Dispose()}catch{$alive=$false}
    Check 'Closing the application stops its classifier' (-not $alive)
    Check 'Closing cleans only its control files' (-not [IO.File]::Exists($control) -and -not [IO.File]::Exists($control+'.status'))
    Check 'Stopped application reports stopped status' ((Get-ManagedLibraryWatcherStatus) -eq '已停止')
    Start-ManagedLibraryWatcher
    Check 'The listener can restart after a normal stop' (Wait-Status '运行中')
    $secondId=$script:ManagedWatcher.Process.Id;$secondControl=$script:ManagedWatcher.Control
    $controlLock=[IO.File]::Open($secondControl,'Open','ReadWrite','Read')
    try{Stop-ManagedLibraryWatcher}finally{$controlLock.Dispose()}
    $secondAlive=$true;try{$p2=[Diagnostics.Process]::GetProcessById($secondId);$secondAlive=-not $p2.HasExited;$p2.Dispose()}catch{$secondAlive=$false}
    Check 'A failed stop request still terminates only the owned classifier' (-not $secondAlive)
    if([IO.File]::Exists($secondControl)){[IO.File]::Delete($secondControl)}
    $orphan=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoProfile -STA -ExecutionPolicy RemoteSigned -File "'+(Join-Path $app 'classifier.ps1')+'" -EnsureRunning -OwnerProcessId '+$PID+' -OwnerStartTicks '+($ticks-1)+' -ControlPath "'+(Join-Path $run 'missing-control.json')+'" -ControlToken invalid') -PassThru
    try{$orphanHandle=$orphan.Handle;$exited=$orphan.WaitForExit(15000);Check 'A classifier with an expired owner identity exits automatically' $exited}finally{if(-not $orphan.HasExited){$orphan.Kill()};$orphan.Dispose()}
    $desktop=Join-Path $run '桌面 中文目录';$startup=Join-Path $run '启动项 中文目录';New-Item -ItemType Directory -Path $desktop,$startup -Force|Out-Null
    if(-not ('Nailong.NativeShortcut' -as [type])){Add-Type -Path (Join-Path $app 'NativeShortcut.cs')}
    $ownPath=Join-Path $startup '旧版分类启动.lnk';$otherPath=Join-Path $startup '其他程序保留.lnk'
    $shellTarget=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    [Nailong.NativeShortcut]::Create($ownPath,$shellTarget,('-File "'+(Join-Path $app 'classifier.ps1')+'"'),$app,'本程序旧启动入口','',7)
    [Nailong.NativeShortcut]::Create($otherPath,(Join-Path $env:SystemRoot 'System32\notepad.exe'),'',$run,'无关程序入口','',1)
    $otherHash=(Get-FileHash -LiteralPath $otherPath -Algorithm SHA256).Hash
    & (Join-Path $SourceDir 'tools\install-desktop.ps1') -ApplicationDirectory $app -DesktopDirectory $desktop -StartupDirectory $startup
    $desktopPath=Join-Path $desktop '奶龙.code.lnk'
    $desktopInfo=[Nailong.NativeShortcut]::Read($desktopPath)
    Check 'Installer creates the integrated desktop shortcut' ([IO.File]::Exists($desktopPath)-and $desktopInfo.TargetPath.Equals($shellTarget,[StringComparison]::OrdinalIgnoreCase)-and $desktopInfo.Arguments.Contains((Join-Path $app 'setup.ps1'))-and $desktopInfo.Arguments.Contains('RemoteSigned')-and $desktopInfo.WorkingDirectory.Equals($app,[StringComparison]::OrdinalIgnoreCase)-and $desktopInfo.Description-eq '奶龙.code：搜索、预览与自动分类')
    Check 'Installer disables this application autostart' (-not [IO.File]::Exists($ownPath))
    Check 'Installer preserves unrelated startup entries' ([IO.File]::Exists($otherPath)-and (Get-FileHash -LiteralPath $otherPath -Algorithm SHA256).Hash-eq $otherHash-and [Nailong.NativeShortcut]::Read($otherPath).Description-eq '无关程序入口')
    Check 'Session and Unicode shortcut installation preserve original document bytes' ([Convert]::ToBase64String([IO.File]::ReadAllBytes($originalDocument))-eq [Convert]::ToBase64String($originalBytes))
    # Use the real per-user state volume, where EFS caused the production second-write failure.
    # These exercise the same Start/Set/Stop APIs used by the unified application UI.
    $sessionLocal=[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')
    if($sessionLocal -ne [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')){throw 'LOCALAPPDATA does not match the current real user state directory.'}
    if($RequireEncryptedState -and $sessionLocal -match '(?i)\\Packages\\sandbox\.'){throw 'Encrypted-state acceptance must run as the real user, outside the redirected sandbox.'}
    $sessionEfsParent=Join-Path $sessionLocal 'Nailong.code\state'
    $sessionEfsFixture=Join-Path $sessionEfsParent ('check-'+[guid]::NewGuid().ToString('N'))
    Assert-SessionNoLinks $sessionEfsFixture
    if(Test-Path -LiteralPath $sessionEfsFixture){throw 'The fresh session state fixture already exists.'}
    [void][IO.Directory]::CreateDirectory($sessionEfsFixture)
    $script:StateDir=$sessionEfsFixture
    $sessionDirEncrypted=[bool]((Get-Item -LiteralPath $sessionEfsFixture -Force).Attributes -band [IO.FileAttributes]::Encrypted)
    Write-Output ('SESSION STATE LocalAppData='+$sessionLocal+' EncryptedDirectory='+$sessionDirEncrypted+' RequireEncrypted='+[bool]$RequireEncryptedState)
    if($RequireEncryptedState){Check 'The real LocalAppData session fixture inherits EFS encryption' $sessionDirEncrypted}
    Start-ManagedLibraryWatcher
    Check 'A real LocalAppData session starts its owned worker' (Wait-Status '运行中')
    $sessionContinuousId=$script:ManagedWatcher.Process.Id
    $sessionContinuousControl=$script:ManagedWatcher.Control
    $sessionStatusEncrypted=[bool]((Get-Item -LiteralPath ($sessionContinuousControl+'.status') -Force).Attributes -band [IO.FileAttributes]::Encrypted)
    Write-Output ('SESSION STATE EncryptedStatus='+$sessionStatusEncrypted)
    if($RequireEncryptedState){Check 'The repeatedly replaced session status file really uses EFS' $sessionStatusEncrypted}
    $sessionRunning=Watch-SessionHeartbeats -Paused $false -Seconds 5.2 -ExpectedProcessId $sessionContinuousId
    Check 'The same real-state worker survives over five seconds and publishes at least three heartbeats' ($sessionRunning.Seconds -gt 5 -and $sessionRunning.Updates -ge 3)
    $sessionInitialControlText=Read-SessionStateUtf8 -Path $sessionContinuousControl
    Set-ManagedLibraryWatcherPaused $true
    Check 'The real-state worker acknowledges pause without restarting' ((Wait-Status '已暂停') -and $script:ManagedWatcher.Process.Id -eq $sessionContinuousId)
    $sessionPausedControlText=Read-SessionStateUtf8 -Path $sessionContinuousControl
    $sessionPaused=Watch-SessionHeartbeats -Paused $true -Seconds 2.2 -ExpectedProcessId $sessionContinuousId
    Check 'Paused status continues replacing the same real-state status file' ($sessionPaused.Updates -ge 2)
    Set-ManagedLibraryWatcherPaused $false
    Check 'The real-state worker acknowledges resume without restarting' ((Wait-Status '运行中') -and $script:ManagedWatcher.Process.Id -eq $sessionContinuousId)
    $sessionResumedControlText=Read-SessionStateUtf8 -Path $sessionContinuousControl
    $sessionResumed=Watch-SessionHeartbeats -Paused $false -Seconds 2.2 -ExpectedProcessId $sessionContinuousId
    Check 'Resumed status continues replacing the same real-state status file' ($sessionResumed.Updates -ge 2)
    Check 'Pause and resume replace the existing control file with acknowledged different bytes' ($sessionInitialControlText -ne $sessionPausedControlText -and $sessionPausedControlText -ne $sessionResumedControlText)
    # A second process holds the real control mutex while both production APIs time out.
    $sessionHoldScript=Join-Path $run 'hold-session-mutex.ps1'
    $sessionReady=Join-Path $sessionEfsFixture 'mutex-holder.ready'
    $sessionRelease=Join-Path $sessionEfsFixture 'mutex-holder.release'
    $sessionHoldBody=@'
param([string]$MutexName,[string]$Ready,[string]$Release)
$ErrorActionPreference='Stop'
$mutex=New-Object Threading.Mutex($false,$MutexName)
$owned=$false
try{
    try{$owned=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$owned=$true}
    if(-not $owned){throw 'Session test mutex holder could not acquire the mutex.'}
    [IO.File]::WriteAllText($Ready,'ready')
    $deadline=[datetime]::UtcNow.AddSeconds(15)
    while(-not [IO.File]::Exists($Release) -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 25}
}finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
'@
    $sessionHoldTokens=$null;$sessionHoldErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseInput($sessionHoldBody,[ref]$sessionHoldTokens,[ref]$sessionHoldErrors)
    if($sessionHoldErrors.Count){throw ('Invalid independent mutex-holder fixture: '+(($sessionHoldErrors|ForEach-Object{$_.Message}) -join '; '))}
    [IO.File]::WriteAllText($sessionHoldScript,$sessionHoldBody,$utf8)
    $sessionHolderStdout=Join-Path $run 'mutex-holder.stdout.log'
    $sessionHolderStderr=Join-Path $run 'mutex-holder.stderr.log'
    if([IO.File]::Exists($sessionReady) -or [IO.File]::Exists($sessionRelease)){throw 'The new mutex-holder fixture contains stale handshake files.'}
    $sessionMutexName=[Nailong.SessionStateFile]::GetMutexName($sessionContinuousControl)
    $sessionMutexHolder=$null
    $sessionReadTimedOut=$false;$sessionWriteTimedOut=$false;$sessionBusySeconds=0;$sessionBusyAlive=$false
    try{
        $sessionMutexHolder=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy RemoteSigned -File "'+$sessionHoldScript+'" -MutexName "'+$sessionMutexName+'" -Ready "'+$sessionReady+'" -Release "'+$sessionRelease+'"') -RedirectStandardOutput $sessionHolderStdout -RedirectStandardError $sessionHolderStderr -PassThru
        $sessionHolderHandle=$sessionMutexHolder.Handle
        $sessionReadyDeadline=[datetime]::UtcNow.AddSeconds(10)
        while(-not [IO.File]::Exists($sessionReady)){
            if($sessionMutexHolder.HasExited -or [datetime]::UtcNow -ge $sessionReadyDeadline){
                $sessionHolderExit=if($sessionMutexHolder.HasExited){[string]$sessionMutexHolder.ExitCode}else{'running'}
                $sessionHolderDiagnostic=if([IO.File]::Exists($sessionHolderStderr)){[IO.File]::ReadAllText($sessionHolderStderr)}else{'No stderr was created.'}
                throw ('The independent session mutex holder did not become ready. ExitCode='+$sessionHolderExit+' stderr='+$sessionHolderDiagnostic)
            }
            Start-Sleep -Milliseconds 50
        }
        $sessionBusyWatch=[Diagnostics.Stopwatch]::StartNew()
        try{Read-SessionStateUtf8 -Path $sessionContinuousControl|Out-Null}catch{if($_.Exception.GetBaseException() -is [TimeoutException]){$sessionReadTimedOut=$true}else{throw}}
        try{Write-SessionStateUtf8 -Path $sessionContinuousControl -Text $sessionResumedControlText}catch{if($_.Exception.GetBaseException() -is [TimeoutException]){$sessionWriteTimedOut=$true}else{throw}}
        $sessionBusyWatch.Stop();$sessionBusySeconds=$sessionBusyWatch.Elapsed.TotalSeconds
        # Keep the lock across more than one classifier timer interval.
        Start-Sleep -Milliseconds 500
        $script:ManagedWatcher.Process.Refresh()
        $sessionBusyAlive=(-not $script:ManagedWatcher.Process.HasExited -and $script:ManagedWatcher.Process.Id -eq $sessionContinuousId)
    }finally{
        if($sessionMutexHolder){
            [IO.File]::WriteAllText($sessionRelease,'release',$utf8)
            try{if(-not $sessionMutexHolder.WaitForExit(2000)){$sessionMutexHolder.Kill();[void]$sessionMutexHolder.WaitForExit(1000)}}finally{$sessionMutexHolder.Dispose()}
        }
    }
    $sessionAfterBusy=Read-SessionStateUtf8 -Path $sessionContinuousControl
    $sessionRecovered=Watch-SessionHeartbeats -Paused $false -Seconds 1.2 -ExpectedProcessId $sessionContinuousId
    Check 'A busy session mutex bounds reader and writer waits, preserves complete JSON and keeps the same worker alive' ($sessionReadTimedOut -and $sessionWriteTimedOut -and $sessionBusySeconds -lt 2 -and $sessionBusyAlive -and $sessionAfterBusy -eq $sessionResumedControlText -and $sessionRecovered.Updates -ge 2)
    # Request a natural stop directly. Do not let Stop-ManagedLibraryWatcher's kill fallback prove success.
    $script:ManagedWatcher.Data.Stop=$true
    Write-SessionStateUtf8 -Path $sessionContinuousControl -Text ($script:ManagedWatcher.Data|ConvertTo-Json -Compress)
    $sessionNaturalStop=$script:ManagedWatcher.Process.WaitForExit(8000)
    Check 'The same real-state worker stops naturally after a replaced Stop control request' ($sessionNaturalStop -and $script:ManagedWatcher.Process.ExitCode -eq 0)
    Stop-ManagedLibraryWatcher
    Check 'A completed real-state session cleans its exact control and status files' (-not [IO.File]::Exists($sessionContinuousControl) -and -not [IO.File]::Exists($sessionContinuousControl+'.status'))
    Check 'The sustained real-state session preserves the original document bytes' ([Convert]::ToBase64String([IO.File]::ReadAllBytes($originalDocument))-eq [Convert]::ToBase64String($originalBytes))
    Check 'Session regression leaves the source configuration and production dedupe gate unchanged' ((Get-SessionSourceHash (Join-Path $SourceDir 'config.json')) -eq $sessionOriginalConfig -and (Get-SessionSourceHash (Join-Path $SourceDir 'tests\verified.json')) -eq $sessionOriginalGate)
    Write-Output ('SESSION passed='+$passed+' failed=0')
}finally{
    if(Get-Command Stop-ManagedLibraryWatcher -ErrorAction SilentlyContinue){Stop-ManagedLibraryWatcher}
    Remove-SessionStateFixture
    Remove-IsolatedTestDirectory -Path $run -AllowedParent $sessionParent
    if((Get-SessionSourceHash (Join-Path $SourceDir 'config.json')) -ne $sessionOriginalConfig -or (Get-SessionSourceHash (Join-Path $SourceDir 'tests\verified.json')) -ne $sessionOriginalGate){throw 'Session tests modified source configuration or production dedupe verification.'}
}
