param([string]$Output = '')
$ErrorActionPreference = 'Stop'
$source = Split-Path $PSScriptRoot -Parent
. (Join-Path $source 'lib.ps1')
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DialogTestNative {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr handle, uint command);
}
'@

# Load the actual dialog functions without starting the watcher or the library window.
foreach ($entry in @(@('classifier.ps1',@('S','Update-UiScale','Show-SubjectDialog')), @('extra-ui.ps1',@('Show-DirectoryManager')))) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source $entry[0]),[ref]$tokens,[ref]$errors)
    foreach ($name in $entry[1]) {
        $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$false)
        Invoke-Expression $definition.Extent.Text
    }
}
$script:Scale=1.0
$scratch=Join-Path $source ('test-runs\dialogs-'+[guid]::NewGuid().ToString('N'))
$script:Root=Join-Path $scratch 'library'
$script:ConfigPath=Join-Path $scratch 'config.json'
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
$script:Cfg.inbox=$script:Root
Write-AtomicUtf8 $script:ConfigPath ($script:Cfg | ConvertTo-Json -Depth 12)
$script:UiUpdating=$false
$script:ColBg=[Drawing.Color]::FromArgb(255,251,240)
$script:ColText2=[Drawing.Color]::FromArgb(126,114,88)
$script:ColSurface=[Drawing.Color]::FromArgb(250,241,212)
$checks=New-Object Collections.ArrayList
function Check([string]$Label,[bool]$Passed) {
    [void]$checks.Add(@{Name=$Label;Passed=$Passed})
    Write-Output ((@('FAIL','PASS')[[int]$Passed])+' '+$Label)
}
function All-Controls($Parent) {
    foreach($control in $Parent.Controls) { $control; All-Controls $control }
}
function Update-DirectoryChoices { $script:ChoicesRefreshed=$true }
function Update-NavigationTree { $script:TreeRefreshed=$true }

