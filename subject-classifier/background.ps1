param([string]$Request,[string]$Result)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
$requestData=[IO.File]::ReadAllText($Request,$script:Utf8) | ConvertFrom-Json
function Report-Job {
    param([string]$State,$Data,[string]$ErrorText='')
    Write-AtomicUtf8 $Result (@{ State=$State; Data=$Data; Error=$ErrorText } | ConvertTo-Json -Depth 12 -Compress)
}
$script:LastOperationProgress=[datetime]::MinValue
$operationProgress={param($done,$total,$name,$operation)
    if($done -eq 0 -or $done -eq $total -or ([datetime]::UtcNow-$script:LastOperationProgress).TotalMilliseconds -ge 150){
        Report-Job 'running' @{Done=$done;Total=$total;Name=$name;Operation=$operation}
        $script:LastOperationProgress=[datetime]::UtcNow
    }
}
$shouldCancel={return [IO.File]::Exists($Result+'.cancel')}
try {
    Report-Job 'running' @{ Done=0; Total=0 }
    switch ([string]$requestData.Task) {
        'search' {
            $limit=200
            if ($requestData.PSObject.Properties['Limit']) { $limit=[int]$requestData.Limit }
            $page=Search-Index -Query ([string]$requestData.Query) -Subject ([string]$requestData.Directory) -IncludeContent ([bool]$requestData.Content) -Limit $limit -Offset ([int]$requestData.Offset) -AsPage -ModifiedSince ([datetime]$requestData.Since) -Extensions @($requestData.Extensions) -SortKey ([string]$requestData.SortKey) -Descending ([bool]$requestData.Descending)
            Report-Job 'done' $page
        }
        'index' {
            $script:LastIndexProgress=[datetime]::MinValue
            $data=Sync-LibraryIndex -Incremental -Force:([bool]$requestData.Force) -Progress {
                param($done,$total,$name)
                if ($done -eq $total -or ([datetime]::UtcNow-$script:LastIndexProgress).TotalMilliseconds -ge 150) {
                    Report-Job 'running' @{ Done=$done; Total=$total; Name=$name }
                    $script:LastIndexProgress=[datetime]::UtcNow
                }
            }
            Report-Job 'done' $data
        }
        {$_ -in @('import','export','print','print-plan')} {
            $paths=@($requestData.Paths | Select-Object -Unique)
            switch([string]$requestData.Task){
                'import'{$outcomes=@(Import-LibraryItems -Paths $paths -Progress $operationProgress -ShouldCancel $shouldCancel)}
                'export'{$outcomes=@(Export-LibraryFiles -Paths $paths -Destination ([string]$requestData.Destination) -Progress $operationProgress -ShouldCancel $shouldCancel)}
                default{$outcomes=@(Invoke-BatchPrint -Paths $paths -Execute:($requestData.Task -eq 'print') -Progress $operationProgress -ShouldCancel $shouldCancel)}
            }
            Report-Job 'done' @{Outcomes=$outcomes;Completed=$outcomes.Count;Total=$paths.Count;Cancelled=([IO.File]::Exists($Result+'.cancel') -and $outcomes.Count -lt $paths.Count);PrinterName=[string]$requestData.PrinterName}
        }
        'train' {
            $indexState=Sync-LibraryIndex -Incremental
            if($indexState.Busy){throw '索引仍在更新，请等待完成后再学习。'}
            $script:LastTrainingProgress=[datetime]::MinValue
            $training=Train-LibraryClassifier -Progress {
                param($done,$total,$name)
                if($done -eq $total -or ([datetime]::UtcNow-$script:LastTrainingProgress).TotalMilliseconds -ge 150){
                    Report-Job 'running' @{Done=$done;Total=$total;Name=$name;Stage='training'}
                    $script:LastTrainingProgress=[datetime]::UtcNow
                }
            }
            Report-Job 'done' $training
        }
        'scan' {
            $plan=@(Find-DuplicateDocuments -Progress { param($done,$total) Report-Job 'running' @{ Done=$done; Total=$total } })
            Report-Job 'done' @{ Plan=$plan }
        }
        'cleanup' {
            $outcomes=@(Invoke-DuplicateCleanup -Plan @($requestData.Plan) -Execute -Progress $operationProgress)
            Report-Job 'done' @{ Outcomes=$outcomes }
        }
        'rebuild' {
            $data=Rebuild-Index -Progress { param($done,$total,$name) Report-Job 'running' @{ Done=$done; Total=$total } }
            Report-Job 'done' $data
        }
        default { throw '未知后台任务。' }
    }
} catch { Write-Log ('JOB ERROR  '+[string]$requestData.Task+'  '+$_.Exception.Message) -Exception $_.Exception; Report-Job 'failed' $null $_.Exception.Message; exit 1 } finally { Flush-ApplicationLogs -Force }
