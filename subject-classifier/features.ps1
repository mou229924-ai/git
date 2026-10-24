function Assert-LibraryFile {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Get-RelativePath $full)) { throw '文件不在资料库内。' }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '请选择普通文件。' }
    $cursor = $item.Directory
    $rootFull = [IO.Path]::GetFullPath($script:Root).TrimEnd('\')
    while ($cursor) {
        if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '不支持目录链接。' }
        if ($cursor.FullName -eq $rootFull) { break }
        if ($cursor.Name.StartsWith('_') -or $cursor.Name.StartsWith('.')) { throw '禁止操作程序内部目录。' }
        $cursor = $cursor.Parent
    }
    if (-not $cursor -or (Test-IgnoredDocument $full)) { throw '文件路径无效或属于临时文件。' }
    return $full
}

function Test-LibraryName {
    param([string]$Name)
    return (-not [string]::IsNullOrWhiteSpace($Name) -and $Name -eq $Name.Trim() -and
        $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0 -and
        $Name -notmatch '^(\.|_|~)|[. ]$|(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)')
}

function Rename-LibraryFile {
    param([string]$Path,[string]$NewName)
    $oldRel=Get-RelativePath $Path
    $renamed=Invoke-LibraryLock {
        $source = Assert-LibraryFile $Path
        if (-not (Test-LibraryName $NewName)) { throw '文件名包含无效字符或保留名称。' }
        if (Test-IgnoredDocument $NewName) { throw '不能重命名为临时文件。' }
        $target = Join-Path ([IO.Path]::GetDirectoryName($source)) $NewName
        if ($source -ceq $target) { return $target }
        if (Test-Path -LiteralPath $target) { throw '同名文件已存在，不会覆盖。' }
        if (-not (Test-FileReady $source)) { throw '文件正在使用，请关闭后重试。' }
        [IO.File]::Move($source,$target)
        Write-Log ('RENAMED  ' + $source + ' -> ' + $target)
        return $target
    }
    $null=Update-IndexEntry -FilePath $renamed -OldRelPath $oldRel
    return $renamed
}

