#!/usr/bin/env bash
# parachute.sh - snapshot dirty worktrees to private refs/heads/backup/* only.
# This file is the `parachute` CLI (install.sh symlinks it to ~/.local/bin/parachute).
#
# bash 3.2 compatible (macOS default). Deliberately NO `set -e`: one repo
# failing must not stop the others.
#
# Usage: parachute run [--dry-run] [--only <path>] [--verbose]
#                      [--prune-remote-older-than <days>]
#        parachute restore [path|ref|sha] | status | version | help
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 GCM_INTERACTIVE=never
export GIT_AUTHOR_NAME="parachute" GIT_AUTHOR_EMAIL="parachute@localhost"
export GIT_COMMITTER_NAME="parachute" GIT_COMMITTER_EMAIL="parachute@localhost"

CONFIG="${PARACHUTE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/parachute/config}"
if [ -n "${PARACHUTE_LOG:-}" ]; then LOG="$PARACHUTE_LOG"
elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then LOG="$HOME/Library/Logs/parachute.log"
else LOG="${XDG_STATE_HOME:-$HOME/.local/state}/parachute/parachute.log"; fi
VERSION="0.1.0"
# state dir: lock + status.json (PARACHUTE_STATE overrides, mainly for tests)
STATE_DIR="${PARACHUTE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/parachute}"
STATUS_FILE="$STATE_DIR/status.json"
LABEL="${PARACHUTE_LABEL:-dev.parachute}"
SCHEDULED="${PARACHUTE_SCHEDULED:-}"   # 1/0; empty = autodetect (launchd job loaded). cron users: set SCHEDULED=1 in config.
STATUS_ON=0; STATUS_DONE=0
LOG_MAX=$((5*1024*1024))
PUSH_TIMEOUT="${PARACHUTE_PUSH_TIMEOUT:-60}"
KEEP_HIST=5

# ---- defaults (overridden by the config file) ----------------------------
ROOTS=(); EXTRA_ROOTS=(); EXCLUDE=()
INTERVAL=600           # seconds between scheduled runs (install.sh; also feeds status.json nextRunEpoch)
MAX_FILE_MB=20         # new (untracked) files bigger than this are not captured
TIP_DAYS=90            # unpushed branch tips older than this are ignored
MAX_DEPTH=5            # how deep under each root to look for repos
PUSH=1                 # 0 = snapshot locally, never push
BACKUP_NAMESPACE=""    # default: short hostname
HOST=""
DRY=0; ONLY=""; VERBOSE=0; PRUNE_DAYS=""; MODE=backup
[ -t 1 ] && VERBOSE=1

log() { local m; m="$(date '+%Y-%m-%d %H:%M:%S') $*"; printf '%s\n' "$m" >> "$LOG" 2>/dev/null; [ "$VERBOSE" = 1 ] && printf '%s\n' "$m"; return 0; }

# sanitize a string for use inside a ref name component
san() {
  local s
  s=$(printf '%s' "$1" | LC_ALL=C sed -e 's/[^A-Za-z0-9._-]/-/g' -e 's/\.\.*/./g' -e 's/^[.-]*//' -e 's/\.lock$//' -e 's/\.$//')
  [ -n "$s" ] || s="x"
  printf '%s' "$s"
}

# run with wall-clock timeout (macOS has no `timeout`)
tmo() {
  local secs=$1; shift
  if command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
  elif command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"; fi
}

warn() { printf '%s\n' "$1" >> "$RUN/warnings"; }

skip() { # reason scope detail
  printf '%s\n' "$1" >> "$RUN/skips"; log "SKIP[$1] $2 $3"
  case "$1" in excluded|unborn-head) ;; *) warn "skipped $1 ${2##*/}";; esac
}

is_excluded() { # path
  local p
  for p in ${EXCLUDE[@]+"${EXCLUDE[@]}"}; do
    # shellcheck disable=SC2254  # intentional glob match
    case "$1" in $p) return 0;; esac
  done
  return 1
}

