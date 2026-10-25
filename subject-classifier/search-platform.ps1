# Desktop capabilities and DPI initialization.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

try {
    $dpiCode = @'
using System;
using System.Runtime.InteropServices;
public class SubjectSearchDpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
}
'@
    Add-Type -TypeDefinition $dpiCode
} catch { Write-Log ('search-platform.ps1 UI fallback: '+$_.Exception.Message) -Level INFO }
$dpiAware = $false
try { $dpiAware = [SubjectSearchDpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { Write-Log ('search-platform.ps1 UI fallback: '+$_.Exception.Message) -Level INFO }
if (-not $dpiAware) {
    try { [SubjectSearchDpi]::SetProcessDPIAware() | Out-Null } catch { Write-Log ('search-platform.ps1 UI fallback: '+$_.Exception.Message) -Level INFO }
}
$script:InitialQuery = ''
$script:InitialSubject = ''
$script:InitialContent = $true
$script:InitialCenter = $null
$script:Dpi = 0
if (-not [string]::IsNullOrEmpty($RestoreFile) -and (Test-Path -LiteralPath $RestoreFile)) {
    try {
        $restore = [System.IO.File]::ReadAllText($RestoreFile, $script:Utf8) | ConvertFrom-Json
        $script:InitialQuery = [string]$restore.Query
        $script:InitialSubject = [string]$restore.Subject
        $script:InitialContent = [bool]$restore.Content
        $script:InitialCenter = New-Object System.Drawing.Point([int]$restore.CenterX, [int]$restore.CenterY)
        $script:Dpi = [int]$restore.Dpi
    } catch { Write-Log ('search-platform.ps1 UI fallback: '+$_.Exception.Message) -Level INFO }
    Remove-Item -LiteralPath $RestoreFile -Force -ErrorAction SilentlyContinue
}
if ($script:Dpi -le 0) {
    $dpiGraphics = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:Dpi = $dpiGraphics.DpiX
    $dpiGraphics.Dispose()
}
$script:Scale = [Math]::Max(1.0, [double]$script:Dpi / 96.0)
function S {
    param([double]$V)
    return [int][Math]::Round($V * $script:Scale)
}

$uiCode = @'
namespace SubjectSearchUi {
    public class SmoothListView : System.Windows.Forms.ListView {
        public SmoothListView() {
            this.DoubleBuffered = true;
            this.SetStyle(System.Windows.Forms.ControlStyles.OptimizedDoubleBuffer | System.Windows.Forms.ControlStyles.AllPaintingInWmPaint, true);
            this.UpdateStyles();
        }
    }
}
'@
$formType = 'System.Windows.Forms.Form'
$listType = 'System.Windows.Forms.ListView'
try {
    Add-Type -TypeDefinition $uiCode -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'
    $listType = 'SubjectSearchUi.SmoothListView'
} catch { Write-Log ('search-platform.ps1 UI fallback: '+$_.Exception.Message) -Level INFO }
