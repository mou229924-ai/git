. (Join-Path $PSScriptRoot 'app-runtime.ps1')
Initialize-ApplicationRuntime
$script:IndexCache = $null
$script:SearchTextCache = @{}

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
    if($ext -in @('.pdf','.png','.jpg','.jpeg','.bmp','.tif','.tiff')){return Get-OcrDocumentText -Path $Path -Max $Max}
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
. (Join-Path $PSScriptRoot 'index-content.ps1')
. (Join-Path $PSScriptRoot 'index-store.ps1')
. (Join-Path $PSScriptRoot 'index-monitor.ps1')
. (Join-Path $PSScriptRoot 'features.ps1')

. (Join-Path $PSScriptRoot 'document-text.ps1')
. (Join-Path $PSScriptRoot 'classification-learning.ps1')

. (Join-Path $PSScriptRoot 'environment.ps1')

. (Join-Path $PSScriptRoot 'app-session.ps1')
