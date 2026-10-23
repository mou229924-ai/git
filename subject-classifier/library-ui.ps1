$script:UiUpdating = $false
$script:AutoDedupe = $false
$script:LastLibrarySignature = ''

function Update-FilePreview {
    if ($list.SelectedItems.Count -eq 0) { return }
    $file = [string]$list.SelectedItems[0].Tag
    $previewTitle.Text = [IO.Path]::GetFileName($file)
    $previewImage.Visible = $false
    if ($previewImage.Image) { $previewImage.Image.Dispose(); $previewImage.Image = $null }
    $previewText.Visible = $true
    $previewText.Text = '正在读取预览…'
    try {
        $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
        if ($ext -eq '.pdf') {
            $previewImage.Image = Get-PdfPreviewImage $file
            $previewImage.Visible = $true; $previewText.Visible = $false
            $previewHint.Text = 'PDF 首页预览 · 双击文件可查看全部页面。'
        } elseif (@('.png','.jpg','.jpeg','.bmp','.gif') -contains $ext) {
            $image = [Drawing.Image]::FromFile($file)
            try { $previewImage.Image = New-Object Drawing.Bitmap($image) } finally { $image.Dispose() }
            $previewImage.Visible = $true; $previewText.Visible = $false
            $previewHint.Text = '图片预览 · 原文件保持不变。'
        } else {
            $text = Get-FileText -Path $file -Max 16000
            if ([string]::IsNullOrWhiteSpace($text)) { $text = '此格式暂不支持内嵌预览。双击文件可用默认程序打开。' }
            $previewText.Text = $text
            $previewHint.Text = '正文节选预览，排版请在原应用中查看。'
        }
    } catch {
        $previewText.Text = '暂时无法预览：' + $_.Exception.Message + "`r`n可双击文件打开。"
    }
}

function Ensure-LibraryWatcher {
    $scriptPath = Join-Path $script:AppDir 'classifier.ps1'
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $scriptPath + '" -EnsureRunning')
}

