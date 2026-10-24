param(
    [ValidateSet('','hold','probe','index')][string]$Worker = '',
    [string]$AppDir = '',
    [string]$SignalDir = '',
    [string]$Output = ''
)
$ErrorActionPreference = 'Stop'

function Wait-Signal {
    param([string]$Path,[int]$Milliseconds = 15000)
    $deadline = [datetime]::UtcNow.AddMilliseconds($Milliseconds)
    while (-not [IO.File]::Exists($Path)) {
        if ([datetime]::UtcNow -ge $deadline) { throw ('Timed out waiting for test signal: ' + $Path) }
        Start-Sleep -Milliseconds 25
    }
}

if ($Worker) {
    try {
        . (Join-Path $AppDir 'lib.ps1')
        switch ($Worker) {
            'hold' {
                Invoke-LibraryLock {
                    [IO.File]::WriteAllText((Join-Path $SignalDir 'ready'), 'held')
                    Wait-Signal (Join-Path $SignalDir 'release')
                }
            }
            'probe' {
                Invoke-LibraryLock -Timeout 800 {
                    [IO.File]::WriteAllText((Join-Path $SignalDir 'acquired'), 'yes')
                }
            }
            'index' {
                $script:ActualFileReader = (Get-Command Get-FileText).ScriptBlock
                function Get-FileText {
                    param([string]$Path,[int]$Max)
                    if ([IO.Path]::GetFileName($Path) -eq 'slow-index.txt') {
                        [IO.File]::WriteAllText((Join-Path $SignalDir 'ready'), 'parsing')
                        Wait-Signal (Join-Path $SignalDir 'release')
                    }
                    & $script:ActualFileReader -Path $Path -Max $Max
                }
                $null = Sync-LibraryIndex
            }
        }
        exit 0
    } catch {
        [IO.File]::WriteAllText((Join-Path $SignalDir 'error.txt'), $_.Exception.ToString())
        exit 1
    }
}

