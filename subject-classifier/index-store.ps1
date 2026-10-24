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
    $json = ConvertTo-Json -InputObject ([object[]]@($Entries)) -Depth 5
    if (-not [IO.File]::Exists($script:IndexManifest) -or [IO.File]::ReadAllText($script:IndexManifest, $script:Utf8) -ne $json) {
        Write-AtomicUtf8 -Path $script:IndexManifest -Text $json
    }
    $script:SearchTextCache = @{}
}

function Sync-LibraryIndex {
    param([scriptblock]$Progress, [switch]$Force)
    Invoke-LibraryLock {
        Initialize-IndexFolders
        $old = @{}
        foreach ($entry in @(Load-IndexEntries)) { $old[[string]$entry.rel] = $entry }
        $files = @(Get-LibraryFiles)
        $entries = New-Object Collections.ArrayList
        $withText = 0
        $i = 0
        foreach ($file in $files) {
            $i++
            if ($Progress) { & $Progress $i $files.Count $file.Name }
            $rel = Get-RelativePath $file.FullName
            $id = Get-IndexId $rel
            $textPath = Join-Path $script:IndexDataDir ($id + '.txt')
            $previous = $old[$rel]
            if (-not $Force -and $previous -and [long]$previous.size -eq $file.Length -and
                [long]$previous.mtimeTicks -eq $file.LastWriteTime.Ticks -and
                (-not $previous.hasText -or [IO.File]::Exists($textPath))) {
                [void]$entries.Add($previous)
                if ($previous.hasText) { $withText++ }
                continue
            }
            if (-not (Test-FileReady $file.FullName)) {
                if ($previous) { [void]$entries.Add($previous); if ($previous.hasText) { $withText++ } }
                continue
            }
            $text = Get-FileText -Path $file.FullName -Max ([int]$script:Cfg.indexMaxChars)
            $hasText = -not [string]::IsNullOrWhiteSpace($text)
            if ($hasText) { Write-AtomicUtf8 $textPath $text; $withText++ }
            [void]$entries.Add([pscustomobject]@{
                id=$id; rel=$rel; name=$file.Name; subject=(Get-SubjectFromRelPath $rel)
                size=[long]$file.Length; mtime=$file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                mtimeTicks=[long]$file.LastWriteTime.Ticks; hasText=$hasText
            })
        }
        Save-IndexEntries -Entries $entries.ToArray()
        return @{ Total=$entries.Count; WithText=$withText }
    }
}

function Rebuild-Index {
    param([scriptblock]$Progress)
    Sync-LibraryIndex -Progress $Progress -Force
}

function Update-IndexEntry {
    param([string]$FilePath, [string]$Text, [switch]$TextProvided, [string]$OldRelPath)
    # Reconcile actual files under the lock; stale snapshots never overwrite another writer.
    $null = Sync-LibraryIndex
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
        [bool]$Descending = $true
    )
    $script:SearchTextCache = @{}
    $entries = @(Load-IndexEntries)
    $terms = @()
    if (-not [string]::IsNullOrWhiteSpace($Query)) {
        $terms = @([regex]::Matches($Query, '"([^"]+)"|(\S+)') | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } })
    }
    $results = New-Object System.Collections.ArrayList
    foreach ($e in $entries) {
        $full = Join-Path $script:Root ([string]$e.rel)
        if (-not (Test-Path -LiteralPath $full)) { continue }
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
        if ($IncludeContent -and [bool]$e.hasText) {
            $id = [string]$e.id
            if ($script:SearchTextCache.ContainsKey($id)) {
                $text = $script:SearchTextCache[$id]
            } else {
                $tp = Join-Path $script:IndexDataDir ($id + '.txt')
                if (Test-Path -LiteralPath $tp) {
                    $text = (Read-AtomicUtf8 $tp)
                    $script:SearchTextCache[$id] = $text
                }
            }
        }

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
    return @($results | Sort-Object -Property @{ Expression = { $_.$SortKey }; Descending = $Descending }, @{ Expression = { $_.mtimeTicks }; Descending = $true }, name | Select-Object -First $Limit)
}

