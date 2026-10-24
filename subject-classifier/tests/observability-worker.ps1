param([string]$RuntimeDirectory,[string]$LogPath,[string]$Prefix,[int]$Count=20)
$ErrorActionPreference='Stop'
$script:Utf8=New-Object Text.UTF8Encoding($false)
$script:LogPath=$LogPath
. (Join-Path $RuntimeDirectory 'observability.ps1')
for($i=0;$i -lt $Count;$i++){Write-Log ('WORKER-'+$Prefix+'-'+$i)}
Flush-ApplicationLogs -Force
