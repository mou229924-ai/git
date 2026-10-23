param(
    [switch]$SelfTest,
    [switch]$EnsureRunning,
    [switch]$SelfTestForm,
    [string]$Inspect,
    [string]$CaptureDialog = ''
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib.ps1')

try {
    $cDpiCode = @'
using System;
using System.Runtime.InteropServices;
public class SubjectClassDpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
}
'@
    Add-Type -TypeDefinition $cDpiCode
} catch {
}
$classDpiAware = $false
try { $classDpiAware = [SubjectClassDpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }
if (-not $classDpiAware) {
    try { [SubjectClassDpi]::SetProcessDPIAware() | Out-Null } catch { }
}
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
$classDpiGraphics = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:Dpi = $classDpiGraphics.DpiX
$classDpiGraphics.Dispose()
$script:Scale = [Math]::Max(1.0, [double]$script:Dpi / 96.0)
function S {
    param([double]$V)
    return [int][Math]::Round($V * $script:Scale)
}

function Update-UiScale {
    try {
        $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        $script:Scale = [Math]::Max(1.0, [double]$g.DpiX / 96.0)
        $g.Dispose()
    } catch {
    }
}

$script:IgnoreNames = @($script:Cfg.ignoreFiles | ForEach-Object { [string]$_ })
$script:IgnoreExts = @($script:Cfg.ignoreExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
foreach ($rule in $script:Cfg.subjects) { $script:IgnoreNames += [string]$rule.name }
$script:IgnoreNames += [string]$script:Cfg.otherFolderName

function Move-ToSubject {
    param($FileInfo, [string]$Folder, [string]$Reason, [string]$Text, [switch]$TextProvided)
    $name = $Folder
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) {
        $name = $name.Replace([string]$ch, '_')
    }
    $name = $name.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$script:Cfg.otherFolderName }
    $destDir = Join-Path $script:Root $name
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    $target = Join-Path $destDir $FileInfo.Name
    if (Test-Path -LiteralPath $target) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FileInfo.Name)
        $ext = [System.IO.Path]::GetExtension($FileInfo.Name)
        $i = 2
        while (Test-Path -LiteralPath $target) {
            $target = Join-Path $destDir ($baseName + ' (' + [string]$i + ')' + $ext)
            $i = $i + 1
        }
    }
    $oldRel = Get-RelativePath -FilePath $FileInfo.FullName
    if (-not (Test-FileReady $FileInfo.FullName)) { throw '文件仍在使用，稍后重试。' }
    Move-Item -LiteralPath $FileInfo.FullName -Destination $target -ErrorAction Stop
    Write-Log ('MOVED  ' + $FileInfo.Name + '  ->  ' + $name + '  [' + $Reason + ']')
    if ($TextProvided) {
        Update-IndexEntry -FilePath $target -Text $Text -TextProvided -OldRelPath $oldRel
    } else {
        Update-IndexEntry -FilePath $target -OldRelPath $oldRel
    }
    return $target
}

function Save-NewSubject {
    param([string]$Name)
    Refresh-LibraryConfig
    $script:IgnoreNames += $Name
    if (-not $script:Cfg.saveNewSubjects) { return }
    try {
        foreach ($rule in $script:Cfg.subjects) {
            if ([string]$rule.name -eq $Name) { return }
        }
        $newRule = New-Object PSObject -Property @{
            name = $Name
            filenameKeywords = @($Name)
            contentKeywords = @($Name)
        }
        $list = New-Object System.Collections.ArrayList
        foreach ($rule in $script:Cfg.subjects) { [void]$list.Add($rule) }
        [void]$list.Add($newRule)
        $script:Cfg.subjects = @($list.ToArray())
        $json = $script:Cfg | ConvertTo-Json -Depth 12
        Write-AtomicUtf8 -Path $script:ConfigPath -Text $json
        Write-Log ('CONFIG  added subject: ' + $Name)
    } catch {
        Write-Log ('CONFIG  save failed: ' + $_.Exception.Message)
    }
}

