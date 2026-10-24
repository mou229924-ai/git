# Classification dialog and progress UI. Loaded by classifier.ps1 after lib.ps1.
function Initialize-ClassifierUi {
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
}

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
    $form.Height = (S 535)
    $form.BackColor = [System.Drawing.Color]::FromArgb(255, 249, 231)
    try { $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10) } catch { }
    try {
        $iconFile = Join-Path $script:AppDir 'assets\app.ico'
        if (Test-Path -LiteralPath $iconFile) { $form.Icon = New-Object System.Drawing.Icon($iconFile) }
    } catch {
    }

    $state = @{ Action = 'cancel'; Name = $null; Remember = $false; Keyword = ''; Form = $form }

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'
    $layout.ColumnCount = 1
    $layout.RowCount = 7
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
    $layout.Controls.Add($bottom, 0, 6)

    # Rule learning is opt-in for each file. Editable suggestions never change configuration by themselves.
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $learning = New-Object System.Windows.Forms.FlowLayoutPanel
    $learning.AutoSize=$true; $learning.Dock='Fill'; $learning.FlowDirection='TopDown'; $learning.WrapContents=$false
    $learning.Margin=New-Object System.Windows.Forms.Padding((S 2), (S 4), (S 2), 0)
    $remember = New-Object System.Windows.Forms.CheckBox
    $remember.Name='RememberClassificationKeyword'; $remember.AutoSize=$true; $remember.Checked=$false
    $remember.Text='记住文件名关键词（仅对本次选择的已有目录生效）'
    $learning.Controls.Add($remember)
    $keyword = New-Object System.Windows.Forms.ComboBox
    $keyword.Name='ClassificationKeyword'; $keyword.DropDownStyle='DropDown'; $keyword.Width=(S 630)
    $keyword.MaxLength=60; $keyword.Enabled=$false
    $stem=[IO.Path]::GetFileNameWithoutExtension($FileName)
    if ($stem.Length -ge 2 -and $stem.Length -le 60) { [void]$keyword.Items.Add($stem); $keyword.Text=$stem }
    foreach ($part in @($stem -split '[_\s()（）\[\]-]+' | Where-Object { $_.Length -ge 2 -and $_.Length -le 60 } | Select-Object -Unique)) {
        if (-not $keyword.Items.Contains($part)) { [void]$keyword.Items.Add($part) }
    }
    $learning.Controls.Add($keyword)
    $learningHint = New-Object System.Windows.Forms.Label
    $learningHint.AutoSize=$true; $learningHint.MaximumSize=New-Object Drawing.Size((S 630),0)
    $learningHint.Text='只记住你确认的文件名短语；未勾选不会修改规则。'
    $learningHint.ForeColor=[Drawing.Color]::FromArgb(139,114,63)
    $learning.Controls.Add($learningHint)
    $remember.Add_CheckedChanged({
        $keyword.Enabled=$remember.Checked
        $learningHint.Text='只记住你确认的文件名短语；未勾选不会修改规则。'
        if ($remember.Checked) { [void]$keyword.Focus() }
    }.GetNewClosure())
    $layout.Controls.Add($learning,0,5)

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
            if ($remember.Checked) {
                $validation=Test-ManualClassificationKeyword -Name $subjectName -Keyword $keyword.Text -FileName $FileName
                if (-not $validation.Valid) {
                    $learningHint.Text=$validation.Error
                    $learningHint.ForeColor=[Drawing.Color]::FromArgb(190,66,44)
                    [void]$keyword.Focus()
                    return
                }
                $state.Remember=$true
                $state.Keyword=$validation.Keyword
            }
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
        $typed = Show-NameInput -Prompt $newPrompt -Title $newTitle -Owner $state.Form
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
    return @{ Action = $state.Action; Name = $state.Name; Remember = $state.Remember; Keyword = $state.Keyword }
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
