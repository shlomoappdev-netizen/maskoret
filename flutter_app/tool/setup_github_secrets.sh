#!/bin/zsh
# One-time setup for publishing updates: puts the three secrets the GitHub workflow needs into the repository.
#  - the permanent Android signing key and its password (from android/maskoret-release.jks + android/key.properties)
#  - the Supabase secret key (pasted when asked: Supabase → Project Settings → API Keys → secret / service_role)
set -e
here=${0:A:h}
repo=Shlomo116/maskoret
android=$here/../android
base64 -i $android/maskoret-release.jks | gh secret set ANDROID_KEYSTORE_BASE64 -R $repo
grep '^storePassword=' $android/key.properties | cut -d= -f2- | tr -d '\n' | gh secret set ANDROID_KEYSTORE_PASSWORD -R $repo
echo "הדבק את המפתח הסודי של Supabase (לא יוצג על המסך) ולחץ Enter:"
gh secret set SUPABASE_SERVICE_KEY -R $repo
gh secret list -R $repo