# HARD GUARD: every push destination must live under refs/heads/backup/
assert_dest() { # dest
  local dest=$1
  case "$dest" in
    refs/heads/backup/?*) ;;
    *) log "GUARD-ABORT destination '$dest' not under refs/heads/backup/"; return 1;;
  esac
  case "$dest" in *..*|*:*|*" "*|*"+"*|*"~"*|*"^"*|*"?"*|*"*"*|*"["*|*"\\"*|*"@{"*) log "GUARD-ABORT illegal chars in '$dest'"; return 1;; esac
  return 0
}
assert_refspec() { # sha dest
  local sha=$1 dest=$2
  case "$sha" in *[!0-9a-f]*|"") log "GUARD-ABORT bad source sha '$sha'"; return 1;; esac
  if [ "${#sha}" -ne 40 ] && [ "${#sha}" -ne 64 ]; then log "GUARD-ABORT bad source sha length '$sha'"; return 1; fi
  assert_dest "$dest"
}

# push a batch: $1=workdir $2=specfile (lines: sha dest marker). Returns 0 on success.
# --force: backup refs are ours alone and are rewritten on every snapshot.
# --no-verify: skip the repo's pre-push hooks. They are meant for real
#   pushes (lint/tests/policy), would run unattended every few minutes, and
#   could block or slow the backup. We only ever write backup/* refs.
safe_push() {
  local wd=$1 specs=$2 sha dest marker args=() sshc
  while read -r sha dest marker; do
    assert_refspec "$sha" "$dest" || { log "GUARD-ABORT: push aborted for $wd"; return 2; }
    args+=("$sha:$dest")
  done < "$specs"
  [ "${#args[@]}" -gt 0 ] || return 0
  sshc=$(git -C "$wd" config core.sshCommand 2>/dev/null); [ -n "$sshc" ] || sshc=ssh
  GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-$sshc} -o BatchMode=yes -o ConnectTimeout=20" \
    tmo "$PUSH_TIMEOUT" git -C "$wd" push --force --no-verify --quiet origin "${args[@]}" >> "$LOG" 2>&1
}

