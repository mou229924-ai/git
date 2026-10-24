# Classification and scan state. No process startup is performed when this module is loaded.
$script:IgnoreNames = @($script:Cfg.ignoreFiles | ForEach-Object { [string]$_ })
$script:IgnoreExts = @($script:Cfg.ignoreExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
foreach ($rule in $script:Cfg.subjects) { $script:IgnoreNames += [string]$rule.name }
$script:IgnoreNames += [string]$script:Cfg.otherFolderName

function Initialize-ClassifierState {
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
}

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
