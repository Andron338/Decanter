#!/bin/bash
# Local CD: runs CI, tags the release, pushes it and publishes a GitHub release with the zipped app.
#
#   Scripts/release.sh 0.2.0              release v0.2.0 from master
#   Scripts/release.sh 0.2.0 --dry-run    everything except tagging, pushing and publishing
#   Scripts/release.sh 0.2.0 --prerelease mark it as a pre-release (allowed from any branch)
#
# Needs the GitHub CLI, signed in once:  brew install gh && gh auth login
set -euo pipefail
cd "$(dirname "$0")/.."

die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }

VERSION="${1:-}"
shift || true
DRY_RUN=0 PRERELEASE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --prerelease) PRERELEASE=1 ;;
        *) die "Unknown option: $arg" ;;
    esac
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] \
    || die "Usage: Scripts/release.sh <version, e.g. 0.2.0> [--dry-run] [--prerelease]"
TAG="v$VERSION"

step "Preflight"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ -z "$(git status --porcelain)" ] || die "The working tree has uncommitted changes. Commit or stash them first."
if [ "$BRANCH" != "master" ] && [ $PRERELEASE -eq 0 ]; then
    die "Releases come from master (you're on $BRANCH). Merge first, or pass --prerelease."
fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "Tag $TAG already exists."
if [ $DRY_RUN -eq 0 ]; then
    command -v gh >/dev/null || die "The GitHub CLI isn't installed: brew install gh && gh auth login"
    gh auth status >/dev/null 2>&1 || die "The GitHub CLI isn't signed in: gh auth login"
    git fetch -q origin
    git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && die "Tag $TAG already exists on GitHub."
    if git rev-parse -q --verify "origin/$BRANCH" >/dev/null; then
        [ -z "$(git rev-list HEAD..origin/$BRANCH)" ] || die "origin/$BRANCH has commits you don't. Pull first."
    fi
fi
echo "Releasing $TAG from $BRANCH at $(git rev-parse --short HEAD)"

export VERSION
BUILD=$(git rev-list --count HEAD)
export BUILD
Scripts/ci.sh
ZIP="dist/Decanter-$VERSION.zip"

step "Release notes"
PREVIOUS=$(git describe --tags --abbrev=0 2>/dev/null || true)
NOTES="dist/notes-$VERSION.md"
{
    if [ -n "$PREVIOUS" ]; then
        echo "## Changes since $PREVIOUS"
        RANGE="$PREVIOUS..HEAD"
    else
        echo "## Changes"
        RANGE="HEAD"
    fi
    echo
    git log --no-merges --format='- %s' "$RANGE"
    echo
    echo "## Install"
    echo
    echo "Unzip and move **Decanter.app** to Applications. The app is ad-hoc signed, not notarized, so"
    echo "macOS will refuse to open it the first time. Clear the download quarantine once:"
    echo
    echo '```bash'
    echo 'xattr -dr com.apple.quarantine /Applications/Decanter.app'
    echo '```'
    echo
    echo "SHA-256: \`$(cut -d' ' -f1 "$ZIP.sha256")\`"
} > "$NOTES"
cat "$NOTES"

if [ $DRY_RUN -eq 1 ]; then
    printf '\n\033[33m• Dry run: not tagging, pushing or publishing. Package: %s\033[0m\n' "$ZIP"
    exit 0
fi

step "Tag and push"
git tag -a "$TAG" -m "Decanter $VERSION"
git push origin "$BRANCH"
git push origin "$TAG"

step "Publish GitHub release"
FLAGS=()
[ $PRERELEASE -eq 1 ] && FLAGS+=(--prerelease)
gh release create "$TAG" "$ZIP" "$ZIP.sha256" --title "Decanter $VERSION" --notes-file "$NOTES" --verify-tag ${FLAGS[@]+"${FLAGS[@]}"}

printf '\n\033[32m✓ Released %s: %s\033[0m\n' "$TAG" "$(gh release view "$TAG" --json url -q .url)"