function Show-DuplicateReview {
    if ($script:UiUpdating) { return }
    $script:UiUpdating = $true
    $refreshTimer.Stop()
    try {
        $form.Cursor = 'WaitCursor'
        $plan = @(Find-DuplicateDocuments)
        $form.Cursor = 'Default'
        if ($plan.Count -eq 0) {
            [void][Windows.Forms.MessageBox]::Show('未发现内容完全相同的非空文档。文件同名或格式不同，不会单独作为删除依据。', '重复文档检查')
            return
        }
        $dialog = New-Object Windows.Forms.Form
        $dialog.Text = '重复文档预演 — 勾选后送入回收站'
        $dialog.BackColor=$script:ColBg
        $dialog.Size = New-Object Drawing.Size((S 1020), (S 540))
        $dialog.MinimumSize = New-Object Drawing.Size((S 780), (S 400))
        $dialog.StartPosition = 'CenterParent'
        $dialog.Font = $form.Font
        $layout = New-Object Windows.Forms.TableLayoutPanel
        $layout.Dock = 'Fill'; $layout.RowCount = 3; $layout.ColumnCount = 1
        $layout.Padding = New-Object Windows.Forms.Padding((S 16))
        [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',(S 60))))
        [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
        [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',(S 52))))
        $dialog.Controls.Add($layout)
        $summary = New-Object Windows.Forms.Label
        $summary.Dock = 'Fill'
        $summary.Text = ('发现 {0} 份多余副本。按 SHA-256 分组，执行前再次逐字节核对。仅处理勾选项，保留文件不会移动。' -f $plan.Count)
        $layout.Controls.Add($summary,0,0)
        $review = New-Object Windows.Forms.ListView
        $review.Dock = 'Fill'; $review.View = 'Details'; $review.CheckBoxes = $true; $review.FullRowSelect = $true
        [void]$review.Columns.Add('多余副本（勾选后回收）',(S 440))
        [void]$review.Columns.Add('保留文件',(S 440))
        foreach ($entry in $plan) {
            $row = New-Object Windows.Forms.ListViewItem((Get-RelativePath $entry.Duplicate))
            [void]$row.SubItems.Add((Get-RelativePath $entry.Keep)); $row.Tag = $entry
            [void]$review.Items.Add($row)
        }
        $layout.Controls.Add($review,0,1)
        $buttons = New-Object Windows.Forms.FlowLayoutPanel
        $buttons.Dock = 'Fill'; $buttons.FlowDirection = 'RightToLeft'
        $layout.Controls.Add($buttons,0,2)
        $close = New-Object Windows.Forms.Button
        $close.Text = '关闭'; $close.AutoSize = $true
        $close.Add_Click({ $dialog.Close() }.GetNewClosure()); $buttons.Controls.Add($close)
        $recycle = New-Object Windows.Forms.Button
        $recycle.Text = '将勾选副本送入回收站'; $recycle.AutoSize = $true
        $recycle.Enabled = Test-DedupeVerified
        $buttons.Controls.Add($recycle)
        $selectAll = New-Object Windows.Forms.Button
        $selectAll.Text = '全选'; $selectAll.AutoSize = $true
        $selectAll.Add_Click({ foreach ($row in $review.Items) { $row.Checked = $true } }.GetNewClosure())
        $buttons.Controls.Add($selectAll)
        $recycle.Add_Click({
            $selected = @($review.CheckedItems | ForEach-Object { $_.Tag })
            if ($selected.Count -eq 0) { return }
            if ([Windows.Forms.MessageBox]::Show(('将 {0} 份副本送入回收站？每组保留一份。' -f $selected.Count),'确认回收','YesNo','Question') -ne 'Yes') { return }
            $outcomes = @(Invoke-DuplicateCleanup -Plan $selected -Execute)
            $done = @($outcomes | Where-Object Status -eq 'recycled').Count
            $skipped = @($outcomes | Where-Object Status -eq 'skipped')
            $message = '已回收 ' + $done + ' 份；跳过 ' + $skipped.Count + ' 份。'
            if ($skipped.Count) { $message += "`r`n" + (($skipped | ForEach-Object { $_.Error } | Select-Object -Unique) -join "`r`n") }
            [void][Windows.Forms.MessageBox]::Show($message,'去重结果')
            $dialog.Close()
        }.GetNewClosure())
        Set-WarmControls $dialog
        [void]$dialog.ShowDialog($form)
        $dialog.Dispose()
        $null = Sync-LibraryIndex
        Invoke-Search
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'重复文档检查') }
    finally { $form.Cursor = 'Default'; $script:UiUpdating = $false; $refreshTimer.Start() }
}

$btnDuplicates = New-RoundButton -Text '查找重复' -Kind 'text'
$btnDuplicates.AutoSize = $true
$btnDuplicates.MinimumSize = New-Object Drawing.Size((S 92),(S 32))
$toolbar.Controls.Add($btnDuplicates)
$btnDuplicates.Add_Click({ Show-DuplicateReview })
$autoCheck = New-Object Windows.Forms.CheckBox
$autoCheck.Text = '自动去重（回收站）'
$autoCheck.AutoSize = $true
$autoCheck.Margin = New-Object Windows.Forms.Padding((S 8),(S 10),0,0)
$autoCheck.Enabled = Test-DedupeVerified
$toolbar.Controls.Add($autoCheck)
$autoCheck.Add_CheckedChanged({
    if ($autoCheck.Checked) {
        $answer = [Windows.Forms.MessageBox]::Show($form,'开启后，窗口运行期间会自动检查整个资料库。仅回收内容完全相同的非空文档，保留一份。可随时取消勾选。是否开启？','自动去重','YesNo','Question')
        if ($answer -ne 'Yes') { $autoCheck.Checked = $false; return }
    }
    $script:AutoDedupe = $autoCheck.Checked
})

$dropPanel = New-Object Windows.Forms.Panel
$dropPanel.Dock = 'Fill'
$dropPanel.Margin = New-Object Windows.Forms.Padding((S 24),(S 8),(S 24),(S 8))
$dropPanel.BackColor = [Drawing.Color]::FromArgb(255,232,157)
$rootLayout.Controls.Add($dropPanel,0,3)
$dropLabel = New-Object Windows.Forms.Label
$dropLabel.Dock = 'Fill'
$dropLabel.TextAlign = 'MiddleCenter'
$dropLabel.ForeColor = $script:ColAccent
$dropLabel.Text = '把桌面文件拖到这里 → 移入资料库并自动分类    ·    同名文件自动改名'
$dropPanel.Controls.Add($dropLabel)
$dropEnter = {
    param($sender,$eventArgs)
    if (-not $script:UiUpdating -and $eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $eventArgs.Effect = 'Move' }
    else { $eventArgs.Effect = 'None' }
}
$dropAction = {
    param($sender,$eventArgs)
    if ($script:UiUpdating) { return }
    if (Get-Command Cancel-DuplicateScan -ErrorAction SilentlyContinue) { Cancel-DuplicateScan }
    if (Get-Command Stop-FilePreview -ErrorAction SilentlyContinue) { Stop-FilePreview }
    $script:UiUpdating = $true; $refreshTimer.Stop()
    try {
        $paths = [string[]]$eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
        $result = @(Import-LibraryItems -Paths $paths)
        $success = @($result | Where-Object Success).Count
        $errors = @($result | Where-Object { -not $_.Success })
        if ($success) { Ensure-LibraryWatcher }
        $lblStatus.Text = '已移入 ' + $success + ' 个文件，后台将自动分类；跳过 ' + $errors.Count + ' 个。'
        if ($errors.Count) { [void][Windows.Forms.MessageBox]::Show((($errors | ForEach-Object { [IO.Path]::GetFileName($_.Source) + '：' + $_.Error }) -join "`r`n"),'部分文件未导入') }
        $null = Sync-LibraryIndex
        Invoke-Search
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'导入失败') }
    finally { $script:UiUpdating = $false; $refreshTimer.Start() }
}
foreach ($control in @($form,$list,$dropPanel,$dropLabel,$previewHost,$previewText)) {
    $control.AllowDrop = $true
    $control.Add_DragEnter($dropEnter)
    $control.Add_DragDrop($dropAction)
}
$list.Add_SelectedIndexChanged({ Update-FilePreview })
$script:RefreshCounter = 0
$refreshTimer = New-Object Windows.Forms.Timer
$refreshTimer.Interval = 5000
$refreshTimer.Add_Tick({
    if ($script:UiUpdating) { return }
    $script:UiUpdating = $true
    try {
        $script:RefreshCounter++
        $null = Sync-LibraryIndex
        $signature = (Get-Item -LiteralPath $script:IndexManifest).LastWriteTimeUtc.Ticks
        if ($script:LastLibrarySignature -ne $signature) {
            $selectedPath = ''
            if ($list.SelectedItems.Count) { $selectedPath = [string]$list.SelectedItems[0].Tag }
            Invoke-Search
            foreach ($row in $list.Items) { if ([string]$row.Tag -eq $selectedPath) { $row.Selected = $true; break } }
            Update-Stats
            $script:LastLibrarySignature = $signature
        }
        if ($script:AutoDedupe -and $script:RefreshCounter % 3 -eq 0) {
            $plan = @(Find-DuplicateDocuments)
            if ($plan.Count) {
                $outcomes = @(Invoke-DuplicateCleanup -Plan $plan -Execute)
                $count = @($outcomes | Where-Object Status -eq 'recycled').Count
                $lblStatus.Text = '自动去重：已将 ' + $count + ' 份完全相同的副本送入回收站。'
            }
        }
    } catch { $lblStatus.Text = '资料库忙碌，稍后自动重试。' }
    finally { $script:UiUpdating = $false }
})
if (-not $SelfTestForm -and [string]::IsNullOrEmpty($Capture)) { $refreshTimer.Start() }
$form.Add_FormClosed({
    $refreshTimer.Stop(); $refreshTimer.Dispose()
    if ($previewImage.Image) { $previewImage.Image.Dispose() }
})

. (Join-Path $PSScriptRoot 'extra-ui.ps1')

. (Join-Path $PSScriptRoot 'explorer-layout.ps1')
