param([string]$Result)
$ErrorActionPreference='Stop'
# A deterministic test-only background task. The UI must remain responsive and be
# able to cancel this process; real scanning is covered by background/core checks.
[IO.File]::WriteAllText($Result,(@{State='running';Data=@{Done=0;Total=1};Error=''}|ConvertTo-Json -Compress),[Text.Encoding]::UTF8)
$deadline=[datetime]::UtcNow.AddSeconds(20)
while([datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
[IO.File]::WriteAllText($Result,(@{State='failed';Data=$null;Error='Test barrier timed out without cancellation.'}|ConvertTo-Json -Compress),[Text.Encoding]::UTF8)
exit 1
