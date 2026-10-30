# איך לעזור בפיתוח — מחשבון שכר

תודה שבאת לעזור! מחשבון שכר היא אפליקציה חינמית לניהול תקציב משפחתי בישראל: חישוב נטו מהתלוש, הוצאות, כרטיס אשראי, חיסכון, מעשרות ועוד.

> **English:** Maskoret is a free Hebrew household-budget app for Israel (Mac/iPhone in SwiftUI, Android/Windows in
> Flutter, Supabase backend). Issues and pull requests are welcome in English or Hebrew. The rules below are summarized
> in English at the end.

## מבנה הפרויקט

| תיקייה | מה יש בה | פלטפורמות |
|---|---|---|
| `Maskoret/` | אפליקציית SwiftUI | מק, אייפון |
| `flutter_app/` | אפליקציית Flutter | אנדרואיד, Windows |
| `supabase/migrations/` | מבנה מסד הנתונים, הרשאות (RLS) ופונקציות בשרת | — |
| `rates/` | שיעורי מס וביטוח לאומי | כולן |
| `tools/` | פרסום גרסאות וסוכן התמיכה | — |

פרטים נוספים ב-[README.md](README.md).

## הרצה מקומית

- **מק / אייפון:** לפתוח את `Maskoret.xcodeproj` ב-Xcode (26 ומעלה) ולהריץ את `Maskoret` או `MaskoretiOS`.
- **אנדרואיד / Windows:** בתיקייה `flutter_app`: ‏`flutter pub get` ואז `flutter run`. בדיקות: `flutter test`.

האפליקציה מתחברת לשרת Supabase של הפרויקט עם המפתח הציבורי בלבד. כל הנתונים מוגנים בהרשאות בשרת, כך שאפשר לפתוח
חשבון בדיקה רגיל. אין צורך במפתחות סודיים כדי לפתח.

## כללים

1. **כל שינוי עובר דרך בקשת שינוי (Pull Request).** אי אפשר לדחוף ישירות ל-`main`, כי הפרסום למשתמשים יוצא ממנו אוטומטית.
2. **חישובים זהים בכל הפלטפורמות.** חישובי שכר, מס ו״נשאר בסוף החודש״ קיימים גם ב-Swift וגם ב-Dart, וחייבים לצאת זהים
   עד האגורה. שינוי בחישוב נעשה בשני המקומות, ובדיקת ההשוואה (`flutter_app/test/swift_crosscheck_test.dart`) חייבת לעבור.
3. **שינוי שהמשתמש ירגיש בו נרשם ב-[CHANGELOG.md](CHANGELOG.md),** בשורה קצרה בעברית מנקודת המבט של המשתמש. את מספר
   הגרסה ואת הפרסום מנהל המתחזק.
4. **שינויים במסד הנתונים** נכתבים כקובץ מיגרציה חדש ב-`supabase/migrations/`, עם הרשאות (RLS) לכל טבלה חדשה. המתחזק
   מריץ אותם בשרת אחרי בדיקה.
5. **בלי סודות בקוד.** לא מעלים מפתחות, סיסמאות או קבצי חתימה.
6. **העיצוב** בכל הפלטפורמות הולך לפי המק והאייפון: זכוכית, אותה פלטת צבעים ומספרים מיושרים.
7. **ממשק המשתמש בעברית, מימין לשמאל.** הקוד והערות הקוד באנגלית.

## איך מתחילים

- תסתכל ב-[Issues](../../issues), או פתח אחד חדש: תקלה, רעיון או שאלה.
- לפני שינוי גדול, כדאי לפתוח Issue ולתאם, כדי שלא תעבוד על משהו שכבר נמצא בעבודה.

## רישיון

הקוד מופץ ברישיון [GPL-3.0](LICENSE). אפשר להשתמש בו, לשנות ולהפיץ, בתנאי שגם גרסה מופצת נשארת פתוחה באותו רישיון.
כל תרומה מתקבלת באותו רישיון.

---

### Rules in short (English)
Pull requests only (releases ship automatically from `main`) · payroll/tax calculations must stay identical in Swift and
Dart (the cross-check test must pass) · user-visible changes get a Hebrew line in `CHANGELOG.md` · database changes as
new migrations with RLS · no secrets in the repo · UI in Hebrew (RTL), code and comments in English · GPL-3.0.
