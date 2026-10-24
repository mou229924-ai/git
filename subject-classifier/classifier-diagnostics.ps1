# Inspection and self-test commands. No tray application is started here.
function Invoke-Inspect {
    param([string]$Target)
    $paths = @()
    if (Test-Path -LiteralPath $Target -PathType Container) {
        $paths = @(Get-ChildItem -LiteralPath $Target -Recurse -File -Force -ErrorAction SilentlyContinue)
    } else {
        $paths = @(Get-Item -LiteralPath $Target)
    }
    $sb = New-Object System.Text.StringBuilder
    $auto = 0
    $ask = 0
    foreach ($f in $paths) {
        $line = ''
        $fdec = Get-FilenameDecision -Text $f.BaseName
        if ($fdec -ne $null -and -not $fdec.Ambiguous) {
            $line = 'AUTO   ' + [string]$fdec.Rule.name + '   [filename]   ' + $f.FullName
            $auto = $auto + 1
        } elseif ($fdec -ne $null -and $fdec.Ambiguous) {
            $line = 'ASK    ambiguous-filename [' + ($fdec.Candidates -join '/') + ']   ' + $f.FullName
            $ask = $ask + 1
        } else {
            $text = Get-FileText -Path $f.FullName
            if ([string]::IsNullOrWhiteSpace($text)) {
                $line = 'ASK    no-text   ' + $f.FullName
                $ask = $ask + 1
            } else {
                $cdec = Get-ContentDecision -Text $text
                if ($cdec -eq $null) {
                    $line = 'ASK    no-keyword   ' + $f.FullName
                    $ask = $ask + 1
                } elseif ($cdec.Ambiguous) {
                    $line = 'ASK    ambiguous-content [' + ($cdec.Candidates -join '/') + ']   ' + $f.FullName
                    $ask = $ask + 1
                } else {
                    $line = 'AUTO   ' + [string]$cdec.Rule.name + '   [content score=' + [string]$cdec.Score + ' runner=' + [string]$cdec.Runner + ']   ' + $f.FullName
                    $auto = $auto + 1
                }
            }
        }
        [void]$sb.AppendLine($line)
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('TOTAL auto=' + [string]$auto + ' ask=' + [string]$ask)
    $reportPath = Join-Path $script:AppDir ([string]$script:Cfg.inspectReportFile)
    [System.IO.File]::WriteAllText($reportPath, $sb.ToString(), $script:Utf8)
    Write-Output ('inspect written to ' + $reportPath + ' auto=' + [string]$auto + ' ask=' + [string]$ask)
}

function Add-Result {
    param([string]$Label, [bool]$Ok, [string]$Detail)
    if ($Ok) {
        $script:Pass = $script:Pass + 1
        [void]$script:Out.AppendLine('PASS  ' + $Label)
    } else {
        $script:Fail = $script:Fail + 1
        [void]$script:Out.AppendLine('FAIL  ' + $Label + '  ' + $Detail)
    }
}

function Run-SelfTest {
    $script:Out = New-Object System.Text.StringBuilder
    $script:Pass = 0
    $script:Fail = 0

    foreach ($rule in $script:Cfg.subjects) {
        $subjectName = [string]$rule.name
        $kws = @($rule.filenameKeywords)
        $probe = 'zz_' + [string]$kws[0] + '_zz'
        $found = Get-FilenameDecision -Text $probe
        $got = 'null'
        if ($found -ne $null -and -not $found.Ambiguous) { $got = [string]$found.Rule.name }
        Add-Result -Label ('filename -> ' + $subjectName + '  [' + $probe + ']') -Ok ($got -eq $subjectName) -Detail ('expected=' + $subjectName + ' got=' + $got)
    }

    foreach ($rule in $script:Cfg.subjects) {
        $subjectName = [string]$rule.name
        foreach ($kw in @($rule.filenameKeywords)) {
            $k = [string]$kw
            if ($k.Length -ne 1) { continue }
            $probe1 = 'a' + $k + 'b'
            $found1 = Get-FilenameDecision -Text $probe1
            $got1 = 'null'
            if ($found1 -ne $null -and -not $found1.Ambiguous) { $got1 = [string]$found1.Rule.name }
            Add-Result -Label ('single char isolated -> ' + $subjectName + '  [' + $probe1 + ']') -Ok ($got1 -eq $subjectName) -Detail ('expected=' + $subjectName + ' got=' + $got1)

            $probe2 = ([string][char]0x4E00) + $k + ([string][char]0x4E8C)
            $found2 = Get-FilenameDecision -Text $probe2
            Add-Result -Label ('single char inside cjk -> none  [' + $probe2 + ']') -Ok ($found2 -eq $null) -Detail 'expected=none'
        }
    }

    $n1 = [string]$script:Cfg.subjects[0].name
    $n2 = [string]$script:Cfg.subjects[1].name
    $amb = Get-FilenameDecision -Text ('zz_' + $n1 + $n2 + '_zz')
    Add-Result -Label 'ambiguous filename (two subjects)' -Ok ($amb -ne $null -and $amb.Ambiguous) -Detail 'expected=ambiguous'

    Add-Result -Label 'unmatched filename -> none' -Ok ((Get-FilenameDecision -Text 'zz_image_0001') -eq $null) -Detail 'expected=none'

    $textA = ((1..5 | ForEach-Object { $n1 }) -join ' ') + ' ' + $n2
    $cdecA = Get-ContentDecision -Text $textA
    $gotA = 'null'
    if ($cdecA -ne $null -and -not $cdecA.Ambiguous) { $gotA = [string]$cdecA.Rule.name }
    Add-Result -Label 'content count decides (5x A vs 1x B)' -Ok ($gotA -eq $n1) -Detail ('expected=' + $n1 + ' got=' + $gotA)

    $textTie = ((1..3 | ForEach-Object { $n1 }) -join ' ') + ' ' + ((1..3 | ForEach-Object { $n2 }) -join ' ')
    $cdecTie = Get-ContentDecision -Text $textTie
    Add-Result -Label 'content tie -> ambiguous' -Ok ($cdecTie -ne $null -and $cdecTie.Ambiguous) -Detail 'expected=ambiguous'

    Add-Result -Label 'content no keyword -> none' -Ok ((Get-ContentDecision -Text 'zzzz nothing here') -eq $null) -Detail 'expected=none'

    if ($script:Cfg.subjects.Count -ge 10) {
        $chemName = [string]$script:Cfg.subjects[4].name
        $physName = [string]$script:Cfg.subjects[3].name
        $itKw = [string](@($script:Cfg.subjects[9].contentKeywords)[0])
        $probe = (($chemName + ' ') * 5) + ($physName + ' ') + $itKw
        $cdec = Get-ContentDecision -Text $probe
        $got = 'null'
        if ($cdec -ne $null -and -not $cdec.Ambiguous) { $got = [string]$cdec.Rule.name }
        Add-Result -Label ('chemistry doc with physics/it words -> ' + $chemName) -Ok ($got -eq $chemName) -Detail ('expected=' + $chemName + ' got=' + $got)
    }

    $tmpTxt = Join-Path $env:TEMP 'subject-classifier-selftest.txt'
    [System.IO.File]::WriteAllText($tmpTxt, (($n1 + ' ') * 6), $script:Utf8)
    $txt = Get-FileText -Path $tmpTxt
    $cdecTxt = Get-ContentDecision -Text $txt
    $gotTxt = 'null'
    if ($cdecTxt -ne $null -and -not $cdecTxt.Ambiguous) { $gotTxt = [string]$cdecTxt.Rule.name }
    Add-Result -Label ('txt content -> ' + $n1) -Ok ($gotTxt -eq $n1) -Detail ('expected=' + $n1 + ' got=' + $gotTxt)

    $tmpDocx = Join-Path $env:TEMP 'subject-classifier-selftest.docx'
    if (Test-Path -LiteralPath $tmpDocx) { Remove-Item -LiteralPath $tmpDocx -Force }
    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        $fs = [System.IO.File]::Open($tmpDocx, [System.IO.FileMode]::Create)
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        $entry = $zip.CreateEntry('word/document.xml')
        $writer = New-Object System.IO.StreamWriter($entry.Open(), $script:Utf8)
        $writer.Write('<w:document><w:body><w:p><w:r><w:t>' + ($n1 + ' ') * 6 + '</w:t></w:r></w:p></w:body></w:document>')
        $writer.Close()
        $zip.Dispose()
        $fs.Close()
        $docxText = Get-FileText -Path $tmpDocx
        $cdecDocx = Get-ContentDecision -Text $docxText
        $gotDocx = 'null'
        if ($cdecDocx -ne $null -and -not $cdecDocx.Ambiguous) { $gotDocx = [string]$cdecDocx.Rule.name }
        Add-Result -Label ('docx content -> ' + $n1) -Ok ($gotDocx -eq $n1) -Detail ('expected=' + $n1 + ' got=' + $gotDocx)
    } catch {
        Add-Result -Label 'docx content extraction' -Ok $false -Detail $_.Exception.Message
    } finally {
        if (Test-Path -LiteralPath $tmpDocx) { Remove-Item -LiteralPath $tmpDocx -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tmpTxt) { Remove-Item -LiteralPath $tmpTxt -Force -ErrorAction SilentlyContinue }
    }

    [void]$script:Out.AppendLine('')
    [void]$script:Out.AppendLine('TOTAL pass=' + [string]$script:Pass + ' fail=' + [string]$script:Fail)
    $outPath = Join-Path $script:AppDir '_selftest.txt'
    [System.IO.File]::WriteAllText($outPath, $script:Out.ToString(), $script:Utf8)
    Write-Output ('selftest written to ' + $outPath + ' pass=' + [string]$script:Pass + ' fail=' + [string]$script:Fail)
}
