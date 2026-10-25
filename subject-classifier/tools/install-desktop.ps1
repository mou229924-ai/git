param([string]$ApplicationDirectory=(Split-Path $PSScriptRoot -Parent),[string]$DesktopDirectory=[Environment]::GetFolderPath('Desktop'),[string]$StartupDirectory=[Environment]::GetFolderPath('Startup'))
$ErrorActionPreference='Stop'
$app=[IO.Path]::GetFullPath($ApplicationDirectory).TrimEnd('\')
$entry=Join-Path $app 'setup.ps1'
if(-not [IO.File]::Exists($entry)){throw '应用入口缺失。'}
if(-not ('Nailong.NativeShortcut' -as [type])){Add-Type -Path (Join-Path $app 'NativeShortcut.cs')}
$desktop=[IO.Path]::GetFullPath($DesktopDirectory)
[void][IO.Directory]::CreateDirectory($desktop)
$target=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments='-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "'+$entry+'" -Launch'
$icon=Join-Path $app 'assets\app.ico';if(-not [IO.File]::Exists($icon)){$icon=''}
function Test-OwnedDesktopShortcut([string]$Path){
    if(-not [IO.File]::Exists($Path)){return $false}
    if([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint){return $false}
    try{
        $link=[Nailong.NativeShortcut]::Read($Path)
        if(-not $link.TargetPath.Equals($target,[StringComparison]::OrdinalIgnoreCase)){return $false}
        # Check the first command mode, so -File text embedded in -Command cannot establish ownership.
        $mode=[regex]::Match($link.Arguments,'(?i)(?:^|\s)-(?<Mode>File|f|Command|c|EncodedCommand|enc|ec|e|CommandWithArgs|cwa)(?:\s+|$)(?:"(?<Quoted>[^"]+)"|(?<Plain>\S+))?')
        if(-not $mode.Success -or $mode.Groups['Mode'].Value -notmatch '^(?i:file|f)$'){return $false}
        $pathArgument=$mode.Groups['Quoted'].Value
        if(-not $pathArgument){$pathArgument=$mode.Groups['Plain'].Value}
        if(-not [IO.Path]::IsPathRooted($pathArgument) -or -not [IO.Path]::GetFullPath($pathArgument).Equals($entry,[StringComparison]::OrdinalIgnoreCase)){return $false}
        return $link.Arguments.Substring($mode.Index+$mode.Length).Trim() -ieq '-Launch'
    }catch{return $false}
}
$desktopPath=Join-Path $desktop '奶龙select.lnk'
if([IO.File]::Exists($desktopPath) -and -not (Test-OwnedDesktopShortcut $desktopPath)){throw '桌面已有同名快捷方式，属于其他程序或无法验证。请先重命名该快捷方式，再安装本应用入口。'}
[Nailong.NativeShortcut]::Create($desktopPath,$target,$arguments,$app,'奶龙select：搜索、预览与自动分类',$icon,7)
$installed=[Nailong.NativeShortcut]::Read($desktopPath)
if(-not (Test-OwnedDesktopShortcut $desktopPath) -or $installed.Arguments -cne $arguments -or -not $installed.WorkingDirectory.Equals($app,[StringComparison]::OrdinalIgnoreCase) -or $installed.Description -cne '奶龙select：搜索、预览与自动分类'){throw '桌面快捷方式写入后校验失败，保留原有入口。'}
$legacyDesktop=Join-Path $desktop '奶龙.code.lnk'
if(Test-OwnedDesktopShortcut $legacyDesktop){Remove-Item -LiteralPath $legacyDesktop -Force}
$removed=0
if([IO.Directory]::Exists($StartupDirectory)){
    foreach($file in @(Get-ChildItem -LiteralPath $StartupDirectory -Filter '*.lnk' -File -Force)){
        # Read-only load: never resolve or rewrite an unrelated startup shortcut.
        try{$shortcut=[Nailong.NativeShortcut]::Read($file.FullName)}catch{continue}
        $command=([string]$shortcut.TargetPath)+' '+([string]$shortcut.Arguments)
        $launcher=[IO.Path]::GetFileName([string]$shortcut.TargetPath)
        if($launcher -in @('powershell.exe','pwsh.exe','wscript.exe','cscript.exe','奶龙.code.cmd','奶龙select.cmd') -and $command.IndexOf($app+'\',[StringComparison]::OrdinalIgnoreCase) -ge 0 -and $command -match '(?i)(classifier|setup|search|\.vbs|\.cmd)'){
            Remove-Item -LiteralPath $file.FullName -Force;$removed++
        }
    }
}
Write-Output ('桌面快捷方式已更新；已关闭本应用的 '+$removed+' 个启动文件夹入口。')
