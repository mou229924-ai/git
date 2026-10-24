# Tray lifetime and polling. Loaded by classifier.ps1 after classifier-scan.ps1.
function Start-TrayApp {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    [System.Windows.Forms.Application]::add_ThreadException({
        param($sender, $e)
        Write-Log ('UI ERROR  ' + $e.Exception.Message)
    })
    [AppDomain]::CurrentDomain.add_UnhandledException({
        param($sender, $e)
        Write-Log ('FATAL  ' + [string]$e.ExceptionObject)
    })

    $script:Context = New-Object System.Windows.Forms.ApplicationContext
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $trayIconFile = Join-Path $script:AppDir 'assets\app.ico'
    try {
        if (Test-Path -LiteralPath $trayIconFile) {
            $script:TrayIcon = New-Object System.Drawing.Icon($trayIconFile)
            $notify.Icon = $script:TrayIcon
        } else {
            $notify.Icon = [System.Drawing.SystemIcons]::Application
        }
    } catch {
        $notify.Icon = [System.Drawing.SystemIcons]::Application
    }
    $notify.Text = [string]$script:Cfg.tray.text
    $notify.Visible = $true

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval=500
    $script:NextClassificationScan=[datetime]::MinValue; $script:ClassificationDirty=$false
    $script:NextClassificationReconcile=[datetime]::MinValue
    Start-IndexChangeMonitor
    $timer.Add_Tick({
        try {
            $changes=Flush-IndexChangeMonitor
            $now=Get-Date
            $pending=($script:States.Count -gt 0 -or $script:FolderStates.Count -gt 0)
            $retryDue=@($script:Defer.Values | Where-Object {$_ -le $now}).Count -gt 0
            if($changes -gt 0){$script:ClassificationDirty=$true}
            if(-not $script:Ui.Paused -and $now -ge $script:NextClassificationScan -and ($script:ClassificationDirty -or $pending -or $retryDue -or $now -ge $script:NextClassificationReconcile)){
                Scan-Once
                $script:ClassificationDirty=$false
                $script:NextClassificationScan=$now.AddSeconds([Math]::Max(1,[int]$script:Cfg.pollSeconds))
                $script:NextClassificationReconcile=$now.AddSeconds(30)
            }
        } catch [System.TimeoutException] {
            # A short library mutation is in progress; the next tick retries fairly.
        } catch {
            Write-Log ('TICK ERROR  ' + $_.Exception.Message)
        }
    })

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $title = [string]$script:Cfg.tray.title
    $rootPath = $script:Root
    $logPath = $script:LogPath
    $searchVbs = Join-Path $script:AppDir 'search.vbs'
    $pauseText = [string]$script:Cfg.tray.menuPause
    $resumeText = [string]$script:Cfg.tray.menuResume
    $runningTip = [string]$script:Cfg.tray.text
    $pausedTip = [string]$script:Cfg.tray.textPaused

    $itemOpen = New-Object System.Windows.Forms.ToolStripMenuItem
    $itemOpen.Text = [string]$script:Cfg.tray.menuOpen
    $itemOpen.Add_Click({
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $rootPath + '"')
    }.GetNewClosure())
    [void]$menu.Items.Add($itemOpen)

    $itemSearch = New-Object System.Windows.Forms.ToolStripMenuItem
    $itemSearch.Text = [string]$script:Cfg.tray.menuSearch
    $itemSearch.Add_Click({
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $searchVbs + '"')
    }.GetNewClosure())
    [void]$menu.Items.Add($itemSearch)

    $itemLog = New-Object System.Windows.Forms.ToolStripMenuItem
    $itemLog.Text = [string]$script:Cfg.tray.menuLog
    $itemLog.Add_Click({
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $logPath + '"')
    }.GetNewClosure())
    [void]$menu.Items.Add($itemLog)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $itemPause = New-Object System.Windows.Forms.ToolStripMenuItem
    $itemPause.Text = $pauseText
    $ui = $script:Ui
    $notifyLocal = $notify
    $pauseItem = $itemPause
    $itemPause.Add_Click({
        $ui.Paused = -not $ui.Paused
        if ($ui.Paused) {
            $pauseItem.Text = $resumeText
            $notifyLocal.Text = $pausedTip
        } else {
            $pauseItem.Text = $pauseText
            $notifyLocal.Text = $runningTip
        }
    }.GetNewClosure())
    [void]$menu.Items.Add($itemPause)

    $itemExit = New-Object System.Windows.Forms.ToolStripMenuItem
    $itemExit.Text = [string]$script:Cfg.tray.menuExit
    $timerLocal = $timer
    $contextLocal = $script:Context
    $itemExit.Add_Click({
        if ($script:Busy) { return }
        $timerLocal.Stop()
        $notifyLocal.Visible = $false
        $notifyLocal.Dispose()
        $contextLocal.ExitThread()
    }.GetNewClosure())
    [void]$menu.Items.Add($itemExit)

    $notify.ContextMenuStrip = $menu
    $notify.Add_DoubleClick({
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $searchVbs + '"')
    }.GetNewClosure())

    $timer.Start()
    $notify.ShowBalloonTip(5000, $title, [string]$script:Cfg.tray.started, [System.Windows.Forms.ToolTipIcon]::Info)
    try{[System.Windows.Forms.Application]::Run($script:Context)}finally{Stop-IndexChangeMonitor;$timer.Dispose();$notify.Dispose()}
}
