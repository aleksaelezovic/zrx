#!/usr/bin/env bash
# Fails unless a commit is the merge of a pull request into `main` that was
# checked on exactly its code. A release relies on this instead of running
# the checks again; a commit `main` took before its rules did has nothing
# to show.
#
# It asks what GitHub itself asked when it let the pull request merge: for
# each check `main` requires, the latest result on the head commit, of those
# finished by the time of the merge, is a success. A check run again after
# the merge does not count. Which pull request started a run does not
# matter, as it does not to GitHub: every such run checks the head merged
# with a `main` that the head already contains, which is the head's files.
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
read -r head merged < <(gh api "repos/$repo/pulls/$pr" -q '[.head.sha, .merged_at] | @tsv')

# `main` takes a branch only up to date, so a merge has the files of the head
# it merged. If it does not, it holds code no check of the head saw.
tree=$(gh api "repos/$repo/git/commits/$commit" -q .tree.sha)
head_tree=$(gh api "repos/$repo/git/commits/$head" -q .tree.sha)
if [ "$tree" != "$head_tree" ]; then
    echo "::error::$commit does not have the files of #$pr's head $head"
    exit 1
fi

required=$(gh api "repos/$repo/rules/branches/main" \
    -q '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context')
if [ -z "$required" ]; then
    echo "::error::main requires no checks, so nothing shows that $commit was checked"
    exit 1
fi
# Every attempt of every check GitHub Actions finished on the head before the
# merge; for each name, the latest decides.
passed=$(gh api --paginate "repos/$repo/commits/$head/check-runs?filter=all&per_page=100" \
    -q ".check_runs[] | select(.app.slug == \"github-actions\" and .completed_at != null and .completed_at <= \"$merged\") | [.name, .completed_at, .conclusion] | @tsv" \
    | sort -t $'\t' -k1,1 -k2,2 | awk -F '\t' '{ last[$1] = $3 } END { for (name in last) if (last[name] == "success") print name }')

missing=$(comm -23 <(sort -u <<<"$required") <(sort -u <<<"$passed"))
if [ -n "$missing" ]; then
    echo "::error::when #$pr merged, its head $head had not passed these checks of main:"
    echo "$missing"
    exit 1
fi
echo "$commit is the merge of #$pr, whose head passed all $(wc -l <<<"$required" | tr -d ' ') checks main requires before it merged"