# classify origin: prints private|local|public|no-origin|unknown-remote|no-gh-auth|gh-error
GH_OK=""
check_private() { # workdir
  local url owner repo out
  url=$(git -C "$1" remote get-url --push origin 2>/dev/null) || { echo no-origin; return; }
  [ -n "$url" ] || { echo no-origin; return; }
  case "$url" in /*|file://*|./*|../*) echo local; return;; esac
  if [[ "$url" =~ ^(https?://([^/@]+@)?|ssh://([^/@]+@)?|[^/@:]+@)github\.com[:/]+([^/]+)/([^/]+)/?$ ]]; then
    owner="${BASH_REMATCH[4]}"; repo="${BASH_REMATCH[5]%.git}"
  else
    echo unknown-remote; return
  fi
  if [ -z "$GH_OK" ]; then
    if command -v gh >/dev/null 2>&1 && tmo 20 gh auth status >/dev/null 2>&1; then GH_OK=yes; else GH_OK=no; fi
  fi
  [ "$GH_OK" = yes ] || { echo no-gh-auth; return; }
  out=$(tmo 30 gh repo view "$owner/$repo" --json isPrivate -q .isPrivate 2>/dev/null)
  case "$out" in true) echo private;; false) echo public;; *) echo gh-error;; esac
}

is_secretish() { # basename
  case "$1" in
    .env.example|.env.sample|.env.template|.env.dist) return 1;;
    .env|.env.*|*.pem|*.key|*.p12|*.pfx|*.p8|*.mobileprovision|*.keystore|*.jks|id_rsa*|id_ed25519*|id_ecdsa*|credentials.json|service-account*.json|.npmrc|.netrc|*.secret|*.secrets) return 0;;
  esac
  return 1
}

# ---- per worktree -------------------------------------------------------
process_wt() { # wt gd specs
  local wt=$1 gd=$2 specs=$3 br head st bs ds ts tdir idx tree headtree lasttree commit dropl n f base sz
  if [ ! -d "$wt" ]; then skip missing-dir "$wt" ""; return; fi
  if is_excluded "$wt"; then skip excluded "$wt" ""; return; fi
  WTS=$((WTS+1))
  br=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null); [ -n "$br" ] || br=detached
  head=$(git -C "$wt" rev-parse -q --verify HEAD 2>/dev/null)
  if [ -z "$head" ]; then skip unborn-head "$wt" ""; [ "$DRY" = 1 ] && echo "WT|$wt|$br|unborn|skip" >> "$RUN/table"; return; fi
  bs=$(san "$br"); ds=$(san "$(basename "$wt")")
  local ref="refs/backup/$bs/$ds" marker="refs/backup-pushed/$bs/$ds"
  st=$(git -C "$wt" status --porcelain --untracked-files=normal 2>/dev/null); local src=$?
  if [ "$src" -ne 0 ]; then skip status-failed "$wt" ""; return; fi
  if [ -n "$st" ]; then
    DIRTY=$((DIRTY+1))
    if [ "$DRY" = 1 ]; then
      n=$(printf '%s\n' "$st" | wc -l | tr -d ' ')
      echo "WT|$wt|$br|dirty($n entries)|would snapshot -> $ref" >> "$RUN/table"
    else
      ts=$(date -u +%Y%m%dT%H%M%SZ)
      tdir=$(mktemp -d "${TMPDIR:-/tmp}/parachuteidx.XXXXXX") || { skip mktemp-failed "$wt" ""; return; }
      idx="$tdir/index"
      # temp index: the real index, HEAD and worktree are never touched
      if ! GIT_INDEX_FILE="$idx" git -C "$wt" read-tree HEAD >>"$LOG" 2>&1; then skip read-tree-failed "$wt" ""; rm -rf "$tdir"; return; fi
      if ! GIT_INDEX_FILE="$idx" git -C "$wt" add -A >>"$LOG" 2>&1; then log "WARN add -A returned nonzero in $wt (continuing with what was staged)"; fi
      # drop secret-looking / oversized files that are NEW relative to HEAD (never touches tracked content)
      dropl="$tdir/drop"; : > "$dropl"; n=0
      while IFS= read -r -d '' f; do
        base=${f##*/}; sz=0
        if is_secretish "$base"; then printf '%s\0' "$f" >> "$dropl"; n=$((n+1)); log "FILTER secret-like '$f' in $wt"; continue; fi
        if [ -f "$wt/$f" ]; then sz=$(wc -c < "$wt/$f" 2>/dev/null | tr -d ' ')
          if [ "${sz:-0}" -gt $((MAX_FILE_MB*1024*1024)) ]; then printf '%s\0' "$f" >> "$dropl"; n=$((n+1)); log "FILTER oversize(${sz}B) '$f' in $wt"; fi
        fi
      done < <(GIT_INDEX_FILE="$idx" git -C "$wt" diff --cached --name-only --diff-filter=A -z HEAD 2>/dev/null)
      if [ "$n" -gt 0 ]; then
        xargs -0 -n 100 env GIT_INDEX_FILE="$idx" git -C "$wt" update-index --force-remove -- < "$dropl" >>"$LOG" 2>&1
      fi
      tree=$(GIT_INDEX_FILE="$idx" git -C "$wt" write-tree 2>>"$LOG")
      rm -rf "$tdir"
      if [ -z "$tree" ]; then skip write-tree-failed "$wt" ""; return; fi
      headtree=$(git -C "$wt" rev-parse "HEAD^{tree}")
      lasttree=$(git -C "$wt" rev-parse -q --verify "$ref^{tree}" 2>/dev/null)
      if [ "$tree" = "$headtree" ]; then UNCH=$((UNCH+1)); log "NOCHANGE(equals HEAD after filters) $wt"
      elif [ "$tree" = "$lasttree" ]; then UNCH=$((UNCH+1)); log "NOCHANGE(same as last backup) $wt"
      else
        commit=$(git -C "$wt" commit-tree "$tree" -p "$head" -m "parachute $ts" -m "worktree: $wt
branch: $br
host: $HOST" 2>>"$LOG")
        if [ -z "$commit" ]; then skip commit-failed "$wt" ""; return; fi
        git -C "$wt" update-ref "$ref" "$commit" && git -C "$wt" update-ref "refs/backup-hist/$bs/$ds/$ts" "$commit"
        # prune local history to last $KEEP_HIST
        git -C "$wt" for-each-ref --sort=-refname --format='%(refname)' "refs/backup-hist/$bs/$ds/" 2>/dev/null \
          | tail -n +$((KEEP_HIST+1)) | while read -r old; do git -C "$wt" update-ref -d "$old"; done
        SNAPS=$((SNAPS+1)); log "SNAPSHOT $wt branch=$br -> $ref $commit"
      fi
    fi
  else
    CLEAN=$((CLEAN+1))
    [ "$DRY" = 1 ] && echo "WT|$wt|$br|clean|-" >> "$RUN/table"
  fi
  # queue push of the (possibly pre-existing) snapshot if not yet pushed
  local sha cur
  sha=$(git -C "$wt" rev-parse -q --verify "$ref" 2>/dev/null)
  if [ -n "$sha" ]; then
    cur=$(git -C "$wt" rev-parse -q --verify "$marker" 2>/dev/null)
    [ "$cur" = "$sha" ] || printf '%s refs/heads/backup/%s/%s--%s %s\n' "$sha" "$HOST" "$bs" "$ds" "$marker" >> "$specs"
  fi
}

