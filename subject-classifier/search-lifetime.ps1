# Window startup, capture and event loop.
$form.AcceptButton = $btnSearch

$form.Add_Shown({
    Update-Stats
    Invoke-Search
})

if ($null -ne $script:InitialCenter) {
    $targetScreen = [System.Windows.Forms.Screen]::FromPoint($script:InitialCenter)
    $wa = $targetScreen.WorkingArea
    $px = $script:InitialCenter.X - [int]($form.Width / 2)
    $py = $script:InitialCenter.Y - [int]($form.Height / 2)
    if ($px -lt $wa.Left) { $px = $wa.Left }
    if ($py -lt $wa.Top) { $py = $wa.Top }
    if (($px + $form.Width) -gt $wa.Right) { $px = $wa.Right - $form.Width }
    if (($py + $form.Height) -gt $wa.Bottom) { $py = $wa.Bottom - $form.Height }
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point($px, $py)
}

$script:RestartTimer = New-Object System.Windows.Forms.Timer
$script:RestartTimer.Interval = 700
$script:RestartTimer.Add_Tick({
    $script:RestartTimer.Stop()
    Restart-SearchWindow
})
$script:Restarting = $false
$script:PendingDpi = 0
$script:PendingCenter = $null
$form.Add_DpiChanged({
    param($s, $e)
    if ($script:Restarting) { return }
    $script:PendingDpi = [int]$e.DeviceDpiNew
    $script:PendingCenter = New-Object System.Drawing.Point(([int]($form.Left + ($form.Width / 2))), ([int]($form.Top + ($form.Height / 2))))
    $script:RestartTimer.Stop()
    $script:RestartTimer.Start()
})

if ($UiTestOutput) {
    . (Join-Path $PSScriptRoot 'tests\ui-responsive.ps1')
    exit
}

if (-not [string]::IsNullOrEmpty($Capture)) {
    $form.ShowInTaskbar = $false
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(20, 20)
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    if (-not [string]::IsNullOrEmpty($CaptureQuery)) {
        $txtQuery.ForeColor = $script:ColText
        $txtQuery.Text = $CaptureQuery
        Invoke-Search

    }
    $captureDeadline=(Get-Date).AddSeconds(25)
    do {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 60
    } while ($script:SearchJob -and (Get-Date) -lt $captureDeadline)
    if ($list.Items.Count -gt 0) { $list.Items[0].Selected=$true; Update-FilePreview }
    $captureDeadline=(Get-Date).AddSeconds(18)
    do {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 60
    } while (($previewDelay.Enabled -or ($script:PreviewJob -and -not $script:PreviewJob.Ready)) -and (Get-Date) -lt $captureDeadline)
    $paintDeadline=(Get-Date).AddSeconds(4)
    while((Get-Date) -lt $paintDeadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 60}
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)
    $captureGraphics=[Drawing.Graphics]::FromImage($bmp)
    try { $captureGraphics.CopyFromScreen($form.Left,$form.Top,0,0,$bmp.Size) } finally { $captureGraphics.Dispose() }
    $bmp.Save($Capture, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $form.Close()
    Write-Output ('captured ' + $Capture)
    exit
}

if ($SelfTestForm) {
    $form.Dispose()
    Write-Output 'search form build: ok'
    exit
}

[void]$form.ShowDialog()
$form.Dispose()
