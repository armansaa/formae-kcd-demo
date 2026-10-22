#!/usr/bin/env bash
# Post a forma's plan as a new PR comment and hide that forma's previous plan
# comments as outdated (still expandable in the PR).
#
# Usage: formae-plan-comment.sh <forma> <pr-number> <head-sha> <plan.md>
# Env:   GH_TOKEN, GITHUB_REPOSITORY
set -euo pipefail

forma=$1 pr=$2 head_sha=$3 plan_md=$4
: "${GITHUB_REPOSITORY:?}"

marker="<!-- formae-plan:$forma -->"
body=$(mktemp)
{
  echo "$marker"
  echo "## formae plan"
  echo
  cat "$plan_md"
  echo
  echo "---"
  echo "Planned at ${head_sha:0:7}. Comment:"
  echo
  echo "- \`formae apply -d $forma\` — apply only this forma (needs an approval)"
  echo "- \`formae apply\` — apply every forma in this PR"
  echo "- \`formae plan -d $forma\` / \`formae plan\` — plan again, e.g. after an apply to confirm there are no changes left"
  echo "- \`formae import -d $forma\` — a resource shown as \`create\` already exists in the cloud? Adopt it instead of creating a duplicate"
  echo
  echo "Merge the PR yourself once the plan shows no changes."
} > "$body"

old=$(gh api "repos/$GITHUB_REPOSITORY/issues/$pr/comments" --paginate \
        --jq ".[] | select(.body | startswith(\"$marker\")) | .node_id")
for node in $old; do
  gh api graphql -f id="$node" -f query='
    mutation($id: ID!) {
      minimizeComment(input: {subjectId: $id, classifier: OUTDATED}) { clientMutationId }
    }' > /dev/null || echo "::warning::could not hide old plan comment $node"
done
gh api "repos/$GITHUB_REPOSITORY/issues/$pr/comments" -F body=@"$body" > /dev/null
rm -f "$body"
