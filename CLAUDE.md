# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Pullse is a macOS 14+ menu bar app (SwiftUI, Swift 6 language mode, Swift Package, no
.xcodeproj). It polls GitHub for activity on the user's open pull requests in one
organization and posts native notifications.

## Commands

```sh
make build     # scripts/build-app.sh → build/Pullse.app (release build, bundled, ad-hoc signed)
make run       # build and open build/Pullse.app
make install   # build, copy to ~/Applications, relaunch
make check     # build, then one live read-only fetch: prints what the last 24h would notify
make test      # swift test
make demo      # render docs/demo/*.gif (notifications, Settings tour, update) from sample data
make dist      # build + zip: build/Pullse-<version>.zip and .sha256 (scripts/package.sh)
make stats     # read-only download counts per release (manual vs in-app updates), plus repo traffic
scripts/next-version.sh     # the version the [Unreleased] notes would release as, or exit 1
scripts/test.sh --filter <testFunctionName>   # a single test (Swift Testing, not XCTest)
swift build    # debug build; enough to type-check the app target
```

There is no linter configured.

`.build/debug/Pullse` runs, but notifications and launch-at-login only work from the
bundled `.app`, so the app has to go through `make build`. `Pullse --check` (the `--check`
flag on the binary) runs one fetch, prints, and exits without notifying or touching saved
state. `Pullse --demo <dir>` (`Demo.swift`) renders the README's GIFs: each frame is the
real views, drawn by `Capture.swift` into off-screen windows with sample data and
temporary files (so no Screen Recording permission), inside a made-up desktop (menu bar,
notification banners, a pointer), and ImageIO writes the GIF. Re-run it after UI
changes; the sample data follows the placeholder-names rule below. The pointer and menu
positions are fixed coordinates in `Demo.swift`, so re-check the GIFs when the menu or
Settings layout changes.

## Toolchain quirks (Command Line Tools only, macOS 27 SDK)

- **Don't use `@State`.** In this SDK it is a macro whose plugin ships only with Xcode, so
  it fails to compile here. Views use `private let x = State(initialValue: …)` with
  `.wrappedValue` / `.projectedValue`. Other SwiftUI property-wrapper macros may break the
  same way; `@Observable` (Observation) works.
- `make demo` launches the app with `open`, because a
  process started straight from a terminal stays inactive and AppKit draws its controls
  inactive (grey switches, plain default buttons). Clicking into another app while it
  runs has the same effect, so check the images and re-run if they look grey.
- `swift test` sometimes fails with "plugin for module 'TestingMacros' not found" and
  passes on a re-run. `scripts/test.sh` (used by `make test` and CI) retries only that
  error, so run tests through it.

## Architecture

Two targets. `PullseCore` has no AppKit or SwiftUI and holds all the logic under test.
`Pullse` is the thin app on top of it.

**One poll** (`AppModel.fetchAndNotify`):
1. `SettingsModel.reloadIfChanged()` re-reads `~/.config/pullse/settings.json` when its
   modification date changes. It stops the poll if there's no org or the file won't parse.
2. `GitHubClient.snapshot` makes 1–2 GraphQL requests using the token from `gh auth
   token`. The client looks for `gh` in Homebrew paths first, because GUI apps don't get
   the shell's PATH. On a 401 it drops the cached token and retries once. Query text is in
   `Queries.swift`.
3. `EventDetector.detect(snapshot, state:, settings:, now:)` is pure (no I/O, no clock) and
   returns the new events plus the next `SeenState`.
4. `PersistedState.record` adds the events to history. `StateStore` saves it to
   `~/Library/Application Support/Pullse/state.json`, and `Notifier` posts the
   notifications. More than 5 events at once become one summary notification.
5. The same snapshot gives the open PRs (`OpenPullRequest`: draft, review decision,
   rollup state), kept in memory only with the org they came from. `AppModel.openPRs`
   shows none for another org and drops muted repos (`ActivityGroups.visible`). With
   `showOpenPullRequests` on, the menu's `ActivityGroups.build` adds the open PRs with no
   activity after the active groups.

