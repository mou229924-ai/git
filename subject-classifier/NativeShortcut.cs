using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace Nailong
{
    public sealed class ShortcutInformation
    {
        public string TargetPath { get; internal set; }
        public string Arguments { get; internal set; }
        public string WorkingDirectory { get; internal set; }
        public string Description { get; internal set; }
        public string IconPath { get; internal set; }
        public int IconIndex { get; internal set; }
        public int ShowCommand { get; internal set; }
    }

    // IShellLinkW and IPersistFile take UTF-16 strings. Never route names through WSH/ANSI.
    public static class NativeShortcut
    {
        [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
        private class ShellLinkObject { }

        [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellLinkW
        {
            void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int capacity, IntPtr findData, uint flags);
            void GetIDList(out IntPtr itemIdList);
            void SetIDList(IntPtr itemIdList);
            void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder description, int capacity);
            void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string description);
            void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder directory, int capacity);
            void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
            void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder arguments, int capacity);
            void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string arguments);
            void GetHotkey(out short hotkey);
            void SetHotkey(short hotkey);
            void GetShowCmd(out int showCommand);
            void SetShowCmd(int showCommand);
            void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder iconPath, int capacity, out int iconIndex);
            void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int iconIndex);
            void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
            void Resolve(IntPtr owner, uint flags);
            void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
        }

        private static string LinkPath(string path)
        {
            if (String.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path))
                throw new ArgumentException("An absolute shortcut path is required.", "path");
            string full = Path.GetFullPath(path);
            if (!String.Equals(Path.GetExtension(full), ".lnk", StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("The shortcut path must end in .lnk.", "path");
            return full;
        }

        public static void Create(string path, string targetPath, string arguments, string workingDirectory,
                                  string description, string iconPath, int showCommand)
        {
            string full = LinkPath(path);
            if (String.IsNullOrWhiteSpace(targetPath) || !Path.IsPathRooted(targetPath))
                throw new ArgumentException("An absolute shortcut target is required.", "targetPath");
            string directory = Path.GetDirectoryName(full);
            if (!Directory.Exists(directory)) throw new DirectoryNotFoundException(directory);
            string temporary = Path.Combine(directory, Path.GetFileNameWithoutExtension(full) + "." + Guid.NewGuid().ToString("N") + ".lnk");
            object instance = new ShellLinkObject();
            try
            {
                IShellLinkW link = (IShellLinkW)instance;
                link.SetPath(Path.GetFullPath(targetPath));
                link.SetArguments(arguments ?? String.Empty);
                link.SetWorkingDirectory(String.IsNullOrEmpty(workingDirectory) ? String.Empty : Path.GetFullPath(workingDirectory));
                link.SetDescription(description ?? String.Empty);
                link.SetShowCmd(showCommand);
                if (!String.IsNullOrEmpty(iconPath)) link.SetIconLocation(Path.GetFullPath(iconPath), 0);
                IPersistFile file = (IPersistFile)instance;
                file.Save(temporary, true);
                file.SaveCompleted(temporary);
                if (File.Exists(full)) File.Replace(temporary, full, null);
                else File.Move(temporary, full);
            }
            finally
            {
                Marshal.FinalReleaseComObject(instance);
                if (File.Exists(temporary)) File.Delete(temporary);
            }
        }

        public static ShortcutInformation Read(string path)
        {
            string full = LinkPath(path);
            if (!File.Exists(full)) throw new FileNotFoundException("Shortcut does not exist.", full);
            object instance = new ShellLinkObject();
            try
            {
                ((IPersistFile)instance).Load(full, 0);
                IShellLinkW link = (IShellLinkW)instance;
                StringBuilder target = new StringBuilder(32768);
                StringBuilder arguments = new StringBuilder(32768);
                StringBuilder working = new StringBuilder(32768);
                StringBuilder description = new StringBuilder(32768);
                StringBuilder icon = new StringBuilder(32768);
                int show, iconIndex;
                // SLGP_RAWPATH returns the stored path without Resolve or launching the target.
                link.GetPath(target, target.Capacity, IntPtr.Zero, 4);
                link.GetArguments(arguments, arguments.Capacity);
                link.GetWorkingDirectory(working, working.Capacity);
                link.GetDescription(description, description.Capacity);
                link.GetIconLocation(icon, icon.Capacity, out iconIndex);
                link.GetShowCmd(out show);
                return new ShortcutInformation {
                    TargetPath = target.ToString(), Arguments = arguments.ToString(), WorkingDirectory = working.ToString(),
                    Description = description.ToString(), IconPath = icon.ToString(), IconIndex = iconIndex, ShowCommand = show
                };
            }
            finally { Marshal.FinalReleaseComObject(instance); }
        }
    }
}
