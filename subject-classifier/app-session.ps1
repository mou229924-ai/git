# Session IPC is serialized in place because some EFS state directories reject file renames.
# Configuration and index files keep their separate atomic writer.
function Write-SessionStateUtf8 {
    param(
        [string]$Path,
        [string]$Text,
        [ValidateRange(1,5000)][int]$TimeoutMilliseconds = 500
    )

    if (-not ('Nailong.SessionStateFile' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'SessionState.cs')
    }
    [Nailong.SessionStateFile]::WriteUtf8($Path, $Text, $TimeoutMilliseconds)
}

function Read-SessionStateUtf8 {
    param(
        [string]$Path,
        [ValidateRange(1,5000)][int]$TimeoutMilliseconds = 200
    )

    if (-not ('Nailong.SessionStateFile' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'SessionState.cs')
    }
    return [Nailong.SessionStateFile]::ReadUtf8($Path, $TimeoutMilliseconds)
}

# Importing the application-owned process helpers never starts a listener.
function Test-ApplicationOwnerAlive {
    param([int]$ProcessId, [long]$StartTicks)

    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById($ProcessId)
        return (-not $process.HasExited -and $process.StartTime.ToUniversalTime().Ticks -eq $StartTicks)
    } catch {
        return $false
    } finally {
        if ($process) {
            $process.Dispose()
        }
    }
}

function Start-ManagedLibraryWatcher {
    if ($script:ManagedWatcher -and -not $script:ManagedWatcher.Process.HasExited) {
        return
    }
    if ($script:ManagedWatcher) {
        Stop-ManagedLibraryWatcher
    }

    [void][IO.Directory]::CreateDirectory($script:StateDir)
    $owner = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $started = $owner.StartTime.ToUniversalTime().Ticks
    } finally {
        $owner.Dispose()
    }

    $control = Join-Path $script:StateDir ('watcher-' + $PID + '-' + [guid]::NewGuid().ToString('N') + '.json')
    $data = @{
        OwnerProcessId = $PID
        OwnerStartTicks = $started
        Paused = $false
        Stop = $false
        Token = [guid]::NewGuid().ToString('N')
    }
    Write-SessionStateUtf8 $control ($data | ConvertTo-Json -Compress)
    $arguments = '-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "' +
        (Join-Path $script:AppDir 'classifier.ps1') + '" -EnsureRunning -OwnerProcessId ' + $PID +
        ' -OwnerStartTicks ' + $started + ' -ControlPath "' + $control + '" -ControlToken ' + $data.Token
    try {
        $process = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments -PassThru
        $processHandle = $process.Handle
        $script:ManagedWatcher = @{
            Process = $process
            Control = $control
            Data = $data
            Started = Get-Date
            LastStatus = '启动中'
        }
    } catch {
        $startFailure = $_
        try {
            if ([IO.File]::Exists($control)) {
                [IO.File]::Delete($control)
            }
        } catch {
            Write-Log ('WATCHER START CLEANUP ' + $_.Exception.Message) -Level WARN -Exception $_.Exception
        }
        throw $startFailure
    }
}

function Set-ManagedLibraryWatcherPaused {
    param([bool]$Paused)

    if (-not $script:ManagedWatcher -or $script:ManagedWatcher.Process.HasExited) {
        Start-ManagedLibraryWatcher
    }
    $previous = $script:ManagedWatcher.Data.Paused
    $script:ManagedWatcher.Data.Paused = $Paused
    try {
        Write-SessionStateUtf8 $script:ManagedWatcher.Control ($script:ManagedWatcher.Data | ConvertTo-Json -Compress)
    } catch {
        # Keep the next button action consistent if this pause request was not delivered.
        $script:ManagedWatcher.Data.Paused = $previous
        throw
    }
}

