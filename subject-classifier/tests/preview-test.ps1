param([string]$Output = '')
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib.ps1')
$file = Join-Path $script:Root '物理\PDF预览测试.pdf'
$image = Get-PdfPreviewImage $file
try {
    if ($image.Width -le 0 -or $image.Height -le 0) { throw 'PDF preview returned no image' }
    if ($Output) { $image.Save($Output, [Drawing.Imaging.ImageFormat]::Png) }
    Write-Output ('PDF preview passed: ' + $image.Width + 'x' + $image.Height)
} finally { $image.Dispose() }
