param([string]$Output = '',[string]$Report = '',[string]$SourceDir = (Split-Path $PSScriptRoot -Parent),[string]$ScratchBase = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-support.ps1')
if (-not $ScratchBase) { $ScratchBase = Join-Path $SourceDir 'test-runs' }
$run = Join-Path $ScratchBase ('check-' + [guid]::NewGuid().ToString('N'))
$checks = New-Object Collections.ArrayList
function Check([string]$Name,[bool]$Passed) {
    [void]$checks.Add(@{Name=$Name;Passed=$Passed})
    Write-Output ((@('FAIL','PASS')[[int]$Passed])+' '+$Name)
}
try {
    $installation = New-IsolatedTestApplication -SourceDir $SourceDir -RunDir $run
    . (Join-Path $installation.AppDir 'lib.ps1')
    $pdf = $installation.Fixtures.Pdf
    $imageFile = $installation.Fixtures.Image
    $pdfHash = (Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash
    $imageHash = (Get-FileHash -LiteralPath $imageFile -Algorithm SHA256).Hash
    Check 'Synthetic PDF has a real PDF header and cross-reference table' ([IO.File]::ReadAllText($pdf).StartsWith('%PDF-1.4') -and [IO.File]::ReadAllText($pdf).Contains('startxref'))
    $page = Get-PdfPageImage -Path $pdf
    try {
        Check 'Windows PDF renderer opens the generated one-page fixture' ($page.Pages -eq 1 -and $page.Image.Width -gt 100 -and $page.Image.Height -gt 100)
        Check 'Rendered PDF page preserves its portrait aspect ratio' ($page.Image.Height -gt $page.Image.Width)
        if ($Output) { $page.Image.Save($Output,[Drawing.Imaging.ImageFormat]::Png) }
    } finally { $page.Image.Dispose() }
    $image = [Drawing.Image]::FromFile($imageFile)
    try { Check 'Synthetic PNG decodes at its expected resolution' ($image.Width -eq 640 -and $image.Height -eq 360) }
    finally { $image.Dispose() }
    Check 'Preview renderers release both source file handles' ((Test-FileReady $pdf) -and (Test-FileReady $imageFile))
    Check 'PDF and image preview leave all source bytes unchanged' ((Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash -eq $pdfHash -and (Get-FileHash -LiteralPath $imageFile -Algorithm SHA256).Hash -eq $imageHash)
} catch { Check ('Preview fixture error: '+$_.Exception.Message) $false; Write-Output $_.ScriptStackTrace }
finally {
    $summary = @{Passed=@($checks|Where-Object Passed).Count;Failed=@($checks|Where-Object {-not $_.Passed}).Count;Checks=@($checks.ToArray());SyntheticFixtures=$true}
    if (-not $Report) { $Report = Join-Path $PSScriptRoot 'preview-results.json' }
    [IO.File]::WriteAllText($Report,($summary|ConvertTo-Json -Depth 5),[Text.Encoding]::UTF8)
    Remove-IsolatedTestDirectory -Path $run -AllowedParent $ScratchBase
    Write-Output ('TOTAL passed='+$summary.Passed+' failed='+$summary.Failed)
}
if ($summary.Failed) { exit 1 }
