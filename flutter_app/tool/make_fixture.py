"""Builds test/fixtures/swift_household.json from the Swift app's real files on this Mac.

The household document on the server is the Swift FamilyBackup: {state, files: {memberId: SaveFile}}.
Names, notes and amounts are anonymized (the structure, ids, dates and every key stay as Swift wrote them),
so the fixture is safe to keep in a repository.

Usage: python3 tool/make_fixture.py [path to the "Maskoret" Application Support folder]
"""
import json, os, re, sys

src = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Library/Application Support/Maskoret")
state = json.load(open(os.path.join(src, "family.json")))
files = {}
for m in state["members"]:
    p = os.path.join(src, "maskoret-data.json") if m["id"] == state["primaryID"] else os.path.join(src, "members", m["id"] + ".json")
    if os.path.exists(p):
        files[m["id"]] = json.load(open(p))

UUID = re.compile(r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$", re.I)
IDENT = re.compile(r"^[A-Za-z0-9_.\-]{1,40}$")
FREE_TEXT = {"note", "fileName", "title", "name", "merchant", "person", "billingLabel", "category", "cardLast4"}
MONEY = {"amount", "price", "actualNet", "manualAmount", "originalAmount", "hourlyRate", "openingBalance", "monthlyLimit", "manualNet"}
tokens = {}

def anon_text(s):
    if s == "" or UUID.match(s) or s.startswith("http"):
        return s
    if s not in tokens:
        tokens[s] = f"טקסט {len(tokens) + 1}"
    return tokens[s]

def walk(x, key=None):
    if isinstance(x, dict):
        out = {}
        for k, v in x.items():
            nk = k if (UUID.match(k) or IDENT.match(k)) else anon_text(k)
            out[nk] = walk(v, k)
        return out
    if isinstance(x, list):
        return [walk(v, key) for v in x]
    if isinstance(x, str):
        if key in FREE_TEXT or not IDENT.match(x):
            return anon_text(x)
        return x
    if isinstance(x, bool) or x is None:
        return x
    if key in MONEY or key is None and isinstance(x, float):
        v = round(x * 0.73, 2)
        return int(v) if isinstance(x, int) else v
    return x

doc = {"state": state, "files": files}
out = walk(doc)
dst = os.path.join(os.path.dirname(__file__), "..", "test", "fixtures", "swift_household.json")
json.dump(out, open(dst, "w"), ensure_ascii=False, separators=(",", ":"))
print("wrote", os.path.abspath(dst), len(json.dumps(out)), "bytes,", len(tokens), "texts anonymized")
