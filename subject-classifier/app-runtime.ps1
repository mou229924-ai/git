. (Join-Path $PSScriptRoot 'configuration.ps1')
# Runtime initialization and the single shared logging implementation.
function Initialize-ApplicationRuntime {
    $script:AppDir=$PSScriptRoot
    $script:ConfigPath=Join-Path $script:AppDir 'config.json'
    $script:Utf8=New-Object Text.UTF8Encoding($false)
    $script:StateDir=Join-Path $env:LOCALAPPDATA ('Nailong.code\state\'+(Get-ConfigurationPathId $script:ConfigPath))
    $script:Cfg=Read-ApplicationConfiguration -Path $script:ConfigPath -TemplatePath (Join-Path $script:AppDir 'config.example.json') -StateDirectory $script:StateDir
    $script:Root=[string]$script:Cfg.inbox
    $script:LogPath=Join-Path $script:AppDir ([string]$script:Cfg.logFile)
    $script:IndexDir=Join-Path $script:AppDir '_index'
    $script:IndexDataDir=Join-Path $script:IndexDir 'data'
    $script:IndexManifest=Join-Path $script:IndexDir 'manifest.json'
    $script:AppVersion='1.1'
    $versionPath=Join-Path $script:AppDir 'VERSION'
    if([IO.File]::Exists($versionPath)){$script:AppVersion=[IO.File]::ReadAllText($versionPath).Trim()}
}
function Write-Log {
    param([string]$Message)
    try {
        if ((Test-Path -LiteralPath $script:LogPath) -and ((Get-Item -LiteralPath $script:LogPath).Length -gt 2MB)) {
            Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.old') -Force
        }
        $line=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'  '+$Message+[Environment]::NewLine
        [IO.File]::AppendAllText($script:LogPath,$line,$script:Utf8)
    } catch {}
}
