# Main window and control construction.
$form = New-Object $formType
try {
    $dbFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
    $dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', $dbFlags)
    if ($dbProp -ne $null) { $dbProp.SetValue($form, $true, $null) }
} catch { Write-Log ('search-controls.ps1 UI fallback: '+$_.Exception.Message) -Level INFO }
$form.Text = [string]$script:Cfg.search.title + ' · v' + $script:AppVersion
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size((S 1320), (S 820))
$form.MinimumSize = New-Object System.Drawing.Size((S 1100), (S 650))
$form.BackColor = $script:ColBg
try { $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10) } catch { Write-Log ('search-controls.ps1 UI fallback: '+$_.Exception.Message) -Level INFO }
try {
    if (Test-Path -LiteralPath $script:IconPath) { $form.Icon = New-Object System.Drawing.Icon($script:IconPath) }
} catch { Write-Log ('search-controls.ps1 UI fallback: '+$_.Exception.Message) -Level INFO }

$rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
$rootLayout.Dock = 'Fill'
$rootLayout.ColumnCount = 1
$rootLayout.RowCount = 6
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, (S 78))))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, (S 64))))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, (S 88))))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, (S 32))))
[void]$rootLayout.RowStyles.Insert(3, (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, (S 76))))
$form.Controls.Add($rootLayout)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Fill'
$header.BackColor = $script:ColBg
$rootLayout.Controls.Add($header, 0, 0)

$picLogo = New-Object System.Windows.Forms.PictureBox
$picLogo.Location = New-Object System.Drawing.Point((S 24), (S 17))
$picLogo.Size = New-Object System.Drawing.Size((S 42), (S 42))
$picLogo.SizeMode = 'Zoom'
$picLogo.BackColor = $script:ColBg
$logoImage = $null
try {
    if (Test-Path -LiteralPath $script:LogoPath) {
        $logoImage = [System.Drawing.Image]::FromFile($script:LogoPath)
        $picLogo.Image = $logoImage
    }
} catch { Write-Log ('search-controls.ps1 UI fallback: '+$_.Exception.Message) -Level INFO }
$header.Controls.Add($picLogo)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = [string]$script:Cfg.search.title
$lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $script:ColText
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point((S 80), (S 18))
$header.Controls.Add($lblTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text = ''
$lblSubtitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$lblSubtitle.ForeColor = $script:ColText2
$lblSubtitle.AutoSize = $true
$lblSubtitle.Location = New-Object System.Drawing.Point((S 82), (S 48))
$header.Controls.Add($lblSubtitle)

$searchRow = New-Object System.Windows.Forms.Panel
$searchRow.Dock = 'Fill'
$searchRow.BackColor = $script:ColBg
$rootLayout.Controls.Add($searchRow, 0, 1)

$searchBar = New-Object System.Windows.Forms.Panel
$searchBar.BackColor = $script:ColSurface
$searchBar.Location = New-Object System.Drawing.Point((S 24), (S 8))
$searchBar.Size = New-Object System.Drawing.Size((S 1020), (S 48))
$searchRow.Controls.Add($searchBar)
Set-RoundedRegion -Control $searchBar -Radius (S 24)
$searchBar.Add_Resize({
    Set-RoundedRegion -Control $searchBar -Radius (S 24)
    if ($null -ne $txtQuery -and $null -ne $clearBtn) {
        $txtQuery.Width = [Math]::Max((S 80), $searchBar.Width - (S 46) - (S 42))
        $clearBtn.Left = $searchBar.Width - (S 34)
    }
})
$searchBar.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $pen = New-Object System.Drawing.Pen($script:ColText2, [single](1.8 * $script:Scale))
    $g.DrawEllipse($pen, (S 18), (S 15), (S 12), (S 12))
    $g.DrawLine($pen, (S 28), (S 26), (S 34), (S 32))
    $pen.Dispose()
})

$txtQuery = New-Object System.Windows.Forms.TextBox
$txtQuery.BorderStyle = 'None'
$txtQuery.BackColor = $script:ColSurface
$txtQuery.ForeColor = $script:ColText
$txtQuery.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
$txtQuery.Location = New-Object System.Drawing.Point((S 46), (S 12))
$txtQuery.Width = (S 900)
$searchBar.Controls.Add($txtQuery)

$clearBtn = New-Object System.Windows.Forms.Label
$clearBtn.Text = [string][char]0x00D7
$clearBtn.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14)
$clearBtn.ForeColor = $script:ColText2
$clearBtn.BackColor = $script:ColSurface
$clearBtn.AutoSize = $false
$clearBtn.Size = New-Object System.Drawing.Size((S 24), (S 24))
$clearBtn.Location = New-Object System.Drawing.Point((S 986), (S 12))
$clearBtn.TextAlign = 'MiddleCenter'
$clearBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$clearBtn.Add_Click({
    $txtQuery.ForeColor = $script:ColText
    $txtQuery.Clear()
    $txtQuery.Focus()
})
$searchBar.Controls.Add($clearBtn)



