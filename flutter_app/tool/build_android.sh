#!/bin/zsh
# Builds the Android app and puts it in the distribution folder: להפצה/Android/מחשבון שכר.apk
set -e
here=${0:A:h}
app=$here/..
out=$app/../להפצה/Android
cd $app
flutter build apk --release
mkdir -p $out
cp -f build/app/outputs/flutter-apk/app-release.apk "$out/מחשבון שכר.apk"
echo "מוכן: $out/מחשבון שכר.apk"
