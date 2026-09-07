#!/usr/bin/env bash
# Resolve a git ref in a remote repository to a full commit SHA.
#
# Usage: ./scripts/resolve-ref.sh <repo-url> <ref>
#
# `git ls-remote <url> <ref>` is a *glob* match — asking for `main` also matches
# `refs/heads/lez-bump/main` — so this asks for exact refs, branches first, then
# tags (dereferencing annotated tags to the commit they point at). A ref that
# matches nothing is assumed to already be a SHA and echoed back.

set -euo pipefail

URL="${1:?usage: resolve-ref.sh <repo-url> <ref>}"
REF="${2:?usage: resolve-ref.sh <repo-url> <ref>}"

sha_for() { git ls-remote "$URL" "$1" 2>/dev/null | awk 'NR==1 {print $1}'; }

# An annotated tag's `^{}` entry is the commit; a lightweight tag has none.
for candidate in "refs/heads/$REF" "refs/tags/$REF^{}" "refs/tags/$REF"; do
    sha=$(sha_for "$candidate")
    if [ -n "$sha" ]; then
        echo "$sha"
        exit 0
    fi
done

if [[ "$REF" =~ ^[0-9a-f]{7,40}$ ]]; then
    echo "$REF"
    exit 0
fi

echo "resolve-ref: '$REF' is not a branch, tag or SHA in $URL" >&2
exit 1
