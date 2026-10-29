"""Writes test/fixtures/max_sample.xlsx: an artificial statement in Max's export format (no personal data).
Three sheets like the real export, a billing label above the header, installments, identical purchases on
the same day, shared and inline strings, and a date written as an Excel serial number."""
import os, zipfile
from xml.sax.saxutils import escape

header = ["תאריך עסקה", "שם בית העסק", "קטגוריה", "4 ספרות אחרונות של כרטיס האשראי", "סוג עסקה",
          "סכום חיוב", "מטבע חיוב", "סכום עסקה מקורי", "מטבע עסקה מקורי", "תאריך חיוב", "הערות",
          "תיוגים", "מועדון הנחות", "מפתח דיסקונט", "אופן ביצוע ההעסקה", "שער המרה ממטבע מקור/התחשבנות לש\"ח"]

charged = [
    ["05-10-2026", "המכולת בשכונה", "מזון וצריכה", "1234", "רגילה", "45.90", "₪", "45.90", "₪", "02-11-2026", "", "", "", "", "טלפוני", ""],
    ["05-10-2026", "המכולת בשכונה", "מזון וצריכה", "1234", "רגילה", "45.90", "₪", "45.90", "₪", "02-11-2026", "", "", "", "", "טלפוני", ""],
    ["07/10/2026", "חנות   הנעליים", "אופנה", "1234", "תשלומים", "150", "₪", "450", "₪", "02/11/2026", "תשלום 2 מתוך 3", "", "", "", "", ""],
    ["46300", "חברת החשמל", "חשמל וגז", "5678", "הוראת קבע", "1,234.56", "₪", "1,234.56", "₪", "02-11-2026", "", "", "", "", "", ""],
    ["12-10-2026", "החזר מחנות", "שונות", "1234", "זיכוי", "-30", "₪", "-30", "₪", "02-11-2026", "", "", "", "", "", ""],
    ["15-10-2026", "בית קפה", "", "1234", "רגילה", "18", "₪", "18", "₪", "02-11-2026", "", "", "", "", "", ""],
]
foreign = [
    ["20-10-2026", "STREAMING SERVICE", "פנאי", "5678", "רגילה", "39.20", "₪", "10.99", "USD", "02-11-2026", "", "", "", "", "", "3.567"],
]
pending = [
    ["27-10-2026", "המכולת בשכונה", "מזון וצריכה", "1234", "רגילה", "", "₪", "88.10", "₪", "", "", "", "", "", "", ""],
    ["28-10-2026", "תחנת דלק", "רכב ותחבורה", "5678", "רגילה", "", "₪", "250", "₪", "", "", "", "", "", "", ""],
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

def sheet(rows_before, rows):
    xml = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
           '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>']
    r = 0
    for row in rows_before + [header] + rows:
        r += 1
        cells = []
        for c, v in enumerate(row):
            if v == "":
                continue
            ref = f"{col(c)}{r}"
            if v.replace(".", "", 1).isdigit() and c == 0:
                cells.append(f'<c r="{ref}"><v>{v}</v></c>')          # Excel serial date
            elif c == 1 and r % 2 == 0:
                cells.append(f'<c r="{ref}" t="inlineStr"><is><t>{escape(v)}</t></is></c>')
            else:
                cells.append(f'<c r="{ref}" t="s"><v>{s(v)}</v></c>')
        xml.append(f'<row r="{r}">' + "".join(cells) + "</row>")
    xml.append("</sheetData></worksheet>")
    return "".join(xml)

top = [["פירוט עסקאות"], ["כל הכרטיסים"], ["10/2026"], []]
sheets = [("עסקאות במועד החיוב", sheet(top, charged)),
          ('עסקאות חו"ל ומט"ח', sheet(top, foreign)),
          ("עסקאות שטרם נקלטו", sheet(top, pending))]

out = os.path.join(os.path.dirname(__file__), "..", "test", "fixtures", "max_sample.xlsx")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("[Content_Types].xml", '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
    z.writestr("xl/workbook.xml", '<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
               + "".join(f'<sheet name="{escape(n, {chr(34): "&quot;"})}" sheetId="{i+1}" r:id="rId{i+1}"/>' for i, (n, _) in enumerate(sheets)) + "</sheets></workbook>")
    z.writestr("xl/_rels/workbook.xml.rels", '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
               + "".join(f'<Relationship Id="rId{i+1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{i+1}.xml"/>' for i in range(len(sheets))) + "</Relationships>")
    for i, (_, x) in enumerate(sheets):
        z.writestr(f"xl/worksheets/sheet{i+1}.xml", x)
    z.writestr("xl/sharedStrings.xml", '<?xml version="1.0" encoding="UTF-8"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
               + "".join(f"<si><t>{escape(t)}</t></si>" for t in shared) + "</sst>")
print("wrote", os.path.abspath(out))