function Show-SubjectDialog {
    param(
        [string]$FileName,
        [string]$Prompt,
        [string]$Hint,
        [string]$Snippet,
        [bool]$HasSnippet,
        [string]$CapturePath = '',
        [switch]$BuildOnly
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName Microsoft.VisualBasic
    Update-UiScale

    $form = New-Object System.Windows.Forms.Form
    $form.Text = [string]$script:Cfg.popup.title
    $form.TopMost = $true
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $true
    $form.Width = (S 700)
    $form.Height = (S 445)
    $form.BackColor = [System.Drawing.Color]::FromArgb(255, 249, 231)
    try { $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10) } catch { }
    try {
        $iconFile = Join-Path $script:AppDir 'assets\app.ico'
        if (Test-Path -LiteralPath $iconFile) { $form.Icon = New-Object System.Drawing.Icon($iconFile) }
    } catch {
    }

    $state = @{ Action = 'cancel'; Name = $null; Form = $form }

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'
    $layout.ColumnCount = 1
    $layout.RowCount = 6
    $layout.Padding = New-Object System.Windows.Forms.Padding((S 12))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, (S 130))))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $lblPrompt = New-Object System.Windows.Forms.Label
    $lblPrompt.Text = $Prompt
    $lblPrompt.AutoSize = $true
    $lblPrompt.MaximumSize = New-Object System.Drawing.Size((S 640), 0)
    $lblPrompt.ForeColor = [System.Drawing.Color]::FromArgb(99, 74, 29)
    $lblPrompt.Margin = New-Object System.Windows.Forms.Padding((S 2), (S 2), (S 2), (S 6))
    $layout.Controls.Add($lblPrompt, 0, 0)

    $lblFile = New-Object System.Windows.Forms.Label
    $lblFile.Text = $FileName
    $lblFile.AutoSize = $true
    $lblFile.MaximumSize = New-Object System.Drawing.Size((S 640), 0)
    $lblFile.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $lblFile.Margin = New-Object System.Windows.Forms.Padding((S 2), 0, (S 2), (S 6))
    $layout.Controls.Add($lblFile, 0, 1)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = $Hint
    $lblHint.AutoSize = $true
    $lblHint.MaximumSize = New-Object System.Drawing.Size((S 640), 0)
    $lblHint.ForeColor = [System.Drawing.Color]::FromArgb(217, 48, 37)
    $lblHint.Margin = New-Object System.Windows.Forms.Padding((S 2), 0, (S 2), (S 6))
    $layout.Controls.Add($lblHint, 0, 2)

    $txtSnippet = New-Object System.Windows.Forms.TextBox
    $txtSnippet.Multiline = $true
    $txtSnippet.TabStop = $false
    $txtSnippet.ReadOnly = $true
    $txtSnippet.ScrollBars = 'Vertical'
    $txtSnippet.Dock = 'Fill'
    $txtSnippet.BorderStyle = 'None'
    $txtSnippet.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 212)
    $txtSnippet.ForeColor = [System.Drawing.Color]::FromArgb(99, 74, 29)
    $txtSnippet.Margin = New-Object System.Windows.Forms.Padding((S 2), 0, (S 2), (S 8))
    if ($HasSnippet) {
        $txtSnippet.Text = [string]$script:Cfg.popup.snippetLabel + "`r`n" + $Snippet
    } else {
        $txtSnippet.Text = [string]$script:Cfg.popup.snippetEmpty
    }
    $layout.Controls.Add($txtSnippet, 0, 3)

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'
    $flow.AutoScroll = $true
    $flow.FlowDirection = 'LeftToRight'
    $flow.WrapContents = $true
    $flow.Margin = New-Object System.Windows.Forms.Padding(0)
    $layout.Controls.Add($flow, 0, 4)

    $bottom = New-Object System.Windows.Forms.FlowLayoutPanel
    $bottom.AutoSize = $true
    $bottom.Dock = 'Fill'
    $bottom.FlowDirection = 'RightToLeft'
    $bottom.WrapContents = $false
    $bottom.Margin = New-Object System.Windows.Forms.Padding(0, (S 8), 0, 0)
    $layout.Controls.Add($bottom, 0, 5)

    $form.Controls.Add($layout)

    foreach ($rule in $script:Cfg.subjects) {
        $subjectName = [string]$rule.name
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $subjectName
        $btn.AutoSize = $true
        $btn.MinimumSize = New-Object System.Drawing.Size((S 108), (S 38))
        $btn.Margin = New-Object System.Windows.Forms.Padding((S 4))
        $btn.FlatStyle = 'Flat'
        $btn.FlatAppearance.BorderSize = 0
        $btn.UseVisualStyleBackColor = $false
        $btn.BackColor = [System.Drawing.Color]::FromArgb(255, 240, 194)
        $btn.ForeColor = [System.Drawing.Color]::FromArgb(81, 60, 22)
        $btn.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
        $btnBase = $btn.BackColor
        $btnHover = [System.Drawing.Color]::FromArgb(249, 224, 160)
        $btn.Add_MouseEnter({ param($s, $e) $s.BackColor = $btnHover }.GetNewClosure())
        $btn.Add_MouseLeave({ param($s, $e) $s.BackColor = $btnBase }.GetNewClosure())
        $btn.Add_SizeChanged({ param($s, $e) Set-RoundedRegion -Control $s -Radius (S 18) })
        $btn.Add_Click({
            $state.Action = 'subject'
            $state.Name = $subjectName
            $state.Form.Close()
        }.GetNewClosure())
        $flow.Controls.Add($btn)
    }

    $btnKeep = New-Object System.Windows.Forms.Button
    $btnKeep.Text = [string]$script:Cfg.popup.keep
    $btnKeep.AutoSize = $true
    $btnKeep.MinimumSize = New-Object System.Drawing.Size((S 108), (S 38))
    $btnKeep.Margin = New-Object System.Windows.Forms.Padding((S 4))
    $btnKeep.FlatStyle = 'Flat'
    $btnKeep.FlatAppearance.BorderSize = 0
    $btnKeep.UseVisualStyleBackColor = $false
    $btnKeep.BackColor = [System.Drawing.Color]::FromArgb(255, 249, 231)
    $btnKeep.ForeColor = [System.Drawing.Color]::FromArgb(139, 114, 63)
    $keepBase = $btnKeep.BackColor
    $keepHover = [System.Drawing.Color]::FromArgb(255, 240, 194)
    $btnKeep.Add_MouseEnter({ param($s, $e) $s.BackColor = $keepHover }.GetNewClosure())
    $btnKeep.Add_MouseLeave({ param($s, $e) $s.BackColor = $keepBase }.GetNewClosure())
    $btnKeep.Add_SizeChanged({ param($s, $e) Set-RoundedRegion -Control $s -Radius (S 18) })
    $btnKeep.Add_Click({
        $state.Action = 'keep'
        $state.Form.Close()
    }.GetNewClosure())
    $bottom.Controls.Add($btnKeep)

    $btnOther = New-Object System.Windows.Forms.Button
    $btnOther.Text = [string]$script:Cfg.popup.other
    $btnOther.AutoSize = $true
    $btnOther.MinimumSize = New-Object System.Drawing.Size((S 108), (S 38))
    $btnOther.Margin = New-Object System.Windows.Forms.Padding((S 4))
    $btnOther.FlatStyle = 'Flat'
    $btnOther.FlatAppearance.BorderSize = 0
    $btnOther.UseVisualStyleBackColor = $false
    $btnOther.BackColor = [System.Drawing.Color]::FromArgb(255, 249, 231)
    $btnOther.ForeColor = [System.Drawing.Color]::FromArgb(139, 114, 63)
    $otherBase = $btnOther.BackColor
    $otherHover = [System.Drawing.Color]::FromArgb(255, 240, 194)
    $btnOther.Add_MouseEnter({ param($s, $e) $s.BackColor = $otherHover }.GetNewClosure())
    $btnOther.Add_MouseLeave({ param($s, $e) $s.BackColor = $otherBase }.GetNewClosure())
    $btnOther.Add_SizeChanged({ param($s, $e) Set-RoundedRegion -Control $s -Radius (S 18) })
    $btnOther.Add_Click({
        $state.Action = 'other'
        $state.Form.Close()
    }.GetNewClosure())
    $bottom.Controls.Add($btnOther)

    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Text = [string]$script:Cfg.popup.newSubject
    $btnNew.AutoSize = $true
    $btnNew.MinimumSize = New-Object System.Drawing.Size((S 108), (S 38))
    $btnNew.Margin = New-Object System.Windows.Forms.Padding((S 4))
    $btnNew.FlatStyle = 'Flat'
    $btnNew.FlatAppearance.BorderSize = 0
    $btnNew.UseVisualStyleBackColor = $false
    $btnNew.BackColor = [System.Drawing.Color]::FromArgb(255, 249, 231)
    $btnNew.ForeColor = [System.Drawing.Color]::FromArgb(168, 107, 15)
    $newBase = $btnNew.BackColor
    $newHover = [System.Drawing.Color]::FromArgb(255, 240, 194)
    $btnNew.Add_MouseEnter({ param($s, $e) $s.BackColor = $newHover }.GetNewClosure())
    $btnNew.Add_MouseLeave({ param($s, $e) $s.BackColor = $newBase }.GetNewClosure())
    $btnNew.Add_SizeChanged({ param($s, $e) Set-RoundedRegion -Control $s -Radius (S 18) })
    $newPrompt = [string]$script:Cfg.popup.newSubjectPrompt
    $newTitle = [string]$script:Cfg.popup.title
    $btnNew.Add_Click({
        $typed = Show-NameInput -Prompt $newPrompt -Title $newTitle
        if (-not [string]::IsNullOrWhiteSpace($typed)) {
            $state.Action = 'new'
            $state.Name = $typed
            $state.Form.Close()
        }
    }.GetNewClosure())
    $bottom.Controls.Add($btnNew)

    Set-WarmControls $form
    if (-not [string]::IsNullOrEmpty($CapturePath)) {
        $form.ShowInTaskbar = $false
        $form.StartPosition = 'Manual'
        $form.Location = New-Object System.Drawing.Point(-4000, -4000)
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.Application]::DoEvents()
        $capBmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        $capRect = New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)
        $form.DrawToBitmap($capBmp, $capRect)
        $capBmp.Save($CapturePath, [System.Drawing.Imaging.ImageFormat]::Png)
        $capBmp.Dispose()
        $form.Close()
        $form.Dispose()
        return @{ Action = 'capture'; Name = $null }
    }

    if ($BuildOnly) {
        $form.Dispose()
        return @{ Action = 'build-ok'; Name = $null }
    }

    try {
        $form.Add_Shown({
            $form.Activate()
            $form.ActiveControl = $null
        }.GetNewClosure())
        [System.Media.SystemSounds]::Exclamation.Play()
        [void]$form.ShowDialog()
    } catch {
        Write-Log ('DIALOG  failed: ' + $_.Exception.Message)
    } finally {
        $form.Dispose()
    }
    return @{ Action = $state.Action; Name = $state.Name }
}

