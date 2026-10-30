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
published yet (no `v<version>` release in shlomoappdev-netizen/maskoret-releases) and was bumped in this session, add to
it instead of bumping again. Never leave a commit with a user-visible change without its changelog line.
`tools/publish_release.sh` refuses to publish a version that is missing from `CHANGELOG.md`.

## Publishing
Publishing a release (`tools/publish_release.sh`) only with the user's explicit approval.
