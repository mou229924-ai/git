# Local training is a background task; explicit classification rules retain priority.
$script:TrainingJob=$null;$script:LastTrainingAttempt=[datetime]::MinValue;$script:LastTrainingSignature=0
$learnMenu=New-Object Windows.Forms.ToolStripMenuItem;$learnMenu.Text='从现有文件夹学习分类规则'
[void]$moreMenu.Items.Add($learnMenu)
$learnAutoMenu=New-Object Windows.Forms.ToolStripMenuItem;$learnAutoMenu.Text='启用本地学习与自动更新';$learnAutoMenu.CheckOnClick=$true;$learnAutoMenu.Checked=[bool]$script:Cfg.learning.enabled
[void]$moreMenu.Items.Add($learnAutoMenu)
$script:LearningSettingUpdating=$false
$learnAutoMenu.Add_CheckedChanged({
    if($script:LearningSettingUpdating){return}
    try{
        Invoke-LibraryLock -Timeout 250 {
            $cfg=[IO.File]::ReadAllText($script:ConfigPath,$script:Utf8)|ConvertFrom-Json
            $cfg.learning.enabled=$learnAutoMenu.Checked
            Write-AtomicUtf8 $script:ConfigPath ($cfg|ConvertTo-Json -Depth 20)
            $script:Cfg=$cfg
        }
    }catch{$script:LearningSettingUpdating=$true;try{$learnAutoMenu.Checked=[bool]$script:Cfg.learning.enabled}finally{$script:LearningSettingUpdating=$false};$lblStatus.Text='学习设置未保存：'+$_.Exception.Message}
})
function Start-LibraryTraining {
    if($script:TrainingJob){return}
    if($script:IndexJob){$lblStatus.Text='索引更新完成后即可学习分类规则。';return}
    $script:LastTrainingAttempt=[datetime]::UtcNow
    if([IO.File]::Exists($script:IndexManifest)){$script:LastTrainingSignature=(Get-Item -LiteralPath $script:IndexManifest).LastWriteTimeUtc.Ticks}
    $script:TrainingJob=Start-LibraryJob @{Task='train'}
    $learnMenu.Enabled=$false;$lblStatus.Text='正在后台学习现有文件夹，原文件保持不动…'
}
$learnMenu.Add_Click({Start-LibraryTraining})
$stopLearningMenu=New-Object Windows.Forms.ToolStripMenuItem;$stopLearningMenu.Text='停止本次学习'
$stopLearningMenu.Add_Click({if($script:TrainingJob){Close-LibraryJob $script:TrainingJob -Stop;$script:TrainingJob=$null;$learnMenu.Enabled=$true;$lblStatus.Text='本次学习已停止，已通过验证的旧模型保持可用。'}})
[void]$moreMenu.Items.Add($stopLearningMenu)

$trainingTimer=New-Object Windows.Forms.Timer;$trainingTimer.Interval=500
$trainingTimer.Add_Tick({
    if($script:TrainingJob){
        $job=$script:TrainingJob;$state=Read-LibraryJob $job
        if($state -and $state.State -eq 'running'){$lblStatus.Text='学习分类规则  '+$state.Data.Done+' / '+$state.Data.Total+'  '+$state.Data.Name}
        if($state -and $state.State -in @('done','failed')){
            Close-LibraryJob $job;$script:TrainingJob=$null;$learnMenu.Enabled=$true
            if($state.State -eq 'failed'){$lblStatus.Text='学习未完成：'+$state.Error}
            elseif($state.Data.Published){$lblStatus.Text='学习完成：'+$state.Data.Labels.Count+' 个目录，'+$state.Data.SampleCount+' 份样本，留出验证 '+$state.Data.Validation.Correct+' / '+$state.Data.Validation.Tested+'，正确率 '+([Math]::Round(100*$state.Data.Validation.Accuracy))+'%。'}
            else{$lblStatus.Text=[string]$state.Data.Reason}
        }elseif($job.Process.HasExited -and (-not $state -or $state.State -eq 'running')){Close-LibraryJob $job;$script:TrainingJob=$null;$learnMenu.Enabled=$true;$lblStatus.Text='学习进程已退出，可重新学习。'}
        return
    }
    if(-not $learnAutoMenu.Checked -or $script:IndexJob -or $script:DedupeJob -or $script:BatchJob -or $script:UiUpdating -or -not [IO.File]::Exists($script:IndexManifest)){return}
    $minutes=[Math]::Max(1,[int]$script:Cfg.learning.retrainMinutes)
    if(([datetime]::UtcNow-$script:LastTrainingAttempt).TotalMinutes -lt $minutes){return}
    $signature=(Get-Item -LiteralPath $script:IndexManifest).LastWriteTimeUtc.Ticks
    if($signature -ne $script:LastTrainingSignature){Start-LibraryTraining}
})
$form.Add_Shown({if(-not $SelfTestForm -and -not $UiTestOutput -and -not $Capture){$trainingTimer.Start()}})
$form.Add_FormClosed({$trainingTimer.Stop();$trainingTimer.Dispose();Close-LibraryJob $script:TrainingJob -Stop})
