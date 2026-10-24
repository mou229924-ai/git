param(
    [string]$Query = '',
    [string]$Report = '',
    [switch]$RebuildIndex,
    [switch]$SelfTestForm,
    [string]$UiTestOutput = '',
    [string]$Capture = '',
    [string]$CaptureQuery = '',
    [string]$RestoreFile = ''
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib.ps1')

if ($RebuildIndex) {
    $rebuilt = Rebuild-Index
    Write-Output ('rebuilt total=' + [string]$rebuilt.Total + ' withText=' + [string]$rebuilt.WithText)
    exit
}

if (-not [string]::IsNullOrEmpty($Query) -or -not [string]::IsNullOrEmpty($Report)) {
    $results = @(Search-Index -Query $Query -Limit 500)
    if (-not [string]::IsNullOrEmpty($Report)) {
        $sb = New-Object System.Text.StringBuilder
        foreach ($r in $results) {
            [void]$sb.AppendLine([string]$r.score + "`t" + [string]$r.subject + "`t" + [string]$r.rel + "`t" + [string]$r.hit)
        }
        [void]$sb.AppendLine('TOTAL=' + [string]$results.Count)
        [System.IO.File]::WriteAllText($Report, $sb.ToString(), $script:Utf8)
    }
    Write-Output ('results=' + [string]$results.Count)
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

try {
    $dpiCode = @'
using System;
using System.Runtime.InteropServices;
public class SubjectSearchDpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
}
'@
    Add-Type -TypeDefinition $dpiCode
} catch {
}
$dpiAware = $false
try { $dpiAware = [SubjectSearchDpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }
if (-not $dpiAware) {
    try { [SubjectSearchDpi]::SetProcessDPIAware() | Out-Null } catch { }
}
$script:InitialQuery = ''
$script:InitialSubject = ''
$script:InitialContent = $true
$script:InitialCenter = $null
$script:Dpi = 0
if (-not [string]::IsNullOrEmpty($RestoreFile) -and (Test-Path -LiteralPath $RestoreFile)) {
    try {
        $restore = [System.IO.File]::ReadAllText($RestoreFile, $script:Utf8) | ConvertFrom-Json
        $script:InitialQuery = [string]$restore.Query
        $script:InitialSubject = [string]$restore.Subject
        $script:InitialContent = [bool]$restore.Content
        $script:InitialCenter = New-Object System.Drawing.Point([int]$restore.CenterX, [int]$restore.CenterY)
        $script:Dpi = [int]$restore.Dpi
    } catch {
    }
    Remove-Item -LiteralPath $RestoreFile -Force -ErrorAction SilentlyContinue
}
if ($script:Dpi -le 0) {
    $dpiGraphics = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:Dpi = $dpiGraphics.DpiX
    $dpiGraphics.Dispose()
}
$script:Scale = [Math]::Max(1.0, [double]$script:Dpi / 96.0)
function S {
    param([double]$V)
    return [int][Math]::Round($V * $script:Scale)
}

$uiCode = @'
namespace SubjectSearchUi {
    public class SmoothListView : System.Windows.Forms.ListView {
        public SmoothListView() {
            this.DoubleBuffered = true;
            this.SetStyle(System.Windows.Forms.ControlStyles.OptimizedDoubleBuffer | System.Windows.Forms.ControlStyles.AllPaintingInWmPaint, true);
            this.UpdateStyles();
        }
    }
}
'@
$formType = 'System.Windows.Forms.Form'
$listType = 'System.Windows.Forms.ListView'
try {
    Add-Type -TypeDefinition $uiCode -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'
    $listType = 'SubjectSearchUi.SmoothListView'
} catch {
}

$script:IconPath = Join-Path $script:AppDir 'assets\app.ico'
$script:LogoPath = Join-Path $script:AppDir 'assets\logo.png'

$script:ColBg = [System.Drawing.Color]::FromArgb(255, 248, 226)
$script:ColSurface = [System.Drawing.Color]::FromArgb(255, 240, 194)
$script:ColSurface2 = [System.Drawing.Color]::FromArgb(249, 224, 160)
$script:ColBorder = [System.Drawing.Color]::FromArgb(230, 205, 145)
$script:ColSep = [System.Drawing.Color]::FromArgb(249, 237, 207)
$script:ColText = [System.Drawing.Color]::FromArgb(81, 60, 22)
$script:ColText2 = [System.Drawing.Color]::FromArgb(139, 114, 63)
$script:ColAccent = [System.Drawing.Color]::FromArgb(168, 107, 15)
$script:ColAccentHover = [System.Drawing.Color]::FromArgb(133, 83, 11)
$script:ColSelected = [System.Drawing.Color]::FromArgb(249, 217, 120)
$script:ColHover = [System.Drawing.Color]::FromArgb(255, 244, 212)
$script:ColChip = [System.Drawing.Color]::FromArgb(255, 240, 194)

$script:BrBg = New-Object System.Drawing.SolidBrush($script:ColBg)
$script:BrHover = New-Object System.Drawing.SolidBrush($script:ColHover)
$script:BrSelected = New-Object System.Drawing.SolidBrush($script:ColSelected)
$script:BrChip = New-Object System.Drawing.SolidBrush($script:ColChip)
$script:PenSep = New-Object System.Drawing.Pen($script:ColSep, 1)
$script:PenBorder = New-Object System.Drawing.Pen($script:ColBorder, 1)
$script:FontName = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$script:FontNorm = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:FontHeader = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$script:Tf = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
$script:TfCenter = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix

$script:HoverIndex = -1

function New-RoundButton {
    param([string]$Text, [string]$Kind = 'text')
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.UseVisualStyleBackColor = $false
    $b.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $b.AutoSize = $false
    $b.Padding = New-Object System.Windows.Forms.Padding((S 10), 0, (S 10), 0)
    $b.TextAlign = 'MiddleCenter'
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Kind -eq 'primary') {
        $baseColor = $script:ColAccent
        $hoverColor = $script:ColAccentHover
        $b.BackColor = $baseColor
        $b.ForeColor = [System.Drawing.Color]::FromArgb(255, 249, 231)
    } else {
        $baseColor = $script:ColBg
        $hoverColor = $script:ColSurface
        $b.BackColor = $baseColor
        $b.ForeColor = $script:ColAccent
    }
    $b.Add_MouseEnter({ param($s, $e) $s.BackColor = $hoverColor }.GetNewClosure())
    $b.Add_MouseLeave({ param($s, $e) $s.BackColor = $baseColor }.GetNewClosure())
    $b.Add_SizeChanged({ param($s, $e) Set-RoundedRegion -Control $s -Radius ([single]($s.Height / 2)) })
    return $b
}

function Format-Size {
    param([long]$Size)
    if ($Size -ge 1073741824) { return ('{0:N1} GB' -f ([double]$Size / 1073741824)) }
    if ($Size -ge 1048576) { return ('{0:N1} MB' -f ([double]$Size / 1048576)) }
    if ($Size -ge 1024) { return ('{0:N0} KB' -f ([double]$Size / 1024)) }
    return ([string]$Size + ' B')
}

function Update-Stats {
    if (Get-Command Update-DirectoryChoices -ErrorAction SilentlyContinue) { Update-DirectoryChoices }
    $entries = @(Load-IndexEntries)
    $withText = @($entries | Where-Object { [bool]$_.hasText }).Count
    $lblSubtitle.Text = [string]::Format([string]$script:Cfg.search.subtitle, $entries.Count)
    $lblStatus.Text = [string]::Format([string]$script:Cfg.search.statLine, $entries.Count, $withText) + '  ' + [string]$script:Cfg.search.pdfNote
}

function Restart-SearchWindow {
    if ($script:Restarting) { return }
    if ($script:PendingDpi -le 0) { return }
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
        $scriptPath = $PSCommandPath
        if ([string]::IsNullOrEmpty($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Path }
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $scriptPath, '-RestoreFile', $statePath)
        $script:RestartTimer.Stop()
        $form.Hide()
        $form.Close()
    } catch {
        $script:Restarting = $false
    }
}

