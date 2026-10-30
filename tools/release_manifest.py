#!/usr/bin/env python3
"""Writes what a release publishes, from version.json, CHANGELOG.md and the built files (used by release.yml).

  release_manifest.py <out-dir> <repo> <tag>

<out-dir> holds maskoret-android.apk, maskoret-windows.zip, maskoret-windows-setup.exe and maskoret-mac.dmg. Writes there:
  latest.json     what the apps read to offer an update (url, sha256 and size per platform)
  changelog.json  every version, newest first, for the "מה חדש" screen after an update
  notes.md        the release notes on GitHub
"""
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out, repo, tag = sys.argv[1:4]
version = json.load(open(os.path.join(ROOT, "version.json"), encoding="utf-8"))
base = f"https://github.com/{repo}/releases/download/{tag}/"


def asset(name):
    path = os.path.join(out, name)
    data = open(path, "rb").read()
    return {"url": base + name, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}


latest = {
    "version": version["version"], "build": version["build"], "date": version.get("date"),
    "notes": version.get("notes", []),
    "platforms": {
        "android": asset("maskoret-android.apk"),
        # The ZIP only updates copies of 4.1.x (they unpack it); everything newer installs with the setup.
        "windows": asset("maskoret-windows.zip"),
        "windows_setup": asset("maskoret-windows-setup.exe"),
        "mac": asset("maskoret-mac.dmg"),
    },
}
json.dump(latest, open(os.path.join(out, "latest.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)

entries, current = [], None
for line in open(os.path.join(ROOT, "CHANGELOG.md"), encoding="utf-8"):
    m = re.match(r"^## (\d+\.\d+\.\d+) \(build (\d+)\)(?: — (\S+))?", line)
    if m:
        current = {"version": m[1], "build": int(m[2]), "date": m[3], "notes": []}
        entries.append(current)
    elif current and line.startswith("- "):
        current["notes"].append(line[2:].strip())
    elif line.startswith("## "):
        current = None  # work in progress, not released
if not any(e["build"] == version["build"] for e in entries):
    sys.exit(f"CHANGELOG.md has no section for {version['version']} (build {version['build']})")
json.dump(entries, open(os.path.join(out, "changelog.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)

notes = f"## מחשבון שכר {version['version']}\n\n" + "\n".join("- " + n for n in version.get("notes", []))
notes += ("\n\n**התקנה:** Windows — maskoret-windows-setup.exe · אנדרואיד — maskoret-android.apk · "
          "Mac — maskoret-mac.dmg\n\nאו מהאתר: https://maskoret.vercel.app\n")
open(os.path.join(out, "notes.md"), "w", encoding="utf-8").write(notes)
print(f"{version['version']} ({version['build']}): latest.json, changelog.json ({len(entries)} versions), notes.md")
