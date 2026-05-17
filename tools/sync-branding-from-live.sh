#!/usr/bin/env bash
#
# Sync the live merged all.css back into the repo, commit, and push.
#
# Run this on the VPS *after* you have manually performed the 3-way merge in
#   /var/www/jitsi/jitsi-meet-web/css/all.css
# It copies the live file into the repo at conf/branding/all.css, commits, and
# pushes. No prompts. No further intervention.
#
# This closes the upgrade loop so the next YNH upgrade starts the 3-way diff
# from the correct baseline.
#
# Idempotent: re-running with no changes prints "nothing to commit" and exits 0.
# Safe re: other uncommitted work: only conf/branding/all.css is staged.

set -euo pipefail

LIVE_CSS="/var/www/jitsi/jitsi-meet-web/css/all.css"

# Resolve repo root from the script's own location, ignoring $PWD.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_ROOT/conf/branding/all.css"

if [[ ! -f "$LIVE_CSS" ]]; then
    echo "ERROR: live file not found at $LIVE_CSS" >&2
    echo "       Is Jitsi installed on this host? Are you on the right machine?" >&2
    exit 1
fi

if [[ ! -d "$REPO_ROOT/.git" ]]; then
    echo "ERROR: $REPO_ROOT is not a git repository" >&2
    exit 1
fi

cd "$REPO_ROOT"

cp -- "$LIVE_CSS" "$TARGET"
chmod 0644 "$TARGET"

git add -- conf/branding/all.css

if git diff --cached --quiet -- conf/branding/all.css; then
    echo "No changes — conf/branding/all.css already matches live. Nothing to commit."
    exit 0
fi

LIVE_MD5="$(md5sum "$LIVE_CSS" | awk '{print $1}')"
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")"
STAMP="$(date -u +'%Y-%m-%d %H:%M UTC')"

git commit -m "Sync conf/branding/all.css from live merged baseline

Snapshot taken: $STAMP
Source: $LIVE_CSS
Live file md5:  $LIVE_MD5
Branch:         $BRANCH"

echo
echo "Pushing to origin/$BRANCH ..."
if git push origin "$BRANCH"; then
    echo "Done. Repo's branding baseline is now in sync with the live file."
else
    echo "WARN: commit landed locally but push failed. Retry: git push origin $BRANCH" >&2
    exit 2
fi