function Save-LibraryDirectory {
    param([string]$Name,[string[]]$FilenameKeywords,[string[]]$ContentKeywords)
    Invoke-LibraryLock {
        if (-not (Test-LibraryName $Name)) { throw '目录名包含无效字符或保留名称。' }
        $config = [IO.File]::ReadAllText($script:ConfigPath,$script:Utf8) | ConvertFrom-Json
        if ([IO.Path]::GetFullPath([string]$config.inbox) -ne [IO.Path]::GetFullPath($script:Root)) { throw '资料库配置不一致，请重新打开程序。' }
        $target = Join-Path $script:Root $Name
        if ((Test-Path -LiteralPath $target) -and (Get-Item -LiteralPath $target).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '不能使用目录链接。' }
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $nameWords = @(@($Name) + @($FilenameKeywords) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $contentWords = @($ContentKeywords | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $rules = @($config.subjects | Where-Object { [string]$_.name -ne $Name })
        $rules += [pscustomobject]@{ name=$Name; filenameKeywords=$nameWords; contentKeywords=$contentWords }
        $config.subjects = $rules
        Write-AtomicUtf8 $script:ConfigPath ($config | ConvertTo-Json -Depth 12)
        $script:Cfg = $config
        return $target
    }
}

function Get-DirectoryChoices {
    param([string]$Directory=$script:Root,[string]$Prefix='')
    foreach ($item in @(Get-ChildItem -LiteralPath $Directory -Directory -Force -ErrorAction Stop | Sort-Object Name)) {
        if ($item.Name -match '^[._]' -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $item.FullName -eq [IO.Path]::GetFullPath($script:AppDir).TrimEnd('\')) { continue }
        $relative = $item.Name
        if ($Prefix) { $relative = $Prefix + '\' + $item.Name }
        $relative
        Get-DirectoryChoices -Directory $item.FullName -Prefix $relative
    }
}

function Refresh-LibraryConfig {
    if (-not [IO.File]::Exists($script:ConfigPath)) { return }
    $config = [IO.File]::ReadAllText($script:ConfigPath,$script:Utf8) | ConvertFrom-Json
    if ([IO.Path]::GetFullPath([string]$config.inbox) -ne [IO.Path]::GetFullPath($script:Root)) { return }
    $script:Cfg=$config
    $script:IgnoreNames=@($config.ignoreFiles) + @($config.subjects | ForEach-Object { [string]$_.name }) + @([string]$config.otherFolderName)
}

function Get-PrintFileCapability {
    param([string]$Path)
    $full = Assert-LibraryFile $Path
    $extension = [IO.Path]::GetExtension($full).ToLowerInvariant()
    if (@('.pdf','.doc','.docx','.rtf','.odt','.ppt','.pptx','.xls','.xlsx','.txt','.png','.jpg','.jpeg','.bmp') -notcontains $extension) {
        return [pscustomobject]@{ Path=$full; Supported=$false; Error='此格式不支持快捷打印。' }
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $full
    $supported = @($info.Verbs) -contains 'print'
    $errorMessage = ''
    if (-not $supported) { $errorMessage='未找到系统打印入口，请先安装或设置支持此格式打印的应用。' }
    return [pscustomobject]@{ Path=$full; Supported=$supported; Error=$errorMessage }
}

function Start-DocumentPrint {
    param([string]$Path)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Path; $info.Verb='print'; $info.UseShellExecute=$true
    $info.WindowStyle='Hidden'
    $process = [Diagnostics.Process]::Start($info)
    if ($process) { $process.Dispose() }
}

function Invoke-BatchPrint {
    param([string[]]$Paths,[switch]$Execute)
    $seen = @{}
    foreach ($path in $Paths) {
        try {
            $full = Assert-LibraryFile $path
            if ($seen.ContainsKey($full)) { continue }
            $seen[$full]=$true
            $capability = Get-PrintFileCapability $full
            if (-not $Execute) { $capability; continue }
            if (-not $capability.Supported) { throw $capability.Error }
            if (-not (Test-FileReady $full)) { throw '文件正在使用，请关闭后重试。' }
            Start-DocumentPrint $full
            [pscustomobject]@{ Path=$full; Status='submitted'; Error='' }
        } catch { [pscustomobject]@{ Path=$path; Status='skipped'; Supported=$false; Error=$_.Exception.Message } }
    }
}

function Export-LibraryFiles {
    param([string[]]$Paths,[string]$Destination)
    $outcomes=@(Invoke-LibraryLock {
        if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { throw '目标文件夹不存在。' }
        if (Get-RelativePath (Join-Path $Destination 'probe.txt')) { throw '此入口仅用于移出资料库。' }
        foreach ($path in $Paths) {
            try {
                $source = Assert-LibraryFile $path
                if (-not (Test-FileReady $source)) { throw '文件正在使用。' }
                $target = Join-Path $Destination ([IO.Path]::GetFileName($source))
                $number=2
                while (Test-Path -LiteralPath $target) {
                    $target=Join-Path $Destination ([IO.Path]::GetFileNameWithoutExtension($source)+' ('+$number+')'+[IO.Path]::GetExtension($source)); $number++
                }
                Move-Item -LiteralPath $source -Destination $target -ErrorAction Stop
                Write-Log ('EXPORTED  '+$source+' -> '+$target)
                [pscustomobject]@{ Source=$source; Target=$target; Success=$true; Error='' }
            } catch { [pscustomobject]@{ Source=$path; Target=''; Success=$false; Error=$_.Exception.Message } }
        }
    })
    foreach($outcome in $outcomes){if($outcome.Success){$null=Update-IndexEntry -FilePath $outcome.Source}}
    return $outcomes
}

function Set-WarmControls {
    param($Control)
    if ($Control -is [Windows.Forms.TextBox] -or $Control -is [Windows.Forms.ComboBox] -or $Control -is [Windows.Forms.ListView]) {
        $Control.BackColor=[Drawing.Color]::FromArgb(255,249,231)
        $Control.ForeColor=[Drawing.Color]::FromArgb(81,60,22)
    } elseif ($Control -is [Windows.Forms.Button] -and $Control.UseVisualStyleBackColor) {
        $Control.UseVisualStyleBackColor=$false
        $Control.BackColor=[Drawing.Color]::FromArgb(255,232,157)
        $Control.ForeColor=[Drawing.Color]::FromArgb(81,60,22)
    }
    foreach ($child in $Control.Controls) { Set-WarmControls $child }
}

function Show-LibraryDialog {
    param($Dialog,$Owner=$null,$InitialFocus=$null)
    Add-Type -AssemblyName System.Windows.Forms
    if (-not $Owner) { $Owner=[Windows.Forms.Form]::ActiveForm }
    if ($Owner -and ($Owner.IsDisposed -or $Owner -eq $Dialog)) { $Owner=$null }
    if ($Owner) {
        $Dialog.Owner=$Owner
        $Dialog.StartPosition='CenterParent'
        $Dialog.ShowInTaskbar=$false
        # Owned inputs must share the classifier's topmost band to remain reachable.
        $Dialog.TopMost=$Owner.TopMost
    }
    $focusDialog=[Action]{
        if ($Dialog.IsDisposed -or -not $Dialog.Visible) { return }
        $Dialog.BringToFront()
        $Dialog.Activate()
        if ($InitialFocus -and $InitialFocus.CanFocus) {
            $Dialog.ActiveControl=$InitialFocus
            $InitialFocus.Select()
            [void]$InitialFocus.Focus()
        }
    }.GetNewClosure()
    $shown=[EventHandler]{ param($sender,$eventArgs) [void]$sender.BeginInvoke($focusDialog) }.GetNewClosure()
    $Dialog.Add_Shown($shown)
    try {
        if ($Owner) { return $Dialog.ShowDialog($Owner) }
        return $Dialog.ShowDialog()
    } finally { $Dialog.Remove_Shown($shown) }
}

function Show-NameInput {
    param([string]$Prompt,[string]$Title,[string]$Default='',$Owner=$null)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text=$Title; $dialog.StartPosition='CenterScreen'; $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false; $dialog.ClientSize=New-Object Drawing.Size((S 560),(S 190))
    $dialog.BackColor=[Drawing.Color]::FromArgb(255,248,226)
    $dialog.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
    $label=New-Object Windows.Forms.Label
    $label.Location=New-Object Drawing.Point((S 20),(S 20)); $label.Size=New-Object Drawing.Size((S 520),(S 44)); $label.Text=$Prompt
    $box=New-Object Windows.Forms.TextBox
    $box.Location=New-Object Drawing.Point((S 20),(S 72)); $box.Width=(S 520); $box.Text=$Default
    $ok=New-Object Windows.Forms.Button
    $ok.Text='确定'; $ok.DialogResult='OK'; $ok.Location=New-Object Drawing.Point((S 340),(S 125)); $ok.Size=New-Object Drawing.Size((S 95),(S 38))
    $cancel=New-Object Windows.Forms.Button
    $cancel.Text='取消'; $cancel.DialogResult='Cancel'; $cancel.Location=New-Object Drawing.Point((S 445),(S 125)); $cancel.Size=$ok.Size
    $dialog.Controls.AddRange(@($label,$box,$ok,$cancel)); $dialog.AcceptButton=$ok; $dialog.CancelButton=$cancel
    Set-WarmControls $dialog
    try { if ((Show-LibraryDialog -Dialog $dialog -Owner $Owner -InitialFocus $box) -eq 'OK') { return $box.Text }; return '' } finally { $dialog.Dispose() }
}
