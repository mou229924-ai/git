# Configuration migrations preserve unknown fields and explicit user choices.
function Get-ConfigurationPathId {
    param([string]$Path)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Path).ToLowerInvariant())))).Replace('-','').Substring(0,24)}finally{$sha.Dispose()}
}

function Resolve-LibraryConfigRoot {
    param($Config,[string]$BaseDirectory=$script:AppDir)
    $value=[string]$Config.inbox
    if([string]::IsNullOrWhiteSpace($value)){throw '配置中没有资料目录 inbox。'}
    if($value -match '^[A-Za-z]:[^\\/]'){throw '资料目录不能使用相对于磁盘的路径。'}
    if(-not [IO.Path]::IsPathRooted($value)){
        if(-not $BaseDirectory){throw '相对资料路径需要明确的配置目录。'}
        $value=Join-Path $BaseDirectory $value
    }
    return [IO.Path]::GetFullPath($value).TrimEnd('\')
}

function Merge-ConfigurationDefaults {
    param($Target,$Defaults)
    foreach($property in $Defaults.PSObject.Properties){
        $existing=$Target.PSObject.Properties[$property.Name]
        if(-not $existing){$Target | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value}
        elseif($existing.Value -is [Management.Automation.PSCustomObject] -and $property.Value -is [Management.Automation.PSCustomObject]){Merge-ConfigurationDefaults $existing.Value $property.Value}
    }
}

function Read-ApplicationConfiguration {
    param([string]$Path,[string]$TemplatePath,[string]$StateDirectory='',[int]$SupportedSchema=1)
    if(-not [IO.File]::Exists($Path)){throw '尚未配置资料目录，请从桌面入口或 setup.ps1 首次启动。'}
    $utf8=New-Object Text.UTF8Encoding($false)
    $mutex=New-Object Threading.Mutex($false,('Local\NailongConfig_'+(Get-ConfigurationPathId $Path)))
    $owned=$false
    try{
        try{$owned=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){throw (New-Object TimeoutException('配置正在更新，请稍后重试。'))}
        $original=[IO.File]::ReadAllText($Path,$utf8)
        try{$config=$original | ConvertFrom-Json}catch{throw 'config.json 格式无效，原文件保持原样。'}
        if($config -isnot [Management.Automation.PSCustomObject]){throw '配置必须是 JSON 对象。'}
        $schema=0
        if($config.PSObject.Properties['schemaVersion']){
            try{$schema=[int]$config.schemaVersion}catch{throw '配置 schemaVersion 无效。'}
        }
        if($schema -gt $SupportedSchema){throw '配置来自更高版本，请使用对应的新程序或原配置备份。'}
        $defaults=[IO.File]::ReadAllText($TemplatePath,$utf8) | ConvertFrom-Json
        Merge-ConfigurationDefaults $config $defaults
        if(-not $config.PSObject.Properties['ocr']){$config | Add-Member -NotePropertyName ocr -NotePropertyValue ([pscustomobject]@{enabled=$false;maxPages=2;maxFileMiB=25;timeoutSeconds=12})}
        if(-not $config.PSObject.Properties['schemaVersion']){$config | Add-Member -NotePropertyName schemaVersion -NotePropertyValue $SupportedSchema}
        $config.schemaVersion=$SupportedSchema
        $config.inbox=Resolve-LibraryConfigRoot -Config $config -BaseDirectory (Split-Path $Path -Parent)
        if([int]$config.pollSeconds -lt 1 -or [int]$config.stablePolls -lt 1){throw '监听间隔和稳定检查次数必须大于零。'}
        $obsolete=@('start.vbs','stop.vbs','install-autostart.ps1')
        $appDirectory=Split-Path $Path -Parent
        $config.ignoreFiles=@($config.ignoreFiles | Where-Object {$_ -notin $obsolete -or [IO.File]::Exists((Join-Path $appDirectory $_))})
        $updated=$config | ConvertTo-Json -Depth 32
        # Avoid touching a current configuration on every worker startup.
        $beforeNormalized=($original | ConvertFrom-Json) | ConvertTo-Json -Depth 32
        if($updated -ne $beforeNormalized){
            if($schema -lt $SupportedSchema){
                if(-not $StateDirectory){$StateDirectory=Join-Path ([IO.Path]::GetTempPath()) ('Nailong-config-'+(Get-ConfigurationPathId $Path))}
                [void][IO.Directory]::CreateDirectory($StateDirectory)
                $backup=Join-Path $StateDirectory ('config-before-schema-'+$SupportedSchema+'.json')
                if(-not [IO.File]::Exists($backup)){[IO.File]::Copy($Path,$backup,$false)}
            }
            $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
            try{
                [IO.File]::WriteAllText($temporary,$updated,$utf8)
                [IO.File]::Replace($temporary,$Path,[Management.Automation.Language.NullString]::Value)
            }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
        }
        return $config
    } finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
