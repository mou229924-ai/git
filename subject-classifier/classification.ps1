function Get-FilenameDecision {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $matches = @()
    foreach ($rule in $script:Cfg.subjects) {
        foreach ($keyword in @($rule.filenameKeywords)) {
            if (Test-Keyword -Text $Text -Keyword ([string]$keyword)) {
                $matches += $rule
                break
            }
        }
    }
    if ($matches.Count -eq 0) { return $null }
    if ($matches.Count -gt 1) {
        return @{ Ambiguous=$true; Candidates=@($matches | ForEach-Object { [string]$_.name }); Detail='multiple filename subjects' }
    }
    return @{ Ambiguous=$false; Rule=$matches[0]; Detail='filename keyword' }
}

function Get-ContentDecision {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $nw = [int]$script:Cfg.scoring.nameWeight
    $kww = [int]$script:Cfg.scoring.keywordWeight
    $min = [int]$script:Cfg.scoring.minScore
    $dom = [double]$script:Cfg.scoring.dominance
    $scores = New-Object System.Collections.ArrayList
    foreach ($rule in $script:Cfg.subjects) {
        $subjectName = [string]$rule.name
        $nameCount = Count-Occurrences -Text $Text -Needle $subjectName
        $score = [Math]::Min($nameCount, 12) * $nw
        $parts = @()
        if ($nameCount -gt 0) { $parts += ($subjectName + '=' + [string]$nameCount) }
        foreach ($kw in @($rule.contentKeywords)) {
            $k = [string]$kw
            if ($k -eq $subjectName) { continue }
            $c = Count-Occurrences -Text $Text -Needle $k
            if ($c -gt 0) {
                $score = $score + [Math]::Min($c, 12) * $kww
                $parts += ($k + '=' + [string]$c)
            }
        }
        [void]$scores.Add([pscustomobject]@{ Rule = $rule; Score = $score; Detail = ($parts -join ',') })
    }
    $sorted = @($scores | Sort-Object -Property Score -Descending)
    $top = $sorted[0]
    if ($top.Score -lt $min) { return $null }
    $secondScore = 0
    if ($sorted.Count -gt 1) { $secondScore = [int]$sorted[1].Score }
    if ($secondScore -gt 0 -and $top.Score -lt ($secondScore * $dom)) {
        $cands = @()
        foreach ($s in $sorted) {
            if ($s.Score -gt 0 -and $cands.Count -lt 4) { $cands += [string]$s.Rule.name }
        }
        return @{ Ambiguous = $true; Candidates = $cands; Detail = ($top.Detail + ' | runner=' + [string]$secondScore) }
    }
    return @{ Ambiguous = $false; Rule = $top.Rule; Score = [int]$top.Score; Runner = $secondScore; Detail = $top.Detail }
}

function Get-DocumentClassification {
    param([string]$Path,[string]$Context='')
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    $nameDecision = Get-FilenameDecision $file.BaseName
    $text = Get-FileText -Path $Path
    $contentDecision = Get-ContentDecision $text
    $decision = $null
    $how = 'unknown'
    if ($nameDecision -and $nameDecision.Ambiguous) { $decision=$nameDecision; $how='mixed-filename' }
    elseif ($nameDecision) {
        if ($contentDecision -and -not $contentDecision.Ambiguous -and $contentDecision.Rule.name -ne $nameDecision.Rule.name) {
            $decision=@{ Ambiguous=$true; Candidates=@([string]$nameDecision.Rule.name,[string]$contentDecision.Rule.name); Detail='filename/content conflict' }
            $how='conflict'
        } else { $decision=$nameDecision; $how='filename' }
    } elseif ($contentDecision) { $decision=$contentDecision; $how='content' }
    elseif ($Context) {
        $rule = @($script:Cfg.subjects | Where-Object name -eq $Context) | Select-Object -First 1
        if ($rule) { $decision=@{ Ambiguous=$false; Rule=$rule; Detail='parent directory context' }; $how='folder-context' }
    }
    return @{ Decision=$decision; Text=$text; How=$how }
}
