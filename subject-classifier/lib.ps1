$script:AppDir = $PSScriptRoot
$script:ConfigPath = Join-Path $script:AppDir 'config.json'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Cfg = [System.IO.File]::ReadAllText($script:ConfigPath, $script:Utf8) | ConvertFrom-Json
$script:Root = [string]$script:Cfg.inbox
$script:LogPath = Join-Path $script:AppDir ([string]$script:Cfg.logFile)

$script:IndexDir = Join-Path $script:AppDir '_index'
$script:IndexDataDir = Join-Path $script:IndexDir 'data'
$script:IndexManifest = Join-Path $script:IndexDir 'manifest.json'
$script:IndexCache = $null
$script:SearchTextCache = @{}

function Write-Log {
    param([string]$Message)
    try {
        if ((Test-Path -LiteralPath $script:LogPath) -and ((Get-Item -LiteralPath $script:LogPath).Length -gt 2MB)) {
            Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.old') -Force
        }
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Message + "`r`n"
        [System.IO.File]::AppendAllText($script:LogPath, $line, $script:Utf8)
    } catch {
    }
}

function Count-Occurrences {
    param([string]$Text, [string]$Needle)
    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Needle)) { return 0 }
    return ([regex]::Matches($Text, [regex]::Escape($Needle))).Count
}

function Test-Keyword {
    param([string]$Text, [string]$Keyword)
    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Keyword)) { return $false }
    if ($Keyword -match '^[\x20-\x7E]+$') {
        $pattern = '(?<![A-Za-z])' + [regex]::Escape($Keyword) + '(?![A-Za-z])'
        return [regex]::IsMatch($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    if ($Keyword.Length -eq 1) {
        $pattern = '(?<![\u4e00-\u9fff])' + [regex]::Escape($Keyword) + '(?![\u4e00-\u9fff])'
        return [regex]::IsMatch($Text, $pattern)
    }
    return ($Text.IndexOf($Keyword, [System.StringComparison]::Ordinal) -ge 0)
}

function Read-TextBytes {
    param([string]$Path, [int]$Max)
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $cap = [int]([Math]::Min([long]$fs.Length, [long]($Max * 4 + 8)))
            if ($cap -le 0) { return '' }
            $buf = New-Object byte[] $cap
            $n = $fs.Read($buf, 0, $cap)
        } finally {
            $fs.Close()
        }
    } catch {
        return $null
    }
    if ($n -le 0) { return '' }
    if ($n -ge 3 -and $buf[0] -eq 0xEF -and $buf[1] -eq 0xBB -and $buf[2] -eq 0xBF) {
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 3, $n - 3)
    } elseif ($n -ge 2 -and $buf[0] -eq 0xFF -and $buf[1] -eq 0xFE) {
        $text = [System.Text.Encoding]::Unicode.GetString($buf, 2, $n - 2)
    } elseif ($n -ge 2 -and $buf[0] -eq 0xFE -and $buf[1] -eq 0xFF) {
        $text = [System.Text.Encoding]::BigEndianUnicode.GetString($buf, 2, $n - 2)
    } else {
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        if ($text.IndexOf([char]0xFFFD) -ge 0) {
            try {
                $gbk = [System.Text.Encoding]::GetEncoding(936)
                $text = $gbk.GetString($buf, 0, $n)
            } catch {
            }
        }
    }
    if ($text.Length -gt $Max) { $text = $text.Substring(0, $Max) }
    return $text
}

