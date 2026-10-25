param([string]$Output = '',[switch]$Headless)
$ErrorActionPreference = 'Stop'
$Headless = $Headless -or $env:NAILONG_TEST_HEADLESS -eq '1'
$skipped = New-Object Collections.ArrayList
$source = Split-Path $PSScriptRoot -Parent
. (Join-Path $source 'lib.ps1')
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DialogTestNative {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr handle, uint command);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint current, uint foreground, bool attach);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr handle);
}
'@

# The dialog module has no watcher startup side effects and can be loaded directly.
. (Join-Path $source 'classifier-dialog.ps1')
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'extra-ui.ps1'),[ref]$tokens,[ref]$errors)
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-DirectoryManager'},$false)
if (-not $definition -or @($errors).Count) { throw 'Directory manager test could not load its definition.' }
Invoke-Expression $definition.Extent.Text
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
$script:FocusDiagnostics=New-Object Collections.ArrayList
$script:DirectoryInputDiagnostics=New-Object Collections.ArrayList
$savedInputLanguage=[Windows.Forms.InputLanguage]::CurrentInputLanguage
$asciiInputLanguage=@([Windows.Forms.InputLanguage]::InstalledInputLanguages|Where-Object {$_.Culture.Name -eq 'en-US'}|Select-Object -First 1)
if(-not $Headless -and $asciiInputLanguage.Count){[Windows.Forms.InputLanguage]::CurrentInputLanguage=$asciiInputLanguage[0]}
function Check([string]$Label,[bool]$Passed) {
    [void]$checks.Add(@{Name=$Label;Passed=$Passed})
    Write-Output ((@('FAIL','PASS')[[int]$Passed])+' '+$Label)
}
function All-Controls($Parent) {
    foreach($control in $Parent.Controls) { $control; All-Controls $control }
}
function Update-DirectoryChoices { $script:ChoicesRefreshed=$true }
function Update-NavigationTree { $script:TreeRefreshed=$true }

function Activate-DialogTestOwner($Owner) {
    if($Headless){return}
    # Simulate selecting the test application first. Do not focus the dialog being asserted.
    $foreground=[DialogTestNative]::GetForegroundWindow();$foregroundProcess=[uint32]0
    $foregroundThread=[DialogTestNative]::GetWindowThreadProcessId($foreground,[ref]$foregroundProcess)
    $currentThread=[DialogTestNative]::GetCurrentThreadId();$attached=$false
    try{
        if($foregroundThread -and $foregroundThread -ne $currentThread){$attached=[DialogTestNative]::AttachThreadInput($currentThread,$foregroundThread,$true)}
        $Owner.BringToFront();[void][DialogTestNative]::SetForegroundWindow($Owner.Handle);$Owner.Activate()
        [Windows.Forms.Application]::DoEvents()
    }finally{if($attached){[void][DialogTestNative]::AttachThreadInput($currentThread,$foregroundThread,$false)}}
}

