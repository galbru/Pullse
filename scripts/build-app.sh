#!/bin/sh
# Build "Pullse.app" from the Swift package. Notifications only work from a real
# bundle with a bundle id, so the bare SwiftPM binary is not enough.
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product Pullse
BIN="$(swift build -c release --show-bin-path)/Pullse"

APP="build/Pullse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pullse"
cp Support/Info.plist "$APP/Contents/Info.plist"

# The bundle id is personal (macOS keys notification permission and login items by it),
# so it isn't committed: $BUNDLE_ID, else "bundleIdentifier" in the settings file, else
# a placeholder.
SETTINGS="${PULLSE_SETTINGS:-$HOME/.config/pullse/settings.json}"
BUNDLE_ID="${BUNDLE_ID:-}"
if [ -z "$BUNDLE_ID" ] && [ -f "$SETTINGS" ]; then
    BUNDLE_ID="$(plutil -extract bundleIdentifier raw -o - "$SETTINGS" 2>/dev/null || true)"
fi
if [ -z "$BUNDLE_ID" ]; then
    BUNDLE_ID="com.example.pullse"
    echo "note: no bundleIdentifier in $SETTINGS, using $BUNDLE_ID" >&2
    # Releases carry a real id and the updater refuses one that differs, so a local build
    # with the placeholder offers Download instead of Install (UpdateChecker.canInstallReleases).
    PLACEHOLDER_ID=1
fi
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
if [ -n "${PLACEHOLDER_ID:-}" ]; then
    plutil -replace PullsePlaceholderBundleID -bool true "$APP/Contents/Info.plist"
fi

# Version from VERSION; build number from CI's run number, else the commit count.
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="${GITHUB_RUN_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 0)}"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"

# Where the app looks for updates: owner/name of the GitHub repo it was built from. Taken
# from CI or the origin remote rather than committed; without it, update checks are off.
REPO="${PULLSE_UPDATE_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
if [ -z "$REPO" ]; then
    REPO="$(git remote get-url origin 2>/dev/null \
        | sed -nE 's#^(https://github\.com/|git@github\.com:)([^/]+/[^/]+)$#\2#p' \
        | sed 's/\.git$//' || true)"
fi
if [ -n "$REPO" ]; then
    plutil -replace PullseUpdateRepository -string "$REPO" "$APP/Contents/Info.plist"
else
    echo "note: no GitHub origin remote, update checks disabled in this build" >&2
fi

# A build made outside GitHub Actions is marked with the commit it was built from (plus
# "-modified" with uncommitted changes), so the app can show it isn't a release.
if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
    LOCAL="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    if [ "$LOCAL" != unknown ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        LOCAL="$LOCAL-modified"
    fi
    plutil -replace PullseLocalBuild -string "$LOCAL" "$APP/Contents/Info.plist"
fi

# Ad-hoc signature: enough for notifications and launch-at-login on this Mac.
codesign --force --sign - --timestamp=none "$APP"

echo "Built $APP $VERSION ($BUILD) ($BUNDLE_ID)"
