#!/usr/bin/env bash
# Fails unless a commit is the merge of a pull request into `main` that was
# checked on exactly its code. A release relies on this instead of running
# the checks again; a commit `main` took before its rules did has nothing
# to show.
#
# For each check `main` requires, the latest result on the head commit is a
# success, of the results that checked a pull request and finished before
# the merge. Not counted: a result after the merge; a job skipped, which a
# pull request into another branch reports and which checked nothing; and a
# run started by hand. Which pull request started a run does not matter:
# every run that checks one into `main` checks the head merged with a `main`
# the head already contains, which is the head's files.
#
#   checked-on-main.sh <owner/repo> <commit>
#
# Needs GH_TOKEN with read access to pull requests, checks and actions.
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
# merge, but for skipped ones, with the check suite it belongs to.
results=$(gh api --paginate "repos/$repo/commits/$head/check-runs?filter=all&per_page=100" \
    -q ".check_runs[] | select(.app.slug == \"github-actions\" and .completed_at != null and .completed_at <= \"$merged\" and .conclusion != \"skipped\") | [.check_suite.id, .name, .completed_at, .conclusion] | @tsv")
# The suites whose run a pull request started.
from_pull_requests=$(cut -f 1 <<<"$results" | sort -u | while read -r suite; do
    [ -n "$suite" ] || continue
    event=$(gh api "repos/$repo/actions/runs?check_suite_id=$suite" -q '.workflow_runs[0].event // empty')
    [ "$event" = pull_request ] && echo "$suite"
done || true)
# For each name, the latest of those decides.
passed=$(awk -F '\t' 'NR == FNR { keep[$1] = 1; next } keep[$1] { print $2 "\t" $3 "\t" $4 }' \
        <(printf '%s\n' "$from_pull_requests") <(printf '%s\n' "$results") \
    | sort -t $'\t' -k1,1 -k2,2 | awk -F '\t' '{ last[$1] = $3 } END { for (name in last) if (last[name] == "success") print name }')

missing=$(comm -23 <(sort -u <<<"$required") <(sort -u <<<"$passed"))
if [ -n "$missing" ]; then
    echo "::error::when #$pr merged, its head $head had not passed these checks of main:"
    echo "$missing"
    exit 1
fi
echo "$commit is the merge of #$pr, whose head passed all $(wc -l <<<"$required" | tr -d ' ') checks main requires before it merged"
