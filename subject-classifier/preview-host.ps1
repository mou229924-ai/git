param([string]$File,[long]$ParentHandle,[int]$Width=500,[int]$Height=600,[string]$Status,[switch]$ForceFallback,[int]$Page=0)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('Nailong.Native' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'NativePreview.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing }
$window=New-Object Windows.Forms.Form
$window.FormBorderStyle='None'; $window.ShowInTaskbar=$false
$window.StartPosition='Manual'; $window.Location=New-Object Drawing.Point(-4000,-4000)
$window.ClientSize=New-Object Drawing.Size($Width,$Height); $window.BackColor=[Drawing.Color]::White
$nativePanel=New-Object Nailong.PreviewPanel
$nativePanel.Dock='Fill'; $window.Controls.Add($nativePanel)
$window.Show()
if ($ParentHandle) {
    $null=[Nailong.Native]::SetParent($window.Handle,[IntPtr]$ParentHandle)
    $style=[Nailong.Native]::GetWindowLong($window.Handle,-16)
    $null=[Nailong.Native]::SetWindowLong($window.Handle,-16,(($style -band -2147483649) -bor 0x40000000))
    $null=[Nailong.Native]::MoveWindow($window.Handle,0,0,$Width,$Height,$true)
}
try {
    $mode='native'; $pages=0
    try {
        if ($ForceFallback) { throw 'Fallback requested' }
        $nativePanel.OpenFile([IO.Path]::GetFullPath($File))
    } catch {
        $nativePanel.CloseFile(); $nativePanel.Visible=$false
        $scroll=New-Object Windows.Forms.Panel; $scroll.Dock='Fill'; $scroll.AutoScroll=$true
        $window.Controls.Add($scroll); $scroll.BringToFront()
        $extension=[IO.Path]::GetExtension($File).ToLowerInvariant()
        if ($extension -eq '.pdf') {
            $info=Get-PdfPageImage -Path $File -PageIndex $Page
            $image=$info.Image; $pages=$info.Pages; $mode='pdf'
        } elseif (@('.png','.jpg','.jpeg','.gif','.bmp') -contains $extension) {
            $original=[Drawing.Image]::FromFile($File)
            try { $image=New-Object Drawing.Bitmap($original) } finally { $original.Dispose() }
            $mode='image'
        } else {
            $text=Get-FileText -Path $File -Max 120000
            if (-not $text) { throw '系统没有可用的此格式预览器。请点击“打开文件”。' }
            $box=New-Object Windows.Forms.TextBox
            $box.Dock='Fill'; $box.Multiline=$true; $box.ReadOnly=$true; $box.ScrollBars='Both'; $box.WordWrap=$true
            $box.Font=New-Object Drawing.Font('Microsoft YaHei UI',11); $box.BorderStyle='None'; $box.Text=$text
            $scroll.Controls.Add($box); $mode='text'
        }
        if ($image) {
            $picture=New-Object Windows.Forms.PictureBox
            $picture.Image=$image; $picture.SizeMode='StretchImage'
            $ratio=[Math]::Min(1.0,([double]($Width-24)/$image.Width))
            $picture.Width=[int]($image.Width*$ratio); $picture.Height=[int]($image.Height*$ratio)
            $picture.Location=New-Object Drawing.Point(8,8); $scroll.Controls.Add($picture)
            $scroll.Add_MouseWheel({
                param($sender,$eventArgs)
                if ([Windows.Forms.Control]::ModifierKeys -band [Windows.Forms.Keys]::Control) {
                    $factor=1.15; if($eventArgs.Delta -lt 0){$factor=1/1.15}
                    $picture.Width=[Math]::Max(100,[int]($picture.Width*$factor)); $picture.Height=[Math]::Max(100,[int]($picture.Height*$factor))
                }
            }.GetNewClosure())
        }
    }
    Write-AtomicUtf8 $Status (@{ State='ready'; Handle=$window.Handle.ToInt64(); Mode=$mode; Pages=$pages; Page=$Page } | ConvertTo-Json)
    [Windows.Forms.Application]::Run($window)
} catch {
    Write-AtomicUtf8 $Status (@{ State='failed'; Error=$_.Exception.Message } | ConvertTo-Json)
} finally { $nativePanel.Dispose(); if($image){$image.Dispose()}; $window.Dispose() }
