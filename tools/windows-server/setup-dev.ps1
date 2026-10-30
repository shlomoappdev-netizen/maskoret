<#
  Prepares the server for developing the Windows app (flutter_app) with Claude Code: build, run and test it on real
  Windows. Run in PowerShell **as Administrator**, after setup.ps1:
    Set-ExecutionPolicy -Scope Process Bypass -Force; .\setup-dev.ps1

    1. Visual Studio 2022 Build Tools with the C++ desktop workload (needed by `flutter build windows`)
    2. Flutter (stable, the version CI uses) in C:\flutter, on the PATH
    3. Inno Setup (the Windows installer)
    4. The code in C:\maskoret (separate from the support agent's C:\maskoret-agent), and GitHub sign-in for pushing
#>
$ErrorActionPreference = 'Stop'
function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
$flutterVersion = '3.44.4'   # same as .github/workflows/flutter-app.yml

Step '1/4 Visual Studio Build Tools (C++) — לוקח כמה דקות'
winget install --id Microsoft.VisualStudio.2022.BuildTools -e --silent --accept-package-agreements --accept-source-agreements `
    --override '--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'

Step '2/4 Flutter'
if (-not (Test-Path 'C:\flutter\bin\flutter.bat')) {
    git clone -q --depth 1 --branch $flutterVersion https://github.com/flutter/flutter.git C:\flutter
}
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machinePath -notlike '*C:\flutter\bin*') {
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;C:\flutter\bin", 'Machine')
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
flutter config --no-analytics | Out-Null
flutter config --enable-windows-desktop | Out-Null
flutter doctor

Step '3/4 Inno Setup'
winget install --id JRSoftware.InnoSetup -e --silent --accept-package-agreements --accept-source-agreements

Step '4/4 הקוד והתחברות ל-GitHub'
if (-not (Test-Path 'C:\maskoret\.git')) { git clone -q https://github.com/shlomoappdev-netizen/maskoret.git C:\maskoret }
Push-Location C:\maskoret\flutter_app
flutter pub get
Pop-Location
# gh writes "not logged in" to stderr, which Windows PowerShell would treat as an error: check the exit code instead.
$ErrorActionPreference = 'Continue'
gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'התחברות ל-GitHub עם החשבון shlomoappdev-netizen (כדי ש-Claude יוכל לדחוף שינויים):' -ForegroundColor Yellow
    gh auth login --hostname github.com --git-protocol https --web
}
gh auth setup-git
git config --global core.autocrlf true

Write-Host "`nמוכן לפיתוח: פתח באפליקציית Claude שיחת Code חדשה בתיקייה C:\maskoret." -ForegroundColor Green
