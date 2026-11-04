---
name: parachute
description: Automatically back up uncommitted and unpushed git work (dirty files, untracked files, local-only branches) from every repo and worktree to hidden backup/* branches on private GitHub remotes, so a crash, reboot or disk loss cannot lose work. Use when the user says "back up my uncommitted work", "I lost work after a crash", "set up autosave for all my repos", "restore my lost changes", or asks for protection against losing work-in-progress.
---

# parachute

Every N minutes, snapshots dirty + untracked work in all git repos and worktrees under configured roots into hidden local refs (temp index; real index, HEAD and worktree are never touched), then pushes **only** to `refs/heads/backup/<namespace>/...` on **private** GitHub (or local-path) remotes. Respects `.gitignore`; drops secret-looking new files (`.env*`, `*.pem`, `*.key`, `.npmrc`, ...) and new files over 20 MB.

Scripts live in `scripts/` next to this file. Use absolute paths.

## Install (always in this order)

1. Ask the user which directories hold their repos. Do not guess or default to `$HOME`.
2. `bash scripts/install.sh --roots <dir1>,<dir2>` writes `~/.config/parachute/config`, renders the launchd plist (macOS), and runs a **dry run**. It does NOT schedule anything.
3. Show the user the dry-run table. Repos marked `NO PUSH` are public/unknown/no-origin and will only be snapshotted locally. Needs `gh auth login` for the private check on GitHub remotes.
4. Run once on a single repo and verify: `parachute run --only <repo>` (install.sh symlinks the `parachute` CLI to `~/.local/bin`; otherwise `bash scripts/parachute.sh run --only <repo>`) then `git -C <repo> ls-remote origin 'refs/heads/backup/*'`.
5. Only after the user agrees, enable the schedule: `bash scripts/install.sh --enable` (macOS launchd). On Linux, add the cron line install.sh prints.

## Restore

`parachute restore <repo-or-worktree-path>` (or `bash scripts/parachute-restore.sh ...`) lists snapshots and **prints** recovery commands (never applies them). On a fresh machine, fetch first: `git fetch origin 'refs/heads/backup/*:refs/remotes/origin/backup/*'`, then pass `refs/remotes/origin/backup/<namespace>/<branch>--<dirname>` to the script. Prefer the "new branch + worktree" recovery; use `checkout <ref> -- .` only if the user confirms overwriting files.

## Maintenance

- Logs: `~/Library/Logs/parachute.log` (macOS) or `${XDG_STATE_HOME:-~/.local/state}/parachute/parachute.log`.
- Status: `parachute status` prints `${XDG_STATE_HOME:-~/.local/state}/parachute/status.json` (state, last result, warnings). `--dry-run` never writes it.
- Backup branches accumulate. Preview then prune: `parachute run --prune-remote-older-than 30 --dry-run`, then without `--dry-run`. Only ever deletes `refs/heads/backup/<own namespace>/*`.
- Uninstall: `bash scripts/uninstall.sh` (unloads + removes plist and the `~/.local/bin/parachute` symlink; leaves config, refs and remote branches, and prints how to prune them).

## Safety rules for Claude

- Never run the tool against repos the user has not named as roots; always dry-run first.
- Never enable the schedule, push, or prune without the user's explicit go-ahead.
- Never loosen `assert_refspec` or the private-repo check, never add `--force` pushes elsewhere.
- Pushes use `--no-verify` on purpose (unattended pre-push hooks would block or slow backups); only backup refs are written.
- Backup branches may trigger CI configured with `on: push`; warn the user (see README).
- Tracked files already containing secrets are not filtered, only *new* secret-looking files are.
