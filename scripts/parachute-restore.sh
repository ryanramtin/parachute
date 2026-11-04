#!/usr/bin/env bash
# parachute-restore.sh [worktree-path | ref | sha]   (no arg: current directory)
# Lists parachute snapshots and PRINTS recovery commands. Never applies anything.
set -u
arg="${1:-.}"
if [ -d "$arg" ]; then
  wt=$(cd "$arg" && pwd -P); top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo: $arg"; exit 1; }
  name=$(basename "$top")
  echo "# Snapshots for worktree dir '$name' in $top"
  echo "# latest local refs (refs/backup/<branch>/$name):"
  git -C "$top" for-each-ref --sort=-creatordate --format='  %(refname)  %(objectname:short)  %(creatordate:iso)  %(subject)' 'refs/backup/*' | grep "/$name " || echo "  (none)"
  echo "# local history (last 5 per branch):"
  git -C "$top" for-each-ref --sort=-refname --format='  %(refname)  %(objectname:short)  %(creatordate:iso)' 'refs/backup-hist/*' | grep "/$name/" || echo "  (none)"
  echo "# on origin (also works on a fresh machine / after the local clone was lost):"
  echo "git -C '$top' ls-remote origin 'refs/heads/backup/*'"
  echo "git -C '$top' fetch origin 'refs/heads/backup/*:refs/remotes/origin/backup/*'"
  echo "#   then pass e.g. refs/remotes/origin/backup/<namespace>/<branch>--$name to this script"
  latest=$(git -C "$top" for-each-ref --sort=-creatordate --format='%(refname)' 'refs/backup/*' | grep "/$name$" | head -1)
  [ -n "$latest" ] || { echo "# nothing to restore locally"; exit 0; }
  ref=$latest
else
  top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "run inside a repo for a ref/sha"; exit 1; }
  ref=$arg
  git -C "$top" rev-parse -q --verify "$ref^{commit}" >/dev/null || { echo "unknown ref: $ref"; exit 1; }
fi
sha=$(git -C "$top" rev-parse --short "$ref")
echo
echo "# Inspect (does NOT change anything):"
echo "git -C '$top' show --stat $ref"
echo "git -C '$top' diff --stat HEAD $ref        # snapshot vs current HEAD"
echo "git -C '$top' diff HEAD $ref               # full patch"
echo
echo "# Recover (run manually - pick one):"
echo "git -C '$top' checkout $ref -- .                     # overwrite matching files in the working tree (does not delete files)"
echo "git -C '$top' diff HEAD $ref | git -C '$top' apply   # apply as patch (tracked changes only; untracked files need checkout form)"
echo "git -C '$top' branch rescue/$sha $ref && git -C '$top' worktree add ../rescue-$sha rescue/$sha   # safe: new branch + worktree"