**What counts as new** is the heart of the app (`EventDetector`). An item notifies only if
its id is not in the seen set **and** its timestamp is at or after `lastPollAt − 5 min`. The
time rule is what stops a first launch, a newly opened PR, or an event type being turned
back on from replaying old history. Items are marked seen even when filters drop them.
Seen entries older than 24h are pruned. Consequences to keep in mind when changing it:
- Inline review comments are read through `reviews { comments }`, not `reviewThreads`,
  because every reply is its own review and reviews come back newest first. They are dated
  by `publishedAt ?? createdAt`: a draft's `createdAt` is when it was written.
- An empty-bodied `COMMENTED` review is skipped, because its inline comments are reported
  one by one.
- CI checks are keyed `id:outcome:finishedAt`, because a legacy StatusContext keeps its id
  across fail → pass → fail. Every check that finishes on one PR in one poll becomes one
  event.
- Mentions come from a separate search of other people's PRs, and the body must contain
  `@login` as a whole word. Their seen ids have a `mention:` prefix.
- The user's own items never notify. Bots (`__typename == "Bot"` or a login ending in
  `[bot]`) are filtered unless `includeBots` is on.

**Settings.** `~/.config/pullse/settings.json` (`PULLSE_SETTINGS` overrides the path) is
the only settings store. There are no `UserDefaults` or `@AppStorage`. `PullseSettings` decodes
leniently: every key is optional. A file that doesn't parse is never overwritten, and saves
are blocked until it is fixed. `bundleIdentifier` in the same file is read only by
`scripts/build-app.sh`, which stamps it into the bundle's `Info.plist`. `BUNDLE_ID` in the
environment overrides it, and with neither the build uses `com.example.pullse`. A local
build with that placeholder can't install releases (the bundle id check refuses them), so
the script stamps `PullsePlaceholderBundleID` and the updater shows Download instead of
Install (`UpdateChecker.canInstallReleases`).

**Poll loop.** `AppModel.restartLoop()` cancels and restarts the timer; it is called when
the interval or org changes. A `poll()` requested while one is running sets `pollAgain`
instead of being dropped. The fetch runs in an unstructured `Task`, so cancelling the loop
doesn't abort a request half way.

**Keyboard.** `GlobalShortcut` registers `openMenuShortcut` with Carbon's
`RegisterEventHotKey`, which needs no Accessibility permission. `MenuBarExtra` has no API
to open its window, so `MenuToggle` clicks Pullse's status bar button (`performClick`).
Inside the menu, `MenuKeys` reads keys with a local event monitor limited to the menu
window, because SwiftUI focus has nothing focused there; the selection order is
`ActivityGroups.rowIDs`/`next`.

**Versions and updates.** `VERSION` is the only place the version lives.
`scripts/build-app.sh` stamps it into the bundle, along with a build number and
`PullseUpdateRepository` (owner/name from `$GITHUB_REPOSITORY` or the `origin` remote). Outside
GitHub Actions it also stamps `PullseLocalBuild` (short commit, `-modified` if the tree is
dirty), which shows as "local" next to the version in the menu and Settings; the demos hide
it. The committed `Info.plist` holds placeholders. `Updater` (app target) uses the pure
`UpdateChecker` (`Updates.swift`) to pick the newest non-draft release above the running
version that has both `Pullse-<v>.zip` and `.zip.sha256`. Those names come from
`scripts/package.sh`, so keep the two in sync. Install: download through the REST API with
the `gh` token (the `Authorization` header is stripped on the redirect to storage), check
the SHA-256, `ditto -x`, check bundle id, version and `codesign --verify`, then a detached
`/bin/sh` swaps the bundle after the app quits and reopens it. Installs happen only from
`/Applications` or `~/Applications`; elsewhere the button opens the release page.
`PersistedState.lastRunVersion` drives the one-time "updated to x.y.z" notification.
A browser download opened in place runs translocated (from a read-only
`…/AppTranslocation/` mount) and can't replace itself: at launch `AppMover` offers to copy
it into an Applications folder, clear `com.apple.quarantine`, trash the download (found
with `SecTranslocateCreateOriginalPathForURL`, looked up at run time) and relaunch. The
path rules are `AppLocation` in PullseCore, and a build in the repo is never offered the
move.

