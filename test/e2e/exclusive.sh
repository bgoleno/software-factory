# Sourced by test/e2e.sh, in its shell and in the order of AREAS there (#70); not run alone.
# run-exclusive (#214): one heavy run at a time on the host. Every case uses the run's own lock
# (FACTORY_RUN_LOCK, set by test/e2e.sh), never the real one. Ordering is checked only from marks the
# commands record, never from how long anything took: these runs are meant for a loaded machine.
echo "--- run-exclusive: one heavy run at a time (#214)"
rx=$T/rx; mkdir -p $rx
# Waits for a condition, up to 30s (a limit for a run that went wrong, not a timing check).
rx_until() { local i=0; until eval "$1"; do i=$((i + 1)); [ $i -ge 150 ] && return 1; sleep 0.2; done; }
# A holder (a script: run-exclusive runs a program) that records its start, then waits for a go file
# before it records its end: hold <name> <marks> <go file>.
printf '#!/bin/sh\necho "$1 start" >> "$2"\nuntil [ -e "$3" ]; do sleep 0.1; done\necho "$1 end" >> "$2"\n' > $rx/hold; chmod +x $rx/hold
real="$(ruby -retc -e 'print Etc.getpwuid(Process.uid).dir')/Library/Application Support/software-factory"; [ -e "$real" ] && real_was=1 || real_was=0

out=$($S run-exclusive -- sh -c 'echo ran; exit 7' 2>&1); rc=$?
[ $rc = 7 ] && [ "$out" = ran ] && ok "run-exclusive runs the command and exits with its status" || { bad "run-exclusive status (rc=$rc)"; echo "$out" | tail -2; }
out=$(TEAM_CONFIG=$T/no-such-team.yaml $S run-exclusive -- true 2>&1); rc=$?
[ $rc = 0 ] && [ -z "$out" ] && ok "run-exclusive needs no team file, and prints nothing when the lock is free" || { bad "run-exclusive without a team file (rc=$rc)"; echo "$out" | tail -2; }
out=$($S run-exclusive -- 'echo not a shell' 2>&1); rc=$?
[ $rc = 127 ] && ok "run-exclusive runs an argument list, never a shell string" || { bad "run-exclusive ran a shell string (rc=$rc)"; echo "$out" | tail -2; }

# Two runs wait while a third holds the lock; each says who holds it and since when; none overlaps.
m=$rx/marks; rm -f $rx/go
TEAM_ROLE=hx $S run-exclusive -- $rx/hold H $m $rx/go 2>$rx/h.err &
h=$!
rx_until "grep -q 'H start' $m 2>/dev/null"
for w in W1 W2; do
  TEAM_ROLE=$w $S run-exclusive -- sh -c 'echo "$0 start" >> "$1"; echo "$0 end" >> "$1"' $w $m 2>$rx/$w.err &
  eval "p$w=\$!"
done
rx_until "grep -q 'waiting for the lock' $rx/W1.err && grep -q 'waiting for the lock' $rx/W2.err"; waiting=$?
before=$(cat $m 2>/dev/null)
touch $rx/go; wait $h; hrc=$?; wait $pW1; w1rc=$?; wait $pW2; w2rc=$?
# Each start is followed at once by its own end, H's first.
pairs=$(awk '{ if (NR % 2) { r = $1; if ($2 != "start") bad = 1 } else if ($1 != r || $2 != "end") bad = 1 } END { print (bad || NR != 6) ? "overlap" : "ok" }' $m 2>/dev/null)
[ $waiting = 0 ] && [ "$before" = "H start" ] && [ $hrc = 0 ] && [ $w1rc = 0 ] && [ $w2rc = 0 ] && [ "$pairs" = ok ] && [ "$(head -n 1 $m)" = "H start" ] \
  && ok "run-exclusive: two runs wait for the holder, then run one at a time, none overlapping" || { bad "run-exclusive: two waiting runs (waiting=$waiting h=$hrc w1=$w1rc w2=$w2rc)"; cat $m; cat $rx/W1.err $rx/W2.err; }
grep -q "held by hx[^(]* (pid [0-9]*, in .*), holding since [0-9-]*T[0-9:]*: $rx/hold H" $rx/W1.err && grep -q 'got the lock after' $rx/W1.err \
  && ok "run-exclusive: a waiting run says who holds the lock, since when, and when it got it" || { bad "run-exclusive: the waiting message"; cat $rx/W1.err; }

# A killed holder: TERM ends its command too, and releases the lock.
rm -f $rx/go $rx/k.pid
$S run-exclusive -- sh -c 'echo $$ > "$0"; while :; do sleep 0.2; done' $rx/k.pid 2>/dev/null &
h=$!
rx_until "[ -s $rx/k.pid ]"
$S run-exclusive -- sh -c 'echo ran > "$0"' $rx/k.ran 2>$rx/k.err &
w=$!
rx_until "grep -q 'waiting for the lock' $rx/k.err"; waiting=$?
kill -TERM $h; wait $h; hrc=$?; wait $w; wrc=$?
rx_until "! kill -0 $(cat $rx/k.pid) 2>/dev/null"; gone=$?
[ $waiting = 0 ] && [ $hrc = 143 ] && [ $wrc = 0 ] && [ "$(cat $rx/k.ran 2>/dev/null)" = ran ] && [ $gone = 0 ] \
  && ok "run-exclusive: TERM to the holder ends its command and releases the lock to the waiting run" || { bad "run-exclusive: TERM to the holder (waiting=$waiting h=$hrc w=$wrc gone=$gone)"; cat $rx/k.err; }
