#!/bin/zsh
# Optional one-time setup: gives the GitHub build the permanent Android signing key and its password
# (from android/maskoret-release.jks + android/key.properties), so APKs built there can update installed apps.
set -e
here=${0:A:h}
repo=Shlomo116/maskoret
# The code repo belongs to the Shlomo116 account (without switching the account gh uses elsewhere).
export GH_TOKEN=$(gh auth token -u Shlomo116)
android=$here/../android
base64 -i $android/maskoret-release.jks | gh secret set ANDROID_KEYSTORE_BASE64 -R $repo
grep '^storePassword=' $android/key.properties | cut -d= -f2- | tr -d '\n' | gh secret set ANDROID_KEYSTORE_PASSWORD -R $repo
gh secret list -R $repo