$script:ProgressForm = $null
$script:ProgressLabel = $null
$script:ProgressBar = $null

function Show-ProgressForm {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Update-UiScale
    $form = New-Object System.Windows.Forms.Form
    $form.Text = [string]$script:Cfg.tray.title
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedToolWindow'
    $form.StartPosition = 'CenterScreen'
    $form.Width = (S 480)
    $form.Height = (S 150)
    $form.ShowInTaskbar = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(255, 249, 231)
    try { $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10) } catch { }
    try {
        $pIconFile = Join-Path $script:AppDir 'assets\app.ico'
        if (Test-Path -LiteralPath $pIconFile) { $form.Icon = New-Object System.Drawing.Icon($pIconFile) }
    } catch {
    }
    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Dock = 'Bottom'
    $bar.Height = (S 22)
    $bar.Minimum = 0
    $bar.Maximum = 100
    $label = New-Object System.Windows.Forms.Label
    $label.Dock = 'Fill'
    $label.TextAlign = 'MiddleLeft'
    $label.Text = ''
    $form.Controls.Add($label)
    $form.Controls.Add($bar)
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $script:ProgressForm = $form
    $script:ProgressLabel = $label
    $script:ProgressBar = $bar
}

function Update-ProgressForm {
    param([int]$Index, [int]$Total, [string]$Name)
    if ($null -eq $script:ProgressForm) { return }
    try {
        $text = [string]::Format([string]$script:Cfg.folder.progress, $Index, $Total)
        if (-not [string]::IsNullOrEmpty($Name)) {
            if ($Name.Length -gt 42) { $Name = $Name.Substring(0, 42) + '...' }
            $text = $text + "`r`n" + $Name
        }
        $script:ProgressLabel.Text = $text
        $script:ProgressBar.Maximum = [Math]::Max(1, $Total)
        $script:ProgressBar.Value = [Math]::Min($Index, $script:ProgressBar.Maximum)
        [System.Windows.Forms.Application]::DoEvents()
    } catch {
    }
}

function Hide-ProgressForm {
    if ($null -ne $script:ProgressForm) {
        try { $script:ProgressForm.Close() } catch { }
        try { $script:ProgressForm.Dispose() } catch { }
        $script:ProgressForm = $null
        $script:ProgressLabel = $null
        $script:ProgressBar = $null
    }
}

function Get-FolderSignature {
    param([string]$Path)
    try {
        $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
        $sum = 0
        $max = 0
        foreach ($f in $files) {
            $sum = $sum + [long]$f.Length
            $t = $f.LastWriteTimeUtc.Ticks
            if ($t -gt $max) { $max = $t }
        }
        return ([string]$files.Count + '|' + [string]$sum + '|' + [string]$max)
    } catch {
        return 'error'
    }
}

function Get-UniquePath {
    param([string]$Path)
    $isDir = Test-Path -LiteralPath $Path -PathType Container
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $ext = [System.IO.Path]::GetExtension($Path)
    if ($isDir) {
        $name = [System.IO.Path]::GetFileName($Path)
        $ext = ''
    }
    $i = 2
    while (Test-Path -LiteralPath $Path) {
        $Path = Join-Path $parent ($name + ' (' + [string]$i + ')' + $ext)
        $i = $i + 1
    }
    return $Path
}

