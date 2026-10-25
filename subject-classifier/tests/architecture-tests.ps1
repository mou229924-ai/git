param([string]$SourceDir = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $SourceDir 'application-files.json'
$runtimeFiles = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
if (-not $runtimeFiles.Count) { throw 'The application file manifest is empty.' }
$seen = @{}
$definitions = @{}
foreach ($relative in $runtimeFiles) {
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)' -or $seen.ContainsKey($relative)) {
        throw ('Invalid or repeated application path: ' + $relative)
    }
    $seen[$relative] = $true
    $fullPath = Join-Path $SourceDir $relative
    if (-not [IO.File]::Exists($fullPath)) { throw ('Missing application file: ' + $relative) }
    if ([IO.Path]::GetExtension($relative) -ne '.ps1') { continue }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($fullPath,[ref]$tokens,[ref]$errors)
    if (@($errors).Count) { throw ('Invalid PowerShell syntax in ' + $relative + ': ' + ($errors.Message -join '; ')) }
    $definitions[$relative] = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
}
# These are the actual independent process loading groups. Their entry-point helpers
# may share names across processes, but never overwrite another definition in one process.
$uiFiles = @('search.ps1','library-ui.ps1','extra-ui.ps1','explorer-layout.ps1','batch-ui.ps1','session-ui.ps1','learning-ui.ps1')
$uiFiles += @($definitions.Keys | Where-Object { $_ -like 'search-*' })
$entryFiles = @('classifier.ps1','background.ps1','preview-host.ps1','pdf-text-worker.ps1')
$shared = @($definitions.Keys | Where-Object { $_ -notin $uiFiles -and $_ -notin $entryFiles -and $_ -notlike 'classifier-*' })
$groups = @{
    Classifier = @($shared) + @($definitions.Keys | Where-Object { $_ -like 'classifier-*' }) + @('classifier.ps1')
    Library = @($shared) + $uiFiles
    Background = @($shared) + @('background.ps1')
    Preview = @($shared) + @('preview-host.ps1')
}
foreach ($groupName in $groups.Keys) {
    $names = @{}
    foreach ($relative in $groups[$groupName]) {
        foreach ($definition in @($definitions[$relative])) {
            if ($null -eq $definition) { continue }
            if ($names.ContainsKey($definition.Name)) {
                throw ('Function override in ' + $groupName + ': ' + $definition.Name + ' (' + $names[$definition.Name] + ', ' + $relative + ')')
            }
            $names[$definition.Name] = $relative
        }
    }
    Write-Output ('PASS No duplicate function definitions in ' + $groupName + ' process (' + $names.Count + ' functions)')
}
Write-Output ('PASS Application manifest: ' + $runtimeFiles.Count + ' existing unique files')
