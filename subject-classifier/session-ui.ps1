# The listener belongs to this window and follows its lifecycle.
$watchButton = New-Object Windows.Forms.Button
$watchButton.Text = '监听：未开启'
$watchButton.Width = (S 142)
$watchButton.Height = (S 30)
$watchButton.FlatStyle = 'Flat'
$watchButton.FlatAppearance.BorderSize = 0
$watchButton.UseVisualStyleBackColor = $false
$watchButton.BackColor = [Drawing.Color]::FromArgb(255,240,186)
$watchButton.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(255,231,151)
$watchButton.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(249,217,120)
$watchButton.Cursor = 'Hand'
$watchButton.Add_SizeChanged({
    param($sender,$eventArgs)
    Set-RoundedRegion -Control $sender -Radius (S 10)
})
$resultActions.Controls.Add($watchButton)
Set-RoundedRegion -Control $watchButton -Radius (S 10)
$watchButton.Add_Click({
    try {
        $status = Get-ManagedLibraryWatcherStatus
        Set-ManagedLibraryWatcherPaused ($status -match '运行中')
        $watchButton.Text = '监听：'+(Get-ManagedLibraryWatcherStatus)
    } catch {
        $lblStatus.Text = '监听未启动：'+$_.Exception.Message
    }
})
$stopWatch = New-Object Windows.Forms.ToolStripMenuItem
$stopWatch.Text = '停止分类监听'
$stopWatch.Add_Click({
    Stop-ManagedLibraryWatcher
    $watchButton.Text = '监听：已停止'
    $lblStatus.Text = '分类监听已停止，点击监听按钮可重新开启。'
})
[void]$moreMenu.Items.Add($stopWatch)
$watchStatusTimer = New-Object Windows.Forms.Timer
$watchStatusTimer.Interval = 1000
$watchStatusTimer.Add_Tick({
    $watchButton.Text = '监听：'+(Get-ManagedLibraryWatcherStatus)
})
$form.Add_Shown({
    if (-not $SelfTestForm -and -not $UiTestOutput -and -not $Capture) {
        try {
            Ensure-LibraryWatcher
            $watchStatusTimer.Start()
        } catch {
            $lblStatus.Text = '监听未启动：'+$_.Exception.Message
        }
    }
})
$form.Add_FormClosed({
    $watchStatusTimer.Stop()
    $watchStatusTimer.Dispose()
    Stop-ManagedLibraryWatcher
})
