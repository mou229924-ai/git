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
    $ocr=[pscustomobject]@{Available=$false;Reason='未提供本机文字识别组件；带文字层 PDF 仍由随包解析器提取，扫描页和图片保留文件名搜索。';Languages=@()}
    if(Get-Command Get-OcrAvailability -ErrorAction SilentlyContinue){try{$ocr=Get-OcrAvailability}catch{}}
    $pdfText=[pscustomobject]@{Available=$false;Engine='';Reason='未加载 PDF 文字层诊断模块，请使用完整程序包。';Missing=@()}
    $pdfCommand=Get-Command Get-PdfTextAvailability -ErrorAction SilentlyContinue
    if($pdfCommand){
        try{
            if($pdfCommand.Parameters.ContainsKey('Directory')){$capability=Get-PdfTextAvailability -Directory $Directory}
            else{$capability=Get-PdfTextAvailability}
            $expected=Join-Path $Directory 'third-party\pdfpig'
            if([IO.Path]::GetFullPath([string]$capability.Directory).TrimEnd('\') -ne [IO.Path]::GetFullPath($expected).TrimEnd('\')){
                $pdfText.Reason='PDF 解析器来自其他目录，请在目标程序中运行诊断。'
            }else{
                $pdfText.Available=[bool]$capability.Available
                $pdfText.Engine=[string]$capability.Engine
                $pdfText.Missing=@($capability.Missing|Where-Object {$_})
                $pdfText.Reason=[string]$capability.Reason
                if($pdfText.Available){$pdfText.Reason='组件文件检查通过；尚未读取任何 PDF，实际提取结果由单份文档任务报告。'}
            }
        }catch{$pdfText.Reason='PDF 文字层组件检查失败：'+$_.Exception.Message}
    }
    $policy='Unknown';$policies=@();try{$policy=[string](Get-ExecutionPolicy);$policies=@(Get-ExecutionPolicy -List|ForEach-Object{[pscustomobject]@{Scope=[string]$_.Scope;Policy=[string]$_.ExecutionPolicy}})}catch{}
    $signature=Get-ApplicationSignatureState (Join-Path $Directory 'setup.ps1')
    $handlers=@{};foreach($ext in @('.pdf','.docx','.xlsx','.pptx')){$handlers[$ext]=Get-PreviewHandlerCapability $ext}
    $build='';try{$build=[string][Microsoft.Win32.Registry]::GetValue('HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion','CurrentBuildNumber','')}catch{}
    $version='';$versionFile=Join-Path $Directory 'VERSION';if([IO.File]::Exists($versionFile)){$version=[IO.File]::ReadAllText($versionFile).Trim()}
    $fallback=@('缺少 Office 或系统预览器时，Office 文档尝试正文预览，排版可能简化；可用默认应用打开原文件。','PDF 缺少系统预览器时使用 Windows PDF 渲染；渲染组件也不可用时，可用默认应用打开。','带文字层 PDF 默认由随包解析器离线提取正文；OCR 不可用或未启用不会关闭文字层索引。','扫描页和图片的 OCR 可选；无法识别时保留文件名搜索、目录筛选和手动分类。','PDF 提取受页数、大小、总等待和内存限制，达到上限时保留已提取正文并报告具体原因。')
    return [pscustomobject]@{
        ApplicationVersion=$version;WindowsVersion=[Environment]::OSVersion.Version.ToString();WindowsBuild=$build
        PowerShellVersion=$PSVersionTable.PSVersion.ToString();PowerShellEdition=[string]$PSVersionTable.PSEdition;Process64Bit=[Environment]::Is64BitProcess
        SupportedPowerShell=($PSVersionTable.PSVersion.Major-eq 5-and $PSVersionTable.PSVersion-ge [version]'5.1');WinForms=$forms;WindowsPdf=(Get-WindowsPdfCapability)
        PdfTextAvailable=[bool]$pdfText.Available;PdfTextEngine=[string]$pdfText.Engine;PdfTextCheck='ComponentFilesOnly';PdfTextReason=[string]$pdfText.Reason;PdfTextMissing=@($pdfText.Missing)
        OcrAvailable=[bool]$ocr.Available;OcrReason=[string]$ocr.Reason;OcrLanguages=@($ocr.Languages);SystemPreviewHandlers=$handlers
        ExecutionPolicy=$policy;ExecutionPolicyScopes=$policies;EntrySignature=$signature.Status;EntryDownloaded=$signature.Downloaded
        InteractiveDesktop=[Environment]::UserInteractive;PolicyChangesMade=$false;Fallback=$fallback
        SigningNotice='当前源码发行版未使用可信证书签名。请核对发布页 SHA-256；程序不会更改系统策略或自动解除文件锁定。'
    }
}
function Show-ApplicationEnvironment {
    param($Owner=$null,[string]$Directory=$script:AppDir)
    $s=Get-ApplicationEnvironment -Directory $Directory
    $lines=@(('版本：'+$s.ApplicationVersion),('Windows：'+$s.WindowsVersion+'（内部版本 '+$s.WindowsBuild+'）'),('Windows PowerShell：'+$s.PowerShellVersion),('窗口组件：'+$s.WinForms),('Windows PDF 渲染组件：'+$s.WindowsPdf),('PDF 文字层组件（文件检查）：'+$s.PdfTextAvailable+' '+$s.PdfTextEngine),$s.PdfTextReason,('本机 OCR：'+$s.OcrAvailable+' '+$s.OcrReason),('入口签名：'+$s.EntrySignature),('当前脚本策略：'+$s.ExecutionPolicy),'')
    foreach($ext in @('.pdf','.docx','.xlsx','.pptx')){$lines+=($ext+' 系统预览器：'+$s.SystemPreviewHandlers[$ext].Registered)}
    $lines+=@('',$s.SigningNotice,'')+@($s.Fallback)
    if(-not $s.WinForms){return ($lines-join [Environment]::NewLine)}
    if(-not $Owner){$Owner=[Windows.Forms.Form]::ActiveForm}
    if($Owner-and $Owner.IsDisposed){$Owner=$null}
    [void][Windows.Forms.MessageBox]::Show($Owner,($lines-join [Environment]::NewLine),'奶龙select · 运行环境',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information)
}
function Start-ApplicationWindow {
    $entry=Join-Path $script:AppDir 'setup.ps1'
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments='-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "'+$entry+'" -Launch'
    Start-Process -FilePath $shell -WindowStyle Hidden -ArgumentList $arguments
}