collect_tips() { # gd specs
  local gd=$1 specs=$2 ref sha ct br sb marker cur contained cutoff
  cutoff=$(( $(date +%s) - TIP_DAYS*86400 ))
  while read -r ref sha ct; do
    br=${ref#refs/heads/}
    case "$br" in backup/*) continue;; esac
    [ "${ct:-0}" -ge "$cutoff" ] 2>/dev/null || continue
    contained=$(git --git-dir="$gd" for-each-ref --count=1 --contains "$sha" --format=x refs/remotes 2>/dev/null)
    [ -z "$contained" ] || continue
    sb=$(san "$br"); marker="refs/backup-pushed-tip/$sb"
    cur=$(git --git-dir="$gd" rev-parse -q --verify "$marker" 2>/dev/null)
    [ "$cur" = "$sha" ] && continue
    printf '%s refs/heads/backup/%s/%s--branch-tip %s\n' "$sha" "$HOST" "$sb" "$marker" >> "$specs"
    TIPS=$((TIPS+1))
  done < <(git --git-dir="$gd" for-each-ref --format='%(refname) %(objectname) %(committerdate:unix)' refs/heads 2>/dev/null)
}

# first existing worktree of a repo (a safe place to run `git push` from)
first_worktree() { # wtl-file fallback
  local p wd=""
  wd=$(sed -n 's/^worktree //p' "$1" | while IFS= read -r p; do [ -d "$p" ] && { echo "$p"; break; }; done)
  [ -n "$wd" ] || wd=$2
  printf '%s' "$wd"
}

process_repo() { # gd firstdir
  local gd=$1 first=$2 specs wd line p nspec priv sha dest marker
  REPOS=$((REPOS+1))
  specs="$RUN/specs.$REPOS"; : > "$specs"
  git -C "$first" worktree list --porcelain 2>/dev/null > "$RUN/wtl.$REPOS"
  local bare=0
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) p=${line#worktree }; bare=0;;
      bare) bare=1;;
      "")  [ -n "${p:-}" ] && [ "$bare" = 0 ] && handle_wt "$p" "$gd" "$specs"; p="";;
    esac
  done < <(cat "$RUN/wtl.$REPOS"; echo)
  # fallback for repos where worktree list is unavailable
  [ -s "$RUN/wtl.$REPOS" ] || handle_wt "$first" "$gd" "$specs"
  wd=$(first_worktree "$RUN/wtl.$REPOS" "$first")
  collect_tips "$gd" "$specs"
  nspec=$(wc -l < "$specs" | tr -d ' ')
  if [ "$nspec" = 0 ] && [ "$DRY" = 0 ]; then return; fi
  if [ "$PUSH" != 1 ]; then
    [ "$DRY" = 1 ] && echo "REPO|$wd|-|$nspec pending|push disabled (PUSH=0)" >> "$RUN/table"
    return
  fi
  priv=$(check_private "$wd")
  case "$priv" in
    private|local) ;;
    *) if [ "$nspec" -gt 0 ] || [ "$DRY" = 1 ]; then
         echo "$priv" >> "$RUN/skips"; warn "skipped $priv repo ${wd##*/}"; log "SKIP[$priv] push for $wd ($nspec refs pending; local snapshot kept)"
         [ "$DRY" = 1 ] && echo "REPO|$wd|$priv|$nspec pending|NO PUSH" >> "$RUN/table"
       fi
       return;;
  esac
  if [ "$DRY" = 1 ]; then
    echo "REPO|$wd|$priv|$nspec pending|would push $nspec ref(s)" >> "$RUN/table"
    while read -r a b c; do log "would-push: $a $b"; done < "$specs"
    return
  fi
  if safe_push "$wd" "$specs"; then
    while read -r sha dest marker; do git -C "$wd" update-ref "$marker" "$sha"; PUSHED=$((PUSHED+1)); done < "$specs"
    PUSHREPOS=$((PUSHREPOS+1)); log "PUSHED $nspec ref(s) from $wd"
  else
    PUSHFAIL=$((PUSHFAIL+1)); skip push-failed "$wd" "(see log)"
  fi
}