function Get-ContextSubject {
    param([string]$FilePath, [string]$StopDir)
    try {
        $stop = [System.IO.Path]::GetFullPath($StopDir).TrimEnd('\')
        $cur = [System.IO.Path]::GetFullPath([System.IO.Path]::GetDirectoryName($FilePath)).TrimEnd('\')
        $guard = 0
        while ($guard -lt 30) {
            $guard = $guard + 1
            $inStop = $cur.Equals($stop, [System.StringComparison]::OrdinalIgnoreCase) -or $cur.StartsWith($stop + '\', [System.StringComparison]::OrdinalIgnoreCase)
            if (-not $inStop) { break }
            $dec = Get-FilenameDecision -Text ([System.IO.Path]::GetFileName($cur))
            if ($dec -ne $null -and -not $dec.Ambiguous) { return [string]$dec.Rule.name }
            if ($cur.Equals($stop, [System.StringComparison]::OrdinalIgnoreCase)) { break }
            $parent = [System.IO.Path]::GetDirectoryName($cur)
            if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cur) { break }
            $cur = $parent.TrimEnd('\')
        }
        return $null
    } catch {
        return $null
    }
}

function Index-FilesUnder {
    param([string]$Path)
    $files = @()
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    } elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        $files = @(Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    }
    $i = 0
    foreach ($f in $files) {
        $i = $i + 1
        Update-ProgressForm -Index $i -Total $files.Count -Name $f.Name
        Update-IndexEntry -FilePath $f.FullName
    }
}

function Remove-EmptyDirs {
    param([string]$Dir)
    try {
        foreach ($child in @(Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue)) {
            Remove-EmptyDirs -Dir $child.FullName
        }
        $items = @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)
        if ($items.Count -eq 0) {
            Remove-Item -LiteralPath $Dir -Force -ErrorAction SilentlyContinue
        }
    } catch {
    }
}

function Move-DroppedFolderWhole {
    param($Dir, [string]$Subject)
    $subjectDir = Join-Path $script:Root $Subject
    if (-not (Test-Path -LiteralPath $subjectDir)) {
        New-Item -ItemType Directory -Path $subjectDir -Force | Out-Null
    }
    if ($Dir.Name -eq $Subject) {
        $children = @(Get-ChildItem -LiteralPath $Dir.FullName -Force -ErrorAction SilentlyContinue)
        $i = 0
        foreach ($child in $children) {
            $i = $i + 1
            Update-ProgressForm -Index $i -Total $children.Count -Name $child.Name
            $target = Join-Path $subjectDir $child.Name
            if (Test-Path -LiteralPath $target) { $target = Get-UniquePath -Path $target }
            Move-Item -LiteralPath $child.FullName -Destination $target -ErrorAction Stop
            Index-FilesUnder -Path $target
        }
        Remove-Item -LiteralPath $Dir.FullName -Force -ErrorAction SilentlyContinue
        Write-Log ('FOLDER MERGED  ' + $Dir.Name + '  ->  ' + $Subject)
    } else {
        $target = Join-Path $subjectDir $Dir.Name
        if (Test-Path -LiteralPath $target) { $target = Get-UniquePath -Path $target }
        Move-Item -LiteralPath $Dir.FullName -Destination $target -ErrorAction Stop
        Index-FilesUnder -Path $target
        Write-Log ('FOLDER MOVED  ' + $Dir.Name + '  ->  ' + $Subject)
    }
}

function Process-DroppedFolderFiles {
    param($Dir)
    $files = @(Get-DropFolderFiles $Dir.FullName)
    $total = $files.Count
    $i = 0
    foreach ($f in $files) {
        $i = $i + 1
        Update-ProgressForm -Index $i -Total $total -Name $f.Name

        $sig = [string]$f.Length + '|' + [string]$f.LastWriteTimeUtc.Ticks
        if ($script:Skip.ContainsKey($f.FullName) -and $script:Skip[$f.FullName] -eq $sig) { continue }

        if (Test-IgnoredDocument $f.FullName) { continue }
        if (-not (Test-FileReady $f.FullName)) { continue }
        try {
            $context = Get-ContextSubject -FilePath $f.FullName -StopDir $Dir.FullName
            $classification = Get-DocumentClassification -Path $f.FullName -Context $context
            $text=$classification.Text; $attempted=$true
            $subjectName=$null; $ambiguous=$null; $reason=$classification.How
            if ($classification.Decision) {
                if ($classification.Decision.Ambiguous) { $ambiguous=$classification.Decision }
                else { $subjectName=[string]$classification.Decision.Rule.name }
            }

            if ($subjectName -ne $null) {
                if ($attempted) {
                    [void](Move-ToSubject -FileInfo $f -Folder $subjectName -Reason $reason -Text $text -TextProvided)
                } else {
                    [void](Move-ToSubject -FileInfo $f -Folder $subjectName -Reason $reason)
                }
            } else {
                $prompt = [string]$script:Cfg.popup.unknown
                $hint = ''
                if ($ambiguous -ne $null) {
                    $prompt = [string]$script:Cfg.popup.ambiguous
                    $sep = [string]$script:Cfg.popup.candidatesSeparator
                    $hint = [string]$script:Cfg.popup.candidatesLabel + ($ambiguous.Candidates -join $sep)
                }
                $snippet = ''
                $hasSnippet = $false
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    $snippet = ([regex]::Replace($text, '\s+', ' ')).Trim()
                    if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) }
                    $hasSnippet = $true
                }
                $result = Show-SubjectDialog -FileName $f.Name -Prompt $prompt -Hint $hint -Snippet $snippet -HasSnippet $hasSnippet
                if ($result.Action -eq 'subject' -or $result.Action -eq 'other' -or $result.Action -eq 'new') {
                    $folderName = [string]$result.Name
                    if ($result.Action -eq 'other') { $folderName = [string]$script:Cfg.otherFolderName }
                    if ($result.Action -eq 'new') { Save-NewSubject -Name $folderName }
                    if ($attempted) {
                        [void](Move-ToSubject -FileInfo $f -Folder $folderName -Reason 'manual' -Text $text -TextProvided)
                    } else {
                        [void](Move-ToSubject -FileInfo $f -Folder $folderName -Reason 'manual')
                    }
                } else {
                    $script:Skip[$f.FullName] = $sig
                    Write-Log ('KEPT (folder)  ' + $f.FullName)
                }
            }
        } catch {
            Write-Log ('FOLDER FILE ERROR  ' + $f.FullName + '  ' + $_.Exception.Message)
        }
    }
    Remove-EmptyDirs -Dir $Dir.FullName
    Write-Log ('FOLDER PROCESSED  ' + $Dir.Name + '  files=' + [string]$total)
}

