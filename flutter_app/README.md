# מחשבון שכר — גרסת Android ו-Windows (Flutter)

אותה אפליקציה כמו באייפון ובמק, עם אותו חשבון ואותם משקי בית. השינויים מסתנכרנים בין כל המכשירים דרך השרת (Supabase).

## מה יש בגרסה הראשונה

- **כניסה:** התחברות במייל וסיסמה, הרשמה עם קוד אימות בן 6 ספרות שמגיע במייל, "שכחתי סיסמה" עם קוד, והתחברות עם Google (אחרי ההגדרה שבהמשך). כמו באייפון ובמק, צריך חשבון.
- **הכל בענן:** הנתונים נשמרים בשרת. במכשיר נשאר רק עותק זמני **מוצפן** (AES-GCM, המפתח באחסון המאובטח של Android/Windows) לעבודה בלי אינטרנט, והוא נמחק בהתנתקות. חשבון אחר שמתחבר באותו מכשיר מתחיל ריק.
- **גרסאות קודמות:** 30 הגרסאות האחרונות של משק הבית שמורות בשרת, ואפשר לשחזר כל אחת (משקי בית וחשבון ← גרסאות קודמות).
- **משקי בית:** רשימה, מעבר בין משקי בית, יצירה, קוד הזמנה, הצטרפות עם קוד, עזיבה, מחיקה, הסרת חבר ושינוי שם.
- **מסכים:** סיכום החודש, הכנסות, ניכויים (כולל חישוב אוטומטי של מס הכנסה לפי מדרגות ונקודות זיכוי, ביטוח לאומי, מס בריאות, פנסיה וקרן השתלמות), הוצאות קבועות, תנועות, וחשבונות וחסכונות.
- אם במשק הבית יש כמה בני משפחה, בוחרים את מי עורכים בכפתור 👥 שבסרגל העליון.

**עוד לא קיימים כאן** (ממשיכים לעבוד באייפון ובמק): ייבוא כרטיס אשראי ו-Max, תחזית, מעשרות, חובות, מגמות, תובנות AI, וקניות חוזרות.
**הנתונים של המסכים האלה לא נמחקים:** האפליקציה שומרת את כל המסמך כמו שהוא, ומשנה רק את השדות שערכת בה.

## הורדה

### Windows
1. נכנסים ל-GitHub, ללשונית **Actions** של המאגר, ובוחרים את ההרצה האחרונה של **Flutter app (Windows + Android)**.
2. בתחתית הדף, תחת **Artifacts**, מורידים את `maskoret-windows`.
3. פותחים את ה-ZIP לתיקייה קבועה (למשל `C:\מחשבון שכר`) ומפעילים את `maskoret.exe`. צריך להשאיר את כל הקבצים שבתיקייה יחד.
   בפעם הראשונה Windows עלול להציג "Windows protected your PC", כי האפליקציה לא חתומה: לוחצים **More info** ואז **Run anyway**.

### Android
- במק: מריצים `tool/build_android.sh`. הקובץ המוכן נשמר ב-`להפצה/Android/מחשבון שכר.apk`.
- או מאותו דף של ההרצה ב-GitHub מורידים את `maskoret-android`.
- מעבירים לטלפון ומתקינים. צריך לאשר "התקנה ממקורות לא ידועים".

כל קבצי ההתקנה (Mac, ‏Android, ‏Windows) מרוכזים בתיקייה `להפצה` שבתיקייה הראשית, וההסבר נמצא בקובץ `איפה מה.txt` שבתוכה.

## העלאה ל-GitHub (פעם אחת)

הפרויקט עוד לא נמצא ב-git. כדי ש-GitHub יבנה את גרסת Windows:

1. יוצרים מאגר חדש ב-GitHub, **פרטי** (Private), למשל `maskoret`, בלי README.
2. בטרמינל, בתיקייה `מחשבון שכר` (התיקייה הראשית, לא `flutter_app`):
   ```bash
   git init -b main
   git add .
   git commit -m "מחשבון שכר"
   git remote add origin https://github.com/<שם-המשתמש>/maskoret.git
   git push -u origin main
   ```
3. הבנייה מתחילה לבד (בערך 10 דקות). מכאן, כל `git push` שמשנה את `flutter_app/` בונה גרסה חדשה. אפשר גם להפעיל אותה ידנית: **Actions → Flutter app → Run workflow**.

הקובץ `.gitignore` שבתיקייה הראשית משאיר מחוץ למאגר קבצים אישיים: קבצי אקסל (פירוטי כרטיס), התיקייה `להפצה` וקבצי מערכת. לפני ה-push הראשון כדאי להריץ `git status` ולוודא שאין שם שום דבר אישי.

## עדכונים אוטומטיים

