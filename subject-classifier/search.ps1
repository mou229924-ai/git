param(
    [string]$Query = '',
    [string]$Report = '',
    [switch]$RebuildIndex,
    [switch]$SelfTestForm,
    [string]$UiTestOutput = '',
    [string]$Capture = '',
    [string]$CaptureQuery = '',
    [string]$RestoreFile = ''
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib.ps1')

if ($RebuildIndex) {
    $rebuilt = Rebuild-Index
    Write-Output ('rebuilt total=' + [string]$rebuilt.Total + ' withText=' + [string]$rebuilt.WithText)
    exit
}

if (-not [string]::IsNullOrEmpty($Query) -or -not [string]::IsNullOrEmpty($Report)) {
    $results = @(Search-Index -Query $Query -Limit 500)
    if (-not [string]::IsNullOrEmpty($Report)) {
        $sb = New-Object System.Text.StringBuilder
        foreach ($r in $results) {
            [void]$sb.AppendLine([string]$r.score + "`t" + [string]$r.subject + "`t" + [string]$r.rel + "`t" + [string]$r.hit)
        }
        [void]$sb.AppendLine('TOTAL=' + [string]$results.Count)
        [System.IO.File]::WriteAllText($Report, $sb.ToString(), $script:Utf8)
    }
    Write-Output ('results=' + [string]$results.Count)
    exit
}

# Load each UI responsibility explicitly; modules share this window's script scope.
. (Join-Path $PSScriptRoot 'search-platform.ps1')
. (Join-Path $PSScriptRoot 'search-theme.ps1')
. (Join-Path $PSScriptRoot 'search-actions.ps1')
. (Join-Path $PSScriptRoot 'search-controls.ps1')
. (Join-Path $PSScriptRoot 'search-events.ps1')
. (Join-Path $PSScriptRoot 'library-ui.ps1')
. (Join-Path $PSScriptRoot 'search-lifetime.ps1')
