param([string]$Output='')
$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
$run=Join-Path $source ('test-runs\ocr-'+[guid]::NewGuid().ToString('N'))
$app=Join-Path $run 'app';$library=Join-Path $run 'library'
New-Item -ItemType Directory -Path $app,$library -Force|Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
$checks=New-Object Collections.ArrayList;$skipped=New-Object Collections.ArrayList
function Check([string]$Name,[bool]$Passed){[void]$checks.Add(@{Name=$Name;Passed=$Passed});Write-Output ((@('FAIL','PASS')[[int]$Passed])+' '+$Name)}
function Skip([string]$Name,[string]$Reason){[void]$skipped.Add(@{Name=$Name;Reason=$Reason});Write-Output ('SKIP '+$Name+': '+$Reason)}
function New-OcrImage([string]$Path,[string]$Word){
    $image=New-Object Drawing.Bitmap(1600,420)
    $graphics=[Drawing.Graphics]::FromImage($image)
    $font=New-Object Drawing.Font('Arial',96,[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
    $memory=New-Object IO.MemoryStream
    try{
        $graphics.Clear([Drawing.Color]::White)
        $graphics.TextRenderingHint=[Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $graphics.DrawString($Word,$font,[Drawing.Brushes]::Black,55,100)
        $image.Save($Path,[Drawing.Imaging.ImageFormat]::Png)
        $image.Save($memory,[Drawing.Imaging.ImageFormat]::Jpeg)
        return [pscustomobject]@{Path=$Path;Jpeg=$memory.ToArray()}
    }finally{$memory.Dispose();$font.Dispose();$graphics.Dispose();$image.Dispose()}
}
function New-ImageOnlyPdf([string]$Path,[byte[][]]$Pages){
    $stream=New-Object IO.MemoryStream;$ascii=[Text.Encoding]::ASCII;$offsets=@{}
    function Write-Ascii([string]$Text){$bytes=$ascii.GetBytes($Text);$stream.Write($bytes,0,$bytes.Length)}
    function Write-Object([int]$Number,[string]$Text){$offsets[$Number]=$stream.Position;Write-Ascii ([string]$Number+" 0 obj
"+$Text+"
endobj
")}
    try{
        Write-Ascii "%PDF-1.4
"
        Write-Object 1 '<< /Type /Catalog /Pages 2 0 R >>'
        $kids=@();for($index=0;$index -lt $Pages.Count;$index++){$kids+=([string](3+$index*3)+' 0 R')}
        Write-Object 2 ('<< /Type /Pages /Kids ['+($kids -join ' ')+'] /Count '+$Pages.Count+' >>')
        for($index=0;$index -lt $Pages.Count;$index++){
            $pageNumber=3+$index*3;$imageNumber=$pageNumber+1;$contentNumber=$pageNumber+2
            Write-Object $pageNumber ('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 800 210] /Resources << /XObject << /Im0 '+$imageNumber+' 0 R >> >> /Contents '+$contentNumber+' 0 R >>')
            $offsets[$imageNumber]=$stream.Position
            $jpeg=$Pages[$index]
            Write-Ascii ([string]$imageNumber+" 0 obj
<< /Type /XObject /Subtype /Image /Width 1600 /Height 420 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length "+$jpeg.Length+" >>
stream
")
            $stream.Write($jpeg,0,$jpeg.Length);Write-Ascii "
endstream
endobj
"
            $content='q 800 0 0 210 0 0 cm /Im0 Do Q'
            Write-Object $contentNumber ('<< /Length '+$ascii.GetByteCount($content)+" >>
stream
"+$content+"
endstream")
        }
        $xref=$stream.Position;$count=2+$Pages.Count*3
        Write-Ascii ("xref
0 "+($count+1)+"
0000000000 65535 f 
")
        for($index=1;$index -le $count;$index++){Write-Ascii (([long]$offsets[$index]).ToString('0000000000')+" 00000 n 
")}
        Write-Ascii ("trailer
<< /Size "+($count+1)+" /Root 1 0 R >>
startxref
"+$xref+"
%%EOF
")
        [IO.File]::WriteAllBytes($Path,$stream.ToArray())
    }finally{$stream.Dispose()}
}
try{
    $manifest=[IO.File]::ReadAllText((Join-Path $source 'application-files.json'),$utf8)|ConvertFrom-Json
    foreach($relative in $manifest){$destination=Join-Path $app $relative;New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force|Out-Null;Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $destination}
    foreach($name in @('application-files.json','config.example.json')){Copy-Item -LiteralPath (Join-Path $source $name) -Destination $app -Force}
    $config=[IO.File]::ReadAllText((Join-Path $source 'config.example.json'),$utf8)|ConvertFrom-Json
    $config.inbox=$library
    Add-Member -InputObject $config -NotePropertyName ocr -NotePropertyValue ([pscustomobject]@{enabled=$false;maxPages=2;maxFileMiB=25;timeoutSeconds=12}) -Force
    [IO.File]::WriteAllText((Join-Path $app 'config.json'),($config|ConvertTo-Json -Depth 20),$utf8)
    . (Join-Path $app 'lib.ps1')
    Add-Type -AssemblyName System.Drawing
    $png=Join-Path $library 'ocr-fixture.png'
    $first=New-OcrImage -Path $png -Word 'NAILONG'
    $second=New-OcrImage -Path (Join-Path $library 'second-page.png') -Word 'SECONDPAGEONLY'
    $pdf=Join-Path $library 'image-only.pdf'
    New-ImageOnlyPdf -Path $pdf -Pages @($first.Jpeg,$second.Jpeg)
    $pngHash=(Get-FileHash -LiteralPath $png -Algorithm SHA256).Hash;$pdfHash=(Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash
    Check 'OCR stays disabled by default for generated images' ([string]::IsNullOrWhiteSpace((Get-OcrDocumentText -Path $png -Max 1000)))
    Check 'OCR stays disabled for a real image-only PDF' ([string]::IsNullOrWhiteSpace((Get-OcrDocumentText -Path $pdf -Max 1000)))
    $script:Cfg.ocr.enabled=$true
    $unsupported=Join-Path $library 'not-an-image.txt';[IO.File]::WriteAllBytes($unsupported,[IO.File]::ReadAllBytes($png))
    Check 'Unsupported extensions are rejected without OCR exceptions' ([string]::IsNullOrWhiteSpace((Get-OcrDocumentText -Path $unsupported -Max 1000)))
    Check 'Missing OCR source files return no text without throwing' ([string]::IsNullOrWhiteSpace((Get-OcrDocumentText -Path (Join-Path $library 'missing.png') -Max 1000)))
    $oversize=Join-Path $library 'oversize.png';[IO.File]::WriteAllBytes($oversize,[IO.File]::ReadAllBytes($png))
    $file=[IO.File]::OpenWrite($oversize);try{$file.SetLength(1MB+1)}finally{$file.Dispose()}
    $script:Cfg.ocr.maxFileMiB=1
    Check 'One byte above the configured file-size limit is rejected' ([string]::IsNullOrWhiteSpace((Get-OcrDocumentText -Path $oversize -Max 1000)))
    $exact=Join-Path $library 'exact-limit.png';[IO.File]::WriteAllBytes($exact,[IO.File]::ReadAllBytes($png))
    $file=[IO.File]::OpenWrite($exact);try{$file.SetLength(1MB)}finally{$file.Dispose()}
    $availability=Get-OcrAvailability
    Check 'OCR availability exposes an explicit reason when unavailable' ($availability.Available -or -not [string]::IsNullOrWhiteSpace([string]$availability.Reason))
    if($availability.Available){
        $text=Get-OcrDocumentText -Path $png -Max 1000
        Check 'Installed Windows OCR actually recognizes NAILONG from pixels' (([string]$text -replace '\s','').ToUpperInvariant().Contains('NAILONG'))
        $text=Get-OcrDocumentText -Path $exact -Max 1000
        Check 'A valid image at the exact file-size limit is accepted' (([string]$text -replace '\s','').ToUpperInvariant().Contains('NAILONG'))
        $text=Get-OcrDocumentText -Path $png -Max 4
        Check 'OCR respects the maximum returned-character boundary' (-not [string]::IsNullOrWhiteSpace($text) -and $text.Length -le 4)
        $script:Cfg.ocr.maxFileMiB=25;$script:Cfg.ocr.maxPages=1
        $text=Get-OcrDocumentText -Path $pdf -Max 1000
        $normalized=([string]$text -replace '\s','').ToUpperInvariant()
        Check 'Image-only PDF OCR reads its first page and honors maxPages one' ($normalized.Contains('NAILONG') -and -not $normalized.Contains('SECONDPAGEONLY'))
        $script:Cfg.ocr.maxPages=2
        $text=Get-OcrDocumentText -Path $pdf -Max 1000
        $normalized=([string]$text -replace '\s','').ToUpperInvariant()
        Check 'Raising the page limit allows real second-page OCR' ($normalized.Contains('NAILONG') -and $normalized.Contains('SECONDPAGEONLY'))
    }else{
        foreach($name in @('Real image OCR','Exact file-size boundary recognition','Returned-character boundary','Image-only PDF page limits')){Skip $name ([string]$availability.Reason)}
        Check 'Unavailable OCR degrades to empty text without throwing' ([string]::IsNullOrWhiteSpace((Get-OcrDocumentText -Path $png -Max 1000)))
    }
    Check 'OCR and all limit checks preserve original image and PDF bytes' ((Get-FileHash -LiteralPath $png -Algorithm SHA256).Hash -eq $pngHash -and (Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash -eq $pdfHash)
    Check 'OCR closes its source image and PDF handles' ((Test-FileReady $png) -and (Test-FileReady $pdf))
}catch{Check ('Unhandled OCR test error: '+$_.Exception.Message) $false;Write-Output $_.ScriptStackTrace}
$report=@{Passed=@($checks|Where-Object Passed).Count;Failed=@($checks|Where-Object {-not $_.Passed}).Count;Checks=@($checks.ToArray());SkippedCapabilities=@($skipped.ToArray());SyntheticFixtures=$true;Scratch=$run}
if(-not $Output){$Output=Join-Path $PSScriptRoot 'ocr-results.json'}
[IO.File]::WriteAllText($Output,($report|ConvertTo-Json -Depth 8),$utf8)
Write-Output ('TOTAL passed='+$report.Passed+' failed='+$report.Failed+' skipped='+$skipped.Count)
if($report.Failed){exit 1}
