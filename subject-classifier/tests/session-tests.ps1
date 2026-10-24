param([string]$SourceDir=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $SourceDir 'tests\test-support.ps1')
$sessionParent=Join-Path ([IO.Path]::GetTempPath()) 'Nailong-session-tests'
$run=Join-Path $sessionParent ('check-'+[guid]::NewGuid().ToString('N'))
$app=Join-Path $run 'app';$library=Join-Path $run 'library'
New-Item -ItemType Directory -Path $app,$library -Force|Out-Null
$utf8=New-Object Text.UTF8Encoding($false);$passed=0
function Check([string]$Name,[bool]$Condition){if(-not $Condition){throw ('FAIL '+$Name)};$script:passed++;Write-Output ('PASS '+$Name)}
function Wait-Status([string]$Expected){$until=[datetime]::UtcNow.AddSeconds(25);do{if((Get-ManagedLibraryWatcherStatus) -eq $Expected){return $true};Start-Sleep -Milliseconds 100}while([datetime]::UtcNow -lt $until);return $false}
try{
    $manifest=[IO.File]::ReadAllText((Join-Path $SourceDir 'application-files.json'),$utf8)|ConvertFrom-Json
    foreach($relative in $manifest){$to=Join-Path $app $relative;[void][IO.Directory]::CreateDirectory((Split-Path $to -Parent));Copy-Item -LiteralPath (Join-Path $SourceDir $relative) -Destination $to}
    Copy-Item -LiteralPath (Join-Path $SourceDir 'application-files.json') -Destination $app
    $cfg=[IO.File]::ReadAllText((Join-Path $app 'config.example.json'),$utf8)|ConvertFrom-Json;$cfg.inbox=$library;$cfg.processExistingOnStartup=$false
    [IO.File]::WriteAllText((Join-Path $app 'config.json'),($cfg|ConvertTo-Json -Depth 16),$utf8)
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
    $desktop=Join-Path $run 'desktop';$startup=Join-Path $run 'startup';New-Item -ItemType Directory -Path $desktop,$startup -Force|Out-Null
    $shell=New-Object -ComObject WScript.Shell
    try{
        $own=$shell.CreateShortcut((Join-Path $startup 'SubjectAutoClassifier.lnk'));$own.TargetPath='powershell.exe';$own.Arguments='-File "'+(Join-Path $app 'classifier.ps1')+'"';$own.Save()
        $other=$shell.CreateShortcut((Join-Path $startup 'Unrelated.lnk'));$other.TargetPath='notepad.exe';$other.Save()
    }finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
    & (Join-Path $SourceDir 'tools\install-desktop.ps1') -ApplicationDirectory $app -DesktopDirectory $desktop -StartupDirectory $startup
    Check 'Installer creates the integrated desktop shortcut' ([IO.File]::Exists((Join-Path $desktop '奶龙.code.lnk')))
    Check 'Installer disables this application autostart' (-not [IO.File]::Exists((Join-Path $startup 'SubjectAutoClassifier.lnk')))
    Check 'Installer preserves unrelated startup entries' ([IO.File]::Exists((Join-Path $startup 'Unrelated.lnk')))
    Write-Output ('SESSION passed='+$passed+' failed=0')
}finally{
    if(Get-Command Stop-ManagedLibraryWatcher -ErrorAction SilentlyContinue){Stop-ManagedLibraryWatcher}
    Remove-IsolatedTestDirectory -Path $run -AllowedParent $sessionParent
}
