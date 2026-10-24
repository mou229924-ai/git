# Optional local classifier. Explicit rules and conflicts must be resolved before calling it.
function Initialize-LearnedFeatureExtractor {
    if ('Nailong.LearnedFeatures' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
namespace Nailong {
    public static class LearnedFeatures {
        private static readonly HashSet<string> Stop = new HashSet<string>(new string[] {
            "练习","试卷","答案","考试","文档","资料","测试","问题","内容","说明","题目",
            "the","and","with","this","from","that","test","document","pdf","docx","page"
        }, StringComparer.OrdinalIgnoreCase);
        private static void Add(Dictionary<string,double> result, string token, double weight) {
            if (Stop.Contains(token) || token.Length > 48) return;
            double old;
            string key = "w:" + token;
            result.TryGetValue(key, out old);
            result[key] = Math.Min(24.0, old + weight);
        }
        private static void Accumulate(Dictionary<string,double> result, string text, double weight, int cap) {
            if (String.IsNullOrWhiteSpace(text)) return;
            text = text.Substring(0, Math.Min(cap, text.Length)).ToLowerInvariant();
            foreach (Match match in Regex.Matches(text, "[a-z][a-z0-9]{2,}")) Add(result, match.Value, weight);
            foreach (Match match in Regex.Matches(text, "[\u3400-\u9fff]{2,}")) {
                string run = match.Value;
                for (int size = 2; size <= 3; size++)
                    for (int i = 0; i + size <= run.Length; i++)
                        Add(result, run.Substring(i, size), weight);
            }
        }
        public static Dictionary<string,double> Extract(string name, string text) {
            var result = new Dictionary<string,double>(StringComparer.Ordinal);
            Accumulate(result, name, 4.0, 160);
            Accumulate(result, text, 1.0, 8000);
            return result;
        }
    }
}
'@
}

function ConvertTo-LearnedMap {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        $map=@{}; foreach ($key in $Value.Keys) { $map[[string]$key]=ConvertTo-LearnedMap $Value[$key] }; return $map
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $map=@{}; foreach ($property in $Value.PSObject.Properties) { $map[$property.Name]=ConvertTo-LearnedMap $property.Value }; return $map
    }
    if ($Value -is [Array]) {
        $items=@(); foreach ($item in $Value) { $items+=,(ConvertTo-LearnedMap $item) }; return ,$items
    }
    return $Value
}

function Test-LearnedModelShape {
    param($Model,[string]$Identity)
    if (-not ($Model -is [Collections.IDictionary]) -or $Model.Schema -ne 1 -or [string]$Model.Root -ne $Identity -or
        -not ($Model.Enabled -is [bool]) -or -not $Model.Enabled -or @($Model.Labels).Count -lt 2 -or
        -not ($Model.Vocabulary -is [Collections.IDictionary]) -or $Model.Vocabulary.Count -lt 4 -or $Model.Vocabulary.Count -gt 3000 -or
        -not ($Model.Centroids -is [Collections.IDictionary]) -or $Model.SampleCount -lt (3*@($Model.Labels).Count)) { return $false }
    if ($Model.Validation.Tested -lt @($Model.Labels).Count -or $Model.Validation.Accuracy -lt 0.8 -or $Model.Validation.Accuracy -gt 1 -or
        $Model.Validation.Precision -lt 0.9 -or $Model.Validation.Precision -gt 1 -or $Model.Validation.Coverage -lt 0.8 -or $Model.Validation.Coverage -gt 1) { return $false }
    if ($Model.Thresholds.MinScore -lt 0.4 -or $Model.Thresholds.MinScore -gt 1 -or $Model.Thresholds.MinMargin -lt 0.18 -or $Model.Thresholds.MinMargin -gt 1 -or
        $Model.Thresholds.MinRelativeMargin -lt 0.3 -or $Model.Thresholds.MinRelativeMargin -gt 1 -or $Model.Thresholds.MinEvidence -lt 2 -or $Model.Thresholds.MinEvidence -gt 8) { return $false }
    foreach ($token in $Model.Vocabulary.Keys) {
        $idf=[double]$Model.Vocabulary[$token]
        if (-not ([string]$token).StartsWith('w:') -or ([string]$token).Length -gt 50 -or [double]::IsNaN($idf) -or [double]::IsInfinity($idf) -or $idf -le 0 -or $idf -gt 20) { return $false }
    }
    foreach ($label in $Model.Labels) {
        if (-not ($label -is [string]) -or -not (Test-LibraryName $label) -or $label -eq [string]$script:Cfg.otherFolderName -or $label -eq [string]$script:Cfg.search.unclassified -or
            -not $Model.Centroids.ContainsKey($label) -or -not ($Model.Centroids[$label] -is [Collections.IDictionary]) -or
            $Model.Centroids[$label].Count -eq 0 -or $Model.SampleCounts[$label] -lt 3 -or $Model.Validation.CorrectPerLabel[$label] -lt 1) { return $false }
        $norm=0.0
        foreach ($token in $Model.Centroids[$label].Keys) {
            $weight=[double]$Model.Centroids[$label][$token]
            if (-not $Model.Vocabulary.ContainsKey($token) -or [double]::IsNaN($weight) -or [double]::IsInfinity($weight) -or $weight -lt 0 -or $weight -gt 1.000001) { return $false }
            $norm+=$weight*$weight
        }
        if ($norm -lt 0.99 -or $norm -gt 1.01) { return $false }
    }
    return $true
}

