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
    $script:LastScanBusyCount = 0
    $script:Ui = @{ Paused = $false }
    # Existing folders are user categories, regardless of whether they have keyword rules.
    $script:ExistingCategoryDirectories=@(Get-ChildItem -LiteralPath $script:Root -Directory -Force -ErrorAction SilentlyContinue | Where-Object {-not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)} | ForEach-Object FullName)

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
    foreach ($ch in [IO.Path]::GetInvalidFileNameChars()) { $name = $name.Replace([string]$ch, '_') }
    $name = $name.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$script:Cfg.otherFolderName }
    if (-not (Test-LibraryName $name)) { throw '目录名包含无效字符或保留名称。' }
    # Capture the enumeration snapshot before waiting. Never classify a file that changed while a dialog was open.
    $expectedLength = [long]$FileInfo.Length
    $expectedTime = [long]$FileInfo.LastWriteTimeUtc.Ticks
    $sourcePath = [string]$FileInfo.FullName
    $oldRel = Get-RelativePath -FilePath $sourcePath
    $target = Invoke-LibraryLock -Timeout 250 {
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw (New-Object IO.IOException('文件已由其他操作移动，稍后刷新。')) }
        $source = Assert-LibraryFile $sourcePath
        $current = Get-Item -LiteralPath $source -Force -ErrorAction Stop
        if ($current.Length -ne $expectedLength -or $current.LastWriteTimeUtc.Ticks -ne $expectedTime) {
            throw (New-Object IO.IOException('文件在分类期间发生变化，稍后重新识别。'))
        }
        if (-not (Test-FileReady $source)) { throw (New-Object IO.IOException('文件仍在使用，稍后重试。')) }
        $destDir = Join-Path $script:Root $name
        if ((Test-Path -LiteralPath $destDir) -and ((Get-Item -LiteralPath $destDir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw '不能将文件移动到目录链接。'
        }
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        $destination = Get-UniquePath -Path (Join-Path $destDir $FileInfo.Name)
        Move-Item -LiteralPath $source -Destination $destination -ErrorAction Stop
        return $destination
    }
    Write-Log ('MOVED  ' + $FileInfo.Name + '  ->  ' + $name + '  [' + $Reason + ']')
    # Indexing has its own lock. Text extraction and index work never keep the library mutation lock.
    if ($TextProvided) { Update-IndexEntry -FilePath $target -Text $Text -TextProvided -OldRelPath $oldRel }
    else { Update-IndexEntry -FilePath $target -OldRelPath $oldRel }
    return $target
}