function Get-OfficeZipText {
    param([string]$Path, [int]$Max)
    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $sb = New-Object System.Text.StringBuilder
        try {
            foreach ($entry in $zip.Entries) {
                $fn = $entry.FullName
                $wanted = $false
                if ($fn -eq 'word/document.xml' -or $fn -eq 'word/footnotes.xml' -or $fn -eq 'word/endnotes.xml') {
                    $wanted = $true
                } elseif ($fn -match '^word/(header|footer)\d*\.xml$') {
                    $wanted = $true
                } elseif ($fn -match '^ppt/(slides|notesSlides)/[^/]+\.xml$') {
                    $wanted = $true
                } elseif ($fn -eq 'xl/sharedStrings.xml' -or $fn -match '^xl/worksheets/sheet\d+\.xml$') {
                    $wanted = $true
                }
                if (-not $wanted) { continue }
                $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
                try {
                    $xml = $reader.ReadToEnd()
                } finally {
                    $reader.Close()
                }
                $plain = [regex]::Replace($xml, '<[^>]+>', ' ')
                $plain = [System.Net.WebUtility]::HtmlDecode($plain)
                [void]$sb.Append($plain)
                [void]$sb.Append(' ')
                if ($sb.Length -ge $Max) { break }
            }
        } finally {
            $zip.Dispose()
        }
        $out = $sb.ToString()
        if ($out.Length -gt $Max) { $out = $out.Substring(0, $Max) }
        return $out
    } catch {
        return $null
    }
}

function Get-ZipInnerText {
    param([string]$Path, [int]$Max)
    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $sb = New-Object System.Text.StringBuilder
        $used = 0
        try {
            foreach ($entry in $zip.Entries) {
                if ($entry.Length -le 0) { continue }
                $innerExt = [System.IO.Path]::GetExtension($entry.Name).ToLowerInvariant()
                if (@('.docx', '.docm', '.pptx', '.pptm', '.xlsx', '.xlsm', '.txt', '.md', '.html', '.htm') -notcontains $innerExt) { continue }
                $tmp = Join-Path $env:TEMP ('zipinner-' + [guid]::NewGuid().ToString('N') + $innerExt)
                try {
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $tmp, $true)
                    $inner = Get-FileText -Path $tmp -Max $Max
                    if (-not [string]::IsNullOrWhiteSpace($inner)) {
                        [void]$sb.Append($inner)
                        [void]$sb.Append(' ')
                        $used = $used + 1
                    }
                } catch {
                } finally {
                    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
                }
                if ($sb.Length -ge $Max -or $used -ge 3) { break }
            }
        } finally {
            $zip.Dispose()
        }
        $out = $sb.ToString()
        if ($out.Length -gt $Max) { $out = $out.Substring(0, $Max) }
        return $out
    } catch {
        return $null
    }
}

function Get-FileText {
    param([string]$Path, [int]$Max = 0)
    if ($Max -le 0) { $Max = [int]$script:Cfg.contentMaxChars }
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -eq '.zip') {
        return Get-ZipInnerText -Path $Path -Max $Max
    }
    if (@('.docx', '.docm', '.pptx', '.pptm', '.xlsx', '.xlsm') -contains $ext) {
        return Get-OfficeZipText -Path $Path -Max $Max
    }
    if (@('.txt', '.md', '.markdown', '.csv', '.tsv', '.log', '.json', '.xml', '.html', '.htm', '.tex', '.srt', '.ass', '.ini', '.yml', '.yaml', '.ps1', '.js', '.ts', '.py', '.java', '.c', '.h', '.cpp', '.sql', '.bat', '.cmd') -contains $ext) {
        return Read-TextBytes -Path $Path -Max $Max
    }
    return $null
}

function Test-FileReady {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $fs.Close()
        return $true
    } catch {
        return $false
    }
}

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
    if (-not (Test-Path -LiteralPath $script:IndexManifest)) {
        return
    }
    try {
        $raw = [System.IO.File]::ReadAllText($script:IndexManifest, $script:Utf8)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return
        }
        $obj = $raw | ConvertFrom-Json
        if ($null -eq $obj) { return }
        foreach ($item in @($obj)) { $item }
    } catch {
        return
    }
}

function Save-IndexEntries {
    param($Entries)
    Initialize-IndexFolders
    $list = @($Entries)
    $json = ConvertTo-Json -InputObject ([object[]]$list) -Depth 5
    [System.IO.File]::WriteAllText($script:IndexManifest, $json, $script:Utf8)
    $script:SearchTextCache = @{}
}

