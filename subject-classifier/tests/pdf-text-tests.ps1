param([string]$Output='')
$ErrorActionPreference = 'Stop'
$source = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'test-support.ps1')
$parent = Join-Path ([IO.Path]::GetTempPath()) 'Nailong-pdf-tests'
$run = Join-Path $parent ('check-'+[guid]::NewGuid().ToString('N'))
$app = Join-Path $run 'app'
$library = Join-Path $run 'library'
$utf8 = New-Object Text.UTF8Encoding($false)
$checks = New-Object Collections.ArrayList
$skipped = New-Object Collections.ArrayList
function Check([string]$Name,[bool]$Passed) {
    [void]$checks.Add(@{Name=$Name;Passed=$Passed})
    Write-Output ((@('FAIL','PASS')[[int]$Passed])+' '+$Name)
}
function Optional-Hash([string]$Path) { if ([IO.File]::Exists($Path)) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash };return '' }
$originalConfig = Optional-Hash (Join-Path $source 'config.json')
$originalGate = Optional-Hash (Join-Path $source 'tests\verified.json')
Add-Type -AssemblyName System.IO.Compression,System.Drawing
if (-not ('NailongPdfFixtures' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Text;
public static class NailongPdfFixtures {
    private static readonly Encoding Ascii=Encoding.ASCII;
    private static byte[] Bytes(string text) {return Ascii.GetBytes(text);}
    private static byte[] Deflate(byte[] input) {
        using(MemoryStream raw=new MemoryStream()) {
            using(DeflateStream stream=new DeflateStream(raw,CompressionMode.Compress,true)) {stream.Write(input,0,input.Length);}
            byte[] compressed=raw.ToArray();byte[] result=new byte[compressed.Length+6];
            result[0]=0x78;result[1]=0x9c;Buffer.BlockCopy(compressed,0,result,2,compressed.Length);
            uint a=1,b=0;foreach(byte value in input){a=(a+value)%65521;b=(b+a)%65521;}
            uint sum=(b<<16)|a;for(int i=0;i<4;i++)result[result.Length-4+i]=(byte)(sum>>(24-8*i));
            return result;
        }
    }
    private static byte[] Stream(byte[] content,bool compress) {
        byte[] payload=compress?Deflate(content):content;
        using(MemoryStream output=new MemoryStream()) {
            byte[] header=Bytes("<< /Length "+payload.Length+(compress?" /Filter /FlateDecode":"")+" >>\nstream\n");
            output.Write(header,0,header.Length);output.Write(payload,0,payload.Length);
            byte[] trailer=Bytes("\nendstream");output.Write(trailer,0,trailer.Length);return output.ToArray();
        }
    }
    public static void Write(string path,string[] pages,bool compressed) {
        List<byte[]> objects=new List<byte[]>();objects.Add(Bytes("<< /Type /Catalog /Pages 2 0 R >>"));
        StringBuilder kids=new StringBuilder();for(int i=0;i<pages.Length;i++)kids.Append((8+2*i)+" 0 R ");
        objects.Add(Bytes("<< /Type /Pages /Kids ["+kids+"] /Count "+pages.Length+" >>"));
        objects.Add(Bytes("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"));
        objects.Add(Bytes("<< /Type /Font /Subtype /Type0 /BaseFont /FixtureCJK /Encoding /Identity-H /DescendantFonts [5 0 R] /ToUnicode 7 0 R >>"));
        objects.Add(Bytes("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /FixtureCJK /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 6 0 R /DW 1000 /CIDToGIDMap /Identity >>"));
        objects.Add(Bytes("<< /Type /FontDescriptor /FontName /FixtureCJK /Flags 4 /FontBBox [0 -200 1000 1000] /ItalicAngle 0 /Ascent 880 /Descent -120 /CapHeight 700 /StemV 80 >>"));
        SortedSet<char> chars=new SortedSet<char>();foreach(string text in pages)foreach(char value in text)if(value>127)chars.Add(value);
        StringBuilder cmap=new StringBuilder("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /FixtureUnicode def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
        cmap.Append(chars.Count+" beginbfchar\n");foreach(char value in chars){string hex=((int)value).ToString("X4",CultureInfo.InvariantCulture);cmap.Append("<"+hex+"> <"+hex+">\n");}
        cmap.Append("endbfchar\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");objects.Add(Stream(Bytes(cmap.ToString()),compressed));
        for(int i=0;i<pages.Length;i++) {
            objects.Add(Bytes("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents "+(9+2*i)+" 0 R >>"));
            StringBuilder latin=new StringBuilder(),cjk=new StringBuilder();foreach(char value in pages[i]){if(value>127)cjk.Append(((int)value).ToString("X4",CultureInfo.InvariantCulture));else latin.Append(value);}
            string escaped=latin.ToString().Replace("\\","\\\\").Replace("(","\\(").Replace(")","\\)");
            string content="BT /F1 16 Tf 36 740 Td ("+escaped+") Tj 0 -28 Td /F2 16 Tf <"+cjk+"> Tj ET";
            objects.Add(Stream(Bytes(content),compressed));
        }
        using(MemoryStream pdf=new MemoryStream()) {
            List<long> offsets=new List<long>();byte[] header=Bytes("%PDF-1.4\n");pdf.Write(header,0,header.Length);
            for(int i=0;i<objects.Count;i++){offsets.Add(pdf.Position);byte[] before=Bytes((i+1)+" 0 obj\n"),after=Bytes("\nendobj\n");pdf.Write(before,0,before.Length);pdf.Write(objects[i],0,objects[i].Length);pdf.Write(after,0,after.Length);}
            long xref=pdf.Position;StringBuilder tail=new StringBuilder("xref\n0 "+(objects.Count+1)+"\n0000000000 65535 f \n");
            foreach(long offset in offsets)tail.Append(offset.ToString("0000000000",CultureInfo.InvariantCulture)+" 00000 n \n");
            tail.Append("trailer\n<< /Size "+(objects.Count+1)+" /Root 1 0 R >>\nstartxref\n"+xref+"\n%%EOF\n");byte[] bytes=Bytes(tail.ToString());pdf.Write(bytes,0,bytes.Length);File.WriteAllBytes(path,pdf.ToArray());
        }
    }
}
'@
}
try {
    [void][IO.Directory]::CreateDirectory($app)
    [void][IO.Directory]::CreateDirectory($library)
    $manifest = [IO.File]::ReadAllText((Join-Path $source 'application-files.json'),$utf8) | ConvertFrom-Json
    $files = @($manifest)+@('pdf-text.ps1','pdf-text-worker.ps1')
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $source 'third-party\pdfpig') -File)) { $files += 'third-party/pdfpig/'+$file.Name }
    foreach ($relative in @($files|Select-Object -Unique)) {
        $target = Join-Path $app $relative
        [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
        Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $target
    }
    Copy-Item -LiteralPath (Join-Path $source 'application-files.json') -Destination $app
    $config = [IO.File]::ReadAllText((Join-Path $source 'config.example.json'),$utf8) | ConvertFrom-Json
    $config.inbox=$library;$config.ocr.enabled=$false;$config.processExistingOnStartup=$false
    [IO.File]::WriteAllText((Join-Path $app 'config.json'),($config|ConvertTo-Json -Depth 20),$utf8)
    . (Join-Path $app 'lib.ps1')
    $pdf = Join-Path $library '中文 空格;O''Brien`试卷.pdf'
    [NailongPdfFixtures]::Write($pdf,[string[]]@('COMPRESSEDSENTINEL 中文试卷正文','SECONDPAGESENTINEL 物理力学'),$true)
    $originalPdfHash=Optional-Hash $pdf
    $availability=Get-PdfTextAvailability
    Check 'Bundled PDF extractor and all offline dependencies are available' $availability.Available
    Check 'Availability inspects its explicit target application rather than the source tree' (-not (Get-PdfTextAvailability -Directory $run).Available)
    $result=Get-PdfTextExtraction -Path $pdf -Max 60000
    Check 'OCR-disabled compressed PDF text is extracted by the real independent worker' ($result.Status -eq 'Complete' -and $result.Text.Contains('COMPRESSEDSENTINEL') -and -not $script:Cfg.ocr.enabled)
    Check 'A ToUnicode CMap preserves real Chinese PDF text' ($result.Text.Contains('中文试卷正文'))
    Check 'Multiple text-layer pages are preserved with accurate page counts' ($result.TotalPages -eq 2 -and $result.ProcessedPages -eq 2 -and $result.Text.Contains('SECONDPAGESENTINEL'))
    $limited=Get-PdfTextExtraction -Path $pdf -Max 17
    Check 'A character limit returns useful bounded partial text' ($limited.Text.Length -eq 17 -and $limited.Status -eq 'Partial' -and $limited.Truncated)
    $script:Cfg.pdfText.maxPages=1
    $one=Get-PdfTextExtraction -Path $pdf -Max 60000
    Check 'A page limit retains the first page and reports the unprocessed remainder' ($one.ProcessedPages -eq 1 -and $one.TotalPages -eq 2 -and $one.Status -eq 'Partial' -and $one.Text.Contains('COMPRESSEDSENTINEL') -and -not $one.Text.Contains('SECONDPAGESENTINEL'))
    $script:Cfg.pdfText.maxPages=100
    $ocrAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'ocr-tests.ps1'),[ref]$null,[ref]$null)
    foreach($functionName in @('New-OcrImage','New-ImageOnlyPdf')) {
        $definition=$ocrAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName}.GetNewClosure(),$true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $scan=Join-Path $library '扫描页.pdf'
    $image=New-OcrImage -Path (Join-Path $run 'scan.png') -Word 'NEWTON'
    # An explicit jagged array preserves one JPEG as one PDF page in Windows PowerShell.
    $singleImagePage = New-Object 'byte[][]' 1
    $singleImagePage[0] = [byte[]]$image.Jpeg
    New-ImageOnlyPdf -Path $scan -Pages $singleImagePage
    $scanHash=Optional-Hash $scan
    $empty=Get-PdfTextExtraction -Path $scan
    if($empty.Status -ne 'NoTextLayer' -or $empty.EmptyPages.Count -ne 1){Write-Output ($empty|Select-Object Status,Reason,TotalPages,ProcessedPages,EmptyPages,OcrPages|ConvertTo-Json -Depth 4 -Compress)}
    Check 'An image-only PDF reports the missing text layer without silently inventing text' ($empty.Status -eq 'NoTextLayer' -and -not $empty.Text -and $empty.EmptyPages.Count -eq 1 -and $empty.OcrPages -eq 0)
    $ocrAvailability=Get-OcrAvailability
    if ($ocrAvailability.Available) {
        $script:Cfg.ocr.enabled=$true
        $recognized=Get-PdfTextExtraction -Path $scan
        if($recognized.Text -notmatch 'NEWTON' -or $recognized.OcrPages -ne 1){Write-Output ($recognized|Select-Object Status,Reason,TotalPages,ProcessedPages,EmptyPages,OcrPages,Text|ConvertTo-Json -Depth 4 -Compress)}
        Check 'The independent PDF worker can OCR an actual image-only page when explicitly enabled' ($recognized.Text -match 'NEWTON' -and $recognized.OcrPages -eq 1)
        $script:Cfg.ocr.enabled=$false
    } else { [void]$skipped.Add('Image-only PDF OCR: '+$ocrAvailability.Reason) }
    $broken=Join-Path $run 'broken.pdf';[IO.File]::WriteAllText($broken,'not a PDF',$utf8)
    $invalid=Get-PdfTextExtraction -Path $broken
    Check 'A malformed PDF reports failure without blocking or changing the original' ($invalid.Status -eq 'Failed' -and -not $invalid.Text -and [IO.File]::ReadAllText($broken) -eq 'not a PDF')
    Check 'A missing PDF returns an explicit invalid-input result' ((Get-PdfTextExtraction -Path (Join-Path $run 'missing.pdf')).Status -eq 'InvalidInput')
    $large=Join-Path $run 'large.pdf';$stream=[IO.File]::Open($large,'CreateNew','Write');try{$stream.SetLength(2MB)}finally{$stream.Dispose()}
    $script:Cfg.pdfText.maxFileMiB=1
    Check 'The size limit rejects an oversized file before starting extraction' ((Get-PdfTextExtraction -Path $large).Status -eq 'SizeLimit')
    $script:Cfg.pdfText.maxFileMiB=25
    $script:Cfg.pdfText.maxPages=999;$script:Cfg.pdfText.timeoutSeconds=999;$script:Cfg.pdfText.maxMemoryMiB=999;$script:Cfg.pdfText.maxFileMiB=999
    $bounds=Get-PdfTextLimits
    Check 'Untrusted limit settings are clamped to the supported hard ceilings' ($bounds.MaxPages -eq 500 -and $bounds.TimeoutSeconds -eq 60 -and $bounds.MaxMemoryMiB -eq 512 -and $bounds.MaxFileMiB -eq 100)
    $script:Cfg.pdfText.maxPages=100;$script:Cfg.pdfText.timeoutSeconds=15;$script:Cfg.pdfText.maxMemoryMiB=256;$script:Cfg.pdfText.maxFileMiB=25
    $initial=Sync-LibraryIndex
    Check 'PDF body text becomes searchable while OCR remains disabled' (@(Search-Index -Query 'COMPRESSEDSENTINEL').Count -eq 1 -and -not $script:Cfg.ocr.enabled)
    Check 'Chinese text-layer content participates in the actual search index' (@(Search-Index -Query '中文试卷正文').Count -eq 1)
    $entries=@(Load-IndexEntries);$legacy=@($entries|Where-Object name -eq ([IO.Path]::GetFileName($pdf)))[0]
    $legacy.hasText=$false;$legacy.textKey='';$legacy.PSObject.Properties.Remove('extractorVersion')
    $null=Save-IndexEntries -Entries $entries
    $script:PdfExtractionCalls=@{}
    $savedGetText=(Get-Command Get-FileText).ScriptBlock
    function Get-FileText {
        param([string]$Path,[int]$Max=0)
        if(-not $script:PdfExtractionCalls.ContainsKey($Path)){$script:PdfExtractionCalls[$Path]=0}
        $script:PdfExtractionCalls[$Path]++
        & $savedGetText -Path $Path -Max $Max
    }
    try {
        $null=Sync-LibraryIndex -Incremental
        Check 'A formerly empty legacy PDF is re-extracted once without re-reading unchanged files' ($script:PdfExtractionCalls.Count -eq 1 -and $script:PdfExtractionCalls[$pdf] -eq 1 -and @(Search-Index -Query 'COMPRESSEDSENTINEL').Count -eq 1)
        $script:PdfExtractionCalls.Clear();$null=Sync-LibraryIndex -Incremental
        Check 'An unchanged PDF and an empty scanned PDF do not repeatedly reparse or invoke OCR' ($script:PdfExtractionCalls.Count -eq 0 -and -not $script:Cfg.ocr.enabled)
    } finally {Set-Item Function:\Get-FileText -Value $savedGetText}
    $scanEntry=@(Load-IndexEntries|Where-Object name -eq ([IO.Path]::GetFileName($scan)))[0]
    Check 'Empty PDF index entries retain extractor version and a useful no-text diagnosis' (-not $scanEntry.hasText -and $scanEntry.extractorVersion -eq (Get-PdfTextExtractorVersion) -and $scanEntry.extractionStatus -eq 'NoTextLayer')
    $checkpointDir=Join-Path $run 'checkpoint';[void][IO.Directory]::CreateDirectory($checkpointDir)
    $completeSlot=@{CheckpointSequence=2;Text='verified-previous-page';Status='Partial'}|ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $checkpointDir 'result.json'),$completeSlot,$utf8)
    [IO.File]::WriteAllText((Join-Path $checkpointDir 'result.previous.json'),'{interrupted JSON',$utf8)
    Check 'A damaged newest checkpoint does not discard the previous complete page text' ((Read-PdfTextCheckpoint -Directory $checkpointDir -MaxChars 60000).Text -eq 'verified-previous-page')
    [IO.File]::WriteAllText((Join-Path $checkpointDir 'result.previous.json'),(@{CheckpointSequence=3;Text='newest-complete-page';Status='Partial'}|ConvertTo-Json -Compress),$utf8)
    Check 'When both checkpoints are valid the greatest sequence wins' ((Read-PdfTextCheckpoint -Directory $checkpointDir -MaxChars 60000).Text -eq 'newest-complete-page')
    $fakeWorker=Join-Path $run 'bounded-worker.ps1'
    $fakeBody=@'
