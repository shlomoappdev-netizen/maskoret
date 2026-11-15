"""Writes test/fixtures/isracard_sample.xlsx: an artificial statement in Isracard's export format (no personal data).
Like the real export ("פירוט עסקאות"): a title row with the month, then a block per card — its name with the last four
digits (wrapped in direction marks), the charge day ("לחיוב ב-02.12"), and sections with their own header row. Dates are
"dd.MM.yy" text; amounts are numbers. It has regular purchases, identical ones on the same day, a refund, a discount
that leaves nothing to charge, an installment ("תשלום 2 מתוך 6"), a foreign purchase charged in ₪ and one charged in $,
one not yet charged ("עסקאות שטרם נקלטו"), a second card, and the totals rows."""
import os, zipfile
from xml.sax.saxutils import escape

S, N = "s", "n"
header = ["תאריך רכישה", "שם בית עסק", "סכום עסקה", "מטבע עסקה", "סכום חיוב", "מטבע חיוב", "מס' שובר", "פירוט נוסף"]
H = [(S, h) for h in header]
rows = [
    [],
    [(S, "פירוט עסקאות"), (S, ""), (S, "נובמבר 2026")],
    [], [],
    [(S, "‫פלטינה מסטרקארד‬ - 1111"), (S, ""), (S, ""), (S, ""), (S, ""), (S, ""), (S, ""), (S, "₪ 1,014.50")],
    [(S, "על שם לקוח לדוגמה"), (S, ""), (S, ""), (S, ""), (S, ""), (S, ""), (S, ""), (S, "לחיוב ב-02.12")],
    [],
    [(S, "עסקאות למועד חיוב")],
    H,
    [(S, "28.10.26"), (S, "סופר השכונה"), (N, 245.9), (S, "₪"), (N, 245.9), (S, "₪"), (S, "100000001")],
    [(S, "15.11.26"), (S, "חניון העירייה"), (N, 12), (S, "₪"), (N, 12), (S, "₪"), (S, "100000002")],
    [(S, "15.11.26"), (S, "חניון העירייה"), (N, 12), (S, "₪"), (N, 12), (S, "₪"), (S, "100000003")],
    [(S, "05.11.26"), (S, "חנות בגדים"), (N, -80), (S, "₪"), (N, -80), (S, "₪"), (S, "100000004"), (S, "זיכוי")],
    [(S, "23.10.26"), (S, "דמי כרטיס"), (N, 24.31), (S, "₪"), (N, 0), (S, "₪"), (S, "100000005"), (S, "הנחה ₪24.31 ")],
    [(S, "10.09.26"), (S, "חנות חשמל"), (N, 600), (S, "₪"), (N, 100), (S, "₪"), (S, "100000006"), (S, "תשלום 2 מתוך 6")],
    [(S, ""), (S, "סה\"כ לחיוב החודש בכרטיס בש\"ח"), (S, ""), (S, ""), (N, 289.9), (S, "₪")],
    [],
    [(S, "עסקאות בחו\"ל")],
    H,
    [(S, "02.11.26"), (S, "AMAZON MKTPLACE"), (N, 20), (S, "$"), (N, 74.6), (S, "₪"), (S, "200000001")],
    [(S, "09.11.26"), (S, "NETFLIX.COM"), (N, 15.49), (S, "$"), (N, 15.49), (S, "$"), (S, "200000002")],
    [],
    [(S, "עסקאות שטרם נקלטו")],
    H,
    [(S, "13.11.26"), (S, "תחנת דלק"), (N, 250), (S, "₪"), (S, ""), (S, ""), (S, "")],
    [],
    [(S, "‫ישראכרט זהב‬ - 2222"), (S, ""), (S, ""), (S, ""), (S, ""), (S, ""), (S, ""), (S, "₪ 18.00")],
    [(S, "על שם לקוח לדוגמה"), (S, ""), (S, ""), (S, ""), (S, ""), (S, ""), (S, ""), (S, "לחיוב ב-10.12")],
    [(S, "עסקאות למועד חיוב")],
    H,
    [(S, "01.11.26"), (S, "בית קפה"), (N, 18), (S, "₪"), (N, 18), (S, "₪"), (S, "300000001")],
    [(S, ""), (S, "סה\"כ לחיוב החודש בכרטיס בש\"ח"), (S, ""), (S, ""), (N, 18), (S, "₪")],
    [],
    [(S, "תנאים משפטיים\nהנתונים במסך זה אינם סופיים")],
]

shared, index = [], {}
def s(text):
    if text not in index:
        index[text] = len(shared)
        shared.append(text)
    return index[text]

def col(i):
    out = ""
    i += 1
    while i:
        i, r = divmod(i - 1, 26)
        out = chr(65 + r) + out
    return out

NS = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
sheet_rows = []
for r, row in enumerate(rows, start=1):
    cells = []
    for c, (kind, value) in enumerate(row):
        ref = f"{col(c)}{r}"
        if kind == N:
            cells.append(f'<c r="{ref}"><v>{value}</v></c>')
        else:
            cells.append(f'<c r="{ref}" t="s"><v>{s(value)}</v></c>')
    sheet_rows.append(f'<row r="{r}">{"".join(cells)}</row>')

files = {
    "[Content_Types].xml": '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>',
    "_rels/.rels": '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    "xl/workbook.xml": f'<?xml version="1.0" encoding="UTF-8"?><workbook {NS} xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="פירוט עסקאות" sheetId="1" r:id="rId1"/></sheets></workbook>',
    "xl/_rels/workbook.xml.rels": '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/></Relationships>',
    "xl/worksheets/sheet1.xml": f'<?xml version="1.0" encoding="UTF-8"?><worksheet {NS}><sheetData>{"".join(sheet_rows)}</sheetData></worksheet>',
    "xl/sharedStrings.xml": f'<?xml version="1.0" encoding="UTF-8"?><sst {NS} count="{len(shared)}" uniqueCount="{len(shared)}">'
        + "".join(f'<si><t xml:space="preserve">{escape(t)}</t></si>' for t in shared) + "</sst>",
}

out = os.path.join(os.path.dirname(__file__), "..", "test", "fixtures", "isracard_sample.xlsx")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for name, text in files.items():
        z.writestr(name, text)
print("wrote", os.path.normpath(out))
