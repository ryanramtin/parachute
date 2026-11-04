#!/usr/bin/env bash
# Self-contained test: throwaway repos + a local bare origin under mktemp -d.
# Touches nothing outside the temp dir. Exits nonzero on any failure.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BK="$HERE/../scripts/parachute.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@localhost GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@localhost
export PARACHUTE_CONFIG="$T/config" PARACHUTE_LOG="$T/test.log" PARACHUTE_STATE="$T/state"
FAILS=0; PASSES=0
ok()   { PASSES=$((PASSES+1)); echo "  ok   - $1"; }
fail() { FAILS=$((FAILS+1)); echo "  FAIL - $1"; }
check() { # desc cmd...
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi
}

bash -n "$BK" || { echo "syntax error in parachute.sh"; exit 2; }
for f in "$HERE"/../scripts/*.sh; do bash -n "$f" || { echo "syntax error in $f"; exit 2; }; done
NS=testhost
mkdir -p "$T/roots"
cat > "$T/config" <<CFG
ROOTS=("$T/roots")
MAX_FILE_MB=1
BACKUP_NAMESPACE=$NS
CFG

git init -q --bare "$T/origin.git"
R="$T/roots/proj"
git init -q -b main "$R"
git -C "$R" remote add origin "$T/origin.git"
echo one > "$R/tracked.txt"; printf 'ignored/\n' > "$R/.gitignore"
git -C "$R" add -A; git -C "$R" commit -q -m init; git -C "$R" push -q origin main
git -C "$R" checkout -q -b feat; echo f > "$R/feat.txt"; git -C "$R" add feat.txt; git -C "$R" commit -q -m feat
git -C "$R" checkout -q main
# dirty state
echo two >> "$R/tracked.txt"
echo new > "$R/untracked.txt"
echo s > "$R/.env"; echo s > "$R/.env.production"; echo s > "$R/server.pem"
echo ex > "$R/.env.example"
mkdir -p "$R/ignored"; echo i > "$R/ignored/x.txt"
head -c 2097152 /dev/zero > "$R/big.bin"
git -C "$R" add tracked.txt   # partially staged on purpose

snapstate() { git -C "$R" status --porcelain=v2 --untracked-files=all; git -C "$R" rev-parse HEAD; shasum "$R/.git/index"; }
BEFORE="$(snapstate)"

echo "== run 1: snapshot + push"
bash "$BK" run --verbose >"$T/run1.out" 2>&1; rc=$?
[ $rc -eq 0 ] && ok "run 1 exits 0" || { fail "run 1 exits 0 (rc=$rc)"; cat "$T/run1.out"; }
SNAP=refs/backup/main/proj
files="$(git -C "$R" ls-tree -r --name-only "$SNAP" 2>/dev/null)"
has() { printf '%s\n' "$files" | grep -Fxq -- "$1"; }
check "snapshot ref exists"                git -C "$R" rev-parse -q --verify "$SNAP"
check "snapshot has tracked.txt"           has tracked.txt
check "snapshot has untracked.txt"         has untracked.txt
check "snapshot has .env.example (not secret)" has .env.example
check "snapshot tracked.txt carries edit"  test "$(git -C "$R" show "$SNAP:tracked.txt" | wc -l | tr -d ' ')" = 2
! has .env            && ok "excludes .env"            || fail "excludes .env"
! has .env.production && ok "excludes .env.production" || fail "excludes .env.production"
! has server.pem      && ok "excludes server.pem"      || fail "excludes server.pem"
! has ignored/x.txt   && ok "excludes ignored dir"     || fail "excludes ignored dir"
! has big.bin         && ok "excludes >MAX_FILE_MB file" || fail "excludes >MAX_FILE_MB file"
[ "$BEFORE" = "$(snapstate)" ] && ok "status/HEAD/index unchanged" || fail "status/HEAD/index unchanged"

echo "== remote contents"
remote_refs="$(git --git-dir="$T/origin.git" for-each-ref --format='%(refname)')"
echo "$remote_refs" | sed 's/^/    /'
check "snapshot pushed under backup/$NS/"  git --git-dir="$T/origin.git" rev-parse -q --verify "refs/heads/backup/$NS/main--proj"
check "unpushed branch tip pushed"         git --git-dir="$T/origin.git" rev-parse -q --verify "refs/heads/backup/$NS/feat--branch-tip"
others="$(echo "$remote_refs" | grep -v '^refs/heads/backup/' | sort | tr '\n' ' ')"
[ "$others" = "refs/heads/main " ] && ok "only main + backup/* exist on origin" || fail "unexpected refs on origin: $others"
check "origin main untouched"              test "$(git --git-dir="$T/origin.git" rev-parse refs/heads/main)" = "$(git -C "$R" rev-parse HEAD)"

echo "== run 2: no-op"
REFS1="$remote_refs"; SHA1="$(git --git-dir="$T/origin.git" for-each-ref --format='%(refname) %(objectname)')"
bash "$BK" run --verbose >"$T/run2.out" 2>&1
grep -q 'snapshots=0 .*pushed_refs=0' "$T/run2.out" && ok "second run: 0 snapshots, 0 pushes" || { fail "second run no-op"; cat "$T/run2.out"; }
[ "$SHA1" = "$(git --git-dir="$T/origin.git" for-each-ref --format='%(refname) %(objectname)')" ] && ok "remote refs identical after run 2" || fail "remote refs identical after run 2"

echo "== dry-run writes nothing"
echo more > "$R/another.txt"
bash "$BK" run --dry-run >"$T/dry.out" 2>&1
check "dry-run mentions would snapshot"    grep -q 'would snapshot' "$T/dry.out"
[ "$SHA1" = "$(git --git-dir="$T/origin.git" for-each-ref --format='%(refname) %(objectname)')" ] && ok "dry-run left origin untouched" || fail "dry-run left origin untouched"
check "dry-run did not snapshot new file"  test -z "$(git -C "$R" ls-tree -r --name-only "$SNAP" | grep -Fx another.txt)"

echo "== guard (sourced functions)"
GS="$(git -C "$R" rev-parse HEAD)"
guard() { ( . "$BK"; assert_refspec "$@" ) >/dev/null 2>&1; }
guard "$GS" refs/heads/backup/h/x             && ok "guard accepts refs/heads/backup/h/x"      || fail "guard accepts good dest"
guard "$GS" refs/heads/main                   && fail "guard rejects refs/heads/main"          || ok "guard rejects refs/heads/main"
guard "$GS" refs/tags/x                       && fail "guard rejects refs/tags/x"              || ok "guard rejects refs/tags/x"
guard "$GS" refs/heads/backupx/y              && fail "guard rejects refs/heads/backupx/y"     || ok "guard rejects refs/heads/backupx/y"
guard "$GS" refs/heads/backup/                && fail "guard rejects empty backup/ dest"       || ok "guard rejects empty backup/ dest"
guard "$GS" refs/heads/backup/../main         && fail "guard rejects .. traversal"             || ok "guard rejects .. traversal"
guard "$GS" refs/heads/backup/a:refs/heads/main && fail "guard rejects embedded colon"         || ok "guard rejects embedded colon"
guard "main" refs/heads/backup/h/x            && fail "guard rejects non-sha source"           || ok "guard rejects non-sha source"
# mixed batch: one good + one bad => whole push aborted, nothing lands
printf '%s refs/heads/backup/%s/good-in-mixed m1\n%s refs/heads/main m2\n' "$GS" "$NS" "$GS" > "$T/spec.mixed"
( . "$BK"; safe_push "$R" "$T/spec.mixed" ) >/dev/null 2>&1; mrc=$?
[ $mrc -ne 0 ] && ok "mixed batch rejected (rc=$mrc)" || fail "mixed batch rejected"
check "mixed batch: good ref did not land" test -z "$(git --git-dir="$T/origin.git" for-each-ref "refs/heads/backup/$NS/good-in-mixed")"
printf '%s refs/tags/x m\n' "$GS" > "$T/spec.tag"
( . "$BK"; safe_push "$R" "$T/spec.tag" ) >/dev/null 2>&1 && fail "tag push rejected" || ok "tag push rejected"
check "no tag on origin" test -z "$(git --git-dir="$T/origin.git" for-each-ref refs/tags)"
check "origin main still untouched" test "$(git --git-dir="$T/origin.git" rev-parse refs/heads/main)" = "$(git -C "$R" rev-parse HEAD)"

echo "== prune only touches own namespace"
OLD="$(GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' git -C "$R" commit-tree "$(git -C "$R" rev-parse 'HEAD^{tree}')" -m old)"
git -C "$R" push -q origin "$OLD:refs/heads/backup/$NS/old--x" "$OLD:refs/heads/backup/otherhost/old--x" "$OLD:refs/heads/keep-me"
bash "$BK" run --prune-remote-older-than 30 --verbose >"$T/prune.out" 2>&1
check "old own-namespace branch pruned"    test -z "$(git --git-dir="$T/origin.git" for-each-ref "refs/heads/backup/$NS/old--x")"
check "other namespace's old branch kept"  git --git-dir="$T/origin.git" rev-parse -q --verify refs/heads/backup/otherhost/old--x
check "non-backup old branch kept"         git --git-dir="$T/origin.git" rev-parse -q --verify refs/heads/keep-me
check "fresh snapshot kept"                git --git-dir="$T/origin.git" rev-parse -q --verify "refs/heads/backup/$NS/main--proj"
check "origin main still present"          git --git-dir="$T/origin.git" rev-parse -q --verify refs/heads/main

echo "== status.json"
SF="$PARACHUTE_STATE/status.json"
jq_py() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$SF" "$1" 2>/dev/null; }
if command -v python3 >/dev/null 2>&1; then
  jchk() { # desc python-expr-that-must-be-true
    [ "$(jq_py "$2")" = True ] && ok "$1" || fail "$1"
  }
else
  jchk() { ok "$1 (skipped: no python3)"; }
fi
# state after run 1 (a real, partially-skipped-free pass; run 2 already overwrote it with a no-op pass)
check "status.json exists"                 test -f "$SF"
check "no leftover tmp files"              test -z "$(ls "$PARACHUTE_STATE" | grep 'status.json.tmp')"
jchk "valid JSON, exact key set"           "sorted(d.keys())==sorted(['version','state','pid','lastRunStart','lastRunEnd','lastResult','reposScanned','worktreesScanned','snapshots','pushedRefs','skipped','warnings','nextRunEpoch'])"
jchk "idle after finish, pid null"         "d['version']==1 and d['state']=='idle' and d['pid'] is None"
jchk "lastRunStart/End are ints, end>=start" "isinstance(d['lastRunStart'],int) and isinstance(d['lastRunEnd'],int) and d['lastRunEnd']>=d['lastRunStart']"
jchk "counts are ints, repos>=1"           "all(isinstance(d[k],int) for k in ['reposScanned','worktreesScanned','snapshots','pushedRefs','skipped']) and d['reposScanned']>=1"
jchk "ok result, empty warnings, unscheduled nextRunEpoch null" "d['lastResult']=='ok' and d['warnings']==[] and d['nextRunEpoch'] is None"

# running state (deterministic: drive the status functions directly, no timing race)
( . "$BK"; STATUS_FILE="$SF"; STATE_DIR="$PARACHUTE_STATE"; INTERVAL=600; RUN="$T/fakerun"; mkdir -p "$RUN"; : > "$RUN/skips"; : > "$RUN/warnings"; log() { :; }
  status_begin; cp "$SF" "$T/status.running"; status_finish 0 )
jq_run() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$T/status.running" "$1" 2>/dev/null; }
[ "$(jq_run "d['state']=='running' and isinstance(d['pid'],int) and isinstance(d['lastRunStart'],int)")" = True ] && ok "status is running with pid + lastRunStart during a pass" || fail "running state"
jchk "finish after begin: idle, pid null"  "d['state']=='idle' and d['pid'] is None"

# unknown-remote repo (classified, not pushed) => partial + warning, scheduled => nextRunEpoch
R2="$T/roots/slow"; git init -q -b main "$R2"; echo a > "$R2/a"; git -C "$R2" add -A; git -C "$R2" commit -q -m i; echo b >> "$R2/a"
git -C "$R2" remote add origin "https://example.invalid/acme/none.git"
rm -f "$SF"
PARACHUTE_SCHEDULED=1 bash "$BK" run --only "$R2" >/dev/null 2>&1
jchk "final state idle, pid null"          "d['state']=='idle' and d['pid'] is None"
jchk "scheduled => nextRunEpoch = start+INTERVAL" "d['nextRunEpoch']==d['lastRunStart']+600"
jchk "skipped public/unknown remote => partial + warning" "d['lastResult']=='partial' and d['skipped']>=1 and any(w.startswith('skipped ') and w.endswith(' repo slow') for w in d['warnings'])"

# trap: a failed pass must not leave state=running
bash "$BK" run --only "$T/not-a-repo" >/dev/null 2>&1; frc=$?
[ $frc -ne 0 ] && ok "failed pass exits nonzero" || fail "failed pass exits nonzero"
jchk "failed pass: pid null, not running, lastResult error" "d['state']!='running' and d['pid'] is None and d['lastResult']=='error'"

# stale pid recovery
cat > "$SF" <<'STALE'
{
  "version": 1,
  "state": "running",
  "pid": 2999999,
  "lastRunStart": 1700000000,
  "lastRunEnd": 1699999000,
  "lastResult": "ok",
  "reposScanned": 3,
  "worktreesScanned": 3,
  "snapshots": 1,
  "pushedRefs": 1,
  "skipped": 0,
  "warnings": [],
  "nextRunEpoch": null
}
STALE
bash "$BK" status 2>&1 | grep -q 'STALE' && ok "status flags dead-pid running state as STALE" || fail "status flags stale"
( . "$BK"; STATUS_FILE="$SF"; STATE_DIR="$PARACHUTE_STATE"; INTERVAL=600; recover_stale_status )
jchk "stale recovery: idle, pid null, lastResult error, counts kept" "d['state']=='idle' and d['pid'] is None and d['lastResult']=='error' and d['lastRunStart']==1700000000 and d['reposScanned']==3"
# a live pass over a stale file also ends idle
sed -i.bak 's/"state": "idle"/"state": "running"/; s/"pid": null/"pid": 2999999/' "$SF"; rm -f "$SF.bak"
bash "$BK" run >/dev/null 2>&1
jchk "pass over stale running file ends idle"  "d['state']=='idle' and d['pid'] is None and d['lastRunStart']>1700000000"

# dry-run does not touch status
cp "$SF" "$T/status.before"
echo dirty >> "$R/another.txt"
bash "$BK" run --dry-run >/dev/null 2>&1
cmp -s "$SF" "$T/status.before" && ok "dry-run leaves status.json byte-identical" || fail "dry-run leaves status.json byte-identical"
rm -f "$SF"; bash "$BK" run --dry-run >/dev/null 2>&1
[ ! -e "$SF" ] && ok "dry-run creates no status.json" || fail "dry-run creates no status.json"

# local-path remote counts as allowed; no-origin repo => warning
R3="$T/roots/noorigin"; git init -q -b main "$R3"; echo a > "$R3/a"; git -C "$R3" add -A; git -C "$R3" commit -q -m i; echo b >> "$R3/a"
bash "$BK" run >/dev/null 2>&1
jchk "no-origin repo warned, local-path repo not warned" "any(w=='skipped no-origin repo noorigin' for w in d['warnings']) and not any('proj' in w for w in d['warnings'])"
jchk "warnings max 20 and all strings"     "len(d['warnings'])<=20 and all(isinstance(w,str) for w in d['warnings'])"

echo "== CLI"
out="$(bash "$BK" 2>&1)"; echo "$out" | grep -q 'usage: parachute run' && ok "no args prints help" || fail "no args prints help"
bash "$BK" version | grep -q '^parachute [0-9]' && ok "version" || fail "version"
bash "$BK" status | grep -q 'last result' && ok "status prints human-readable" || fail "status prints"
bash "$BK" bogus >/dev/null 2>&1 && fail "unknown subcommand rejected" || ok "unknown subcommand rejected"
bash "$BK" restore "$R" | grep -q 'Snapshots for worktree' && ok "restore subcommand dispatches" || fail "restore subcommand"

echo "== install.sh / uninstall.sh (sandboxed; launchctl disabled)"
SH="$HERE/../scripts"
export PARACHUTE_BIN_DIR="$T/bin" PARACHUTE_LAUNCHAGENTS_DIR="$T/agents" PARACHUTE_NO_LAUNCHCTL=1
mkdir -p "$T/ins"; echo 'x' > "$T/bin.marker"
PARACHUTE_CONFIG="$T/ins/config" bash "$SH/install.sh" --roots "$T/ins" >"$T/inst1.out" 2>&1; irc=$?
[ $irc -eq 0 ] && ok "install.sh exits 0" || { fail "install.sh exits 0 (rc=$irc)"; cat "$T/inst1.out"; }
[ -L "$T/bin/parachute" ] && [ "$(readlink "$T/bin/parachute")" = "$(cd "$SH" && pwd -P)/parachute.sh" ] && ok "CLI symlink -> scripts/parachute.sh" || fail "CLI symlink"
"$T/bin/parachute" version | grep -q '^parachute' && ok "symlinked CLI runs" || fail "symlinked CLI runs"
"$T/bin/parachute" restore "$R" | grep -q 'Snapshots for worktree' && ok "symlinked CLI resolves restore script" || fail "symlinked restore"
PARACHUTE_CONFIG="$T/ins/config" bash "$SH/install.sh" >"$T/inst2.out" 2>&1
[ -L "$T/bin/parachute" ] && ok "install.sh idempotent (symlink intact)" || fail "install idempotent"
if [ "$(uname -s)" = Darwin ]; then
  check "plist rendered with label dev.parachute and run arg" sh -c "grep -q '<string>dev.parachute</string>' '$T/agents/dev.parachute.plist' && grep -q '<string>run</string>' '$T/agents/dev.parachute.plist'"
fi
printf 'keep' > "$T/bin2file"; mkdir -p "$T/bin2"; echo real > "$T/bin2/parachute"
PARACHUTE_BIN_DIR="$T/bin2" PARACHUTE_CONFIG="$T/ins/config" bash "$SH/install.sh" >/dev/null 2>&1
[ "$(cat "$T/bin2/parachute")" = real ] && ok "install.sh never clobbers a real file" || fail "install clobbered a real file"
bash "$SH/uninstall.sh" >"$T/un.out" 2>&1
[ ! -e "$T/bin/parachute" ] && ok "uninstall removes the symlink" || fail "uninstall removes the symlink"
[ "$(cat "$T/bin2/parachute")" = real ] && ok "uninstall leaves non-symlink alone" || fail "uninstall removed a real file"
check "uninstall leaves config alone"      test -f "$T/ins/config"

echo "== refuses to run without config"
PARACHUTE_CONFIG="$T/nonexistent" bash "$BK" run >/dev/null 2>&1 && fail "refuses without config" || ok "refuses without config"

echo
echo "passed=$PASSES failed=$FAILS"
[ "$FAILS" -eq 0 ]
