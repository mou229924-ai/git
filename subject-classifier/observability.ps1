# Shared best-effort logging. Expected contention is informational and counted.
function Get-ExpectedBusyMessage {
    param([Exception]$Exception,[string]$Message)
    $current=$Exception
    while($current){
        if(($current -is [TimeoutException] -and $current.Data['LibraryBusy']) -or $current.Message -match '资料库正在处理文件|索引正在更新|配置正在更新|本地学习任务正在运行'){return $current.Message}
        $current=$current.InnerException
    }
    if($Message -match '资料库正在处理文件|索引正在更新|配置正在更新|本地学习任务正在运行'){return ($Message -replace '^.*?ERROR\s+','')}
    return ''
}

function Write-ApplicationLogLine {
    param([string]$Path,[string]$Level,[string]$Message)
    $mutex=$null;$owned=$false
    try{
        if(-not $Path){return $false}
        $full=[IO.Path]::GetFullPath($Path)
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$id=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($full.ToLowerInvariant())))).Replace('-','').Substring(0,32)}finally{$sha.Dispose()}
        $mutex=New-Object Threading.Mutex($false,('Local\NailongLog_'+$id))
        try{$owned=$mutex.WaitOne(1000)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){return $false}
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
        if([IO.File]::Exists($full) -and (Get-Item -LiteralPath $full).Length -gt 2MB){
            $previous=$full+'.old'
            if([IO.File]::Exists($previous)){[IO.File]::Delete($previous)}
            [IO.File]::Move($full,$previous)
        }
        $line=[datetime]::UtcNow.ToString('o')+' ['+$Level+'] [pid:'+$PID+'] '+$Message+[Environment]::NewLine
        [IO.File]::AppendAllText($full,$line,(New-Object Text.UTF8Encoding($false)))
        return $true
    }catch{return $false}finally{if($mutex){if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}}
}

function Flush-ApplicationLogs {
    param([switch]$Force)
    if(-not $script:ApplicationLogState){return}
    $now=[datetime]::UtcNow
    foreach($record in @($script:ApplicationLogState.Values)){
        if($record.Suppressed -le 0 -or (-not $Force -and ($now-$record.LastWrite).TotalSeconds -lt $record.Window)){continue}
        $summary=$record.Message+'  [本轮重复 '+$record.Suppressed+' 次，累计 '+$record.Total+' 次]'
        if(Write-ApplicationLogLine -Path $record.Path -Level $record.Level -Message $summary){$record.Suppressed=0;$record.LastWrite=$now}
    }
}

function Write-Log {
    param([string]$Message,[Exception]$Exception,[ValidateSet('','INFO','WARN','ERROR','DEBUG')][string]$Level='',[ValidateRange(0,3600)][int]$ThrottleSeconds=30)
    try{
        if(-not $script:ApplicationLogState){$script:ApplicationLogState=@{}}
        $busy=Get-ExpectedBusyMessage -Exception $Exception -Message $Message
        if($busy){$Message='BUSY  '+$busy;$Level='INFO'}
        if(-not $Level){
            if($Message -match '(?:^|\s)(?:ERROR|FATAL)(?:\s|$)'){$Level='ERROR'}
            elseif($Message -match '(?:SKIP|RECOVERY|DEFER)'){$Level='WARN'}else{$Level='INFO'}
        }
        $Message=($Message -replace '[\r\n]+',' ').Trim()
        Flush-ApplicationLogs
        $now=[datetime]::UtcNow
        $key=([string]$script:LogPath)+'|'+$Level+'|'+$Message
        if($script:ApplicationLogState.ContainsKey($key)){
            $record=$script:ApplicationLogState[$key];$record.Total++;$record.Suppressed++;$record.LastSeen=$now
            if($ThrottleSeconds -eq 0 -or ($now-$record.LastWrite).TotalSeconds -ge $record.Window){Flush-ApplicationLogs -Force}
            return
        }
        if($script:ApplicationLogState.Count -ge 1024){
            Flush-ApplicationLogs -Force
            $oldest=@($script:ApplicationLogState.GetEnumerator() | Sort-Object {$_.Value.LastSeen} | Select-Object -First 1)[0]
            if($oldest){$script:ApplicationLogState.Remove($oldest.Key)}
        }
        $script:ApplicationLogState[$key]=@{Path=[string]$script:LogPath;Level=$Level;Message=$Message;Total=1;Suppressed=0;LastWrite=$now;LastSeen=$now;Window=$ThrottleSeconds}
        $null=Write-ApplicationLogLine -Path $script:LogPath -Level $Level -Message $Message
    }catch{}
}

function Invoke-OperationProgress {
    param([scriptblock]$Progress,[int]$Done,[int]$Total,[string]$Name='',[string]$Operation='')
    if(-not $Progress){return}
    try{$null=& $Progress $Done $Total $Name $Operation}catch{Write-Log ('PROGRESS SKIP  '+$_.Exception.Message) -Level WARN}
}

function Test-OperationCancellation {
    param([scriptblock]$ShouldCancel)
    if(-not $ShouldCancel){return $false}
    try{return [bool](& $ShouldCancel)}catch{Write-Log ('CANCEL CHECK SKIP  '+$_.Exception.Message) -Level WARN;return $true}
}
