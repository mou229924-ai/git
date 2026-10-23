Option Explicit
Dim fso, sh, startupPath, lnkPath
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
startupPath = sh.SpecialFolders("Startup")
lnkPath = fso.BuildPath(startupPath, "SubjectAutoClassifier.lnk")
If fso.FileExists(lnkPath) Then
    fso.DeleteFile lnkPath, True
    MsgBox "Autostart disabled.", 64, "Subject Classifier"
Else
    MsgBox "Autostart was not enabled.", 64, "Subject Classifier"
End If
