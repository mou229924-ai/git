# Shared operations. All index writers and file movers use the same per-library lock.
function Invoke-LibraryLock {
    param([scriptblock]$Action, [int]$Timeout = 30000)
    $id = Get-IndexId -RelPath ([IO.Path]::GetFullPath($script:Root))
    $mutex = New-Object Threading.Mutex($false, ('Local\SubjectLibrary_' + $id))
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne($Timeout) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw '资料库正在处理文件，请稍后重试。' }
        & $Action
    } finally { if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Test-IgnoredDocument {
    param([string]$Path)
    $name = [IO.Path]::GetFileName($Path)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    return ($name -match '^(~|\.)' -or $name -match '(?i)\.tmp(?:\.|$)' -or
        @($script:Cfg.ignoreFiles) -contains $name -or @($script:Cfg.ignoreExtensions) -contains $ext)
}

function Get-LibraryFiles {
    param([string]$Directory = $script:Root)
    $appFull = [IO.Path]::GetFullPath($script:AppDir).TrimEnd('\')
    foreach ($item in @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if ($item.PSIsContainer) {
            if ($item.Name.StartsWith('.') -or $item.Name.StartsWith('_') -or $item.FullName -eq $appFull) { continue }
            Get-LibraryFiles -Directory $item.FullName
        } elseif (-not (Test-IgnoredDocument $item.FullName)) { $item }
    }
}

function Test-FileReady {
    param([string]$Path)
    try {
        $f = [IO.File]::Open($Path, 'Open', 'Read', 'None')
        $f.Dispose()
        return $true
    } catch { return $false }
}

function Write-AtomicUtf8 {
    param([string]$Path, [string]$Text)
    $tempPath = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($tempPath, $Text, $script:Utf8)
        for ($attempt=0; $attempt -lt 10; $attempt++) {
            try {
                if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tempPath, $Path, [System.Management.Automation.Language.NullString]::Value) }
                else { [IO.File]::Move($tempPath, $Path) }
                break
            } catch [IO.IOException] { if ($attempt -eq 9) { throw }; Start-Sleep -Milliseconds 30 }
        }
    } finally { if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) } }
}

function Read-AtomicUtf8 {
    param([string]$Path)
    for ($attempt=0; $attempt -lt 20; $attempt++) {
        try {
            $stream = [IO.File]::Open($Path, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $reader = New-Object IO.StreamReader($stream, $script:Utf8)
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        } catch [IO.IOException] { if ($attempt -eq 19) { throw }; Start-Sleep -Milliseconds 25 }
          catch [UnauthorizedAccessException] { if ($attempt -eq 19) { throw }; Start-Sleep -Milliseconds 25 }
    }
}

function Get-StreamHash {
    param([IO.Stream]$Stream)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $Stream.Position = 0; return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '') }
    finally { $sha.Dispose(); $Stream.Position = 0 }
}

function Test-StreamsEqual {
    param([IO.Stream]$First,[IO.Stream]$Second)
    if (-not ('Nailong.Native' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'NativePreview.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing }
    return [Nailong.Native]::SameContent($First,$Second)
}

function Find-DuplicateDocuments {
    param([scriptblock]$Progress)
    Invoke-LibraryLock {
        $scanFiles=@(Get-LibraryFiles | Sort-Object FullName)
        $scanIndex=0
        $lastProgress=[datetime]::MinValue
        $groups = @{}
        $documentExtensions = @('.pdf','.doc','.docx','.docm','.rtf','.odt','.ppt','.pptx','.xls','.xlsx','.txt')
        foreach ($file in $scanFiles) {
            $scanIndex++
            if ($Progress -and ((Get-Date)-$lastProgress).TotalMilliseconds -ge 150) { & $Progress $scanIndex $scanFiles.Count; $lastProgress=Get-Date }
            if ($documentExtensions -notcontains $file.Extension.ToLowerInvariant() -or $file.Length -eq 0) { continue }
            try {
                $stream = [IO.File]::Open($file.FullName, 'Open', 'Read', 'Read')
                try { $hash = Get-StreamHash $stream } finally { $stream.Dispose() }
                $key = [string]$file.Length + ':' + $hash
                if (-not $groups.ContainsKey($key)) { $groups[$key] = $file.FullName; continue }
                [pscustomobject]@{ Keep=$groups[$key]; Duplicate=$file.FullName; Hash=$hash; Size=[long]$file.Length }
            } catch { Write-Log ('DEDUPE SCAN SKIP  ' + $file.FullName + '  ' + $_.Exception.Message) }
        }
    }
}

function Assert-LibraryDocument {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Get-RelativePath $full)) { throw '文件不在资料库内。' }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw '禁止删除目录。' }
    $cursor = $item.Directory
    $rootFull = [IO.Path]::GetFullPath($script:Root).TrimEnd('\')
    while ($cursor) {
        if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '禁止通过链接操作文件。' }
        if ($cursor.FullName -eq $rootFull) { break }
        if ($cursor.Name.StartsWith('_') -or $cursor.Name.StartsWith('.')) { throw '禁止操作内部目录。' }
        $cursor = $cursor.Parent
    }
    if (-not $cursor) { throw '文件路径无效。' }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '禁止操作链接。' }
    if (@('.pdf','.doc','.docx','.docm','.rtf','.odt','.ppt','.pptx','.xls','.xlsx','.txt') -notcontains $item.Extension.ToLowerInvariant()) { throw '仅允许回收文档副本。' }
    if (Test-IgnoredDocument $full) { throw '禁止操作临时或内部文件。' }
    return $full
}

