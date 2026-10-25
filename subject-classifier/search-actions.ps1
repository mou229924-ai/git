# Search statistics and window restart actions.
function Update-Stats {
    if (Get-Command Update-DirectoryChoices -ErrorAction SilentlyContinue) { Update-DirectoryChoices }
    $entries = @(Load-IndexEntries)
    $withText = @($entries | Where-Object { [bool]$_.hasText }).Count
    $lblSubtitle.Text = [string]::Format([string]$script:Cfg.search.subtitle, $entries.Count)
    $pdf = Get-PdfTextAvailability
    if ($pdf.Available) {
        $pdfNote = 'PDF 文字层可搜索；扫描页可按设置启用文字识别。'
    } else {
        $pdfNote = 'PDF 正文提取不可用：'+$pdf.Reason
    }
    $lblStatus.Text = [string]::Format([string]$script:Cfg.search.statLine, $entries.Count, $withText) + '  ' + $pdfNote
}

function Restart-SearchWindow {
    if ($script:Restarting) { return }
    if ($script:PendingDpi -le 0) { return }
    if ($script:BatchJob -or ($script:DedupeJob -and $script:DedupeJob.Task -eq 'cleanup')) {
        # Keep the visible window until the current mutation can close safely.
        $script:RestartTimer.Start()
        return
    }
    $script:Restarting = $true
    try {
        $subject = ''
        if ($cmbSubject.SelectedIndex -gt 0) { $subject = [string]$cmbSubject.SelectedItem }
        $state = New-Object PSObject -Property @{
            Query = [string]$txtQuery.Text
            Subject = $subject
            Content = [bool]$chkContent.Checked
            CenterX = [int]$script:PendingCenter.X
            CenterY = [int]$script:PendingCenter.Y
            Dpi = [int]$script:PendingDpi
        }
        $statePath = Join-Path $script:AppDir '_restart-state.json'
        [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 4), $script:Utf8)
        $scriptPath = Join-Path $script:AppDir 'search.ps1'
        $arguments = '-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "'+$scriptPath+'" -RestoreFile "'+$statePath+'"'
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $arguments
        $script:RestartTimer.Stop()
        $form.Hide()
        $form.Close()
    } catch {
        $script:Restarting = $false
        $lblStatus.Text = '窗口缩放重载失败：'+$_.Exception.Message
        Write-Log ('UI restart failed: '+$_.Exception.Message) -Level WARN
    }
}
