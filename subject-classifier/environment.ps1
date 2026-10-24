# Read-only runtime diagnostics. Loading this module does not read user configuration or change policy.
function Get-PreviewRegistryValue {
    param([string]$SubKey,[string]$ValueName='')
    $view=[Microsoft.Win32.RegistryView]::Registry32
    if([Environment]::Is64BitProcess){$view=[Microsoft.Win32.RegistryView]::Registry64}
    $root=$null;$key=$null
    try{$root=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::ClassesRoot,$view);$key=$root.OpenSubKey($SubKey);if($key){return [string]$key.GetValue($ValueName,$null)}}catch{}
    finally{if($key){$key.Dispose()};if($root){$root.Dispose()}}
    return ''
}
function Get-PreviewHandlerCapability {
    param([string]$Extension)
    if($Extension-notmatch '^\.[A-Za-z0-9]+$'){return [pscustomobject]@{Registered=$false;Handler='';Reason='格式无效。'}}
    $class=Get-PreviewRegistryValue $Extension
    $suffix='\shellex\{8895b1c6-b41f-4c1c-a562-0d564250836f}'
    foreach($key in @($Extension,('SystemFileAssociations\'+$Extension),$class)){
        if(-not $key){continue};$handler=Get-PreviewRegistryValue ($key+$suffix);$id=[guid]::Empty
        if($handler-and [guid]::TryParse($handler,[ref]$id)){
            return [pscustomobject]@{Registered=$true;Handler=$handler;Reason='已注册系统预览器；是否能正常打开仍以该文件实际预览为准。'}
        }
    }
    return [pscustomobject]@{Registered=$false;Handler='';Reason='未注册与当前进程匹配的系统预览器，使用内置备用预览。'}
}
function Get-RegisteredPreviewCapability {
    param([string]$Extension)
    return [bool](Get-PreviewHandlerCapability $Extension).Registered
}
function Get-WindowsPdfCapability {
    try{Add-Type -AssemblyName System.Runtime.WindowsRuntime;$null=[Windows.Data.Pdf.PdfDocument,Windows.Data.Pdf,ContentType=WindowsRuntime];return $true}catch{return $false}
}
function Get-ApplicationSignatureState {
    param([string]$Path)
    if(-not [IO.File]::Exists($Path)){return [pscustomobject]@{Status='Missing';Downloaded=$false;DownloadZone=0}}
    $status='UnknownError';try{$status=[string](Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop).Status}catch{}
    $zone=0
    try{$lines=@(Get-Content -LiteralPath $Path -Stream Zone.Identifier -ErrorAction Stop);foreach($line in $lines){if($line-match '^ZoneId=(\d+)$'){$zone=[int]$Matches[1]}}}catch{}
    return [pscustomobject]@{Status=$status;Downloaded=($zone-ge 3);DownloadZone=$zone}
}
function Get-ApplicationEnvironment {
    param([string]$Directory=$script:AppDir)
    if(-not $Directory){$Directory=$PSScriptRoot};$Directory=[IO.Path]::GetFullPath($Directory)
    $forms=$false;try{Add-Type -AssemblyName System.Windows.Forms,System.Drawing;$forms=$true}catch{}
    $ocr=[pscustomobject]@{Available=$false;Reason='未提供本机文字识别组件，仍可按文件名搜索和手动分类。';Languages=@()}
    if(Get-Command Get-OcrAvailability -ErrorAction SilentlyContinue){try{$ocr=Get-OcrAvailability}catch{}}
    $policy='Unknown';$policies=@();try{$policy=[string](Get-ExecutionPolicy);$policies=@(Get-ExecutionPolicy -List|ForEach-Object{[pscustomobject]@{Scope=[string]$_.Scope;Policy=[string]$_.ExecutionPolicy}})}catch{}
    $signature=Get-ApplicationSignatureState (Join-Path $Directory 'setup.ps1')
    $handlers=@{};foreach($ext in @('.pdf','.docx','.xlsx','.pptx')){$handlers[$ext]=Get-PreviewHandlerCapability $ext}
    $build='';try{$build=[string][Microsoft.Win32.Registry]::GetValue('HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion','CurrentBuildNumber','')}catch{}
    $version='';$versionFile=Join-Path $Directory 'VERSION';if([IO.File]::Exists($versionFile)){$version=[IO.File]::ReadAllText($versionFile).Trim()}
    $fallback=@('缺少 Office 或系统预览器时，Office 文档尝试正文预览，排版可能简化；可用默认应用打开原文件。','PDF 缺少系统预览器时使用 Windows PDF 渲染；渲染组件也不可用时，可用默认应用打开。','图片和文本使用内置预览；OCR 不可用或未启用时保留文件名搜索、目录筛选和手动分类。')
    return [pscustomobject]@{
        ApplicationVersion=$version;WindowsVersion=[Environment]::OSVersion.Version.ToString();WindowsBuild=$build
        PowerShellVersion=$PSVersionTable.PSVersion.ToString();PowerShellEdition=[string]$PSVersionTable.PSEdition;Process64Bit=[Environment]::Is64BitProcess
        SupportedPowerShell=($PSVersionTable.PSVersion.Major-eq 5-and $PSVersionTable.PSVersion-ge [version]'5.1');WinForms=$forms;WindowsPdf=(Get-WindowsPdfCapability)
        OcrAvailable=[bool]$ocr.Available;OcrReason=[string]$ocr.Reason;OcrLanguages=@($ocr.Languages);SystemPreviewHandlers=$handlers
        ExecutionPolicy=$policy;ExecutionPolicyScopes=$policies;EntrySignature=$signature.Status;EntryDownloaded=$signature.Downloaded
        InteractiveDesktop=[Environment]::UserInteractive;PolicyChangesMade=$false;Fallback=$fallback
        SigningNotice='当前源码发行版未使用可信证书签名。请核对发布页 SHA-256；程序不会更改系统策略或自动解除文件锁定。'
    }
}
function Show-ApplicationEnvironment {
    param($Owner=$null,[string]$Directory=$script:AppDir)
    $s=Get-ApplicationEnvironment -Directory $Directory
    $lines=@(('版本：'+$s.ApplicationVersion),('Windows：'+$s.WindowsVersion+'（内部版本 '+$s.WindowsBuild+'）'),('Windows PowerShell：'+$s.PowerShellVersion),('窗口组件：'+$s.WinForms),('Windows PDF 渲染组件：'+$s.WindowsPdf),('本机 OCR：'+$s.OcrAvailable+' '+$s.OcrReason),('入口签名：'+$s.EntrySignature),('当前脚本策略：'+$s.ExecutionPolicy),'')
    foreach($ext in @('.pdf','.docx','.xlsx','.pptx')){$lines+=($ext+' 系统预览器：'+$s.SystemPreviewHandlers[$ext].Registered)}
    $lines+=@('',$s.SigningNotice,'')+@($s.Fallback)
    if(-not $s.WinForms){return ($lines-join [Environment]::NewLine)}
    if(-not $Owner){$Owner=[Windows.Forms.Form]::ActiveForm}
    if($Owner-and $Owner.IsDisposed){$Owner=$null}
    [void][Windows.Forms.MessageBox]::Show($Owner,($lines-join [Environment]::NewLine),'奶龙.code · 运行环境',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information)
}
function Start-ApplicationWindow {
    $entry=Join-Path $script:AppDir 'setup.ps1'
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments='-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "'+$entry+'" -Launch'
    Start-Process -FilePath $shell -WindowStyle Hidden -ArgumentList $arguments
}
