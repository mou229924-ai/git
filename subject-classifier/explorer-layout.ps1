# Explorer-style shell. Slow operations run in independent processes.
$script:SearchJob=$null; $script:DedupeJob=$null; $script:IndexJob=$null
$script:PreviewJob=$null; $script:PreviewPath=''; $script:PreviewPage=0
$script:SearchAgain=$false; $script:ListUpdating=$false; $script:DedupeDialogOpen=$false
$script:LastAutoScan=Get-Date
$script:PageOffset=0; $script:PageSize=200; $script:LastIndexPoll=[datetime]::MinValue; $script:LastReconcile=[datetime]::MinValue; $script:IndexSignature=0
$jobsDirectory=Join-Path $script:AppDir '_jobs'
New-Item -ItemType Directory -Path $jobsDirectory -Force | Out-Null
if (-not ('Nailong.Native' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'NativePreview.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing }

function Start-LibraryJob {
    param([hashtable]$Request)
    $id=[guid]::NewGuid().ToString('N')
    $requestPath=Join-Path $jobsDirectory ($id+'.request.json')
    $resultPath=Join-Path $jobsDirectory ($id+'.result.json')
    Write-AtomicUtf8 $requestPath ($Request | ConvertTo-Json -Depth 12)
    $arguments='-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $script:AppDir 'background.ps1')+'" -Request "'+$requestPath+'" -Result "'+$resultPath+'"'
    $process=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments -PassThru
    return @{ Process=$process; Request=$requestPath; Result=$resultPath; Task=$Request.Task; Started=(Get-Date); Auto=$false }
}

function Read-LibraryJob {
    param($Job)
    if (-not $Job -or -not [IO.File]::Exists($Job.Result)) { return $null }
    try { return (Read-AtomicUtf8 $Job.Result) | ConvertFrom-Json } catch { return $null }
}

function Close-LibraryJob {
    param($Job,[switch]$Stop)
    if (-not $Job) { return }
    if ($Stop -and -not $Job.Process.HasExited) { $Job.Process.Kill(); $null=$Job.Process.WaitForExit(2000) }
    $Job.Process.Dispose()
    foreach ($file in @($Job.Request,$Job.Result)) { if ($file -and [IO.File]::Exists($file)) { try { [IO.File]::Delete($file) } catch { } } }
}

function Cancel-DuplicateScan {
    if ($script:DedupeJob -and $script:DedupeJob.Task -eq 'scan') {
        Close-LibraryJob $script:DedupeJob -Stop
        $script:DedupeJob=$null; $dedupeProgress.Visible=$false; $cancelScan.Visible=$false
        $lblStatus.Text='重复检查已取消，文件保持原样。'
    }
}

function Stop-FilePreview {
    if ($script:PreviewJob) {
        if (-not $script:PreviewJob.Process.HasExited) { $script:PreviewJob.Process.Kill(); $null=$script:PreviewJob.Process.WaitForExit(1500) }
        $script:PreviewJob.Process.Dispose()
        if ([IO.File]::Exists($script:PreviewJob.Status)) { try { [IO.File]::Delete($script:PreviewJob.Status) } catch { } }
        $script:PreviewJob=$null
    }
}

function Show-FilePreview {
    param([string]$Path,[int]$Page=0,[switch]$Fallback)
    Stop-FilePreview
    $script:PreviewPath=$Path; $script:PreviewPage=$Page
    $previewTitle.Text=[IO.Path]::GetFileName($Path)
    $previewText.Visible=$true; $previewText.Text='正在载入预览…'
    $previewImage.Visible=$false
    $statusPath=Join-Path $jobsDirectory ([guid]::NewGuid().ToString('N')+'.preview.json')
    $args='-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $script:AppDir 'preview-host.ps1')+'" -File "'+$Path+'" -ParentHandle '+$previewHost.Handle.ToInt64()+' -Width '+$previewHost.Width+' -Height '+$previewHost.Height+' -Status "'+$statusPath+'" -Page '+$Page
    if ($Fallback) { $args+=' -ForceFallback' }
    $process=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $args -PassThru
    $script:PreviewJob=@{ Process=$process; Status=$statusPath; Started=(Get-Date); Ready=$false; Fallback=[bool]$Fallback; Handle=0 }
    $previewHint.Text='原始排版预览 · 可滚动阅读'
}

function Update-FilePreview {
    if ($script:ListUpdating) { return }
    $previewDelay.Stop()
    if ($list.SelectedItems.Count -eq 0) { return }
    $previewDelay.Start()
}

function Invoke-Search {
    param([switch]$KeepPage)
    if(-not $KeepPage){$script:PageOffset=0}
    if ($script:SearchJob) { $script:SearchAgain=$true; return }
    $directory=''
    if ($cmbSubject.SelectedIndex -gt 0) { $directory=[string]$cmbSubject.SelectedItem }
    $since=[datetime]::MinValue
    switch ($dateFilter.SelectedIndex) { 1 {$since=[datetime]::Today} 2 {$since=[datetime]::Today.AddDays(-6)} 3 {$since=[datetime]::Today.AddDays(-29)} }
    $extensions=@()
    switch ($formatFilter.SelectedIndex) {
        1 {$extensions=@('.pdf')} 2 {$extensions=@('.doc','.docx','.docm','.rtf','.odt')}
        3 {$extensions=@('.txt','.md','.csv','.tsv')} 4 {$extensions=@('.png','.jpg','.jpeg','.gif','.bmp')}
        5 {$extensions=@('.zip','.rar','.7z')}
    }
    $script:SearchJob=Start-LibraryJob @{ Task='search'; Query=$txtQuery.Text.Trim(); Directory=$directory; Content=$chkContent.Checked; Since=$since.ToString('o'); Extensions=$extensions; SortKey=$script:SortKey; Descending=$script:SortDescending; Offset=$script:PageOffset; Limit=$script:PageSize }
    $lblStatus.Text='正在更新文件列表…'
    $addressLabel.Text='资料库  ›  '+$(if($directory){$directory.Replace('\','  ›  ')}else{'全部文件'})
}

function Show-SearchResults {
    param($Data)
    $selected=@($list.SelectedItems | ForEach-Object { [string]$_.Tag })
    $script:ListUpdating=$true; $list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($result in @($Data.Results)) {
            if (-not $result) { continue }
            $item=New-Object Windows.Forms.ListViewItem([string]$result.name)
            [void]$item.SubItems.Add((Format-Size ([long]$result.size)))
            [void]$item.SubItems.Add([string]$result.mtime)
            $directory=[IO.Path]::GetDirectoryName([string]$result.rel)
            if (-not $directory) { $directory='根目录' }
            [void]$item.SubItems.Add($directory)
            [void]$item.SubItems.Add([string]$result.hit)
            $item.Tag=[string]$result.full
            $extension=[IO.Path]::GetExtension([string]$result.name).ToLowerInvariant()
            if (-not $fileIcons.Images.ContainsKey($extension)) {
                try { $icon=[Drawing.Icon]::ExtractAssociatedIcon([string]$result.full); $fileIcons.Images.Add($extension,$icon); $icon.Dispose() } catch { }
            }
            $item.ImageKey=$extension
            [void]$list.Items.Add($item)
            if ($selected -contains [string]$result.full) { $item.Selected=$true }
        }
    } finally { $list.EndUpdate(); $script:ListUpdating=$false }
    $total=[int]$Data.TotalMatches
    $offset=[int]$Data.Offset
    if($total -gt 0 -and $offset -ge $total){$script:PageOffset=[int]([Math]::Floor(($total-1)/$script:PageSize)*$script:PageSize);Invoke-Search -KeepPage;return}
    $first=0; if($total -gt 0){$first=$offset+1}
    $last=$offset+$list.Items.Count
    $lblStatus.Text=('显示 {0}–{1} / 共 {2} 个结果   ·   资料库 {3} 个文件' -f $first,$last,$total,$Data.TotalIndexed)
    $pageInfo.Text=('第 {0} / {1} 页' -f ([int][Math]::Floor($offset/$script:PageSize)+1),[Math]::Max(1,[Math]::Ceiling($total/[double]$script:PageSize)))
    $pagePreviousButton.Enabled=$offset -gt 0; $pageNextButton.Enabled=[bool]$Data.HasMore
    if ($list.SelectedItems.Count) { Update-FilePreview }
    elseif ($script:PreviewPath -and -not [IO.File]::Exists($script:PreviewPath)) { Stop-FilePreview; $previewTitle.Text='预览'; $previewText.Text='选择一个文件以预览。'; $previewText.Visible=$true }
    $available=$list.ClientSize.Width-(S 25)
    $hasHits=@($Data.Results | Where-Object { $_.hit }).Count -gt 0
    $list.Columns[4].Width=0
    if($hasHits){$list.Columns[4].Width=(S 160)}
    $list.Columns[1].Width=(S 70);$list.Columns[2].Width=(S 142);$list.Columns[3].Width=(S 130)
    $list.Columns[0].Width=[Math]::Max((S 190),$available-$list.Columns[1].Width-$list.Columns[2].Width-$list.Columns[3].Width-$list.Columns[4].Width)
    Update-DirectoryChoices
}

function Invoke-Rebuild {
    param([switch]$Auto)
    if ($script:IndexJob) { return }
    Cancel-DuplicateScan
    $script:IndexJob=Start-LibraryJob @{ Task='rebuild' }
    $lblStatus.Text='正在后台重建索引，仍可浏览文件。'
}

function Show-DuplicateReview {
    if ($script:DedupeJob -or $script:DedupeDialogOpen) { return }
    $script:DedupeJob=Start-LibraryJob @{ Task='scan' }
    $dedupeProgress.Visible=$true; $cancelScan.Visible=$true
    $lblStatus.Text='正在后台检查重复文档…'
}

function Show-DuplicatePlan {
    param([object[]]$Plan)
    if (-not $Plan.Count) { [void][Windows.Forms.MessageBox]::Show($form,'未发现内容完全相同的非空文档。','重复检查'); return }
    $script:DedupeDialogOpen=$true
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='重复文档 · 检查后回收'; $dialog.StartPosition='CenterParent'
    $dialog.Size=New-Object Drawing.Size((S 1000),(S 520)); $dialog.Font=$form.Font; $dialog.BackColor=$script:ColBg
    $layout=New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock='Fill'; $layout.RowCount=3; $layout.ColumnCount=1; $layout.Padding=New-Object Windows.Forms.Padding((S 18))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',(S 52))))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',(S 48))))
    $dialog.Controls.Add($layout)
    $label=New-Object Windows.Forms.Label; $label.Dock='Fill'
    $label.Text='找到 '+$Plan.Count+' 份多余副本。勾选后送入回收站，每组始终保留一份。'
    $layout.Controls.Add($label,0,0)
    $review=New-Object Windows.Forms.ListView; $review.Dock='Fill'; $review.View='Details'; $review.CheckBoxes=$true; $review.FullRowSelect=$true
    [void]$review.Columns.Add('回收副本',(S 440)); [void]$review.Columns.Add('保留文件',(S 440))
    foreach($entry in $Plan){$row=New-Object Windows.Forms.ListViewItem((Get-RelativePath $entry.Duplicate));[void]$row.SubItems.Add((Get-RelativePath $entry.Keep));$row.Tag=$entry;[void]$review.Items.Add($row)}
    $layout.Controls.Add($review,0,1)
    $buttons=New-Object Windows.Forms.FlowLayoutPanel; $buttons.Dock='Fill'; $buttons.FlowDirection='RightToLeft';$layout.Controls.Add($buttons,0,2)
    $recycle=New-Object Windows.Forms.Button; $recycle.Text='回收勾选副本';$recycle.AutoSize=$true;$buttons.Controls.Add($recycle)
    $recycle.Add_Click({
        $selection=@($review.CheckedItems | ForEach-Object {$_.Tag})
        if(-not $selection.Count){return}
        if([Windows.Forms.MessageBox]::Show($dialog,('将 '+$selection.Count+' 份副本送入回收站？'),'确认回收','YesNo','Question') -ne 'Yes'){return}
        $script:DedupeJob=Start-LibraryJob @{Task='cleanup';Plan=$selection}
        $lblStatus.Text='正在后台将副本送入回收站…';$dedupeProgress.Visible=$true;$cancelScan.Visible=$false
        $dialog.Close()
    }.GetNewClosure())
    $all=New-Object Windows.Forms.Button;$all.Text='全选';$all.AutoSize=$true;$buttons.Controls.Add($all)
    $all.Add_Click({foreach($row in $review.Items){$row.Checked=$true}}.GetNewClosure())
    Set-WarmControls $dialog
    try{[void]$dialog.ShowDialog($form)}finally{$dialog.Dispose();$script:DedupeDialogOpen=$false}
}

# A restrained warm theme: cream chrome, white document surfaces, amber selection.
$script:ColBg=[Drawing.Color]::FromArgb(255,251,240)
$script:ColSurface=[Drawing.Color]::FromArgb(250,241,212)
$script:ColText=[Drawing.Color]::FromArgb(54,49,38)
$script:ColText2=[Drawing.Color]::FromArgb(126,114,88)
$script:ColAccent=[Drawing.Color]::FromArgb(156,104,20)
$form.BackColor=$script:ColBg
$form.ClientSize=New-Object Drawing.Size((S 1380),(S 820))
$form.MinimumSize=New-Object Drawing.Size((S 1100),(S 650))
$rootLayout.Controls.Clear();$rootLayout.RowStyles.Clear();$rootLayout.RowCount=6;$rootLayout.Padding=New-Object Windows.Forms.Padding(0)
foreach($height in @(44,48,44,42)){[void]$rootLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',(S $height))))}
[void]$rootLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$rootLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',(S 28))))

$brand=New-Object Windows.Forms.Panel;$brand.Dock='Fill';$brand.BackColor=$script:ColBg;$rootLayout.Controls.Add($brand,0,0)
$picLogo.Size=New-Object Drawing.Size((S 26),(S 26));$picLogo.Location=New-Object Drawing.Point((S 18),(S 9));$picLogo.BackColor=$script:ColBg;$brand.Controls.Add($picLogo)
$lblTitle.Font=New-Object Drawing.Font('Microsoft YaHei UI',11,[Drawing.FontStyle]::Bold);$lblTitle.Location=New-Object Drawing.Point((S 54),(S 10));$lblTitle.ForeColor=$script:ColText;$brand.Controls.Add($lblTitle)
$brandHint=New-Object Windows.Forms.Label;$brandHint.Text='文件资料库';$brandHint.AutoSize=$true;$brandHint.ForeColor=$script:ColText2;$brandHint.Location=New-Object Drawing.Point((S 176),(S 13));$brand.Controls.Add($brandHint)

$addressRow=New-Object Windows.Forms.TableLayoutPanel;$addressRow.Dock='Fill';$addressRow.Padding=New-Object Windows.Forms.Padding((S 16),(S 5),(S 16),(S 5));$addressRow.ColumnCount=2;$addressRow.RowCount=1;[void]$addressRow.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$addressRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',65)));[void]$addressRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',35)))
$rootLayout.Controls.Add($addressRow,0,1)
$addressLabel=New-Object Windows.Forms.Label;$addressLabel.Dock='Fill';$addressLabel.Text='资料库  ›  全部文件';$addressLabel.BackColor=[Drawing.Color]::White;$addressLabel.TextAlign='MiddleLeft';$addressLabel.Padding=New-Object Windows.Forms.Padding((S 12),0,0,0);$addressLabel.AutoEllipsis=$true;$addressRow.Controls.Add($addressLabel,0,0)
$searchBoxRow=New-Object Windows.Forms.TableLayoutPanel;$searchBoxRow.Dock='Fill';$searchBoxRow.ColumnCount=2;$searchBoxRow.RowCount=1;[void]$searchBoxRow.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$searchBoxRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)));[void]$searchBoxRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',(S 66))))
$addressRow.Controls.Add($searchBoxRow,1,0)
$txtQuery.Dock='Fill';$txtQuery.BorderStyle='FixedSingle';$txtQuery.BackColor=[Drawing.Color]::White;$txtQuery.Font=New-Object Drawing.Font('Microsoft YaHei UI',10);$txtQuery.Margin=New-Object Windows.Forms.Padding((S 8),(S 4),(S 4),0);$searchBoxRow.Controls.Add($txtQuery,0,0)
$btnSearch.Dock='Fill';$btnSearch.Text='搜索';$btnSearch.Margin=New-Object Windows.Forms.Padding(0,0,0,0);$btnSearch.BackColor=$script:ColSurface;$btnSearch.ForeColor=$script:ColAccent;$btnSearch.Font=$form.Font;$searchBoxRow.Controls.Add($btnSearch,1,0)

