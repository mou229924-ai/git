param([string]$SourceDir,[string]$Root,[string]$AppDir,[string]$Worker)
$ErrorActionPreference = 'Stop'
$workerRoot = $Root; $workerAppDir = $AppDir
. (Join-Path $SourceDir 'lib.ps1')
$script:Root = $workerRoot
$script:AppDir = $workerAppDir
$script:IndexDir = Join-Path $workerAppDir '_index'
$script:IndexDataDir = Join-Path $script:IndexDir 'data'
$script:IndexManifest = Join-Path $script:IndexDir 'manifest.json'
$script:LogPath = Join-Path $workerAppDir '_classifier.log'
for ($i=0; $i -lt 8; $i++) {
    [IO.File]::WriteAllText((Join-Path $Root ('worker-' + $Worker + '-' + $i + '.txt')),('parallel-' + $Worker + '-' + $i),$script:Utf8)
    $null = Sync-LibraryIndex
    Start-Sleep -Milliseconds 30
}