# Delete OLD backup branches on origin. Touches only refs/heads/backup/<this host>/*.
prune_repo() { # gd firstdir
  local gd=$1 first=$2 wd priv ref ct name dest cutoff n=0 tmpns="refs/parachute-prune"
  REPOS=$((REPOS+1))
  git -C "$first" worktree list --porcelain 2>/dev/null > "$RUN/wtl.$REPOS"
  wd=$(first_worktree "$RUN/wtl.$REPOS" "$first")
  priv=$(check_private "$wd")
  case "$priv" in private|local) ;; *) log "SKIP[$priv] prune for $wd"; return;; esac
  cutoff=$(( $(date +%s) - PRUNE_DAYS*86400 ))
  if ! tmo "$PUSH_TIMEOUT" git -C "$wd" fetch --no-tags --quiet origin "+refs/heads/backup/$HOST/*:$tmpns/*" >>"$LOG" 2>&1; then
    log "SKIP[fetch-failed] prune for $wd"; return
  fi
  while read -r ref ct; do
    [ "${ct:-0}" -lt "$cutoff" ] 2>/dev/null || continue
    name=${ref#"$tmpns"/}
    dest="refs/heads/backup/$HOST/$name"
    assert_dest "$dest" || continue
    case "$dest" in "refs/heads/backup/$HOST/"?*) ;; *) continue;; esac
    if [ "$DRY" = 1 ]; then log "would-prune: $dest ($wd)"
    elif tmo "$PUSH_TIMEOUT" git -C "$wd" push --no-verify --quiet origin ":$dest" >>"$LOG" 2>&1; then
      log "PRUNED $dest ($wd)"; PUSHED=$((PUSHED+1))
    else log "WARN prune push failed for $dest ($wd)"; fi
    n=$((n+1))
  done < <(git -C "$wd" for-each-ref --format='%(refname) %(committerdate:unix)' "$tmpns/")
  git -C "$wd" for-each-ref --format='%(refname)' "$tmpns/" | while read -r ref; do git -C "$wd" update-ref -d "$ref"; done
  [ "$n" -gt 0 ] && log "prune: $n old backup branch(es) matched in $wd"
  return 0
}

handle_wt() { # path gd specs
  local real
  real=$(cd "$1" 2>/dev/null && pwd -P) || { skip missing-dir "$1" ""; return; }
  grep -Fxq -- "$real" "$RUN/seen_wt" 2>/dev/null && return
  echo "$real" >> "$RUN/seen_wt"
  process_wt "$real" "$2" "$3"
}

handle_candidate() { # dir that contains .git
  local d=$1 gd
  if is_excluded "$d"; then skip excluded "$d" ""; return; fi
  gd=$(git -C "$d" rev-parse --git-common-dir 2>/dev/null) || { skip not-a-repo "$d" ""; return; }
  case "$gd" in /*) ;; *) gd=$d/$gd;; esac
  gd=$(cd "$gd" 2>/dev/null && pwd -P) || { skip bad-gitdir "$d" ""; return; }
  grep -Fxq -- "$gd" "$RUN/seen_gd" 2>/dev/null && return
  echo "$gd" >> "$RUN/seen_gd"
  if [ "$MODE" = prune ]; then prune_repo "$gd" "$d"; else process_repo "$gd" "$d"; fi
}

discover() {
  local r
  for r in "$@"; do
    if [ ! -d "$r" ]; then continue; fi
    if ! ls "$r" >/dev/null 2>&1; then log "WARN cannot read root '$r' (permission/TCC? see README)"; warn "cannot read root $r (macOS Full Disk Access?)"; continue; fi
    find "$r" -maxdepth "$MAX_DEPTH" \( -name node_modules -o -name .venv -o -name Pods -o -name .next -o -name DerivedData -o -name .cache \) -prune -o -name .git -prune -print 2>/dev/null
  done
}

rotate_log() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  local sz=0; [ -f "$LOG" ] && sz=$(wc -c < "$LOG" | tr -d ' ')
  [ "$sz" -gt "$LOG_MAX" ] && mv -f "$LOG" "$LOG.1"
  return 0
}

usage() {
  cat <<USAGE
parachute $VERSION - snapshot uncommitted git work to private backup/* branches

usage: parachute run [--dry-run] [--only <repo-path>] [--verbose]
                     [--prune-remote-older-than <days>]
       parachute restore [worktree-path | ref | sha]   (prints recovery commands)
       parachute status                                (human-readable status.json)
       parachute version
       parachute help
config: $CONFIG  (create it with scripts/install.sh)
status: $STATUS_FILE
USAGE
}

# ---- status.json (contract with the menu bar app; keys are fixed) ----------
json_str() { # escape for a JSON string body
  local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//[[:cntrl:]]/ }; printf '%s' "${s:0:160}"
}
jget() { # key  -> raw scalar (number/null/string without quotes) from STATUS_FILE
  [ -f "$STATUS_FILE" ] || return 0
  sed -n -e "s/^ *\"$1\": *\"\\([^\"]*\\)\".*/\\1/p" -e "s/^ *\"$1\": *\\([0-9][0-9]*\\).*/\\1/p" -e "s/^ *\"$1\": *\\(null\\).*/\\1/p" "$STATUS_FILE" | head -1
}
jnum() { local v; v=$(jget "$1"); case "$v" in ""|null|*[!0-9]*) printf 'null';; *) printf '%s' "$v";; esac; }
jcount() { local v; v=$(jget "$1"); case "$v" in ""|*[!0-9]*) printf 0;; *) printf '%s' "$v";; esac; }
jstrq() { local v; v=$(jget "$1"); case "$v" in ""|null) printf 'null';; *) printf '"%s"' "$(json_str "$v")";; esac; }