function Get-LearnedModel {
    $path=Join-Path $script:IndexDir 'model.json'
    if (-not [IO.File]::Exists($path)) { return $null }
    $stamp=(Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks
    $identity=[IO.Path]::GetFullPath($script:Root).TrimEnd('\').ToLowerInvariant()
    if ($script:LearnedModelCache -and $script:LearnedModelCache.Path -eq $path -and $script:LearnedModelCache.Stamp -eq $stamp -and $script:LearnedModelCache.Root -eq $identity) { return $script:LearnedModelCache.Model }
    try {
        $raw=(Read-AtomicUtf8 $path) | ConvertFrom-Json
        $model=ConvertTo-LearnedMap $raw
        if (-not (Test-LearnedModelShape -Model $model -Identity $identity)) { return $null }
        $script:LearnedModelCache=@{Path=$path;Stamp=$stamp;Root=$identity;Model=$model}
        return $model
    } catch { return $null }
}

function Get-LearnedModelStatus {
    if(-not $script:Cfg.learning -or -not [bool]$script:Cfg.learning.enabled){return [pscustomobject]@{Enabled=$false;Reason='本地学习已关闭。';Labels=@();Samples=0}}
    $model=Get-LearnedModel
    if (-not $model) { return [pscustomobject]@{ Enabled=$false; Reason='尚无通过留出验证的本地学习模型。'; Labels=@(); Samples=0 } }
    return [pscustomobject]@{ Enabled=$true; Reason='本地学习模型已通过留出验证。'; Labels=@($model.Labels); Samples=[int]$model.SampleCount; TrainedUtc=[string]$model.TrainedUtc; Validation=$model.Validation }
}

function New-LearnedCentroids {
    param([object[]]$Samples, [string[]]$Labels)
    $df=@{}; $labelDf=@{}; $counts=@{}
    foreach ($label in $Labels) { $counts[$label]=@($Samples | Where-Object Label -eq $label).Count }
    foreach ($sample in $Samples) {
        foreach ($token in $sample.Features.Keys) {
            if (-not $df.ContainsKey($token)) { $df[$token]=0; $labelDf[$token]=@{} }
            $df[$token]++
            if (-not $labelDf[$token].ContainsKey($sample.Label)) { $labelDf[$token][$sample.Label]=0 }
            $labelDf[$token][$sample.Label]++
        }
    }
    $ranked=New-Object Collections.ArrayList
    foreach ($token in $df.Keys) {
        if ($df[$token] -lt 2) { continue }
        $rates=@(foreach ($label in $Labels) { [double]$labelDf[$token][$label]/[Math]::Max(1,$counts[$label]) })
        $rates=@($rates | Sort-Object -Descending)
        $difference=$rates[0]-$rates[1]
        if ($rates[0] -lt 0.5 -or $difference -lt 0.25) { continue }
        $idf=1+[Math]::Log(($Samples.Count+1.0)/($df[$token]+1.0))
        [void]$ranked.Add([pscustomobject]@{Token=$token;Idf=$idf;Rank=($idf*$difference*$df[$token])})
    }
    $vocabulary=@{}
    foreach ($feature in @($ranked | Sort-Object @{Expression='Rank';Descending=$true},Token | Select-Object -First 3000)) { $vocabulary[$feature.Token]=[double]$feature.Idf }
    $centroids=@{}
    foreach ($label in $Labels) { $centroids[$label]=@{} }
    foreach ($sample in $Samples) {
        $vector=@{}; $norm=0.0
        foreach ($token in $sample.Features.Keys) {
            if (-not $vocabulary.ContainsKey($token)) { continue }
            $weight=(1+[Math]::Log([double]$sample.Features[$token]))*$vocabulary[$token]
            $vector[$token]=$weight; $norm+=$weight*$weight
        }
        $norm=[Math]::Sqrt($norm)
        if ($norm -le 0) { continue }
        foreach ($token in $vector.Keys) {
            if (-not $centroids[$sample.Label].ContainsKey($token)) { $centroids[$sample.Label][$token]=0.0 }
            $centroids[$sample.Label][$token]+=$vector[$token]/$norm
        }
    }
    foreach ($label in $Labels) {
        $norm=0.0; foreach ($weight in $centroids[$label].Values) { $norm+=$weight*$weight }
        $norm=[Math]::Sqrt($norm)
        if ($norm -le 0) { continue }
        foreach ($token in @($centroids[$label].Keys)) { $centroids[$label][$token]/=$norm }
    }
    return @{Vocabulary=$vocabulary;Centroids=$centroids;Labels=$Labels;Thresholds=@{MinScore=0.4;MinMargin=0.18;MinRelativeMargin=0.3;MinEvidence=2}}
}

function Get-LearnedPrediction {
    param($Features,$Model)
    $vector=@{}; $norm=0.0
    foreach ($token in $Features.Keys) {
        if (-not $Model.Vocabulary.ContainsKey($token)) { continue }
        $weight=(1+[Math]::Log([double]$Features[$token]))*[double]$Model.Vocabulary[$token]
        $vector[$token]=$weight; $norm+=$weight*$weight
    }
    $norm=[Math]::Sqrt($norm)
    if ($norm -le 0) { return $null }
    $scores=New-Object Collections.ArrayList
    foreach ($label in $Model.Labels) {
        $score=0.0
        foreach ($token in $vector.Keys) { $score+=($vector[$token]/$norm)*[double]$Model.Centroids[$label][$token] }
        [void]$scores.Add([pscustomobject]@{Label=[string]$label;Score=$score})
    }
    $ranked=@($scores | Sort-Object @{Expression='Score';Descending=$true},Label)
    if ($ranked.Count -lt 2) { return $null }
    $best=$ranked[0]; $second=$ranked[1]
    $margin=$best.Score-$second.Score
    if ($best.Score -lt $Model.Thresholds.MinScore -or $margin -lt $Model.Thresholds.MinMargin -or ($margin/[Math]::Max(0.000001,$best.Score)) -lt $Model.Thresholds.MinRelativeMargin) { return $null }
    $evidence=New-Object Collections.ArrayList
    foreach ($token in $vector.Keys) {
        $bestWeight=[double]$Model.Centroids[$best.Label][$token]
        $secondWeight=[double]$Model.Centroids[$second.Label][$token]
        if ($bestWeight -gt 0 -and $bestWeight -gt ($secondWeight*1.25)) {
            [void]$evidence.Add([pscustomobject]@{Token=$token.Substring(2);Weight=($vector[$token]/$norm)*$bestWeight})
        }
    }
    if ($evidence.Count -lt $Model.Thresholds.MinEvidence) { return $null }
    $total=0.0; foreach ($score in $ranked) { $total+=[Math]::Max(0,$score.Score) }
    return [pscustomobject]@{Label=$best.Label;Score=$best.Score;Margin=$margin;Confidence=$best.Score;Evidence=@($evidence | Sort-Object @{Expression='Weight';Descending=$true},Token | Select-Object -First 8 | ForEach-Object Token)}
}

function Get-LearnedClassification {
    param([string]$Path,[string]$Text,[switch]$TextProvided)
    if(-not $script:Cfg.learning -or -not [bool]$script:Cfg.learning.enabled){return $null}
    $model=Get-LearnedModel
    if (-not $model) { return $null }
    Initialize-LearnedFeatureExtractor
    if (-not $TextProvided) { $Text=Get-FileText -Path $Path -Max 8000 }
    $features=[Nailong.LearnedFeatures]::Extract([IO.Path]::GetFileNameWithoutExtension($Path),$Text)
    $prediction=Get-LearnedPrediction -Features $features -Model $model
    if (-not $prediction) { return $null }
    $directory=Join-Path $script:Root $prediction.Label
    $target=Get-Item -LiteralPath $directory -Force -ErrorAction SilentlyContinue
    if (-not $target -or -not $target.PSIsContainer -or ($target.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $target.Name -match '^[._]') { return $null }
    return [pscustomobject]@{
        Ambiguous=$false; Rule=[pscustomobject]@{name=$prediction.Label;filenameKeywords=@();contentKeywords=@()}
        How='learned'; Score=$prediction.Score; Confidence=[Math]::Round($prediction.Confidence,3); Evidence=$prediction.Evidence; ModelTrainedUtc=$model.TrainedUtc
    }
}

function Invoke-LearnedTrainingCore {
    param([scriptblock]$Progress,[ValidateRange(3,50)][int]$MinimumSamplesPerLabel=3,[ValidateRange(3,1000)][int]$MaxSamplesPerLabel=200)
    Initialize-LearnedFeatureExtractor
    $entries=@(Load-IndexEntries | Sort-Object rel)
    $candidates=New-Object Collections.ArrayList
    $seenPerLabel=@{}
    foreach ($entry in $entries) {
        $parts=([string]$entry.rel) -split '\\'
        if ($parts.Count -lt 2 -or [long]$entry.size -le 0) { continue }
        $label=$parts[0]
        if ($label -match '^[._]' -or $label -eq [string]$script:Cfg.otherFolderName -or $label -eq [string]$script:Cfg.search.unclassified) { continue }
        if (-not $seenPerLabel.ContainsKey($label)) { $seenPerLabel[$label]=0 }
        if ($seenPerLabel[$label] -ge $MaxSamplesPerLabel) { continue }
        $path=Join-Path $script:Root ([string]$entry.rel)
        $file=Get-IndexSourceItem $path
        if (-not $file -or $file.Length -le 0 -or [long]$file.Length -ne [long]$entry.size -or [long]$file.LastWriteTime.Ticks -ne [long]$entry.mtimeTicks) { continue }
        [void]$candidates.Add([pscustomobject]@{Entry=$entry;File=$file;Label=$label})
        $seenPerLabel[$label]++
    }
    $samples=New-Object Collections.ArrayList
    $skipped=0; $done=0
    foreach ($candidate in $candidates) {
        $done++
        if ($Progress) { & $Progress $done $candidates.Count $candidate.File.Name }
        try {
            $stream=[IO.File]::Open($candidate.File.FullName,'Open','Read','Read')
            try { $hash=Get-StreamHash $stream } finally { $stream.Dispose() }
            $after=Get-IndexSourceItem $candidate.File.FullName
            if (-not $after -or [long]$after.Length -ne [long]$candidate.Entry.size -or [long]$after.LastWriteTime.Ticks -ne [long]$candidate.Entry.mtimeTicks) { $skipped++; continue }
            # Indexed bodies are reused; training never invokes OCR or document extraction.
            $body=Read-IndexContentText $candidate.Entry
            $features=[Nailong.LearnedFeatures]::Extract([IO.Path]::GetFileNameWithoutExtension($candidate.File.Name),[string]$body)
            if ($features.Count -lt 2) { $skipped++; continue }
            [void]$samples.Add([pscustomobject]@{Label=$candidate.Label;Hash=$hash;Rel=$candidate.Entry.rel;Features=$features})
        } catch { $skipped++; Write-Log ('LEARNING SAMPLE SKIP  '+$candidate.File.FullName+'  '+$_.Exception.Message) }
    }
    $groups=@{}
    foreach ($sample in $samples) { if (-not $groups.ContainsKey($sample.Hash)) { $groups[$sample.Hash]=New-Object Collections.ArrayList }; [void]$groups[$sample.Hash].Add($sample) }
    $unique=New-Object Collections.ArrayList
    $conflicting=0; $duplicateCopies=0
    foreach ($group in $groups.Values) {
        $labels=@($group | ForEach-Object Label | Select-Object -Unique)
        if ($labels.Count -gt 1) { $conflicting+=$group.Count; continue }
        $representative=@($group | Sort-Object Rel)[0]
        [void]$unique.Add($representative)
        $duplicateCopies+=$group.Count-1
    }
    $counts=@{}; $eligible=New-Object Collections.ArrayList; $ignoredLabels=New-Object Collections.ArrayList
    foreach ($label in @($unique | ForEach-Object Label | Sort-Object -Unique)) {
        $count=@($unique | Where-Object Label -eq $label).Count
        $counts[$label]=$count
        if ($count -ge $MinimumSamplesPerLabel) { [void]$eligible.Add([string]$label) } else { [void]$ignoredLabels.Add([string]$label) }
    }
    $summary=@{ Published=$false; Enabled=[bool](Get-LearnedModel); Labels=@($eligible.ToArray()); SampleCounts=$counts; ExcludedCrossLabelDuplicates=$conflicting; DuplicateCopies=$duplicateCopies; Skipped=$skipped; InsufficientLabels=@($ignoredLabels.ToArray()) }
    if ($eligible.Count -lt 2) { $summary.Reason='至少需要两个目录，每个目录至少有三份内容独立、可读的样本。'; return [pscustomobject]$summary }
    $training=New-Object Collections.ArrayList; $validation=New-Object Collections.ArrayList; $all=New-Object Collections.ArrayList
    foreach ($label in $eligible) {
        $items=@($unique | Where-Object Label -eq $label | Sort-Object Hash)
        $holdout=[Math]::Max(1,[int][Math]::Floor($items.Count*0.2))
        for ($i=0; $i -lt $items.Count; $i++) {
            [void]$all.Add($items[$i])
            if ($i -lt $holdout) { [void]$validation.Add($items[$i]) } else { [void]$training.Add($items[$i]) }
        }
    }
    $trial=New-LearnedCentroids -Samples $training.ToArray() -Labels $eligible.ToArray()
    $covered=0; $correct=0; $correctPerLabel=@{}
    foreach ($label in $eligible) { $correctPerLabel[$label]=0 }
    foreach ($sample in $validation) {
        $prediction=Get-LearnedPrediction -Features $sample.Features -Model $trial
        if (-not $prediction) { continue }
        $covered++
        if ($prediction.Label -eq $sample.Label) { $correct++; $correctPerLabel[$sample.Label]++ }
    }
    $metrics=@{ Tested=$validation.Count; Covered=$covered; Correct=$correct; Accuracy=($correct/[double][Math]::Max(1,$validation.Count)); Precision=($correct/[double][Math]::Max(1,$covered)); Coverage=($covered/[double][Math]::Max(1,$validation.Count)); CorrectPerLabel=$correctPerLabel }
    $summary.Validation=$metrics
    $eachLabelCovered=(@($correctPerLabel.Values | Where-Object { $_ -lt 1 }).Count -eq 0)
    if ($trial.Vocabulary.Count -lt 4 -or $metrics.Accuracy -lt 0.8 -or $metrics.Precision -lt 0.9 -or $metrics.Coverage -lt 0.8 -or -not $eachLabelCovered) {
        $summary.Reason='样本区分度或留出验证结果不足，未启用新模型；已有有效模型会保留。'
        return [pscustomobject]$summary
    }
    $model=New-LearnedCentroids -Samples $all.ToArray() -Labels $eligible.ToArray()
    $identity=[IO.Path]::GetFullPath($script:Root).TrimEnd('\').ToLowerInvariant()
    $fingerprint=New-Object IO.MemoryStream(,[Text.Encoding]::UTF8.GetBytes((@($all | Sort-Object Label,Hash | ForEach-Object { $_.Label+':'+$_.Hash }) -join ';')))
    try { $trainingHash=Get-StreamHash $fingerprint } finally { $fingerprint.Dispose() }
    $model.Schema=1; $model.Root=$identity; $model.Enabled=$true; $model.TrainedUtc=[datetime]::UtcNow.ToString('o')
    $model.SampleCount=$all.Count; $model.SampleCounts=$counts; $model.Validation=$metrics; $model.TrainingHash=$trainingHash
    Initialize-IndexFolders
    Write-AtomicUtf8 (Join-Path $script:IndexDir 'model.json') ($model | ConvertTo-Json -Depth 15 -Compress)
    $script:LearnedModelCache=$null
    $summary.Published=$true; $summary.Enabled=$true; $summary.Reason='本地样本学习完成，并已通过独立留出验证。'; $summary.SampleCount=$all.Count
    return [pscustomobject]$summary
}

function Train-LibraryClassifier {
    param([scriptblock]$Progress,[ValidateRange(3,50)][int]$MinimumSamplesPerLabel=3,[ValidateRange(3,1000)][int]$MaxSamplesPerLabel=200)
    $id=Get-IndexId ([IO.Path]::GetFullPath($script:IndexDir))
    $mutex=New-Object Threading.Mutex($false,('Local\NailongLearning_'+$id))
    $owned=$false
    try {
        try {$owned=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$owned=$true}
        if (-not $owned) {return [pscustomobject]@{Published=$false;Enabled=[bool](Get-LearnedModel);Busy=$true;Reason='本地学习任务正在运行，请等待完成。'}}
        return Invoke-LearnedTrainingCore -Progress $Progress -MinimumSamplesPerLabel $MinimumSamplesPerLabel -MaxSamplesPerLabel $MaxSamplesPerLabel
    } finally {if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
