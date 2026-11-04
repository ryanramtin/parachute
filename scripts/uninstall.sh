#!/usr/bin/env bash
# uninstall.sh - unload and remove the launchd agent and the ~/.local/bin/parachute
# symlink (only if it is a symlink to parachute.sh). Leaves config, logs, status,
# local backup refs and remote backup/* branches alone.
set -u
LABEL="${PARACHUTE_LABEL:-dev.parachute}"
AGENTS_DIR="${PARACHUTE_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$AGENTS_DIR/$LABEL.plist"
BIN_DIR="${PARACHUTE_BIN_DIR:-$HOME/.local/bin}"
link="$BIN_DIR/parachute"
if [ -L "$link" ]; then
  case "$(readlink "$link")" in */parachute.sh) rm -f "$link" && echo "removed symlink $link";; *) echo "$link is a symlink to something else; left alone";; esac
elif [ -e "$link" ]; then echo "$link is not a symlink; left alone"; fi
if [ "$(uname -s)" = Darwin ]; then
  uid=$(id -u)
  if [ -z "${PARACHUTE_NO_LAUNCHCTL:-}" ]; then
    launchctl bootout "gui/$uid" "$PLIST" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null
  fi
  if [ -f "$PLIST" ]; then rm -f "$PLIST" && echo "removed $PLIST"; else echo "no plist at $PLIST"; fi
else
  echo "Not macOS: remove your cron/systemd entry for parachute.sh manually."
fi
cat <<'MSG'

Left in place (delete by hand if you want):
  config:          ~/.config/parachute/config
  status/state:    ${XDG_STATE_HOME:-~/.local/state}/parachute/
  logs:            ~/Library/Logs/parachute.log (macOS) or ${XDG_STATE_HOME:-~/.local/state}/parachute/parachute.log
  local refs:      refs/backup/*, refs/backup-hist/*, refs/backup-pushed*/* in each repo
  remote branches: refs/heads/backup/<namespace>/* on each origin

Prune remote backup branches (touches only your own namespace):
  parachute run --prune-remote-older-than 1 --dry-run   # preview
  parachute run --prune-remote-older-than 1             # delete (needs the config)
or per repo:
  git push origin --delete backup/<namespace>/<name>
Drop local refs in a repo:
  git for-each-ref --format='%(refname)' 'refs/backup*' | xargs -n1 git update-ref -d
MSG