$form = New-Object $formType
try {
    $dbFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
    $dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', $dbFlags)
    if ($dbProp -ne $null) { $dbProp.SetValue($form, $true, $null) }
} catch {
}
$form.Text = [string]$script:Cfg.search.title + ' · v' + $script:AppVersion
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size((S 1320), (S 820))
$form.MinimumSize = New-Object System.Drawing.Size((S 1100), (S 650))
$form.BackColor = $script:ColBg
try { $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10) } catch { }
try {
    if (Test-Path -LiteralPath $script:IconPath) { $form.Icon = New-Object System.Drawing.Icon($script:IconPath) }
} catch {
}

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
} catch {
}
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
$list.OwnerDraw = $true
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
} catch {
}
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

$list.Add_DrawColumnHeader({
    param($sender, $e)
    $e.DrawDefault = $false
    $g = $e.Graphics
    $g.FillRectangle($script:BrBg, $e.Bounds)
    $g.DrawLine($script:PenBorder, $e.Bounds.Left, ($e.Bounds.Bottom - 1), $e.Bounds.Right, ($e.Bounds.Bottom - 1))
    $rect = New-Object System.Drawing.Rectangle(($e.Bounds.X + (S 12)), $e.Bounds.Y, ($e.Bounds.Width - (S 16)), $e.Bounds.Height)
    [System.Windows.Forms.TextRenderer]::DrawText($g, $e.Header.Text, $script:FontHeader, $rect, $script:ColText2, $script:Tf)
})

