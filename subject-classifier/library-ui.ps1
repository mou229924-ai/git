$script:UiUpdating = $false
$script:AutoDedupe = $false
$script:LastLibrarySignature = ''

function Ensure-LibraryWatcher {
    Start-ManagedLibraryWatcher
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
    try {
        $paths=[string[]]$eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
        Start-LibraryBatchJob @{Task='import';Paths=@($paths)}
    }catch{$lblStatus.Text='导入未开始：'+$_.Exception.Message}
}
foreach ($control in @($form,$list,$dropPanel,$dropLabel,$previewHost,$previewText)) {
    $control.AllowDrop = $true
    $control.Add_DragEnter($dropEnter)
    $control.Add_DragDrop($dropAction)
}
$list.Add_SelectedIndexChanged({ Update-FilePreview })
$form.Add_FormClosed({
    $refreshTimer.Stop(); $refreshTimer.Dispose()
    if ($previewImage.Image) { $previewImage.Image.Dispose() }
})

. (Join-Path $PSScriptRoot 'extra-ui.ps1')

. (Join-Path $PSScriptRoot 'explorer-layout.ps1')
