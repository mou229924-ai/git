# Batch file operations run in their own worker. Cancellation is checked between files.
$script:BatchJob=$null
$batchProgress=New-Object Windows.Forms.ProgressBar;$batchProgress.Dock='Fill';$batchProgress.Visible=$false
$batchCancel=New-Object Windows.Forms.Button;$batchCancel.Text='停止后续';$batchCancel.Dock='Fill';$batchCancel.Visible=$false
$statusRow.ColumnCount=5
[void]$statusRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',0)))
[void]$statusRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',0)))
$statusRow.Controls.Add($batchProgress,3,0);$statusRow.Controls.Add($batchCancel,4,0)
$batchResultTip=New-Object Windows.Forms.ToolTip
function Start-LibraryBatchJob {
    param([hashtable]$Request)
    if($script:BatchJob){$lblStatus.Text='请先等待当前批量任务完成。';return}
    if($script:DedupeJob -and $script:DedupeJob.Task -eq 'cleanup'){$lblStatus.Text='回收正在执行，请完成后再处理其他文件。';return}
    Cancel-DuplicateScan;Stop-FilePreview
    $script:BatchJob=Start-LibraryJob $Request
    $script:BatchJob.CancelRequested=$false
    $batchProgress.Minimum=0;$batchProgress.Maximum=[Math]::Max(1,@($Request.Paths).Count);$batchProgress.Value=0
    $batchProgress.Visible=$true;$batchCancel.Visible=$true;$batchCancel.Enabled=$true;$batchCancel.Text='停止后续'
    $statusRow.ColumnStyles[3].Width=(S 130);$statusRow.ColumnStyles[4].Width=(S 96)
    $lblStatus.Text='批量任务已在后台启动，可继续搜索和预览。'
}
function Show-PreparedPrintPlan {
    param($Data)
    if($Data.Cancelled){$lblStatus.Text='已停止打印检查，未提交打印任务。';return}
    $supported=@($Data.Outcomes | Where-Object Supported)
    $unsupported=@($Data.Outcomes | Where-Object {-not $_.Supported})
    $summary='Windows 默认打印机：'+$Data.PrinterName+[Environment]::NewLine+'可提交 '+$supported.Count+' 个，跳过 '+$unsupported.Count+' 个。'
    if(-not $supported.Count){$lblStatus.Text=$summary;return}
    $summary+=[Environment]::NewLine+[Environment]::NewLine+'提交到打印应用？纸张和份数使用关联应用的设置，实际完成情况请查看 Windows 打印队列。'
    if([Windows.Forms.MessageBox]::Show($form,$summary,'批量打印','YesNo','Question') -eq 'Yes'){
        Start-LibraryBatchJob @{Task='print';Paths=@($supported | ForEach-Object Path);PrinterName=$Data.PrinterName}
    }
}
$batchCancel.Add_Click({
    if(-not $script:BatchJob){return}
    Write-AtomicUtf8 ($script:BatchJob.Result+'.cancel') ''
    $script:BatchJob.CancelRequested=$true;$batchCancel.Enabled=$false;$batchCancel.Text='正在停止'
    $lblStatus.Text='等待当前文件处理完成后停止；已移入、移出或提交打印的项目会保留。'
})
$batchTimer=New-Object Windows.Forms.Timer;$batchTimer.Interval=160
$batchTimer.Add_Tick({
    $job=$script:BatchJob;if(-not $job){return}
    $state=Read-LibraryJob $job
    $title=switch($job.Task){'import'{'移入资料库'}'export'{'移出资料库'}'print'{'提交到打印应用'}default{'检查打印支持'}}
    if($state -and $state.State -eq 'running'){
        $done=[Math]::Max(0,[int]$state.Data.Done);$total=[Math]::Max(1,[int]$state.Data.Total)
        $batchProgress.Maximum=$total;$batchProgress.Value=[Math]::Min($total,$done)
        if(-not $job.CancelRequested){$lblStatus.Text=$title+'  '+$done+' / '+[int]$state.Data.Total+'   ·   可继续搜索和预览'}
        return
    }
    if(-not $state -or $state.State -notin @('done','failed')){
        if(-not $job.Process.HasExited){return}
        $state=@{State='failed';Error='后台任务意外退出，已处理项目请刷新查看；不会自动重试打印。'}
    }
    $task=$job.Task;$script:BatchJob=$null;Close-LibraryJob $job
    $batchProgress.Visible=$false;$batchCancel.Visible=$false;$statusRow.ColumnStyles[3].Width=0;$statusRow.ColumnStyles[4].Width=0
    if($state.State -eq 'failed'){$lblStatus.Text=$state.Error;return}
    if($task -eq 'print-plan'){Show-PreparedPrintPlan $state.Data;return}
    $outcomes=@($state.Data.Outcomes)
    $success=@($outcomes | Where-Object {$_.Success -or $_.Status -eq 'submitted'}).Count
    $errors=@($outcomes | Where-Object {($_.PSObject.Properties['Success'] -and -not $_.Success) -or $_.Status -eq 'skipped'})
    $prefix='';if($state.Data.Cancelled){$prefix='已停止后续项目。'}
    if($task -eq 'print'){$lblStatus.Text=$prefix+'已交给打印应用 '+$success+' 个，失败/跳过 '+$errors.Count+' 个。实际进度请查看 Windows 打印队列。'}
    elseif($task -eq 'import'){
        if($success){Ensure-LibraryWatcher;Request-IndexRefresh -Paths @($outcomes | Where-Object Success | ForEach-Object Target)}
        $lblStatus.Text=$prefix+'已移入 '+$success+' 个，跳过 '+$errors.Count+' 个；后台将自动分类。';Invoke-Search
    }else{Request-IndexRefresh -Paths @($outcomes | Where-Object Success | ForEach-Object Source);$lblStatus.Text=$prefix+'已移出 '+$success+' 个，跳过 '+$errors.Count+' 个。';Invoke-Search}
    $details=@($errors | ForEach-Object {([string]$_.Source)+([string]$_.Path)+'：'+$_.Error}) -join [Environment]::NewLine
    if($details){$batchResultTip.SetToolTip($lblStatus,$details)}else{$batchResultTip.SetToolTip($lblStatus,'')}
})
$form.Add_Shown({$batchTimer.Start()})
$moveDesktop=New-Object Windows.Forms.ToolStripMenuItem;$moveDesktop.Text='移动所选到桌面'
$moveDesktop.Add_Click({
    $paths=@($list.SelectedItems | ForEach-Object {[string]$_.Tag});if(-not $paths.Count){return}
    Start-LibraryBatchJob @{Task='export';Paths=$paths;Destination=[Environment]::GetFolderPath('DesktopDirectory')}
})
[void]$ctx.Items.Add($moveDesktop)
$form.Add_FormClosing({param($sender,$e)
    if(($script:BatchJob -and -not $script:BatchJob.Process.HasExited) -or ($script:DedupeJob -and $script:DedupeJob.Task -eq 'cleanup' -and -not $script:DedupeJob.Process.HasExited)){
        $e.Cancel=$true;$lblStatus.Text='文件操作正在执行。请等待完成，或使用“停止后续”后再关闭；回收执行期间需要等待完成。'
    }
})
$form.Add_FormClosed({$batchTimer.Stop();$batchTimer.Dispose();$batchResultTip.Dispose();if($script:BatchJob){Close-LibraryJob $script:BatchJob};Flush-ApplicationLogs -Force})
