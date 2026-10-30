#!/bin/zsh
# One-time setup of the cloud release (.github/workflows/release.yml): stores in GitHub, as encrypted secrets of
# shlomoappdev-netizen/maskoret:
#   1. the permanent Android signing key   (flutter_app/android/maskoret-release.jks + key.properties)
#   2. the "Maskoret Signing" certificate  (exported from Keychain Access as a .p12 — the script asks for it)
#   3. a new SSH key that may push only to the download site (shlomoappdev-netizen/maskoret-releases)
# Run it yourself in Terminal; nothing is printed or saved besides the secrets in GitHub.
set -e
ROOT=${0:A:h:h}
REPO=shlomoappdev-netizen/maskoret
SITE=shlomoappdev-netizen/maskoret-releases
export GH_TOKEN=$(gh auth token -u shlomoappdev-netizen)

echo "== 1/3 מפתח החתימה של אנדרואיד"
android=$ROOT/flutter_app/android
base64 -i $android/maskoret-release.jks | gh secret set ANDROID_KEYSTORE_BASE64 -R $REPO
grep '^storePassword=' $android/key.properties | cut -d= -f2- | tr -d '\n' | gh secret set ANDROID_KEYSTORE_PASSWORD -R $REPO

echo
echo "== 2/3 תעודת החתימה של המק (Maskoret Signing)"
echo "   ב״גישה למחזיק מפתחות״ (Keychain Access): המחזיק ״login״ ← ״התעודות שלי״ ← לחיצה ימנית על ״Maskoret Signing״"
echo "   ← ״ייצא…״ ← שמירה בשולחן העבודה בשם maskoret-signing.p12, עם סיסמה חדשה לקובץ."
open -a "Keychain Access"
P12=~/Desktop/maskoret-signing.p12
until [ -f $P12 ]; do read "?   לחץ Enter אחרי שהקובץ נשמר בשולחן העבודה… "; done
read -s "P12PW?   הסיסמה שבחרת לקובץ: "; echo
base64 -i $P12 | gh secret set MAC_CERT_P12 -R $REPO
print -rn -- "$P12PW" | gh secret set MAC_CERT_PASSWORD -R $REPO
rm -P $P12 2>/dev/null || rm $P12
unset P12PW
echo "   הקובץ נמחק משולחן העבודה."

echo
echo "== 3/3 מפתח לעדכון אתר ההורדות"
tmp=$(mktemp -d)
ssh-keygen -q -t ed25519 -N "" -C "maskoret release" -f $tmp/key
gh repo deploy-key add $tmp/key.pub -R $SITE --allow-write --title "release from $REPO"
gh secret set SITE_DEPLOY_KEY -R $REPO < $tmp/key
rm -rf $tmp

echo
gh secret list -R $REPO
echo "הכול מוכן: מעכשיו כל גרסה שמסומנת ״ready״ מתפרסמת לבד מ-GitHub."
