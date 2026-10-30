# מחשבון שכר — rules for every session

## Language
Everything written for the user is in Hebrew, including messages to other sessions. Code and code comments stay in English.

## Version and changelog — on every update
Whenever a change the user or the subscribers will notice is done (a feature, a fix, a design change, an admin tool),
in the same commit:
1. Bump the version: `build` +1 always; `version` patch for fixes, minor for new features (x.y.z).
   - `version.json` (`version`, `build`, `date`, `notes`) — the Flutter builds and CI read it from here.
   - `Maskoret.xcodeproj/project.pbxproj`: every `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
2. Write the change in `CHANGELOG.md` under the new version (Hebrew, short, from the user's point of view), and the same
   lines in `version.json` → `notes` (they show in the updates screen and on the download site).
Several changes in one working session may share one version: if the current version in `version.json` was not
published yet (the site's latest.json has an older build) and was bumped in this session, add to
it instead of bumping again. Never leave a commit with a user-visible change without its changelog line.
`tools/publish_release.sh` refuses to publish a version that is missing from `CHANGELOG.md`.

## Publishing (automatic, in the cloud)
`.github/workflows/release.yml` publishes by itself when a push to main leaves `version.json` with `"ready": true` and a
build newer than the site's: Windows setup + ZIP and APK (flutter-app.yml), the Mac app built on a GitHub Mac runner and
signed with "Maskoret Signing", a GitHub release in this repo, and latest.json + changelog.json (the "מה חדש" screen) on
the download site. Secrets are set once with `tools/setup_cloud_release.sh`. `tools/publish_release.sh` is a manual
fallback from the Mac.
- While a version is being worked on, keep `"ready": false`. Set it to `true` (in its own commit, after the work is
  finished and checked on the platforms it touches) only with the user's approval — that commit is the release.
- Right after a release, the next change starts the next version (bump, `"ready": false`).

## Open source
The repo is public (shlomoappdev-netizen/maskoret, GPL-3.0); contributions come as pull requests (main is protected
for outside contributors). Never commit secrets, personal emails or user data; see CONTRIBUTING.md.
