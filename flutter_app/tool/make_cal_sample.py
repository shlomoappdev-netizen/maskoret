"""Writes test/fixtures/cal_sample.xlsx: an artificial statement in CAL's export format (no personal data).
Like the real export: every element with an "x:" namespace prefix, absolute targets in the rels, a title row, header
cells that break lines, dates as Excel serial numbers and amounts as numbers. It has a regular purchase, identical
purchases on the same day, a refund ("השבת מכירה", negative), a pending one ("עסקה בקליטה"), installments in 2 and in
10 (one row per payment charged so far, at the purchase date), and the totals rows at the end."""
import datetime, os, zipfile
from xml.sax.saxutils import escape

def serial(d):
    return (datetime.date(*d) - datetime.date(1899, 12, 30)).days

header = ["תאריך\nעסקה", "שם בית עסק", "סכום\nבש\"ח", "מועד\nחיוב", "סוג\nעסקה",
          "מזהה כרטיס\nבארנק דיגילטי", "הנחה", "עיגול", "הערות"]
S, N = "s", "n"
rows = [
    [(S, "פירוט עסקאות וזיכויים — לקוח לדוגמה, חשבון 12-345-678")],
    [(S, h) for h in header],
    [(N, serial((2026, 8, 15))), (S, "המכולת בשכונה"), (N, 120.5), (N, serial((2026, 9, 2))), (S, "רגילה")],
    [(N, serial((2026, 9, 20))), (S, "בית קפה"), (N, 18), (N, serial((2026, 10, 2))), (S, "רגילה")],
    [(N, serial((2026, 10, 12))), (S, "חניון העירייה"), (N, 12), (N, serial((2026, 11, 2))), (S, "רגילה")],
    [(N, serial((2026, 10, 12))), (S, "חניון העירייה"), (N, 12), (N, serial((2026, 11, 2))), (S, "רגילה")],
    [(N, serial((2026, 10, 3))), (S, "תחנת דלק"), (N, 250), (N, serial((2026, 11, 2))), (S, "רגילה")],
    [(N, serial((2026, 10, 5))), (S, "חנות בגדים בע\"מ"), (N, -79.9), (N, serial((2026, 11, 2))), (S, "השבת מכירה")],
    [(N, serial((2026, 10, 30))), (S, "סופר גדול"), (N, 88.1), (S, ""), (S, "רגילה"), (S, ""), (S, ""), (S, ""),
     (S, "עסקה בקליטה")],
    # Installments in 2: one row per payment charged so far (October and November).
    [(N, serial((2026, 9, 10))), (S, "חנות נעליים"), (N, 150), (S, ""), (S, "תשלומים"), (S, ""), (S, ""), (S, ""),
     (S, "עסקה ב-2 תשלומים")],
    [(N, serial((2026, 9, 10))), (S, "חנות נעליים"), (N, 150), (S, ""), (S, "תשלומים"), (S, ""), (S, ""), (S, ""),
     (S, "עסקה ב-2 תשלומים")],
    # Installments in 10: three payments so far.
    [(N, serial((2026, 8, 25))), (S, "חנות חשמל"), (N, 99.9), (S, ""), (S, "תשלומים"), (S, ""), (S, ""), (S, ""),
     (S, "עסקה ב-10 תשלומים")],
    [(N, serial((2026, 8, 25))), (S, "חנות חשמל"), (N, 99.9), (S, ""), (S, "תשלומים"), (S, ""), (S, ""), (S, ""),
     (S, "עסקה ב-10 תשלומים")],
    [(N, serial((2026, 8, 25))), (S, "חנות חשמל"), (N, 99.9), (S, ""), (S, "תשלומים"), (S, ""), (S, ""), (S, ""),
     (S, "עסקה ב-10 תשלומים")],
    [(S, ""), (S, "סה\"כ לחיוב"), (N, 932.3)],
    [(S, "* העסקאות בקליטה עשויות להשתנות")],
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

NS = 'xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
sheet_rows = []
for r, row in enumerate(rows, start=1):
    cells = []
    for c, (kind, value) in enumerate(row):
        ref = f"{col(c)}{r}"
        if kind == N:
            cells.append(f'<x:c r="{ref}"><x:v>{value}</x:v></x:c>')
        elif value != "":
            cells.append(f'<x:c r="{ref}" t="s"><x:v>{s(value)}</x:v></x:c>')
    sheet_rows.append(f'<x:row r="{r}">{"".join(cells)}</x:row>')

files = {
    "[Content_Types].xml": '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>',
    "_rels/.rels": '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="/xl/workbook.xml"/></Relationships>',
    "xl/workbook.xml": f'<?xml version="1.0" encoding="UTF-8"?><x:workbook {NS} xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<x:sheets><x:sheet name="פירוט עסקאות" sheetId="1" r:id="R1"/></x:sheets></x:workbook>',
    "xl/_rels/workbook.xml.rels": '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="R1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="/xl/worksheets/sheet1.xml"/>'
        '<Relationship Id="R2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="/xl/sharedStrings.xml"/></Relationships>',
    "xl/worksheets/sheet1.xml": f'<?xml version="1.0" encoding="UTF-8"?><x:worksheet {NS}><x:sheetData>{"".join(sheet_rows)}</x:sheetData></x:worksheet>',
    "xl/sharedStrings.xml": f'<?xml version="1.0" encoding="UTF-8"?><x:sst {NS} count="{len(shared)}" uniqueCount="{len(shared)}">'
        + "".join(f'<x:si><x:t xml:space="preserve">{escape(t)}</x:t></x:si>' for t in shared) + "</x:sst>",
}

out = os.path.join(os.path.dirname(__file__), "..", "test", "fixtures", "cal_sample.xlsx")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for name, text in files.items():
        z.writestr(name, text)
print("wrote", os.path.normpath(out))
