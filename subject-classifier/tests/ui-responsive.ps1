$ErrorActionPreference='Stop'
$rootFull=[IO.Path]::GetFullPath($script:Root)
if (-not $rootFull.StartsWith(([IO.Path]::GetFullPath($script:AppDir).TrimEnd('\')+'\test-library'),[StringComparison]::OrdinalIgnoreCase)) { throw '响应测试仅允许在隔离资料库中运行。' }
$journalPath=Join-Path $script:AppDir '_dedupe-journal.jsonl'
$journalBefore=0;if([IO.File]::Exists($journalPath)){$journalBefore=(Get-Item -LiteralPath $journalPath).Length}
$fixturePath=Join-Path $script:Root '物理\真实PDF预览测试.pdf'
$fixtureHash=(Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
$script:UiChecks=New-Object Collections.ArrayList
function Ui-Check([string]$Name,[bool]$Passed){[void]$script:UiChecks.Add(@{Name=$Name;Passed=$Passed});Write-Output ($Name+': '+$Passed)}
function Pump-Ui([int]$Milliseconds){$deadline=(Get-Date).AddMilliseconds($Milliseconds);while((Get-Date)-lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 15}}
$form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(30,30);$form.Show()
$script:Heartbeats=0
$heartbeat=New-Object Windows.Forms.Timer;$heartbeat.Interval=30;$heartbeat.Add_Tick({$script:Heartbeats++});$heartbeat.Start()
try{
    Ui-Check 'Search input is separated from the magnifier' ($txtQuery.Left -ge (S 45))
    Ui-Check 'Search input stays clear of the search button' (($txtQuery.Right+(S 5)) -lt $btnSearch.Left)
    Ui-Check 'Search field occupies the main content width' ($searchShell.Width -gt ($form.ClientSize.Width*0.65))
    # Hold the library lock so a scan definitely remains in progress while UI messages are pumped.
    Invoke-LibraryLock {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        Show-DuplicateReview
        $watch.Stop()
        Ui-Check 'Starting duplicate scan returns without waiting for hashing' ($watch.ElapsedMilliseconds -lt 1500)
        $before=$script:Heartbeats
        Pump-Ui 1400
        Ui-Check 'UI timer remains responsive while duplicate scan is blocked' (($script:Heartbeats-$before) -ge 15)
        Ui-Check 'Duplicate scan runs in another process' ($script:DedupeJob -and $script:DedupeJob.Process.Id -ne $PID)
        $watch.Restart();Cancel-DuplicateScan;$watch.Stop()
        Ui-Check 'Scan cancellation releases background task promptly' (-not $script:DedupeJob -and $watch.ElapsedMilliseconds -lt 2200)
    }
    Pump-Ui 300
    $deadline=(Get-Date).AddSeconds(20)
    while($script:SearchJob -and (Get-Date)-lt $deadline){Pump-Ui 100}
    Ui-Check 'Background search completes and populates file list' ($list.Items.Count -gt 0)
    $pdf=Get-ChildItem -LiteralPath $script:Root -Recurse -File -Filter '真实PDF预览测试.pdf' | Select-Object -First 1
    Show-FilePreview $pdf.FullName
    $deadline=(Get-Date).AddSeconds(20)
    while($script:PreviewJob -and -not $script:PreviewJob.Ready -and (Get-Date)-lt $deadline){Pump-Ui 100}
    Ui-Check 'PDF preview runs independently and reaches ready state' ($script:PreviewJob -and $script:PreviewJob.Ready -and $script:PreviewJob.Process.Id -ne $PID)
    Ui-Check 'Native preview is embedded in the right-hand pane' ($script:PreviewJob -and [Nailong.Native]::GetParent([IntPtr]$script:PreviewJob.Handle) -eq $previewHost.Handle)
    $before=$script:Heartbeats;Pump-Ui 400
    Ui-Check 'UI stays responsive with native PDF preview active' (($script:Heartbeats-$before) -ge 4)
    if($script:PreviewJob){$script:PreviewJob.Process.Kill();$null=$script:PreviewJob.Process.WaitForExit(1500)}
    Pump-Ui 400
    Ui-Check 'Terminating preview cannot terminate or freeze main window' (-not $script:PreviewJob -and -not $form.IsDisposed)
    Ui-Check 'Preview process releases the source PDF' (Test-FileReady $pdf.FullName)
    $sourceHash=(Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash
    $journalAfter=0;if([IO.File]::Exists($journalPath)){$journalAfter=(Get-Item -LiteralPath $journalPath).Length}
    Ui-Check 'Cancelled scan never appends a deletion action' ($journalBefore -eq $journalAfter)
    Ui-Check 'Original source fixture remains unchanged' ($fixtureHash -eq (Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash)
}catch{Ui-Check ('Unhandled test error: '+$_.Exception.Message) $false;Write-Output $_.ScriptStackTrace}
finally{
    $heartbeat.Stop();$heartbeat.Dispose()
    Cancel-DuplicateScan;Stop-FilePreview
    $uiResultSummary=@{Passed=@($script:UiChecks | Where-Object Passed).Count;Failed=@($script:UiChecks | Where-Object {-not $_.Passed}).Count;Checks=@($script:UiChecks.ToArray())}
    [IO.File]::WriteAllText($UiTestOutput,($uiResultSummary|ConvertTo-Json -Depth 5),$script:Utf8)
    $form.Close();$form.Dispose()
}
if($uiResultSummary.Failed){exit 1}
