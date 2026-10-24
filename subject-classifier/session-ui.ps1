# Search window and listener share one lifetime. Test/capture modes never start a listener.
$watchButton=New-Object Windows.Forms.Button
$watchButton.Text='监听：未开启';$watchButton.Width=(S 142);$watchButton.Height=(S 30)
$watchButton.FlatStyle='Flat';$watchButton.FlatAppearance.BorderSize=0;$watchButton.BackColor=[Drawing.Color]::FromArgb(255,240,186)
$watchButton.Cursor='Hand';$resultActions.Controls.Add($watchButton)
$watchButton.Add_Click({
    try{
        if(-not $script:ManagedWatcher -or $script:ManagedWatcher.Process.HasExited){Ensure-LibraryWatcher}
        else{Set-ManagedLibraryWatcherPaused (-not [bool]$script:ManagedWatcher.Data.Paused)}
    }catch{$lblStatus.Text='监听未启动：'+$_.Exception.Message}
})
$stopWatch=New-Object Windows.Forms.ToolStripMenuItem;$stopWatch.Text='停止分类监听'
$stopWatch.Add_Click({Stop-ManagedLibraryWatcher;$watchButton.Text='监听：已停止';$lblStatus.Text='分类监听已停止，点击监听按钮可重新开启。'})
[void]$moreMenu.Items.Add($stopWatch)
$watchStatusTimer=New-Object Windows.Forms.Timer;$watchStatusTimer.Interval=1000
$watchStatusTimer.Add_Tick({$watchButton.Text='监听：'+(Get-ManagedLibraryWatcherStatus)})
$form.Add_Shown({
    if(-not $SelfTestForm -and -not $UiTestOutput -and -not $Capture){
        try{Ensure-LibraryWatcher;$watchStatusTimer.Start()}catch{$lblStatus.Text='监听未启动：'+$_.Exception.Message}
    }
})
$form.Add_FormClosed({$watchStatusTimer.Stop();$watchStatusTimer.Dispose();Stop-ManagedLibraryWatcher})
