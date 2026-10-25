$script:SortKey='mtimeTicks'
$script:SortDescending=$true
$script:UpdatingDirectoryChoices=$false

function Update-DirectoryChoices {
    $script:UpdatingDirectoryChoices=$true
    try {
        $selected=[string]$cmbSubject.SelectedItem
        $choices=@([string]$script:Cfg.search.allSubjects,[string]$script:Cfg.search.unclassified)+@(Get-DirectoryChoices)
        $current=@($cmbSubject.Items | ForEach-Object { [string]$_ })
        if (($choices -join '|') -ne ($current -join '|')) {
            $cmbSubject.Items.Clear()
            foreach ($choice in $choices) { [void]$cmbSubject.Items.Add($choice) }
            $index=$cmbSubject.Items.IndexOf($selected)
            if ($index -lt 0) { $index=0 }
            $cmbSubject.SelectedIndex=$index
        }
    } finally { $script:UpdatingDirectoryChoices=$false }
}

function Rename-SelectedFile {
    if (Get-Command Cancel-DuplicateScan -ErrorAction SilentlyContinue) { Cancel-DuplicateScan }
    if (Get-Command Stop-FilePreview -ErrorAction SilentlyContinue) { Stop-FilePreview }
    if ($script:UiUpdating) { return }
    if ($list.SelectedItems.Count -ne 1) { [void][Windows.Forms.MessageBox]::Show('请选择一个文件后重命名。','重命名'); return }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $oldPath=[string]$list.SelectedItems[0].Tag
    $name=Show-NameInput -Prompt '请输入新文件名（保留扩展名）：' -Title '重命名' -Default ([IO.Path]::GetFileName($oldPath)) -Owner $form
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    if ([IO.Path]::GetExtension($name) -ne [IO.Path]::GetExtension($oldPath)) {
        if ([Windows.Forms.MessageBox]::Show('扩展名将改变，文件可能无法正常打开。是否继续？','重命名','YesNo','Question') -ne 'Yes') { return }
    }
    $script:UiUpdating=$true
    try {
        if ($previewImage.Image) { $previewImage.Image.Dispose(); $previewImage.Image=$null }
        $newPath=Rename-LibraryFile -Path $oldPath -NewName $name
        Invoke-Search
        foreach ($row in $list.Items) { if ([string]$row.Tag -eq $newPath) { $row.Selected=$true; break } }
        $lblStatus.Text='已重命名为 '+$name
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'重命名失败') }
    finally { $script:UiUpdating=$false }
}

function Show-DirectoryManager {
    if ($script:UiUpdating) { return }
    $script:UiUpdating=$true
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='奶龙select · 管理目录与分类规则'
    $dialog.Size=New-Object Drawing.Size((S 680),(S 410))
    $dialog.StartPosition='CenterParent'; $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false; $dialog.Font=$form.Font; $dialog.BackColor=$script:ColBg
    $layout=New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock='Fill'; $layout.ColumnCount=2; $layout.RowCount=5
    $layout.Padding=New-Object Windows.Forms.Padding((S 20))
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',(S 150))))
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
    for ($i=0;$i -lt 4;$i++) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',(S 58)))) }
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
    $dialog.Controls.Add($layout)
    $fields=@('目录名','文件名关键词','正文关键词','说明')
    $nameBox=New-Object Windows.Forms.ComboBox
    $nameBox.DropDownStyle='DropDown'; $nameBox.Dock='Fill'
    foreach ($name in @(Get-DirectoryChoices | Where-Object { $_ -notmatch '\\' })) { [void]$nameBox.Items.Add($name) }
    $fileWords=New-Object Windows.Forms.TextBox; $fileWords.Dock='Fill'
    $bodyWords=New-Object Windows.Forms.TextBox; $bodyWords.Dock='Fill'
    $note=New-Object Windows.Forms.Label
    $note.Text='可输入新目录名。关键词用逗号分隔；目录名会自动作为文件名关键词。多个目录命中时请用户确认。'
    $note.Dock='Fill'; $note.ForeColor=$script:ColText2
    $controls=@($nameBox,$fileWords,$bodyWords,$note)
    for ($i=0;$i -lt 4;$i++) {
        $label=New-Object Windows.Forms.Label; $label.Text=$fields[$i]; $label.Dock='Fill'
        $layout.Controls.Add($label,0,$i); $layout.Controls.Add($controls[$i],1,$i)
    }
    $nameBox.Add_SelectedIndexChanged({
        $rule=@($script:Cfg.subjects | Where-Object { [string]$_.name -eq [string]$nameBox.Text }) | Select-Object -First 1
        $fileWords.Text=(@($rule.filenameKeywords) -join '，'); $bodyWords.Text=(@($rule.contentKeywords) -join '，')
    }.GetNewClosure())
    $save=New-Object Windows.Forms.Button; $save.Text='保存目录与规则'; $save.AutoSize=$true
    $save.BackColor=$script:ColSurface
    $cancel=New-Object Windows.Forms.Button; $cancel.Text='取消'; $cancel.AutoSize=$true; $cancel.DialogResult='Cancel'
    $buttons=New-Object Windows.Forms.FlowLayoutPanel; $buttons.Dock='Fill'
    $buttons.Controls.AddRange(@($save,$cancel)); $layout.Controls.Add($buttons,1,4)
    $dialog.AcceptButton=$save; $dialog.CancelButton=$cancel
    $save.Add_Click({
        try {
            $null=Save-LibraryDirectory -Name $nameBox.Text -FilenameKeywords @($fileWords.Text -split '[,，;；\r\n]+' | ForEach-Object { $_.Trim() }) -ContentKeywords @($bodyWords.Text -split '[,，;；\r\n]+' | ForEach-Object { $_.Trim() })
            $dialog.DialogResult='OK'
            $dialog.Close()
        } catch { [void][Windows.Forms.MessageBox]::Show($dialog,$_.Exception.Message,'保存失败') }
    }.GetNewClosure())
    Set-WarmControls $dialog
    try {
        if ((Show-LibraryDialog -Dialog $dialog -Owner $form -InitialFocus $nameBox) -eq 'OK') {
            Update-DirectoryChoices
            if (Get-Command Update-NavigationTree -ErrorAction SilentlyContinue) { Update-NavigationTree }
        }
    }
    finally { $dialog.Dispose(); $script:UiUpdating=$false }
}

