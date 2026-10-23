param([string]$Request,[string]$Result)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
$requestData=[IO.File]::ReadAllText($Request,$script:Utf8) | ConvertFrom-Json
function Report-Job {
    param([string]$State,$Data,[string]$ErrorText='')
    Write-AtomicUtf8 $Result (@{ State=$State; Data=$Data; Error=$ErrorText } | ConvertTo-Json -Depth 12 -Compress)
}
try {
    Report-Job 'running' @{ Done=0; Total=0 }
    switch ([string]$requestData.Task) {
        'search' {
            $null=Sync-LibraryIndex
            $results=@(Search-Index -Query ([string]$requestData.Query) -Subject ([string]$requestData.Directory) -IncludeContent ([bool]$requestData.Content) -Limit 3000 -ModifiedSince ([datetime]$requestData.Since) -Extensions @($requestData.Extensions) -SortKey ([string]$requestData.SortKey) -Descending ([bool]$requestData.Descending))
            Report-Job 'done' @{ Results=$results; Total=@(Load-IndexEntries).Count }
        }
        'scan' {
            $plan=@(Find-DuplicateDocuments -Progress { param($done,$total) Report-Job 'running' @{ Done=$done; Total=$total } })
            Report-Job 'done' @{ Plan=$plan }
        }
        'cleanup' {
            $outcomes=@(Invoke-DuplicateCleanup -Plan @($requestData.Plan) -Execute)
            Report-Job 'done' @{ Outcomes=$outcomes }
        }
        'rebuild' {
            $data=Rebuild-Index -Progress { param($done,$total,$name) Report-Job 'running' @{ Done=$done; Total=$total } }
            Report-Job 'done' $data
        }
        default { throw '未知后台任务。' }
    }
} catch { Report-Job 'failed' $null $_.Exception.Message; exit 1 }