$btnSearch = New-RoundButton -Text ([string]$script:Cfg.search.search) -Kind 'primary'
$btnSearch.Size = New-Object System.Drawing.Size((S 100), (S 44))
$btnSearch.Location = New-Object System.Drawing.Point((S 1056), (S 10))
$searchRow.Controls.Add($btnSearch)
$searchRow.Add_Resize({
    $w = $searchRow.ClientSize.Width
    if ($w -le 0) { return }
    $searchBar.Width = [Math]::Max((S 240), $w - (S 24) - (S 24) - (S 100) - (S 12))
    if ($null -ne $btnSearch) { $btnSearch.Left = $w - (S 24) - (S 100) }
})

$toolbar = New-Object System.Windows.Forms.FlowLayoutPanel
$toolbar.Dock = 'Fill'
$toolbar.BackColor = $script:ColBg
$toolbar.Padding = New-Object System.Windows.Forms.Padding((S 24), (S 6), (S 24), 0)
$toolbar.WrapContents = $true
$toolbar.AutoScroll = $false
$rootLayout.Controls.Add($toolbar, 0, 2)

$chkContent = New-Object System.Windows.Forms.CheckBox
$chkContent.Text = [string]$script:Cfg.search.content
$chkContent.Checked = $true
$chkContent.AutoSize = $true
$chkContent.FlatStyle = 'Flat'
$chkContent.ForeColor = $script:ColText
$chkContent.BackColor = $script:ColBg
$chkContent.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
$chkContent.Margin = New-Object System.Windows.Forms.Padding(0, (S 10), (S 14), 0)
$toolbar.Controls.Add($chkContent)

$lblSubject = New-Object System.Windows.Forms.Label
$lblSubject.Text = '目录筛选'
$lblSubject.AutoSize = $true
$lblSubject.ForeColor = $script:ColText2
$lblSubject.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
$lblSubject.Margin = New-Object System.Windows.Forms.Padding((S 4), (S 12), (S 6), 0)
$toolbar.Controls.Add($lblSubject)

$cmbSubject = New-Object System.Windows.Forms.ComboBox
$cmbSubject.DropDownStyle = 'DropDownList'
$cmbSubject.FlatStyle = 'Flat'
$cmbSubject.Width = (S 140)
$cmbSubject.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
$cmbSubject.BackColor = $script:ColBg
$cmbSubject.ForeColor = $script:ColText
$cmbSubject.Margin = New-Object System.Windows.Forms.Padding(0, (S 7), (S 18), 0)
$toolbar.Controls.Add($cmbSubject)

[void]$cmbSubject.Items.Add([string]$script:Cfg.search.allSubjects)
foreach ($rule in $script:Cfg.subjects) { [void]$cmbSubject.Items.Add([string]$rule.name) }
[void]$cmbSubject.Items.Add([string]$script:Cfg.otherFolderName)
if (-not $cmbSubject.Items.Contains([string]$script:Cfg.search.unclassified)) {
    [void]$cmbSubject.Items.Add([string]$script:Cfg.search.unclassified)
}
$cmbSubject.SelectedIndex = 0

$chkContent.Checked = $script:InitialContent
if (-not [string]::IsNullOrEmpty($script:InitialSubject)) {
    $initialSubjectIndex = $cmbSubject.Items.IndexOf($script:InitialSubject)
    if ($initialSubjectIndex -ge 0) { $cmbSubject.SelectedIndex = $initialSubjectIndex }
}
if (-not [string]::IsNullOrEmpty($script:InitialQuery)) { $txtQuery.Text = $script:InitialQuery }

$btnRebuild = New-RoundButton -Text ([string]$script:Cfg.search.rebuild) -Kind 'text'
$btnRebuild.AutoSize = $true
$btnRebuild.MinimumSize = New-Object System.Drawing.Size((S 88), (S 32))
$btnRebuild.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
$btnRebuild.Margin = New-Object System.Windows.Forms.Padding(0, (S 4), (S 10), 0)
$toolbar.Controls.Add($btnRebuild)

$btnOpenRoot = New-RoundButton -Text ([string]$script:Cfg.search.openRoot) -Kind 'text'
$btnOpenRoot.AutoSize = $true
$btnOpenRoot.MinimumSize = New-Object System.Drawing.Size((S 112), (S 32))
$btnOpenRoot.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
$btnOpenRoot.Margin = New-Object System.Windows.Forms.Padding(0, (S 4), 0, 0)
$toolbar.Controls.Add($btnOpenRoot)

