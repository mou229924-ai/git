param([string]$LibraryPath='',[switch]$NoPrompt,[switch]$Launch,[switch]$Listen)
$ErrorActionPreference='Stop'
$app=$PSScriptRoot
$configPath=Join-Path $app 'config.json'
$utf8=New-Object Text.UTF8Encoding($false)
try {
    if($Launch -and $Listen){throw '启动方式只能选择一种。'}
    if(-not [IO.File]::Exists($configPath)){
        if(-not $LibraryPath){
            if($NoPrompt){throw '首次配置需要指定资料目录。'}
            Add-Type -AssemblyName System.Windows.Forms
            $picker=New-Object Windows.Forms.FolderBrowserDialog
            $picker.Description='选择要管理的资料文件夹。资料保存在你选择的位置。'
            $picker.ShowNewFolderButton=$true
            try{if($picker.ShowDialog() -ne 'OK'){exit 0};$LibraryPath=$picker.SelectedPath}finally{$picker.Dispose()}
        }
        if(-not [IO.Path]::IsPathRooted($LibraryPath) -or $LibraryPath -match '^[A-Za-z]:[^\\/]'){throw '请选择完整的资料目录路径。'}
        $root=[IO.Path]::GetFullPath($LibraryPath).TrimEnd('\')
        if($root.Length -le 3){throw '请选择资料文件夹，不要选择整个磁盘。'}
        if($root.Equals($app,[StringComparison]::OrdinalIgnoreCase) -or $root.StartsWith($app.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw '资料目录请放在程序文件夹之外。'}
        [void][IO.Directory]::CreateDirectory($root)
        if((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '请选择实际文件夹，当前不支持目录链接。'}
        $template=Join-Path $app 'config.example.json'
        if(-not [IO.File]::Exists($template)){throw '配置示例缺失，请重新解压完整发布包。'}
        $config=[IO.File]::ReadAllText($template,$utf8) | ConvertFrom-Json
        $config.inbox=$root
        $temporary=$configPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        try{
            [IO.File]::WriteAllText($temporary,($config | ConvertTo-Json -Depth 16),$utf8)
            if(-not [IO.File]::Exists($configPath)){[IO.File]::Move($temporary,$configPath)}
        }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
    }
    $existing=[IO.File]::ReadAllText($configPath,$utf8) | ConvertFrom-Json
    if(-not $existing.inbox -or -not [IO.Path]::IsPathRooted([string]$existing.inbox)){throw '资料路径无效，请检查 config.json 的 inbox。'}
    if($Launch){& (Join-Path $app 'search.ps1')}
    elseif($Listen){& (Join-Path $app 'search.ps1')}
    else{Write-Output '资料库配置已就绪。'}
} catch {
    if($NoPrompt){Write-Error $_.Exception.Message;exit 1}
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'奶龙.code · 启动未完成','OK','Error')
    exit 1
}
