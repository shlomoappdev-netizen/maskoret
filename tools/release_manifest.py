#!/usr/bin/env python3
"""Writes what a release publishes, from version.json, CHANGELOG.md and the built files (used by release.yml).

  release_manifest.py <out-dir> <repo> <tag> [previous latest.json]

<out-dir> holds the files that were built this time: maskoret-android.apk, maskoret-windows.zip +
maskoret-windows-setup.exe, maskoret-mac.dmg — any of them may be missing (each platform goes out as soon as its own
build is ready). A missing one keeps its entry from the previous latest.json. Every platform entry carries its own
version and build; the top-level version/build are the oldest of them, so a copy that only reads those is never offered
a file that isn't newer than itself. Writes there:
  latest.json     what the apps read to offer an update (url, sha256, size and signature per platform)
  changelog.json  every version, newest first, for the "מה חדש" screen after an update
  notes.md        the release notes on GitHub
"""
import hashlib
import json
import os
import re
import sys

from manifest_sig import sign

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out, repo, tag = sys.argv[1:4]
previous = {}
if len(sys.argv) > 4 and os.path.exists(sys.argv[4]):
    try:
        previous = json.load(open(sys.argv[4], encoding="utf-8"))
    except ValueError:
        previous = {}
version = json.load(open(os.path.join(ROOT, "version.json"), encoding="utf-8"))
base = f"https://github.com/{repo}/releases/download/{tag}/"


def asset(key, name):
    """This build's file (signed), or — when it wasn't built this time — the platform's previous entry, as it was:
    an entry is signed only when its file was built in this run, never because the site already listed it."""
    path = os.path.join(out, name)
    if not os.path.exists(path):
        old = dict(previous.get("platforms", {}).get(key) or {})
        if old:
            old.setdefault("version", previous.get("version"))
            old.setdefault("build", previous.get("build"))
        return old or None
    data = open(path, "rb").read()
    return sign(key, {"url": base + name, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data),
                      "version": version["version"], "build": version["build"]})


platforms = {
    "android": asset("android", "maskoret-android.apk"),
    # The ZIP only updates copies of 4.1.x (they unpack it); everything newer installs with the setup.
    "windows": asset("windows", "maskoret-windows.zip"),
    "windows_setup": asset("windows_setup", "maskoret-windows-setup.exe"),
    "mac": asset("mac", "maskoret-mac.dmg"),
}
platforms = {k: v for k, v in platforms.items() if v}
built = [k for k, v in platforms.items() if v.get("build") == version["build"]]
if not built:
    sys.exit("Nothing new was built — no platform has this version's file.")
oldest = min(platforms.values(), key=lambda v: v.get("build") or 0)
latest = {
    "version": oldest.get("version") or version["version"], "build": oldest.get("build") or version["build"],
    "date": version.get("date"), "notes": version.get("notes", []),
    "platforms": platforms,
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
names = {"windows_setup": "Windows — maskoret-windows-setup.exe", "android": "אנדרואיד — maskoret-android.apk",
         "mac": "Mac — maskoret-mac.dmg"}
notes += "\n\n**התקנה:** " + " · ".join(names[k] for k in names if k in built) + "\n\nאו מהאתר: https://maskoret.vercel.app\n"
open(os.path.join(out, "notes.md"), "w", encoding="utf-8").write(notes)
print(f"{version['version']} ({version['build']}): built {', '.join(built)}; latest.json, changelog.json "
      f"({len(entries)} versions), notes.md")
open(os.path.join(out, "built.txt"), "w").write(" ".join(built))
