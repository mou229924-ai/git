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
[Nailong.NativeShortcut]::Create((Join-Path $desktop '奶龙.code.lnk'),$target,$arguments,$app,'奶龙.code：搜索、预览与自动分类',$icon,7)
$removed=0
if([IO.Directory]::Exists($StartupDirectory)){
    foreach($file in @(Get-ChildItem -LiteralPath $StartupDirectory -Filter '*.lnk' -File -Force)){
        # Read-only load: never resolve or rewrite an unrelated startup shortcut.
        try{$shortcut=[Nailong.NativeShortcut]::Read($file.FullName)}catch{continue}
        $command=([string]$shortcut.TargetPath)+' '+([string]$shortcut.Arguments)
        $launcher=[IO.Path]::GetFileName([string]$shortcut.TargetPath)
        if($launcher -in @('powershell.exe','pwsh.exe','wscript.exe','cscript.exe','奶龙.code.cmd') -and $command.IndexOf($app+'\',[StringComparison]::OrdinalIgnoreCase) -ge 0 -and $command -match '(?i)(classifier|setup|search|\.vbs)'){
            Remove-Item -LiteralPath $file.FullName -Force;$removed++
        }
    }
}
Write-Output ('桌面快捷方式已更新；已关闭本应用的 '+$removed+' 个启动文件夹入口。')
