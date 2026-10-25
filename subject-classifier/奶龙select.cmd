@echo off
setlocal
set "NAILONG_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "NAILONG_ENTRY=%~dp0setup.ps1"
if not exist "%NAILONG_PS%" (
  echo Windows PowerShell 5.1 is required. See README.md.
  pause
  exit /b 1
)
"%NAILONG_PS%" -NoLogo -NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -Command "$ErrorActionPreference='Stop'; try { & $env:NAILONG_ENTRY -Launch } catch { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show(($_.Exception.Message + [Environment]::NewLine + [Environment]::NewLine + 'If this trusted download was blocked: compare the ZIP SHA-256 with its GitHub release, then open ZIP Properties, select Unblock if shown, and extract again. Organization policy may require a trusted signature. No system policy was changed.'),'Nailong Select - Start failed',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error); exit 1 }"
exit /b %ERRORLEVEL%