function Process-DroppedFolder {
    param($Dir)
    foreach ($file in @(Get-DropFolderFiles $Dir.FullName)) {
        if ($file.Name -match '^~|(?i)\.tmp(?:\.|$)' -or @($script:Cfg.ignoreExtensions) -contains $file.Extension.ToLowerInvariant()) { throw '文件夹内仍有临时文件，等待保存或复制完成。' }
        if (-not (Test-IgnoredDocument $file.FullName) -and -not (Test-FileReady $file.FullName)) { throw '文件夹内有文件正在使用，稍后重试。' }
    }
    Show-ProgressForm
    try {
        $fdec = Get-FilenameDecision -Text $Dir.Name
        if ($fdec -ne $null -and -not $fdec.Ambiguous) {
            Move-DroppedFolderWhole -Dir $Dir -Subject ([string]$fdec.Rule.name)
        } else {
            Process-DroppedFolderFiles -Dir $Dir
        }
    } finally {
        Hide-ProgressForm
    }
}

function Scan-Once {
    if ($script:Busy) { return }
    $script:Busy = $true
    try {
      Invoke-LibraryLock -Timeout 0 {
        Refresh-LibraryConfig
        try {
            $files = @(Get-ChildItem -LiteralPath $script:Root -File -Force -ErrorAction SilentlyContinue)
        } catch {
            $files = @()
        }
        $present = @{}
        $now = Get-Date

        foreach ($fi in $files) {
            $name = $fi.Name
            if (Test-IgnoredDocument $fi.FullName) { continue }
            if ($script:IgnoreNames -contains $name) { continue }
            $ext = [System.IO.Path]::GetExtension($name).ToLowerInvariant()
            if ($script:IgnoreExts -contains $ext) { continue }

            $present[$fi.FullName] = $true
            $sig = [string]$fi.Length + '|' + [string]$fi.LastWriteTimeUtc.Ticks
            $key = $fi.FullName

            if ($script:Skip.ContainsKey($key) -and $script:Skip[$key] -eq $sig) { continue }

            if ($script:Defer.ContainsKey($key)) {
                if ($now -lt $script:Defer[$key]) { continue }
                $script:Defer.Remove($key)
            }

            if (-not $script:States.ContainsKey($key)) {
                $script:States[$key] = @{ Sig = $sig; Count = 0 }
            }
            $st = $script:States[$key]
            if ($st.Sig -ne $sig) {
                $st.Sig = $sig
                $st.Count = 0
            } else {
                $st.Count = $st.Count + 1
            }
            if ($st.Count -lt [int]$script:Cfg.stablePolls) { continue }
            if (-not (Test-FileReady -Path $fi.FullName)) { continue }

            try {
                $classification = Get-DocumentClassification -Path $fi.FullName
                $text = $classification.Text
                $textAttempted = $true
                $decision = $classification.Decision
                $how = $classification.How

                if ($decision -ne $null -and -not $decision.Ambiguous) {
                    $reason = $how + ': ' + $decision.Detail
                    if ($textAttempted) {
                        [void](Move-ToSubject -FileInfo $fi -Folder ([string]$decision.Rule.name) -Reason $reason -Text $text -TextProvided)
                    } else {
                        [void](Move-ToSubject -FileInfo $fi -Folder ([string]$decision.Rule.name) -Reason $reason)
                    }
                } else {
                    $prompt = [string]$script:Cfg.popup.unknown
                    $hint = ''
                    if ($decision -ne $null -and $decision.Ambiguous) {
                        $prompt = [string]$script:Cfg.popup.ambiguous
                        $sep = [string]$script:Cfg.popup.candidatesSeparator
                        $hint = [string]$script:Cfg.popup.candidatesLabel + ($decision.Candidates -join $sep)
                    }
                    $snippet = ''
                    $hasSnippet = $false
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        $snippet = ([regex]::Replace($text, '\s+', ' ')).Trim()
                        if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) }
                        $hasSnippet = $true
                    }
                    $result = Show-SubjectDialog -FileName $fi.Name -Prompt $prompt -Hint $hint -Snippet $snippet -HasSnippet $hasSnippet
                    if ($result.Action -eq 'keep') {
                        $script:Skip[$key] = $sig
                        Write-Log ('KEPT   ' + $fi.Name)
                    } elseif ($result.Action -eq 'cancel') {
                        $script:Defer[$key] = $now.AddSeconds(180)
                        Write-Log ('DEFER  ' + $fi.Name + '  (no answer, ask again in 180s)')
                    } elseif ($result.Action -eq 'other') {
                        if ($textAttempted) {
                            [void](Move-ToSubject -FileInfo $fi -Folder ([string]$script:Cfg.otherFolderName) -Reason 'manual' -Text $text -TextProvided)
                        } else {
                            [void](Move-ToSubject -FileInfo $fi -Folder ([string]$script:Cfg.otherFolderName) -Reason 'manual')
                        }
                    } elseif ($result.Action -eq 'new') {
                        $newName = [string]$result.Name
                        Save-NewSubject -Name $newName
                        if ($textAttempted) {
                            [void](Move-ToSubject -FileInfo $fi -Folder $newName -Reason 'manual-new' -Text $text -TextProvided)
                        } else {
                            [void](Move-ToSubject -FileInfo $fi -Folder $newName -Reason 'manual-new')
                        }
                    } elseif ($result.Action -eq 'subject') {
                        if ($textAttempted) {
                            [void](Move-ToSubject -FileInfo $fi -Folder ([string]$result.Name) -Reason 'manual' -Text $text -TextProvided)
                        } else {
                            [void](Move-ToSubject -FileInfo $fi -Folder ([string]$result.Name) -Reason 'manual')
                        }
                    }
                }
            } catch {
                Write-Log ('ERROR  ' + $fi.Name + '  ' + $_.Exception.Message)
            }

            if ($script:States.ContainsKey($key)) { $script:States.Remove($key) }
        }

        if ($script:States.Count -gt 0) {
            $removeKeys = @()
            foreach ($k in @($script:States.Keys)) {
                if (-not $present.ContainsKey($k)) { $removeKeys += $k }
            }
            foreach ($k in $removeKeys) { $script:States.Remove($k) }
        }
        if ($script:Defer.Count -gt 0) {
            $removeDefer = @()
            foreach ($k in @($script:Defer.Keys)) {
                if (-not $present.ContainsKey($k)) { $removeDefer += $k }
            }
            foreach ($k in $removeDefer) { $script:Defer.Remove($k) }
        }

        try {
            $dirs = @(Get-ChildItem -LiteralPath $script:Root -Directory -Force -ErrorAction SilentlyContinue)
        } catch {
            $dirs = @()
        }
        foreach ($dir in $dirs) {
            $dn = $dir.Name
            if ($dn.StartsWith('_') -or $dn.StartsWith('.')) { continue }
            if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($script:IgnoreNames -contains $dn) { continue }
            $dsig = Get-FolderSignature -Path $dir.FullName
            if ($script:FolderSkip.ContainsKey($dir.FullName) -and $script:FolderSkip[$dir.FullName] -eq $dsig) { continue }
            if (-not $script:FolderStates.ContainsKey($dir.FullName)) {
                $script:FolderStates[$dir.FullName] = @{ Sig = $dsig; Count = 0 }
            }
            $fst = $script:FolderStates[$dir.FullName]
            if ($fst.Sig -ne $dsig) {
                $fst.Sig = $dsig
                $fst.Count = 0
            } else {
                $fst.Count = $fst.Count + 1
            }
            if ($fst.Count -lt [int]$script:Cfg.stablePolls) { continue }
            try {
                Process-DroppedFolder -Dir $dir
            } catch {
                Write-Log ('FOLDER ERROR  ' + $dn + '  ' + $_.Exception.Message)
                continue
            }
            $script:FolderStates.Remove($dir.FullName)
            if (Test-Path -LiteralPath $dir.FullName) {
                $script:FolderSkip[$dir.FullName] = (Get-FolderSignature -Path $dir.FullName)
            } else {
                $script:FolderSkip.Remove($dir.FullName)
            }
        }
        if ($script:FolderStates.Count -gt 0) {
            $removeFolders = @()
            foreach ($k in @($script:FolderStates.Keys)) {
                if (-not (Test-Path -LiteralPath $k)) { $removeFolders += $k }
            }
            foreach ($k in $removeFolders) { $script:FolderStates.Remove($k) }
        }
        if ($script:FolderSkip.Count -gt 0) {
            $removeSkips = @()
            foreach ($k in @($script:FolderSkip.Keys)) {
                if (-not (Test-Path -LiteralPath $k)) { $removeSkips += $k }
            }
            foreach ($k in $removeSkips) { $script:FolderSkip.Remove($k) }
        }
      }
    } finally {
        $script:Busy = $false
    }
}

