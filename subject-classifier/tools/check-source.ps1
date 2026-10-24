param([string]$SourceDir = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$manifest = [IO.File]::ReadAllText((Join-Path $SourceDir 'application-files.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json
$runtime = @($manifest | Where-Object { [IO.Path]::GetExtension($_) -eq '.ps1' })
$files = New-Object Collections.ArrayList
foreach ($relative in $runtime) { [void]$files.Add((Join-Path $SourceDir $relative)) }
foreach ($directory in @('tests','tools')) {
    $path = Join-Path $SourceDir $directory
    if ([IO.Directory]::Exists($path)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $path -File -Filter '*.ps1')) { [void]$files.Add($file.FullName) }
    }
}
$problems = New-Object Collections.ArrayList
foreach ($file in @($files | Select-Object -Unique)) {
    $bytes = [IO.File]::ReadAllBytes($file)
    $relative = $file.Substring([IO.Path]::GetFullPath($SourceDir).TrimEnd('\').Length+1)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { [void]$problems.Add($relative+': PowerShell 5.1 sources require UTF-8 BOM.') }
    if ($bytes.Length -ge 6 -and $bytes[3] -eq 0xEF -and $bytes[4] -eq 0xBB -and $bytes[5] -eq 0xBF) { [void]$problems.Add($relative+': duplicate UTF-8 BOM creates an invalid first command.') }
    $text = [IO.File]::ReadAllText($file,[Text.Encoding]::UTF8)
    if ($text -match '(?<!\r)\n|\r(?!\n)') { [void]$problems.Add($relative+': use consistent CRLF line endings.') }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
    foreach ($errorRecord in @($errors)) { [void]$problems.Add($relative+': '+$errorRecord.Message) }
    if ($runtime -contains $relative) {
        foreach ($command in $ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)) {
            if ($command.GetCommandName() -in @('Invoke-Expression','iex','Set-ExecutionPolicy')) { [void]$problems.Add($relative+': avoid runtime expression evaluation or changing persistent execution policy.') }
        }
    }
}
$operations = Join-Path $SourceDir 'operations.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($operations,[ref]$null,[ref]$null)
$dedupe = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DuplicateCleanup'},$true)
if (-not $dedupe -or $dedupe.Extent.Text -notmatch 'SendToRecycleBin') { [void]$problems.Add('Duplicate cleanup must explicitly use the Windows Recycle Bin.') }
if ($dedupe) {
    foreach ($command in $dedupe.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)) {
        if ($command.GetCommandName() -in @('Remove-Item','rm','del','erase')) { [void]$problems.Add('Duplicate cleanup contains a permanent-delete command.') }
    }
    if ($dedupe.Extent.Text -match '\[IO\.File\]::Delete\(|DeletePermanently') { [void]$problems.Add('Duplicate cleanup contains a permanent-delete method.') }
}
if ($problems.Count) { $problems | Write-Output; throw ('Source lint failed: '+$problems.Count+' problem(s).') }
Write-Output ('PASS Source lint: '+@($files|Select-Object -Unique).Count+' PowerShell files; syntax, encoding, runtime structure, recycle-only guard')