כל הגרסאות (Mac, ‏Android, ‏Windows) מתפרסמות במאגר הציבורי [maskoret-releases](https://github.com/shlomoappdev-netizen/maskoret-releases), יחד עם קובץ גרסה משותף: `https://shlomoappdev-netizen.github.io/maskoret-releases/latest.json`. האפליקציה בודקת את הקובץ הזה כשהיא נפתחת וכשחוזרים אליה. אם ה-`build` שבו גבוה מזה שמותקן, מופיע "יש גרסה חדשה". "עדכן עכשיו" מוריד את הקובץ, מוודא שהוא זהה לזה שפורסם (sha256) ומתקין:
- **Android:** נפתח המתקין של המערכת. בפעם הראשונה צריך לאשר "התקנה מהאפליקציה הזו".
- **Windows:** האפליקציה מחליפה את הקבצים שלה ונפתחת מחדש. התיקייה שלה צריכה להיות תיקייה שלך, לא Program Files.

**מספרי גרסה:** הגרסה ומספר ה-build נלקחים מ-`version.json` שבתיקייה הראשית. זה מונה אחד לכל האפליקציות, ו-`tool/build_android.sh` והבנייה ב-GitHub משתמשים בו. לפני פרסום גרסה מעלים את ה-build.

**מפתח החתימה של Android** (`android/maskoret-release.jks` + `android/key.properties`) לא נמצא ב-git. **חובה לשמור ממנו עותק** במקום בטוח, למשל במנהל סיסמאות. בלי המפתח אי אפשר לפרסם עדכון לאפליקציה שכבר מותקנת. אם רוצים שגם ה-APK שנבנה ב-GitHub ייחתם בו, מריצים פעם אחת `tool/setup_github_secrets.sh`.

## התחברות עם Google — הגדרה חד־פעמית

הקוד כבר באפליקציה. כדי שהכפתור יעבוד, צריך להפעיל את Google בשרת:

1. ב-[Google Cloud Console](https://console.cloud.google.com/apis/credentials): יוצרים פרויקט, אחר כך **OAuth consent screen** (סוג External, שם האפליקציה והמייל שלך), ואז **Create credentials → OAuth client ID** מסוג **Web application**.
   ב-**Authorized redirect URIs** מוסיפים: `https://pukbrxsuucqrukiaojlp.supabase.co/auth/v1/callback`
2. ב-Supabase: **Authentication → Sign In / Providers → Google**. מפעילים ומדביקים את ה-Client ID וה-Client Secret.
3. ב-Supabase: **Authentication → URL Configuration → Redirect URLs**. מוסיפים: `com.shlomodavid.maskoret://login-callback`

אחרי זה "התחברות עם Google" פותח את הדפדפן, ואחרי בחירת החשבון חוזרים לאפליקציה מחוברים. ב-Windows האפליקציה רושמת את הקישור הזה לבד בהפעלה הראשונה, בלי התקנה ובלי הרשאות מנהל.

**התחברות עם Apple** דורשת מנוי בתשלום ל-Apple Developer Program (‏99$ לשנה), גם באנדרואיד וב-Windows, כי Supabase צריך מפתח ו-Services ID מאפל. לכן היא לא נכללת כרגע.

## לפני הפצה רחבה

שרת המיילים המובנה של Supabase שולח מיילים (קוד אימות, איפוס סיסמה) **רק לחברי הצוות של הארגון ב-Supabase**. לפני שנותנים את האפליקציה לאחרים, צריך לחבר SMTP משלך: Supabase → Authentication → Emails → SMTP Settings. עד אז, בודקים הרשמה רק עם `<admin email>`.

## למפתחים

```bash
cd flutter_app
flutter pub get
flutter test            # כל הבדיקות (במק: כולל בדיקה מול קוד ה-Swift האמיתי)
flutter run             # אמולטור / מכשיר מחובר
```

- `lib/data/` — המודל. כל מחלקה היא "תצוגה" מעל אובייקט ה-JSON המקורי (`FamilyBackup` מ-`Family.swift`, `Store.SaveFile`, `Budget`, `MoneyData`…). קריאה משתמשת באותן ברירות מחדל של ה-decoder ב-Swift, וכתיבה משנה רק את המפתח שלה. תאריכים הם שניות מ-1.1.2001 (`timeIntervalSinceReferenceDate`), ומזהים הם UUID באותיות גדולות, בדיוק כמו ש-Swift כותב.
- `lib/data/tax.dart` — העתק של `TaxCalc` מ-`TaxRates.swift`. השיעורים ב-`bundled_rates.dart` נוצרו מ-`rates/tax-rates.json`. כשמעדכנים את הקובץ הזה, צריך לעדכן גם אותם.
- `lib/sync/server_sync.dart` — העתק של `ServerSync.swift`: עותק מקומי קודם, השהיה של 2 שניות, `lastSeenRevision`, בהתנגשות הגרסה החדשה יותר מנצחת והשנייה נשמרת כגיבוי במכשיר, Realtime ובדיקה כל 60 שניות.
- `test/compat_test.dart`, `test/sync_test.dart` — טוענים JSON אמיתי מאפליקציית ה-Swift (`test/fixtures/swift_household.json`, אחרי הסתרת שמות וסכומים), מבצעים עריכות וסנכרון, ומוודאים שאף שדה אחר לא השתנה.
- `test/swift_crosscheck_test.dart` (רק במק) — מקמפל את קבצי המודל האמיתיים מ-`Maskoret/` (באמצעות `tool/swift_check.sh`), מפענח איתם את מה שהאפליקציה הזו כותבת, ומשווה את החישובים (מס, נטו, יתרות) לחישובים ב-Dart.
- `tool/make_fixture.py` — יוצר מחדש את קובץ הבדיקה מהנתונים שבמק.
