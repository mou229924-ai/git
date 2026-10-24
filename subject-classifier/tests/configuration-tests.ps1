param([string]$Output='')
$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
. (Join-Path $source 'configuration.ps1')
$run=Join-Path $source ('test-runs\configuration-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run -Force|Out-Null
$template=Join-Path $source 'config.example.json'
$utf8=New-Object Text.UTF8Encoding($false)
$checks=New-Object Collections.ArrayList
function Check([string]$Name,[bool]$Passed){[void]$checks.Add(@{Name=$Name;Passed=$Passed});Write-Output ((@('FAIL','PASS')[[int]$Passed])+' '+$Name)}
function Write-Config([string]$Path,$Config){[IO.File]::WriteAllText($Path,($Config|ConvertTo-Json -Depth 20),$utf8)}
try {
    $path=Join-Path $run 'config.json'
    $state=Join-Path $run 'state'
    [IO.File]::WriteAllText((Join-Path $run 'start.vbs'),'legacy launcher fixture',$utf8)
    $legacy=@{
        inbox='.\资料';processExistingOnStartup=$false;subjects=@();pollSeconds=9
        scoring=@{minScore=3;customNested='preserve-nested'}
        ocr=@{enabled=$false;maxPages=1}
        custom=@{token='preserve-user-setting'}
        ignoreFiles=@('start.vbs','stop.vbs','install-autostart.ps1','personal-file.txt')
    }
    Write-Config $path $legacy
    $originalHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $config=Read-ApplicationConfiguration -Path $path -TemplatePath $template -StateDirectory $state
    Check 'Legacy configuration migrates to supported schema 1' ($config.schemaVersion -eq 1)
    Check 'Explicit false and custom polling settings survive migration' (-not $config.processExistingOnStartup -and $config.pollSeconds -eq 9)
    Check 'An explicitly empty custom directory rule list stays empty' (@($config.subjects).Count -eq 0)
    Check 'Nested defaults are filled without overwriting existing values' ($config.scoring.minScore -eq 3 -and $config.scoring.nameWeight -gt 0 -and $config.scoring.customNested -eq 'preserve-nested')
    Check 'OCR defaults preserve disabled state and the chosen page limit' (-not $config.ocr.enabled -and $config.ocr.maxPages -eq 1 -and $config.ocr.maxFileMiB -eq 25 -and $config.ocr.timeoutSeconds -eq 12)
    Check 'Unknown user configuration properties survive migration' ($config.custom.token -eq 'preserve-user-setting')
    Check 'Only nonexistent obsolete launcher names are removed' (@($config.ignoreFiles) -contains 'start.vbs' -and @($config.ignoreFiles) -notcontains 'stop.vbs' -and @($config.ignoreFiles) -notcontains 'install-autostart.ps1' -and @($config.ignoreFiles) -contains 'personal-file.txt')
    $expectedRoot=[IO.Path]::GetFullPath((Join-Path $run '资料'))
    Check 'Relative library paths become canonical paths beside their config' ($config.inbox -eq $expectedRoot -and [IO.Path]::IsPathRooted($config.inbox))
    $persisted=[IO.File]::ReadAllText($path,$utf8)|ConvertFrom-Json
    Check 'Migrated schema and canonical root are persisted' ($persisted.schemaVersion -eq 1 -and $persisted.inbox -eq $expectedRoot)
    $backup=Join-Path $state 'config-before-schema-1.json'
    Check 'The migration backup preserves original configuration bytes' ([IO.File]::Exists($backup) -and (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -eq $originalHash)
    $backupTime=(Get-Item -LiteralPath $backup).LastWriteTimeUtc.Ticks
    $migratedHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $again=Read-ApplicationConfiguration -Path $path -TemplatePath $template -StateDirectory $state
    Check 'Repeated reads neither replace the one-time backup nor rewrite stable settings' ((Get-Item -LiteralPath $backup).LastWriteTimeUtc.Ticks -eq $backupTime -and (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -eq $originalHash -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $migratedHash)
    $relativeConfig=[pscustomobject]@{inbox='.\other-library'}
    $resolved=Resolve-LibraryConfigRoot -Config $relativeConfig -BaseDirectory $run
    Check 'Standalone root resolution honors its explicit base directory' ($resolved -eq [IO.Path]::GetFullPath((Join-Path $run 'other-library')))
    $absoluteConfig=[pscustomobject]@{inbox=$expectedRoot}
    Check 'Root resolution preserves an absolute library path' ((Resolve-LibraryConfigRoot -Config $absoluteConfig -BaseDirectory $run) -eq $expectedRoot)
    $future=Join-Path $run 'future.json';$futureState=Join-Path $run 'future-state'
    Write-Config $future @{schemaVersion=2;inbox=$expectedRoot;subjects=@()}
    $futureHash=(Get-FileHash -LiteralPath $future -Algorithm SHA256).Hash;$blocked=$false
    try{$null=Read-ApplicationConfiguration -Path $future -TemplatePath $template -StateDirectory $futureState}catch{$blocked=$true}
    Check 'Future schema versions are rejected without modifying their bytes' ($blocked -and (Get-FileHash -LiteralPath $future -Algorithm SHA256).Hash -eq $futureHash)
    Check 'Rejected future schemas do not create misleading migration backups' (-not [IO.File]::Exists((Join-Path $futureState 'config-before-schema-1.json')))
    $invalid=Join-Path $run 'invalid.json';$invalidState=Join-Path $run 'invalid-state'
    [IO.File]::WriteAllText($invalid,'{"inbox":"保留原文", invalid json',$utf8)
    $invalidHash=(Get-FileHash -LiteralPath $invalid -Algorithm SHA256).Hash;$blocked=$false
    try{$null=Read-ApplicationConfiguration -Path $invalid -TemplatePath $template -StateDirectory $invalidState}catch{$blocked=$true}
    Check 'Invalid JSON is rejected while preserving every original byte' ($blocked -and (Get-FileHash -LiteralPath $invalid -Algorithm SHA256).Hash -eq $invalidHash)
    Check 'Invalid JSON creates no migration backup' (-not [IO.File]::Exists((Join-Path $invalidState 'config-before-schema-1.json')))
    $zero=Join-Path $run 'schema-zero.json';$zeroState=Join-Path $run 'zero-state'
    Write-Config $zero @{schemaVersion=0;inbox=$expectedRoot;subjects=@();ocr=@{enabled=$true}}
    $zeroConfig=Read-ApplicationConfiguration -Path $zero -TemplatePath $template -StateDirectory $zeroState
    Check 'Schema zero migrates while preserving an explicitly enabled OCR choice' ($zeroConfig.schemaVersion -eq 1 -and $zeroConfig.ocr.enabled -and $zeroConfig.ocr.maxPages -eq 2)
} catch {Check ('Unhandled configuration test error: '+$_.Exception.Message) $false;Write-Output $_.ScriptStackTrace}
$report=@{Passed=@($checks|Where-Object Passed).Count;Failed=@($checks|Where-Object {-not $_.Passed}).Count;Checks=@($checks.ToArray());Scratch=$run}
if(-not $Output){$Output=Join-Path $PSScriptRoot 'configuration-results.json'}
[IO.File]::WriteAllText($Output,($report|ConvertTo-Json -Depth 8),$utf8)
Write-Output ('TOTAL passed='+$report.Passed+' failed='+$report.Failed)
if($report.Failed){exit 1}
