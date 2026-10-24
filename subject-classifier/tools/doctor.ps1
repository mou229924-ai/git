param([switch]$Json,[switch]$ShowWindow,[string]$ApplicationDirectory=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$ApplicationDirectory=[IO.Path]::GetFullPath($ApplicationDirectory)
. (Join-Path $ApplicationDirectory 'environment.ps1')
$ocrModule=Join-Path $ApplicationDirectory 'document-text.ps1'
if([IO.File]::Exists($ocrModule)){. $ocrModule}
$state=Get-ApplicationEnvironment -Directory $ApplicationDirectory
if($Json){$state|ConvertTo-Json -Depth 8}elseif($ShowWindow){Show-ApplicationEnvironment -Directory $ApplicationDirectory}else{$state|Format-List}
if(-not $state.WinForms-or -not $state.SupportedPowerShell){exit 1}
