# Contributing

Small, focused PRs welcome.

- Scripts must stay **bash 3.2 compatible** (macOS default): no associative arrays, no `mapfile`, no `${var,,}`. Beware empty arrays under `set -u` (use `${arr[@]+"${arr[@]}"}`).
- Do not weaken the safety properties: pushes only to `refs/heads/backup/*` (`assert_refspec`), private/local remotes only, never touch the real index/HEAD/worktree. Any change in this area needs a test in `test/run.sh`.
- Run `bash test/run.sh` (must exit 0) and `shellcheck scripts/*.sh test/run.sh` before opening a PR.
- No personal paths, hostnames or project names in code, docs or tests.