# SIGKILL: the kernel drops the lock, so the waiting run starts. (The killed run's command is orphaned
# and may still run: documented. It is ended here by hand.)
rm -f $rx/k.pid $rx/k.ran
$S run-exclusive -- sh -c 'echo $$ > "$0"; while :; do sleep 0.2; done' $rx/k.pid 2>/dev/null &
h=$!
rx_until "[ -s $rx/k.pid ]"
$S run-exclusive -- sh -c 'echo ran > "$0"' $rx/k.ran 2>$rx/k.err &
w=$!
rx_until "grep -q 'waiting for the lock' $rx/k.err"; waiting=$?
kill -KILL $h; wait $h 2>/dev/null; wait $w; wrc=$?
kill $(cat $rx/k.pid) 2>/dev/null
[ $waiting = 0 ] && [ $wrc = 0 ] && [ "$(cat $rx/k.ran 2>/dev/null)" = ran ] \
  && ok "run-exclusive: a holder killed with SIGKILL releases the lock to the waiting run" || { bad "run-exclusive: SIGKILL to the holder (waiting=$waiting w=$wrc)"; cat $rx/k.err; }

# A holder record whose pid is gone (a SIGKILLed run leaves its record) names no one.
rm -f $rx/go
$S run-exclusive -- $rx/hold U $rx/u.marks $rx/go 2>/dev/null &
h=$!
rx_until "grep -q 'U start' $rx/u.marks 2>/dev/null"
sh -c 'exit 0' & dead=$!; wait $dead
printf '{"pid":%s,"who":"gone","since":"2000-01-01T00:00:00","cwd":"/","cmd":"x"}' $dead > $FACTORY_RUN_LOCK.holder
$S run-exclusive -- true 2>$rx/u.err &
w=$!
rx_until "grep -q 'waiting for the lock' $rx/u.err"
touch $rx/go; wait $h; wait $w
grep -q 'held by an unknown holder' $rx/u.err && ! grep -q 'gone' $rx/u.err \
  && ok "run-exclusive: a holder record whose pid is gone shows an unknown holder" || { bad "run-exclusive: a dead holder record"; cat $rx/u.err; }

# Nesting: a run-exclusive inside the command of another runs at once, instead of waiting for itself.
out=$($S run-exclusive -- $S run-exclusive -- sh -c 'echo nested' 2>&1); rc=$?
[ $rc = 0 ] && [ "$out" = nested ] && ok "run-exclusive inside run-exclusive runs at once (no wait for itself)" || { bad "nested run-exclusive (rc=$rc)"; echo "$out" | tail -2; }
# A stale variable (left in a tmux server started under the lock) whose pid is gone still waits.
rm -f $rx/go $rx/s.ran
$S run-exclusive -- $rx/hold S $rx/s.marks $rx/go 2>/dev/null &
h=$!
rx_until "grep -q 'S start' $rx/s.marks 2>/dev/null"
FACTORY_RUN_EXCLUSIVE_HELD=$FACTORY_RUN_LOCK:$dead $S run-exclusive -- sh -c 'echo ran > "$0"' $rx/s.ran 2>$rx/s.err &
w=$!
rx_until "grep -q 'waiting for the lock' $rx/s.err"; waiting=$?
early=$(cat $rx/s.ran 2>/dev/null)
touch $rx/go; wait $h; wait $w
[ $waiting = 0 ] && [ -z "$early" ] && [ "$(cat $rx/s.ran 2>/dev/null)" = ran ] \
  && ok "run-exclusive: a stale FACTORY_RUN_EXCLUSIVE_HELD whose holder is gone does not skip the lock" || { bad "run-exclusive: stale held variable (waiting=$waiting early=$early)"; cat $rx/s.err; }

# The lock is never taken through a link (#194's checks).
mkdir -p $rx/ln && ln -s $rx/ln-target $rx/ln/lock
out=$(FACTORY_RUN_LOCK=$rx/ln/lock $S run-exclusive -- sh -c 'echo SHOULD-NOT-RUN' 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -qF "$rx/ln/lock is a symlink" && ! echo "$out" | grep -q SHOULD-NOT-RUN && [ ! -e $rx/ln-target ] \
  && ok "run-exclusive refuses a lock file that is a symlink, and runs nothing" || { bad "run-exclusive through a symlink (rc=$rc)"; echo "$out" | tail -2; }
: > $rx/hl-other; mkdir -p $rx/hl && ln $rx/hl-other $rx/hl/lock
out=$(FACTORY_RUN_LOCK=$rx/hl/lock $S run-exclusive -- sh -c 'echo SHOULD-NOT-RUN' 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -qF "$rx/hl/lock is a symlink, a hard link" && ! echo "$out" | grep -q SHOULD-NOT-RUN \
  && ok "run-exclusive refuses a lock file that is a hard link, and runs nothing" || { bad "run-exclusive through a hard link (rc=$rc)"; echo "$out" | tail -2; }
[ "$(stat -f %Lp $(dirname $FACTORY_RUN_LOCK))" = 700 ] && ok "run-exclusive makes the lock's folder owner-only (700)" || bad "run-exclusive lock folder mode ($(stat -f %Lp $(dirname $FACTORY_RUN_LOCK)))"
{ [ $real_was = 1 ] || [ ! -e "$real" ]; } && ok "the e2e never made the real lock's folder ($real)" || bad "the e2e made the real lock's folder $real"
e2e_end=exclusive # the last line: test/e2e.sh checks that the file ran to here