$listPanel = New-Object System.Windows.Forms.Panel
$listPanel.Dock = 'Fill'
$listPanel.BackColor = $script:ColBg
$listPanel.Padding = New-Object System.Windows.Forms.Padding((S 24), (S 2), (S 24), 0)
$rootLayout.Controls.Add($listPanel, 0, 4)

$list = New-Object $listType
$list.Dock = 'Fill'
$list.View = 'Details'
$list.OwnerDraw = $false
$list.FullRowSelect = $true
$list.HideSelection = $false
$list.MultiSelect = $true
$list.GridLines = $false
$list.BorderStyle = 'None'
$list.BackColor = $script:ColBg
$list.ForeColor = $script:ColText
$list.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
[void]$list.Columns.Add([string]$script:Cfg.search.colFile, (S 300))
[void]$list.Columns.Add([string]$script:Cfg.search.colSize, (S 76))
[void]$list.Columns.Add([string]$script:Cfg.search.colTime, (S 160))
[void]$list.Columns.Add([string]$script:Cfg.search.colPath, (S 220))
[void]$list.Columns.Add([string]$script:Cfg.search.colHit, (S 235))
$rowImages = New-Object System.Windows.Forms.ImageList
$rowImages.ImageSize = New-Object System.Drawing.Size(1, (S 38))
$list.SmallImageList = $rowImages
try {
    $prop = $list.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
    if ($prop -ne $null) { $prop.SetValue($list, $true, $null) }
} catch { Write-Log ('search-controls.ps1 UI fallback: '+$_.Exception.Message) -Level INFO }
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.Size = New-Object Drawing.Size((S 1220), (S 480))
$split.Panel1MinSize = (S 500)
$split.Panel2MinSize = (S 280)
$split.SplitterDistance = (S 820)
$split.FixedPanel = 'Panel2'
$split.Panel1.Controls.Add($list)
$listPanel.Controls.Add($split)
$previewLayout = New-Object System.Windows.Forms.TableLayoutPanel
$previewLayout.Dock = 'Fill'
$previewLayout.Padding = New-Object System.Windows.Forms.Padding((S 16))
$previewLayout.RowCount = 3
$previewLayout.ColumnCount = 1
[void]$previewLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', (S 56))))
[void]$previewLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$previewLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', (S 38))))
$split.Panel2.BackColor = $script:ColSurface
$split.Panel2.Controls.Add($previewLayout)
$previewTitle = New-Object System.Windows.Forms.Label
$previewTitle.Dock = 'Fill'
$previewTitle.Text = '选择文件以预览'
$previewTitle.AutoEllipsis = $true
$previewTitle.Font = $script:FontHeader
$previewLayout.Controls.Add($previewTitle, 0, 0)
$previewHost = New-Object System.Windows.Forms.Panel
$previewHost.Dock = 'Fill'
$previewLayout.Controls.Add($previewHost, 0, 1)
$previewText = New-Object System.Windows.Forms.TextBox
$previewText.Multiline = $true
$previewText.ReadOnly = $true
$previewText.ScrollBars = 'Vertical'
$previewText.BorderStyle = 'None'
$previewText.BackColor = $script:ColSurface
$previewText.Dock = 'Fill'
$previewText.Text = '支持 Word 正文、PDF 首页、图片和文本预览。'
$previewHost.Controls.Add($previewText)
$previewImage = New-Object System.Windows.Forms.PictureBox
$previewImage.Dock = 'Fill'
$previewImage.SizeMode = 'Zoom'
$previewImage.Visible = $false
$previewHost.Controls.Add($previewImage)
$previewHint = New-Object System.Windows.Forms.Label
$previewHint.Dock = 'Fill'
$previewHint.ForeColor = $script:ColText2
$previewHint.Text = '双击列表文件，可用默认程序查看完整内容。'
$previewHint.AutoEllipsis = $true
$previewLayout.Controls.Add($previewHint, 0, 2)
$list.Columns[0].Width = (S 260)
$list.Columns[3].Width = (S 160)
$list.Columns[4].Width = (S 200)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Dock = 'Fill'
$lblStatus.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 212)
$lblStatus.ForeColor = $script:ColText2
$lblStatus.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$lblStatus.TextAlign = 'MiddleLeft'
$lblStatus.Padding = New-Object System.Windows.Forms.Padding((S 26), 0, (S 10), 0)
$rootLayout.Controls.Add($lblStatus, 0, 5)
