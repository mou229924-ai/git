. (Join-Path $PSScriptRoot 'pdf-text.ps1')

# Optional local OCR is used for images and PDF pages without a text layer.
function Get-OcrAvailability {
    try{
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null=[Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
        $engine=[Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        $languages=@([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object LanguageTag)
        if(-not $engine){return [pscustomobject]@{Available=$false;Languages=$languages;Reason='尚未安装与当前语言匹配的 Windows 文字识别语言包。'}}
        return [pscustomobject]@{Available=$true;Languages=$languages;Reason='本机 Windows 文字识别可用。'}
    } catch{return [pscustomobject]@{Available=$false;Languages=@();Reason='本机未提供 Windows 文字识别组件。'}}
}

function Wait-OcrOperation {
    param($Operation,[Type]$ResultType,[int]$Seconds=12)
    $method=[System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {$_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'} | Select-Object -First 1
    $task=$method.MakeGenericMethod($ResultType).Invoke($null,@($Operation))
    if(-not $task.Wait([Math]::Max(1,$Seconds)*1000)){try{$Operation.Cancel()}catch{};throw (New-Object TimeoutException('本机文字识别等待超时。'))}
    return $task.GetAwaiter().GetResult()
}

function Get-OcrImageText {
    param([string]$Path,[int]$Seconds=12)
    $null=[Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
    $null=[Windows.Graphics.Imaging.BitmapDecoder,Windows.Foundation,ContentType=WindowsRuntime]
    $null=[Windows.Graphics.Imaging.SoftwareBitmap,Windows.Foundation,ContentType=WindowsRuntime]
    $file=Wait-OcrOperation ([Windows.Storage.StorageFile]::GetFileFromPathAsync([IO.Path]::GetFullPath($Path))) ([Windows.Storage.StorageFile]) $Seconds
    $stream=$null;$bitmap=$null
    try{
        $stream=Wait-OcrOperation ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream]) $Seconds
        $decoder=Wait-OcrOperation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder]) $Seconds
        if($decoder.PixelWidth -gt [Windows.Media.Ocr.OcrEngine]::MaxImageDimension -or $decoder.PixelHeight -gt [Windows.Media.Ocr.OcrEngine]::MaxImageDimension){return $null}
        $bitmap=Wait-OcrOperation ($decoder.GetSoftwareBitmapAsync([Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,[Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied)) ([Windows.Graphics.Imaging.SoftwareBitmap]) $Seconds
        $engine=[Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        if(-not $engine){return $null}
        $result=Wait-OcrOperation ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult]) $Seconds
        return [string]$result.Text
    }finally{if($bitmap){$bitmap.Dispose()};if($stream){$stream.Dispose()}}
}

function Get-OcrDocumentText {
    param([string]$Path,[int]$Max=60000,[int[]]$PageIndices)
    if(-not $script:Cfg.ocr -or -not $script:Cfg.ocr.enabled){return $null}
    $extension=[IO.Path]::GetExtension($Path).ToLowerInvariant()
    if($extension -notin @('.pdf','.png','.jpg','.jpeg','.bmp','.tif','.tiff')){return $null}
    $file=Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if(-not $file -or $file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -eq 0){return $null}
    $cap=25;if($script:Cfg.ocr.maxFileMiB){$cap=[Math]::Max(1,[Math]::Min(100,[int]$script:Cfg.ocr.maxFileMiB))}
    if($file.Length -gt $cap*1MB){return $null}
    if(-not (Get-OcrAvailability).Available){return $null}
    $seconds=12;if($script:Cfg.ocr.timeoutSeconds){$seconds=[Math]::Max(1,[Math]::Min(30,[int]$script:Cfg.ocr.timeoutSeconds))}
    try{
        $text=''
        if($extension -eq '.pdf'){
            $limit=2;if($script:Cfg.ocr.maxPages){$limit=[Math]::Max(1,[Math]::Min(10,[int]$script:Cfg.ocr.maxPages))}
            $selected=@(0..($limit-1));if($PSBoundParameters.ContainsKey('PageIndices')){$selected=@($PageIndices | Where-Object {$_ -ge 0} | Select-Object -Unique -First $limit)}
            foreach($page in $selected){
                $render=Get-PdfPageImage -Path $Path -PageIndex $page
                $temporary=Join-Path ([IO.Path]::GetTempPath()) ('nailong-ocr-'+[guid]::NewGuid().ToString('N')+'.png')
                try{$render.Image.Save($temporary,[Drawing.Imaging.ImageFormat]::Png);$text+=(Get-OcrImageText -Path $temporary -Seconds $seconds)+[Environment]::NewLine}
                finally{$render.Image.Dispose();if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
                if($text.Length -ge $Max -or $page+1 -ge $render.Pages){break}
            }
        } else{$text=Get-OcrImageText -Path $Path -Seconds $seconds}
        if($text -and $text.Length -gt $Max){return $text.Substring(0,$Max)}
        return $text
    }catch{Write-Log ('OCR unavailable for '+[IO.Path]::GetFileName($Path)+': '+$_.Exception.Message);return $null}
}