$source = Split-Path $PSScriptRoot -Parent
$run = Join-Path $source ('test-runs\concurrency-' + [guid]::NewGuid().ToString('N'))
$app = Join-Path $run 'app'
$library = Join-Path $run 'library'
New-Item -ItemType Directory -Path $app,$library -Force | Out-Null
$manifest = [IO.File]::ReadAllText((Join-Path $source 'application-files.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json
foreach ($relative in $manifest) {
    $destination = Join-Path $app $relative
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $destination
}
Copy-Item -LiteralPath (Join-Path $source 'application-files.json') -Destination $app
$config = [IO.File]::ReadAllText((Join-Path $source 'config.example.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json
$config.inbox = $library
$config.stablePolls = 2
$config.processExistingOnStartup = $true
[IO.File]::WriteAllText((Join-Path $app 'config.json'),($config | ConvertTo-Json -Depth 12),[Text.Encoding]::UTF8)
. (Join-Path $app 'lib.ps1')
. (Join-Path $app 'classifier-scan.ps1')
Initialize-ClassifierState
$checks = New-Object Collections.ArrayList
$processes = New-Object Collections.ArrayList
$releaseFiles = New-Object Collections.ArrayList
function Check {
    param([string]$Name,[bool]$Passed)
    [void]$checks.Add(@{Name=$Name;Passed=$Passed})
    Write-Output ((@('FAIL','PASS')[[int]$Passed]) + ' ' + $Name)
}
function Start-TestWorker {
    param([string]$Mode,[string]$Name)
    $signals = Join-Path $run $Name
    New-Item -ItemType Directory -Path $signals -Force | Out-Null
    $workerArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Worker ' + $Mode + ' -AppDir "' + $app + '" -SignalDir "' + $signals + '"'
    $process = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $workerArguments -PassThru
    $processHandle=$process.Handle
    [void]$processes.Add($process)
    [void]$releaseFiles.Add((Join-Path $signals 'release'))
    return [pscustomobject]@{Process=$process;Signals=$signals}
}
function Stop-TestHold {
    param($Job)
    [IO.File]::WriteAllText((Join-Path $Job.Signals 'release'),'done')
    if (-not $Job.Process.WaitForExit(5000)) { throw 'The isolated test worker did not stop.' }
    if ($Job.Process.ExitCode -ne 0) {
        $errorFile = Join-Path $Job.Signals 'error.txt'
        if ([IO.File]::Exists($errorFile)) { throw [IO.File]::ReadAllText($errorFile) }
        throw 'The isolated test worker failed.'
    }
}
try {
    $hold = Start-TestWorker -Mode hold -Name 'busy-lock'
    Wait-Signal (Join-Path $hold.Signals 'ready')
    $caught = $null
    try { Invoke-LibraryLock -Timeout 30 { throw 'Unexpected lock acquisition.' } } catch { $caught = $_.Exception }
    Check 'A busy library reports a typed TimeoutException' ($caught -is [TimeoutException])
    $script:BusyActionRan = $false
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-LibraryLock -Timeout 0 -SkipIfBusy { $script:BusyActionRan = $true }
    $watch.Stop()
    Check 'SkipIfBusy returns promptly without running its action' (-not $script:BusyActionRan -and $watch.ElapsedMilliseconds -lt 1000)
    $automatic = Join-Path $library '物理试卷.txt'
    [IO.File]::WriteAllText($automatic,'concurrency-classification-fixture',[Text.Encoding]::UTF8)
    $null=Scan-Once; $watch.Restart(); Scan-Once; $watch.Stop()
    Check 'Watcher skips a busy move without blocking its polling loop' ($watch.ElapsedMilliseconds -lt 1800 -and $script:LastScanBusyCount -gt 0 -and [IO.File]::Exists($automatic))
    $log = ''; if ([IO.File]::Exists($script:LogPath)) { $log = [IO.File]::ReadAllText($script:LogPath) }
    Check 'Normal busy contention is not logged as ERROR' ($log -notmatch '(?m)(TICK ERROR|^.*\sERROR\s|FOLDER ERROR)')
    Stop-TestHold $hold
    $script:Defer.Clear()
    Scan-Once
    $classified = Join-Path $library '物理\物理试卷.txt'
    Check 'Watcher retries the same stable file once the lock is released' ([IO.File]::Exists($classified) -and -not [IO.File]::Exists($automatic))

    $manual = Join-Path $library 'unknown-manual-fixture.txt'
    [IO.File]::WriteAllText($manual,'unrecognized-content-fixture',[Text.Encoding]::UTF8)
    $script:DialogProbeCalled = $false
    $script:DialogProbeAcquired = $false
    function Show-SubjectDialog {
        $script:DialogProbeCalled = $true
        $probe = Start-TestWorker -Mode probe -Name 'dialog-probe'
        if ($probe.Process.WaitForExit(3500)) {
            $script:DialogProbeAcquired = ($probe.Process.ExitCode -eq 0 -and [IO.File]::Exists((Join-Path $probe.Signals 'acquired')))
        }
        return @{Action='keep';Name=$null}
    }
    Scan-Once
    Scan-Once
    Check 'Manual classification decision does not hold the library lock' ($script:DialogProbeCalled -and $script:DialogProbeAcquired)
    Check 'The mocked manual keep action preserves original bytes' ([IO.File]::ReadAllText($manual) -eq 'unrecognized-content-fixture')
    [IO.File]::Delete($manual)

    $slow = Join-Path $library '物理\slow-index.txt'
    [IO.File]::WriteAllText($slow,'slow-body-parser-fixture',[Text.Encoding]::UTF8)
    $index = Start-TestWorker -Mode index -Name 'slow-index'
    Wait-Signal (Join-Path $index.Signals 'ready')
    $script:ShortLockRan = $false
    $watch.Restart()
    Invoke-LibraryLock -Timeout 400 { $script:ShortLockRan = $true }
    $watch.Stop()
    Check 'Index body extraction leaves the library lock available' ($script:ShortLockRan -and $watch.ElapsedMilliseconds -lt 1200)
    $later = Join-Path $library '物理新增试卷.txt'
    [IO.File]::WriteAllText($later,'later-classifier-fixture',[Text.Encoding]::UTF8)
    Scan-Once; $watch.Restart(); Scan-Once; $watch.Stop()
    $laterTarget = Join-Path $library '物理\物理新增试卷.txt'
    Check 'A short classifier move completes while index extraction is paused' ($watch.ElapsedMilliseconds -lt 3500 -and [IO.File]::Exists($laterTarget))
    Stop-TestHold $index
    $entries = @(Load-IndexEntries)
    Check 'Index commit preserves the concurrently classified document' (@($entries | Where-Object rel -eq '物理\物理新增试卷.txt').Count -eq 1)
    Check 'Index commit includes the parsed document without duplicates' (@($entries | Where-Object rel -eq '物理\slow-index.txt').Count -eq 1)
    Check 'Concurrent operations preserve both document byte contents' ([IO.File]::ReadAllText($slow) -eq 'slow-body-parser-fixture' -and [IO.File]::ReadAllText($laterTarget) -eq 'later-classifier-fixture')
} catch {
    Check ('Unhandled concurrency test error: ' + $_.Exception.Message) $false
    Write-Output $_.ScriptStackTrace
} finally {
    foreach ($release in $releaseFiles) { [IO.File]::WriteAllText($release,'cleanup') }
    foreach ($process in $processes) {
        if (-not $process.HasExited -and -not $process.WaitForExit(2000)) { $process.Kill(); [void]$process.WaitForExit(2000) }
        $process.Dispose()
    }
    $report = @{Passed=@($checks | Where-Object Passed).Count;Failed=@($checks | Where-Object {-not $_.Passed}).Count;Checks=@($checks.ToArray());Scratch=$run}
    if (-not $Output) { $Output = Join-Path $PSScriptRoot 'concurrency-results.json' }
    [IO.File]::WriteAllText($Output,($report | ConvertTo-Json -Depth 5),[Text.Encoding]::UTF8)
    Write-Output ('TOTAL passed=' + $report.Passed + ' failed=' + $report.Failed)
}
if ($report.Failed) { exit 1 }
