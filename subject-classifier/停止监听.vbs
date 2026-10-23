Option Explicit
Dim svc, procs, p, cmdline, killed
killed = 0
Set svc = GetObject("winmgmts:\\.\root\cimv2")
Set procs = svc.ExecQuery("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='powershell.exe'")
For Each p In procs
    If Not IsNull(p.CommandLine) Then
        cmdline = LCase(p.CommandLine)
        If InStr(cmdline, "classifier.ps1") > 0 Then
            p.Terminate()
            killed = killed + 1
        End If
    End If
Next
MsgBox "Stopped " & killed & " watcher process(es).", 64, "Subject Classifier"