is_scheduled() {
  case "$SCHEDULED" in 1) return 0;; 0) return 1;; esac
  [ "$(uname -s 2>/dev/null)" = Darwin ] && [ -z "${PARACHUTE_NO_LAUNCHCTL:-}" ] || return 1
  launchctl list "$LABEL" >/dev/null 2>&1
}

# write_status state pid lastStart lastEnd lastResult repos wts snaps pushed skipped warnfile
# pid/lastStart/lastEnd: integer or "null"; lastResult: word or "null". Atomic: tmp in same dir, then mv.
write_status() {
  local state=$1 pid=$2 ls=$3 le=$4 lr=$5 nr=null w n=0 first=1 tmp
  [ "$lr" = null ] || lr="\"$lr\""
  if [ "$ls" != null ] && is_scheduled; then nr=$((ls+INTERVAL)); fi
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  tmp="$STATUS_FILE.tmp.$$"
  {
    printf '{\n  "version": 1,\n  "state": "%s",\n  "pid": %s,\n  "lastRunStart": %s,\n  "lastRunEnd": %s,\n  "lastResult": %s,\n' "$state" "$pid" "$ls" "$le" "$lr"
    printf '  "reposScanned": %s,\n  "worktreesScanned": %s,\n  "snapshots": %s,\n  "pushedRefs": %s,\n  "skipped": %s,\n' "$6" "$7" "$8" "$9" "${10}"
    printf '  "warnings": ['
    if [ -n "${11:-}" ] && [ -s "${11}" ]; then
      while IFS= read -r w; do
        [ "$n" -ge 20 ] && break
        [ "$first" = 1 ] || printf ','
        printf '\n    "%s"' "$(json_str "$w")"; first=0; n=$((n+1))
      done < <(awk '!s[$0]++' "${11}")
      printf '\n  '
    fi
    printf '],\n  "nextRunEpoch": %s\n}\n' "$nr"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATUS_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# A status that says running with a dead pid (SIGKILL, power loss) is stale:
# record it as an errored run so the next write keeps an honest lastResult.
recover_stale_status() {
  local st pid
  [ -f "$STATUS_FILE" ] || return 0
  st=$(jget state); pid=$(jget pid)
  [ "$st" = running ] || return 0
  case "$pid" in ""|null|*[!0-9]*) ;; *) kill -0 "$pid" 2>/dev/null && return 0;; esac
  log "stale status (state=running, pid=${pid:-?} dead): marking last run as error"
  write_status idle null "$(jnum lastRunStart)" "$(date +%s)" error "$(jcount reposScanned)" "$(jcount worktreesScanned)" "$(jcount snapshots)" "$(jcount pushedRefs)" "$(jcount skipped)" ""
}