function Start-TrayApp {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    [System.Windows.Forms.Application]::add_ThreadException({
        param($sender, $e)
        Write-Log ('UI ERROR  ' + $e.Exception.Message)
    })
    [AppDomain]::CurrentDomain.add_UnhandledException({
        param($sender, $e)
        Write-Log ('FATAL  ' + [string]$e.ExceptionObject)
    })

    $script:Context = New-Object System.Windows.Forms.ApplicationContext
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $trayIconFile = Join-Path $script:AppDir 'assets\app.ico'
    try {
        if (Test-Path -LiteralPath $trayIconFile) {
            $script:TrayIcon = New-Object System.Drawing.Icon($trayIconFile)
            $notify.Icon = $script:TrayIcon
        } else {
            $notify.Icon = [System.Drawing.SystemIcons]::Application
        }
    } catch {
        $notify.Icon = [System.Drawing.SystemIcons]::Application
    }
    $notify.Text = [string]$script:Cfg.tray.text
    $notify.Visible = $true

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [int]$script:Cfg.pollSeconds * 1000
    $timer.Add_Tick({
        try {
            if (-not $script:Ui.Paused) { Scan-Once }
        } catch {
            Write-Log ('TICK ERROR  ' + $_.Exception.Message)
        }
    })

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $title = [string]$script:Cfg.tray.title
    $rootPath = $script:Root
    $logPath = $script:LogPath
    $searchVbs = Join-Path $script:AppDir 'search.vbs'
    $pauseText = [string]$script:Cfg.tray.menuPause
    $resumeText = [string]$script:Cfg.tray.menuResume
    $runningTip = [string]$script:Cfg.tray.text
    $pausedTip = [string]$script:Cfg.tray.textPaused

    $itemOpen = New-Object System.Windows.Forms.ToolStripMenuItem
    $itemOpen.Text = [string]$script:Cfg.tray.menuOpen
    $itemOpen.Add_Click({
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $rootPath + '"')
    }.GetNewClosure())
    [void]$menu.Items.Add($itemOpen)

    $itemSearch = New-Object System.Windows.Forms.ToolStripMenuItem
    $itemSearch.Text = [string]$script:Cfg.tray.menuSearch
    $itemSearch.Add_Click({
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $searchVbs + '"')
    }.GetNewClosure())
    [void]$menu.Items.Add($itemSearch)

    $itemLog = New-Object System.Windows.Forms.ToolStripMenuItem
    $itemLog.Text = [string]$script:Cfg.tray.menuLog
    $itemLog.Add_Click({
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $logPath + '"')
    }.GetNewClosure())
    [void]$menu.Items.Add($itemLog)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $itemPause = New-Object System.Windows.Forms.ToolStripMenuItem
    $itemPause.Text = $pauseText
    $ui = $script:Ui
    $notifyLocal = $notify
    $pauseItem = $itemPause
    $itemPause.Add_Click({
        $ui.Paused = -not $ui.Paused
        if ($ui.Paused) {
            $pauseItem.Text = $resumeText
            $notifyLocal.Text = $pausedTip
        } else {
            $pauseItem.Text = $pauseText
            $notifyLocal.Text = $runningTip
        }
    }.GetNewClosure())
    [void]$menu.Items.Add($itemPause)

    $itemExit = New-Object System.Windows.Forms.ToolStripMenuItem
    $itemExit.Text = [string]$script:Cfg.tray.menuExit
    $timerLocal = $timer
    $contextLocal = $script:Context
    $itemExit.Add_Click({
        if ($script:Busy) { return }
        $timerLocal.Stop()
        $notifyLocal.Visible = $false
        $notifyLocal.Dispose()
        $contextLocal.ExitThread()
    }.GetNewClosure())
    [void]$menu.Items.Add($itemExit)

    $notify.ContextMenuStrip = $menu
    $notify.Add_DoubleClick({
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $searchVbs + '"')
    }.GetNewClosure())

    $timer.Start()
    $notify.ShowBalloonTip(5000, $title, [string]$script:Cfg.tray.started, [System.Windows.Forms.ToolTipIcon]::Info)
    [System.Windows.Forms.Application]::Run($script:Context)
}

