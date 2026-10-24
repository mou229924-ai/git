param([switch]$Desktop,[switch]$Recycle,[string]$ArtifactsDirectory='',[string]$SourceDir=(Split-Path $PSScriptRoot -Parent),[string]$ScratchBase='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'test-support.ps1')
$SourceDir=[IO.Path]::GetFullPath($SourceDir)
if(-not $ScratchBase){$ScratchBase=Join-Path ([IO.Path]::GetTempPath()) 'Nailong-checks'}
if(-not $ArtifactsDirectory){$ArtifactsDirectory=Join-Path $SourceDir 'test-artifacts\latest'}
New-Item -ItemType Directory -Path $ArtifactsDirectory -Force|Out-Null
$run=Join-Path $ScratchBase ('check-'+[guid]::NewGuid().ToString('N'))
$steps=New-Object Collections.ArrayList
$failures=New-Object Collections.ArrayList
$skipped=New-Object Collections.ArrayList
$started=[datetime]::UtcNow
function Get-OptionalHash([string]$Path){if([IO.File]::Exists($Path)){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash};return ''}
$originalConfig=Get-OptionalHash (Join-Path $SourceDir 'config.json')
$originalGate=Get-OptionalHash (Join-Path $SourceDir 'tests\verified.json')
function Invoke-IsolatedCheck {
    param([string]$Name,[string]$Script,[string[]]$Arguments=@(),[int]$TimeoutSeconds=300)
    $stdout=Join-Path $ArtifactsDirectory ($Name+'.stdout.log')
    $stderr=Join-Path $ArtifactsDirectory ($Name+'.stderr.log')
    $quoted=@()
    foreach($argument in $Arguments){if($argument.Contains('"')){throw 'Unsupported quote in test argument.'};$quoted+='"'+$argument+'"'}
    $processArguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+$Script+'" '+($quoted -join ' ')
    $oldHeadless=$env:NAILONG_TEST_HEADLESS
    $watch=[Diagnostics.Stopwatch]::StartNew();$process=$null;$exitCode=1
    try {
        if($Desktop){$env:NAILONG_TEST_HEADLESS=''}else{$env:NAILONG_TEST_HEADLESS='1'}
        $process=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $processArguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
        $processHandle=$process.Handle
        $deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        while(-not $process.HasExited -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100;$process.Refresh()}
        if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(2000);$exitCode=124}else{$process.WaitForExit();$exitCode=$process.ExitCode}
    } finally {$env:NAILONG_TEST_HEADLESS=$oldHeadless;$watch.Stop();if($process){$process.Dispose()}}
    [void]$steps.Add(@{Name=$Name;ExitCode=$exitCode;Milliseconds=$watch.ElapsedMilliseconds;Stdout=($Name+'.stdout.log');Stderr=($Name+'.stderr.log')})
    if($exitCode -ne 0){[void]$failures.Add($Name+' failed with exit code '+$exitCode);Write-Output ('FAIL '+$Name);Get-Content -LiteralPath $stdout -Tail 25;Get-Content -LiteralPath $stderr -Tail 15}
    else{Write-Output ('PASS '+$Name+' ('+$watch.ElapsedMilliseconds+'ms)')}
}
try {
    $installation=New-IsolatedTestApplication -SourceDir $SourceDir -RunDir $run
    $app=$installation.AppDir
    Invoke-IsolatedCheck -Name source-lint -Script (Join-Path $app 'tools\check-source.ps1')
    Invoke-IsolatedCheck -Name architecture -Script (Join-Path $app 'tests\architecture-tests.ps1')
    $recycleArguments=@();if(-not $Recycle){$recycleArguments=@('-SkipRecycle')}
    Invoke-IsolatedCheck -Name safety -Script (Join-Path $app 'tests\run-tests.ps1') -Arguments (@($recycleArguments)+@('-ScratchBase',(Join-Path $run 'safety')))
    Invoke-IsolatedCheck -Name concurrency -Script (Join-Path $app 'tests\concurrency-tests.ps1')
    $reserved=@('architecture-tests.ps1','run-tests.ps1','concurrency-tests.ps1','dialog-tests.ps1','background-tests.ps1')
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $app 'tests') -File -Filter '*-tests.ps1'|Sort-Object Name)){
        if($file.Name -notin $reserved){Invoke-IsolatedCheck -Name $file.BaseName -Script $file.FullName}
    }
    $learning=Join-Path $app 'tests\test-learning.ps1';if([IO.File]::Exists($learning)){Invoke-IsolatedCheck -Name learning -Script $learning}
    Invoke-IsolatedCheck -Name preview -Script (Join-Path $app 'tests\preview-test.ps1') -Arguments @('-Report',(Join-Path $app 'tests\preview-results.json'))
    Invoke-IsolatedCheck -Name background -Script (Join-Path $app 'tests\background-tests.ps1') -Arguments $recycleArguments
    $dialogArguments=@();if(-not $Desktop){$dialogArguments=@('-Headless')}
    Invoke-IsolatedCheck -Name dialogs -Script (Join-Path $app 'tests\dialog-tests.ps1') -Arguments $dialogArguments
    Invoke-IsolatedCheck -Name form-build -Script (Join-Path $app 'search.ps1') -Arguments @('-SelfTestForm')
    Invoke-IsolatedCheck -Name ui-responsive -Script (Join-Path $app 'search.ps1') -Arguments @('-UiTestOutput',(Join-Path $app 'tests\ui-results.json')) -TimeoutSeconds 100
    if(-not $Recycle -and [IO.File]::Exists((Join-Path $app 'tests\verified.json'))){[void]$failures.Add('CI created a verification report enabling recycling.')}
} catch {[void]$failures.Add($_.Exception.ToString());Write-Output $_.ScriptStackTrace}
finally {
    if(Get-Variable app -ErrorAction SilentlyContinue){
        # Export summaries only. Never export config, verified.json or any scratch installation.
        foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $app 'tests') -File -Filter '*-results.json' -ErrorAction SilentlyContinue)){
            Copy-Item -LiteralPath $file.FullName -Destination $ArtifactsDirectory -Force
            try{$data=[IO.File]::ReadAllText($file.FullName,[Text.Encoding]::UTF8)|ConvertFrom-Json;foreach($item in @($data.SkippedInteractiveAssertions)){if($item){[void]$skipped.Add($item)}}}
            catch{[void]$failures.Add('Unreadable result summary: '+$file.Name)}
        }
    }
    if((Get-OptionalHash (Join-Path $SourceDir 'config.json')) -ne $originalConfig){[void]$failures.Add('Source installation configuration changed during checks.')}
    if((Get-OptionalHash (Join-Path $SourceDir 'tests\verified.json')) -ne $originalGate){[void]$failures.Add('Source installation verification report changed during checks.')}
    try{Remove-IsolatedTestDirectory -Path $run -AllowedParent $ScratchBase}catch{[void]$failures.Add('Scratch cleanup failed: '+$_.Exception.Message)}
    $summary=@{
        Passed=@($steps|Where-Object {$_.ExitCode -eq 0}).Count;Failed=$failures.Count;Failures=@($failures.ToArray());Steps=@($steps.ToArray())
        Desktop=[bool]$Desktop;RecycleTest=[bool]$Recycle;SyntheticFixtures=$true
        ProductionConfigurationUnchanged=((Get-OptionalHash (Join-Path $SourceDir 'config.json')) -eq $originalConfig)
        ProductionGateUnchanged=((Get-OptionalHash (Join-Path $SourceDir 'tests\verified.json')) -eq $originalGate)
        SkippedInteractiveAssertions=@($skipped.ToArray());StartedUtc=$started.ToString('o');FinishedUtc=[datetime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText((Join-Path $ArtifactsDirectory 'checks-results.json'),($summary|ConvertTo-Json -Depth 8),[Text.Encoding]::UTF8)
    Write-Output ('CHECKS passed='+$summary.Passed+' failed='+$summary.Failed+' artifacts='+$ArtifactsDirectory)
}
if($summary.Failed){exit 1}
exit 0