$form=New-Object Windows.Forms.Form
$form.Text='Dialog regression test owner'; $form.Size=New-Object Drawing.Size(500,260)
$form.StartPosition='CenterScreen'; $form.Show(); $form.Activate()
try {
    # Exercise the real nested "new directory" button on the topmost classifier popup.
    $state=@{Deadline=(Get-Date).AddSeconds(10);Launched=$false;Handled=$false}
    $timer=New-Object Windows.Forms.Timer; $timer.Interval=180
    $timer.Add_Tick({
        try {
            $windows=@([Windows.Forms.Application]::OpenForms)
            $input=$windows | Where-Object { @((All-Controls $_) | Where-Object { $_ -is [Windows.Forms.TextBox] -and -not $_.ReadOnly }).Count -gt 0 } | Select-Object -First 1
            if($state.Sent -and -not $state.Finished) {
                $state.Finished=$true
                # Verify delivered text from the returned value after the modal loop completes.
                [Windows.Forms.SendKeys]::SendWait('{ENTER}')
            } elseif($input -and -not $state.Handled) {
                $state.Handled=$true
                $box=(All-Controls $input) | Where-Object { $_ -is [Windows.Forms.TextBox] -and -not $_.ReadOnly } | Select-Object -First 1
                $parent=$windows | Where-Object { $_ -ne $input -and $_ -ne $form } | Select-Object -First 1
                Check 'Nested input has an explicit classifier owner' ($input.Owner -eq $parent -and $null -ne $parent)
                Check 'Nested input remains above its topmost owner' $input.TopMost
                $ready=($box.ContainsFocus -and [DialogTestNative]::GetForegroundWindow() -eq $input.Handle)
                Check 'Nested input receives foreground and keyboard focus' $ready
                if($ready) {
                    $state.Box=$box; $state.Sent=$true
                    [Windows.Forms.SendKeys]::SendWait('new-directory-123')
                } else { $input.DialogResult='Cancel'; $input.Close(); $parent.Close() }
            } elseif(-not $state.Launched) {
                $parent=$windows | Where-Object { $_ -ne $form } | Select-Object -First 1
                if($parent) {
                    $button=(All-Controls $parent) | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq [string]$script:Cfg.popup.newSubject } | Select-Object -First 1
                    $state.Launched=$true
                    [void]$parent.BeginInvoke([Action]{$button.PerformClick()}.GetNewClosure())
                }
            }
            if((Get-Date) -gt $state.Deadline) {
                Check 'Nested dialog finishes without blocking' $false
                foreach($window in $windows) { if($window -ne $form){$window.Close()} }
            }
        } catch { Check ('Nested dialog error: '+$_.Exception.Message) $false; foreach($window in @([Windows.Forms.Application]::OpenForms)){if($window -ne $form){$window.Close()}} }
    }.GetNewClosure())
    $timer.Start()
    try { $result=Show-SubjectDialog -FileName 'test.txt' -Prompt 'Choose a test directory' -HasSnippet $false }
    finally { $timer.Stop(); $timer.Dispose() }
    Check 'Classifier returns the typed new directory' ($result.Action -eq 'new' -and $result.Name -eq 'new-directory-123')

    foreach($mode in @('save','cancel','reopen')) {
        $state=@{Deadline=(Get-Date).AddSeconds(8);Handled=$false;Mode=$mode}
        $timer=New-Object Windows.Forms.Timer; $timer.Interval=200
        $timer.Add_Tick({
            try {
                $dialog=@([Windows.Forms.Application]::OpenForms) | Where-Object { $_.Text -eq '奶龙.code · 管理目录与分类规则' } | Select-Object -First 1
                if($state.Sent -and -not $state.Finished) {
                    $state.Finished=$true
                    if($state.Mode -eq 'save') {
                        Check 'Enter is connected to saving the directory' ($null -ne $dialog.AcceptButton)
                        if($dialog.AcceptButton){[Windows.Forms.SendKeys]::SendWait('{ENTER}')}else{((All-Controls $dialog) | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq '保存目录与规则' } | Select-Object -First 1).PerformClick()}
                    } else {
                        Check ($state.Mode+': Escape can cancel the dialog') ($null -ne $dialog.CancelButton)
                        if($dialog.CancelButton){[Windows.Forms.SendKeys]::SendWait('{ESC}')}else{$dialog.Close()}
                    }
                } elseif($dialog -and -not $state.Handled) {
                    $state.Handled=$true
                    $box=(All-Controls $dialog) | Where-Object { $_ -is [Windows.Forms.ComboBox] } | Select-Object -First 1
                    Check ($state.Mode+': directory manager is owned by the library') ($dialog.Owner -eq $form)
                    $ready=($box.ContainsFocus -and [DialogTestNative]::GetForegroundWindow() -eq $dialog.Handle)
                    Check ($state.Mode+': directory field has keyboard focus') $ready
                    if($ready) {
                        $text='directory-'+$state.Mode
                        $state.Box=$box; $state.Text=$text; $state.Sent=$true
                        [Windows.Forms.SendKeys]::SendWait($text)
                    } else { $dialog.Close() }
                }
                if((Get-Date) -gt $state.Deadline -and $dialog) { Check 'Directory manager finishes without blocking' $false; $dialog.Close() }
            } catch { Check ('Directory manager error: '+$_.Exception.Message) $false; if($dialog){$dialog.Close()} }
        }.GetNewClosure())
        $timer.Start()
        try { Show-DirectoryManager } finally { $timer.Stop(); $timer.Dispose() }
        Check ($mode+': modal state is released after closing') (-not $script:UiUpdating -and $form.Enabled)
    }
    Check 'Saving creates the actual test directory' (Test-Path -LiteralPath (Join-Path $script:Root 'directory-save') -PathType Container)
    $saved=[IO.File]::ReadAllText($script:ConfigPath,$script:Utf8) | ConvertFrom-Json
    Check 'Saved directory persists in the configuration' (@($saved.subjects | Where-Object name -eq 'directory-save').Count -eq 1)
    Check 'Cancel creates no directory' (-not (Test-Path -LiteralPath (Join-Path $script:Root 'directory-cancel')))
    Check 'Saving refreshes the directory tree' ([bool]$script:TreeRefreshed)
} finally {
    $form.Close(); $form.Dispose()
}
$report=@{Passed=@($checks | Where-Object Passed).Count;Failed=@($checks | Where-Object {-not $_.Passed}).Count;Checks=@($checks.ToArray())}
if(-not $Output){$Output=Join-Path $PSScriptRoot 'dialog-results.json'}
[IO.File]::WriteAllText($Output,($report | ConvertTo-Json -Depth 5),$script:Utf8)
Write-Output ('TOTAL passed='+$report.Passed+' failed='+$report.Failed)
if($report.Failed){exit 1}