status_begin() {
  recover_stale_status
  PRIOR_END=$(jnum lastRunEnd); PRIOR_RES=$(jstrq lastResult); PRIOR_RES=${PRIOR_RES//\"/}
  RUN_START=$(date +%s); STATUS_ON=1
  write_status running $$ "$RUN_START" "$PRIOR_END" "$PRIOR_RES" "$(jcount reposScanned)" "$(jcount worktreesScanned)" "$(jcount snapshots)" "$(jcount pushedRefs)" "$(jcount skipped)" ""
}

status_finish() { # rc
  local rc=$1 res total
  [ "$STATUS_ON" = 1 ] && [ "$STATUS_DONE" = 0 ] || return 0
  STATUS_DONE=1
  total=$(wc -l < "$RUN/skips" 2>/dev/null | tr -d ' '); total=${total:-0}
  if [ "$rc" -ne 0 ]; then res=error
  elif [ "${PUSHFAIL:-0}" -gt 0 ] && [ "${PUSHREPOS:-0}" -eq 0 ]; then res=error
  elif [ -s "$RUN/warnings" ] || [ "$total" -gt 0 ]; then res=partial
  else res=ok; fi
  if [ "$rc" -ne 0 ]; then
    [ -s "$RUN/warnings" ] || warn "run aborted (exit $rc); see log"
    write_status error null "$RUN_START" "$(date +%s)" error "${REPOS:-0}" "${WTS:-0}" "${SNAPS:-0}" "${PUSHED:-0}" "$total" "$RUN/warnings"
  else
    write_status idle null "$RUN_START" "$(date +%s)" "$res" "${REPOS:-0}" "${WTS:-0}" "${SNAPS:-0}" "${PUSHED:-0}" "$total" "$RUN/warnings"
  fi
}

on_exit() {
  local rc=$?
  status_finish "$rc"
  rm -f "$STATUS_FILE.tmp.$$" 2>/dev/null
  rm -rf "${RUN:-}" "${LOCK:-}"
}

cmd_status() {
  local st pid ls le lr nr w
  if [ ! -f "$STATUS_FILE" ]; then echo "parachute: no status yet ($STATUS_FILE not found; no pass has run)"; return 0; fi
  st=$(jget state); pid=$(jget pid); ls=$(jget lastRunStart); le=$(jget lastRunEnd); lr=$(jget lastResult); nr=$(jget nextRunEpoch)
  fmt() { case "$1" in ""|null) printf 'never';; *) date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$1";; esac; }
  echo "parachute status ($STATUS_FILE)"
  printf '  state:         %s' "$st"
  if [ "$st" = running ]; then
    case "$pid" in ""|null) ;; *) if kill -0 "$pid" 2>/dev/null; then printf ' (pid %s)' "$pid"; else printf ' (pid %s is dead: STALE, last run did not finish)' "$pid"; fi;; esac
  fi
  echo
  echo "  last start:    $(fmt "$ls")"
  echo "  last end:      $(fmt "$le")"
  echo "  last result:   ${lr:-null}"
  echo "  repos:         $(jcount reposScanned) scanned, $(jcount worktreesScanned) worktrees"
  echo "  snapshots:     $(jcount snapshots)   pushed refs: $(jcount pushedRefs)   skipped: $(jcount skipped)"
  echo "  next run:      $(fmt "$nr") $( [ -z "$nr" ] || [ "$nr" = null ] && echo '(not scheduled)')"
  w=$(sed -n '/"warnings": \[/,/^  \]/p' "$STATUS_FILE" | sed -n 's/^ *"\(.*\)",\{0,1\}$/\1/p')
  if [ -n "$w" ]; then echo "  warnings:"; printf '%s\n' "$w" | sed 's/^/    - /'; else echo "  warnings:      none"; fi
}

load_config() {
  if [ ! -f "$CONFIG" ]; then
    echo "parachute: no config at $CONFIG" >&2
    echo "Run scripts/install.sh (e.g. install.sh --roots ~/code) to create one." >&2
    exit 78
  fi
  # shellcheck disable=SC1090
  . "$CONFIG"
  if [ "${#ROOTS[@]}" -eq 0 ]; then
    echo "parachute: ROOTS is empty in $CONFIG; nothing to scan." >&2; exit 78
  fi
  case "$MAX_FILE_MB$TIP_DAYS$MAX_DEPTH$INTERVAL" in *[!0-9]*|"") echo "parachute: MAX_FILE_MB/TIP_DAYS/MAX_DEPTH/INTERVAL must be integers" >&2; exit 78;; esac
  [ -n "$BACKUP_NAMESPACE" ] || BACKUP_NAMESPACE="$(hostname -s 2>/dev/null || hostname)"
  HOST=$(san "$BACKUP_NAMESPACE")
}

