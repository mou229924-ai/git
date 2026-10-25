# PDF text-layer extraction runs in a resource-bounded local child process.
function Get-PdfTextExtractorVersion { return 'pdfpig-0.1.16-v1' }

function Get-PdfTextLimits {
    $limits = [ordered]@{MaxPages=100;MaxFileMiB=25;TimeoutSeconds=15;MaxMemoryMiB=256}
    $config = $script:Cfg.pdfText
    foreach ($entry in @(@('maxPages','MaxPages',1,500),@('maxFileMiB','MaxFileMiB',1,100),@('timeoutSeconds','TimeoutSeconds',1,60),@('maxMemoryMiB','MaxMemoryMiB',64,512))) {
        if ($config -and $config.PSObject.Properties[$entry[0]]) {
            try { $limits[$entry[1]] = [Math]::Max([int]$entry[2],[Math]::Min([int]$entry[3],[int]$config.($entry[0]))) }
            catch { Write-Log ('Invalid PDF limit '+$entry[0]+'; using the bounded default.') -Level INFO -ThrottleSeconds 60 }
        }
    }
    return [pscustomobject]$limits
}

function Get-PdfTextAvailability {
    param([string]$Directory=$PSScriptRoot)
    $application = [IO.Path]::GetFullPath($Directory)
    $directory = Join-Path $application 'third-party\pdfpig'
    $required = @('System.Runtime.CompilerServices.Unsafe.dll','System.Buffers.dll','System.Numerics.Vectors.dll','System.Memory.dll','Microsoft.Bcl.HashCode.dll','System.ValueTuple.dll','UglyToad.PdfPig.Core.dll','UglyToad.PdfPig.Tokens.dll','UglyToad.PdfPig.Tokenization.dll','UglyToad.PdfPig.Fonts.dll','UglyToad.PdfPig.dll','UglyToad.PdfPig.DocumentLayoutAnalysis.dll')
    $missing = @($required | Where-Object {-not [IO.File]::Exists((Join-Path $directory $_))})
    $worker = Join-Path $application 'pdf-text-worker.ps1'
    $hostPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $available = ($missing.Count -eq 0 -and [IO.File]::Exists($worker) -and [IO.File]::Exists($hostPath))
    $reason = '内置 PDF 文字提取可用；无需启用 OCR 或联网。'
    if (-not $available) { $reason = 'PDF 文字提取组件不完整，请重新解压完整程序包；文件名搜索和预览仍可用。' }
    return [pscustomobject]@{Available=$available;Engine='PdfPig 0.1.16';Version=(Get-PdfTextExtractorVersion);ApplicationDirectory=$application;Directory=$directory;Worker=$worker;HostPath=$hostPath;Missing=$missing;Reason=$reason}
}

function Read-PdfTextCheckpoint {
    param([string]$Directory,[int]$MaxChars)
    $checkpoint = $null
    foreach ($name in @('result.json','result.previous.json')) {
        $slot = Join-Path $Directory $name
        if (-not [IO.File]::Exists($slot)) { continue }
        $file = Get-Item -LiteralPath $slot -Force
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -gt (8L*$MaxChars+65536)) { continue }
        try {
            $candidate = [IO.File]::ReadAllText($slot,[Text.Encoding]::UTF8) | ConvertFrom-Json
            $sequence = 0L
            if (-not $candidate -or -not $candidate.PSObject.Properties['Text'] -or -not $candidate.PSObject.Properties['Status'] -or -not [long]::TryParse([string]$candidate.CheckpointSequence,[ref]$sequence) -or $sequence -le 0) { continue }
            if (-not $checkpoint -or $sequence -gt [long]$checkpoint.CheckpointSequence) { $checkpoint = $candidate }
        } catch {
            # A killed child can leave one slot incomplete. The other slot remains readable.
            continue
        }
    }
    return $checkpoint
}

