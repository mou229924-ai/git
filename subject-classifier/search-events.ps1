# File list commands and context menu.
$btnSearch.Add_Click({ Invoke-Search })
$btnRebuild.Add_Click({ Invoke-Rebuild })
$btnOpenRoot.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:Root + '"') })

$list.Add_DoubleClick({
    if ($list.SelectedItems.Count -gt 0) {
        $p = [string]$list.SelectedItems[0].Tag
        if (Test-Path -LiteralPath $p) { Start-Process -FilePath $p }
    }
})

$ctx = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = New-Object System.Windows.Forms.ToolStripMenuItem
$miOpen.Text = [string]$script:Cfg.search.menuOpen
$miOpen.Add_Click({
    if ($list.SelectedItems.Count -gt 0) {
        $p = [string]$list.SelectedItems[0].Tag
        if (Test-Path -LiteralPath $p) { Start-Process -FilePath $p }
    }
})
[void]$ctx.Items.Add($miOpen)
$miLocate = New-Object System.Windows.Forms.ToolStripMenuItem
$miLocate.Text = [string]$script:Cfg.search.menuLocate
$miLocate.Add_Click({
    if ($list.SelectedItems.Count -gt 0) {
        $p = [string]$list.SelectedItems[0].Tag
        if (Test-Path -LiteralPath $p) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $p + '"') }
    }
})
[void]$ctx.Items.Add($miLocate)
$miCopy = New-Object System.Windows.Forms.ToolStripMenuItem
$miCopy.Text = [string]$script:Cfg.search.menuCopy
$miCopy.Add_Click({
    if ($list.SelectedItems.Count -gt 0) {
        [System.Windows.Forms.Clipboard]::SetText([string]$list.SelectedItems[0].Tag)
    }
})
[void]$ctx.Items.Add($miCopy)
$list.ContextMenuStrip = $ctx