param([string]$Request)
$ErrorActionPreference='Stop'
$job=Get-Content -LiteralPath $Request -Raw|ConvertFrom-Json
$utf8=New-Object Text.UTF8Encoding($false)
$result=@{CheckpointSequence=1;Text='partial-before-resource-limit';Status='Partial';Reason='synthetic progress';TotalPages=3;ProcessedPages=1;EmptyPages=@();FailedPages=@();Truncated=$true;OcrPages=0}
[IO.File]::WriteAllText($job.ResultPath,($result|ConvertTo-Json -Compress),$utf8)
if($job.Ocr.timeoutSeconds -eq 29){$allocation=New-Object byte[] (200MB);for($i=0;$i -lt $allocation.Length;$i+=4096){$allocation[$i]=1}}
Start-Sleep -Seconds 30
'@
    [IO.File]::WriteAllText($fakeWorker,$fakeBody,$utf8)
    $realAvailability=(Get-Command Get-PdfTextAvailability).ScriptBlock
    function Get-PdfTextAvailability {return [pscustomobject]@{Available=$true;Worker=$fakeWorker;HostPath=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')}}
    try {
        $script:Cfg.pdfText.timeoutSeconds=3;$script:Cfg.pdfText.maxMemoryMiB=512
        $timer=[Diagnostics.Stopwatch]::StartNew();$timed=Get-PdfTextExtraction -Path $pdf;$timer.Stop()
        Check 'A stalled independent extractor is terminated within its bounded deadline and preserves completed page text' ($timer.Elapsed.TotalSeconds -lt 9 -and $timed.Status -eq 'Partial' -and $timed.Reason -match '等待时间' -and $timed.Text -eq 'partial-before-resource-limit')
        $script:Cfg.pdfText.timeoutSeconds=10;$script:Cfg.pdfText.maxMemoryMiB=96;$script:Cfg.ocr.timeoutSeconds=29
        $timer=[Diagnostics.Stopwatch]::StartNew();$memory=Get-PdfTextExtraction -Path $pdf;$timer.Stop()
        Check 'The parent monitors and terminates an oversized child without blocking on its output streams' ($timer.Elapsed.TotalSeconds -lt 9 -and $memory.Status -in @('Partial','ResourceLimit') -and $memory.Reason -match '内存')
    } finally {Set-Item Function:\Get-PdfTextAvailability -Value $realAvailability}
    Check 'PDF extraction, index migration and OCR leave original PDF bytes unchanged' ((Optional-Hash $pdf) -eq $originalPdfHash -and (Optional-Hash $scan) -eq $scanHash)
    Check 'PDF tests preserve the source configuration and production dedupe verification' ((Optional-Hash (Join-Path $source 'config.json')) -eq $originalConfig -and (Optional-Hash (Join-Path $source 'tests\verified.json')) -eq $originalGate)
} catch {
    Check ('Unhandled PDF regression error: '+$_.Exception.Message) $false
    Write-Output $_.ScriptStackTrace
} finally {
    if(-not $Output){$Output=Join-Path $PSScriptRoot 'pdf-text-results.json'}
    $report=@{Passed=@($checks|Where-Object Passed).Count;Failed=@($checks|Where-Object {-not $_.Passed}).Count;Checks=@($checks.ToArray());Skipped=@($skipped.ToArray());OfflineDependencies=$true;UserConfigurationUnchanged=((Optional-Hash (Join-Path $source 'config.json')) -eq $originalConfig);ProductionGateUnchanged=((Optional-Hash (Join-Path $source 'tests\verified.json')) -eq $originalGate)}
    [IO.File]::WriteAllText($Output,($report|ConvertTo-Json -Depth 6),$utf8)
    Remove-IsolatedTestDirectory -Path $run -AllowedParent $parent
}
Write-Output ('PDF TEXT passed='+$report.Passed+' failed='+$report.Failed+' skipped='+$report.Skipped.Count)
if($report.Failed){exit 1}