function Show-BatchPrint {
    if($script:UiUpdating){return}
    $paths=@($list.SelectedItems|ForEach-Object{[string]$_.Tag})
    if(-not $paths.Count){$lblStatus.Text='请先多选要打印的文件。';return}
    try{
        $printer=New-Object Drawing.Printing.PrinterSettings
        if(-not $printer.IsValid){throw '没有可用的默认打印机，请先在 Windows 中设置。'}
        Start-LibraryBatchJob @{Task='print-plan';Paths=$paths;PrinterName=$printer.PrinterName}
    }catch{$lblStatus.Text='打印未开始：'+$_.Exception.Message}
}

$dateFilter=New-Object Windows.Forms.ComboBox
$dateFilter.DropDownStyle='DropDownList'; $dateFilter.Width=(S 145)
$dateFilter.Margin=New-Object Windows.Forms.Padding((S 8),(S 7),(S 8),0)
foreach ($value in @('全部修改时间','今天修改','最近 7 天修改','最近 30 天修改')) { [void]$dateFilter.Items.Add($value) }
$dateFilter.SelectedIndex=0; $toolbar.Controls.Add($dateFilter)
$formatFilter=New-Object Windows.Forms.ComboBox
$formatFilter.DropDownStyle='DropDownList'; $formatFilter.Width=(S 120)
$formatFilter.Margin=New-Object Windows.Forms.Padding((S 4),(S 7),(S 8),0)
foreach ($value in @('全部格式','PDF','Word / 文档','文本','图片','压缩包')) { [void]$formatFilter.Items.Add($value) }
$formatFilter.SelectedIndex=0; $toolbar.Controls.Add($formatFilter)
foreach ($definition in @(@('管理目录','Show-DirectoryManager'),@('重命名 F2','Rename-SelectedFile'),@('批量打印','Show-BatchPrint'))) {
    $button=New-RoundButton -Text $definition[0] -Kind 'text'
    $button.AutoSize=$true; $button.MinimumSize=New-Object Drawing.Size((S 92),(S 32))
    $actionName=$definition[1]
    $button.Add_Click({ & $actionName }.GetNewClosure())
    $toolbar.Controls.Add($button)
}
$cmbSubject.Add_SelectedIndexChanged({ if (-not $script:UpdatingDirectoryChoices -and -not $script:UiUpdating) { Invoke-Search } })
$dateFilter.Add_SelectedIndexChanged({ if (-not $script:UiUpdating) { Invoke-Search } })
$formatFilter.Add_SelectedIndexChanged({ if (-not $script:UiUpdating) { Invoke-Search } })
$list.Add_ColumnClick({
    param($sender,$eventArgs)
    $keys=@('name','size','mtimeTicks','rel','score')
    $next=$keys[$eventArgs.Column]
    if ($script:SortKey -eq $next) { $script:SortDescending=-not $script:SortDescending }
    else { $script:SortKey=$next; $script:SortDescending=($next -in @('mtimeTicks','size','score')) }
    $names=@('文件名','大小','修改时间','所在目录','匹配内容')
    for ($i=0;$i -lt $names.Count;$i++) {
        $list.Columns[$i].Text=$names[$i]
        if ($keys[$i] -eq $script:SortKey) { if ($script:SortDescending) { $list.Columns[$i].Text+=' ↓' } else { $list.Columns[$i].Text+=' ↑' } }
    }
    Invoke-Search
})
$list.Columns[2].Text='修改时间 ↓'
$list.Add_KeyDown({
    param($sender,$eventArgs)
    if ($eventArgs.KeyCode -eq 'F2') { Rename-SelectedFile; $eventArgs.SuppressKeyPress=$true }
    elseif ($eventArgs.Control -and $eventArgs.KeyCode -eq 'A') { foreach ($row in $list.Items) { $row.Selected=$true }; $eventArgs.SuppressKeyPress=$true }
})
$renameMenu=New-Object Windows.Forms.ToolStripMenuItem
$renameMenu.Text='重命名 F2'; $renameMenu.Add_Click({ Rename-SelectedFile }); [void]$ctx.Items.Add($renameMenu)
$printMenu=New-Object Windows.Forms.ToolStripMenuItem
$printMenu.Text='批量打印所选文件'; $printMenu.Add_Click({ Show-BatchPrint }); [void]$ctx.Items.Add($printMenu)
$desktopMenu=New-Object Windows.Forms.ToolStripMenuItem
$desktopMenu.Text='移到桌面'
$desktopMenu.Add_Click({
    try {
        $paths=@($list.SelectedItems | ForEach-Object { [string]$_.Tag })
        if (-not $paths.Count) { return }
        if ([Windows.Forms.MessageBox]::Show(('将 '+$paths.Count+' 个文件移到桌面？同名文件自动改名。'),'移到桌面','YesNo','Question') -ne 'Yes') { return }
        if ($previewImage.Image) { $previewImage.Image.Dispose(); $previewImage.Image=$null }
        $result=@(Export-LibraryFiles -Paths $paths -Destination ([Environment]::GetFolderPath('DesktopDirectory')))
        Invoke-Search
        $errors=@($result | Where-Object { -not $_.Success })
        $lblStatus.Text='已移到桌面 '+@($result | Where-Object Success).Count+' 个文件。'
        if ($errors.Count) { [void][Windows.Forms.MessageBox]::Show((@($errors | ForEach-Object Error) -join "`r`n"),'部分移动失败') }
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'移到桌面') }
})
[void]$ctx.Items.Add($desktopMenu)
$list.Add_ItemDrag({
    if (Get-Command Cancel-DuplicateScan -ErrorAction SilentlyContinue) { Cancel-DuplicateScan }
    if (Get-Command Stop-FilePreview -ErrorAction SilentlyContinue) { Stop-FilePreview }
    if ($script:UiUpdating -or $list.SelectedItems.Count -eq 0) { return }
    $script:UiUpdating=$true; $refreshTimer.Stop()
    $effectStream=$null
    try {
        $paths=[string[]]@($list.SelectedItems | ForEach-Object { Assert-LibraryFile ([string]$_.Tag) })
        foreach ($path in $paths) { if (-not (Test-FileReady $path)) { throw '所选文件正在使用，请关闭后再拖出。' } }
        if ($previewImage.Image) { $previewImage.Image.Dispose(); $previewImage.Image=$null }
        $data=New-Object Windows.Forms.DataObject
        $data.SetData([Windows.Forms.DataFormats]::FileDrop,$paths)
        $effectStream=New-Object IO.MemoryStream(,[BitConverter]::GetBytes([int]2))
        $data.SetData('Preferred DropEffect',$effectStream)
        # Explorer performs the move. Never delete the source again after DoDragDrop returns.
        $null=$list.DoDragDrop($data,[Windows.Forms.DragDropEffects]::Move)
        Request-IndexRefresh -Paths $paths; Invoke-Search
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'拖出文件') }
    finally { if ($effectStream) { $effectStream.Dispose() }; $script:UiUpdating=$false; $refreshTimer.Start() }
})
$dropLabel.Text='拖入文件 → 移入并分类    ·    从列表拖出 → 移到桌面    ·    Ctrl / Shift 多选，F2 重命名'
$txtQuery.Add_KeyDown({ param($sender,$eventArgs) if ($eventArgs.KeyCode -eq 'Enter') { Invoke-Search; $eventArgs.SuppressKeyPress=$true } })
Update-DirectoryChoices

Set-WarmControls $form

function Invoke-OcrRebuild {
    if($script:IndexJob){$lblStatus.Text='索引正在更新，请完成后再识别扫描件。';return}
    $capability=Get-OcrAvailability
    if(-not $capability.Available){[void][Windows.Forms.MessageBox]::Show($form,$capability.Reason,'本机文字识别');return}
    if([Windows.Forms.MessageBox]::Show($form,'启用本机文字识别并重建索引？默认识别每份 PDF 前两页及图片，资料不会上传。文件较多时需要一些时间。','识别扫描件文字','YesNo','Question') -ne 'Yes'){return}
    try{Set-LibraryOcrEnabled $true;Invoke-Rebuild;$lblStatus.Text='正在后台识别并建立文字索引…'}catch{[void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'文字识别未启动')}
}