$list.Add_DrawItem({
    param($sender, $e)
    $e.DrawDefault = $false
    if ($e.ItemIndex -lt 0) { return }
    $g = $e.Graphics
    $bounds = $e.Bounds
    $bgBrush = $script:BrBg
    if ($e.Item.Selected) {
        $bgBrush = $script:BrSelected
    } elseif ($e.ItemIndex -eq $script:HoverIndex) {
        $bgBrush = $script:BrHover
    }
    $g.FillRectangle($bgBrush, $bounds)

    $subs = $e.Item.SubItems

    $colRects = New-Object System.Collections.ArrayList
    $cx = $bounds.Left
    for ($ci = 0; $ci -lt $list.Columns.Count; $ci++) {
        [void]$colRects.Add((New-Object System.Drawing.Rectangle($cx, $bounds.Top, $list.Columns[$ci].Width, $bounds.Height)))
        $cx = $cx + $list.Columns[$ci].Width
    }

    $nr = $colRects[0]
    $rect = New-Object System.Drawing.Rectangle(($nr.X + (S 16)), $nr.Y, [Math]::Max((S 10), ($nr.Width - (S 24))), $nr.Height)
    [System.Windows.Forms.TextRenderer]::DrawText($g, $subs[0].Text, $script:FontName, $rect, $script:ColText, $script:Tf)

    for ($i = 1; $i -lt 5; $i++) {
        $r = $colRects[$i]
        $color = $script:ColText2
        if ($i -eq 4) { $color = $script:ColText }
        $rect = New-Object System.Drawing.Rectangle(($r.X + (S 6)), $r.Y, [Math]::Max((S 10), ($r.Width - (S 10))), $r.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $subs[$i].Text, $script:FontNorm, $rect, $color, $script:Tf)
    }

    $g.DrawLine($script:PenSep, ($bounds.Left + (S 16)), ($bounds.Bottom - 1), ($bounds.Right - (S 16)), ($bounds.Bottom - 1))
})

$list.Add_MouseMove({
    param($sender, $e)
    $item = $sender.GetItemAt($e.X, $e.Y)
    $idx = -1
    if ($item -ne $null) { $idx = $item.Index }
    if ($idx -ne $script:HoverIndex) {
        $oldIdx = $script:HoverIndex
        $script:HoverIndex = $idx
        if ($oldIdx -ge 0 -and $oldIdx -lt $sender.Items.Count) {
            $b = $sender.Items[$oldIdx].Bounds
            $sender.Invalidate((New-Object System.Drawing.Rectangle(0, $b.Top, $sender.ClientSize.Width, $b.Height)))
        }
        if ($idx -ge 0 -and $idx -lt $sender.Items.Count) {
            $b = $sender.Items[$idx].Bounds
            $sender.Invalidate((New-Object System.Drawing.Rectangle(0, $b.Top, $sender.ClientSize.Width, $b.Height)))
        }
    }
})
$list.Add_MouseLeave({
    if ($script:HoverIndex -ne -1) {
        $oldIdx = $script:HoverIndex
        $script:HoverIndex = -1
        if ($oldIdx -ge 0 -and $oldIdx -lt $list.Items.Count) {
            $b = $list.Items[$oldIdx].Bounds
            $list.Invalidate((New-Object System.Drawing.Rectangle(0, $b.Top, $list.ClientSize.Width, $b.Height)))
        }
    }
})

$btnSearch.Add_Click({ Invoke-Search })
$btnRebuild.Add_Click({ Invoke-Rebuild })
$btnOpenRoot.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:Root + '"') })

$list.Add_DoubleClick({
    if ($list.SelectedItems.Count -gt 0) {
        $p = [string]$list.SelectedItems[0].Tag
        if (Test-Path -LiteralPath $p) { Start-Process -FilePath $p }
    }
})

