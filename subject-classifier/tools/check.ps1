param([switch]$Desktop,[switch]$Recycle,[string]$ArtifactsDirectory = '')
$ErrorActionPreference = 'Stop'
$source = Split-Path $PSScriptRoot -Parent
& (Join-Path $source 'tests\run-checks.ps1') -Desktop:$Desktop -Recycle:$Recycle -ArtifactsDirectory $ArtifactsDirectory
exit $LASTEXITCODE
