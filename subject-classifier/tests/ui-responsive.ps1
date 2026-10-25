$ErrorActionPreference='Stop'
$headless=$env:NAILONG_TEST_HEADLESS -eq '1'
$skippedInteractive=New-Object Collections.ArrayList
$rootFull=[IO.Path]::GetFullPath($script:Root)
if (-not $rootFull.StartsWith(([IO.Path]::GetFullPath($script:AppDir).TrimEnd('\')+'\test-library'),[StringComparison]::OrdinalIgnoreCase)) { throw '响应测试仅允许在隔离资料库中运行。' }
$journalPath=Join-Path $script:AppDir '_dedupe-journal.jsonl'
$journalBefore=0;if([IO.File]::Exists($journalPath)){$journalBefore=(Get-Item -LiteralPath $journalPath).Length}
$fixturePath=Join-Path $script:Root '物理\真实PDF预览测试.pdf'
if($headless){$fixturePath=Join-Path $script:Root '物理\preview-fixture.png'}
$fixtureHash=(Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
$script:UiChecks=New-Object Collections.ArrayList
function Ui-Check([string]$Name,[bool]$Passed){[void]$script:UiChecks.Add(@{Name=$Name;Passed=$Passed});Write-Output ($Name+': '+$Passed)}
function Pump-Ui([int]$Milliseconds){$deadline=(Get-Date).AddMilliseconds($Milliseconds);while((Get-Date)-lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 15}}
$form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(30,30);$form.Show()
$script:Heartbeats=0
$heartbeat=New-Object Windows.Forms.Timer;$heartbeat.Interval=30;$heartbeat.Add_Tick({$script:Heartbeats++});$heartbeat.Start()
try{
    Pump-Ui 160
    Ui-Check 'Result actions including listener stay inside the header' ($resultActions.Right -le $resultHeader.ClientSize.Width -and $watchButton.Right -le $resultActions.ClientSize.Width)
    Ui-Check 'Both page buttons stay entirely inside the footer' ($pageNextButton.Right -le $pageBar.ClientSize.Width -and $pageNextButton.Bottom -le $pageBar.ClientSize.Height -and $pagePreviousButton.Left -ge 0)
    $savedWindowSize=$form.Size;$form.Size=$form.MinimumSize;Pump-Ui 160
    Ui-Check 'Commands and paging fit the minimum window width' ($resultActions.Right -le $resultHeader.ClientSize.Width -and $pageNextButton.Right -le $pageBar.ClientSize.Width -and $resultLayout.Right -le ($resultCard.ClientSize.Width-$resultCard.Padding.Right))
    $form.Size=$savedWindowSize;Pump-Ui 160
    Ui-Check 'Search input is separated from the magnifier' ($txtQuery.Left -ge (S 45))
    Ui-Check 'Search input stays clear of the search button' (($txtQuery.Right+(S 5)) -lt $btnSearch.Left)
    Ui-Check 'Search field occupies the main content width' ($searchShell.Width -gt ($form.ClientSize.Width*0.65))
    # Use a deterministic independent task: read-only scans no longer wait on the library lock.
    $script:UiOriginalJobStarter=(Get-Command Start-LibraryJob).ScriptBlock
    function Start-LibraryJob {
        param([hashtable]$Request)
        if($Request.Task -ne 'scan'){return (& $script:UiOriginalJobStarter -Request $Request)}
        $id=[guid]::NewGuid().ToString('N')
        $resultPath=Join-Path $script:AppDir ('_jobs\'+$id+'.ui-barrier.json')
        $workerPath=Join-Path $script:AppDir 'tests\ui-barrier-worker.ps1'
        $arguments='-NoProfile -ExecutionPolicy RemoteSigned -File "'+$workerPath+'" -Result "'+$resultPath+'"'
        $process=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments -PassThru
        return @{Process=$process;Request='';Result=$resultPath;Task='scan';Started=(Get-Date);Auto=$false}
    }
    try {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        Show-DuplicateReview
        $watch.Stop()
        Ui-Check 'Starting duplicate scan returns without waiting for hashing' ($watch.ElapsedMilliseconds -lt 1500)
        $before=$script:Heartbeats
        Pump-Ui 1400
        Ui-Check 'UI timer remains responsive while a background scan task waits' (($script:Heartbeats-$before) -ge 15)
        Ui-Check 'Duplicate scan runs in another process' ($script:DedupeJob -and $script:DedupeJob.Process.Id -ne $PID)
        $watch.Restart();Cancel-DuplicateScan;$watch.Stop()
        Ui-Check 'Scan cancellation releases background task promptly' (-not $script:DedupeJob -and $watch.ElapsedMilliseconds -lt 2200)
    } finally {
        Cancel-DuplicateScan
        Set-Item Function:\Start-LibraryJob -Value $script:UiOriginalJobStarter
    }
    Pump-Ui 300
    $deadline=(Get-Date).AddSeconds(20)
    # Initial full-text extraction may outlive the first metadata-only search.
    while(($script:SearchJob -or $script:IndexJob -or $list.Items.Count -eq 0) -and (Get-Date)-lt $deadline){Pump-Ui 100}
    Ui-Check 'Background search completes and populates file list' ($list.Items.Count -gt 0)
    $pdf=Get-Item -LiteralPath $fixturePath
    Show-FilePreview $pdf.FullName
    $deadline=(Get-Date).AddSeconds(20)
    while($script:PreviewJob -and -not $script:PreviewJob.Ready -and (Get-Date)-lt $deadline){Pump-Ui 100}
    Ui-Check 'Synthetic file preview runs independently and reaches ready state' ($script:PreviewJob -and $script:PreviewJob.Ready -and $script:PreviewJob.Process.Id -ne $PID)
    Ui-Check 'Native preview is embedded in the right-hand pane' ($script:PreviewJob -and [Nailong.Native]::GetParent([IntPtr]$script:PreviewJob.Handle) -eq $previewHost.Handle)
    # Opening a modal input must still work while a cross-process preview is embedded.
    $dialogProbe=@{Deadline=(Get-Date).AddSeconds(5);Handled=$false}
    $dialogTimer=New-Object Windows.Forms.Timer; $dialogTimer.Interval=200
    $dialogTimer.Add_Tick({
        $directoryDialog=@([Windows.Forms.Application]::OpenForms) | Where-Object {$_.Text -eq '奶龙.code · 管理目录与分类规则'} | Select-Object -First 1
        if($directoryDialog -and -not $dialogProbe.Handled){
            $dialogProbe.Handled=$true
            $directoryInput=$directoryDialog.Controls[0].Controls | Where-Object {$_ -is [Windows.Forms.ComboBox]} | Select-Object -First 1
            Ui-Check 'Directory dialog stays owned by the library with preview active' ($directoryDialog.Owner -eq $form)
            if($headless){
                [void]$skippedInteractive.Add('Directory input keyboard focus with preview (requires an interactive desktop)')
                Ui-Check 'Directory input stays editable with preview in headless mode' ($directoryInput.Enabled -and $directoryInput.DropDownStyle -ne 'DropDownList')
            }else{Ui-Check 'Directory input gets focus while native preview is active' $directoryInput.ContainsFocus}
            $directoryDialog.CancelButton.PerformClick()
        } elseif($directoryDialog -and (Get-Date) -gt $dialogProbe.Deadline){$directoryDialog.Close()}
    }.GetNewClosure())
    $dialogTimer.Start()
    try{Show-DirectoryManager}finally{$dialogTimer.Stop();$dialogTimer.Dispose()}
    Ui-Check 'Closing directory dialog restores the live preview and library' ($dialogProbe.Handled -and -not $script:UiUpdating -and $form.Enabled -and $script:PreviewJob.Ready)
    $before=$script:Heartbeats;Pump-Ui 400
    Ui-Check 'UI stays responsive with synthetic preview active' (($script:Heartbeats-$before) -ge 4)
    if($script:PreviewJob){$script:PreviewJob.Process.Kill();$null=$script:PreviewJob.Process.WaitForExit(1500)}
    Pump-Ui 400
    Ui-Check 'Terminating preview cannot terminate or freeze main window' (-not $script:PreviewJob -and -not $form.IsDisposed)
    Ui-Check 'Preview process releases the synthetic source file' (Test-FileReady $pdf.FullName)
    $sourceHash=(Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash
    $journalAfter=0;if([IO.File]::Exists($journalPath)){$journalAfter=(Get-Item -LiteralPath $journalPath).Length}
    Ui-Check 'Cancelled scan never appends a deletion action' ($journalBefore -eq $journalAfter)
    # Real batch workers move only these synthetic files; they must not block the UI.
    $savedEnsure=(Get-Command Ensure-LibraryWatcher).ScriptBlock
    function Ensure-LibraryWatcher {$script:UiBatchWatcherRequested=$true}
    $batchSource=Join-Path $script:AppDir ('ui-batch-'+[guid]::NewGuid().ToString('N')+'.txt')
    $batchExport=Join-Path $script:AppDir ('_ui-export-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($batchExport)
    [IO.File]::WriteAllText($batchSource,'synthetic-ui-batch-content',$script:Utf8)
    try{
        $before=$script:Heartbeats;$watch=[Diagnostics.Stopwatch]::StartNew()
        Start-LibraryBatchJob @{Task='import';Paths=@($batchSource)};$watch.Stop()
        Ui-Check 'Starting a real batch import returns promptly' ($watch.ElapsedMilliseconds -lt 1800 -and $script:BatchJob.Process.Id -ne $PID)
        $deadline=(Get-Date).AddSeconds(20);while($script:BatchJob -and (Get-Date)-lt $deadline){Pump-Ui 80}
        $batchImported=Join-Path $script:Root ([IO.Path]::GetFileName($batchSource))
        Ui-Check 'Batch import completes with original bytes and UI heartbeats' (-not $script:BatchJob -and [IO.File]::Exists($batchImported) -and [IO.File]::ReadAllText($batchImported) -eq 'synthetic-ui-batch-content' -and ($script:Heartbeats-$before) -ge 4)
        Start-LibraryBatchJob @{Task='export';Paths=@($batchImported);Destination=$batchExport}
        $deadline=(Get-Date).AddSeconds(20);while($script:BatchJob -and (Get-Date)-lt $deadline){Pump-Ui 80}
        Ui-Check 'Batch export completes and releases the progress UI' (-not $script:BatchJob -and -not $batchProgress.Visible -and -not [IO.File]::Exists($batchImported) -and [IO.File]::ReadAllText((Join-Path $batchExport ([IO.Path]::GetFileName($batchSource)))) -eq 'synthetic-ui-batch-content')
    }finally{Set-Item Function:\Ensure-LibraryWatcher -Value $savedEnsure}
    Ui-Check 'Original source fixture remains unchanged' ($fixtureHash -eq (Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash)
}catch{Ui-Check ('Unhandled test error: '+$_.Exception.Message) $false;Write-Output $_.ScriptStackTrace}
finally{
    $heartbeat.Stop();$heartbeat.Dispose()
    Cancel-DuplicateScan;Stop-FilePreview
    $uiResultSummary=@{Passed=@($script:UiChecks | Where-Object Passed).Count;Failed=@($script:UiChecks | Where-Object {-not $_.Passed}).Count;Checks=@($script:UiChecks.ToArray());Headless=[bool]$headless;SkippedInteractiveAssertions=@($skippedInteractive.ToArray())}
    [IO.File]::WriteAllText($UiTestOutput,($uiResultSummary|ConvertTo-Json -Depth 5),$script:Utf8)
    $form.Close();$form.Dispose()
}
if($uiResultSummary.Failed){exit 1}
