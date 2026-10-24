$ErrorActionPreference='Stop'
$app=Split-Path $PSScriptRoot -Parent
. (Join-Path $app 'lib.ps1')
if(-not ([IO.Path]::GetFullPath($script:Root)).StartsWith(([IO.Path]::GetFullPath($app).TrimEnd('\')+'\test-library'),[StringComparison]::OrdinalIgnoreCase)){throw '仅允许在隔离资料库中测试。'}
$checks=New-Object Collections.ArrayList
function Verify([string]$Name,[bool]$Passed){[void]$checks.Add(@{Name=$Name;Passed=$Passed});Write-Output ($Name+': '+$Passed)}
function Run-Worker([hashtable]$Request){
    $id=[guid]::NewGuid().ToString('N');$requestFile=Join-Path $PSScriptRoot ($id+'.request.json');$resultFile=Join-Path $PSScriptRoot ($id+'.result.json')
    [IO.File]::WriteAllText($requestFile,($Request|ConvertTo-Json -Depth 10),$script:Utf8)
    $arguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+(Join-Path $app 'background.ps1')+'" -Request "'+$requestFile+'" -Result "'+$resultFile+'"'
    $process=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments -PassThru
    try{
        if(-not $process.WaitForExit(25000)){$process.Kill();throw '后台测试超时。'}
        return (Read-AtomicUtf8 $resultFile)|ConvertFrom-Json
    }finally{$process.Dispose();foreach($file in @($requestFile,$resultFile)){if([IO.File]::Exists($file)){[IO.File]::Delete($file)}}}
}
$directory=Join-Path $script:Root '后台测试'
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$keep=Join-Path $directory 'a.txt';$duplicate=Join-Path $directory 'b.txt'
[IO.File]::WriteAllText($keep,'async-task-fixture unique sample',$script:Utf8)
[IO.File]::WriteAllText($duplicate,'async-task-fixture unique sample',$script:Utf8)
$before=(Get-FileHash -LiteralPath $keep -Algorithm SHA256).Hash
$scan=Run-Worker @{Task='scan'}
Verify 'Background scanner returns a completed plan' ($scan.State -eq 'done')
$plan=@($scan.Data.Plan|Where-Object {$_.Duplicate -eq $duplicate})
Verify 'Background scanner detects the isolated duplicate correctly' ($plan.Count -eq 1 -and $plan[0].Keep -eq $keep)
$cleanup=Run-Worker @{Task='cleanup';Plan=$plan}
Verify 'Background cleanup reports one recycled copy' ($cleanup.State -eq 'done' -and @($cleanup.Data.Outcomes|Where-Object Status -eq 'recycled').Count -eq 1)
Verify 'Background cleanup preserves the retained file exactly' ((Test-Path -LiteralPath $keep) -and (Get-FileHash -LiteralPath $keep -Algorithm SHA256).Hash -eq $before -and -not (Test-Path -LiteralPath $duplicate))
$index=Run-Worker @{Task='index'}
Verify 'Background index update completes before snapshot search' ($index.State -eq 'done')
$search=Run-Worker @{Task='search';Query='async-task-fixture';Directory='后台测试';Content=$true;Since=[datetime]::MinValue.ToString('o');Extensions=@('.txt');SortKey='mtimeTicks';Descending=$true}
Verify 'Background search combines directory, content and format filters' ($search.State -eq 'done' -and @($search.Data.Results).Count -eq 1 -and $search.Data.Results[0].full -eq $keep)
$invalid=Run-Worker @{Task='invalid-operation'}
Verify 'Unknown worker task returns an explicit failure state' ($invalid.State -eq 'failed' -and [bool]$invalid.Error)
$report=@{Passed=@($checks|Where-Object Passed).Count;Failed=@($checks|Where-Object{-not $_.Passed}).Count;Checks=@($checks.ToArray())}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'background-results.json'),($report|ConvertTo-Json -Depth 5),$script:Utf8)
if($report.Failed){exit 1}
