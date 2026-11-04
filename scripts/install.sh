#!/usr/bin/env bash
# install.sh - write config, render the launchd plist, dry-run. Loads the
# schedule ONLY with --enable.
#
#   install.sh --roots ~/code,~/work [--interval 600] [--namespace NAME]
#              [--force] [--enable]
# Also symlinks the `parachute` CLI into ~/.local/bin (PARACHUTE_BIN_DIR overrides).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
LABEL="${PARACHUTE_LABEL:-dev.parachute}"
CONFIG="${PARACHUTE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/parachute/config}"
AGENTS_DIR="${PARACHUTE_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
BIN_DIR="${PARACHUTE_BIN_DIR:-$HOME/.local/bin}"
PLIST="$AGENTS_DIR/$LABEL.plist"
ROOTS_ARG=""; INTERVAL=""; NS=""; FORCE=0; ENABLE=0

die() { echo "install.sh: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --roots) shift; ROOTS_ARG="${1:-}";;
    --interval) shift; INTERVAL="${1:-}";;
    --namespace) shift; NS="${1:-}";;
    --force) FORCE=1;;
    --enable) ENABLE=1;;
    -h|--help) sed -n '2,9p' "$0"; exit 0;;
    *) die "unknown option $1";;
  esac; shift
done
case "$INTERVAL" in ""|*[!0-9]*) [ -z "$INTERVAL" ] || die "--interval must be seconds";; esac
[ -z "$INTERVAL" ] || [ "$INTERVAL" -ge 60 ] || die "--interval must be >= 60"

# ---- config ---------------------------------------------------------------
if [ -z "$ROOTS_ARG" ] && [ ! -f "$CONFIG" ]; then
  if [ -t 0 ]; then
    printf 'Directories to scan for git repos (comma-separated, e.g. ~/code,~/work): '
    read -r ROOTS_ARG
  fi
  [ -n "$ROOTS_ARG" ] || die "no config and no --roots given; refusing to guess. Example: install.sh --roots ~/code"
fi
if [ -n "$ROOTS_ARG" ]; then
  if [ -f "$CONFIG" ] && [ "$FORCE" != 1 ]; then die "$CONFIG exists; pass --force to overwrite or edit it by hand"; fi
  mkdir -p "$(dirname "$CONFIG")" || die "cannot create config dir"
  {
    echo "# parachute config (shell-sourceable). See README.md."
    printf 'ROOTS=('
    old_ifs=$IFS; IFS=,
    for r in $ROOTS_ARG; do
      r=$(printf '%s' "$r" | sed -e 's/^ *//' -e 's/ *$//'); [ -n "$r" ] || continue
      case "$r" in "~"/*) r="$HOME/${r#\~/}";; esac
      printf ' %q' "$r"
    done
    IFS=$old_ifs
    echo ' )'
    echo 'EXTRA_ROOTS=()          # more directories to scan'
    echo "INTERVAL=${INTERVAL:-600}            # seconds between runs (re-run install.sh --force to change the schedule)"
    echo 'MAX_FILE_MB=20          # new untracked files larger than this are skipped'
    echo 'TIP_DAYS=90             # unpushed branch tips older than this are ignored'
    echo 'MAX_DEPTH=5             # directory depth to search under each root'
    echo 'EXCLUDE=()              # glob patterns on absolute repo/worktree path, e.g. ( "*/scratch/*" )'
    echo 'PUSH=1                  # 0 = local snapshots only, never push'
    printf 'BACKUP_NAMESPACE=%q      # empty = short hostname\n' "$NS"
  } > "$CONFIG"
  echo "wrote $CONFIG"
fi
if [ -z "$INTERVAL" ]; then
  INTERVAL=$(bash -c ". '$CONFIG' 2>/dev/null; echo \"\${INTERVAL:-600}\"")
fi

# ---- CLI symlink (idempotent; never clobbers a real file) -----------------
mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR"
if [ -e "$BIN_DIR/parachute" ] && [ ! -L "$BIN_DIR/parachute" ]; then
  echo "WARN: $BIN_DIR/parachute exists and is not a symlink; leaving it alone" >&2
else
  ln -sfn "$HERE/parachute.sh" "$BIN_DIR/parachute" || die "cannot link $BIN_DIR/parachute"
  echo "linked $BIN_DIR/parachute -> $HERE/parachute.sh"
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "note: $BIN_DIR is not on your PATH";; esac
fi

# ---- schedule -------------------------------------------------------------
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
if [ "$(uname -s)" = Darwin ]; then
  LOGDIR="$HOME/Library/Logs"; mkdir -p "$LOGDIR" "$AGENTS_DIR"
  tmpl=$(<"$ROOT/templates/launchd.plist.tmpl")
  tmpl=${tmpl//@LABEL@/$(xml "$LABEL")}
  tmpl=${tmpl//@SCRIPT@/$(xml "$HERE/parachute.sh")}
  tmpl=${tmpl//@INTERVAL@/$INTERVAL}
  tmpl=${tmpl//@HOME@/$(xml "$HOME")}
  tmpl=${tmpl//@LOGDIR@/$(xml "$LOGDIR")}
  printf '%s\n' "$tmpl" > "$PLIST" || die "cannot write $PLIST"
  plutil -lint "$PLIST" || die "rendered plist failed lint"
  echo "rendered $PLIST (every ${INTERVAL}s)"
else
  echo "Not macOS: no launchd plist. Schedule scripts/parachute.sh yourself, e.g. cron:"
  echo "  */10 * * * * /bin/bash '$HERE/parachute.sh' run >/dev/null 2>&1"
  echo "and put SCHEDULED=1 in $CONFIG so status.json reports nextRunEpoch."
fi

# ---- dry run (writes nothing to any repo) ---------------------------------
echo; echo "== dry run =="
PARACHUTE_CONFIG="$CONFIG" bash "$HERE/parachute.sh" run --dry-run

# ---- enable ---------------------------------------------------------------
if [ "$ENABLE" = 1 ]; then
  [ "$(uname -s)" = Darwin ] || die "--enable only supports launchd (macOS)"
  [ -z "${PARACHUTE_NO_LAUNCHCTL:-}" ] || die "PARACHUTE_NO_LAUNCHCTL is set; refusing to touch launchd"
  uid=$(id -u)
  launchctl bootout "gui/$uid" "$PLIST" 2>/dev/null
  launchctl bootstrap "gui/$uid" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST" || die "launchctl failed"
  echo "schedule ENABLED ($LABEL)."
else
  echo "Next steps:"
  echo "  1. Review the dry-run table above (repos with NO PUSH are public/unknown/no-origin)."
  echo "  2. Try one repo:   parachute run --only /path/to/repo   # or: bash '$HERE/parachute.sh' run --only ..."
  echo "  3. Enable:         bash '$HERE/install.sh' --enable"
fi
