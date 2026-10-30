# שרת Windows שתמיד דלוק

מחשב Windows שער 24/7 מריץ את מה שצריך מחשב פעיל כל הזמן. כרגע זה **סוכן התמיכה**: כל הודעה של מנוי מעירה את Claude, והוא מכין הצעות שרק המנהל רואה. הפרסום של גרסאות כבר רץ בענן (GitHub Actions), ובנייה של המק והאייפון חייבת Mac.

ב-PowerShell **כמנהל** (Run as Administrator):

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
$base = 'https://raw.githubusercontent.com/shlomoappdev-netizen/maskoret/main/tools/windows-server'
irm "$base/setup.ps1" -OutFile setup.ps1; irm "$base/install-agent.ps1" -OutFile install-agent.ps1
.\setup.ps1          # תמיד דלוק, SSH, Tailscale, AnyDesk, Git, Node, gh
.\install-agent.ps1  # סוכן התמיכה כמשימה שעולה עם Windows
```

- **‏`setup.ps1`:**
  - מבטל שינה, ומגדיר שהפעלות מחדש של עדכוני Windows יקרו רק בין 23:00 ל-06:00.
  - מפעיל שרת SSH שה-shell שלו הוא PowerShell.
  - מתקין Tailscale, ‏AnyDesk, ‏Git, ‏Node.js LTS ו-GitHub CLI.
  - בסוף הוא מבקש ממך להתחבר ל-Tailscale ולהגדיר ב-AnyDesk גישה בלי אישור על המסך (סיסמה ואימות דו-שלבי).
- **‏`install-agent.ps1`:**
  - משכפל את הקוד ל-`C:\maskoret`, והסוכן מושך ממנו עדכונים כל שעה.
  - מתקין את Claude Code, ומבקש ממך להתחבר אליו פעם אחת עם המנוי.
  - יוצר טוקן חדש לסוכן. הטוקן נשמר מוצפן, כך שרק משתמש Windows הזה יכול לפענח אותו. הסקריפט מציג טביעת אצבע של הטוקן, שאותה שולחים ל-Claude בצ'אט כדי שיאשר אותה בשרת.
  - רושם משימה מתוזמנת שעולה עם Windows ומופעלת מחדש אם היא נעצרת.
- **יומן:** ‏`%LOCALAPPDATA%\maskoret\agent.log`

אחרי שהסוכן עובד על השרת, מכבים את הסוכן שבמק: `tools/support-agent/install.sh remove`.