$commands=New-Object Windows.Forms.FlowLayoutPanel;$commands.Dock='Fill';$commands.Padding=New-Object Windows.Forms.Padding((S 14),(S 4),0,0);$commands.WrapContents=$false;$rootLayout.Controls.Add($commands,0,2)
foreach($definition in @(@('新建目录','Show-DirectoryManager'),@('重命名','Rename-SelectedFile'),@('批量打印','Show-BatchPrint'),@('检查重复','Show-DuplicateReview'),@('刷新索引','Invoke-Rebuild'))){
    $button=New-RoundButton -Text $definition[0] -Kind 'text';$button.AutoSize=$false;$button.Size=New-Object Drawing.Size((S 98),(S 32));$button.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.5);$button.BackColor=$script:ColBg;$button.ForeColor=$script:ColText;$action=$definition[1];$button.Add_Click({& $action}.GetNewClosure());$commands.Controls.Add($button)
}
$btnOpenRoot.Text='在资源管理器中打开';$btnOpenRoot.AutoSize=$false;$btnOpenRoot.Size=New-Object Drawing.Size((S 166),(S 32));$btnOpenRoot.BackColor=$script:ColBg;$commands.Controls.Add($btnOpenRoot)
$previewToggle=New-Object Windows.Forms.CheckBox;$previewToggle.Text='预览窗格';$previewToggle.Checked=$true;$previewToggle.AutoSize=$true;$previewToggle.Margin=New-Object Windows.Forms.Padding((S 20),(S 7),0,0);$commands.Controls.Add($previewToggle)
$previewToggle.Add_CheckedChanged({$split.Panel2Collapsed=-not $previewToggle.Checked;if(-not $previewToggle.Checked){Stop-FilePreview}else{Update-FilePreview}})

