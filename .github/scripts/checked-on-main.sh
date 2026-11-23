#!/usr/bin/env bash
# Fails unless a commit is the merge of a pull request into `main` that was
# checked on exactly its code: the merge has the files of the pull request's
# head, and the last run of Validation for that pull request passed every
# check `main` requires. A release relies on that instead of running the
# checks again; a commit `main` took before its rules did has none to show.
#
#   checked-on-main.sh <owner/repo> <commit>
#
# Needs GH_TOKEN with read access to pull requests and actions.
set -euo pipefail

repo=$1
commit=$2

pr=$(gh api "repos/$repo/commits/$commit/pulls" \
    -q "[.[] | select(.base.ref == \"main\" and .merge_commit_sha == \"$commit\")][0].number // empty")
if [ -z "$pr" ]; then
    echo "::error::$commit is not the merge of a pull request into main"
    exit 1
fi
read -r head head_ref opened merged < <(gh api "repos/$repo/pulls/$pr" \
    -q '[.head.sha, .head.ref, .created_at, .merged_at] | @tsv')

# `main` takes a branch only up to date, so a merge has the files of the head
# it merged. If it does not, it holds code no run of the pull request saw.
tree=$(gh api "repos/$repo/git/commits/$commit" -q .tree.sha)
head_tree=$(gh api "repos/$repo/git/commits/$head" -q .tree.sha)
if [ "$tree" != "$head_tree" ]; then
    echo "::error::$commit does not have the files of #$pr's head $head"
    exit 1
fi

# The runs of this pull request: Validation, started by a pull request, on
# its branch and head, while it was open. GitHub forgets which pull request a
# run belonged to once the branch is gone, so the run is matched by these.
# The last one is the one whose checks let it merge.
run=$(gh api --paginate "repos/$repo/actions/workflows/validation.yml/runs?head_sha=$head&event=pull_request&per_page=100" \
    -q ".workflow_runs[] | select(.head_branch == \"$head_ref\" and .created_at >= \"$opened\" and .created_at <= \"$merged\") | [.created_at, .id] | @tsv" \
    | sort | tail -n 1 | cut -f 2)
if [ -z "$run" ]; then
    echo "::error::no run of Validation checked #$pr at its head $head"
    exit 1
fi

required=$(gh api "repos/$repo/rules/branches/main" \
    -q '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context')
if [ -z "$required" ]; then
    echo "::error::main requires no checks, so nothing shows that $commit was checked"
    exit 1
fi
passed=$(gh api --paginate "repos/$repo/actions/runs/$run/jobs?per_page=100" \
    -q '.jobs[] | select(.conclusion == "success") | .name')

missing=$(comm -23 <(sort -u <<<"$required") <(sort -u <<<"$passed"))
if [ -n "$missing" ]; then
    echo "::error::run $run of #$pr did not pass these checks of main:"
    echo "$missing"
    exit 1
fi
echo "$commit is the merge of #$pr; run $run passed all $(wc -l <<<"$required" | tr -d ' ') checks main requires on its files"
