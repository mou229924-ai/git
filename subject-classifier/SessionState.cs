using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace Nailong
{
    // Small, rebuildable IPC messages only. Configuration/index files retain their separate atomic writer.
    // Every participating session reader and writer must use the same path mutex.
    public static class SessionStateFile
    {
        private const int MaximumBytes = 65536;
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);

        private static string NormalizePath(string path)
        {
            if (String.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path))
                throw new ArgumentException("An absolute session-state file path is required.", "path");
            string full = Path.GetFullPath(path);
            if (String.IsNullOrEmpty(Path.GetFileName(full)))
                throw new ArgumentException("A session-state file name is required.", "path");
            return full;
        }

        public static string GetMutexName(string path)
        {
            string normalized = NormalizePath(path).ToLowerInvariant();
            using (SHA256 hash = SHA256.Create())
            {
                return "Local\\NailongSessionState_" + BitConverter.ToString(hash.ComputeHash(Utf8.GetBytes(normalized))).Replace("-", "");
            }
        }

        private static void Acquire(Mutex mutex, int timeoutMilliseconds)
        {
            if (timeoutMilliseconds < 1 || timeoutMilliseconds > 5000)
                throw new ArgumentOutOfRangeException("timeoutMilliseconds");
            bool owned;
            try { owned = mutex.WaitOne(timeoutMilliseconds); }
            catch (AbandonedMutexException) { owned = true; }
            if (!owned) throw new TimeoutException("Session-state IPC is busy; the message was not accessed.");
        }

        public static void WriteUtf8(string path, string text, int timeoutMilliseconds)
        {
            string full = NormalizePath(path);
            byte[] bytes = Utf8.GetBytes(text ?? String.Empty);
            if (bytes.Length > MaximumBytes) throw new InvalidDataException("Session-state IPC message exceeds 64 KiB.");
            using (Mutex mutex = new Mutex(false, GetMutexName(full)))
            {
                bool owned = false;
                try
                {
                    Acquire(mutex, timeoutMilliseconds); owned = true;
                    // Keep the existing file identity, EFS, ACLs and other streams. No rename or replacement.
                    using (FileStream stream = new FileStream(full, FileMode.OpenOrCreate, FileAccess.Write, FileShare.None))
                    {
                        stream.SetLength(0);
                        stream.Write(bytes, 0, bytes.Length);
                        stream.Flush(true);
                    }
                }
                finally { if (owned) mutex.ReleaseMutex(); }
            }
        }

        public static string ReadUtf8(string path, int timeoutMilliseconds)
        {
            string full = NormalizePath(path);
            using (Mutex mutex = new Mutex(false, GetMutexName(full)))
            {
                bool owned = false;
                try
                {
                    Acquire(mutex, timeoutMilliseconds); owned = true;
                    using (FileStream stream = new FileStream(full, FileMode.Open, FileAccess.Read, FileShare.Read))
                    {
                        if (stream.Length > MaximumBytes) throw new InvalidDataException("Session-state IPC message exceeds 64 KiB.");
                        using (StreamReader reader = new StreamReader(stream, Utf8, true)) { return reader.ReadToEnd(); }
                    }
                }
                finally { if (owned) mutex.ReleaseMutex(); }
            }
        }
    }
}
