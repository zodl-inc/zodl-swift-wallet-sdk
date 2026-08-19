#!/usr/bin/env bash
#
# start-release.sh: open a release for review.
#
# This is the FIRST step of a release, before Scripts/prepare-release.sh and
# Scripts/release.sh. It creates the two branches described in CONTRIBUTING.md
# and makes the CHANGELOG commit:
#
#   release/X.Y.Z   cut from the PREVIOUS release tag. It is the base of the
#                   release PR and what eventually gets tagged.
#   review/X.Y.Z    cut from the revision being released. It carries the
#                   release preparation commits.
#
# The PR from review/X.Y.Z into release/X.Y.Z then shows exactly what this
# release adds over the previous one, with none of the intervening history.
#
# It does not touch Package.swift. The binary target's URL and checksum cannot
# be known until the xcframework has been built and uploaded, so those are
# written by Scripts/release.sh, which runs after this PR has merged.
#
# Usage:
#   ./Scripts/start-release.sh [options] <remote> <version> [<revision>]
#
#   <remote>    git remote for the release repository, e.g. upstream
#   <version>   version being released, e.g. 2.7.1
#   <revision>  commit or branch holding the changes to release
#               (default: current HEAD, which should be a maint/ branch)
#
# Options:
#   --previous <tag>  base the release branch on this tag rather than the
#                     detected one. Use when the newest tag reachable from
#                     <revision> is not the release you are following.
#   --push-review     also push review/X.Y.Z, so the PR can be opened at once.
#   --dry-run         print what would happen and change nothing.
#
# It deliberately does not tag, publish, or open the PR: those are the steps
# worth a human looking at the diff first.

set -euo pipefail

# Tags and release branches carry no `v` prefix in this repository (2.7.0-rc.1,
# release/3.0.0), unlike the sibling Android SDK. Maintenance branches do.
readonly TAG_PREFIX=""

# The repository the release PR is opened against: the one the workflow runs in
# (GITHUB_REPOSITORY in Actions), so forks release onto themselves.
readonly REPO="${GITHUB_REPOSITORY:-zodl-inc/zcash-swift-wallet-sdk}"

usage() { sed -n '2,38p' "$0" | sed 's|^# \{0,1\}||'; exit "${1:-1}"; }

PREVIOUS=""
PUSH_REVIEW=false
DRY_RUN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --previous)     PREVIOUS="${2:?--previous needs a tag}"; shift 2 ;;
        --push-review)  PUSH_REVIEW=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        -h|--help)      usage 0 ;;
        --*)            echo "error: unknown option '$1'" >&2; usage ;;
        *)              break ;;
    esac
done

[ $# -ge 2 ] || usage
readonly REMOTE="$1"
readonly VERSION="${2#v}"
readonly REVISION="${3:-HEAD}"

cd "$(git rev-parse --show-toplevel)"

run() {
    if $DRY_RUN; then echo "  would run: $*"; else "$@"; fi
}

step() { echo; echo "==> $*"; }

# Semver ordering. GNU `sort -V` ranks 2.7.0-rc.1 *above* 2.7.0, which is
# backwards: a pre-release precedes its release. Mapping '-' to '~' fixes it,
# because sort -V treats '~' as lower than the empty string.
version_sort() { sed 's/-/~/' | sort -V | sed 's/~/-/'; }

version_le() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | version_sort | head -1)" = "$1" ]
}

# ---------------------------------------------------------------- preflight

step "Checking preconditions"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "error: working tree has uncommitted changes." >&2
    exit 1
fi

git remote get-url "$REMOTE" >/dev/null 2>&1 || {
    echo "error: no such remote '$REMOTE'." >&2; exit 1; }

echo "  fetching $REMOTE ..."
git fetch --tags "$REMOTE" >/dev/null 2>&1

REV_SHA="$(git rev-parse --verify "${REVISION}^{commit}")"
echo "  releasing the content of $REVISION ($(git rev-parse --short "$REV_SHA"))"

readonly NEW_TAG="${TAG_PREFIX}${VERSION}"
if git rev-parse -q --verify "refs/tags/${NEW_TAG}" >/dev/null; then
    echo "error: ${NEW_TAG} is already tagged; pick a new version." >&2
    exit 1
fi

# ------------------------------------------------------- previous release

step "Determining the release base"

if [ -n "$PREVIOUS" ]; then
    PREV_TAG="${PREVIOUS}"
    git rev-parse -q --verify "refs/tags/${PREV_TAG}" >/dev/null || {
        echo "error: no such tag '${PREV_TAG}'." >&2; exit 1; }
    echo "  using --previous ${PREV_TAG}"
