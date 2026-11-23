#!/usr/bin/env bash
# Fails unless a commit is the merge of a pull request into `main` whose head
# passed every check `main` requires now. A release relies on that instead of
# running the checks again; a commit `main` took before its rules did, or
# that came another way, has none to show.
#
#   checked-on-main.sh <owner/repo> <commit>
#
# Needs GH_TOKEN with read access to pull requests and checks.
set -euo pipefail

repo=$1
commit=$2

pr=$(gh api "repos/$repo/commits/$commit/pulls" \
    -q "[.[] | select(.base.ref == \"main\" and .merge_commit_sha == \"$commit\")][0].number // empty")
if [ -z "$pr" ]; then
    echo "::error::$commit is not the merge of a pull request into main"
    exit 1
fi
head=$(gh api "repos/$repo/pulls/$pr" -q .head.sha)

required=$(gh api "repos/$repo/rules/branches/main" \
    -q '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context')
if [ -z "$required" ]; then
    echo "::error::main requires no checks, so nothing shows that $commit was checked"
    exit 1
fi
passed=$(gh api --paginate "repos/$repo/commits/$head/check-runs?per_page=100" \
    -q '.check_runs[] | select(.conclusion == "success") | .name')

missing=$(comm -23 <(sort -u <<<"$required") <(sort -u <<<"$passed"))
if [ -n "$missing" ]; then
    echo "::error::pull request #$pr did not pass these checks of main:"
    echo "$missing"
    exit 1
fi
echo "$commit is the merge of #$pr, whose head $head passed all $(wc -l <<<"$required" | tr -d ' ') checks main requires"