$form=New-Object Windows.Forms.Form
$form.Text='Dialog regression test owner'; $form.Size=New-Object Drawing.Size(500,260)
$form.StartPosition='CenterScreen'; $form.Show(); Activate-DialogTestOwner $form
try {
    # Exercise the real nested "new directory" button on the topmost classifier popup.
    $state=@{Deadline=(Get-Date).AddSeconds(10);Launched=$false;Handled=$false}
    $timer=New-Object Windows.Forms.Timer; $timer.Interval=180
    $timer.Add_Tick({
        try {
            $windows=@([Windows.Forms.Application]::OpenForms)
            $input=$windows | Where-Object { @((All-Controls $_) | Where-Object { $_ -is [Windows.Forms.TextBox] -and -not $_.ReadOnly }).Count -gt 0 } | Select-Object -First 1
            if($input -and -not $state.Handled) {
                $box=(All-Controls $input) | Where-Object { $_ -is [Windows.Forms.TextBox] -and -not $_.ReadOnly } | Select-Object -First 1
                if($state.TypedSent) {
                    # SendKeys can return before posted characters are consumed. Submit only after the real input catches up.
                    if($box.Text -eq 'new-directory-123'){$state.Handled=$true;[Windows.Forms.SendKeys]::SendWait('{ENTER}')}
                    elseif((Get-Date) -ge $state.TypedDeadline){$state.Handled=$true;Check 'Nested keyboard input is delivered completely' $false;$input.DialogResult='Cancel';$input.Close()}
                    return
                }
                $parent=$windows | Where-Object { $_ -ne $input -and $_ -ne $form } | Select-Object -First 1
                if(-not $state.FocusDeadline) {
                    if(-not $Headless){$box.ImeMode='Disable'}
                    $state.FocusDeadline=(Get-Date).AddSeconds(3)
                    Check 'Nested input has an explicit classifier owner' ($input.Owner -eq $parent -and $null -ne $parent)
                    Check 'Nested input remains above its topmost owner' $input.TopMost
                }
                # Shown/BeginInvoke and foreground activation need more than one timer tick.
                # Never send keystrokes until the actual target owns keyboard focus.
                $ready=$Headless -or ($box.ContainsFocus -and [DialogTestNative]::GetForegroundWindow() -eq $input.Handle)
                if($ready -or (Get-Date) -ge $state.FocusDeadline) {
                    $state.Handled=$true
                    if($Headless) {
                        [void]$skipped.Add('Nested input receives foreground and keyboard focus (requires an interactive desktop)')
                        Check 'Headless nested input remains editable' ($box.Enabled -and -not $box.ReadOnly)
                    } else { Check 'Nested input receives foreground and keyboard focus' $ready }
                    if($ready) {
                        if($Headless) { $box.Text='new-directory-123'; $input.AcceptButton.PerformClick() }
                        else { $state.Handled=$false;$state.TypedSent=$true;$state.TypedDeadline=(Get-Date).AddSeconds(3);if($asciiInputLanguage.Count){[Windows.Forms.InputLanguage]::CurrentInputLanguage=$asciiInputLanguage[0]};[Windows.Forms.SendKeys]::SendWait('new-directory-123') }
                    } else { $input.DialogResult='Cancel'; $input.Close(); $parent.Close() }
                }
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
    $script:NestedTestResult=@{Action=$result.Action;NameLength=([string]$result.Name).Length;SyntheticName=[string]$result.Name;Language=[string]([Windows.Forms.InputLanguage]::CurrentInputLanguage.Culture.Name)}
    Check 'Classifier returns the typed new directory' ($result.Action -eq 'new' -and $result.Name -eq 'new-directory-123')

    foreach($mode in @('save','cancel','reopen')) {
        Activate-DialogTestOwner $form
        $state=@{Deadline=(Get-Date).AddSeconds(8);Handled=$false;Mode=$mode}
        $timer=New-Object Windows.Forms.Timer; $timer.Interval=200
        $timer.Add_Tick({
            try {
                $dialog=@([Windows.Forms.Application]::OpenForms) | Where-Object { $_.Text -eq '奶龙select · 管理目录与分类规则' } | Select-Object -First 1
                if($dialog -and -not $state.Handled) {
                    $box=(All-Controls $dialog) | Where-Object { $_ -is [Windows.Forms.ComboBox] } | Select-Object -First 1
                    if($state.TypedSent) {
                        # SendWait may finish before posted text is consumed. Keep submission separate,
                        # just as the nested input test does, and never submit into a different window.
                        if($state.SendingText){return}
                        $inputReady=$box.Text -ceq $state.ExpectedText -and $box.ContainsFocus -and [DialogTestNative]::GetForegroundWindow() -eq $dialog.Handle
                        if($inputReady) {
                            $state.Handled=$true
                            Check ($state.Mode+': keyboard input is complete before submitting') $true
                            [void]$state.InputEvents.Add(@{Kind='Submit';Text=[string]$box.Text;Key=$state.SubmitKey;Utc=[datetime]::UtcNow.ToString('o')})
                            [Windows.Forms.SendKeys]::SendWait($state.SubmitKey)
                        } elseif((Get-Date) -ge $state.TypedDeadline) {
                            $state.Handled=$true
                            Check ($state.Mode+': keyboard input is complete before submitting') $false
                            $dialog.DialogResult='Cancel';$dialog.Close()
                        }
                        return
                    }
                    if(-not $state.FocusDeadline) {
                        if(-not $Headless){$box.ImeMode='Disable'}
                        $state.InputEvents=New-Object Collections.ArrayList
                        $box.Add_TextChanged({[void]$state.InputEvents.Add(@{Kind='TextChanged';Text=[string]$box.Text;Utc=[datetime]::UtcNow.ToString('o')})}.GetNewClosure())
                        $dialog.Add_FormClosing({[void]$state.InputEvents.Add(@{Kind='Closing';Text=[string]$box.Text;Result=[string]$dialog.DialogResult;Utc=[datetime]::UtcNow.ToString('o')})}.GetNewClosure())
                        $state.FocusDeadline=(Get-Date).AddSeconds(3)
                        Check ($state.Mode+': directory manager is owned by the library') ($dialog.Owner -eq $form)
                    }
                    $ready=$Headless -or ($box.ContainsFocus -and [DialogTestNative]::GetForegroundWindow() -eq $dialog.Handle)
                    if($ready -or (Get-Date) -ge $state.FocusDeadline) {
                        if(-not $ready -and -not $Headless){
                            $fgHandle=[DialogTestNative]::GetForegroundWindow();$fgProcess=[uint32]0
                            [void][DialogTestNative]::GetWindowThreadProcessId($fgHandle,[ref]$fgProcess)
                            $fgName='';try{$fgName=[Diagnostics.Process]::GetProcessById([int]$fgProcess).ProcessName}catch{}
                            [void]$script:FocusDiagnostics.Add(@{Mode=$state.Mode;Expected=$dialog.Handle.ToInt64();Foreground=$fgHandle.ToInt64();ForegroundProcess=$fgName;SameProcess=($fgProcess -eq $PID);DialogFocus=$dialog.ContainsFocus;InputFocus=$box.ContainsFocus;OwnerFocus=$form.ContainsFocus;OwnerTopMost=$form.TopMost;DialogTopMost=$dialog.TopMost;InputEnabled=$box.Enabled;ActiveControl=[string]$dialog.ActiveControl})
                        }
                        $state.Handled=$true
                        if($Headless) {
                            [void]$skipped.Add($state.Mode+': directory field has keyboard focus (requires an interactive desktop)')
                            Check ($state.Mode+': headless directory field stays editable') ($box.Enabled -and $box.DropDownStyle -ne 'DropDownList')
                        } else { Check ($state.Mode+': directory field has keyboard focus') $ready }
                        if($ready) {
                            $text='directory-'+$state.Mode
                            if($state.Mode -eq 'save') {
                                Check 'Enter is connected to saving the directory' ($null -ne $dialog.AcceptButton)
                                if($Headless) { $box.Text=$text; $dialog.AcceptButton.PerformClick() }
                            } else {
                                Check ($state.Mode+': Escape can cancel the dialog') ($null -ne $dialog.CancelButton)
                                if($Headless) { $box.Text=$text; $dialog.CancelButton.PerformClick() }
                            }
                            if(-not $Headless) {
                                if($asciiInputLanguage.Count){[Windows.Forms.InputLanguage]::CurrentInputLanguage=$asciiInputLanguage[0]}
                                $state.ExpectedText=$text;$state.SubmitKey=if($state.Mode -eq 'save'){'{ENTER}'}else{'{ESC}'}
                                $state.TypedSent=$true;$state.TypedDeadline=(Get-Date).AddSeconds(3)
                                $state.Handled=$false;$state.SendingText=$true
                                try{[Windows.Forms.SendKeys]::SendWait($text)}finally{$state.SendingText=$false}
                            }
                        } else { $dialog.Close() }
                    }
                }
                if((Get-Date) -gt $state.Deadline -and $dialog) { Check 'Directory manager finishes without blocking' $false; $dialog.Close() }
            } catch { Check ('Directory manager error: '+$_.Exception.Message) $false; if($dialog){$dialog.Close()} }
        }.GetNewClosure())
        $timer.Start()
        try { Show-DirectoryManager } finally { $timer.Stop(); $timer.Dispose() }
        $directoryInput=@{Mode=$mode;Events=@($state.InputEvents);CreatedDirectories=@(Get-ChildItem -LiteralPath $script:Root -Directory | ForEach-Object Name)}
        [void]$script:DirectoryInputDiagnostics.Add($directoryInput)
        Write-Output ('DIALOG INPUT '+($directoryInput|ConvertTo-Json -Depth 5 -Compress))
        Check ($mode+': modal state is released after closing') (-not $script:UiUpdating -and $form.Enabled)
    }
    Check 'Saving creates the actual test directory' (Test-Path -LiteralPath (Join-Path $script:Root 'directory-save') -PathType Container)
    $saved=[IO.File]::ReadAllText($script:ConfigPath,$script:Utf8) | ConvertFrom-Json
    Check 'Saved directory persists in the configuration' (@($saved.subjects | Where-Object name -eq 'directory-save').Count -eq 1)
    Check 'Cancel creates no directory' (-not (Test-Path -LiteralPath (Join-Path $script:Root 'directory-cancel')))
    Check 'Saving refreshes the directory tree' ([bool]$script:TreeRefreshed)
} finally {
    $form.Close(); $form.Dispose()
    if(-not $Headless -and $savedInputLanguage){[Windows.Forms.InputLanguage]::CurrentInputLanguage=$savedInputLanguage}
}
$report=@{Passed=@($checks | Where-Object Passed).Count;Failed=@($checks | Where-Object {-not $_.Passed}).Count;Checks=@($checks.ToArray());NestedTestResult=$script:NestedTestResult;FocusDiagnostics=@($script:FocusDiagnostics.ToArray());DirectoryInputDiagnostics=@($script:DirectoryInputDiagnostics.ToArray());Headless=[bool]$Headless;SkippedInteractiveAssertions=@($skipped.ToArray())}
if(-not $Output){$Output=Join-Path $PSScriptRoot 'dialog-results.json'}
[IO.File]::WriteAllText($Output,($report | ConvertTo-Json -Depth 5),$script:Utf8)
Write-Output ('TOTAL passed='+$report.Passed+' failed='+$report.Failed)
if($report.Failed){exit 1}