else
    # Only tags reachable from the revision are candidates: a tag on a newer
    # line is not something this release can be a successor to. The glob keeps
    # non-version tags (e.g. rustwelding-*) out of the running.
    PREV_TAG="$(git tag --list --merged "$REV_SHA" '[0-9]*' | version_sort | tail -1)"
    [ -n "$PREV_TAG" ] || {
        echo "error: no release tags are reachable from ${REVISION}." >&2
        echo "       pass --previous <tag> to say which release this follows." >&2
        exit 1; }
    echo "  newest release reachable from ${REVISION}: ${PREV_TAG}"
fi

PREV_VERSION="${PREV_TAG#"$TAG_PREFIX"}"
if version_le "$VERSION" "$PREV_VERSION"; then
    echo "error: ${VERSION} does not come after ${PREV_VERSION}." >&2
    exit 1
fi

readonly RELEASE_BRANCH="release/${VERSION}"
readonly REVIEW_BRANCH="review/${VERSION}"

for b in "$RELEASE_BRANCH" "$REVIEW_BRANCH"; do
    git rev-parse -q --verify "refs/heads/${b}" >/dev/null && {
        echo "error: branch ${b} already exists locally." >&2; exit 1; }
done

echo
echo "  ${RELEASE_BRANCH}  <- ${PREV_TAG}        (PR base, pushed to ${REMOTE})"
echo "  ${REVIEW_BRANCH}   <- ${REVISION}   (release prep goes here)"

# --------------------------------------------------------------- branches

step "Creating ${RELEASE_BRANCH} from ${PREV_TAG}"
run git branch "$RELEASE_BRANCH" "refs/tags/${PREV_TAG}"
run git push "$REMOTE" "${RELEASE_BRANCH}:${RELEASE_BRANCH}"

step "Creating ${REVIEW_BRANCH} from ${REVISION}"
run git switch -c "$REVIEW_BRANCH" "$REV_SHA"

# ------------------------------------------------------------- CHANGELOG

step "Promoting the CHANGELOG"

# Entries are written as part of the commit that makes each change, so this
# only ever promotes what is already there -- it never generates text. An
# empty Unreleased section means the entries were not written, which is much
# more likely to be an oversight than a genuinely invisible release.
if ! awk '/^# Unreleased/{f=1;next} f && /^# /{exit} f && NF{found=1} END{exit !found}' CHANGELOG.md; then
    echo "error: the Unreleased section is empty." >&2
    echo "       Every user-visible change needs an entry before release." >&2
    exit 1
fi

if $DRY_RUN; then
    echo "  would insert '# ${VERSION} - $(date +%Y-%m-%d)' below '# Unreleased'"
else
    awk -v ver="$VERSION" -v date="$(date +%Y-%m-%d)" '
        !done && /^# Unreleased/ { print; print ""; print "# " ver " - " date; done=1; next }
        { print }
    ' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
    grep -q "^# ${VERSION} - " CHANGELOG.md \
        || { echo "error: CHANGELOG not promoted." >&2; exit 1; }
    echo "  # ${VERSION} - $(date +%Y-%m-%d)"
fi

# ----------------------------------------------------------------- commit

step "Committing"
run git add CHANGELOG.md
run git commit -m "Prepare SDK release ${VERSION}"

if $PUSH_REVIEW; then
    step "Pushing ${REVIEW_BRANCH}"
    run git push -u "$REMOTE" "$REVIEW_BRANCH"
fi

# ------------------------------------------------------------- next steps

cat <<EOF

Done. ${RELEASE_BRANCH} is on ${REMOTE}; ${REVIEW_BRANCH} is checked out here.

Next:
EOF
$PUSH_REVIEW || echo "  git push -u ${REMOTE} ${REVIEW_BRANCH}"
cat <<EOF
  gh pr create --repo ${REPO} \\
      --base ${RELEASE_BRANCH} --head ${REVIEW_BRANCH} \\
      --title "Release zcash-swift-wallet-sdk ${VERSION}"

Review the PR diff: it is exactly what users get over ${PREV_TAG}. Then merge
it and run

  ./Scripts/release.sh ${REMOTE} ${VERSION}

from ${RELEASE_BRANCH}, which builds the xcframework, writes the Package.swift
URL and checksum, tags ${NEW_TAG} and publishes. Afterwards merge the release
branch back into its maint/ branch and forward along the chain, as described in
CONTRIBUTING.md.
EOF
