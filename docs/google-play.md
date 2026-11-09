# העלאה ל-Google Play — מדריך מסודר

המסמך הזה מרכז את כל מה שצריך כדי להעלות את "מחשבון שכר" ל-Google Play ולעבור את הבדיקה של Google:
הצעדים בחשבון המפתח, הטקסטים לדף בחנות, והתשובות לטפסים של Google. הקישורים לאתר כבר קיימים ועובדים.

הערה: ה-APK מהאתר ממשיך כמו היום (עם העדכון העצמי). ל-Play יש בנייה נפרדת (`tools/build_play_bundle.sh`) בלי עדכון
עצמי ובלי ההרשאה להתקין קבצים — Google אוסרים על אפליקציה מ-Play לעדכן את עצמה.

---

## 1. מה שרק אתה יכול לעשות (חשבון וזהות)

1. **חשבון מפתח** ב-[Play Console](https://play.google.com/console) (תשלום חד-פעמי של 25$, אימות זהות עם תעודה).
   - **חשבון אישי** (Personal): לפני פרסום לכולם Google דורשים **בדיקה סגורה עם לפחות 12 בודקים, 14 ימים ברצף**.
     אפשר לגייס אותם מהמנויים הקיימים (הם צריכים חשבון Google ולהצטרף לבדיקה מהקישור).
   - **חשבון ארגון** (Organization): פטור מהדרישה הזו, אבל צריך מספר D-U-N-S לעסק.
2. **חשבון בדיקה ל-Google**: האפליקציה דורשת התחברות, אז הבודקים של Google צריכים משתמש. צור חשבון רגיל באפליקציה
   (למשל מייל ייעודי), מלא בו נתוני דוגמה, ותן את פרטיו בטופס "App access" (סעיף 5). אל תשתמש בחשבון האמיתי שלך.
3. **מפתח החתימה**: כשיוצרים את האפליקציה ב-Console, ב-"App signing" לבחור **להשתמש במפתח הקיים**
   (Use existing app signing key → "Export and upload a key from Java keystore", עם כלי ה-PEPK ש-Google נותנים)
   ולהעלות את `flutter_app/android/maskoret-release.jks`. כך מי שהתקין מהאתר יכול לעבור ל-Play בלי להסיר ולהתקין
   מחדש, וההתחברות עם Google ממשיכה לעבוד בלי שינוי.
   - אם בכל זאת תבחר במפתח ש-Google יוצרים: צריך להוסיף את ה-SHA-1 של "App signing key certificate" מה-Console
     ללקוח ה-OAuth של Android ב-Google Cloud, אחרת ההתחברות עם Google לא תעבוד בגרסה מ-Play.

## 2. יצירת האפליקציה

| שדה | ערך |
|---|---|
| App name | מחשבון שכר – תקציב הבית |
| Default language | עברית (he-IL) |
| App or game | App |
| Free or paid | Free |
| Package name | com.shlomodavid.maskoret (נקבע אוטומטית מה-AAB) |

## 3. הדף בחנות (Main store listing)

**שם (עד 30 תווים):**
> מחשבון שכר – תקציב הבית

**תיאור קצר (עד 80 תווים):**
> כמה באמת נשאר בסוף החודש: מהברוטו לנטו, אשראי, תשלומים, חיסכון ותחזית קדימה

**תיאור מלא:**

> מחשבון שכר עוזר לדעת בדיוק כמה כסף נשאר לכם החודש — לא הערכה כללית, אלא חשבון אמיתי מהתלוש ועד כרטיס האשראי.
>
> 💼 מהברוטו לנטו
> מקלידים ברוטו, והאפליקציה מחשבת מס הכנסה לפי מדרגות ונקודות זיכוי, ביטוח לאומי, מס בריאות, פנסיה וקרן השתלמות. אפשר לסרוק תלוש שכר — הקריאה נעשית במכשיר עצמו.
>
> 💳 כרטיס אשראי ותשלומים
> טוענים את קובץ הפירוט מחברת האשראי, והחיובים והתשלומים נכנסים לחודשים הנכונים. חיובים במטבע חוץ מומרים לפי השער היציג של בנק ישראל.
>
> 🏠 מסך הבית
> כמה נשאר בפועל ממה שכבר ירד, כמה צפוי להישאר אחרי חיוב האשראי, ולאן הולך הנטו.
>
> 📈 תחזית, חיסכון ומגמות
> תחזית לחודשים הבאים לפי ההוצאות הקבועות והתשלומים, יעדי חיסכון ופיקדונות, ומגמות הוצאה עם תקרה חודשית.
>
> 👨‍👩‍👧 משק בית משותף
> מזמינים את בן או בת הזוג עם קוד, וכל שינוי מגיע לכל המכשירים תוך שניות — אנדרואיד, Windows, Mac ואייפון.
>
> 🤲 ועוד
> מעשרות שמחושבות מההכנסות, חובות שחייבים לכם, חיובים משותפים עם חברים, היסטוריית גרסאות ושחזור.
>
> 🔐 פרטיות
> הנתונים נשמרים בשרת מאובטח באירופה, ורק אתם ומי שהזמנתם רואים אותם. בלי פרסומות, ולא מוכרים מידע. האפליקציה לא מתחברת לחשבון הבנק.
>
> חינם, וקוד פתוח ב-GitHub.
>
> שימו לב: החישובים הם הערכה לפי הנתונים שהזנתם, ולא ייעוץ פיננסי או מיסויי.

**גרפיקה:**
- אייקון 512×512: [docs/play/icon-512.png](play/icon-512.png) (מוכן).
- תמונה ראשית (Feature graphic) 1024×500: [docs/play/feature-graphic.png](play/feature-graphic.png) (מוכנה).
- לפחות 2 צילומי מסך מהטלפון (מומלץ 4–6: מסך הבית, אשראי, תקציב, תחזית, מגמות). בלי נתונים אמיתיים —
  אפשר לבנות עם נתוני הדוגמה: `flutter run --dart-define=DEMO=true`.

**פרטי קשר:** מייל shlomoappdev@gmail.com · אתר https://shlomoappdev-netizen.github.io/maskoret-releases/

## 4. קטגוריה ותגיות
- Category: **Finance**
- Tags: Budget, Personal finance, Money manager

## 5. App content — התשובות לטפסים

**Privacy policy:** https://shlomoappdev-netizen.github.io/maskoret-releases/privacy.html

**App access:** "All or some functionality is restricted" → להוסיף את פרטי חשבון הבדיקה מסעיף 1,
עם הוראה: "Sign in with email and password on the first screen."

**Ads:** No, the app does not contain ads.

**Content rating (IARC):** קטגוריה "All other app types" / Utility, productivity. לענות "לא" על אלימות, מין, שפה,
סמים, הימורים. על שיתוף תוכן בין משתמשים: הנתונים משותפים רק עם מי שהמשתמש הזמין למשק הבית שלו (לא ציבורי).
התוצאה הצפויה: 3+ / Everyone.

**Target audience:** 18 ומעלה. האפליקציה לא מיועדת לילדים.

**News app:** No. **Government app:** No. **Health:** No.

**Financial features:** לסמן **"Personal finance → Budgeting / money management"** (ניהול תקציב אישי). לא: הלוואות,
בנקאות, קריפטו, תשלומים, השקעות. האפליקציה לא מעבירה כסף ולא מתחברת לחשבונות בנק.

**Data safety** (מה שנאסף, לפי מה שהאפליקציה באמת עושה):

| סוג מידע (Google) | נאסף? | למה | חובה? |
|---|---|---|---|
| Personal info → Email address | כן | Account management | חובה |
| Personal info → Name | כן (שם תצוגה) | Account management | חובה |
| Financial info → Other financial info | כן (התקציב שהמשתמש מזין) | App functionality | חובה |
| Messages → Other in-app messages | כן (פניות תמיכה, והשיחה עם ה-AI שנשמרת בחשבון כדי להסתנכרן בין המכשירים) | Developer communications / App functionality | לא חובה |
| App info and performance → Diagnostics | כן, רק אם המשתמש מצרף לפנייה | App functionality (תמיכה) — לא Analytics | לא חובה |
| App info and performance → Other (גרסת האפליקציה, פעילות אחרונה) | כן | App functionality / support | חובה |
| Location, Contacts, Photos, Files, Device IDs | לא | — | — |

- תלושים וקובצי אשראי מעובדים במכשיר בלבד, ולכן לפי ההגדרה של Google הם **לא** "נאספים".
- **Data shared with third parties:** No. (Supabase הוא ספק שירות שמעבד בשמנו — לא נחשב שיתוף. תובנות AI בענן נשלחות
  מהמכשיר ישירות לספק שהמשתמש בחר, רק לבקשתו ועם המפתח שלו. המפתח נשמר מוצפן בחשבון רק אם המשתמש בחר בזה.)
- **Encrypted in transit:** Yes.
- **Users can request deletion:** Yes — מתוך האפליקציה, ובקישור:
  https://shlomoappdev-netizen.github.io/maskoret-releases/delete-account.html

## 6. בנייה והעלאה

1. `tools/build_play_bundle.sh` — בונה AAB ל-Play מהגרסה ב-`version.json`, חתום ובלי REQUEST_INSTALL_PACKAGES.
2. ב-Console: Testing → **Closed testing** → Create track → להעלות את ה-AAB → להוסיף את 12 הבודקים (רשימת מיילים
   או Google Group) → לשלוח לבדיקה.
3. אחרי 14 ימים עם 12 בודקים: Production → Apply for production → ושוב לשלוח לבדיקה.
4. כל גרסה חדשה: להריץ שוב את הסקריפט ולהעלות את ה-AAB (ה-versionCode עולה לבד עם ה-build).

## 7. דרישות טכניות שכבר מתקיימות
- Target API 36 (Android 16) — הדרישה של Google לאפליקציות חדשות מ-31.08.2026.
- AAB עם arm64-v8a, armeabi-v7a, x86_64.
- מחיקת חשבון מתוך האפליקציה + דף מחיקה באתר.
- מדיניות פרטיות בעברית ובאנגלית, מעודכנת ל-08.11.2026.
