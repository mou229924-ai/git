$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('nailong-package-'+[guid]::NewGuid().ToString('N'))
$app=Join-Path $scratch 'app';$library=Join-Path $scratch 'library'
[void][IO.Directory]::CreateDirectory($app)
foreach($name in @('setup.ps1','config.example.json')){Copy-Item -LiteralPath (Join-Path $source $name) -Destination $app}
$checks=New-Object Collections.ArrayList
function Check([string]$Name,[bool]$Passed){[void]$checks.Add(@{Name=$Name;Passed=$Passed});Write-Output ($Name+': '+$Passed)}
try{
    Check 'The application ships a readable changelog beside its README' ([IO.File]::Exists((Join-Path $source 'CHANGELOG.md')) -and [IO.File]::ReadAllText((Join-Path $source 'README.md')).Contains('[CHANGELOG.md](CHANGELOG.md)'))
    Check 'The runtime download example does not pin an obsolete release version' ([IO.File]::ReadAllText((Join-Path $source 'RUNTIME.md')) -notmatch 'nailong-code-v[0-9]+\.[0-9]+-windows\.zip')
    $output=@(& powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File (Join-Path $app 'setup.ps1') -LibraryPath $library -NoPrompt 2>&1)
    Check 'First setup succeeds without Git or an existing local config' ($LASTEXITCODE -eq 0)
    $configPath=Join-Path $app 'config.json'
    Check 'First setup creates the user-selected library directory' ([IO.Directory]::Exists($library))
    $config=[IO.File]::ReadAllText($configPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
    Check 'Generated configuration stores the selected absolute path' ($config.inbox -eq $library)
    $before=(Get-FileHash -LiteralPath $configPath).Hash
    $null=& powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File (Join-Path $app 'setup.ps1') -LibraryPath (Join-Path $scratch 'different') -NoPrompt
    Check 'A later setup preserves the existing user configuration' ($LASTEXITCODE -eq 0 -and (Get-FileHash -LiteralPath $configPath).Hash -eq $before)
    Check 'Setup never creates the template example directory implicitly' (-not [IO.Directory]::Exists((Join-Path $scratch 'different')))
    [IO.File]::Delete($configPath)
    $ErrorActionPreference='Continue'
    $null=@(& powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File (Join-Path $app 'setup.ps1') -LibraryPath (Join-Path $app 'nested-library') -NoPrompt 2>&1)
    $expectedExit=$LASTEXITCODE; $ErrorActionPreference='Stop'
    Check 'Setup refuses a library nested in application files' ($expectedExit -ne 0 -and -not [IO.File]::Exists($configPath))
    $ErrorActionPreference='Continue'
    $null=@(& powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File (Join-Path $app 'setup.ps1') -LibraryPath 'relative-folder' -NoPrompt 2>&1)
    $expectedExit=$LASTEXITCODE; $ErrorActionPreference='Stop'
    Check 'Setup refuses ambiguous relative library paths' ($expectedExit -ne 0 -and -not [IO.File]::Exists($configPath))
    Check 'The distributed template no longer references obsolete English launchers' (@($config.ignoreFiles | Where-Object {$_ -in @('start.vbs','stop.vbs','install-autostart.ps1')}).Count -eq 0)
}finally{
    # This fixture never creates links; remove only this verified temporary subtree.
    if(-not [IO.Path]::GetFullPath($scratch).StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected package-test cleanup path.'}
    if(Test-Path -LiteralPath $scratch){Remove-Item -LiteralPath $scratch -Recurse -Force}
}
$report=@{Passed=@($checks | Where-Object Passed).Count;Failed=@($checks | Where-Object {-not $_.Passed}).Count;Checks=@($checks.ToArray())}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'package-results.json'),($report | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
if($report.Failed){exit 1}