resolve_self_dir() { # dir of this script with symlinks resolved (bash 3.2: no readlink -f)
  local s="${BASH_SOURCE[0]:-$0}" d
  while [ -L "$s" ]; do
    d=$(cd "$(dirname "$s")" && pwd -P); s=$(readlink "$s")
    case "$s" in /*) ;; *) s="$d/$s";; esac
  done
  (cd "$(dirname "$s")" && pwd -P)
}

main() {
  local sub="${1:-help}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    run) ;;
    restore) exec bash "$(resolve_self_dir)/parachute-restore.sh" "$@";;
    status) cmd_status; exit 0;;
    version|--version|-V) echo "parachute $VERSION"; exit 0;;
    help|-h|--help) usage; exit 0;;
    *) echo "parachute: unknown command '$sub'" >&2; usage >&2; exit 64;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY=1; VERBOSE=1;;
      --only) shift; ONLY="${1:-}"; VERBOSE=1;;
      --verbose) VERBOSE=1;;
      --prune-remote-older-than)
        shift; PRUNE_DAYS="${1:-}"
        case "$PRUNE_DAYS" in ""|*[!0-9]*|0) echo "days must be an integer >= 1" >&2; exit 64;; esac
        MODE=prune;;
      -h|--help) usage; exit 0;;
      *) usage; exit 64;;
    esac; shift
  done
  load_config
  rotate_log
  mkdir -p "$STATE_DIR"
  LOCK="$STATE_DIR/lock"
  if ! mkdir "$LOCK" 2>/dev/null; then
    local op; op=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$op" ] && kill -0 "$op" 2>/dev/null; then log "another run active (pid $op); exiting"; exit 0; fi
    rm -rf "$LOCK"; mkdir "$LOCK" || exit 1
  fi
  echo $$ > "$LOCK/pid"
  RUN=$(mktemp -d "${TMPDIR:-/tmp}/parachute.XXXXXX")
  trap on_exit EXIT
  trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
  : > "$RUN/skips"; : > "$RUN/table"; : > "$RUN/seen_gd"; : > "$RUN/seen_wt"; : > "$RUN/warnings"
  REPOS=0; WTS=0; DIRTY=0; SNAPS=0; UNCH=0; CLEAN=0; PUSHED=0; PUSHREPOS=0; PUSHFAIL=0; TIPS=0
  # status.json: real backup passes only (not --dry-run, not prune)
  if [ "$DRY" = 0 ] && [ "$MODE" = backup ]; then status_begin; fi
  local start; start=$(date +%s)
  log "=== run start mode=$MODE dry=$DRY only='${ONLY}' namespace=$HOST ==="

  local cand
  if [ -n "$ONLY" ]; then
    local top; top=$(git -C "$ONLY" rev-parse --show-toplevel 2>/dev/null) || { log "ERROR --only '$ONLY' is not a git repo"; exit 1; }
    handle_candidate "$top"
  else
    local roots=() r
    for r in "${ROOTS[@]}" ${EXTRA_ROOTS[@]+"${EXTRA_ROOTS[@]}"}; do
      case "$r" in "~"/*) r="$HOME/${r#\~/}";; esac
      roots+=("$r")
    done
    while IFS= read -r cand; do handle_candidate "$(dirname "$cand")"; done < <(discover "${roots[@]}")
  fi

  local reasons total
  total=$(wc -l < "$RUN/skips" | tr -d ' ')
  reasons=$(sort "$RUN/skips" | uniq -c | awk '{printf "%s%s=%s",(NR>1?",":""),$2,$1}')
  if [ "$DRY" = 1 ] && [ "$MODE" = backup ]; then
    echo; echo "DRY-RUN TABLE (kind|path|branch/remote|state|action)"
    if command -v column >/dev/null 2>&1; then column -t -s'|' "$RUN/table"; else cat "$RUN/table"; fi
    echo
  fi
  log "SUMMARY repos=$REPOS worktrees=$WTS dirty=$DIRTY snapshots=$SNAPS unchanged=$UNCH clean=$CLEAN unpushed_tips=$TIPS pushed_refs=$PUSHED(repos=$PUSHREPOS) skipped=$total${reasons:+ [$reasons]} dry=$DRY secs=$(( $(date +%s)-start ))"
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then main "$@"; fi
