<#
  Installs the support agent (tools/support-agent) on the always-on Windows server, as a scheduled task that starts
  with Windows and restarts if it stops. Run in PowerShell **as Administrator**, after setup.ps1:
    Set-ExecutionPolicy -Scope Process Bypass -Force; .\install-agent.ps1

  The agent wakes on every subscriber message and asks Claude Code (read-only, with your Claude subscription — no API
  key) for proposals that only the admin sees. Steps for you, when the script asks: sign in to Claude Code once, give
  Claude (in the chat) the token's fingerprint it prints, and type this Windows user's password for the task.
  Log: %LOCALAPPDATA%\maskoret\agent.log
#>
# Its own clone, apart from the development folder (C:\maskoret): the agent pulls it every hour.
param([string]$Dir = 'C:\maskoret-agent')
$ErrorActionPreference = 'Stop'
function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$data = Join-Path $env:LOCALAPPDATA 'maskoret'
New-Item -ItemType Directory -Force -Path $data | Out-Null

Step '1/5 הקוד'
if (Test-Path "$Dir\.git") { git -C $Dir pull -q --ff-only }
else { git clone -q https://github.com/shlomoappdev-netizen/maskoret.git $Dir }
Push-Location "$Dir\tools\support-agent"
npm install --silent --no-audit --no-fund
Pop-Location

Step '2/5 Claude Code'
$claude = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
if (-not (Test-Path $claude)) { Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression }
& $claude --version
Write-Host 'עכשיו צריך להתחבר פעם אחת עם המנוי שלך: בחלון שנפתח, הקלד /login והשלם את ההתחברות, ואז /exit.' -ForegroundColor Yellow
Start-Process -FilePath $claude -WorkingDirectory $Dir -Wait

Step '3/5 טוקן לסוכן'
$tokenFile = Join-Path $data 'agent-token.dpapi'
if (-not (Test-Path $tokenFile)) {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $token = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    # Encrypted for this Windows user only (DPAPI).
    ConvertTo-SecureString $token -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -LiteralPath $tokenFile
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($token)) | ForEach-Object { $_.ToString('x2') })
    Remove-Variable token
    Write-Host "`nטביעת האצבע של הטוקן (היא לא סוד — שלח אותה ל-Claude בצ'אט כדי שיאשר אותה בשרת):" -ForegroundColor Yellow
    Write-Host $hash -ForegroundColor Green
    Read-Host "`nלחץ Enter אחרי ש-Claude אישר שהטוקן הופעל"
} else {
    Write-Host 'טוקן כבר קיים.'
}

Step '4/5 משימה מתוזמנת'
$node = (Get-Command node).Source
$runner = Join-Path $data 'run-agent.cmd'
@"
@echo off
set MASKORET_AGENT_PULL=1
set CLAUDE_BIN=$claude
cd /d "$Dir\tools\support-agent"
"$node" agent.mjs >> "$data\agent.log" 2>&1
"@ | Set-Content -LiteralPath $runner -Encoding ASCII
$cred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message 'הסיסמה של משתמש Windows הזה (כדי שהסוכן ירוץ גם בלי שמישהו מחובר)'
$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$runner`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'Maskoret Support Agent' -Action $action -Trigger $trigger -Settings $settings `
    -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Limited -Force | Out-Null
Start-ScheduledTask -TaskName 'Maskoret Support Agent'

Step '5/5 בדיקה'
Start-Sleep -Seconds 15
Get-Content "$data\agent.log" -Tail 5
Write-Host "`nסוכן התמיכה פועל על השרת. יומן: $data\agent.log" -ForegroundColor Green
