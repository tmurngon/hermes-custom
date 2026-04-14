#!/usr/bin/env bash
set -euo pipefail

repo_dir="${HERMES_REPO_DIR:-$HOME/.hermes/hermes-agent}"
custom_branch_default="feat/custom-status-bar-zar"
requested_branch="${1:-}"

cd "$repo_dir"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "✗ Not a git repository: $repo_dir" >&2
  exit 1
fi

current_branch="$(git branch --show-current)"
if [[ -z "$current_branch" ]]; then
  current_branch="HEAD"
fi

if [[ -n "$requested_branch" ]]; then
  target_branch="$requested_branch"
elif [[ "$current_branch" != "main" && "$current_branch" != "HEAD" ]]; then
  target_branch="$current_branch"
elif git show-ref --verify --quiet "refs/heads/$custom_branch_default"; then
  target_branch="$custom_branch_default"
else
  target_branch=""
fi

auto_stash=0
stash_name="update-safe-$(date +%Y%m%d-%H%M%S)"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "→ Stashing local changes..."
  git stash push -u -m "$stash_name" >/dev/null
  auto_stash=1
fi

restore_stash() {
  if [[ "$auto_stash" -eq 1 ]]; then
    echo "→ Restoring stashed local changes..."
    if ! git stash pop --index >/dev/null 2>&1; then
      echo "⚠ Could not auto-restore stashed changes cleanly." >&2
      echo "  Restore manually with: git stash list && git stash pop --index" >&2
      return 1
    fi
  fi
}

trap 'rc=$?; if [[ $rc -ne 0 ]]; then echo "✗ update-safe aborted." >&2; fi' EXIT

if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "✗ Missing upstream remote." >&2
  echo "  Add it with: git remote add upstream git@github.com:NousResearch/hermes-agent.git" >&2
  exit 1
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "✗ Missing origin remote." >&2
  exit 1
fi

if [[ -n "$target_branch" ]] && ! git show-ref --verify --quiet "refs/heads/$target_branch"; then
  echo "✗ Target branch '$target_branch' does not exist locally." >&2
  exit 1
fi

echo "⚕ Safe Hermes update"
echo
printf 'Current branch: %s\n' "$current_branch"
if [[ -n "$target_branch" ]]; then
  printf 'Target branch:  %s\n' "$target_branch"
else
  echo "Target branch:  <none; main only>"
fi
echo

echo "→ Fetching upstream and origin..."
git fetch upstream
git fetch origin

echo "→ Updating local main from upstream/main..."
git checkout main >/dev/null
if git rev-parse --verify --quiet refs/remotes/upstream/main >/dev/null; then
  git branch --set-upstream-to=upstream/main main >/dev/null 2>&1 || true
fi
git pull --ff-only upstream main

echo "→ Pushing updated main to origin..."
git push origin main

if [[ -n "$target_branch" && "$target_branch" != "main" ]]; then
  echo "→ Rebasing $target_branch onto main..."
  git checkout "$target_branch" >/dev/null
  if ! git rebase main; then
    echo
    echo "⚠ Rebase stopped due to conflicts." >&2
    echo "  Resolve conflicts, then run: git rebase --continue" >&2
    echo "  Or abort with: git rebase --abort" >&2
    exit 1
  fi

  if git rev-parse --verify --quiet "refs/remotes/origin/$target_branch" >/dev/null; then
    echo "→ Pushing rebased $target_branch to origin..."
    git push --force-with-lease origin "$target_branch"
  else
    echo "→ Pushing new branch $target_branch to origin..."
    git push -u origin "$target_branch"
  fi
else
  echo "→ No non-main target branch selected; leaving update at main only."
fi

if [[ "$current_branch" != "HEAD" ]]; then
  echo "→ Returning to original branch: $current_branch"
  git checkout "$current_branch" >/dev/null
fi

restore_stash || true
trap - EXIT

echo
echo "✓ Safe update complete."
if [[ -n "$target_branch" && "$target_branch" != "main" ]]; then
  echo "  main is synced from upstream and mirrored to origin."
  echo "  $target_branch has been rebased on top of updated main."
else
  echo "  main is synced from upstream and mirrored to origin."
fi
