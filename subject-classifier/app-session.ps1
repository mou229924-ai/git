# Application-owned classifier process. Importing this module does not launch anything.
function Test-ApplicationOwnerAlive {
    param([int]$ProcessId,[long]$StartTicks)
    $process=$null
    try{$process=[Diagnostics.Process]::GetProcessById($ProcessId);return (-not $process.HasExited -and $process.StartTime.ToUniversalTime().Ticks -eq $StartTicks)}catch{return $false}finally{if($process){$process.Dispose()}}
}
function Start-ManagedLibraryWatcher {
    if($script:ManagedWatcher -and -not $script:ManagedWatcher.Process.HasExited){return}
    if($script:ManagedWatcher){Stop-ManagedLibraryWatcher}
    [void][IO.Directory]::CreateDirectory($script:StateDir)
    $owner=[Diagnostics.Process]::GetCurrentProcess()
    try{$started=$owner.StartTime.ToUniversalTime().Ticks}finally{$owner.Dispose()}
    $control=Join-Path $script:StateDir ('watcher-'+$PID+'-'+[guid]::NewGuid().ToString('N')+'.json')
    $data=@{OwnerProcessId=$PID;OwnerStartTicks=$started;Paused=$false;Stop=$false;Token=[guid]::NewGuid().ToString('N')}
    Write-AtomicUtf8 $control ($data | ConvertTo-Json -Compress)
    $arguments='-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "'+(Join-Path $script:AppDir 'classifier.ps1')+'" -EnsureRunning -OwnerProcessId '+$PID+' -OwnerStartTicks '+$started+' -ControlPath "'+$control+'" -ControlToken '+$data.Token
    try{$process=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments -PassThru;$processHandle=$process.Handle;$script:ManagedWatcher=@{Process=$process;Control=$control;Data=$data;Started=Get-Date}}catch{[IO.File]::Delete($control);throw}
}
function Set-ManagedLibraryWatcherPaused {
    param([bool]$Paused)
    if(-not $script:ManagedWatcher -or $script:ManagedWatcher.Process.HasExited){Start-ManagedLibraryWatcher}
    $script:ManagedWatcher.Data.Paused=$Paused
    Write-AtomicUtf8 $script:ManagedWatcher.Control ($script:ManagedWatcher.Data | ConvertTo-Json -Compress)
}
function Get-ManagedLibraryWatcherStatus {
    if(-not $script:ManagedWatcher){return '已停止'}
    if($script:ManagedWatcher.Process.HasExited){return '已停止（可重新开启）'}
    $status=$script:ManagedWatcher.Control+'.status'
    if([IO.File]::Exists($status)){
        try{$data=[IO.File]::ReadAllText($status,$script:Utf8)|ConvertFrom-Json;if($data.Token -eq $script:ManagedWatcher.Data.Token){if($data.Paused){return '已暂停'};return '运行中'}}catch{}
    }
    return '启动中'
}
function Stop-ManagedLibraryWatcher {
    if(-not $script:ManagedWatcher){return}
    $watcher=$script:ManagedWatcher
    try{
        if(-not $watcher.Process.HasExited){$watcher.Data.Stop=$true;Write-AtomicUtf8 $watcher.Control ($watcher.Data | ConvertTo-Json -Compress)}
    }catch{Write-Log ('WATCHER STOP REQUEST '+$_.Exception.Message) -Level WARN}
    finally{
        try{if(-not $watcher.Process.HasExited -and -not $watcher.Process.WaitForExit(1800)){$watcher.Process.Kill();[void]$watcher.Process.WaitForExit(1000)}}catch{Write-Log ('WATCHER STOP '+$_.Exception.Message) -Level WARN}
        $watcher.Process.Dispose()
        foreach($p in @($watcher.Control,($watcher.Control+'.status'))){try{if([IO.File]::Exists($p)){[IO.File]::Delete($p)}}catch{}}
        $script:ManagedWatcher=$null
    }
}
function Update-ManagedWatcherControl {
    if(-not $script:OwnerProcessId){return $true}
    if(-not (Test-ApplicationOwnerAlive -ProcessId $script:OwnerProcessId -StartTicks $script:OwnerStartTicks)){return $false}
    try{
        $data=[IO.File]::ReadAllText($script:ControlPath,$script:Utf8)|ConvertFrom-Json
        if($data.Token -ne $script:ControlToken -or $data.OwnerProcessId -ne $script:OwnerProcessId -or $data.OwnerStartTicks -ne $script:OwnerStartTicks){return $false}
        if($data.Stop){return $false}
        $script:Ui.Paused=[bool]$data.Paused
        if(([datetime]::UtcNow-$script:LastWatcherStatus).TotalSeconds -ge 1){Write-AtomicUtf8 ($script:ControlPath+'.status') (@{Token=$script:ControlToken;Paused=$script:Ui.Paused;ProcessId=$PID}|ConvertTo-Json -Compress);$script:LastWatcherStatus=[datetime]::UtcNow}
        return $true
    }catch{Write-Log ('WATCHER CONTROL '+$_.Exception.Message);return $false}
}
