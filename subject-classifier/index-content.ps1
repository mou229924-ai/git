# Immutable compressed text objects are shared by documents with identical extracted text.
function Get-IndexContentPath {
    param($Entry)
    if ([string]$Entry.textKey -match '^[a-f0-9]{64}$') { return Join-Path $script:IndexDataDir ($Entry.textKey + '.gz') }
    if ([string]$Entry.id -match '^[a-f0-9]{40}$') { return Join-Path $script:IndexDataDir ($Entry.id + '.txt') }
    return $null
}

function New-IndexContentData {
    param([string]$Text)
    $bytes = $script:Utf8.GetBytes($Text)
    $input = New-Object IO.MemoryStream(,$bytes)
    try { $key = (Get-StreamHash $input).ToLowerInvariant() } finally { $input.Dispose() }
    $memory = New-Object IO.MemoryStream
    $gzip = New-Object IO.Compression.GZipStream($memory, [IO.Compression.CompressionMode]::Compress, $true)
    try { $gzip.Write($bytes, 0, $bytes.Length) } finally { $gzip.Dispose() }
    try { return [pscustomobject]@{ Key=$key; Bytes=$memory.ToArray() } } finally { $memory.Dispose() }
}

function Write-IndexContentData {
    param($Candidate)
    if (-not $Candidate.Entry.hasText) { return }
    $target = Get-IndexContentPath $Candidate.Entry
    if ([IO.File]::Exists($target)) { return }
    $temporary = $target + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllBytes($temporary, [byte[]]$Candidate.CacheBytes)
        [IO.File]::Move($temporary, $target)
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Read-IndexContentText {
    param($Entry)
    if (-not $Entry.hasText) { return $null }
    $path = Get-IndexContentPath $Entry
    if (-not $path -or -not [IO.File]::Exists($path)) { return $null }
    $cacheKey = $path
    if (-not $Entry.textKey) { $cacheKey += ':' + [string]$Entry.mtimeTicks }
    if ($script:SearchTextCache.ContainsKey($cacheKey)) { return $script:SearchTextCache[$cacheKey] }
    try {
        if ($path.EndsWith('.gz', [StringComparison]::OrdinalIgnoreCase)) {
            $stream = [IO.File]::Open($path, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $gzip = New-Object IO.Compression.GZipStream($stream, [IO.Compression.CompressionMode]::Decompress)
            $reader = New-Object IO.StreamReader($gzip, $script:Utf8)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Dispose() }
        } else { $text = Read-AtomicUtf8 $path }
        # Keep the process cache bounded; a large library never retains every body twice.
        $bytes = $text.Length * 2
        if ($bytes -le 8MB) {
            if (($script:IndexTextCacheBytes + $bytes) -gt 8MB) { $script:SearchTextCache=@{}; $script:IndexTextCacheBytes=0 }
            $script:SearchTextCache[$cacheKey]=$text
            $script:IndexTextCacheBytes += $bytes
        }
        return $text
    } catch {
        Write-Log ('INDEX CACHE RECOVERY  ' + [string]$Entry.rel + '  ' + $_.Exception.Message)
        # This only discards an unreadable cache object. The original document is untouched.
        Invoke-IndexLock { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
        Request-IndexRefresh -Paths @((Join-Path $script:Root ([string]$Entry.rel)))
        return $null
    }
}

function Open-IndexReadLease {
    Initialize-IndexFolders
    $directory = Join-Path $script:IndexDir 'readers'
    [void][IO.Directory]::CreateDirectory($directory)
    $path = Join-Path $directory ([guid]::NewGuid().ToString('N') + '.lease')
    $stream = [IO.File]::Open($path, 'CreateNew', 'ReadWrite', 'Read')
    return [pscustomobject]@{ Path=$path; Stream=$stream }
}

function Close-IndexReadLease {
    param($Lease)
    if (-not $Lease) { return }
    $Lease.Stream.Dispose()
    try { if ([IO.File]::Exists($Lease.Path)) { [IO.File]::Delete($Lease.Path) } } catch [IO.IOException] {} catch [UnauthorizedAccessException] {}
}

function Remove-OrphanIndexContent {
    param([object[]]$Entries)
    # A search creates its lease before reading a snapshot. Active older snapshots
    # keep their immutable bodies until the next maintenance pass.
    $readers = Join-Path $script:IndexDir 'readers'
    if ([IO.Directory]::Exists($readers)) {
        foreach ($lease in @(Get-ChildItem -LiteralPath $readers -File -Filter '*.lease' -ErrorAction SilentlyContinue)) {
            try {
                $handle = [IO.File]::Open($lease.FullName, 'Open', 'ReadWrite', 'None')
                $handle.Dispose()
                [IO.File]::Delete($lease.FullName)
            } catch { return 0 }
        }
    }
    $referenced=@{}
    foreach ($entry in $Entries) {
        if ($entry.hasText) { $referenced[(Get-IndexContentPath $entry)]=$true }
    }
    $removed=0
    foreach ($file in @(Get-ChildItem -LiteralPath $script:IndexDataDir -File -ErrorAction SilentlyContinue)) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Name -notmatch '^(?:[a-f0-9]{40}\.txt|[a-f0-9]{64}\.gz)$') { continue }
        if (-not $referenced.ContainsKey($file.FullName)) { [IO.File]::Delete($file.FullName); $removed++ }
    }
    return $removed
}