$filters=New-Object Windows.Forms.FlowLayoutPanel;$filters.Dock='Fill';$filters.Padding=New-Object Windows.Forms.Padding((S 18),(S 4),0,0);$filters.WrapContents=$false;$rootLayout.Controls.Add($filters,0,3)
foreach($control in @($dateFilter,$formatFilter,$chkContent,$autoCheck)){$control.Margin=New-Object Windows.Forms.Padding(0,(S 3),(S 16),0);$control.BackColor=$script:ColBg;$control.ForeColor=$script:ColText2;$filters.Controls.Add($control)}
$gateLabel=New-Object Windows.Forms.Label;$gateLabel.AutoSize=$true;$gateLabel.ForeColor=$script:ColText2;$gateLabel.Margin=New-Object Windows.Forms.Padding((S 4),(S 6),0,0);$gateLabel.Text='安全校验中';if(Test-DedupeVerified){$gateLabel.Text='安全校验通过 · 默认关闭'}else{$gateLabel.Text='去重校验待更新'};$filters.Controls.Add($gateLabel)

$navigation=New-Object Windows.Forms.SplitContainer;$navigation.Dock='Fill';$navigation.Size=New-Object Drawing.Size((S 1350),(S 580));$navigation.Panel1MinSize=(S 150);$navigation.Panel2MinSize=(S 800);$navigation.SplitterDistance=(S 190);$navigation.FixedPanel='Panel1';$navigation.SplitterWidth=(S 4)
$rootLayout.Controls.Add($navigation,0,4)
$tree=New-Object Windows.Forms.TreeView;$tree.Dock='Fill';$tree.BorderStyle='None';$tree.BackColor=$script:ColBg;$tree.ForeColor=$script:ColText;$tree.Font=New-Object Drawing.Font('Microsoft YaHei UI',10);$tree.ItemHeight=(S 32);$tree.HideSelection=$false;$tree.FullRowSelect=$true;$tree.ShowLines=$false;$tree.ShowPlusMinus=$true;$tree.Indent=(S 16);$navigation.Panel1.Controls.Add($tree)
$listPanel.Padding=New-Object Windows.Forms.Padding(0);$listPanel.BackColor=[Drawing.Color]::White;$navigation.Panel2.Controls.Add($listPanel)
$split.Panel1MinSize=(S 350);$split.Panel2MinSize=(S 310);$split.FixedPanel='Panel2';$split.SplitterWidth=(S 5)
$split.SplitterDistance=[Math]::Max((S 350),$split.Width-(S 460))
$list.OwnerDraw=$false;$list.BackColor=[Drawing.Color]::White;$list.ForeColor=$script:ColText;$list.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.5);$list.BorderStyle='None';$list.ShowItemToolTips=$true
$fileIcons=New-Object Windows.Forms.ImageList;$fileIcons.ImageSize=New-Object Drawing.Size((S 20),(S 20));$fileIcons.ColorDepth='Depth32Bit';$list.SmallImageList=$fileIcons
$list.Columns[0].Width=(S 270);$list.Columns[1].Width=(S 78);$list.Columns[2].Width=(S 146);$list.Columns[3].Width=(S 160);$list.Columns[4].Width=(S 180)