function Get-ManagedLibraryWatcherStatus {
    if (-not $script:ManagedWatcher) {
        return '已停止'
    }
    if ($script:ManagedWatcher.Process.HasExited) {
        return '已停止（可重新开启）'
    }

    $status = $script:ManagedWatcher.Control + '.status'
    if (-not [IO.File]::Exists($status)) {
        return '启动中'
    }
    try {
        $data = (Read-SessionStateUtf8 -Path $status) | ConvertFrom-Json
        if (-not $data -or $data.Token -cne $script:ManagedWatcher.Data.Token -or
            $data.ProcessId -ne $script:ManagedWatcher.Process.Id) {
            Write-Log 'WATCHER STATUS identity mismatch' -Level WARN -ThrottleSeconds 30
            return '状态无效'
        }
        $current = '运行中'
        if ($data.Paused) {
            $current = '已暂停'
        }
        $script:ManagedWatcher.LastStatus = $current
        return $current
    } catch {
        $cause = $_.Exception.GetBaseException()
        if ($cause -is [TimeoutException]) {
            Write-Log 'WATCHER STATUS BUSY; retrying next tick' -Level INFO -Exception $cause -ThrottleSeconds 30
            if ($script:ManagedWatcher.LastStatus) {
                return $script:ManagedWatcher.LastStatus
            }
            return '状态更新中'
        }
        Write-Log ('WATCHER STATUS READ ' + $cause.Message) -Level WARN -Exception $cause -ThrottleSeconds 30
        return '状态不可用'
    }
}

function Stop-ManagedLibraryWatcher {
    if (-not $script:ManagedWatcher) {
        return
    }
    $watcher = $script:ManagedWatcher
    try {
        if (-not $watcher.Process.HasExited) {
            $watcher.Data.Stop = $true
            Write-SessionStateUtf8 $watcher.Control ($watcher.Data | ConvertTo-Json -Compress)
        }
    } catch {
        Write-Log ('WATCHER STOP REQUEST ' + $_.Exception.Message) -Level WARN -Exception $_.Exception
    } finally {
        try {
            if (-not $watcher.Process.HasExited -and -not $watcher.Process.WaitForExit(1800)) {
                $watcher.Process.Kill()
                [void]$watcher.Process.WaitForExit(1000)
            }
        } catch {
            Write-Log ('WATCHER STOP ' + $_.Exception.Message) -Level WARN -Exception $_.Exception
        }
        $watcher.Process.Dispose()
        foreach ($path in @($watcher.Control, ($watcher.Control + '.status'))) {
            try {
                if ([IO.File]::Exists($path)) {
                    [IO.File]::Delete($path)
                }
            } catch {
                Write-Log ('WATCHER CLEANUP ' + $_.Exception.Message) -Level WARN -Exception $_.Exception
            }
        }
        $script:ManagedWatcher = $null
    }
}

function Update-ManagedWatcherControl {
    if (-not $script:OwnerProcessId) {
        return $true
    }
    if (-not (Test-ApplicationOwnerAlive -ProcessId $script:OwnerProcessId -StartTicks $script:OwnerStartTicks)) {
        Write-Log 'WATCHER OWNER no longer matches the owning process' -Level WARN -ThrottleSeconds 30
        return $false
    }

    try {
        $data = (Read-SessionStateUtf8 -Path $script:ControlPath) | ConvertFrom-Json
        if (-not $data -or $data.Token -cne $script:ControlToken -or
            $data.OwnerProcessId -ne $script:OwnerProcessId -or $data.OwnerStartTicks -ne $script:OwnerStartTicks) {
            Write-Log 'WATCHER CONTROL identity mismatch; stopping listener' -Level WARN -ThrottleSeconds 30
            return $false
        }
        if ($data.Stop) {
            return $false
        }
        $script:Ui.Paused = [bool]$data.Paused
        if (([datetime]::UtcNow - $script:LastWatcherStatus).TotalSeconds -ge 1) {
            $heartbeat = @{
                Token = $script:ControlToken
                Paused = $script:Ui.Paused
                ProcessId = $PID
            }
            Write-SessionStateUtf8 ($script:ControlPath + '.status') ($heartbeat | ConvertTo-Json -Compress)
            $script:LastWatcherStatus = [datetime]::UtcNow
        }
        return $true
    } catch {
        $cause = $_.Exception.GetBaseException()
        if ($cause -is [TimeoutException]) {
            # Another participant holds a complete message. Preserve process state and retry next tick.
            Write-Log 'WATCHER CONTROL BUSY; retrying next tick' -Level INFO -Exception $cause -ThrottleSeconds 30
            return $true
        }
        Write-Log ('WATCHER CONTROL ' + $cause.Message) -Level WARN -Exception $cause -ThrottleSeconds 30
        return $false
    }
}
