# FileSystemWatcher handlers only enqueue managed values; PowerShell drains them on its UI thread.
function Start-IndexChangeMonitor {
    if ($script:IndexChangeMonitor) { return }
    if (-not ('Nailong.IndexChangeMonitor' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Concurrent;
using System.Threading;
namespace Nailong {
    public sealed class IndexChangeMonitor : IDisposable {
        private readonly FileSystemWatcher watcher;
        private readonly ConcurrentQueue<string> paths = new ConcurrentQueue<string>();
        private readonly string root;
        private readonly string app;
        private int count;
        private int full;
        public IndexChangeMonitor(string rootDirectory, string applicationDirectory) {
            root = Path.GetFullPath(rootDirectory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            app = Path.GetFullPath(applicationDirectory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            watcher = new FileSystemWatcher(rootDirectory);
            watcher.IncludeSubdirectories = true;
            watcher.NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size;
            watcher.InternalBufferSize = 32768;
            watcher.Created += OnChanged;
            watcher.Changed += OnChanged;
            watcher.Deleted += OnChanged;
            watcher.Renamed += OnRenamed;
            watcher.Error += delegate { Interlocked.Exchange(ref full, 1); };
            watcher.EnableRaisingEvents = true;
        }
        private bool Ignore(string path) {
            if (path.StartsWith(app, StringComparison.OrdinalIgnoreCase)) return true;
            if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return true;
            string relative = path.Substring(root.Length);
            string[] parts = relative.Split(Path.DirectorySeparatorChar);
            for (int i = 0; i < parts.Length - 1; i++)
                if (parts[i].StartsWith(".") || parts[i].StartsWith("_")) return true;
            string name = Path.GetFileName(path);
            return name.StartsWith(".") || name.StartsWith("~");
        }
        private void Queue(string path) {
            if (Ignore(path)) return;
            if (Interlocked.Increment(ref count) > 10000) {
                Interlocked.Decrement(ref count);
                Interlocked.Exchange(ref full, 1);
                return;
            }
            paths.Enqueue(path);
        }
        private void OnChanged(object sender, FileSystemEventArgs e) { Queue(e.FullPath); }
        private void OnRenamed(object sender, RenamedEventArgs e) { Queue(e.OldFullPath); Queue(e.FullPath); }
        public string[] Drain() {
            var result = new System.Collections.Generic.List<string>();
            string path;
            while (paths.TryDequeue(out path)) { Interlocked.Decrement(ref count); result.Add(path); }
            return result.ToArray();
        }
        public bool TakeFullReconcile() { return Interlocked.Exchange(ref full, 0) != 0; }
        public void Dispose() { watcher.EnableRaisingEvents = false; watcher.Dispose(); }
    }
}
'@
    }
    $script:IndexChangeMonitor = New-Object Nailong.IndexChangeMonitor($script:Root, $script:AppDir)
    # Changes made while the application was closed need one initial reconciliation.
    Request-IndexRefresh -Full
    $script:IndexMonitorInitialPending = $true
}

function Request-IndexRefresh {
    param([string[]]$Paths = @(), [switch]$Full)
    Initialize-IndexFolders
    $queueDir = Join-Path $script:IndexDir 'changes'
    [void][IO.Directory]::CreateDirectory($queueDir)
    $valid = @{}
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $fullPath = $path
        if (-not [IO.Path]::IsPathRooted($path)) { $fullPath = Join-Path $script:Root $path }
        $relative = Get-RelativePath $fullPath
        if ($relative -and -not (Test-IgnoredDocument $fullPath)) { $valid[[IO.Path]::GetFullPath($fullPath)] = $true }
    }
    if (-not $Full -and $valid.Count -eq 0) { return }
    $batch = @{ Schema=1; Full=[bool]$Full; Paths=[object[]]@($valid.Keys); CreatedUtc=[datetime]::UtcNow.ToString('o') }
    $target = Join-Path $queueDir ([guid]::NewGuid().ToString('N') + '.json')
    Write-AtomicUtf8 $target ($batch | ConvertTo-Json -Depth 4 -Compress)
}

function Flush-IndexChangeMonitor {
    if (-not $script:IndexChangeMonitor) { return 0 }
    $full = $script:IndexChangeMonitor.TakeFullReconcile() -or $script:IndexMonitorInitialPending
    $script:IndexMonitorInitialPending = $false
    $paths = $script:IndexChangeMonitor.Drain()
    Request-IndexRefresh -Paths $paths -Full:$full
    if ($full) { return [Math]::Max(1, @($paths).Count) }
    return @($paths | Select-Object -Unique).Count
}

function Stop-IndexChangeMonitor {
    if (-not $script:IndexChangeMonitor) { return }
    $null = Flush-IndexChangeMonitor
    $script:IndexChangeMonitor.Dispose()
    $script:IndexChangeMonitor = $null
}
