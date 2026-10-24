# Index storage and querying. File mutations and library locking live in operations.ps1.
function Initialize-IndexFolders {
    if (-not (Test-Path -LiteralPath $script:IndexDir)) {
        New-Item -ItemType Directory -Path $script:IndexDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:IndexDataDir)) {
        New-Item -ItemType Directory -Path $script:IndexDataDir -Force | Out-Null
    }
}

function Get-RelativePath {
    param([string]$FilePath)
    try {
        $rootFull = [System.IO.Path]::GetFullPath($script:Root).TrimEnd('\') + '\'
        $full = [System.IO.Path]::GetFullPath($FilePath)
        if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
        return $full.Substring($rootFull.Length)
    } catch {
        return $null
    }
}

function Get-IndexId {
    param([string]$RelPath)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($RelPath.ToLowerInvariant())
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-SubjectFromRelPath {
    param([string]$RelPath)
    $subject = [string]$script:Cfg.search.unclassified
    $parts = $RelPath -split '\\'
    if ($parts.Count -gt 1) { $subject = $parts[0] }
    return $subject
}

function Load-IndexEntries {
    if (-not [IO.File]::Exists($script:IndexManifest)) { return }
    $raw = Read-AtomicUtf8 $script:IndexManifest
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    foreach ($entry in @($raw | ConvertFrom-Json)) { if ($entry) { $entry } }
}

function Save-IndexEntries {
    param($Entries)
    Initialize-IndexFolders
    $json = ConvertTo-Json -InputObject ([object[]]@($Entries)) -Depth 5 -Compress
    $changed = (-not [IO.File]::Exists($script:IndexManifest) -or (Read-AtomicUtf8 $script:IndexManifest) -ne $json)
    if ($changed) { Write-AtomicUtf8 -Path $script:IndexManifest -Text $json; $script:SearchTextCache=@{}; $script:IndexTextCacheBytes=0 }
    return $changed
}

function Invoke-IndexLock {
    param([scriptblock]$Action, [int]$Timeout = 30000)
    $id = Get-IndexId -RelPath ([IO.Path]::GetFullPath($script:IndexDir))
    $mutex = New-Object Threading.Mutex($false, ('Local\SubjectIndex_' + $id))
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne($Timeout) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw (New-Object System.TimeoutException('索引正在更新，请稍后重试。')) }
        & $Action
    } finally { if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Get-IndexSourceItem {
    param([string]$Path)
    if (-not (Get-RelativePath $Path) -or (Test-IgnoredDocument $Path)) { return $null }
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $file -or $file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
    $rootFull = [IO.Path]::GetFullPath($script:Root).TrimEnd('\')
    $appFull = [IO.Path]::GetFullPath($script:AppDir).TrimEnd('\')
    $cursor = $file.Directory
    while ($cursor -and $cursor.FullName -ne $rootFull) {
        if ($cursor.Name -match '^[._]' -or $cursor.FullName -eq $appFull -or
            ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
        $cursor = $cursor.Parent
    }
    if (-not $cursor) { return $null }
    return $file
}

function New-IndexCandidate {
    param($File, [string]$Text, [switch]$TextProvided)
    $rel = Get-RelativePath $File.FullName
    if (-not $rel -or -not (Test-FileReady $File.FullName)) { return $null }
    if (-not $TextProvided) { $Text = Get-FileText -Path $File.FullName -Max ([int]$script:Cfg.indexMaxChars) }
    $hasText = -not [string]::IsNullOrWhiteSpace($Text)
    $body = $null
    if ($hasText) { $body = New-IndexContentData $Text }
    return [pscustomobject]@{
        Entry = [pscustomobject]@{
            id=(Get-IndexId $rel); rel=$rel; name=$File.Name; subject=(Get-SubjectFromRelPath $rel)
            size=[long]$File.Length; mtime=$File.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            mtimeTicks=[long]$File.LastWriteTime.Ticks; hasText=$hasText; textKey=[string]$body.Key
        }
        CacheBytes = $body.Bytes
    }
}

function Commit-IndexCandidates {
    param([object[]]$Candidates, [string[]]$RemovePaths = @(), [switch]$Reconcile, [switch]$PruneCache, [switch]$FullReconcile)
    Invoke-IndexLock {
        Initialize-IndexFolders
        $current = @{}
        $deferred = New-Object Collections.ArrayList
        foreach ($entry in @(Load-IndexEntries)) { $current[[string]$entry.rel] = $entry }
        foreach ($candidate in $Candidates) {
            if (-not $candidate) { continue }
            $entry = $candidate.Entry
            $full = Join-Path $script:Root ([string]$entry.rel)
            $actual = Get-IndexSourceItem $full
            if (-not $actual) { continue }
            if ([long]$actual.Length -ne [long]$entry.size -or [long]$actual.LastWriteTime.Ticks -ne [long]$entry.mtimeTicks) {
                [void]$deferred.Add($full); continue
            }
            Write-IndexContentData $candidate
            $current[[string]$entry.rel] = $entry
        }
        $remove = @($RemovePaths)
        if ($Reconcile) { $remove = @($current.Keys) }
        foreach ($rel in $remove) {
            if ([string]::IsNullOrWhiteSpace($rel)) { continue }
            $full = Join-Path $script:Root $rel
            if ((Get-RelativePath $full) -and -not (Get-IndexSourceItem $full)) { $current.Remove($rel) }
        }
        $entries = @($current.Values | Sort-Object rel)
        $changed = Save-IndexEntries -Entries $entries
        if ($FullReconcile) {
            $state = @{ Schema=2; SourceRoot=[IO.Path]::GetFullPath($script:Root); LastFullUtc=[datetime]::UtcNow.ToString('o') }
            Write-AtomicUtf8 (Join-Path $script:IndexDir 'state.json') ($state | ConvertTo-Json -Compress)
        }
        $pruned=0
        if ($PruneCache) { $pruned=Remove-OrphanIndexContent -Entries $entries }
        return @{ Total=$entries.Count; WithText=@($entries | Where-Object hasText).Count; Changed=[bool]$changed; Deferred=@($deferred.ToArray()); Pruned=$pruned; FullReconcile=[bool]$FullReconcile; Busy=$false }
    }
}

function Sync-LibraryIndex {
    param([scriptblock]$Progress, [switch]$Force, [switch]$Incremental)
    Initialize-IndexFolders
    $null = Flush-IndexChangeMonitor
    $maintenanceId = Get-IndexId -RelPath ([IO.Path]::GetFullPath($script:IndexDir))
    $maintenance = New-Object Threading.Mutex($false, ('Local\SubjectIndexMaintenance_' + $maintenanceId))
    $owned = $false
    try {
        try { $wait=30000; if ($Incremental) { $wait=0 }; $owned=$maintenance.WaitOne($wait) } catch [Threading.AbandonedMutexException] { $owned=$true }
        if (-not $owned) {
            $snapshot=@(Load-IndexEntries)
            return @{ Total=$snapshot.Count; WithText=@($snapshot | Where-Object hasText).Count; Changed=$false; Busy=$true; FullReconcile=$false }
        }
        $old = @{}
        foreach ($entry in @(Load-IndexEntries)) { $old[[string]$entry.rel] = $entry }
        $full = (-not $Incremental -or $Force -or -not [IO.File]::Exists($script:IndexManifest))
        $statePath = Join-Path $script:IndexDir 'state.json'
        $rootChanged=$false
        try {
            $state = (Read-AtomicUtf8 $statePath) | ConvertFrom-Json
            $rootChanged=([string]$state.SourceRoot -ne [IO.Path]::GetFullPath($script:Root))
            if ($rootChanged -or ([datetime]::UtcNow - ([datetime]$state.LastFullUtc).ToUniversalTime()).TotalMinutes -ge 5) { $full=$true }
        } catch { $full=$true }
        $queueDir=Join-Path $script:IndexDir 'changes'
        $batches=@()
        $paths=@{}
        if ([IO.Directory]::Exists($queueDir)) {
            $batches=@(Get-ChildItem -LiteralPath $queueDir -File -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
            foreach ($batch in $batches) {
                try {
                    $change=(Read-AtomicUtf8 $batch.FullName) | ConvertFrom-Json
                    if ($change.Full) { $full=$true }
                    foreach ($path in $change.Paths) {
                        if ($path -and (Get-RelativePath ([string]$path))) { $paths[[IO.Path]::GetFullPath([string]$path)]=$true }
                    }
                } catch { $full=$true }
            }
        }
        if (-not $full -and $paths.Count -eq 0 -and $batches.Count -eq 0) {
            return @{ Total=$old.Count; WithText=@($old.Values | Where-Object hasText).Count; Changed=$false; Busy=$false; FullReconcile=$false }
        }
        $fileMap=@{}
        $remove=@{}
        if ($full) {
            foreach ($file in @(Get-LibraryFiles)) { $fileMap[$file.FullName]=$file }
        } else {
            foreach ($path in $paths.Keys) {
                $rel=Get-RelativePath $path
                $remove[$rel]=$true
                foreach ($existingRel in $old.Keys) {
                    if ($existingRel.StartsWith($rel.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { $remove[$existingRel]=$true }
                }
                $file=Get-IndexSourceItem $path
                if ($file) { $fileMap[$file.FullName]=$file; continue }
                if ([IO.Directory]::Exists($path)) {
                    $directory=Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                    $relativeParent=Get-RelativePath $path
                    if ($directory -and -not ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
                        $relativeParent -notmatch '(?:^|\\)[._]' -and
                        -not $path.StartsWith([IO.Path]::GetFullPath($script:AppDir).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -and
                        $path -ne [IO.Path]::GetFullPath($script:AppDir).TrimEnd('\')) {
                        foreach ($nested in @(Get-LibraryFiles -Directory $path)) { $fileMap[$nested.FullName]=$nested }
                    }
                }
            }
        }
        $candidates=New-Object Collections.ArrayList
        $deferred=New-Object Collections.ArrayList
        $files=@($fileMap.Values)
        $i=0
        foreach ($file in $files) {
            $i++
            if ($Progress) { & $Progress $i $files.Count $file.Name }
            $rel=Get-RelativePath $file.FullName
            $previous=$old[$rel]
            $unchanged=(-not $Force -and -not $rootChanged -and $previous -and [long]$previous.size -eq $file.Length -and [long]$previous.mtimeTicks -eq $file.LastWriteTime.Ticks)
            $legacyText=$null
            if ($unchanged) {
                if (-not $previous.hasText) { continue }
                $cachePath=Get-IndexContentPath $previous
                if ($cachePath -and [IO.File]::Exists($cachePath)) {
                    if ($previous.textKey) { continue }
                    # Old plain-text bodies migrate without opening or reparsing documents.
                    $legacyText=Read-IndexContentText $previous
                }
            }
            if ($null -ne $legacyText) { $candidate=New-IndexCandidate -File $file -Text $legacyText -TextProvided }
            else { $candidate=New-IndexCandidate -File $file }
            if ($candidate) { [void]$candidates.Add($candidate) }
            elseif ([IO.File]::Exists($file.FullName)) { [void]$deferred.Add($file.FullName) }
        }
        $result=Commit-IndexCandidates -Candidates $candidates.ToArray() -RemovePaths @($remove.Keys) -Reconcile:$full -PruneCache:$full -FullReconcile:$full
        # Only batches observed before this scan are acknowledged. New events survive.
        foreach ($batch in $batches) { if ([IO.File]::Exists($batch.FullName)) { [IO.File]::Delete($batch.FullName) } }
        $retry=@($deferred.ToArray())+@($result.Deferred)
        if ($retry.Count) { Request-IndexRefresh -Paths $retry }
        return $result
    } finally { if ($owned) { $maintenance.ReleaseMutex() }; $maintenance.Dispose() }
}

function Rebuild-Index {
    param([scriptblock]$Progress)
    Sync-LibraryIndex -Progress $Progress -Force
}

function Update-IndexEntry {
    param([string]$FilePath, [string]$Text, [switch]$TextProvided, [string]$OldRelPath)
    $rel = Get-RelativePath $FilePath
    if (-not $rel) { return }
    $file = Get-IndexSourceItem $FilePath
    $candidates = @()
    if ($file -and -not $file.PSIsContainer -and -not (Test-IgnoredDocument $FilePath) -and
        -not ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $candidate = New-IndexCandidate -File $file -Text $Text -TextProvided:$TextProvided
        if ($candidate) { $candidates = @($candidate) }
    }
    $null = Commit-IndexCandidates -Candidates $candidates -RemovePaths @($rel, $OldRelPath)
}

function Search-Index {
    param(
        [string]$Query,
        [string]$Subject = '',
        [bool]$IncludeContent = $true,
        [int]$Limit = 300,
        [datetime]$ModifiedSince = [datetime]::MinValue,
        [string[]]$Extensions = @(),
        [string]$SortKey = 'score',
        [bool]$Descending = $true,
        [ValidateRange(0,2147483647)][int]$Offset = 0,
        [switch]$AsPage
    )
    $lease = Open-IndexReadLease
    try {
    $entries = @(Load-IndexEntries)
    $terms = @()
    if (-not [string]::IsNullOrWhiteSpace($Query)) {
        $terms = @([regex]::Matches($Query, '"([^"]+)"|(\S+)') | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } })
    }
    $results = New-Object System.Collections.ArrayList
    foreach ($e in $entries) {
        $full = Join-Path $script:Root ([string]$e.rel)
        if ($Subject -eq [string]$script:Cfg.search.unclassified) {
            if ([string]$e.rel -match '\\') { continue }
        } elseif ($Subject -and -not ([string]$e.rel).StartsWith($Subject.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ([long]$e.mtimeTicks -lt $ModifiedSince.Ticks) { continue }
        if ($Extensions.Count -gt 0 -and $Extensions -notcontains [IO.Path]::GetExtension([string]$e.name).ToLowerInvariant()) { continue }

        if ($terms.Count -eq 0) {
            [void]$results.Add((New-Object PSObject -Property @{
                rel = [string]$e.rel
                full = $full
                name = [string]$e.name
                subject = [string]$e.subject
                size = [long]$e.size
                mtime = [string]$e.mtime
                mtimeTicks = [long]$e.mtimeTicks
                hasText = [bool]$e.hasText
                hit = ''
                score = 0
            }))
            continue
        }

        $text = $null
        if ($IncludeContent -and [bool]$e.hasText) { $text=Read-IndexContentText $e }

        $score = 0
        $allFound = $true
        $snippet = ''
        foreach ($rawTerm in $terms) {
            $exclude=$rawTerm.StartsWith('-') -and $rawTerm.Length -gt 1
            $term=$rawTerm
            if ($exclude) { $term=$rawTerm.Substring(1) }
            $inName = ([string]$e.name).IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            $inRel = ([string]$e.rel).IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            $inText = $false
            $pos = -1
            if ($null -ne $text) {
                $pos = $text.IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase)
                if ($pos -ge 0) { $inText = $true }
            }
            if ($exclude) {
                if ($inName -or $inRel -or $inText) { $allFound=$false; break }
                continue
            }
            if (-not ($inName -or $inRel -or $inText)) {
                $allFound = $false
                break
            }
            if ($inName -or $inRel) { $score = 2 }
            elseif ($inText -and $score -lt 1) { $score = 1 }
            if ($inText -and $snippet -eq '' -and $null -ne $text) {
                $start = [Math]::Max(0, $pos - 40)
                $len = [Math]::Min(120, $text.Length - $start)
                if ($len -gt 0) {
                    $snippet = [regex]::Replace($text.Substring($start, $len), '\s+', ' ').Trim()
                    if ($start -gt 0) { $snippet = '...' + $snippet }
                    if (($start + $len) -lt $text.Length) { $snippet = $snippet + '...' }
                }
            }
        }
        if (-not $allFound) { continue }

        [void]$results.Add((New-Object PSObject -Property @{
            rel = [string]$e.rel
            full = $full
            name = [string]$e.name
            subject = [string]$e.subject
            size = [long]$e.size
            mtime = [string]$e.mtime
            mtimeTicks = [long]$e.mtimeTicks
            hasText = [bool]$e.hasText
            hit = $snippet
            score = $score
        }))
    }

    if (@('score','mtimeTicks','name','size','rel') -notcontains $SortKey) { $SortKey='score' }
    $sorted=@($results | Sort-Object -Property @{ Expression = { $_.$SortKey }; Descending = $Descending }, @{ Expression = { $_.mtimeTicks }; Descending = $true }, name)
    $total=$sorted.Count
    $take=$Limit
    if ($take -le 0) { $take=[Math]::Max(0,$total-$Offset) }
    $page=@()
    if ($Offset -lt $total -and $take -gt 0) { $page=@($sorted | Select-Object -Skip $Offset -First $take) }
    if ($AsPage) {
        return [pscustomobject]@{ Results=[object[]]$page; TotalMatches=$total; TotalIndexed=$entries.Count; Offset=$Offset; Limit=$take; HasMore=(($Offset+$page.Count) -lt $total); Total=$entries.Count }
    }
    return $page
    } finally { Close-IndexReadLease $lease }
}

