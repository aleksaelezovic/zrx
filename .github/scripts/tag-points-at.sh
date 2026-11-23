#!/usr/bin/env bash
# Fails unless a tag of a GitHub repository points at a given commit, as the
# repository has it now. An annotated tag is followed to its commit.
#
#   tag-points-at.sh <owner/repo> <tag> <commit>
set -euo pipefail

repo=$1
tag=$2
expected=$3
refs=$(git ls-remote "https://github.com/$repo" "refs/tags/$tag" "refs/tags/$tag^{}")
commit=$(awk -v ref="refs/tags/$tag^{}" '$2 == ref { print $1 }' <<<"$refs")
[ -n "$commit" ] || commit=$(awk -v ref="refs/tags/$tag" '$2 == ref { print $1 }' <<<"$refs")
if [ "$commit" != "$expected" ]; then
    echo "::error::tag $tag points at ${commit:-nothing}, not at $expected, the commit this run checked"
    exit 1
fi