function Get-ApplicationCodeHash {
    param([string]$Directory=$script:AppDir)
    $manifest = Join-Path $Directory 'application-files.json'
    $names = @('operations.ps1','lib.ps1','classification.ps1','features.ps1','classifier.ps1','search.ps1','library-ui.ps1','extra-ui.ps1','explorer-layout.ps1','background.ps1','preview-host.ps1','NativePreview.cs')
    $parts = @()
    if ([IO.File]::Exists($manifest)) {
        $manifestData = [IO.File]::ReadAllText($manifest, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $names = @($manifestData)
        if ($names.Count -eq 0) { throw '运行文件清单为空。' }
        $parts += 'application-files.json:' + (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
    }
    $rootPrefix = [IO.Path]::GetFullPath($Directory).TrimEnd('\') + '\'
    foreach ($name in $names) {
        $relative = [string]$name
        $full = [IO.Path]::GetFullPath((Join-Path $Directory $relative))
        if ([IO.Path]::IsPathRooted($relative) -or -not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw '运行文件清单包含无效路径。'
        }
        $parts += $relative + ':' + (Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    $stream=New-Object IO.MemoryStream(,[Text.Encoding]::UTF8.GetBytes(($parts -join ';')))
    try { return Get-StreamHash $stream } finally { $stream.Dispose() }
}

function Test-DedupeVerified {
    try {
        $report = Get-Content -LiteralPath (Join-Path $script:AppDir 'tests\verified.json') -Raw | ConvertFrom-Json
        return ($report.Failed -eq 0 -and $report.Passed -ge 20 -and $report.RecycleTest -eq $true -and
            $report.TestedVolume -eq [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($script:Root)) -and
            $report.CodeHash -eq (Get-ApplicationCodeHash) -and
            $report.TestHash -eq (Get-FileHash -LiteralPath (Join-Path $script:AppDir 'tests\run-tests.ps1') -Algorithm SHA256).Hash)
    } catch { return $false }
}

function Invoke-DuplicateCleanup {
    param([object[]]$Plan, [switch]$Execute)
    if (-not $Execute) { return $Plan }
    if (-not (Test-DedupeVerified)) { throw '去重测试未通过或代码已变化，删除功能已锁定。' }
    Invoke-LibraryLock {
        Add-Type -AssemblyName Microsoft.VisualBasic
        foreach ($entry in $Plan) {
            $keepStream = $null; $duplicateStream = $null
            try {
                $keep = Assert-LibraryDocument $entry.Keep
                $duplicate = Assert-LibraryDocument $entry.Duplicate
                if ($keep -eq $duplicate) { throw '保留文件和重复文件不能相同。' }
                # Deny writes to both files and deny deleting the retained file during recycling.
                $keepStream = [IO.File]::Open($keep, 'Open', 'Read', 'Read')
                $duplicateStream = [IO.File]::Open($duplicate, 'Open', 'Read', ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
                if ($keepStream.Length -eq 0 -or $keepStream.Length -ne [long]$entry.Size -or
                    (Get-StreamHash $keepStream) -ne $entry.Hash -or (Get-StreamHash $duplicateStream) -ne $entry.Hash -or
                    -not (Test-StreamsEqual $keepStream $duplicateStream)) { throw '文件已变化或内容不一致，已跳过。' }
                $journal = Join-Path $script:AppDir '_dedupe-journal.jsonl'
                $record = @{ Time=(Get-Date).ToString('o'); Keep=$keep; Duplicate=$duplicate; Hash=$entry.Hash; Status='pending' }
                [IO.File]::AppendAllText($journal, (($record | ConvertTo-Json -Compress) + "`r`n"), $script:Utf8)
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($duplicate,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                    [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException)
                if ([IO.File]::Exists($duplicate)) { throw '回收操作未完成。' }
                $record.Status = 'recycled'
                [IO.File]::AppendAllText($journal, (($record | ConvertTo-Json -Compress) + "`r`n"), $script:Utf8)
                [pscustomobject]@{ Path=$duplicate; Status='recycled'; Error='' }
            } catch {
                [pscustomobject]@{ Path=[string]$entry.Duplicate; Status='skipped'; Error=$_.Exception.Message }
            } finally {
                if ($duplicateStream) { $duplicateStream.Dispose() }
                if ($keepStream) { $keepStream.Dispose() }
            }
        }
    }
}

function Import-LibraryItems {
    param([string[]]$Paths)
    Invoke-LibraryLock {
        foreach ($path in $Paths) {
            try {
                $source = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if (Get-RelativePath $source.FullName) { throw '文件已在资料库内。' }
                if (($source.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $source.PSIsContainer) {
                    throw '请拖入普通文件；文件夹请直接放到分类根目录。'
                }
                if (Test-IgnoredDocument $source.FullName) { throw '临时文件不导入。' }
                if (-not (Test-FileReady $source.FullName)) { throw '文件正在被使用，请关闭后重试。' }
                $target = Join-Path $script:Root $source.Name
                $i=2
                while (Test-Path -LiteralPath $target) {
                    $target = Join-Path $script:Root ($source.BaseName + ' (' + $i + ')' + $source.Extension); $i++
                }
                Move-Item -LiteralPath $source.FullName -Destination $target -ErrorAction Stop
                Write-Log ('IMPORTED  ' + $source.FullName + ' -> ' + $target)
                [pscustomobject]@{ Source=$path; Target=$target; Success=$true; Error='' }
            } catch { [pscustomobject]@{ Source=$path; Target=''; Success=$false; Error=$_.Exception.Message } }
        }
    }
}

function Wait-WinRt {
    param($Operation, [Type]$ResultType)
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1
    $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    return $task.GetAwaiter().GetResult()
}

function Get-PdfPageImage {
    param([string]$Path,[int]$PageIndex=0)
    $Path = [IO.Path]::GetFullPath($Path)
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    Add-Type -AssemblyName System.Drawing
    $null = [Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
    $null = [Windows.Data.Pdf.PdfDocument,Windows.Data.Pdf,ContentType=WindowsRuntime]
    $null = [Windows.Storage.Streams.InMemoryRandomAccessStream,Windows.Storage.Streams,ContentType=WindowsRuntime]
    $inputFile = [IO.File]::OpenRead($Path)
    $inputStream = $null; $page = $null; $memory = $null
    try {
        $inputStream = [IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($inputFile)
        $document = Wait-WinRt ([Windows.Data.Pdf.PdfDocument]::LoadFromStreamAsync($inputStream)) ([Windows.Data.Pdf.PdfDocument])
        $page = $document.GetPage([Math]::Max(0,[Math]::Min($PageIndex,([int]$document.PageCount-1))))
        $memory = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
        $operation = $page.RenderToStreamAsync($memory)
        $method = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and -not $_.IsGenericMethod -and $_.GetParameters().Count -eq 1
        } | Select-Object -First 1
        $task = $method.Invoke($null, @($operation)); $null = $task.GetAwaiter().GetResult()
        $stream = [IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($memory)
        try { $image = [Drawing.Image]::FromStream($stream); try { return @{ Image=(New-Object Drawing.Bitmap($image)); Pages=[int]$document.PageCount } } finally { $image.Dispose() } }
        finally { $stream.Dispose() }
    } finally {
        if ($page) { $page.Dispose() }; if ($memory) { $memory.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }; $inputFile.Dispose()
    }
}

function Get-DropFolderFiles {
    param([string]$Directory)
    foreach ($item in @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '文件夹含有目录链接，请先移除链接。' }
        if ($item.PSIsContainer) { Get-DropFolderFiles $item.FullName } else { $item }
    }
}

function Get-PdfPreviewImage { param([string]$Path) return (Get-PdfPageImage -Path $Path).Image }