$ctx = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = New-Object System.Windows.Forms.ToolStripMenuItem
$miOpen.Text = [string]$script:Cfg.search.menuOpen
$miOpen.Add_Click({
    if ($list.SelectedItems.Count -gt 0) {
        $p = [string]$list.SelectedItems[0].Tag
        if (Test-Path -LiteralPath $p) { Start-Process -FilePath $p }
    }
})
[void]$ctx.Items.Add($miOpen)
$miLocate = New-Object System.Windows.Forms.ToolStripMenuItem
$miLocate.Text = [string]$script:Cfg.search.menuLocate
$miLocate.Add_Click({
    if ($list.SelectedItems.Count -gt 0) {
        $p = [string]$list.SelectedItems[0].Tag
        if (Test-Path -LiteralPath $p) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $p + '"') }
    }
})
[void]$ctx.Items.Add($miLocate)
$miCopy = New-Object System.Windows.Forms.ToolStripMenuItem
$miCopy.Text = [string]$script:Cfg.search.menuCopy
$miCopy.Add_Click({
    if ($list.SelectedItems.Count -gt 0) {
        [System.Windows.Forms.Clipboard]::SetText([string]$list.SelectedItems[0].Tag)
    }
})
[void]$ctx.Items.Add($miCopy)
$list.ContextMenuStrip = $ctx

. (Join-Path $PSScriptRoot 'library-ui.ps1')

$form.AcceptButton = $btnSearch

$form.Add_Shown({
    Update-Stats
    Invoke-Search
})

if ($null -ne $script:InitialCenter) {
    $targetScreen = [System.Windows.Forms.Screen]::FromPoint($script:InitialCenter)
    $wa = $targetScreen.WorkingArea
    $px = $script:InitialCenter.X - [int]($form.Width / 2)
    $py = $script:InitialCenter.Y - [int]($form.Height / 2)
    if ($px -lt $wa.Left) { $px = $wa.Left }
    if ($py -lt $wa.Top) { $py = $wa.Top }
    if (($px + $form.Width) -gt $wa.Right) { $px = $wa.Right - $form.Width }
    if (($py + $form.Height) -gt $wa.Bottom) { $py = $wa.Bottom - $form.Height }
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point($px, $py)
}

$script:RestartTimer = New-Object System.Windows.Forms.Timer
$script:RestartTimer.Interval = 700
$script:RestartTimer.Add_Tick({
    $script:RestartTimer.Stop()
    Restart-SearchWindow
})
$script:Restarting = $false
$script:PendingDpi = 0
$script:PendingCenter = $null
$form.Add_DpiChanged({
    param($s, $e)
    if ($script:Restarting) { return }
    $script:PendingDpi = [int]$e.DeviceDpiNew
    $script:PendingCenter = New-Object System.Drawing.Point(([int]($form.Left + ($form.Width / 2))), ([int]($form.Top + ($form.Height / 2))))
    $script:RestartTimer.Stop()
    $script:RestartTimer.Start()
})

if ($UiTestOutput) {
    . (Join-Path $PSScriptRoot 'tests\ui-responsive.ps1')
    exit
}

if (-not [string]::IsNullOrEmpty($Capture)) {
    $form.ShowInTaskbar = $false
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(20, 20)
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    if (-not [string]::IsNullOrEmpty($CaptureQuery)) {
        $txtQuery.ForeColor = $script:ColText
        $txtQuery.Text = $CaptureQuery
        Invoke-Search

    }
    $captureDeadline=(Get-Date).AddSeconds(25)
    do {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 60
    } while ($script:SearchJob -and (Get-Date) -lt $captureDeadline)
    if ($list.Items.Count -gt 0) { $list.Items[0].Selected=$true; Update-FilePreview }
    $captureDeadline=(Get-Date).AddSeconds(18)
    do {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 60
    } while (($previewDelay.Enabled -or ($script:PreviewJob -and -not $script:PreviewJob.Ready)) -and (Get-Date) -lt $captureDeadline)
    $paintDeadline=(Get-Date).AddSeconds(4)
    while((Get-Date) -lt $paintDeadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 60}
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)
    $captureGraphics=[Drawing.Graphics]::FromImage($bmp)
    try { $captureGraphics.CopyFromScreen($form.Left,$form.Top,0,0,$bmp.Size) } finally { $captureGraphics.Dispose() }
    $bmp.Save($Capture, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $form.Close()
    Write-Output ('captured ' + $Capture)
    exit
}

if ($SelfTestForm) {
    $form.Dispose()
    Write-Output 'search form build: ok'
    exit
}

[void]$form.ShowDialog()
$form.Dispose()