**CI and releases.** `.github/workflows/ci.yml` tests and builds pull requests.
`release.yml` runs on every push to `main`. If `[Unreleased]` has notes, it runs
`scripts/release.sh`, which picks the bump from the changelog headings via
`next-version.sh`, moves the notes, writes `VERSION`, rewrites the README's static
shields.io version badge (static, so it needs no lookup of the releases), and
makes the "Release x.y.z" commit and tag. The README's other badges and links are
relative (`../../actions/…`, `../../releases/…`) so they carry no owner or repo name,
except the downloads badge: shields.io needs `owner/repo` in its URL, and it is the one
deliberate place the repository is named. It then builds, and only after that pushes the commit and tag back to `main`
(atomically) and publishes the release. With no notes it only uploads the build as an
artifact. The release commit's push (deploy key, see below) starts the workflow again, but
that run finds no notes and only builds, so there is no loop. A
tag push triggers nothing, so a version cut and tagged locally would never be published.
Both workflows run on `macos-26`, and actions are pinned by commit SHA. The repository
allows only GitHub-owned actions and requires SHA pinning, so a new action must be
GitHub's own and pinned. Dependabot (`.github/dependabot.yml`) opens a weekly PR
when a pinned action has a new release; it needs no changelog line, since nothing
user-visible changes. Secret scanning with push protection is on. Releases are immutable once published: assets and tag can't be
changed, so a bad release is fixed by releasing a new version. The bundle id comes from the
`BUNDLE_ID` repository variable. The repo is public.

**main is protected** by the "Protect main" ruleset: a pull request with the `build` check
passing and one approval, no direct or force pushes, no deletion. The repository admin
may bypass it only through a pull request, so a solo maintainer merges their own PR with
"Merge without waiting for requirements" (GitHub never lets an author approve their own
PR). The only other bypass is deploy keys: the release job pushes its "Release x.y.z"
commit and tag over SSH with `RELEASE_DEPLOY_KEY`, a secret of the `release` environment,
which only `main` can deploy to. So work on a branch and open a PR; never push to main.

## Tests

Tests live in `Tests/PullseTests`. They build GraphQL JSON with the helpers in
`Fixtures.swift` (`pr`, `comment`, `review`, `checkRun`, `snapshot`, `detect`) and decode it
through the real `GitHubClient.decode`, so they cover the response models as well as the
rules. The fixture clock is fixed: `lastPoll = t0`, `now = t0 + 60s`, and
`polled = SeenState(lastPollAt: lastPoll)`. The tests never touch the network.

## Repository rules

- **Nothing user- or org-specific goes in the repo.** That covers org names, usernames,
  teammates' logins, real repo names and bundle ids. Use placeholders such as `acme`,
  `your-org`, `alice` and `janedoe` in tests, comments, UI prompts and docs; real values
  belong in the settings file.
- Licensed under Apache 2.0 (`LICENSE`, `NOTICE`), copyright "Pullse contributors".
- **Only GitHub links are opened.** Everything handed to `NSWorkspace.open` from GitHub
  data goes through `GitHubLink` (https on github.com only). CI links (`detailsUrl`,
  `targetUrl`) are set by third parties, and `NSWorkspace` follows any URL scheme.
- **The release job's credentials only reach steps that run no repository code.**
  Checkout doesn't persist credentials; the "main moved on" check and Publish get
  `GH_TOKEN`, and only Publish gets the deploy key, each in their own `env`. Keep it that
  way when adding steps.
- **Pullse must stay read-only toward GitHub.** GraphQL queries and REST GETs only, never
  mutations or other methods. `everyQueryIsReadOnly` in `ModelAndStoreTests.swift`
  enforces the GraphQL half.
- **Every user-visible change adds a line under `## [Unreleased]` in `CHANGELOG.md`**, under
  the Keep a Changelog heading that matches it. That line is what releases it: the heading
  sets the bump (`### Fixed` patch, `### Added`/`Changed` minor, `### Breaking` major).
  Never edit `VERSION` by hand; the release workflow does.