function Save-NewSubject {
    param([string]$Name)
    if (-not (Test-LibraryName $Name)) { throw '目录名包含无效字符或保留名称。' }
    Invoke-LibraryLock -Timeout 250 {
        Refresh-LibraryConfig
        $script:IgnoreNames += $Name
        if (-not $script:Cfg.saveNewSubjects) { return }
        foreach ($rule in $script:Cfg.subjects) { if ([string]$rule.name -eq $Name) { return } }
        $newRule = [pscustomobject]@{ name=$Name; filenameKeywords=@($Name); contentKeywords=@($Name) }
        $script:Cfg.subjects = @($script:Cfg.subjects) + @($newRule)
        Write-AtomicUtf8 -Path $script:ConfigPath -Text ($script:Cfg | ConvertTo-Json -Depth 12)
        Write-Log ('CONFIG  added subject: ' + $Name)
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
    param([string]$Path, [string]$OldBasePath = '')
    $files = @()
    if (Test-Path -LiteralPath $Path -PathType Container) { $files = @(Get-DropFolderFiles $Path) }
    elseif (Test-Path -LiteralPath $Path -PathType Leaf) { $files = @(Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue) }
    $i = 0
    foreach ($f in $files) {
        $i++
        Update-ProgressForm -Index $i -Total $files.Count -Name $f.Name
        $oldRel = ''
        if ($OldBasePath) {
            $suffix = $f.FullName.Substring(([IO.Path]::GetFullPath($Path)).TrimEnd('\').Length).TrimStart('\')
            $oldRel = Get-RelativePath (Join-Path $OldBasePath $suffix)
        }
        Update-IndexEntry -FilePath $f.FullName -OldRelPath $oldRel
    }
}

function Remove-EmptyDirs {
    param([string]$Dir)
    if (-not (Get-RelativePath $Dir)) { return }
    # Cleanup only empty ordinary directories, with each deletion serialized against other file movers.
    foreach ($child in @(Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue)) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { Remove-EmptyDirs -Dir $child.FullName }
    }
    try {
        Invoke-LibraryLock -Timeout 250 {
            if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return }
            $current = Get-Item -LiteralPath $Dir -Force -ErrorAction Stop
            if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
            if (@(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction Stop).Count -eq 0) {
                Remove-Item -LiteralPath $Dir -Force -ErrorAction Stop
            }
        }
    } catch [System.TimeoutException] { } catch [IO.IOException] { }
}

function Move-DroppedFolderWhole {
    param($Dir, [string]$Subject)
    if (-not (Test-LibraryName $Subject)) { throw '目录名包含无效字符或保留名称。' }
    $sourceDir = [IO.Path]::GetFullPath($Dir.FullName).TrimEnd('\')
    $subjectDir = Join-Path $script:Root $Subject
    if ($sourceDir.Equals([IO.Path]::GetFullPath($subjectDir).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return }
    if (-not (Get-RelativePath $sourceDir)) { throw '文件夹不在资料库内。' }
    $snapshot = @(Get-DropFolderFiles $sourceDir | ForEach-Object {
        [pscustomobject]@{ Path=$_.FullName; Size=[long]$_.Length; Time=[long]$_.LastWriteTimeUtc.Ticks }
    })
    $target = Invoke-LibraryLock -Timeout 250 {
        $folder = Get-Item -LiteralPath $sourceDir -Force -ErrorAction Stop
        if (-not $folder.PSIsContainer -or ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '不能分类目录链接。' }
        $currentFiles = @(Get-DropFolderFiles $sourceDir)
        if ($currentFiles.Count -ne $snapshot.Count) { throw (New-Object IO.IOException('文件夹内容仍在变化，稍后重试。')) }
        foreach ($entry in $snapshot) {
            $path = Assert-LibraryFile $entry.Path
            $current = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($current.Length -ne $entry.Size -or $current.LastWriteTimeUtc.Ticks -ne $entry.Time -or -not (Test-FileReady $path)) {
                throw (New-Object IO.IOException('文件夹内容仍在变化，稍后重试。'))
            }
        }
        if ((Test-Path -LiteralPath $subjectDir) -and ((Get-Item -LiteralPath $subjectDir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw '不能将文件夹移动到目录链接。'
        }
        if (-not (Test-Path -LiteralPath $subjectDir)) { New-Item -ItemType Directory -Path $subjectDir -Force | Out-Null }
        $destination = Get-UniquePath -Path (Join-Path $subjectDir $Dir.Name)
        Move-Item -LiteralPath $sourceDir -Destination $destination -ErrorAction Stop
        return $destination
    }
    Index-FilesUnder -Path $target -OldBasePath $sourceDir
    Write-Log ('FOLDER MOVED  ' + $Dir.Name + '  ->  ' + $Subject)
}

function Process-DroppedFolderFiles {
    param($Dir)
    $files = @(Get-DropFolderFiles $Dir.FullName)
    $total = $files.Count
    $i = 0
    $retryNeeded = $false
    foreach ($f in $files) {
        $i = $i + 1
        Update-ProgressForm -Index $i -Total $total -Name $f.Name

        $sig = [string]$f.Length + '|' + [string]$f.LastWriteTimeUtc.Ticks
        if ($script:Skip.ContainsKey($f.FullName) -and $script:Skip[$f.FullName] -eq $sig) { continue }

        if (Test-IgnoredDocument $f.FullName) { continue }
        if (-not (Test-FileReady $f.FullName)) { $retryNeeded = $true; continue }
        if ($script:LastScanBusyCount -gt 0) { $retryNeeded = $true; continue }
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
                    if ($result.Action -eq 'subject') {
                        [void](Move-ManualSubjectSelection -FileInfo $f -Result $result -Text $text -TextProvided:$attempted)
                    } elseif ($attempted) {
                        [void](Move-ToSubject -FileInfo $f -Folder $folderName -Reason 'manual' -Text $text -TextProvided)
                    } else {
                        [void](Move-ToSubject -FileInfo $f -Folder $folderName -Reason 'manual')
                    }
                } else {
                    $script:Skip[$f.FullName] = $sig
                    Write-Log ('KEPT (folder)  ' + $f.FullName)
                }
            }
        } catch [System.TimeoutException] {
            $script:LastScanBusyCount++
            $retryNeeded = $true
        } catch [IO.IOException] {
            $retryNeeded = $true
        } catch {
            Write-Log ('FOLDER FILE ERROR  ' + $f.FullName + '  ' + $_.Exception.Message)
        }
    }
    if ($retryNeeded) { throw (New-Object IO.IOException('资料库繁忙，文件夹稍后重试。')) }
    Remove-EmptyDirs -Dir $Dir.FullName
    Write-Log ('FOLDER PROCESSED  ' + $Dir.Name + '  files=' + [string]$total)
}

function Process-DroppedFolder {
    param($Dir)
    foreach ($file in @(Get-DropFolderFiles $Dir.FullName)) {
        if ($file.Name -match '^~|(?i)\.tmp(?:\.|$)' -or @($script:Cfg.ignoreExtensions) -contains $file.Extension.ToLowerInvariant()) { throw (New-Object IO.IOException('文件夹内仍有临时文件，等待保存或复制完成。')) }
        if (-not (Test-IgnoredDocument $file.FullName) -and -not (Test-FileReady $file.FullName)) { throw (New-Object IO.IOException('文件夹内有文件正在使用，稍后重试。')) }
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
    $script:LastScanBusyCount = 0
    try {
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
            # One bounded contention wait per scan; subsequent candidates keep their stable state for the next turn.
            if ($script:LastScanBusyCount -gt 0) { continue }

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
                        [void](Move-ManualSubjectSelection -FileInfo $fi -Result $result -Text $text -TextProvided:$textAttempted)
                    }
                }
            } catch [System.TimeoutException] {
                Write-Log ('BUSY classification retry') -Exception $_.Exception
                $script:LastScanBusyCount++
                $script:Defer[$key] = (Get-Date).AddSeconds([Math]::Max(1, [int]$script:Cfg.pollSeconds))
                continue
            } catch [IO.IOException] {
                $script:Defer[$key] = (Get-Date).AddSeconds([Math]::Max(1, [int]$script:Cfg.pollSeconds))
                continue
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
            if ($script:LastScanBusyCount -gt 0) { break }
            if(($script:Cfg.learning -and [bool]$script:Cfg.learning.enabled) -or $script:ExistingCategoryDirectories -contains $dir.FullName){continue}
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
            } catch [System.TimeoutException] {
                Write-Log ('BUSY classification retry') -Exception $_.Exception
                $script:LastScanBusyCount++
                continue
            } catch [IO.IOException] {
                continue
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
    } finally {
        $script:Busy = $false
    }
}