function Get-PdfTextExtraction {
    param([string]$Path,[int]$Max=60000)
    $Max = [Math]::Max(1,[Math]::Min(1000000,$Max))
    $limits = Get-PdfTextLimits
    $result = [pscustomobject]@{Path=$Path;Text='';Status='Unavailable';Reason='PDF 文字提取未开始。';TotalPages=0;ProcessedPages=0;EmptyPages=@();FailedPages=@();Truncated=$false;OcrPages=0;Engine='PdfPig 0.1.16';Version=(Get-PdfTextExtractorVersion)}
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $file -or $file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -le 0 -or $file.Extension -ne '.pdf') {
        $result.Status = 'InvalidInput'
        $result.Reason = 'PDF 不存在、为空、是链接或扩展名无效。'
        return $result
    }
    $result.Path = $file.FullName
    if ($file.Length -gt $limits.MaxFileMiB*1MB) {
        $result.Status = 'SizeLimit'
        $result.Reason = ('PDF 超过正文索引大小上限 '+$limits.MaxFileMiB+' MiB；可调整 pdfText.maxFileMiB 后重建索引。')
        $result.Truncated = $true
        return $result
    }
    $available = Get-PdfTextAvailability
    if (-not $available.Available) { $result.Reason=$available.Reason;return $result }
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('Nailong-pdf-'+[guid]::NewGuid().ToString('N'))
    $requestPath = Join-Path $temporary 'request.json'
    $resultPath = Join-Path $temporary 'result.json'
    $process = $null
    $stopReason = ''
    try {
        [void][IO.Directory]::CreateDirectory($temporary)
        $request = @{Path=$file.FullName;MaxChars=$Max;MaxPages=$limits.MaxPages;ResultPath=$resultPath;Ocr=$script:Cfg.ocr}
        [IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $available.HostPath
        # User filenames travel only in JSON, never in a command or PowerShell expression.
        $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "'+$available.Worker+'" -Request "'+$requestPath+'"'
        $start.StandardErrorEncoding = [Text.Encoding]::UTF8
        $start.StandardOutputEncoding = [Text.Encoding]::UTF8
        $start.UseShellExecute = $false
        $start.RedirectStandardError = $true
        $start.RedirectStandardOutput = $true
        $start.CreateNoWindow = $true
        $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        if (-not $process.Start()) { throw '无法启动 PDF 文字提取进程。' }
        $processHandle = $process.Handle
        $errorRead = $process.StandardError.ReadToEndAsync()
        $outputRead = $process.StandardOutput.ReadToEndAsync()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(80)) {
            if ($timer.Elapsed.TotalSeconds -ge $limits.TimeoutSeconds) { $stopReason='正文提取达到等待时间上限';break }
            $process.Refresh()
            if (-not $process.HasExited -and $process.PrivateMemorySize64 -gt $limits.MaxMemoryMiB*1MB) { $stopReason='正文提取达到内存监控上限';break }
        }
        if ($stopReason -and -not $process.HasExited) { $process.Kill();$null=$process.WaitForExit(2000) }
        $checkpoint = Read-PdfTextCheckpoint -Directory $temporary -MaxChars $Max
        if ($checkpoint) {
            foreach ($name in @('Text','Status','Reason','TotalPages','ProcessedPages','EmptyPages','FailedPages','Truncated','OcrPages')) {
                if ($checkpoint.PSObject.Properties[$name]) { $result.$name=$checkpoint.$name }
            }
            $result.Text = [string]$result.Text
            if ($result.Text.Length -gt $Max) { $result.Text=$result.Text.Substring(0,$Max);$result.Truncated=$true }
        } else {
            $details = ''
            if ($process.HasExited) { $details=[string]$errorRead.GetAwaiter().GetResult();if($details.Length -gt 1000){$details=$details.Substring(0,1000)} }
            $result.Status = 'Failed'
            $exitCode = if ($process.HasExited) { [string]$process.ExitCode } else { 'still running' }
            $result.Reason = 'PDF 文字提取进程未返回结果（'+$exitCode+'）：'+$details
        }
        if ($stopReason) {
            $result.Status = if ($result.Text) { 'Partial' } else { 'ResourceLimit' }
            $result.Truncated = $true
            $result.Reason = $stopReason+'；保留已提取正文，可调整 pdfText 限制后重建索引。'
        }
    } catch {
        $result.Status = if ($result.Text) { 'Partial' } else { 'Failed' }
        $result.Reason = 'PDF 文字提取失败：'+$_.Exception.Message
    } finally {
        if ($process) {
            try { if (-not $process.HasExited) { $process.Kill();$null=$process.WaitForExit(2000) } }
            catch { Write-Log ('PDF worker cleanup: '+$_.Exception.Message) -Level WARN }
            $process.Dispose()
        }
        foreach ($name in @('request.json','result.json','result.previous.json')) {
            $candidate = Join-Path $temporary $name
            if ([IO.File]::Exists($candidate)) { [IO.File]::Delete($candidate) }
        }
        if ([IO.Directory]::Exists($temporary)) {
            try { [IO.Directory]::Delete($temporary) }
            catch { Write-Log ('PDF temporary directory cleanup: '+$_.Exception.Message) -Level INFO -ThrottleSeconds 60 }
        }
    }
    return $result
}

function Get-PdfDocumentText {
    param([string]$Path,[int]$Max=60000)
    $result = Get-PdfTextExtraction -Path $Path -Max $Max
    $script:LastPdfTextResult = $result
    if ($result.Status -notin @('Complete','OcrComplete')) {
        Write-Log ('PDF TEXT '+$result.Status+'  '+[IO.Path]::GetFileName($Path)+'  '+$result.Reason) -Level INFO -ThrottleSeconds 60
    }
    if ([string]::IsNullOrWhiteSpace([string]$result.Text)) { return $null }
    return [string]$result.Text
}
