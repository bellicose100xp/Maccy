# Maccy (fork)

Fork of https://github.com/p0deje/Maccy, kept to fix issues in the clipboard
manager the user runs daily. Only macOS 26 (Tahoe) and later is supported.

## Build and install

- `./build` builds Debug into `.build/`.
- `./build test` runs the unit tests (MaccyTests) without ClipboardTests, which
  overwrite the real system clipboard while they run; `./build test all` includes
  them. The default test plan contains only MaccyTests, so `xcodebuild test` and
  Cmd+U never run the UI tests either. MaccyUITests takes
  over the mouse and keyboard while it runs and sits in the opt-in
  `MaccyUITests.xctestplan`; run it only when the user asks, and warn them first.
- `./install` builds Release, quits the running copy, replaces
  `~/Applications/Maccy.app`, relaunches it, and checks the signature. Always
  install through this script so only one Maccy runs; two copies fight over the
  clipboard and show two menu bar icons.

The project is signed with the user's Apple Development team `7A6VQZ5YWT`.
The test plan passes `enable-testing`, which keeps tests on an in-memory store
and a separate defaults suite instead of the real history database.

## Good to know

- The installed copy shares its history with any other Maccy on the machine
  (bundle id `org.p0deje.Maccy`, SQLite store in the app container). Do not
  keep a second Maccy in `/Applications`.
- Two `ClipboardTests` (ignore-application cases) fail from a terminal on
  unmodified upstream code too; they read the frontmost app.
- `HistoryItemTests.testSeveralItemsCanHaveEmptyPin` sometimes crashes the test
  host inside SwiftData ("Already have an objectID registered") when the whole
  suite runs; it passes alone. Rerun before blaming a change.

## Releases and updates

- Versions are derived from git by `./version`: `<latest upstream tag>.<fork
  commits since it>` (for example `2.7.1.14`), build number = commit count.
  Every `./build` stamps them, so About always names the running commit. The
  `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` values in the project file are
  fallbacks only; never bump them by hand.
- `./release "note" "note"` builds Release with the next version, zips and
  EdDSA-signs the app, prepends an `appcast.xml` entry, commits, tags, pushes,
  and publishes a GitHub release on the fork.
- Remote `upstream` is p0deje/Maccy. Fork-only work (Tahoe-only support,
  personal features) stays on master. Anything meant for an upstream PR is
  developed on a branch cut from `upstream/master` and merged into master, so
  the PR carries only that change.
- Installed copies update through Sparkle from
  `https://raw.githubusercontent.com/bellicose100xp/Maccy/master/appcast.xml`
  (`SUFeedURL` in `Maccy/Info.plist`); `SUPublicEDKey` there matches the Sparkle
  key in the user's login keychain, shared with other local apps.