$previewLayout.BackColor=[Drawing.Color]::White;$previewLayout.Padding=New-Object Windows.Forms.Padding((S 12));$split.Panel2.BackColor=[Drawing.Color]::White
$previewLayout.RowStyles[0].Height=(S 45);$previewLayout.RowStyles[2].Height=(S 42)
$previewTitle.Font=New-Object Drawing.Font('Microsoft YaHei UI',10,[Drawing.FontStyle]::Bold);$previewTitle.ForeColor=$script:ColText;$previewTitle.Text='预览'
$previewText.BackColor=[Drawing.Color]::White;$previewText.ForeColor=$script:ColText2;$previewText.Text="选择一个文件以预览。`r`n`r`nPDF、Word 等优先使用 Windows 原生预览器。"
$previewHint.Visible=$false
$previewCommands=New-Object Windows.Forms.FlowLayoutPanel;$previewCommands.Dock='Fill';$previewCommands.WrapContents=$false;$previewLayout.Controls.Add($previewCommands,0,2)
$previous=New-Object Windows.Forms.Button;$previous.Text='‹';$previous.Width=(S 35);$previous.Height=(S 30);$previous.Enabled=$false;$previewCommands.Controls.Add($previous)
$pageLabel=New-Object Windows.Forms.Label;$pageLabel.Text='原生预览';$pageLabel.AutoSize=$true;$pageLabel.Margin=New-Object Windows.Forms.Padding((S 6),(S 8),(S 6),0);$previewCommands.Controls.Add($pageLabel)
$next=New-Object Windows.Forms.Button;$next.Text='›';$next.Width=(S 35);$next.Height=(S 30);$next.Enabled=$false;$previewCommands.Controls.Add($next)
$openPreview=New-Object Windows.Forms.Button;$openPreview.Text='打开文件';$openPreview.AutoSize=$true;$openPreview.Height=(S 30);$previewCommands.Controls.Add($openPreview)
$openPreview.Add_Click({if($script:PreviewPath -and [IO.File]::Exists($script:PreviewPath)){Start-Process -FilePath $script:PreviewPath}})
$previous.Add_Click({if($script:PreviewPage -gt 0){Show-FilePreview $script:PreviewPath ($script:PreviewPage-1) -Fallback}})
$next.Add_Click({if($script:PreviewJob -and $script:PreviewPage -lt ($script:PreviewJob.Pages-1)){Show-FilePreview $script:PreviewPath ($script:PreviewPage+1) -Fallback}})
$previewHost.Add_Resize({if($script:PreviewJob -and $script:PreviewJob.Handle){$null=[Nailong.Native]::MoveWindow([IntPtr]$script:PreviewJob.Handle,0,0,$previewHost.Width,$previewHost.Height,$true)}})
$previewDelay=New-Object Windows.Forms.Timer;$previewDelay.Interval=220
$previewDelay.Add_Tick({$previewDelay.Stop();if($list.SelectedItems.Count -and -not $split.Panel2Collapsed){$file=[string]$list.SelectedItems[0].Tag;if($file -ne $script:PreviewPath -or -not $script:PreviewJob){Show-FilePreview $file}}})

$statusRow=New-Object Windows.Forms.TableLayoutPanel;$statusRow.Dock='Fill';$statusRow.ColumnCount=3;$statusRow.RowCount=1;[void]$statusRow.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$statusRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)));[void]$statusRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',(S 150))));[void]$statusRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',(S 90))))
$rootLayout.Controls.Add($statusRow,0,5)
$lblStatus.BackColor=$script:ColBg;$lblStatus.ForeColor=$script:ColText2;$lblStatus.Padding=New-Object Windows.Forms.Padding((S 16),0,0,0);$statusRow.Controls.Add($lblStatus,0,0)
$dedupeProgress=New-Object Windows.Forms.ProgressBar;$dedupeProgress.Dock='Fill';$dedupeProgress.Style='Marquee';$dedupeProgress.Visible=$false;$statusRow.Controls.Add($dedupeProgress,1,0)
$cancelScan=New-Object Windows.Forms.Button;$cancelScan.Text='取消扫描';$cancelScan.Dock='Fill';$cancelScan.Visible=$false;$cancelScan.Add_Click({Cancel-DuplicateScan});$statusRow.Controls.Add($cancelScan,2,0)

