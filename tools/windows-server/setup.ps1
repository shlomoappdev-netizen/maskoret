<#
  One-time setup of the always-on Windows server for מחשבון שכר.
  Run in PowerShell **as Administrator**:
    Set-ExecutionPolicy -Scope Process Bypass -Force; .\setup.ps1

  What it does:
    1. Never sleeps; Windows Update restarts only at night (23:00–06:00)
    2. OpenSSH server (PowerShell as its shell) — remote access for you and for Claude Code
    3. Tailscale (a private network between the server, the Mac and the phone — no open router ports)
    4. AnyDesk, Git, Node.js LTS, GitHub CLI
  What stays for you (the script says when): signing in to Tailscale, and AnyDesk's unattended-access password.
#>
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'יש להריץ את הסקריפט ב-PowerShell כמנהל (Run as Administrator).'
}
function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }

Step '1/4 תמיד דלוק'
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change disk-timeout-ac 0
powercfg /hibernate off
# Windows Update: no restart while someone is signed in, and active hours 06:00–23:00.
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $au -Force | Out-Null
Set-ItemProperty -Path $au -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord
$ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
New-Item -Path $ux -Force | Out-Null
Set-ItemProperty -Path $ux -Name ActiveHoursStart -Value 6 -Type DWord
Set-ItemProperty -Path $ux -Name ActiveHoursEnd -Value 23 -Type DWord
Write-Host 'שינה וכיבוי דיסקים בוטלו; הפעלות מחדש של עדכונים רק בלילה.'
Write-Host 'מומלץ גם ב-BIOS: "Restore on AC Power Loss" = Power On, כדי שהמחשב יידלק לבד אחרי הפסקת חשמל.' -ForegroundColor Yellow

Step '2/4 שרת SSH'
$cap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
    -Value "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True `
        -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}
Write-Host 'SSH פועל (פורט 22).'

Step '3/4 תוכנות'
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget לא מותקן במחשב הזה. התקן את "App Installer" מ-Microsoft Store (או עדכן את Windows) והרץ שוב.'
}
foreach ($id in 'Tailscale.Tailscale', 'AnyDeskSoftwareGmbH.AnyDesk', 'Git.Git', 'OpenJS.NodeJS.LTS', 'GitHub.cli') {
    Write-Host "מתקין $id…"
    winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements --scope machine 2>&1 |
        Select-String -Pattern 'Successfully|already installed|No newer' | ForEach-Object { "   $_" }
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

Step '4/4 התחברות'
Write-Host 'Tailscale: ייפתח דפדפן — התחבר עם אותו חשבון שתשתמש בו גם במק ובטלפון.' -ForegroundColor Yellow
& "$env:ProgramFiles\Tailscale\tailscale.exe" up --unattended
& "$env:ProgramFiles\Tailscale\tailscale.exe" ip -4 | ForEach-Object { Write-Host "כתובת השרת ב-Tailscale: $_" -ForegroundColor Green }
Write-Host @'
AnyDesk: פתח אותו ← הגדרות ← אבטחה ←
  • "גישה לא מבוקרת" (Unattended Access): להפעיל ולבחור סיסמה חזקה
  • אימות דו-שלבי: להפעיל
  • רשימת גישה: רק ה-AnyDesk ID של המק והטלפון שלך
'@ -ForegroundColor Yellow
Write-Host "`nהשלב הבסיסי הושלם. השלב הבא: install-agent.ps1 (סוכן התמיכה)." -ForegroundColor Green