function Invoke-Inspect {
    param([string]$Target)
    $paths = @()
    if (Test-Path -LiteralPath $Target -PathType Container) {
        $paths = @(Get-ChildItem -LiteralPath $Target -Recurse -File -Force -ErrorAction SilentlyContinue)
    } else {
        $paths = @(Get-Item -LiteralPath $Target)
    }
    $sb = New-Object System.Text.StringBuilder
    $auto = 0
    $ask = 0
    foreach ($f in $paths) {
        $line = ''
        $fdec = Get-FilenameDecision -Text $f.BaseName
        if ($fdec -ne $null -and -not $fdec.Ambiguous) {
            $line = 'AUTO   ' + [string]$fdec.Rule.name + '   [filename]   ' + $f.FullName
            $auto = $auto + 1
        } elseif ($fdec -ne $null -and $fdec.Ambiguous) {
            $line = 'ASK    ambiguous-filename [' + ($fdec.Candidates -join '/') + ']   ' + $f.FullName
            $ask = $ask + 1
        } else {
            $text = Get-FileText -Path $f.FullName
            if ([string]::IsNullOrWhiteSpace($text)) {
                $line = 'ASK    no-text   ' + $f.FullName
                $ask = $ask + 1
            } else {
                $cdec = Get-ContentDecision -Text $text
                if ($cdec -eq $null) {
                    $line = 'ASK    no-keyword   ' + $f.FullName
                    $ask = $ask + 1
                } elseif ($cdec.Ambiguous) {
                    $line = 'ASK    ambiguous-content [' + ($cdec.Candidates -join '/') + ']   ' + $f.FullName
                    $ask = $ask + 1
                } else {
                    $line = 'AUTO   ' + [string]$cdec.Rule.name + '   [content score=' + [string]$cdec.Score + ' runner=' + [string]$cdec.Runner + ']   ' + $f.FullName
                    $auto = $auto + 1
                }
            }
        }
        [void]$sb.AppendLine($line)
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('TOTAL auto=' + [string]$auto + ' ask=' + [string]$ask)
    $reportPath = Join-Path $script:AppDir ([string]$script:Cfg.inspectReportFile)
    [System.IO.File]::WriteAllText($reportPath, $sb.ToString(), $script:Utf8)
    Write-Output ('inspect written to ' + $reportPath + ' auto=' + [string]$auto + ' ask=' + [string]$ask)
}

function Add-Result {
    param([string]$Label, [bool]$Ok, [string]$Detail)
    if ($Ok) {
        $script:Pass = $script:Pass + 1
        [void]$script:Out.AppendLine('PASS  ' + $Label)
    } else {
        $script:Fail = $script:Fail + 1
        [void]$script:Out.AppendLine('FAIL  ' + $Label + '  ' + $Detail)
    }
}

function Run-SelfTest {
    $script:Out = New-Object System.Text.StringBuilder
    $script:Pass = 0
    $script:Fail = 0

    foreach ($rule in $script:Cfg.subjects) {
        $subjectName = [string]$rule.name
        $kws = @($rule.filenameKeywords)
        $probe = 'zz_' + [string]$kws[0] + '_zz'
        $found = Get-FilenameDecision -Text $probe
        $got = 'null'
        if ($found -ne $null -and -not $found.Ambiguous) { $got = [string]$found.Rule.name }
        Add-Result -Label ('filename -> ' + $subjectName + '  [' + $probe + ']') -Ok ($got -eq $subjectName) -Detail ('expected=' + $subjectName + ' got=' + $got)
    }

    foreach ($rule in $script:Cfg.subjects) {
        $subjectName = [string]$rule.name
        foreach ($kw in @($rule.filenameKeywords)) {
            $k = [string]$kw
            if ($k.Length -ne 1) { continue }
            $probe1 = 'a' + $k + 'b'
            $found1 = Get-FilenameDecision -Text $probe1
            $got1 = 'null'
            if ($found1 -ne $null -and -not $found1.Ambiguous) { $got1 = [string]$found1.Rule.name }
            Add-Result -Label ('single char isolated -> ' + $subjectName + '  [' + $probe1 + ']') -Ok ($got1 -eq $subjectName) -Detail ('expected=' + $subjectName + ' got=' + $got1)

            $probe2 = ([string][char]0x4E00) + $k + ([string][char]0x4E8C)
            $found2 = Get-FilenameDecision -Text $probe2
            Add-Result -Label ('single char inside cjk -> none  [' + $probe2 + ']') -Ok ($found2 -eq $null) -Detail 'expected=none'
        }
    }

    $n1 = [string]$script:Cfg.subjects[0].name
    $n2 = [string]$script:Cfg.subjects[1].name
    $amb = Get-FilenameDecision -Text ('zz_' + $n1 + $n2 + '_zz')
    Add-Result -Label 'ambiguous filename (two subjects)' -Ok ($amb -ne $null -and $amb.Ambiguous) -Detail 'expected=ambiguous'

    Add-Result -Label 'unmatched filename -> none' -Ok ((Get-FilenameDecision -Text 'zz_image_0001') -eq $null) -Detail 'expected=none'

    $textA = ((1..5 | ForEach-Object { $n1 }) -join ' ') + ' ' + $n2
    $cdecA = Get-ContentDecision -Text $textA
    $gotA = 'null'
    if ($cdecA -ne $null -and -not $cdecA.Ambiguous) { $gotA = [string]$cdecA.Rule.name }
    Add-Result -Label 'content count decides (5x A vs 1x B)' -Ok ($gotA -eq $n1) -Detail ('expected=' + $n1 + ' got=' + $gotA)

    $textTie = ((1..3 | ForEach-Object { $n1 }) -join ' ') + ' ' + ((1..3 | ForEach-Object { $n2 }) -join ' ')
    $cdecTie = Get-ContentDecision -Text $textTie
    Add-Result -Label 'content tie -> ambiguous' -Ok ($cdecTie -ne $null -and $cdecTie.Ambiguous) -Detail 'expected=ambiguous'

    Add-Result -Label 'content no keyword -> none' -Ok ((Get-ContentDecision -Text 'zzzz nothing here') -eq $null) -Detail 'expected=none'

    if ($script:Cfg.subjects.Count -ge 10) {
        $chemName = [string]$script:Cfg.subjects[4].name
        $physName = [string]$script:Cfg.subjects[3].name
        $itKw = [string](@($script:Cfg.subjects[9].contentKeywords)[0])
        $probe = (($chemName + ' ') * 5) + ($physName + ' ') + $itKw
        $cdec = Get-ContentDecision -Text $probe
        $got = 'null'
        if ($cdec -ne $null -and -not $cdec.Ambiguous) { $got = [string]$cdec.Rule.name }
        Add-Result -Label ('chemistry doc with physics/it words -> ' + $chemName) -Ok ($got -eq $chemName) -Detail ('expected=' + $chemName + ' got=' + $got)
    }

    $tmpTxt = Join-Path $env:TEMP 'subject-classifier-selftest.txt'
    [System.IO.File]::WriteAllText($tmpTxt, (($n1 + ' ') * 6), $script:Utf8)
    $txt = Get-FileText -Path $tmpTxt
    $cdecTxt = Get-ContentDecision -Text $txt
    $gotTxt = 'null'
    if ($cdecTxt -ne $null -and -not $cdecTxt.Ambiguous) { $gotTxt = [string]$cdecTxt.Rule.name }
    Add-Result -Label ('txt content -> ' + $n1) -Ok ($gotTxt -eq $n1) -Detail ('expected=' + $n1 + ' got=' + $gotTxt)

    $tmpDocx = Join-Path $env:TEMP 'subject-classifier-selftest.docx'
    if (Test-Path -LiteralPath $tmpDocx) { Remove-Item -LiteralPath $tmpDocx -Force }
    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        $fs = [System.IO.File]::Open($tmpDocx, [System.IO.FileMode]::Create)
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        $entry = $zip.CreateEntry('word/document.xml')
        $writer = New-Object System.IO.StreamWriter($entry.Open(), $script:Utf8)
        $writer.Write('<w:document><w:body><w:p><w:r><w:t>' + ($n1 + ' ') * 6 + '</w:t></w:r></w:p></w:body></w:document>')
        $writer.Close()
        $zip.Dispose()
        $fs.Close()
        $docxText = Get-FileText -Path $tmpDocx
        $cdecDocx = Get-ContentDecision -Text $docxText
        $gotDocx = 'null'
        if ($cdecDocx -ne $null -and -not $cdecDocx.Ambiguous) { $gotDocx = [string]$cdecDocx.Rule.name }
        Add-Result -Label ('docx content -> ' + $n1) -Ok ($gotDocx -eq $n1) -Detail ('expected=' + $n1 + ' got=' + $gotDocx)
    } catch {
        Add-Result -Label 'docx content extraction' -Ok $false -Detail $_.Exception.Message
    } finally {
        if (Test-Path -LiteralPath $tmpDocx) { Remove-Item -LiteralPath $tmpDocx -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tmpTxt) { Remove-Item -LiteralPath $tmpTxt -Force -ErrorAction SilentlyContinue }
    }

    [void]$script:Out.AppendLine('')
    [void]$script:Out.AppendLine('TOTAL pass=' + [string]$script:Pass + ' fail=' + [string]$script:Fail)
    $outPath = Join-Path $script:AppDir '_selftest.txt'
    [System.IO.File]::WriteAllText($outPath, $script:Out.ToString(), $script:Utf8)
    Write-Output ('selftest written to ' + $outPath + ' pass=' + [string]$script:Pass + ' fail=' + [string]$script:Fail)
}

