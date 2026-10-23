Option Explicit
Dim fso, sh, base, startupPath, lnk
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
startupPath = sh.SpecialFolders("Startup")
Set lnk = sh.CreateShortcut(fso.BuildPath(startupPath, "SubjectAutoClassifier.lnk"))
lnk.TargetPath = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\wscript.exe"
lnk.Arguments = """" & fso.BuildPath(base, "启动监听.vbs") & """"
lnk.WorkingDirectory = base
lnk.WindowStyle = 7
lnk.Description = "Subject auto classifier"
lnk.Save
MsgBox "Autostart enabled." & vbCrLf & fso.BuildPath(startupPath, "SubjectAutoClassifier.lnk"), 64, "Subject Classifier"
