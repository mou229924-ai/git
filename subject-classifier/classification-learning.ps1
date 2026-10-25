# Explicit, conservative filename rule learning after a successful manual move.
# Loading this module does not read or change configuration.
function Test-ManualClassificationKeyword {
    param([string]$Name, [string]$Keyword, [string]$FileName, $Config = $script:Cfg)
    $word = $Keyword.Trim()
    $failure = ''
    if (-not (Test-LibraryName $Name) -or $Name -eq [string]$Config.otherFolderName) { $failure = '请选择一个已有的分类目录。' }
    elseif ($word.Length -lt 2 -or $word.Length -gt 60 -or $word -match '[\x00-\x1f\\/:*?"<>|]' -or $word -notmatch '[\p{L}]') { $failure = '关键词需为 2 至 60 个字符，包含文字，且不含路径或特殊符号。' }
    elseif ($word -match '^(?i:扫描|扫描件|文档|文件|试卷|作业|练习|图片|照片|test|document|scan|image|untitled)$') { $failure = '这个词过于宽泛，请填写文件名中更具体的短语。' }
    elseif (-not (Test-Keyword -Text ([IO.Path]::GetFileNameWithoutExtension($FileName)) -Keyword $word)) { $failure = '请使用当前文件名中实际出现的完整短语。' }
    if ($failure) { return [pscustomobject]@{ Valid=$false; Exists=$false; Keyword=$word; Error=$failure } }
    $target = @($Config.subjects | Where-Object { [string]$_.name -eq $Name }) | Select-Object -First 1
    if (-not $target) { return [pscustomobject]@{ Valid=$false; Exists=$false; Keyword=$word; Error='目录规则已变化，请重新选择。' } }
    $normalized = $word.Normalize([Text.NormalizationForm]::FormKC)
    foreach ($rule in @($Config.subjects)) {
        if ([string]$rule.name -eq $Name) { continue }
        foreach ($existing in @($rule.filenameKeywords)) {
            $existingWord = ([string]$existing).Trim()
            if (-not $existingWord) { continue }
            $same = $normalized.Equals($existingWord.Normalize([Text.NormalizationForm]::FormKC), [StringComparison]::OrdinalIgnoreCase)
            if ($same -or (Test-Keyword -Text $word -Keyword $existingWord) -or (Test-Keyword -Text $existingWord -Keyword $word)) {
                return [pscustomobject]@{ Valid=$false; Exists=$false; Keyword=$word; Error=('关键词与“' + [string]$rule.name + '”的规则冲突，请换一个短语或取消记住。') }
            }
        }
    }
    $exists = @($target.filenameKeywords | Where-Object { ([string]$_).Normalize([Text.NormalizationForm]::FormKC).Equals($normalized,[StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    return [pscustomobject]@{ Valid=$true; Exists=$exists; Keyword=$word; Error='' }
}

function Save-ManualClassificationKeyword {
    param([string]$Name, [string]$Keyword, [string]$FileName, [string]$MovedPath, [switch]$Confirmed)
    if (-not $Confirmed) { return [pscustomobject]@{ Saved=$false; Changed=$false; Error='没有明确确认记住关键词。' } }
    # The caller only invokes this after Move-ToSubject succeeds. Recheck the final file under the same mutation lock.
    Invoke-LibraryLock -Timeout 250 {
        $config = (Read-AtomicUtf8 $script:ConfigPath) | ConvertFrom-Json
        $configRoot = [string]$config.inbox
        if (-not [IO.Path]::IsPathRooted($configRoot)) { $configRoot = Join-Path $script:AppDir $configRoot }
        if (-not [IO.Path]::GetFullPath($configRoot).TrimEnd('\').Equals([IO.Path]::GetFullPath($script:Root).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Saved=$false; Changed=$false; Error='资料库配置已变化，未记住关键词。' }
        }
        $check = Test-ManualClassificationKeyword -Name $Name -Keyword $Keyword -FileName $FileName -Config $config
        if (-not $check.Valid) { return [pscustomobject]@{ Saved=$false; Changed=$false; Error=$check.Error } }
        $full = Assert-LibraryFile $MovedPath
        $expectedDirectory = [IO.Path]::GetFullPath((Join-Path $script:Root $Name)).TrimEnd('\')
        if (-not [IO.Path]::GetDirectoryName($full).TrimEnd('\').Equals($expectedDirectory,[StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Keyword -Text ([IO.Path]::GetFileNameWithoutExtension($full)) -Keyword $check.Keyword)) {
            return [pscustomobject]@{ Saved=$false; Changed=$false; Error='文件不在本次选择的目录，未记住关键词。' }
        }
        if ($check.Exists) { return [pscustomobject]@{ Saved=$true; Changed=$false; Error='' } }
        $target = @($config.subjects | Where-Object { [string]$_.name -eq $Name }) | Select-Object -First 1
        $target.filenameKeywords = @($target.filenameKeywords) + @($check.Keyword)
        Write-AtomicUtf8 $script:ConfigPath ($config | ConvertTo-Json -Depth 30)
        $script:Cfg = $config
        Write-Log ('LEARNED  filename keyword -> ' + $Name + '  [' + $check.Keyword + ']')
        return [pscustomobject]@{ Saved=$true; Changed=$true; Error='' }
    }
}

function Show-ClassificationLearningWarning {
    param([string]$Message)
    Add-Type -AssemblyName System.Windows.Forms
    $owner = New-Object Windows.Forms.Form
    $owner.TopMost=$true; $owner.ShowInTaskbar=$false; $owner.Opacity=0
    try {
        $owner.Show()
        [void][Windows.Forms.MessageBox]::Show($owner,('文件已移动，但没有记住关键词。' + [Environment]::NewLine + $Message),'奶龙select · 分类规则',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information)
    } finally { $owner.Close(); $owner.Dispose() }
}

function Complete-ManualClassificationLearning {
    param($Result, [string]$FileName, [string]$MovedPath, [switch]$Quiet)
    if (-not $Result -or $Result.Action -ne 'subject' -or -not $Result.Remember) { return }
    try {
        $saved = Save-ManualClassificationKeyword -Name ([string]$Result.Name) -Keyword ([string]$Result.Keyword) -FileName $FileName -MovedPath $MovedPath -Confirmed
    } catch { $saved = [pscustomobject]@{ Saved=$false; Changed=$false; Error=$_.Exception.Message } }
    $script:LastClassificationLearningResult = $saved
    if (-not $saved.Saved) {
        Write-Log ('LEARNING SKIPPED  ' + $saved.Error)
        if (-not $Quiet) { Show-ClassificationLearningWarning -Message $saved.Error }
    }
    return $saved
}

function Move-ManualSubjectSelection {
    param($FileInfo, $Result, [string]$Text, [switch]$TextProvided, [string]$Reason='manual')
    if (-not $Result -or $Result.Action -ne 'subject') { throw '没有有效的人工目录选择。' }
    if ($TextProvided) { $movedPath = Move-ToSubject -FileInfo $FileInfo -Folder ([string]$Result.Name) -Reason $Reason -Text $Text -TextProvided }
    else { $movedPath = Move-ToSubject -FileInfo $FileInfo -Folder ([string]$Result.Name) -Reason $Reason }
    # No learning attempt is reachable if the move throws, is busy, or fails signature verification.
    $null = Complete-ManualClassificationLearning -Result $Result -FileName $FileInfo.Name -MovedPath $movedPath
    return $movedPath
}