if (-not [string]::IsNullOrEmpty($CaptureDialog)) {
    $capPrompt = [string]$script:Cfg.popup.ambiguous
    $capSep = [string]$script:Cfg.popup.candidatesSeparator
    $capHint = [string]$script:Cfg.popup.candidatesLabel + 'A' + $capSep + 'B'
    Show-SubjectDialog -FileName 'example-file.docx' -Prompt $capPrompt -Hint $capHint -Snippet 'preview text for layout check' -HasSnippet $true -CapturePath $CaptureDialog | Out-Null
    exit
}

if ($SelfTestForm) {
    try {
        $result = Show-SubjectDialog -FileName 'example.pdf' -Prompt ([string]$script:Cfg.popup.unknown) -Hint ([string]$script:Cfg.popup.candidatesLabel + 'test') -Snippet '' -HasSnippet $false -BuildOnly
        Write-Output ('form build: ' + $result.Action)
    } catch {
        Write-Output ('form build failed: ' + $_.Exception.Message)
    }
    exit
}

if ($SelfTest) {
    Run-SelfTest
    exit
}

if (-not [string]::IsNullOrWhiteSpace($Inspect)) {
    Invoke-Inspect -Target $Inspect
    exit
}

$script:Mutex = $null
$createdNew = $false
try {
    $script:Mutex = New-Object System.Threading.Mutex($true, ('Local\SubjectAutoClassifier_' + (Get-IndexId ([IO.Path]::GetFullPath($script:Root)))), [ref]$createdNew)
    if (-not $createdNew) {
        if ($EnsureRunning) { exit }
        Add-Type -AssemblyName System.Windows.Forms
        [System.Media.SystemSounds]::Exclamation.Play()
        [void][System.Windows.Forms.MessageBox]::Show([string]$script:Cfg.tray.alreadyRunning, [string]$script:Cfg.tray.title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        exit
    }
} catch {
}

if (-not (Test-Path -LiteralPath $script:Root)) {
    New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
}

$script:States = @{}
$script:Skip = @{}
$script:Defer = @{}
$script:FolderStates = @{}
$script:FolderSkip = @{}
$script:Busy = $false
$script:Ui = @{ Paused = $false }

if (-not $script:Cfg.processExistingOnStartup) {
    foreach ($fi in @(Get-ChildItem -LiteralPath $script:Root -File -Force -ErrorAction SilentlyContinue)) {
        $sig = [string]$fi.Length + '|' + [string]$fi.LastWriteTimeUtc.Ticks
        $script:Skip[$fi.FullName] = $sig
    }
}

Write-Log 'watcher started (tray, folders, index)'
Start-TrayApp
