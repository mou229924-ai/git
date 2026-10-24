param([string]$ApplicationDirectory=(Split-Path $PSScriptRoot -Parent),[string]$DesktopDirectory=[Environment]::GetFolderPath('Desktop'),[string]$StartupDirectory=[Environment]::GetFolderPath('Startup'))
$ErrorActionPreference='Stop'
$app=[IO.Path]::GetFullPath($ApplicationDirectory).TrimEnd('\')
$entry=Join-Path $app 'setup.ps1'
if(-not [IO.File]::Exists($entry)){throw '应用入口缺失。'}
$shell=New-Object -ComObject WScript.Shell
try{
    [void][IO.Directory]::CreateDirectory($DesktopDirectory)
    $link=$shell.CreateShortcut((Join-Path $DesktopDirectory '奶龙.code.lnk'))
    $link.TargetPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $link.Arguments='-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "'+$entry+'" -Launch'
    $link.WorkingDirectory=$app;$link.WindowStyle=7;$link.Description='奶龙.code：搜索、预览与自动分类'
    $icon=Join-Path $app 'assets\app.ico';if([IO.File]::Exists($icon)){$link.IconLocation=$icon}
    $link.Save();[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)
    $removed=0
    if([IO.Directory]::Exists($StartupDirectory)){
        foreach($file in @(Get-ChildItem -LiteralPath $StartupDirectory -Filter '*.lnk' -File -Force)){
            $shortcut=$shell.CreateShortcut($file.FullName)
            try{
                $command=([string]$shortcut.TargetPath)+' '+([string]$shortcut.Arguments)
                $launcher=[IO.Path]::GetFileName([string]$shortcut.TargetPath)
                if($launcher -in @('powershell.exe','pwsh.exe','wscript.exe','cscript.exe','奶龙.code.cmd') -and $command.IndexOf($app+'\',[StringComparison]::OrdinalIgnoreCase) -ge 0 -and $command -match '(?i)(classifier|setup|search|\.vbs)'){
                    Remove-Item -LiteralPath $file.FullName -Force;$removed++
                }
            }finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)}
        }
    }
    Write-Output ('桌面快捷方式已更新；已关闭本应用的 '+$removed+' 个启动文件夹入口。')
}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
