Option Explicit
Dim fso, base, scriptPath, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(base, "search.ps1")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """"
CreateObject("WScript.Shell").Run cmd, 0, False
