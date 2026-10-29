#!/bin/zsh
# Builds the Android app and puts it in the distribution folder: להפצה/Android/מחשבון שכר.apk
# The version and build number come from version.json (one counter for all the apps), so the update check
# compares correctly. Signed with the permanent key in android/key.properties (needed for updates to install).
set -e
here=${0:A:h}
app=$here/..
root=$app/..
out=$root/להפצה/Android
version=$(python3 -c "import json;print(json.load(open('$root/version.json'))['version'])")
build=$(python3 -c "import json;print(json.load(open('$root/version.json'))['build'])")
[ -f $app/android/key.properties ] || { echo "חסר android/key.properties — בלי מפתח החתימה הקבוע העדכונים לא יותקנו"; exit 1; }
cd $app
flutter build apk --release --build-name "$version" --build-number "$build"
mkdir -p $out
cp -f build/app/outputs/flutter-apk/app-release.apk "$out/מחשבון שכר.apk"
echo "מוכן: גרסה $version (build $build) — $out/מחשבון שכר.apk"
