param(
    [switch]$SelfTest,
    [switch]$EnsureRunning,
    [switch]$SelfTestForm,
    [string]$Inspect,
    [string]$CaptureDialog = ''
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib.ps1')

foreach ($module in @('classifier-dialog.ps1','classifier-scan.ps1','classifier-tray.ps1','classifier-diagnostics.ps1')) {
    . (Join-Path $PSScriptRoot $module)
}
Initialize-ClassifierUi

if (-not [string]::IsNullOrEmpty($CaptureDialog)) {
    $capPrompt = [string]$script:Cfg.popup.ambiguous
    $capSep = [string]$script:Cfg.popup.candidatesSeparator
    $capHint = [string]$script:Cfg.popup.candidatesLabel + 'A' + $capSep + 'B'
    Show-SubjectDialog -FileName 'example-file.docx' -Prompt $capPrompt -Hint $capHint -Snippet 'preview text for layout check' -HasSnippet $true -CapturePath $CaptureDialog | Out-Null
    exit
}

if ($SelfTestForm) {
    try {
        $result = Show-SubjectDialog -FileName 'example.pdf' -Prompt ([string]$script:Cfg.popup.unknown) -Hint ([string]$script:Cfg.popup.candidatesLabel + 'test') -Snippet '' -HasSnippet $false -BuildOnly
        Write-Output ('form build: ' + $result.Action)
    } catch {
        Write-Output ('form build failed: ' + $_.Exception.Message)
    }
    exit
}

if ($SelfTest) {
    Run-SelfTest
    exit
}

if (-not [string]::IsNullOrWhiteSpace($Inspect)) {
    Invoke-Inspect -Target $Inspect
    exit
}

$script:Mutex = $null
$createdNew = $false
try {
    $script:Mutex = New-Object System.Threading.Mutex($true, ('Local\SubjectAutoClassifier_' + (Get-IndexId ([IO.Path]::GetFullPath($script:Root)))), [ref]$createdNew)
    if (-not $createdNew) {
        if ($EnsureRunning) { exit }
        Add-Type -AssemblyName System.Windows.Forms
        [System.Media.SystemSounds]::Exclamation.Play()
        [void][System.Windows.Forms.MessageBox]::Show([string]$script:Cfg.tray.alreadyRunning, [string]$script:Cfg.tray.title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        exit
    }
} catch {
}

if (-not (Test-Path -LiteralPath $script:Root)) {
    New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
}

Initialize-ClassifierState


Write-Log 'watcher started (tray, folders, index)'
Start-TrayApp