function Update-IndexEntry {
    param(
        [string]$FilePath,
        [string]$Text,
        [switch]$TextProvided,
        [string]$OldRelPath
    )
    try {
        $rel = Get-RelativePath -FilePath $FilePath
        if ($null -eq $rel) { return }
        $item = Get-Item -LiteralPath $FilePath -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { return }
        if (-not $TextProvided) {
            $Text = Get-FileText -Path $FilePath -Max ([int]$script:Cfg.indexMaxChars)
        }
        $hasText = -not [string]::IsNullOrWhiteSpace($Text)
        $id = Get-IndexId -RelPath $rel
        Initialize-IndexFolders
        if ($hasText) {
            [System.IO.File]::WriteAllText((Join-Path $script:IndexDataDir ($id + '.txt')), $Text, $script:Utf8)
        }
        $entry = New-Object PSObject -Property @{
            id = $id
            rel = $rel
            name = $item.Name
            subject = (Get-SubjectFromRelPath -RelPath $rel)
            size = [long]$item.Length
            mtime = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            mtimeTicks = [long]$item.LastWriteTime.Ticks
            hasText = $hasText
        }
        $entryList = @(Load-IndexEntries)
        $next = New-Object System.Collections.ArrayList
        foreach ($e in $entryList) {
            if ([string]$e.id -eq $id) { continue }
            if (-not [string]::IsNullOrEmpty($OldRelPath) -and [string]$e.rel -eq $OldRelPath) { continue }
            [void]$next.Add($e)
        }
        [void]$next.Add($entry)
        Save-IndexEntries -Entries $next.ToArray()
        if (-not [string]::IsNullOrEmpty($OldRelPath)) {
            $oldId = Get-IndexId -RelPath $OldRelPath
            $oldFile = Join-Path $script:IndexDataDir ($oldId + '.txt')
            if (Test-Path -LiteralPath $oldFile) { Remove-Item -LiteralPath $oldFile -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        Write-Log ('INDEX ERROR  ' + $FilePath + '  ' + $_.Exception.Message)
    }
}

function Rebuild-Index {
    param([scriptblock]$Progress)
    Initialize-IndexFolders
    if (Test-Path -LiteralPath $script:IndexDataDir) {
        Get-ChildItem -LiteralPath $script:IndexDataDir -File -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    $appFull = [System.IO.Path]::GetFullPath($script:AppDir).TrimEnd('\')
    $files = @(Get-ChildItem -LiteralPath $script:Root -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.FullName.StartsWith($appFull + '\', [System.StringComparison]::OrdinalIgnoreCase) })
    $entries = New-Object System.Collections.ArrayList
    $withText = 0
    $i = 0
    foreach ($f in $files) {
        $i = $i + 1
        if ($Progress -ne $null) { & $Progress $i $files.Count $f.Name }
        $rel = Get-RelativePath -FilePath $f.FullName
        if ($null -eq $rel) { continue }
        $text = Get-FileText -Path $f.FullName -Max ([int]$script:Cfg.indexMaxChars)
        $hasText = -not [string]::IsNullOrWhiteSpace($text)
        $id = Get-IndexId -RelPath $rel
        if ($hasText) {
            [System.IO.File]::WriteAllText((Join-Path $script:IndexDataDir ($id + '.txt')), $text, $script:Utf8)
            $withText = $withText + 1
        }
        [void]$entries.Add((New-Object PSObject -Property @{
            id = $id
            rel = $rel
            name = $f.Name
            subject = (Get-SubjectFromRelPath -RelPath $rel)
            size = [long]$f.Length
            mtime = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            mtimeTicks = [long]$f.LastWriteTime.Ticks
            hasText = $hasText
        }))
    }
    Save-IndexEntries -Entries $entries.ToArray()
    return @{ Total = $files.Count; WithText = $withText }
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

function Get-RoundedPath {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $d = [single]($R * 2)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $path.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $path.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

function Set-RoundedRegion {
    param($Control, [single]$Radius)
    try {
        if ($Control.Width -le 0 -or $Control.Height -le 0) { return }
        $path = Get-RoundedPath -X 0 -Y 0 -W $Control.Width -H $Control.Height -R $Radius
        $Control.Region = New-Object System.Drawing.Region($path)
        $path.Dispose()
    } catch {
    }
}
. (Join-Path $PSScriptRoot 'classification.ps1')
. (Join-Path $PSScriptRoot 'operations.ps1')
. (Join-Path $PSScriptRoot 'features.ps1')
