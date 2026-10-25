# Deterministic, user-data-free fixtures and isolated application copies for checks.
function New-SyntheticPdf {
    param([string]$Path,[string]$Label = 'Nailong synthetic PDF fixture')
    $ascii = [Text.Encoding]::ASCII
    $content = 'BT /F1 20 Tf 72 720 Td (' + $Label.Replace('(','[').Replace(')',']') + ') Tj ET'
    $objects = @(
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
        ('<< /Length ' + $ascii.GetByteCount($content) + " >>
stream
" + $content + "
endstream"),
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
    )
    $pdf = New-Object Text.StringBuilder
    [void]$pdf.Append("%PDF-1.4
")
    $offsets = New-Object Collections.ArrayList
    for ($index=0; $index -lt $objects.Count; $index++) {
        [void]$offsets.Add($ascii.GetByteCount($pdf.ToString()))
        [void]$pdf.Append(([string]($index+1) + " 0 obj
" + $objects[$index] + "
endobj
"))
    }
    $xref = $ascii.GetByteCount($pdf.ToString())
    [void]$pdf.Append("xref
0 6
0000000000 65535 f 
")
    foreach ($offset in $offsets) { [void]$pdf.Append(($offset.ToString('0000000000') + " 00000 n 
")) }
    [void]$pdf.Append(("trailer
<< /Size 6 /Root 1 0 R >>
startxref
" + $xref + "
%%EOF
"))
    [IO.File]::WriteAllBytes($Path,$ascii.GetBytes($pdf.ToString()))
}

function New-SyntheticFixtureSet {
    param([string]$Library)
    Add-Type -AssemblyName System.Drawing
    $folder = Join-Path $Library '物理'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    New-SyntheticPdf -Path (Join-Path $folder 'PDF预览测试.pdf') -Label 'Nailong PDF fixture A'
    New-SyntheticPdf -Path (Join-Path $folder '真实PDF预览测试.pdf') -Label 'Nailong PDF fixture B'
    [IO.File]::WriteAllText((Join-Path $folder 'search-fixture.txt'),'synthetic searchable physics fixture',[Text.Encoding]::UTF8)
    $imagePath = Join-Path $folder 'preview-fixture.png'
    $image = New-Object Drawing.Bitmap(640,360)
    $graphics = [Drawing.Graphics]::FromImage($image)
    $font = New-Object Drawing.Font('Arial',28,[Drawing.FontStyle]::Bold)
    $brush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(81,60,22))
    try {
        $graphics.Clear([Drawing.Color]::FromArgb(255,245,201))
        $graphics.DrawString('SYNTHETIC TEST IMAGE',$font,$brush,28,55)
        $graphics.DrawString('PHYSICS NEWTON FORCE',$font,$brush,28,145)
        $graphics.DrawRectangle([Drawing.Pens]::Goldenrod,12,12,614,334)
        $image.Save($imagePath,[Drawing.Imaging.ImageFormat]::Png)
    } finally { $brush.Dispose(); $font.Dispose(); $graphics.Dispose(); $image.Dispose() }
    return [pscustomobject]@{Pdf=(Join-Path $folder 'PDF预览测试.pdf');UiPdf=(Join-Path $folder '真实PDF预览测试.pdf');Image=$imagePath}
}

function New-IsolatedTestApplication {
    param([string]$SourceDir,[string]$RunDir)
    $app = Join-Path $RunDir 'app'
    $library = Join-Path $app 'test-library'
    New-Item -ItemType Directory -Path $app,$library,(Join-Path $app 'tests'),(Join-Path $app 'tools'),(Join-Path $app 'assets') -Force | Out-Null
    $manifest = [IO.File]::ReadAllText((Join-Path $SourceDir 'application-files.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($relative in $manifest) {
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') { throw 'Unsafe runtime manifest path.' }
        $destination = Join-Path $app $relative
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $SourceDir $relative) -Destination $destination
    }
    foreach ($name in @('application-files.json','config.example.json','README.md','RUNTIME.md','CHANGELOG.md')) { Copy-Item -LiteralPath (Join-Path $SourceDir $name) -Destination $app -Force }
    foreach ($directory in @('tests','tools')) {
        $from = Join-Path $SourceDir $directory
        if ([IO.Directory]::Exists($from)) {
            foreach ($file in @(Get-ChildItem -LiteralPath $from -File -Filter '*.ps1')) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $app $directory) }
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $SourceDir 'assets') -File)) {
        if ($file.Extension -in @('.png','.ico')) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $app 'assets') }
    }
    $config = [IO.File]::ReadAllText((Join-Path $SourceDir 'config.example.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json
    $config.inbox = $library
    $config.processExistingOnStartup = $true
    [IO.File]::WriteAllText((Join-Path $app 'config.json'),($config | ConvertTo-Json -Depth 20),[Text.Encoding]::UTF8)
    $fixtures = New-SyntheticFixtureSet -Library $library
    return [pscustomobject]@{AppDir=$app;Library=$library;Fixtures=$fixtures}
}

function Remove-IsolatedTestDirectory {
    param([string]$Path,[string]$AllowedParent)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $allowed = [IO.Path]::GetFullPath($AllowedParent).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($full) -ne $allowed -or [IO.Path]::GetFileName($full) -notmatch '^check-[a-f0-9]{32}$') { throw 'Refusing to clean an unrecognized test directory.' }
    $ancestor = New-Object IO.DirectoryInfo($allowed)
    while ($ancestor) {
        if ($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Refusing cleanup beneath a linked directory.' }
        $ancestor = $ancestor.Parent
    }
    function Remove-TestNode {
        param([string]$Node)
        $item = Get-Item -LiteralPath $Node -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                foreach ($child in @(Get-ChildItem -LiteralPath $Node -Force)) { Remove-TestNode -Node $child.FullName }
            }
            # Delete a junction itself, never enumerate or recursively delete its target.
            [IO.Directory]::Delete($Node)
        } else { [IO.File]::Delete($Node) }
    }
    if ([IO.Directory]::Exists($full)) { Remove-TestNode -Node $full }
}
