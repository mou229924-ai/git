# Theme colors and reusable controls.
$script:IconPath = Join-Path $script:AppDir 'assets\app.ico'
$script:LogoPath = Join-Path $script:AppDir 'assets\logo.png'

$script:ColBg = [System.Drawing.Color]::FromArgb(255, 248, 226)
$script:ColSurface = [System.Drawing.Color]::FromArgb(255, 240, 194)
$script:ColSurface2 = [System.Drawing.Color]::FromArgb(249, 224, 160)
$script:ColBorder = [System.Drawing.Color]::FromArgb(230, 205, 145)
$script:ColSep = [System.Drawing.Color]::FromArgb(249, 237, 207)
$script:ColText = [System.Drawing.Color]::FromArgb(81, 60, 22)
$script:ColText2 = [System.Drawing.Color]::FromArgb(139, 114, 63)
$script:ColAccent = [System.Drawing.Color]::FromArgb(168, 107, 15)
$script:ColAccentHover = [System.Drawing.Color]::FromArgb(133, 83, 11)
$script:ColSelected = [System.Drawing.Color]::FromArgb(249, 217, 120)
$script:ColHover = [System.Drawing.Color]::FromArgb(255, 244, 212)
$script:ColChip = [System.Drawing.Color]::FromArgb(255, 240, 194)

$script:FontHeader = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)


function New-RoundButton {
    param([string]$Text, [string]$Kind = 'text')
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.UseVisualStyleBackColor = $false
    $b.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $b.AutoSize = $false
    $b.Padding = New-Object System.Windows.Forms.Padding((S 10), 0, (S 10), 0)
    $b.TextAlign = 'MiddleCenter'
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Kind -eq 'primary') {
        $baseColor = $script:ColAccent
        $hoverColor = $script:ColAccentHover
        $b.BackColor = $baseColor
        $b.ForeColor = [System.Drawing.Color]::FromArgb(255, 249, 231)
    } else {
        $baseColor = $script:ColBg
        $hoverColor = $script:ColSurface
        $b.BackColor = $baseColor
        $b.ForeColor = $script:ColAccent
    }
    $b.Add_MouseEnter({ param($s, $e) $s.BackColor = $hoverColor }.GetNewClosure())
    $b.Add_MouseLeave({ param($s, $e) $s.BackColor = $baseColor }.GetNewClosure())
    $b.Add_SizeChanged({ param($s, $e) Set-RoundedRegion -Control $s -Radius ([single]($s.Height / 2)) })
    return $b
}

function Format-Size {
    param([long]$Size)
    if ($Size -ge 1073741824) { return ('{0:N1} GB' -f ([double]$Size / 1073741824)) }
    if ($Size -ge 1048576) { return ('{0:N1} MB' -f ([double]$Size / 1048576)) }
    if ($Size -ge 1024) { return ('{0:N0} KB' -f ([double]$Size / 1024)) }
    return ([string]$Size + ' B')
}
