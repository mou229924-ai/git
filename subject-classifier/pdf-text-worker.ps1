param([Parameter(Mandatory=$true)][string]$Request)
# This independent child reads a single local PDF; it never initializes app configuration.
$ErrorActionPreference='Stop'
$utf8=New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding=$utf8
$job=[IO.File]::ReadAllText($Request,$utf8)|ConvertFrom-Json
$resultPath=[IO.Path]::GetFullPath([string]$job.ResultPath)
if([IO.Path]::GetDirectoryName($resultPath) -ne [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Request))){throw 'PDF result must stay beside its request.'}
$maximum=[Math]::Max(1,[Math]::Min(1000000,[int]$job.MaxChars))
$maxPages=[Math]::Max(1,[Math]::Min(500,[int]$job.MaxPages))
$body=New-Object Text.StringBuilder
$result=[ordered]@{CheckpointSequence=0;Text='';Status='Partial';Reason='正在本机提取 PDF 正文。';TotalPages=0;ProcessedPages=0;EmptyPages=@();FailedPages=@();Truncated=$true;OcrPages=0}
function Save-PdfWorkerCheckpoint {
    # Alternating slots preserve the preceding valid page even if this process stops mid-write.
    # This also works on locations that deny rename/replace while allowing ordinary file writes.
    $result.Text=$body.ToString();$result.CheckpointSequence++
    $target=if($result.CheckpointSequence % 2){$resultPath}else{Join-Path ([IO.Path]::GetDirectoryName($resultPath)) 'result.previous.json'}
    [IO.File]::WriteAllText($target,($result|ConvertTo-Json -Depth 6),$utf8)
}
function Add-PdfWorkerText([string]$Text){
    if([string]::IsNullOrWhiteSpace($Text) -or $body.Length -ge $maximum){return}
    if($body.Length){[void]$body.Append([char]10)}
    $available=$maximum-$body.Length
    if($Text.Length -gt $available){$Text=$Text.Substring(0,$available)}
    [void]$body.Append($Text)
}
function Write-PdfWorkerLog([string]$Message){$result.Reason=$Message}
$document=$null
try{
    $directory=Join-Path $PSScriptRoot 'third-party\pdfpig'
    foreach($name in @('System.Runtime.CompilerServices.Unsafe.dll','System.Buffers.dll','System.Numerics.Vectors.dll','System.Memory.dll','Microsoft.Bcl.HashCode.dll','System.ValueTuple.dll','UglyToad.PdfPig.Core.dll','UglyToad.PdfPig.Tokens.dll','UglyToad.PdfPig.Tokenization.dll','UglyToad.PdfPig.Fonts.dll','UglyToad.PdfPig.dll','UglyToad.PdfPig.DocumentLayoutAnalysis.dll')){$null=[Reflection.Assembly]::LoadFrom((Join-Path $directory $name))}
    $options=New-Object UglyToad.PdfPig.ParsingOptions
    $options.UseActualText=$true;$options.MaxStackDepth=128
    $document=[UglyToad.PdfPig.PdfDocument]::Open([string]$job.Path,$options)
    $result.TotalPages=[int]$document.NumberOfPages
    Save-PdfWorkerCheckpoint
    for($number=1;$number -le [Math]::Min($maxPages,$result.TotalPages);$number++){
        try{
            $page=$document.GetPage($number)
            $text=[UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor.ContentOrderTextExtractor]::GetText($page,$false)
            if([string]::IsNullOrWhiteSpace($text)){$result.EmptyPages+=($number-1)}else{Add-PdfWorkerText $text}
        }catch{$result.FailedPages+=($number-1);$result.Reason='部分 PDF 页面无法解析，已保留其他页面正文。'}
        $result.ProcessedPages=$number
        Save-PdfWorkerCheckpoint
        if($body.Length -ge $maximum){break}
    }
    $document.Dispose();$document=$null
    $result.Truncated=($result.ProcessedPages -lt $result.TotalPages -or $body.Length -ge $maximum -or $result.FailedPages.Count -gt 0)
    $result.Status='Complete';$result.Reason='PDF 文字层正文已提取，无需 OCR。'
    if($result.Truncated){$result.Status='Partial';$result.Reason='PDF 仅索引已读取页面/字符；达到页数、字符上限或存在无法解析的页面，可调整 pdfText 限制后重建。'}
    Save-PdfWorkerCheckpoint
    if($result.EmptyPages.Count -gt 0){
        $result.Status=if($body.Length){'Partial'}else{'NoTextLayer'}
        $result.Reason='PDF 存在无文字层的页面；扫描页需在“更多”启用本机 OCR，现有文字层已保留。'
        Save-PdfWorkerCheckpoint
        if($job.Ocr -and $job.Ocr.enabled -and $body.Length -lt $maximum){
            . (Join-Path $PSScriptRoot 'operations.ps1')
            . (Join-Path $PSScriptRoot 'document-text.ps1')
            Set-Alias -Name Write-Log -Value Write-PdfWorkerLog
            $script:Cfg=[pscustomobject]@{ocr=$job.Ocr}
            $availability=Get-OcrAvailability
            if(-not $availability.Available){$result.Reason=$availability.Reason+' PDF 文字层已保留。'}
            else{
                $ocrLimit=2;if($job.Ocr.maxPages){$ocrLimit=[Math]::Max(1,[Math]::Min(10,[int]$job.Ocr.maxPages))}
                foreach($index in @($result.EmptyPages|Select-Object -First $ocrLimit)){
                    $recognized=Get-OcrDocumentText -Path ([string]$job.Path) -Max ($maximum-$body.Length) -PageIndices @([int]$index)
                    if(-not [string]::IsNullOrWhiteSpace($recognized)){Add-PdfWorkerText $recognized;$result.OcrPages++}
                    Save-PdfWorkerCheckpoint
                    if($body.Length -ge $maximum){break}
                }
                if($result.OcrPages -gt 0){$result.Status='OcrComplete';$result.Reason='文字层和所选扫描页的本机 OCR 正文已提取。'}
                if($result.OcrPages -lt $result.EmptyPages.Count -or $result.Truncated -or $body.Length -ge $maximum){$result.Status='Partial';$result.Reason='保留文字层和已识别扫描页；部分扫描页受 OCR 页数、资源限制或未识别出文字。'}
            }
        }
    }
}catch{
    $kind=$_.Exception.ToString()
    $result.Status=if($body.Length){'Partial'}elseif($kind -match 'Encrypt|Password'){'Encrypted'}else{'Failed'}
    $result.Truncated=$true
    $result.Reason=if($result.Status -eq 'Encrypted'){'PDF 需要密码，正文未读取；可使用原应用解密副本后重建索引。'}else{'PDF 解析失败，已保留之前成功读取的正文；文件名搜索和预览仍可用。 '+$_.Exception.Message}
}finally{if($document){$document.Dispose()};Save-PdfWorkerCheckpoint}
