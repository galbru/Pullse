#!/bin/sh
# Download counts for every release, from GitHub's own counters: scripts/stats.sh [owner/name]
# (or: make stats). Read-only: every call is a GET.
#
# GitHub counts each download of a release asset, browser or not. Only the in-app updater
# fetches the .sha256, so per release "updates" is the .sha256 count and "manual" is what
# the .zip has on top of that. Installs themselves aren't tracked: Pullse sends nothing.
set -eu
cd "$(dirname "$0")/.."

REPO="${1:-$(git remote get-url origin 2>/dev/null \
    | sed -nE 's#^(https://github\.com/|git@github\.com:)([^/]+/[^/]+)$#\2#p' \
    | sed 's/\.git$//' || true)}"
[ -n "$REPO" ] || { echo "usage: scripts/stats.sh owner/name (no GitHub origin remote)" >&2; exit 1; }

# Fetched first so a failure (unknown repo, not logged in) stops here: sh has no pipefail.
RELEASES="$(gh api --paginate "repos/$REPO/releases?per_page=100")"

echo "Downloads of $REPO releases (manual = .zip minus .sha256, updates = .sha256):"
echo
# --paginate prints one array per page; jq -s joins them before counting.
printf '%s\n' "$RELEASES" | jq -rs '
    def count($r; $suffix): [$r.assets[] | select(.name | endswith($suffix)) | .download_count] | add // 0;
    [ add[] | select(.draft | not)
      | { v: .tag_name, date: (.published_at // "" | .[0:10]),
          zip: count(.; ".zip"), sha: count(.; ".sha256") }
      | .manual = ([.zip - .sha, 0] | max) ] as $rows
    | (["VERSION", "DATE", "ZIP", "SHA256", "MANUAL", "UPDATES"] | @tsv),
      ($rows[] | [.v, .date, .zip, .sha, .manual, .sha] | @tsv),
      (["total", "-", ($rows | map(.zip) | add // 0), ($rows | map(.sha) | add // 0),
        ($rows | map(.manual) | add // 0), ($rows | map(.sha) | add // 0)] | @tsv)
' | column -t -s "$(printf '\t')"

echo
# Traffic needs push access to the repository; without it, say so and carry on.
if views="$(gh api "repos/$REPO/traffic/views" --jq '"\(.count) views (\(.uniques) unique)"' 2>/dev/null)" &&
   clones="$(gh api "repos/$REPO/traffic/clones" --jq '"\(.count) clones (\(.uniques) unique)"' 2>/dev/null)"; then
    echo "Last 14 days: $views, $clones."
else
    echo "Repository traffic isn't shown: it needs push access to $REPO."
fi