function Update-NavigationTree {
    $signature=([string]$cmbSubject.Items.Count)+':'+(@($cmbSubject.Items)-join '|')
    if($script:TreeSignature -eq $signature){return};$script:TreeSignature=$signature
    $tree.BeginUpdate()
    try{
        $tree.Nodes.Clear();$all=$tree.Nodes.Add('全部文件');$all.Tag='';$root=$tree.Nodes.Add('根目录');$root.Tag=[string]$script:Cfg.search.unclassified
        $nodes=@{}
        foreach($relative in @(Get-DirectoryChoices)){
            $parts=$relative -split '\\';$parent=$null;$key=''
            foreach($part in $parts){if($key){$key+='\'};$key+=$part;if(-not $nodes.ContainsKey($key)){if($parent){$node=$parent.Nodes.Add($part)}else{$node=$tree.Nodes.Add($part)};$node.Tag=$key;$nodes[$key]=$node};$parent=$nodes[$key]}
        }
        $tree.SelectedNode=$all
    }finally{$tree.EndUpdate()}
}
$tree.Add_AfterSelect({param($sender,$eventArgs)$value=[string]$eventArgs.Node.Tag;$index=0;if($value){$index=$cmbSubject.Items.IndexOf($value)};if($index -ge 0){$cmbSubject.SelectedIndex=$index}})
Update-NavigationTree

# The original drop handlers remain, with cancellation/release performed before moves.
foreach($control in @($list,$tree,$previewHost,$addressLabel)){$control.AllowDrop=$true;$control.Add_DragEnter($dropEnter);$control.Add_DragDrop($dropAction)}
$ctx.Add_Opening({Cancel-DuplicateScan;Stop-FilePreview})

$refreshTimer=New-Object Windows.Forms.Timer;$refreshTimer.Interval=160
$script:LastGateRefresh=Get-Date
$script:LastSearchRefresh=Get-Date
$refreshTimer.Add_Tick({
    foreach($kind in @('SearchJob','IndexJob','DedupeJob')){
        $job=Get-Variable -Name $kind -Scope Script -ValueOnly
        if(-not $job){continue}
        $state=Read-LibraryJob $job
        if($state -and $state.State -eq 'running' -and $kind -eq 'DedupeJob' -and $job.Task -eq 'scan'){
            $lblStatus.Text='检查重复文档  '+$state.Data.Done+' / '+$state.Data.Total+'   ·   可继续浏览或取消'
        }
        if($state -and $state.State -in @('done','failed')){
            Set-Variable -Name $kind -Scope Script -Value $null
            $task=$job.Task;$automatic=$job.Auto;Close-LibraryJob $job
            if($state.State -eq 'failed'){$lblStatus.Text='操作未完成：'+$state.Error;if($kind -eq 'DedupeJob'){$dedupeProgress.Visible=$false;$cancelScan.Visible=$false};continue}
            switch($task){
                'search'{if($script:SearchAgain){$script:SearchAgain=$false;Invoke-Search -KeepPage}else{Show-SearchResults $state.Data}}
                'rebuild'{$lblStatus.Text='索引已更新';Invoke-Search -KeepPage}
                'index'{if($state.Data.Changed){Invoke-Search -KeepPage}}
                'scan'{
                    $dedupeProgress.Visible=$false;$cancelScan.Visible=$false;$plan=@($state.Data.Plan)
                    if($automatic){if($plan.Count){$script:DedupeJob=Start-LibraryJob @{Task='cleanup';Plan=$plan};$dedupeProgress.Visible=$true}}
                    else{Show-DuplicatePlan $plan}
                }
                'cleanup'{
                    $dedupeProgress.Visible=$false;$cancelScan.Visible=$false
                    $count=@($state.Data.Outcomes | Where-Object Status -eq 'recycled').Count
                    $skipped=@($state.Data.Outcomes | Where-Object Status -eq 'skipped').Count
                    $lblStatus.Text='已送入回收站 '+$count+' 份，跳过 '+$skipped+' 份';Invoke-Search
                }
            }
        }elseif($job.Process.HasExited -and (-not $state -or $state.State -eq 'running')){Set-Variable -Name $kind -Scope Script -Value $null;Close-LibraryJob $job;$lblStatus.Text='后台任务已退出，请重试。'}
    }
    if($script:PreviewJob -and $script:PreviewJob.Ready -and $script:PreviewJob.Process.HasExited){Stop-FilePreview;$previewText.Visible=$true;$previewText.Text='预览进程已退出。重新选择文件即可重试。'}
    if($script:PreviewJob){
        $previewJob=$script:PreviewJob
        if(-not $previewJob.Ready -and [IO.File]::Exists($previewJob.Status)){
            try{
                $state=(Read-AtomicUtf8 $previewJob.Status)|ConvertFrom-Json
                if($state.State -eq 'ready'){
                    $previewJob.Ready=$true;$previewJob.Handle=[long]$state.Handle;$previewJob.Pages=[int]$state.Pages
                    $previewText.Visible=$false
                    $pageLabel.Text='系统原生预览';$previous.Enabled=$false;$next.Enabled=$false
                    if($state.Mode -eq 'pdf'){$pageLabel.Text=($state.Page+1).ToString()+' / '+$state.Pages;$previous.Enabled=$state.Page -gt 0;$next.Enabled=$state.Page -lt ($state.Pages-1)}
                    elseif($state.Mode -eq 'text'){$pageLabel.Text='文本预览'}
                    elseif($state.Mode -eq 'image'){$pageLabel.Text='图片预览'}
                }elseif($state.State -eq 'failed'){Stop-FilePreview;$previewText.Visible=$true;$previewText.Text='此文件暂时无法预览。请点击下方“打开文件”。';$pageLabel.Text='预览不可用'}
            }catch{}
        }elseif(-not $previewJob.Ready -and ((Get-Date)-$previewJob.Started).TotalSeconds -gt 10){
            $file=$script:PreviewPath;$page=$script:PreviewPage;$fallback=$previewJob.Fallback;Stop-FilePreview
            if(-not $fallback){Show-FilePreview $file $page -Fallback}else{$previewText.Visible=$true;$previewText.Text='预览响应较慢，请用默认应用打开。'}
        }
    }
    if(((Get-Date)-$script:LastIndexPoll).TotalSeconds -ge 2 -and -not $script:UiUpdating){
        $script:LastIndexPoll=Get-Date
        $changed=Flush-IndexChangeMonitor
        $reconcile=((Get-Date)-$script:LastReconcile).TotalSeconds -ge 300
        $changeDir=Join-Path $script:IndexDir 'changes'
        $queued=(Test-Path -LiteralPath $changeDir) -and @(Get-ChildItem -LiteralPath $changeDir -Filter '*.json' -File | Select-Object -First 1).Count -gt 0
        if(-not $script:IndexJob -and ($changed -gt 0 -or $queued -or $reconcile -or -not [IO.File]::Exists($script:IndexManifest))){
            $script:IndexJob=Start-LibraryJob @{Task='index'}
            if($reconcile){$script:LastReconcile=Get-Date}
        }
        if([IO.File]::Exists($script:IndexManifest)){
            $signature=(Get-Item -LiteralPath $script:IndexManifest).LastWriteTimeUtc.Ticks
            if($signature -ne $script:IndexSignature){$script:IndexSignature=$signature;Invoke-Search -KeepPage;Update-NavigationTree}
        }
    }
    if(((Get-Date)-$script:LastGateRefresh).TotalSeconds -gt 15){
        $script:LastGateRefresh=Get-Date
        $valid=Test-DedupeVerified
        $autoCheck.Enabled=$valid
        if($valid){$gateLabel.Text='安全校验通过'}else{$gateLabel.Text='安全校验未通过 · 去重暂停';$autoCheck.Checked=$false}
    }
    if($script:AutoDedupe -and -not $script:DedupeJob -and -not $script:DedupeDialogOpen -and ((Get-Date)-$script:LastAutoScan).TotalSeconds -gt 30){$script:LastAutoScan=Get-Date;Show-DuplicateReview;if($script:DedupeJob){$script:DedupeJob.Auto=$true}}
})
if(-not $SelfTestForm){$refreshTimer.Start()}
$form.Add_FormClosing({param($sender,$eventArgs)if($script:DedupeJob -and $script:DedupeJob.Task -eq 'cleanup'){$eventArgs.Cancel=$true;$lblStatus.Text='副本回收尚未完成，请稍后关闭。'}})
$form.Add_FormClosed({Stop-IndexChangeMonitor;$previewDelay.Stop();$previewDelay.Dispose();Stop-FilePreview;Cancel-DuplicateScan;Close-LibraryJob $script:SearchJob -Stop;Close-LibraryJob $script:IndexJob -Stop;$fileIcons.Dispose()})
$form.Add_Shown({Start-IndexChangeMonitor})

$autoCheck.Add_CheckedChanged({if($autoCheck.Checked){$script:LastAutoScan=(Get-Date).AddSeconds(-31)}else{Cancel-DuplicateScan}})

# Search-first visual hierarchy, with the existing character as the theme anchor.
$script:ColBg=[Drawing.Color]::FromArgb(255,250,238)
$script:ColText=[Drawing.Color]::FromArgb(51,48,39)
$script:ColText2=[Drawing.Color]::FromArgb(150,137,108)
$form.BackColor=$script:ColBg
$rootLayout.SuspendLayout()
$rootLayout.Controls.Clear();$rootLayout.RowStyles.Clear();$rootLayout.RowCount=6
$rootLayout.Padding=New-Object Windows.Forms.Padding((S 24),0,(S 24),(S 8))
foreach($height in @(62,162,48,46)){[void]$rootLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',(S $height))))}
[void]$rootLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$rootLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',(S 30))))

$brand.BackColor=$script:ColBg
$picLogo.Size=New-Object Drawing.Size((S 36),(S 36));$picLogo.Location=New-Object Drawing.Point(0,(S 13));$picLogo.BackColor=$script:ColBg
$lblTitle.Font=New-Object Drawing.Font('Microsoft YaHei UI',14,[Drawing.FontStyle]::Bold);$lblTitle.Location=New-Object Drawing.Point((S 46),(S 17))
$brandHint.Text='你的文件，都在这里';$brandHint.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.5);$brandHint.Location=New-Object Drawing.Point((S 225),(S 24))
$rootLayout.Controls.Add($brand,0,0)

$hero=New-Object Nailong.RoundSurface
$hero.Dock='Fill';$hero.Fill=[Drawing.Color]::FromArgb(255,244,207);$hero.Stroke=[Drawing.Color]::FromArgb(248,228,174);$hero.Radius=(S 20)
$hero.Margin=New-Object Windows.Forms.Padding(0,0,0,(S 8));$rootLayout.Controls.Add($hero,0,1)
$heroTitle=New-Object Windows.Forms.Label
$heroTitle.Text='想找什么？搜一下就有。';$heroTitle.Font=New-Object Drawing.Font('Microsoft YaHei UI',21,[Drawing.FontStyle]::Bold)
$heroTitle.ForeColor=$script:ColText;$heroTitle.BackColor=$hero.Fill;$heroTitle.AutoSize=$true;$heroTitle.Location=New-Object Drawing.Point((S 26),(S 17));$hero.Controls.Add($heroTitle)
$mascot=New-Object Windows.Forms.PictureBox
$mascot.Image=$picLogo.Image;$mascot.SizeMode='Zoom';$mascot.BackColor=$hero.Fill;$mascot.Size=New-Object Drawing.Size((S 150),(S 138));$hero.Controls.Add($mascot)
$mascotNote=New-Object Windows.Forms.Label
$mascotNote.Text='奶龙帮你找';$mascotNote.Font=New-Object Drawing.Font('Microsoft YaHei UI',9,[Drawing.FontStyle]::Bold)
$mascotNote.AutoSize=$true;$mascotNote.ForeColor=[Drawing.Color]::FromArgb(171,128,35);$mascotNote.BackColor=$hero.Fill;$hero.Controls.Add($mascotNote)

$searchShell=New-Object Nailong.RoundSurface
$searchShell.Fill=[Drawing.Color]::White;$searchShell.Stroke=[Drawing.Color]::FromArgb(242,201,87);$searchShell.Radius=(S 17)
$searchShell.Location=New-Object Drawing.Point((S 26),(S 67));$searchShell.Height=(S 56);$hero.Controls.Add($searchShell)
$searchGlyph=New-Object Windows.Forms.Panel
$searchGlyph.Location=New-Object Drawing.Point((S 13),(S 16));$searchGlyph.Size=New-Object Drawing.Size((S 24),(S 24));$searchGlyph.BackColor=[Drawing.Color]::White
$searchGlyph.Add_Paint({param($sender,$e)$e.Graphics.SmoothingMode='AntiAlias';$pen=New-Object Drawing.Pen([Drawing.Color]::FromArgb(182,151,78),[single](2*$script:Scale));try{$e.Graphics.DrawEllipse($pen,(S 2),(S 2),(S 12),(S 12));$e.Graphics.DrawLine($pen,(S 13),(S 13),(S 20),(S 20))}finally{$pen.Dispose()}})
$searchShell.Controls.Add($searchGlyph)
$txtQuery.Dock='None';$txtQuery.BorderStyle='None';$txtQuery.Font=New-Object Drawing.Font('Microsoft YaHei UI',15)
$txtQuery.BackColor=[Drawing.Color]::White;$txtQuery.ForeColor=$script:ColText;$txtQuery.Location=New-Object Drawing.Point((S 47),(S 14));$searchShell.Controls.Add($txtQuery)
$null=[Nailong.Native]::SendMessage($txtQuery.Handle,0x1501,[IntPtr]1,'搜索文件名、正文关键词…')
$txtQuery.Add_GotFocus({$searchShell.Stroke=[Drawing.Color]::FromArgb(239,178,36);$searchShell.Invalidate()})
$txtQuery.Add_LostFocus({$searchShell.Stroke=[Drawing.Color]::FromArgb(242,201,87);$searchShell.Invalidate()})
$btnSearch=New-Object Nailong.ThemeSearchButton
$btnSearch.Radius=(S 13)
$btnSearch.Text='搜 索';$btnSearch.FlatStyle='Flat';$btnSearch.FlatAppearance.BorderSize=0;$btnSearch.UseVisualStyleBackColor=$false
$btnSearch.BackColor=[Drawing.Color]::FromArgb(249,196,57);$btnSearch.ForeColor=[Drawing.Color]::FromArgb(77,56,13)
$btnSearch.Font=New-Object Drawing.Font('Microsoft YaHei UI',12,[Drawing.FontStyle]::Bold)
$btnSearch.Size=New-Object Drawing.Size((S 112),(S 42));$btnSearch.Top=(S 7);$btnSearch.Cursor='Hand'

$btnSearch.Add_MouseEnter({$btnSearch.BackColor=[Drawing.Color]::FromArgb(255,207,73)})
$btnSearch.Add_MouseLeave({$btnSearch.BackColor=[Drawing.Color]::FromArgb(249,196,57)})
$btnSearch.Add_Click({Invoke-Search});$searchShell.Controls.Add($btnSearch);$form.AcceptButton=$btnSearch
$searchTips=New-Object Windows.Forms.Label
$searchTips.Text='文件名 + 正文一起搜     ·     空格组合关键词     ·     Ctrl + K 快速搜索'
$searchTips.AutoSize=$true;$searchTips.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
$searchTips.ForeColor=[Drawing.Color]::FromArgb(157,132,78);$searchTips.BackColor=$hero.Fill;$searchTips.Location=New-Object Drawing.Point((S 29),(S 131));$hero.Controls.Add($searchTips)
$hero.Add_Resize({
    $searchShell.Width=[Math]::Max((S 480),$hero.Width-(S 240))
    $txtQuery.Location=New-Object Drawing.Point((S 47),(S 15))
    $txtQuery.Width=[Math]::Max((S 200),$searchShell.Width-(S 190))
    $btnSearch.Left=$searchShell.Width-$btnSearch.Width-(S 8)
    $mascot.Left=$hero.Width-(S 182);$mascot.Top=(S 6)
    $mascotNote.Left=$hero.Width-(S 143);$mascotNote.Top=(S 126)
})

$categoryBar=New-Object Windows.Forms.FlowLayoutPanel
$categoryBar.Dock='Fill';$categoryBar.WrapContents=$false;$categoryBar.Padding=New-Object Windows.Forms.Padding(0,(S 7),0,0)
$rootLayout.Controls.Add($categoryBar,0,2)
$script:CategoryButtons=@{}
foreach($definition in @(@('全部',0),@('PDF',1),@('文档',2),@('文本',3),@('图片',4),@('压缩包',5))){
    $pill=New-Object Windows.Forms.Button;$pill.Text=$definition[0];$pill.Tag=[int]$definition[1]
    $pill.Size=New-Object Drawing.Size((S 82),(S 32));$pill.Margin=New-Object Windows.Forms.Padding(0,0,(S 10),0)
    $pill.FlatStyle='Flat';$pill.FlatAppearance.BorderSize=0;$pill.UseVisualStyleBackColor=$false;$pill.BackColor=$script:ColBg;$pill.ForeColor=$script:ColText2
    $pill.Font=New-Object Drawing.Font('Microsoft YaHei UI',10);$pill.Cursor='Hand'
    $pill.Add_SizeChanged({param($sender,$e)Set-RoundedRegion $sender (S 12)})
    $pill.Add_Click({param($sender,$e)$formatFilter.SelectedIndex=[int]$sender.Tag})
    $categoryBar.Controls.Add($pill);Set-RoundedRegion $pill (S 12);$script:CategoryButtons[[int]$definition[1]]=$pill
}
function Update-CategoryPills{
    foreach($key in $script:CategoryButtons.Keys){
        $pill=$script:CategoryButtons[$key]
        if($key -eq $formatFilter.SelectedIndex){$pill.BackColor=[Drawing.Color]::FromArgb(255,231,157);$pill.ForeColor=[Drawing.Color]::FromArgb(143,99,12);$pill.Font=New-Object Drawing.Font('Microsoft YaHei UI',10,[Drawing.FontStyle]::Bold)}
        else{$pill.BackColor=$script:ColBg;$pill.ForeColor=$script:ColText2;$pill.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)}
    }
}
$formatFilter.Add_SelectedIndexChanged({Update-CategoryPills});Update-CategoryPills

$filters.Controls.Clear();$filters.Padding=New-Object Windows.Forms.Padding(0,(S 4),0,0)
$dateFilter.FlatStyle='Flat';$dateFilter.Width=(S 160);$dateFilter.BackColor=$script:ColBg
foreach($control in @($dateFilter,$chkContent)){$control.Margin=New-Object Windows.Forms.Padding(0,(S 3),(S 18),0);$filters.Controls.Add($control)}
$scopeLabel=New-Object Windows.Forms.Label;$scopeLabel.AutoSize=$true;$scopeLabel.Text='范围：全部目录';$scopeLabel.ForeColor=$script:ColText2;$scopeLabel.Margin=New-Object Windows.Forms.Padding((S 4),(S 7),0,0);$filters.Controls.Add($scopeLabel)
$rootLayout.Controls.Add($filters,0,3)
$tree.Add_AfterSelect({param($sender,$e)if([string]$e.Node.Tag){$scopeLabel.Text='范围：'+[string]$e.Node.Tag}else{$scopeLabel.Text='范围：全部目录'}})

$resultCard=New-Object Nailong.RoundSurface
$resultCard.Dock='Fill';$resultCard.Fill=[Drawing.Color]::White;$resultCard.Stroke=[Drawing.Color]::FromArgb(239,235,224);$resultCard.Radius=(S 18)
$resultCard.Padding=New-Object Windows.Forms.Padding((S 16),(S 10),(S 16),(S 12));$resultCard.Margin=New-Object Windows.Forms.Padding(0,0,0,(S 4));$rootLayout.Controls.Add($resultCard,0,4)
$resultLayout=New-Object Windows.Forms.TableLayoutPanel;$resultLayout.Dock='Fill';$resultLayout.RowCount=3;$resultLayout.ColumnCount=1;$resultLayout.BackColor=[Drawing.Color]::White
[void]$resultLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',(S 44))));[void]$resultLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
$resultCard.Controls.Add($resultLayout)
[void]$resultLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',(S 36))))
$pageBar=New-Object Windows.Forms.FlowLayoutPanel; $pageBar.Dock='Fill'; $pageBar.FlowDirection='RightToLeft'; $pageBar.WrapContents=$false; $pageBar.BackColor=[Drawing.Color]::White
$pageNextButton=New-Object Windows.Forms.Button; $pageNextButton.Text='下一页'; $pageNextButton.Width=(S 84); $pageNextButton.Enabled=$false
$pagePreviousButton=New-Object Windows.Forms.Button; $pagePreviousButton.Text='上一页'; $pagePreviousButton.Width=(S 84); $pagePreviousButton.Enabled=$false
$pageInfo=New-Object Windows.Forms.Label; $pageInfo.Text='第 1 / 1 页'; $pageInfo.AutoSize=$true; $pageInfo.Margin=New-Object Windows.Forms.Padding((S 12),(S 7),(S 12),0)
$pageBar.Controls.AddRange(@($pageNextButton,$pageInfo,$pagePreviousButton)); $resultLayout.Controls.Add($pageBar,0,2)
$pageNextButton.Add_Click({$script:PageOffset+=$script:PageSize;Invoke-Search -KeepPage})
$pagePreviousButton.Add_Click({$script:PageOffset=[Math]::Max(0,$script:PageOffset-$script:PageSize);Invoke-Search -KeepPage})
$resultHeader=New-Object Windows.Forms.Panel;$resultHeader.Dock='Fill';$resultHeader.BackColor=[Drawing.Color]::White;$resultLayout.Controls.Add($resultHeader,0,0)
$resultHeading=New-Object Windows.Forms.Label;$resultHeading.Text='全部资料';$resultHeading.AutoSize=$true;$resultHeading.Font=New-Object Drawing.Font('Microsoft YaHei UI',12,[Drawing.FontStyle]::Bold);$resultHeading.ForeColor=$script:ColText;$resultHeading.Location=New-Object Drawing.Point((S 5),(S 9));$resultHeader.Controls.Add($resultHeading)
$resultActions=New-Object Windows.Forms.FlowLayoutPanel;$resultActions.AutoSize=$true;$resultActions.WrapContents=$false;$resultActions.BackColor=[Drawing.Color]::White;$resultHeader.Controls.Add($resultActions)
foreach($definition in @(@('目录','navigation'),@('批量打印','Show-BatchPrint'),@('更多 ···','more'))){
    $button=New-Object Windows.Forms.Button;$button.Text=$definition[0];$button.Size=New-Object Drawing.Size((S 86),(S 30))
    $button.FlatStyle='Flat';$button.FlatAppearance.BorderSize=0;$button.UseVisualStyleBackColor=$false;$button.BackColor=[Drawing.Color]::White;$button.ForeColor=$script:ColText2;$button.Cursor='Hand'
    $operation=$definition[1]
    $button.Add_Click({param($sender,$e)if($operation -eq 'navigation'){$navigation.Panel1Collapsed=-not $navigation.Panel1Collapsed}elseif($operation -eq 'more'){$moreMenu.Show($sender,0,$sender.Height)}else{& $operation}}.GetNewClosure())
    $resultActions.Controls.Add($button)
}
$previewToggle.Text='预览';$previewToggle.BackColor=[Drawing.Color]::White;$previewToggle.ForeColor=$script:ColText2;$previewToggle.Margin=New-Object Windows.Forms.Padding((S 6),(S 6),0,0);$resultActions.Controls.Add($previewToggle)
$resultHeader.Add_Resize({$resultActions.Left=[Math]::Max((S 180),$resultHeader.Width-$resultActions.PreferredSize.Width-(S 3));$resultActions.Top=(S 3)})
$moreMenu=New-Object Windows.Forms.ContextMenuStrip
foreach($definition in @(@('管理目录','Show-DirectoryManager'),@('重命名 F2','Rename-SelectedFile'),@('检查重复文档','Show-DuplicateReview'),@('重建搜索索引','Invoke-Rebuild'),@('识别扫描件文字','Invoke-OcrRebuild'))){
    $item=New-Object Windows.Forms.ToolStripMenuItem;$item.Text=$definition[0];$operation=$definition[1];$item.Add_Click({& $operation}.GetNewClosure());[void]$moreMenu.Items.Add($item)
}
$openFolderMenu=New-Object Windows.Forms.ToolStripMenuItem;$openFolderMenu.Text='在资源管理器中打开';$openFolderMenu.Add_Click({Start-Process explorer.exe -ArgumentList ('"'+$script:Root+'"')});[void]$moreMenu.Items.Add($openFolderMenu)
[void]$moreMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$autoCheck.BackColor=[Drawing.Color]::White;$autoCheck.Margin=New-Object Windows.Forms.Padding((S 8));$autoHost=New-Object Windows.Forms.ToolStripControlHost($autoCheck);[void]$moreMenu.Items.Add($autoHost)
$gateLabel.BackColor=[Drawing.Color]::White;$gateHost=New-Object Windows.Forms.ToolStripControlHost($gateLabel);[void]$moreMenu.Items.Add($gateHost)
$navigation.Panel1Collapsed=$true;$navigation.Margin=New-Object Windows.Forms.Padding(0);$resultLayout.Controls.Add($navigation,0,1)
$tree.BackColor=[Drawing.Color]::FromArgb(255,252,243);$tree.ItemHeight=(S 34)
$fileIcons.ImageSize=New-Object Drawing.Size((S 28),(S 28))
$list.Font=New-Object Drawing.Font('Microsoft YaHei UI',10);$list.BackColor=[Drawing.Color]::White
$script:AutoOpenPreview=$true;$previewToggle.Checked=$false
$previewToggle.Add_Click({$script:AutoOpenPreview=$previewToggle.Checked})
$list.Add_SelectedIndexChanged({if(-not $script:ListUpdating -and $list.SelectedItems.Count -gt 0 -and $script:AutoOpenPreview){$previewToggle.Checked=$true}})
$rootLayout.Controls.Add($statusRow,0,5)
$lblStatus.Font=New-Object Drawing.Font('Microsoft YaHei UI',9);$lblStatus.Padding=New-Object Windows.Forms.Padding((S 3),0,0,0)
$form.KeyPreview=$true
$form.Add_KeyDown({param($sender,$e)if($e.Control -and $e.KeyCode -in @('K','F')){$txtQuery.Focus();$txtQuery.SelectAll();$e.SuppressKeyPress=$true}})
$form.Add_Shown({$txtQuery.Focus()})
$txtQuery.Add_TextChanged({if([string]::IsNullOrWhiteSpace($txtQuery.Text)){$resultHeading.Text='全部资料'}else{$resultHeading.Text='搜索结果'}})
$rootLayout.ResumeLayout($true)
$hero.PerformLayout();$resultHeader.PerformLayout()

function Update-ResultColumnWidths {
    if($list.ClientSize.Width -lt (S 350)){return}
    $available=$list.ClientSize.Width-(S 26)
    $list.Columns[1].Width=(S 68);$list.Columns[2].Width=(S 142);$list.Columns[3].Width=(S 120)
    $list.Columns[0].Width=[Math]::Max((S 190),$available-$list.Columns[1].Width-$list.Columns[2].Width-$list.Columns[3].Width-$list.Columns[4].Width)
}
$list.Add_Resize({Update-ResultColumnWidths})
$searchShell.Add_Resize({
    $txtQuery.Location=New-Object Drawing.Point((S 47),(S 15))
    $txtQuery.Width=[Math]::Max((S 200),$searchShell.Width-(S 190))
    $btnSearch.Left=$searchShell.Width-$btnSearch.Width-(S 8)
})
$txtQuery.Location=New-Object Drawing.Point((S 47),(S 15))
Update-ResultColumnWidths
